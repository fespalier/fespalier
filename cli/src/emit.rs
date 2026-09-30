//! Writes the generated file (`lib/app.g.dart` by default): one readable,
//! committed file that federates the tree into `AppRoutes.router()` / `AppRoutes.mount(at:)` plus typed routes.
//!
//! This module works out every expression; `templates/app.g.dart.jinja` owns
//! the layout of the file.

use std::collections::BTreeSet;

use serde::Serialize;

use crate::config::{Config, DataRetry};
use crate::resolve::{self, App, Bind, Branch, Data, Guard, Route, Transition};
use crate::dart::Span;
use crate::diag::Diags;
use crate::manifest::{self, ManifestCx};
use crate::scan::{Kind, Seg};
use crate::templates;

#[derive(Serialize)]
struct FileCx {
    app_dir: String,
    table: Vec<String>,
    imports: Vec<String>,
    tree: Vec<TreeCx>,
    not_found: String,
    /// not_found.dart files below the root, deepest first.
    not_founds: Vec<NotFoundCx>,
    routes: Vec<RouteCx>,
    params_fns: Vec<ParamsFnCx>,
    providers: Vec<ProviderCx>,
    /// The route manifest, unless `output_manifest:` moves it to its own library.
    manifest: Option<ManifestCx>,
    /// `import '...' show Product;` lines for the types of typed `extra`s.
    extra_imports: Vec<String>,
    /// Whether routes match paths by case.
    case_sensitive: bool,
    /// `keep_previous` from the config: the DataViews' `keepPrevious`.
    keep_previous: bool,
}

/// A GoRoute; a ShellRoute when `layout` is set; a StatefulShellRoute when
/// `branches` is set too.
#[derive(Serialize)]
struct TreeCx {
    layout: Option<LayoutCx>,
    /// A tab layout's tabs, each holding the routes of one folder.
    branches: Vec<BranchCx>,
    path: String,
    /// Guards (inherited, then its own) and, for a redirect.dart route, the
    /// redirect itself: the first to return a location wins.
    redirects: Vec<CallCx>,
    /// A route that only redirects still builds not-found for a segment that
    /// doesn't parse (go_router needs a builder to show anything).
    not_found_builder: bool,
    seg_fn: Option<String>,
    page: String,
    data: Option<ViewDataCx>,
    /// What an unparsable segment shows.
    not_found: String,
    transition: Option<TransitionCx>,
    routes: Vec<TreeCx>,
    /// Starts with a `:segment` (or, for a ShellRoute, holds a route that does).
    #[serde(skip)]
    dynamic: bool,
    /// Ends in a catch-all `:rest(.+)` (or a shell holds a route that does): tried last.
    #[serde(skip)]
    catch_all: bool,
    /// For a GoRoute: its URL, page file and page class, to check matching order.
    #[serde(skip)]
    serves: Option<Serves>,
    /// For a GoRoute: its own `path:` has a `:segment`.
    #[serde(skip)]
    has_params: bool,
}

type Serves = (Vec<Seg>, String, Option<Span>);

#[derive(Serialize)]
struct BranchCx {
    routes: Vec<TreeCx>,
    /// A Dart expression: the app location joined to the mount point.
    initial_location: Option<String>,
    preload: bool,
    /// A Dart string literal: the tab's Navigator scope, from its folder.
    restoration_id: String,
}

