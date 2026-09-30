//! The route manifest: what the generator knows about every route, as data.
//! It becomes `AppManifest` in the generated Dart (in `app.g.dart`, or in its
//! own library with `output_manifest:`) and the extra fields of
//! `fsp routes --json`.
//!
//! The manifest never interprets a route's `meta.dart`: it lists it by import
//! (`_iN.meta`) and the app decides what the type means.

#![allow(
    clippy::unwrap_used,
    reason = "the parent chain always holds the route it started from"
)]

use std::collections::HashMap;

use serde::Serialize;

use crate::config::Config;
use crate::diag::Diags;
use crate::emit::{dart_str, rel};
use crate::locale;
use crate::resolve::{self, App, Branch, Route};
use crate::scan::{Kind, Seg};
use crate::templates;

/// The tab a route sits in: one branch of the tab layout in folder `layout`.
#[derive(Debug, Clone, PartialEq)]
pub struct TabInfo {
    /// The tab layout's folder, relative to the app folder (`(tabs)`).
    pub layout: String,
    /// The branch's position in the layout's tabs.
    pub index: usize,
    /// The branch as `tabs` and `tabOptions` name it: its folder, or `.` for the layout's own page.
    pub branch: String,
}

/// One route (a page or a `redirect.dart`), with everything the manifest lists.
#[derive(Debug)]
pub struct Info {
    /// `ProductRoute`.
    pub class: String,
    /// `/products/:id`, without the mount point.
    pub path: String,
    /// The path in each locale its segments have a spelling for (`fr`: `/produits/:id`); the
    /// canonical spelling where a level has none. Empty without a localized segment.
    pub paths: Vec<(String, String)>,
    /// The route's folder relative to the app folder; empty for the app folder itself.
    pub folder: String,
    /// page.dart or redirect.dart, relative to the app folder.
    pub file: String,
    /// How the route is served, when it isn't a plain page: `redirect` (a redirect.dart),
    /// `custom` (a present.dart builds the page) or `root` (on the root navigator).
    pub presentation: Option<&'static str>,
    /// `(buyer)`, outermost first.
    pub groups: Vec<String>,
    /// The folders of the layouts that wrap it, outermost first.
    pub layouts: Vec<String>,
    pub segments: Vec<(String, String)>,
    /// The `$$rest` / `$$$rest` catch-all segment at the end of the path: its name, and whether
    /// the path without it is the route's too. Its type in `segments` is `List<String>`.
    pub catch_all: Option<(String, bool)>,
    pub query: Vec<(String, String)>,
    /// What data.dart is keyed by; `None` without a data.dart.
    pub data_keys: Option<Vec<String>>,
    /// The tabs it sits in, outermost first.
    pub tabs: Vec<TabInfo>,
    /// meta.dart, relative to the app folder.
    pub meta: Option<String>,
}

/// Every route, in the order of the table in the header of `app.g.dart`.
pub fn collect(app: &App) -> Vec<Info> {
    let mut parent: HashMap<usize, usize> = HashMap::new();
    for (id, r) in app.routes.iter().enumerate() {
        for &c in &r.children {
            parent.insert(c, id);
        }
    }
    let tabs = tabs_of(app);
    app.routes
        .iter()
        .enumerate()
        .filter(|(_, r)| r.is_route())
        .map(|(id, r)| {
            // The folders from the root down to this one.
            let mut chain = vec![id];
            while let Some(&p) = parent.get(chain.last().unwrap()) {
                chain.push(p);
            }
            chain.reverse();
            let groups = chain
                .iter()
                .filter_map(|&c| match &app.routes[c].seg {
                    Some(Seg::Group(g)) => Some(format!("({g})")),
                    _ => None,
                })
                .collect();
            let layouts = chain
                .iter()
                .filter(|&&c| app.routes[c].layout.is_some())
                .map(|&c| app.routes[c].dir.clone())
                .collect();
            let kind = if r.page.is_some() {
                Kind::Page
            } else {
                Kind::Redirect
            };
            Info {
                class: format!("{}Route", r.name.as_deref().unwrap_or("?")),
                path: resolve::pattern(&r.url),
                paths: locale::locales(&r.localized)
                    .into_iter()
                    .map(|l| {
                        let path = locale::pattern_in(&r.url, &r.localized, &l);
                        (l, path)
                    })
                    .collect(),
                folder: r.dir.clone(),
                file: rel(r, kind),
                presentation: match (r.page.is_some(), r.present.is_some(), r.root) {
                    (false, ..) => Some("redirect"),
                    (_, true, _) => Some("custom"),
                    (_, _, true) => Some("root"),
                    _ => None,
                },
                groups,
                layouts,
                segments: app
                    .typed_segs(r)
                    .into_iter()
                    .map(|(n, t)| (n, app.display_type(&t)))
                    .collect(),
                catch_all: match r.url.last() {
                    Some(Seg::CatchAll(n, optional)) => Some((n.clone(), *optional)),
                    _ => None,
                },
                query: r
                    .query
                    .iter()
                    .map(|(n, t)| (n.clone(), app.display_type(t)))
                    .collect(),
                data_keys: r.data.as_ref().map(|d| d.keys.clone()),
                tabs: tabs.get(&id).cloned().unwrap_or_default(),
                meta: r.meta.clone(),
            }
        })
        .collect()
}

