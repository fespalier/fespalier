//! The route tree as JSON, for fespalier's DevTools extension (since 0.7.0).
//!
//! `fsp routes --graph json` prints it, and `app.g.dart` embeds the same tree (compact) in a
//! function the runtime hands to DevTools. It is what [`emit::frames`] gives `go_router`, plus
//! what the extension needs to name a route's file, parameters and markers:
//!
//! ```text
//! {"protocol":1,"package":"shop","appDir":"lib/app",
//!  "items":[
//!    {"type":"route","pattern":"/products/:id","route":"ProductRoute","file":"products/$id/page.dart",
//!     "folder":"products/$id","markers":["data","guard"],"spellings":{"fr":"/produits/:id"},
//!     "params":[{"name":"id","type":"int","in":"path"}],"redirect":false,"children":[…]},
//!    {"type":"shell","file":"(account)/layout.dart","folder":"(account)","markers":["guard"],"items":[…]},
//!    {"type":"tabs","file":"(tabs)/layout.dart","folder":"(tabs)","markers":[],
//!     "branches":[{"index":0,"name":"(home)","items":[…]}]}],
//!  "sites":{"g5@6":{"kind":"guard","file":"(account)/guard.dart","route":"AdminRoute","pattern":"/admin"},…}}
//! ```
//!
//! `file` and `folder` are relative to `appDir`, `markers` are the ones `--graph` draws
//! ([`graph::markers`]), and `params` and `spellings` are the ones `fsp routes --json` has. The
//! tree is protocol 1 of the extension: a new key is fine, a renamed or removed one is protocol 2.
//!
//! **Sites** name the places the generated code has a guard, a `redirect.dart`, a `data.dart` or an
//! action, by the same strings the generated code uses (`refGuard`'s `'g5@6'`, `_data37`,
//! `_action37_0`), so a later protocol can tell DevTools which of them ran. The functions that
//! spell them are here, and `emit.rs` calls them, so the tree and the code cannot disagree.

use std::collections::{BTreeMap, HashMap};

use serde_json::{Map, Value, json};

use crate::config::Config;
use crate::emit::{self, Frame, rel};
use crate::graph;
use crate::locale;
use crate::manifest::{self, Info};
use crate::resolve::{self, App};
use crate::scan::Kind;

/// The protocol of the tree and of everything else the extension and the runtime exchange.
pub const PROTOCOL: u32 = 1;

/// The site of the guard in folder `guard` on the route in folder `route`: the string
/// `refGuard` takes (`g5@6`).
pub fn site_guard(guard: usize, route: usize) -> String {
    format!("g{guard}@{route}")
}

/// The site of the `redirect.dart` of the route in folder `route`.
pub fn site_redirect(route: usize) -> String {
    format!("r{route}")
}

/// The site of the `data.dart` of folder `folder`: the suffix of its provider, `_data37`.
pub fn site_data(folder: usize) -> String {
    format!("d{folder}")
}

/// The site of the `index`th function of the `action.dart` of folder `folder`: the suffix of
/// its provider, `_action37_0`.
pub fn site_action(folder: usize, index: usize) -> String {
    format!("a{folder}_{index}")
}

/// The tree of `app`, as `fsp routes --graph json` prints it and `app.g.dart` embeds it.
pub fn tree(app: &App, cfg: &Config) -> Value {
    let infos: HashMap<usize, Info> = app
        .routes
        .iter()
        .enumerate()
        .filter(|(_, r)| r.is_route())
        .map(|(id, _)| id)
        .zip(manifest::collect(app))
        .collect();
    let mut sites = Sites::default();
    let items = items(app, &infos, &emit::frames(app), &mut sites);
    sites.of_folders(app, &infos);
    json!({
        "protocol": PROTOCOL,
        "package": cfg.package,
        "appDir": cfg.app_dir,
        "items": items,
        "sites": sites.into_json(),
    })
}

/// [`tree`] as `fsp routes --graph json` prints it: indented, one trailing newline.
pub fn pretty(app: &App, cfg: &Config) -> String {
    let mut text = serde_json::to_string_pretty(&tree(app, cfg)).unwrap_or_default();
    text.push('\n');
    text
}

/// [`tree`] as the generated file embeds it.
pub fn compact(app: &App, cfg: &Config) -> String {
    tree(app, cfg).to_string()
}

fn items(
    app: &App,
    infos: &HashMap<usize, Info>,
    frames: &[Frame],
    sites: &mut Sites,
) -> Vec<Value> {
    frames.iter().map(|f| item(app, infos, f, sites)).collect()
}