/// `'it\'s'`: a Dart string literal for `s`.
pub fn dart_str(s: &str) -> String {
    let mut out = String::from("'");
    for c in s.chars() {
        if matches!(c, '\'' | '\\' | '$') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// go_router takes the first route that matches, so `/about` must come before
/// `/:id`, and both before a catch-all `/:rest(.+)`. The sort is stable:
/// otherwise folders keep their order.
fn static_first(mut routes: Vec<TreeCx>) -> Vec<TreeCx> {
    routes.sort_by_key(|r| (r.catch_all, r.dynamic));
    routes
}

/// A call that may need the route's segments parsed first.
#[derive(Serialize)]
struct CallCx {
    seg_fn: Option<String>,
    call: String,
}

/// A layout's builder body: `page` is the layout widget, which a section's `data`
/// (when set) loads first.
#[derive(Serialize)]
struct LayoutCx {
    seg_fn: Option<String>,
    page: String,
    data: Option<ViewDataCx>,
    not_found: String,
    /// The Navigator's `restorationScopeId`, from the layout's folder.
    restoration_id: String,
}

/// A not_found.dart below the root: its URL prefix (`['products', ':id']`) and widget.
#[derive(Serialize)]
struct NotFoundCx {
    prefix: String,
    call: String,
}

/// `_i2.transition(...)`, with the page where `Bind::Child` goes.
#[derive(Serialize)]
struct TransitionCx {
    call: String,
    args: Vec<TransitionArgCx>,
}

#[derive(Serialize)]
struct TransitionArgCx {
    /// `child: ` for a named parameter.
    prefix: String,
    /// `None` for the page itself.
    value: Option<String>,
}

fn transition_cx(t: &Transition) -> TransitionCx {
    let args = t
        .args
        .iter()
        .map(|a| TransitionArgCx {
            prefix: if a.named { format!("{}: ", a.name) } else { String::new() },
            value: (a.bind != Bind::Child).then(|| in_builder(&a.bind)),
        })
        .collect();
    TransitionCx { call: format!("_i{}.transition", t.import), args }
}

#[derive(Serialize)]
struct ViewDataCx {
    provider: String,
    loading: String,
    error: String,
}

#[derive(Serialize)]
struct RouteCx {
    pattern: String,
    file: String,
    name: String,
    fields: Vec<FieldCx>,
    data: Option<TypedDataCx>,
    location: String,
    /// A catch-all that can't be empty: `location` checks it.
    location_assert: Option<String>,
    /// The type of the page's `extra`, when it takes one.
    extra: Option<String>,
}

#[derive(Serialize)]
struct FieldCx {
    name: String,
    ty: String,
    /// How the constructor takes it: `required this.id`, `this.page`, ...
    param: String,
}

#[derive(Serialize)]
struct TypedDataCx {
    file: String,
    keyed: String,
    expr: String,
    verb: &'static str,
    key: String,
    /// `, {required int id, int? page}`: the keys as named parameters of the static
    /// `watch` and `read`, whose types are inferred from the provider.
    args: String,
}

/// Parses what a route (or layout) reads from the URL into a record.
#[derive(Serialize)]
struct ParamsFnCx {
    name: String,
    record: String,
    parse: String,
}

/// Which parse function: a route's own, or its folder's layout's.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum ParamsFn {
    Route(usize),
    Layout(usize),
    /// What one folder's guard reads from the URL.
    Guard(usize),
}

impl ParamsFn {
    fn name(self) -> String {
        match self {
            ParamsFn::Route(id) => format!("_params{id}"),
            ParamsFn::Layout(id) => format!("_layout{id}"),
            ParamsFn::Guard(id) => format!("_guard{id}"),
        }
    }
}

#[derive(Serialize)]
struct ProviderCx {
    id: usize,
    kind: &'static str,
    family: bool,
    params: String,
    call: String,
    /// `data_retry: none`: the provider opts out of Riverpod's retry.
    no_retry: bool,
}

pub fn emit(app: &App, cfg: &Config, diags: &mut Diags) -> String {
    let mut fns = BTreeSet::new();
    let tree = routes_of(app, 0, true, "", &[], &mut fns);
    check_order(&tree, diags);
    check_tab_starts(&tree, diags);
    // With no `output_manifest:` the manifest lives here, and imports its meta.dart files here.
    let (manifest, metas) = match cfg.output_manifest {
        None => {
            let (m, metas) = manifest::cx(app, app.imports.len());
            (Some(m), metas)
        }
        Some(_) => (None, vec![]),
    };
    let cx = FileCx {
        app_dir: cfg.app_dir.clone(),
        table: table(app),
        imports: app.imports.iter().chain(&metas).map(|rel| cfg.import_path(&rel.replace('$', "\\$"))).collect(),
        manifest,
        tree,
        not_found: match &app.not_found {
            Some(w) => w.call(|_| "uri".into()),
            None => "DefaultNotFound(uri)".into(),
        },
        not_founds: not_founds(app),
        routes: app.routes.iter().enumerate().filter_map(|(id, r)| typed_route(app, id, r)).collect(),
        params_fns: fns.into_iter().map(|f| params_fn(app, f)).collect(),
        providers: app.routes.iter().enumerate().filter_map(|(id, r)| provider(app, cfg, id, r)).collect(),
        extra_imports: extra_imports(app, cfg),
        case_sensitive: cfg.case_sensitive,
        keep_previous: cfg.keep_previous,
    };
    templates::render("app.g.dart", &cx)
}

/// How builder code spells each binding. `v` holds the parsed segments.
fn in_builder(b: &Bind) -> String {
    match b {
        Bind::Segment(s) | Bind::Query(s) => format!("v.{s}"),
        Bind::Data => "d".into(),
        Bind::Section(id) => format!("s{id}"),
        Bind::Child => "child".into(),
        Bind::Shell => "navigationShell".into(),
        Bind::Error => "e".into(),
        Bind::StackTrace => "st".into(),
        Bind::Retry => "retry".into(),
        Bind::Uri => "uri".into(),
        Bind::PageKey => "state.pageKey".into(),
        Bind::State => "state".into(),
        // Typed by the parameter it fills.
        Bind::Extra => "extraOf(state)".into(),
    }
}

/// RouteBase entries for a folder. Page-less folders fold their segment into
/// their children's paths; `layout.dart` wraps the result in a ShellRoute.
/// `inherited` holds the guards (route ids) of the folders above that have no
/// route of their own to nest under: every route here starts with them.
fn routes_of(app: &App, id: usize, top: bool, prefix: &str, inherited: &[usize], fns: &mut BTreeSet<ParamsFn>) -> Vec<TreeCx> {
    let r = &app.routes[id];
    let own = match &r.seg {
        None | Some(Seg::Group(_)) => String::new(),
        Some(Seg::Static(s)) => s.clone(),
        Some(Seg::Dynamic(n)) => format!(":{n}"),
        // A catch-all is a parameter with its own pattern: one or more segments.
        Some(Seg::CatchAll(n, _)) => format!(":{n}(.+)"),
    };
    let path = match (prefix.is_empty(), own.is_empty()) {
        (_, true) => prefix.trim_end_matches('/').to_string(),
        (true, false) => own,
        (false, false) => format!("{prefix}{own}"),
    };

    if let (Some(layout), Some(tabs)) = (&r.layout, &r.tabs) {
        return tab_routes(app, id, top, &path, layout, tabs, inherited, fns);
    }

    // Routes beside or below this folder that its own route doesn't contain.
    let mut below = inherited.to_vec();
    below.extend(r.guard.as_ref().map(|_| id));
    let next = if path.is_empty() { String::new() } else { format!("{path}/") };
    // An optional catch-all is two routes: one for the path without it, one with.
    let parent = matches!(&r.seg, Some(Seg::CatchAll(_, true))).then(|| prefix.trim_end_matches('/').to_string());
    let mut out = match (&r.page, &r.redirect) {
        (Some(_), _) => {
            let mut out: Vec<TreeCx> = parent
                .iter()
                .map(|p| without_catch_all(page_route(app, id, top, p, false, inherited, fns), r))
                .collect();
            out.push(page_route(app, id, top, &path, true, inherited, fns));
            out
        }
        // A redirect route always redirects, so what is below it can't nest inside it.
        (None, Some(_)) => {
            let mut out: Vec<TreeCx> = parent
                .iter()
                .map(|p| without_catch_all(redirect_route(app, id, top, p, inherited, fns), r))
                .collect();
            out.push(redirect_route(app, id, top, &path, inherited, fns));
            out.extend(r.children.iter().flat_map(|&c| routes_of(app, c, top, &next, &below, fns)));
            static_first(out)
        }
        (None, None) => static_first(r.children.iter().flat_map(|&c| routes_of(app, c, top, &next, &below, fns)).collect()),
    };

    if let (Some(layout), false) = (&r.layout, out.is_empty()) {
        out = vec![TreeCx {
            layout: Some(layout_cx(app, id, layout, fns)),
            branches: vec![],
            path: String::new(),
            redirects: vec![],
            not_found_builder: false,
            seg_fn: None,
            page: String::new(),
            data: None,
            not_found: String::new(),
            transition: None,
            dynamic: out.iter().any(|r| r.dynamic),
            catch_all: out.iter().any(|r| r.catch_all),
            serves: None,
            has_params: false,
            routes: out,
        }];
    }
    out
}

/// A folder as restoration ids spell it: `(tabs)/`, or `/` for the app folder.
fn folder_id(dir: &str) -> String {
    if dir.is_empty() { "/".into() } else { format!("{dir}/") }
}

/// A tab as `tabs` names it: its folder's name, or `.` for the layout's own page.
fn branch_name(app: &App, b: Branch) -> String {
    match b {
        Branch::Own => ".".into(),
        Branch::Folder(c) => app.routes[c].dir.rsplit('/').next().unwrap_or_default().to_string(),
    }
}

/// The route for the path above an optional catch-all: it serves that URL, not the folder's.
fn without_catch_all(mut t: TreeCx, r: &Route) -> TreeCx {
    if let (Some((_, file, span)), Some((_, parent))) = (t.serves.take(), r.url.split_last()) {
        t.serves = Some((parent.to_vec(), file, span));
    }
    t
}

/// What a folder's layout builds: the layout widget, behind its section's data.dart when
/// it has one, and inside the data.dart files of the sections above it that it asks for.
fn layout_cx(app: &App, id: usize, layout: &resolve::Widget, fns: &mut BTreeSet<ParamsFn>) -> LayoutCx {
    let r = &app.routes[id];
    let section = r.data.as_ref().filter(|_| r.is_section());
    let has_params = !r.segs.is_empty() || !r.layout_query.is_empty();
    let wrapped = with_sections(app, &layout.args, layout.call(in_builder));
    let reads_url = has_params
        && (section.is_some()
            || wrapped != layout.call(in_builder)
            || layout.args.iter().any(|a| matches!(a.bind, Bind::Segment(_) | Bind::Query(_))));
    let seg_fn = reads_url.then(|| {
        fns.insert(ParamsFn::Layout(id));
        ParamsFn::Layout(id).name()
    });
    LayoutCx {
        restoration_id: dart_str(&format!("layout:{}", folder_id(&r.dir))),
        seg_fn,
        page: wrapped,
        data: section.map(|d| ViewDataCx {
            provider: format!("{}{}", provider_expr(id, d), key_expr(app, r, d, "v.")),
            loading: r.loading.as_ref().map_or("const DefaultLoading()".into(), |w| w.call(in_builder)),
            error: r.error.as_ref().map_or("DefaultError(error: e, retry: retry)".into(), |w| w.call(in_builder)),
        }),
        not_found: not_found_call(r),
    }
}

/// Wraps `inner` in a `SectionView` for each section above that its widget takes data
/// from (`Bind::Section`): the section's layout has loaded it, so it's read from the
/// same provider.
fn with_sections(app: &App, args: &[resolve::Arg], inner: String) -> String {
    let mut ids: Vec<usize> = vec![];
    for a in args {
        if let Bind::Section(id) = a.bind {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    ids.into_iter().rev().fold(inner, |acc, sid| {
        let d = app.routes[sid].data.as_ref().expect("a section has data");
        format!(
            "SectionView(\n  watch: (ref) => ref.watch({}{}),\n  data: (s{sid}) => {},\n)",
            provider_expr(sid, d),
            key_expr(app, &app.routes[sid], d, "v."),
            acc.replace('\n', "\n  ")
        )
    })
}

/// What an unparsable segment shows: the nearest not_found.dart below the root, or the
/// root's, which `notFound` picks.
fn not_found_call(r: &Route) -> String {
    r.not_found.as_ref().map_or("notFound(state.uri)".into(), |w| w.call(|_| "state.uri".into()))
}

/// The not_found.dart files below the root, deepest first, static folders before
/// dynamic ones at the same depth, so the nearest match is the first.
fn not_founds(app: &App) -> Vec<NotFoundCx> {
    let mut all: Vec<&resolve::ScopedNotFound> = app.not_founds.iter().collect();
    all.sort_by_key(|n| {
        let dynamic = n.url.iter().filter(|s| matches!(s, Seg::Dynamic(_))).count();
        (std::cmp::Reverse(n.url.len()), dynamic, resolve::pattern(&n.url))
    });
    all.into_iter()
        .map(|n| {
            let parts: Vec<String> = n
                .url
                .iter()
                .filter_map(|s| match s {
                    Seg::Static(s) => Some(format!("'{s}'")),
                    Seg::Dynamic(d) | Seg::CatchAll(d, _) => Some(format!("':{d}'")),
                    Seg::Group(_) => None,
                })
                .collect();
            NotFoundCx { prefix: format!("[{}]", parts.join(", ")), call: n.widget.call(|_| "uri".into()) }
        })
        .collect()
}

/// The redirect chain of a route: the guards inherited from page-less folders
/// above (outermost first), then the folder's own guard and `redirect.dart`.
/// `seg_fn` parses the route's own params for the last two.
fn redirects_of(app: &App, id: usize, inherited: &[usize], seg_fn: &Option<String>, fns: &mut BTreeSet<ParamsFn>) -> Vec<CallCx> {
    let r = &app.routes[id];
    let mut out = vec![];
    for &g in inherited {
        let guard = app.routes[g].guard.as_ref().expect("inherited guards have a guard");
        let seg_fn = (!guard.keys().is_empty()).then(|| {
            fns.insert(ParamsFn::Guard(g));
            ParamsFn::Guard(g).name()
        });
        out.push(hook_call(guard, "guard", seg_fn));
    }
    for (hook, name) in [(&r.guard, "guard"), (&r.redirect, "redirect")] {
        if let Some(h) = hook {
            let own = seg_fn.clone().filter(|_| !h.keys().is_empty());
            out.push(hook_call(h, name, own));
        }
    }
    out
}

/// `_i3.guard(container, id: v.id, uri: state.uri)`; `seg_fn` parses `v`.
fn hook_call(h: &Guard, name: &str, seg_fn: Option<String>) -> CallCx {
    let mut args = vec![];
    if h.container {
        args.push("ProviderScope.containerOf(context, listen: false)".to_string());
    }
    args.extend(h.args.iter().map(|a| match a.bind {
        Bind::Uri => format!("{}: state.uri", a.name),
        _ => format!("{}: {}", a.name, in_builder(&a.bind)),
    }));
    CallCx { seg_fn, call: format!("_i{}.{name}({})", h.import, args.join(", ")) }
}

/// The parse function a route's own guard and redirect share, when it needs one.
fn own_seg_fn(app: &App, id: usize, fns: &mut BTreeSet<ParamsFn>) -> Option<String> {
    (!app.url_params(&app.routes[id]).is_empty()).then(|| {
        fns.insert(ParamsFn::Route(id));
        ParamsFn::Route(id).name()
    })
}

/// The GoRoute for a folder's page.dart. Its subfolders' routes nest below it,
/// unless `nested` is off (a tab layout's own page sits beside its tabs).
fn page_route(app: &App, id: usize, top: bool, path: &str, nested: bool, inherited: &[usize], fns: &mut BTreeSet<ParamsFn>) -> TreeCx {
    let r = &app.routes[id];
    let page = r.page.as_ref().expect("page_route needs a page.dart");
    let routes = if nested {
        static_first(r.children.iter().flat_map(|&c| routes_of(app, c, false, "", &[], fns)).collect())
    } else {
        vec![]
    };
    let seg_fn = own_seg_fn(app, id, fns);
    let redirects = redirects_of(app, id, inherited, &seg_fn, fns);
    let data = r.data.as_ref().map(|d| ViewDataCx {
        provider: format!("{}{}", provider_expr(id, d), key_expr(app, r, d, "v.")),
        loading: r.loading.as_ref().map_or("const DefaultLoading()".into(), |w| w.call(in_builder)),
        error: r.error.as_ref().map_or("DefaultError(error: e, retry: retry)".into(), |w| w.call(in_builder)),
    });
    TreeCx {
        layout: None,
        branches: vec![],
        path: if top { format!("joinLocation(at, '/{path}')") } else { format!("'{path}'") },
        redirects,
        not_found_builder: false,
        seg_fn,
        page: with_sections(app, &page.args, page.call(in_builder)),
        data,
        not_found: not_found_call(r),
        transition: r.transition.as_ref().map(transition_cx),
        routes,
        dynamic: path.contains(':'),
        catch_all: path.contains("(.+)"),
        serves: Some((r.url.clone(), rel(r, Kind::Page), r.page_span.clone())),
        has_params: path.contains(':'),
    }
}

/// The GoRoute for a folder's redirect.dart: no page, just a redirect.
fn redirect_route(app: &App, id: usize, top: bool, path: &str, inherited: &[usize], fns: &mut BTreeSet<ParamsFn>) -> TreeCx {
    let r = &app.routes[id];
    let seg_fn = own_seg_fn(app, id, fns);
    let redirects = redirects_of(app, id, inherited, &seg_fn, fns);
    TreeCx {
        layout: None,
        branches: vec![],
        path: if top { format!("joinLocation(at, '/{path}')") } else { format!("'{path}'") },
        redirects,
        // Only a segment that isn't a String can fail to parse.
        not_found_builder: app.typed_segs(r).iter().any(|(_, t)| t != "String" && t != "List<String>"),
        seg_fn,
        page: String::new(),
        data: None,
        not_found: not_found_call(r),
        transition: None,
        routes: vec![],
        dynamic: path.contains(':'),
        catch_all: path.contains("(.+)"),
        serves: Some((r.url.clone(), rel(r, Kind::Redirect), r.page_span.clone())),
        has_params: path.contains(':'),
    }
}

/// A tab layout: one StatefulShellRoute whose branches are the layout folder's
/// own page and each subfolder, laid out exactly as they would be without it.
#[allow(clippy::too_many_arguments)]
fn tab_routes(
    app: &App,
    id: usize,
    top: bool,
    path: &str,
    layout: &resolve::Widget,
    tabs: &[Branch],
    inherited: &[usize],
    fns: &mut BTreeSet<ParamsFn>,
) -> Vec<TreeCx> {
    // The tabs are siblings of the folder's page, so they share its path.
    let next = if path.is_empty() { String::new() } else { format!("{path}/") };
    // The folder's own guard covers its page, and the tabs beside it too.
    let mut below = inherited.to_vec();
    below.extend(app.routes[id].guard.as_ref().map(|_| id));
    let options = &app.routes[id].tab_options;
    let branches: Vec<BranchCx> = tabs
        .iter()
        .enumerate()
        .map(|(i, b)| BranchCx {
            routes: match *b {
                Branch::Own => vec![page_route(app, id, top, path, false, inherited, fns)],
                Branch::Folder(c) => static_first(routes_of(app, c, top, &next, &below, fns)),
            },
            initial_location: options
                .get(i)
                .and_then(|o| o.initial_location.as_ref())
                .map(|l| format!("joinLocation(at, {})", dart_str(l))),
            preload: options.get(i).is_some_and(|o| o.preload),
            restoration_id: dart_str(&format!("tab:{}{}", folder_id(&app.routes[id].dir), branch_name(app, *b))),
        })
        .filter(|b| !b.routes.is_empty())
        .collect();
    if branches.is_empty() {
        return vec![];
    }
    vec![TreeCx {
        layout: Some(layout_cx(app, id, layout, fns)),
        dynamic: branches.iter().flat_map(|b| &b.routes).any(|r| r.dynamic),
        catch_all: branches.iter().flat_map(|b| &b.routes).any(|r| r.catch_all),
        branches,
        path: String::new(),
        redirects: vec![],
        not_found_builder: false,
        seg_fn: None,
        page: String::new(),
        data: None,
        not_found: String::new(),
        transition: None,
        serves: None,
        has_params: false,
        routes: vec![],
    }]
}

/// go_router tries routes depth-first, in order, and takes the first full
/// match. Static routes are sorted first, but a ShellRoute's routes can't be
/// interleaved with its siblings', so `(group)/about` can still end up behind
/// a `/:slug` outside the group. Report any page that is always caught first.
fn check_order(tree: &[TreeCx], diags: &mut Diags) {
    fn walk<'t>(t: &'t [TreeCx], out: &mut Vec<&'t Serves>) {
        for r in t {
            out.extend(r.serves.as_ref());
            walk(&r.routes, out);
            for b in &r.branches {
                walk(&b.routes, out);
            }
        }
    }
    let mut order = vec![];
    walk(tree, &mut order);
    // `a` matches every URL `b` does: `/:x` catches `/about`, `/docs/*rest` catches `/docs/a/:b`.
    let catches = |a: &[Seg], b: &[Seg]| {
        let (a_rest, a_fixed) = split_catch_all(a);
        let (b_rest, b_fixed) = split_catch_all(b);
        let covered = |n: usize| a_fixed.iter().zip(b_fixed).take(n).all(|(x, y)| matches!(x, Seg::Dynamic(_)) || x == y);
        match a_rest {
            None => b_rest.is_none() && a_fixed.len() == b_fixed.len() && covered(a_fixed.len()),
            Some(optional) => {
                // Every URL of `b` must have enough left over for `a`'s catch-all.
                let left = b_fixed.len().checked_sub(a_fixed.len());
                let enough = match left {
                    Some(0) => optional || b_rest == Some(false),
                    Some(_) => true,
                    None => false,
                };
                enough && covered(a_fixed.len())
            }
        }
    };
    for (j, (url, file, span)) in order.iter().enumerate() {
        if let Some((first, first_file, _)) = order[..j].iter().find(|(u, ..)| u != url && catches(u, url)) {
            diags.error(
                file,
                span.as_ref(),
                format!(
                    "{} is unreachable: {first_file} ({}) comes first and matches it; move one of them into or out of its (group)",
                    resolve::pattern(url),
                    resolve::pattern(first)
                ),
            );
        }
    }
}

/// A URL without its trailing catch-all: `Some(optional)` when it has one.
fn split_catch_all(url: &[Seg]) -> (Option<bool>, &[Seg]) {
    match url.split_last() {
        Some((Seg::CatchAll(_, optional), fixed)) => (Some(*optional), fixed),
        _ => (None, url),
    }
}

/// go_router opens a tab on its first GoRoute and refuses one whose own path has
/// a `:segment` (it would need a value to build the location from). Static
/// routes sort first, so this only bites tabs made entirely of dynamic routes,
/// and a tab layout sitting on a dynamic folder with no page of its own.
fn check_tab_starts(tree: &[TreeCx], diags: &mut Diags) {
    fn first_route(routes: &[TreeCx]) -> Option<&TreeCx> {
        routes.iter().find_map(|r| {
            if r.serves.is_some() {
                return Some(r);
            }
            r.branches.iter().find_map(|b| first_route(&b.routes)).or_else(|| first_route(&r.routes))
        })
    }
    for r in tree {
        for b in &r.branches {
            // With an `initialLocation`, go_router doesn't look at the tab's first route.
            let first = first_route(&b.routes).filter(|f| f.has_params && b.initial_location.is_none());
            if let Some((url, file, span)) = first.and_then(|f| f.serves.as_ref()) {
                diags.error(
                    file,
                    span.as_ref(),
                    format!(
                        "{} is the first route of a tab, and go_router can't open a tab on a path with a `:segment` in it; \
                         put a page with a static path first in the tab, or move the tab layout below the folder that holds the segment",
                        resolve::pattern(url)
                    ),
                );
            }
            check_tab_starts(&b.routes, diags);
        }
        check_tab_starts(&r.routes, diags);
    }
}

fn provider_expr(id: usize, d: &Data) -> String {
    if d.provider { format!("_i{}.data", d.import) } else { format!("_data{id}") }
}

/// The names of a route's catch-all segments.
fn catch_alls(app: &App, r: &Route) -> Vec<String> {
    r.segs.iter().filter(|(_, f)| app.is_catch_all(*f)).map(|(n, _)| n.clone()).collect()
}

/// The keys of a `data()` function that are `List` query parameters. A list compares by
/// identity, so the provider is keyed by a `QueryList` (equal when its elements are).
/// (A catch-all is a list too, but keyed by its path: see `key_expr`.)
fn list_keys(app: &App, r: &Route, d: &Data) -> Vec<String> {
    if d.provider {
        return vec![];
    }
    let rest = catch_alls(app, r);
    app.url_params(r)
        .into_iter()
        .filter(|(n, t)| d.keys.contains(n) && t.starts_with("List<") && !rest.contains(n))
        .map(|(n, _)| n)
        .collect()
}

/// The family argument: nothing, `(v.id)`, or `((a: v.a, b: v.b))`; `QueryList(v.tags)` for
/// lists, and a catch-all as its path in one string (`restKey(v.rest)`).
fn key_expr(app: &App, r: &Route, d: &Data, prefix: &str) -> String {
    let lists = list_keys(app, r, d);
    let rest = catch_alls(app, r);
    let value = |k: &String| {
        if rest.contains(k) {
            format!("restKey({prefix}{k})")
        } else if lists.contains(k) {
            format!("QueryList({prefix}{k})")
        } else {
            format!("{prefix}{k}")
        }
    };
    match (d.keys.as_slice(), d.record) {
        ([], _) => String::new(),
        ([k], false) => format!("({})", value(k)),
        (keys, _) => {
            let fields: Vec<String> = keys.iter().map(|k| format!("{k}: {}", value(k))).collect();
            format!("(({}))", fields.join(", "))
        }
    }
}

fn typed_route(app: &App, id: usize, r: &Route) -> Option<RouteCx> {
    let name = r.name.clone()?;
    if !r.is_route() {
        return None;
    }
    let data = r.data.as_ref().map(|d| {
        let keyed = match d.keys.as_slice() {
            [] => String::new(),
            [k] if !d.record => format!(" keyed by `{k}`"),
            keys => format!(" keyed by `({})`", keys.join(", ")),
        };
        TypedDataCx {
            file: rel(r, Kind::Data),
            keyed,
            expr: provider_expr(id, d),
            verb: if d.stream { "Restarts" } else { "Re-runs" },
            key: key_expr(app, r, d, ""),
            args: keyed_params(app, r, d),
        }
    });
    Some(RouteCx {
        pattern: resolve::pattern(&r.url),
        file: rel(r, if r.page.is_some() { Kind::Page } else { Kind::Redirect }),
        name,
        fields: app
            .url_params(r)
            .into_iter()
            .map(|(name, ty)| {
                let optional_rest = matches!(r.url.last(), Some(Seg::CatchAll(n, true)) if *n == name);
                let param = if optional_rest {
                    format!("this.{name} = const []")
                } else if r.query.iter().any(|(q, _)| *q == name) {
                    if ty.starts_with("List<") { format!("this.{name} = const []") } else { format!("this.{name}") }
                } else {
                    format!("required this.{name}")
                };
                FieldCx { name, ty, param }
            })
            .collect(),
        data,
        location: with_query(r, format!("joinLocation(AppRoutes.base, {})", location(app, r))),
        location_assert: match r.url.last() {
            Some(Seg::CatchAll(n, false)) => Some(format!(
                "assert({n}.isNotEmpty, '{name}Route needs at least one part in `{n}`; the path without it isn\\'t this route')",
                name = r.name.as_deref().unwrap_or("?")
            )),
            _ => None,
        },
        extra: r.extra.as_ref().map(|e| e.ty.clone()),
    })
}

/// `, {required int id, int? page}` for the parameters `data.dart` is keyed by.
fn keyed_params(app: &App, r: &Route, d: &Data) -> String {
    let typed = app.url_params(r);
    let params: Vec<String> = d
        .keys
        .iter()
        .filter_map(|k| typed.iter().find(|(n, _)| n == k))
        .map(|(n, ty)| match (r.query.iter().any(|(q, _)| q == n), ty.starts_with("List<")) {
            (true, true) => format!("{ty} {n} = const []"),
            (true, false) => format!("{ty} {n}"),
            _ => format!("required {ty} {n}"),
        })
        .collect();
    if params.is_empty() { String::new() } else { format!(", {{{}}}", params.join(", ")) }
}

/// `withQuery(<location>, {'page': page})` when the route reads the query.
fn with_query(r: &Route, location: String) -> String {
    if r.query.is_empty() {
        return location;
    }
    let entries: Vec<String> = r.query.iter().map(|(n, _)| format!("'{n}': {n}")).collect();
    format!("withQuery({location}, {{{}}})", entries.join(", "))
}

fn params_fn(app: &App, f: ParamsFn) -> ParamsFnCx {
    let params = match f {
        ParamsFn::Route(id) => app.url_params(&app.routes[id]),
        ParamsFn::Layout(id) => {
            let r = &app.routes[id];
            let mut p = app.typed_segs(r);
            p.extend(r.layout_query.iter().cloned());
            p
        }
        ParamsFn::Guard(id) => {
            let r = &app.routes[id];
            let keys = r.guard.as_ref().map(Guard::keys).unwrap_or_default();
            let query = if r.is_route() { &r.query } else { &r.guard_query };
            let mut p = app.typed_segs(r);
            p.extend(query.iter().cloned());
            p.retain(|(n, _)| keys.contains(n));
            p
        }
    };
    let owner = match f {
        ParamsFn::Route(id) | ParamsFn::Layout(id) | ParamsFn::Guard(id) => &app.routes[id],
    };
    let catch_all = |n: &str| owner.segs.iter().any(|(m, folder)| m == n && app.is_catch_all(*folder));
    let types: Vec<String> = params.iter().map(|(n, t)| format!("{t} {n}")).collect();
    let values: Vec<String> = params
        .iter()
        .map(|(n, t)| {
            // `int` → Segment.asInt, `int?` → Query.asInt, `List<int>` → Query.asIntList,
            // a catch-all `List<String>` → Segment.asRest.
            if catch_all(n) {
                return format!("{n}: Segment.asRest(s, '{n}')");
            }
            let (reader, base, list) = match (t.strip_suffix('?'), t.strip_prefix("List<").and_then(|l| l.strip_suffix('>'))) {
                (_, Some(inner)) => ("Query", inner, "List"),
                (Some(inner), _) => ("Query", inner, ""),
                _ => ("Segment", t.as_str(), ""),
            };
            let base = match base {
                "int" => "Int",
                "double" => "Double",
                "bool" => "Bool",
                _ => "String",
            };
            format!("{n}: {reader}.as{base}{list}(s, '{n}')")
        })
        .collect();
    ParamsFnCx { name: f.name(), record: format!("({{{}}})", types.join(", ")), parse: format!("({})", values.join(", ")) }
}

/// The type a provider's family takes for a key: a catch-all as a `String`.
fn key_ty(rest: &[String], name: &str, ty: &str) -> String {
    if rest.iter().any(|q| q == name) { "String".into() } else { ty.into() }
}

/// What `data()` is called with for a key: a catch-all's path parted again.
fn key_arg(rest: &[String], name: &str, value: &str) -> String {
    if rest.iter().any(|q| q == name) { format!("restParts({value})") } else { value.into() }
}

/// The provider fespalier wraps around a `data()` function.
fn provider(app: &App, cfg: &Config, id: usize, r: &Route) -> Option<ProviderCx> {
    let d = r.data.as_ref().filter(|d| !d.provider)?;
    // A list key is a `QueryList` (see `list_keys`); `data()` still takes a `List`.
    let types: Vec<(String, String)> = app
        .url_params(r)
        .into_iter()
        .filter(|(n, _)| d.keys.contains(n))
        .map(|(n, t)| {
            let t = t.strip_prefix("List<").map_or(t.clone(), |inner| format!("QueryList<{inner}"));
            (n, t)
        })
        .collect();
    // A catch-all key is its path as one string (see `key_expr`), taken apart again for `data()`.
    let rest = catch_alls(app, r);
    let (params, args) = match (types.as_slice(), d.record) {
        ([], _) => ("Ref ref".to_string(), vec![]),
        ([(n, t)], false) => (format!("Ref ref, {} {n}", key_ty(&rest, n, t)), vec![format!("{n}: {}", key_arg(&rest, n, n))]),
        (many, _) => {
            let fields: Vec<String> = many.iter().map(|(n, t)| format!("{} {n}", key_ty(&rest, n, t))).collect();
            (
                format!("Ref ref, ({{{}}}) k", fields.join(", ")),
                many.iter().map(|(n, _)| format!("{n}: {}", key_arg(&rest, n, &format!("k.{n}")))).collect(),
            )
        }
    };
    let mut call_args = vec!["ref".to_string()];
    call_args.extend(args);
    Some(ProviderCx {
        id,
        kind: if d.stream { "StreamProvider" } else { "FutureProvider" },
        family: !d.keys.is_empty(),
        params,
        call: format!("_i{}.data({})", d.import, call_args.join(", ")),
        no_retry: cfg.data_retry == DataRetry::None,
    })
}

/// The imports that let the generated file name the types of typed `extra`s
/// (see `extra.rs`), one line per library.
fn extra_imports(app: &App, cfg: &Config) -> Vec<String> {
    use std::collections::BTreeMap;
    let dart_uri = |uri: String| uri.replace('\\', "\\\\").replace('$', "\\$").replace('\'', "\\'");
    let mut shown: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut aliased = BTreeSet::new();
    for e in app.routes.iter().filter_map(|r| r.extra.as_ref()) {
        for (_, uri, alias) in &e.aliased {
            aliased.insert(format!("import '{}' as {alias};", dart_uri(cfg.import_from_file(&e.file, uri))));
        }
        for uri in e.imports.iter().filter(|_| !e.shown.is_empty()) {
            shown.entry(dart_uri(cfg.import_from_file(&e.file, uri))).or_default().extend(e.shown.iter().cloned());
        }
    }
    let mut out: Vec<String> = shown
        .into_iter()
        .map(|(uri, names)| format!("import '{uri}' show {};", names.into_iter().collect::<Vec<_>>().join(", ")))
        .collect();
    out.extend(aliased);
    out
}

/// The route table in the header of app.g.dart; `fsp routes` prints the same rows.
pub fn table(app: &App) -> Vec<String> {
    let rows: Vec<(String, String, String)> = app
        .routes
        .iter()
        .filter(|r| r.is_route())
        .map(|r| {
            let mut tags = vec![];
            if r.redirect.is_some() {
                tags.push("redirect");
            }
            if r.data.is_some() {
                tags.push("data");
            }
            if r.guard.is_some() {
                tags.push("guard");
            }
            if r.layout.is_some() {
                tags.push("layout");
            }
            if r.transition.is_some() {
                tags.push("transition");
            }
            let tags = if tags.is_empty() { String::new() } else { format!("  ({})", tags.join(", ")) };
            let name = format!("{}Route", r.name.as_deref().unwrap_or("?"));
            (resolve::pattern(&r.url), name, format!("{}{tags}", rel(r, if r.page.is_some() { Kind::Page } else { Kind::Redirect })))
        })
        .collect();
    let w0 = rows.iter().map(|r| r.0.len()).max().unwrap_or(0);
    let w1 = rows.iter().map(|r| r.1.len()).max().unwrap_or(0);
    rows.into_iter().map(|(p, n, f)| format!("{p:w0$}  {n:w1$}  {f}")).collect()
}

pub fn rel(r: &Route, kind: Kind) -> String {
    if r.dir.is_empty() { kind.file().to_string() } else { format!("{}/{}", r.dir, kind.file()) }
}

/// A Dart string literal for the route's location, e.g. `'/products/$id'`.
fn location(app: &App, r: &Route) -> String {
    let types = app.typed_segs(r);
    let (rest, fixed) = split_catch_all(&r.url);
    let parts: Vec<String> = fixed
        .iter()
        .filter_map(|s| match s {
            Seg::Static(s) => Some(s.clone()),
            Seg::Dynamic(n) if types.iter().any(|(m, t)| m == n && t == "String") => {
                Some(format!("${{Uri.encodeComponent({n})}}"))
            }
            Seg::Dynamic(n) => Some(format!("${n}")),
            Seg::CatchAll(..) | Seg::Group(_) => None,
        })
        .collect();
    let path = parts.join("/");
    match (r.url.last(), rest) {
        // Each part encoded on its own; nothing at all for none.
        (Some(Seg::CatchAll(n, _)), _) if !path.is_empty() => format!("'/{path}${{restPath({n})}}'"),
        (Some(Seg::CatchAll(n, _)), _) => format!("'/${{restKey({n})}}'"),
        _ => format!("'/{path}'"),
    }
}