/// The tabs each route sits in. Routes are numbered outermost first, so a
/// nested tab layout adds its tab after the one around it.
fn tabs_of(app: &App) -> HashMap<usize, Vec<TabInfo>> {
    fn subtree(app: &App, id: usize, out: &mut Vec<usize>) {
        out.push(id);
        for &c in &app.routes[id].children {
            subtree(app, c, out);
        }
    }
    let mut out: HashMap<usize, Vec<TabInfo>> = HashMap::new();
    for (id, layout) in app.routes.iter().enumerate() {
        let Some(branches) = &layout.tabs else {
            continue;
        };
        for (index, b) in branches.iter().enumerate() {
            let (branch, members) = match *b {
                Branch::Own => (".".to_string(), vec![id]),
                Branch::Folder(c) => {
                    let mut all = vec![];
                    subtree(app, c, &mut all);
                    (
                        app.routes[c]
                            .dir
                            .rsplit('/')
                            .next()
                            .unwrap_or_default()
                            .to_string(),
                        all,
                    )
                }
            };
            for m in members {
                out.entry(m).or_default().push(TabInfo {
                    layout: layout.dir.clone(),
                    index,
                    branch: branch.clone(),
                });
            }
        }
    }
    out
}

/// The checks on `meta.dart` files the config asks for: `meta: required` and `meta_unique`.
pub fn check(app: &App, cfg: &Config, diags: &mut Diags) {
    check_required(app, cfg, diags);
    check_unique(app, cfg, diags);
}

/// `fespalier: { meta_unique: [code, slug] }`: no two routes pass the same literal to
/// that named argument of `meta`'s constructor call. Only literals (a string, a number,
/// a bool) are compared; an argument that is an expression, or that a route leaves out,
/// says nothing.
fn check_unique(app: &App, cfg: &Config, diags: &mut Diags) {
    use crate::dart::Lit;
    for key in &cfg.meta_unique {
        // (kind, value) of each literal → the first meta.dart that had it.
        let mut seen: HashMap<(&str, &str), &str> = HashMap::new();
        let mut any = false;
        for r in app.routes.iter().filter(|r| r.is_route()) {
            let Some(file) = r.meta.as_deref() else {
                continue;
            };
            let Some(arg) = r.meta_args.iter().find(|a| a.name == *key) else {
                continue;
            };
            let (kind, value, shown) = match &arg.value {
                Lit::Str(v) => ("string", v.as_str(), dart_str(v)),
                Lit::Num(v) => ("number", v.as_str(), v.clone()),
                Lit::Bool(b) => ("bool", if *b { "true" } else { "false" }, b.to_string()),
                Lit::Other => continue,
            };
            any = true;
            match seen.get(&(kind, value)) {
                Some(first) => {
                    let msg = format!(
                        "`{key}: {shown}` is also in {first}; `meta_unique: [{}]` in pubspec.yaml wants every route's `{key}` to differ",
                        cfg.meta_unique.join(", ")
                    );
                    diags.error(file, Some(&arg.span), msg);
                }
                None => {
                    seen.insert((kind, value), file);
                }
            }
        }
        let has_meta = app.routes.iter().any(|r| r.is_route() && r.meta.is_some());
        if has_meta && !any {
            let msg = format!(
                "`meta_unique` in pubspec.yaml lists `{key}`, but no meta.dart passes a literal `{key}:` to its constructor call (`const meta = Meta({key}: 'x');`), so there is nothing to compare"
            );
            diags.warn("pubspec.yaml", None, msg);
        }
    }
}

/// `fespalier: { meta: required }`: a route without a meta.dart is an error.
fn check_required(app: &App, cfg: &Config, diags: &mut Diags) {
    if !cfg.meta_required {
        return;
    }
    for r in app
        .routes
        .iter()
        .filter(|r| r.is_route() && r.meta.is_none())
    {
        // A meta.dart that is broken already has its own error.
        let kind = if r.page.is_some() {
            Kind::Page
        } else {
            Kind::Redirect
        };
        let folder = if r.dir.is_empty() {
            "the app folder".to_string()
        } else {
            format!("`{}/`", r.dir)
        };
        let broken = diags.0.iter().any(|d| d.file == rel_meta(r));
        if !broken {
            let msg = format!(
                "{folder} has no meta.dart, and `fespalier: meta: required` in pubspec.yaml wants one per route: `const meta = ...;`"
            );
            diags.error(&rel(r, kind), r.page_span.as_ref(), msg);
        }
    }
}