fn item(app: &App, infos: &HashMap<usize, Info>, frame: &Frame, sites: &mut Sites) -> Value {
    match frame {
        Frame::Route {
            id,
            url,
            root,
            guarded,
            guards,
            children,
        } => {
            let r = &app.routes[*id];
            let info = &infos[id];
            sites.of_route(app, *id, guards, info);
            let params: Vec<Value> = info
                .segments
                .iter()
                .map(|(n, t)| json!({"name": n, "type": t, "in": "path"}))
                .chain(
                    info.query
                        .iter()
                        .map(|(n, t)| json!({"name": n, "type": t, "in": "query"})),
                )
                .collect();
            let mut node = Map::new();
            node.insert("type".into(), "route".into());
            node.insert("pattern".into(), resolve::pattern(url).into());
            node.insert("route".into(), info.class.clone().into());
            node.insert("file".into(), info.file.clone().into());
            node.insert("folder".into(), info.folder.clone().into());
            node.insert("markers".into(), json!(graph::markers(r, *root, *guarded)));
            // Only for a route with a localized segment, as `fsp routes --json`'s `paths`.
            let spellings: Map<String, Value> = locale::locales(&r.localized)
                .into_iter()
                .map(|l| {
                    let path = locale::pattern_in(url, &r.localized, &l);
                    (l, Value::from(path))
                })
                .collect();
            if !spellings.is_empty() {
                node.insert("spellings".into(), spellings.into());
            }
            node.insert("params".into(), params.into());
            node.insert("redirect".into(), r.page.is_none().into());
            node.insert("children".into(), items(app, infos, children, sites).into());
            node.into()
        }
        Frame::Shell { id, root, children } => {
            let r = &app.routes[*id];
            json!({
                "type": "shell",
                "file": rel(r, Kind::Layout),
                "folder": r.dir,
                "markers": graph::layout_marks(r, *root),
                "items": items(app, infos, children, sites),
            })
        }
        Frame::Tabs { id, root, branches } => {
            let r = &app.routes[*id];
            let branches: Vec<Value> = branches
                .iter()
                .enumerate()
                .map(|(index, (name, routes))| {
                    json!({
                        "index": index,
                        "name": name,
                        "items": items(app, infos, routes, sites),
                    })
                })
                .collect();
            json!({
                "type": "tabs",
                "file": rel(r, Kind::Layout),
                "folder": r.dir,
                "markers": graph::layout_marks(r, *root),
                "branches": branches,
            })
        }
    }
}

/// The sites of the tree, by id: sorted, so the output does not depend on the order they were
/// found in.
#[derive(Default)]
struct Sites(BTreeMap<String, Value>);

impl Sites {
    /// The guards that run before the route in folder `id`, by the folder each one is in.
    fn of_route(&mut self, app: &App, id: usize, guards: &[usize], info: &Info) {
        for &g in guards {
            self.0.insert(
                site_guard(g, id),
                json!({
                    "kind": "guard",
                    "file": rel(&app.routes[g], Kind::Guard),
                    "route": info.class,
                    "pattern": info.path,
                }),
            );
        }
    }

    /// The `redirect.dart`, `data.dart` and `action.dart` of every folder: they do not depend on
    /// where the folder sits in the tree.
    fn of_folders(&mut self, app: &App, infos: &HashMap<usize, Info>) {
        for (id, r) in app.routes.iter().enumerate() {
            let class = infos.get(&id).map(|i| i.class.clone());
            if let (Some(_), Some(info)) = (&r.redirect, infos.get(&id)) {
                self.0.insert(
                    site_redirect(id),
                    json!({
                        "kind": "redirect",
                        "file": rel(r, Kind::Redirect),
                        "route": info.class,
                        "pattern": info.path,
                    }),
                );
            }
            if let Some(d) = &r.data {
                self.0.insert(
                    site_data(id),
                    json!({
                        "kind": "data",
                        "file": rel(r, Kind::Data),
                        "route": class,
                        "section": r.is_section().then(|| r.dir.clone()),
                        "traced": !(d.provider || d.selector),
                    }),
                );
            }
            for (i, a) in r.actions.iter().enumerate() {
                self.0.insert(
                    site_action(id, i),
                    json!({
                        "kind": "action",
                        "file": rel(r, Kind::Action),
                        "name": a.name,
                        "route": class,
                    }),
                );
            }
        }
    }

    fn into_json(self) -> Value {
        Value::Object(self.0.into_iter().collect())
    }
}