fn rel_meta(r: &Route) -> String {
    rel(r, Kind::Meta)
}

// --- Dart ------------------------------------------------------------------

#[derive(Serialize)]
pub struct ManifestCx {
    routes: Vec<RouteInfoCx>,
}

/// Every field is a Dart expression, or `None` to leave the argument out.
#[derive(Serialize)]
struct RouteInfoCx {
    class: String,
    path: String,
    /// `{'fr': '/produits/:id'}`, `None` without a localized segment.
    paths: Option<String>,
    folder: String,
    /// `redirect`, `root` or `custom`: a `RoutePresentation`; `None` for a plain page.
    presentation: Option<&'static str>,
    groups: Option<String>,
    layouts: Option<String>,
    segments: Option<String>,
    query: Option<String>,
    tabs: Option<String>,
    data_keys: Option<String>,
    meta: Option<String>,
}

#[derive(Serialize)]
struct FileCx<'a> {
    app_dir: &'a str,
    /// The main output, imported for the typed routes.
    app_import: String,
    imports: Vec<String>,
    manifest: ManifestCx,
}

/// A Dart list literal of the items, `None` when there are none.
fn list(items: Vec<String>) -> Option<String> {
    (!items.is_empty()).then(|| format!("[{}]", items.join(", ")))
}

fn params(ps: &[(String, String)]) -> Option<String> {
    list(
        ps.iter()
            .map(|(n, t)| format!("RouteParam({}, {})", dart_str(n), dart_str(t)))
            .collect(),
    )
}

/// The manifest as template data. The meta.dart files it lists are numbered
/// from `first_import`: `_i{first_import}` is the first; they are returned in that order.
pub fn cx(app: &App, first_import: usize) -> (ManifestCx, Vec<String>) {
    let mut metas: Vec<String> = vec![];
    let routes = collect(app)
        .into_iter()
        .map(|i| {
            let meta = i.meta.as_ref().map(|f| {
                let at = metas.iter().position(|m| m == f).unwrap_or_else(|| {
                    metas.push(f.clone());
                    metas.len() - 1
                });
                format!("_i{}.meta", first_import + at)
            });
            RouteInfoCx {
                class: i.class,
                path: dart_str(&i.path),
                paths: (!i.paths.is_empty()).then(|| {
                    let entries: Vec<String> = i
                        .paths
                        .iter()
                        .map(|(l, p)| format!("{}: {}", dart_str(l), dart_str(p)))
                        .collect();
                    format!("{{{}}}", entries.join(", "))
                }),
                folder: dart_str(&i.folder),
                presentation: i.presentation,
                groups: list(i.groups.iter().map(|g| dart_str(g)).collect()),
                layouts: list(i.layouts.iter().map(|l| dart_str(l)).collect()),
                segments: list(
                    i.segments
                        .iter()
                        .map(|(n, t)| {
                            let rest = i.catch_all.as_ref().is_some_and(|(c, _)| c == n);
                            let flag = if rest { ", catchAll: true" } else { "" };
                            format!("RouteParam({}, {}{flag})", dart_str(n), dart_str(t))
                        })
                        .collect(),
                ),
                query: params(&i.query),
                tabs: list(
                    i.tabs
                        .iter()
                        .map(|t| {
                            format!(
                                "RouteTab({}, {}, {})",
                                dart_str(&t.layout),
                                t.index,
                                dart_str(&t.branch)
                            )
                        })
                        .collect(),
                ),
                data_keys: i.data_keys.map(|k| {
                    format!(
                        "[{}]",
                        k.iter().map(|k| dart_str(k)).collect::<Vec<_>>().join(", ")
                    )
                }),
                meta,
            }
        })
        .collect();
    (ManifestCx { routes }, metas)
}

/// The manifest library, when `output_manifest:` asks for one.
pub fn emit(app: &App, cfg: &Config) -> Option<String> {
    let app_import = cfg.output_from_manifest()?;
    let (manifest, metas) = cx(app, 0);
    let imports = metas
        .iter()
        .map(|f| cfg.import_path_from_manifest(&f.replace('$', "\\$")))
        .collect();
    Some(templates::render(
        "manifest.dart",
        FileCx {
            app_dir: &cfg.app_dir,
            app_import,
            imports,
            manifest,
        },
    ))
}
