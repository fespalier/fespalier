//! Writes the generated file (`lib/app.g.dart` by default): one readable,
//! committed file that federates the tree into `AppRoutes.router()` / `AppRoutes.mount(at:)` plus typed routes.
//!
//! This module works out every expression; `templates/app.g.dart.jinja` owns
//! the layout of the file.

use std::collections::{BTreeSet, HashMap};

use serde::Serialize;

use crate::config::{Config, DataRetry};
use crate::resolve::{self, App, Bind, Branch, Data, Guard, Route, Transition};
use crate::dart::Span;
use crate::diag::Diags;
use crate::locale::{self, Localized};
use crate::enums;
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
    /// A typed handle for each section's data.dart.
    sections: Vec<SectionCx>,
    /// How `AppRoutes.matchUrl` matches a location to a route, most specific first.
    matchers: Vec<MatcherCx>,
    params_fns: Vec<ParamsFnCx>,
    providers: Vec<ProviderCx>,
    /// The route manifest, unless `output_manifest:` moves it to its own library.
    manifest: Option<ManifestCx>,
    /// `import '...' show Product;` lines for the types of typed `extra`s.
    extra_imports: Vec<String>,
    /// `_i9.extraCodec`, from the app folder's `extra_codec.dart`: `router()` hands it to GoRouter.
    extra_codec: Option<String>,
    /// Whether the root matches paths by case: what the mount point is compared with.
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
    /// `parentNavigatorKey: rootNavigatorKey`: a page (or a shell) that goes on the root navigator.
    root: bool,
    /// Where `root` comes from, for the error when go_router can't honour it.
    #[serde(skip)]
    root_at: Option<(String, Option<Span>)>,
    /// A tab shell's `navigatorContainerBuilder`, when its layout.dart has a `container`.
    container: Option<String>,
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
    /// For a GoRoute: whether its whole path matches by case (`caseSensitive: false` when not).
    case_sensitive: bool,
    /// For a GoRoute: its own `path:` has a localized segment (`:_l0(products|produits)`).
    #[serde(skip)]
    localized: bool,
}

/// A GoRoute's URL, page file and page class, and the localized segments of the URL.
type Serves = (Vec<Seg>, String, Option<Span>, Vec<Localized>);

#[derive(Serialize)]
struct BranchCx {
    routes: Vec<TreeCx>,
    /// A Dart expression: the app location joined to the mount point.
    initial_location: Option<String>,
    preload: bool,
    /// A Dart string literal: the tab's Navigator scope, from its folder.
    restoration_id: String,
}

/// A route's path as it goes between the quotes of a Dart string literal: the `\.` that
/// keeps a dot in a localized spelling from matching any character needs its backslash doubled.
fn path_literal(path: &str) -> String {
    path.replace('\\', "\\\\")
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
    /// The nearest transition.dart builds the shell's page, under a key made from `restoration_id`.
    transition: Option<TransitionCx>,
}

/// A not_found.dart below the root: its URL prefix (`['products', ':id']`) and widget.
#[derive(Serialize)]
struct NotFoundCx {
    prefix: String,
    call: String,
    /// Whether the folder's own path matches by case.
    case_sensitive: bool,
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

/// The page hook `name` (`transition` or `present`) called for a route's page, or, with
/// `shell` holding the restoration id, for a layout's shell: which is keyed by that id, a
/// key that stays the same when the app restarts and while the routes inside the shell change.
fn transition_cx(t: &Transition, name: &str, shell: Option<&str>) -> TransitionCx {
    let value = |b: &Bind| match (b, shell) {
        (Bind::PageKey, Some(id)) => format!("const ValueKey<String>({id})"),
        (Bind::IsShell, _) => shell.is_some().to_string(),
        _ => in_builder(b),
    };
    let args = t
        .args
        .iter()
        .map(|a| TransitionArgCx {
            prefix: if a.named { format!("{}: ", a.name) } else { String::new() },
            value: (a.bind != Bind::Child).then(|| value(&a.bind)),
        })
        .collect();
    TransitionCx { call: format!("_i{}.{name}", t.import), args }
}

#[derive(Serialize)]
struct ViewDataCx {
    provider: String,
    /// A statement that invalidates it: `ref.invalidate(p)`, or through the runtime
    /// helper when `data.dart` selects a provider (see `invalidateSelected`).
    invalidate: String,
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
    /// `locationFor`: the location with the segments in a locale's spelling; only for a route
    /// with a localized segment, else the inherited `locationFor` answers with `location`.
    location_for: Option<String>,
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
    /// `data.dart` selects a provider: the typed helpers go through the runtime's
    /// `readSelected`, `prefetchSelected` and `refreshSelected`.
    selector: bool,
    key: String,
    /// `, {required int id, int? page}`: the keys as named parameters of the static
    /// `watch` and `read`, whose types are inferred from the provider.
    args: String,
}

/// One route as `AppRoutes.matchUrl` tries it.
#[derive(Serialize)]
struct MatcherCx {
    /// A Dart list of the path's parts: `['products', ':id']`.
    pattern: String,
    /// The statements that parse the URL, one per line.
    lines: Vec<String>,
    /// `ProductRoute(id: p.id)`.
    route: String,
    /// `{'id': p.id}`.
    params: String,
    /// `[_data1(l1.shop), _data3(p.id)]`: the section data, then the route's own.
    data: String,
    /// Whether the route's path matches by case (its `route.dart`, else the config).
    case_sensitive: bool,
}

/// The typed handle of a section's data.dart: `AccountSection.watch(ref, ...)`.
#[derive(Serialize)]
struct SectionCx {
    name: String,
    /// The section's folder, as a comment shows it.
    folder: String,
    file: String,
    keyed: String,
    expr: String,
    verb: &'static str,
    selector: bool,
    key: String,
    /// `{required int id}` (or nothing) and, for `prefetch`, with `keepFor`.
    args: String,
    prefetch_args: String,
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
    /// `data.dart` selects a provider: `_dataN` returns it (or is it, with no keys),
    /// and nothing is wrapped.
    selector: bool,
}

pub fn emit(app: &App, cfg: &Config, diags: &mut Diags) -> String {
    let mut fns = BTreeSet::new();
    let tree = routes_of(app, 0, true, "", &[], &mut fns);
    check_order(&tree, diags);
    check_tab_starts(&tree, diags);
    check_root_children(&tree, diags);
    // With no `output_manifest:` the manifest lives here, and imports its meta.dart files here.
    let (manifest, metas) = match cfg.output_manifest {
        None => {
            let (m, metas) = manifest::cx(app, app.imports.len());
            (Some(m), metas)
        }
        Some(_) => (None, vec![]),
    };
    let matchers = matchers(app, &mut fns);
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
        sections: sections(app, diags),
        matchers,
        params_fns: fns.into_iter().map(|f| params_fn(app, f)).collect(),
        providers: app.routes.iter().enumerate().filter_map(|(id, r)| provider(app, cfg, id, r)).collect(),
        extra_imports: extra_imports(app, cfg),
        extra_codec: app.extra_codec.as_ref().map(|c| format!("_i{}.extraCodec", c.import)),
        case_sensitive: app.routes[0].case_sensitive,
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
        Bind::IsShell => "false".into(),
        // Typed by the parameter it fills.
        Bind::Extra => "extraOf(state)".into(),
        // Only a not_found.dart takes these; `not_found_call` spells them.
        Bind::Raw(n) => format!("state.pathParameters['{n}']!"),
    }
}

/// Like [`in_builder`] for what sees the extra of routes that aren't its own: a layout, a
/// guard or a redirect. What isn't the type it asks for reads as `null`, where a page
/// (whose route the extra was passed to) asserts.
fn in_hook(b: &Bind) -> String {
    match b {
        Bind::Extra => "extraOrNull(state)".into(),
        _ => in_builder(b),
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
        // A localized segment is a parameter that matches every spelling (see `locale.rs`).
        Some(Seg::Static(s)) => match locale::at(&r.localized, r.url.len().saturating_sub(1)) {
            Some(l) => l.go_router_part(),
            None => s.clone(),
        },
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
            root: r.root,
            root_at: r.root.then(|| (rel(r, Kind::Layout), None)),
            container: None,
            dynamic: out.iter().any(|r| r.dynamic),
            catch_all: out.iter().any(|r| r.catch_all),
            serves: None,
            has_params: false,
            case_sensitive: true,
            localized: false,
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
    if let (Some((_, file, span, localized)), Some((_, parent))) = (t.serves.take(), r.url.split_last()) {
        t.serves = Some((parent.to_vec(), file, span, localized));
    }
    t
}

/// What a folder's layout builds: the layout widget, behind its section's data.dart when
/// it has one, and inside the data.dart files of the sections above it that it asks for.
fn layout_cx(app: &App, id: usize, layout: &resolve::Widget, fns: &mut BTreeSet<ParamsFn>) -> LayoutCx {
    let r = &app.routes[id];
    let section = r.data.as_ref().filter(|_| r.is_section());
    let has_params = !r.segs.is_empty() || !r.layout_query.is_empty();
    let wrapped = with_sections(app, &layout.args, layout.call(in_hook), fns, false);
    let reads_url = has_params
        && (section.is_some()
            || wrapped != layout.call(in_hook)
            || layout.args.iter().any(|a| matches!(a.bind, Bind::Segment(_) | Bind::Query(_))));
    let seg_fn = reads_url.then(|| {
        fns.insert(ParamsFn::Layout(id));
        ParamsFn::Layout(id).name()
    });
    let restoration_id = dart_str(&format!("layout:{}", folder_id(&r.dir)));
    LayoutCx {
        transition: r.shell_transition.as_ref().map(|t| transition_cx(t, "transition", Some(&restoration_id))),
        restoration_id,
        seg_fn,
        page: wrapped,
        data: section.map(|d| ViewDataCx {
            provider: format!("{}{}", provider_expr(id, d), key_expr(app, r, d, "v.")),
            invalidate: invalidate_expr(app, id, r, d),
            loading: r.loading.as_ref().map_or("const DefaultLoading()".into(), |w| w.call(in_builder)),
            error: r.error.as_ref().map_or("DefaultError(error: e, retry: retry)".into(), |w| w.call(in_builder)),
        }),
        not_found: not_found_call(r),
    }
}

/// Wraps `inner` in a `SectionView` for each section above that its widget takes data
/// from (`Bind::Section`): the section's layout has loaded it, so it's read from the
/// same provider.
fn with_sections(app: &App, args: &[resolve::Arg], inner: String, fns: &mut BTreeSet<ParamsFn>, in_page: bool) -> String {
    let mut ids: Vec<usize> = vec![];
    for a in args {
        if let Bind::Section(id) = a.bind {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    ids.into_iter().rev().fold(inner, |acc, sid| {
        let r = &app.routes[sid];
        let d = r.data.as_ref().expect("a section has data");
        // A page has the section's segments and the query parameters it is keyed by in its own
        // record. A layout below the section only has its own: it reads a query parameter
        // the section is keyed by with the section's parser, from the same URL.
        let prefix = if in_page || d.keys.iter().all(|k| r.segs.iter().any(|(s, _)| s == k)) {
            "v.".to_string()
        } else {
            fns.insert(ParamsFn::Layout(sid));
            format!("{}(state).", ParamsFn::Layout(sid).name())
        };
        format!(
            "SectionView(\n  watch: (ref) => ref.watch({}{}),\n  data: (s{sid}) => {},\n)",
            provider_expr(sid, d),
            key_expr(app, r, d, &prefix),
            acc.replace('\n', "\n  ")
        )
    })
}

/// What an unparsable segment shows: the nearest not_found.dart below the root, or the
/// root's, which `notFound` picks.
fn not_found_call(r: &Route) -> String {
    r.not_found.as_ref().map_or("notFound(state.uri)".into(), |w| {
        w.call(|b| match b {
            Bind::Raw(n) => format!("state.pathParameters['{n}']!"),
            _ => "state.uri".into(),
        })
    })
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
            // A localized segment is all its spellings, joined by `|`.
            let parts: Vec<String> = n
                .url
                .iter()
                .enumerate()
                .filter_map(|(i, s)| match s {
                    Seg::Static(s) => Some(format!("'{}'", locale::at(&n.localized, i).map_or(s.clone(), Localized::matcher_part))),
                    Seg::Dynamic(d) | Seg::CatchAll(d, _) => Some(format!("':{d}'")),
                    Seg::Group(_) => None,
                })
                .collect();
            // A segment above the file, as the URL has it: the part of the path at its position.
            let call = n.widget.call(|b| match b {
                Bind::Raw(name) => {
                    let at = n.url.iter().position(|s| matches!(s, Seg::Dynamic(d) if d == name)).unwrap_or(0);
                    format!("pathPart(uri, base, {at})")
                }
                _ => "uri".into(),
            });
            NotFoundCx { prefix: format!("[{}]", parts.join(", ")), call, case_sensitive: n.case_sensitive }
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
        _ => format!("{}: {}", a.name, in_hook(&a.bind)),
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
    let root_key = r.root && r.layout.is_none();
    let data = r.data.as_ref().map(|d| ViewDataCx {
        provider: format!("{}{}", provider_expr(id, d), key_expr(app, r, d, "v.")),
        invalidate: invalidate_expr(app, id, r, d),
        loading: r.loading.as_ref().map_or("const DefaultLoading()".into(), |w| w.call(in_builder)),
        error: r.error.as_ref().map_or("DefaultError(error: e, retry: retry)".into(), |w| w.call(in_builder)),
    });
    TreeCx {
        layout: None,
        branches: vec![],
        path: if top { format!("joinLocation(at, '/{}')", path_literal(path)) } else { format!("'{}'", path_literal(path)) },
        redirects,
        not_found_builder: false,
        seg_fn,
        page: with_sections(app, &page.args, page.call(in_builder), fns, true),
        data,
        not_found: not_found_call(r),
        transition: match &r.present {
            Some(p) => Some(transition_cx(p, "present", None)),
            None => r.transition.as_ref().map(|t| transition_cx(t, "transition", None)),
        },
        // A layout's shell is what goes on the root navigator; its pages are inside it.
        root: root_key,
        root_at: root_key.then(|| (rel(r, Kind::Page), r.page_span.clone())),
        container: None,
        routes,
        dynamic: locale::has_params(path),
        catch_all: path.contains("(.+)"),
        serves: Some((r.url.clone(), rel(r, Kind::Page), r.page_span.clone(), r.localized.clone())),
        has_params: locale::has_params(path),
        case_sensitive: r.case_sensitive,
        localized: locale::is_localized(path),
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
        path: if top { format!("joinLocation(at, '/{}')", path_literal(path)) } else { format!("'{}'", path_literal(path)) },
        redirects,
        // Only a segment that isn't a String can fail to parse.
        not_found_builder: app.typed_segs(r).iter().any(|(_, t)| t != "String" && t != "List<String>"),
        seg_fn,
        page: String::new(),
        data: None,
        not_found: not_found_call(r),
        transition: None,
        root: false,
        root_at: None,
        container: None,
        routes: vec![],
        dynamic: locale::has_params(path),
        catch_all: path.contains("(.+)"),
        serves: Some((r.url.clone(), rel(r, Kind::Redirect), r.page_span.clone(), r.localized.clone())),
        has_params: locale::has_params(path),
        case_sensitive: r.case_sensitive,
        localized: locale::is_localized(path),
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
        .map(|(i, b)| {
            let routes = match *b {
                Branch::Own => vec![page_route(app, id, top, path, false, inherited, fns)],
                Branch::Folder(c) => static_first(routes_of(app, c, top, &next, &below, fns)),
            };
            // go_router opens a tab at its first route, and can't do that for a route with a
            // path parameter, which a localized segment is: say where, in its canonical spelling.
            let own = options.get(i).and_then(|o| o.initial_location.as_ref()).map(|l| format!("joinLocation(at, {})", dart_str(l)));
            let initial_location = own.or_else(|| {
                let first = first_route(&routes).filter(|f| f.localized && !f.has_params)?;
                let (url, ..) = first.serves.as_ref()?;
                url.iter().all(|s| matches!(s, Seg::Static(_))).then(|| format!("joinLocation(at, {})", dart_str(&resolve::pattern(url))))
            });
            BranchCx {
                routes,
                initial_location,
                preload: options.get(i).is_some_and(|o| o.preload),
                restoration_id: dart_str(&format!("tab:{}{}", folder_id(&app.routes[id].dir), branch_name(app, *b))),
            }
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
        root: app.routes[id].root,
        root_at: app.routes[id].root.then(|| (rel(&app.routes[id], Kind::Layout), None)),
        container: app.routes[id].container.then(|| format!("_i{}.container", layout.import)),
        serves: None,
        has_params: false,
        case_sensitive: true,
        localized: false,
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
    let urls: Vec<Shape> = order.iter().map(|(url, _, _, localized)| (url.as_slice(), localized.as_slice())).collect();
    for (j, first) in first_catchers(&urls).into_iter().enumerate() {
        let (url, file, span, _) = order[j];
        if let Some(first) = first {
            diags.error(
                file,
                span.as_ref(),
                format!(
                    "{} is unreachable: {} ({}) comes first and matches it; move one of them into or out of its (group)",
                    resolve::pattern(url),
                    order[first].1,
                    resolve::pattern(&order[first].0)
                ),
            );
        }
    }
}

/// A route's URL and its localized segments: what decides which URLs it serves.
type Shape<'a> = (&'a [Seg], &'a [Localized]);

/// Every spelling of the static segment at `i`: a localized one has several. A segment that
/// isn't static has none.
fn alts((url, localized): Shape, i: usize) -> Vec<String> {
    match &url[i] {
        Seg::Static(s) => locale::at(localized, i).map_or(vec![s.clone()], Localized::alternatives),
        _ => vec![],
    }
}

/// The same URL, spelled the same ways: a duplicate, which the resolver reports.
fn same(a: Shape, b: Shape) -> bool {
    a.0 == b.0
        && (0..a.0.len()).all(|i| {
            let (mut x, mut y) = (alts(a, i), alts(b, i));
            x.sort();
            y.sort();
            x == y
        })
}

/// `a` matches every URL `b` does: `/:x` catches `/about`, `/docs/*rest` catches `/docs/a/:b`,
/// and `/:x/y` catches `/produits/y` whatever `produits` is a spelling of. A static segment
/// catches another only when it has every spelling the other has.
fn catches(a: Shape, b: Shape) -> bool {
    let (a_rest, a_fixed) = split_catch_all(a.0);
    let (b_rest, b_fixed) = split_catch_all(b.0);
    let covered = |n: usize| {
        a_fixed.iter().zip(b_fixed).enumerate().take(n).all(|(i, (x, y))| match (x, y) {
            (Seg::Dynamic(_), _) => true,
            (Seg::Static(_), Seg::Static(_)) => {
                let mine = alts(a, i);
                alts(b, i).iter().all(|s| mine.contains(s))
            }
            _ => x == y,
        })
    };
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
}

/// For each URL, the first URL before it, in order, that is a different one and catches it.
///
/// Trying every URL against every one before it is quadratic, and it was the slowest step of
/// `emit` on a big app (125 ms of 195 at 5,000 routes). Only a URL with a `:param` or a
/// catch-all can catch a different URL (an all-static one matches just itself, unless a segment
/// has other spellings: `c/` also spelled `a` catches `a/`), and it can
/// only catch one that starts with the same static segment or with a `:param`: so the
/// catching URLs are kept in order, under their first static segment, or in `wild` when they
/// start with a param or a catch-all. A localized first segment has several spellings, and
/// catches a URL whose own are all among them: so it is kept under each of its spellings, and a
/// URL looks under each of its own (a superset, which [`catches`] then settles). Segments are
/// compared exactly (`caseSensitive: false` isn't looked at); if that ever changes, key the
/// buckets by the lowercased segment, and keep the differential test in step.
fn first_catchers(urls: &[Shape]) -> Vec<Option<usize>> {
    let mut wild: Vec<usize> = vec![];
    let mut by_first: HashMap<String, Vec<usize>> = HashMap::new();
    let mut out = Vec::with_capacity(urls.len());
    for (j, url) in urls.iter().enumerate() {
        let hit = |ids: &[usize]| ids.iter().copied().find(|&i| !same(urls[i], *url) && catches(urls[i], *url));
        let mut best = hit(&wild);
        if matches!(url.0.first(), Some(Seg::Static(_))) {
            for spelling in alts(*url, 0) {
                if let Some(h) = by_first.get(&spelling).and_then(|ids| hit(ids)) {
                    best = best.map_or(Some(h), |b| Some(b.min(h)));
                }
            }
        }
        out.push(best);
        if !url.1.is_empty() || url.0.iter().any(|s| matches!(s, Seg::Dynamic(_) | Seg::CatchAll(..))) {
            match url.0.first() {
                Some(Seg::Static(_)) => {
                    for spelling in alts(*url, 0) {
                        by_first.entry(spelling).or_default().push(j);
                    }
                }
                _ => wild.push(j),
            }
        }
    }
    out
}

/// A URL without its trailing catch-all: `Some(optional)` when it has one.
fn split_catch_all(url: &[Seg]) -> (Option<bool>, &[Seg]) {
    match url.split_last() {
        Some((Seg::CatchAll(_, optional), fixed)) => (Some(*optional), fixed),
        _ => (None, url),
    }
}

/// The first GoRoute in `routes`, depth first: what go_router opens a tab on.
fn first_route(routes: &[TreeCx]) -> Option<&TreeCx> {
    routes.iter().find_map(|r| {
        if r.serves.is_some() {
            return Some(r);
        }
        r.branches.iter().find_map(|b| first_route(&b.routes)).or_else(|| first_route(&r.routes))
    })
}

/// go_router opens a tab on its first GoRoute and refuses one whose own path has
/// a `:segment` (it would need a value to build the location from). Static
/// routes sort first, so this only bites tabs made entirely of dynamic routes,
/// and a tab layout sitting on a dynamic folder with no page of its own.
fn check_tab_starts(tree: &[TreeCx], diags: &mut Diags) {
    for r in tree {
        for b in &r.branches {
            // With an `initialLocation`, go_router doesn't look at the tab's first route.
            let first = first_route(&b.routes).filter(|f| f.has_params && b.initial_location.is_none());
            // A localized first route gets an `initialLocation` of its own, unless a `:segment`
            // above it means the location can't be written down here.
            let unsayable = first_route(&b.routes).filter(|f| f.localized && !f.has_params && b.initial_location.is_none());
            if let Some((url, file, span, _)) = unsayable.and_then(|f| f.serves.as_ref()) {
                diags.error(
                    file,
                    span.as_ref(),
                    format!(
                        "{} is the first route of a tab, and a localized segment is a path parameter: go_router can't open a tab on it \
                         when a `:segment` sits above it (fsp would write the tab's initialLocation, but not with a value in it); \
                         put a page without `paths` first in the tab (`tabs` in layout.dart orders them), or drop the `paths`",
                        resolve::pattern(url)
                    ),
                );
            }
            if let Some((url, file, span, _)) = first.and_then(|f| f.serves.as_ref()) {
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

/// go_router puts a route on the root navigator by lifting it out of the shell that
/// would hold it, and can only do that for a route below another route: a direct child of
/// a `ShellRoute` or a tab (`StatefulShellBranch`) with a `parentNavigatorKey` of its own is
/// an assertion at startup.
fn check_root_children(tree: &[TreeCx], diags: &mut Diags) {
    fn direct(routes: &[TreeCx], holder: &str, diags: &mut Diags) {
        for r in routes {
            if let Some((file, span)) = r.root_at.as_ref().filter(|_| r.root) {
                let msg = format!(
                    "this route is on the root navigator, but it sits directly in {holder}, and go_router can't lift a direct child out of a shell (it is the first route of a tab, or one beside the others). Put it below a page.dart that stays in the layout, or move its folder out of the layout's folder"
                );
                diags.error(file, span.as_ref(), msg);
            }
        }
    }
    fn walk(tree: &[TreeCx], diags: &mut Diags) {
        for r in tree {
            if r.layout.is_some() {
                let what = if r.branches.is_empty() { "a layout" } else { "a tab layout" };
                direct(&r.routes, what, diags);
                for b in &r.branches {
                    direct(&b.routes, "a tab layout", diags);
                }
            }
            walk(&r.routes, diags);
            for b in &r.branches {
                walk(&b.routes, diags);
            }
        }
    }
    walk(tree, diags);
}

/// `ref.invalidate(<provider>)`. A selected provider is only known as a
/// `ProviderListenable`, so the runtime checks that it is one.
fn invalidate_expr(app: &App, id: usize, r: &Route, d: &Data) -> String {
    let provider = format!("{}{}", provider_expr(id, d), key_expr(app, r, d, "v."));
    format!("ref.{}({provider})", if d.selector { "invalidateSelected" } else { "invalidate" })
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
    // A selector's function takes a plain `List` too; a `QueryList` is one, and it gives
    // the app's family the value equality a list key needs.
    let rest = catch_alls(app, r);
    data_params(app, r)
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

/// ` keyed by `id``, ` keyed by `(id, q)``, or nothing.
fn keyed_label(d: &Data) -> String {
    match d.keys.as_slice() {
        [] => String::new(),
        [k] if !d.record => format!(" keyed by `{k}`"),
        keys => format!(" keyed by `({})`", keys.join(", ")),
    }
}

/// The typed handle of each section's data.dart (`AccountSection`).
fn sections(app: &App, diags: &mut Diags) -> Vec<SectionCx> {
    let mut taken: Vec<(String, String)> = vec![];
    let mut out = vec![];
    for (id, r) in app.routes.iter().enumerate().filter(|(_, r)| r.is_section()) {
        let d = r.data.as_ref().expect("a section has data");
        let stem = resolve::pascal(&r.dir);
        let stem = match stem.chars().next() {
            None => "Root".to_string(),
            Some(c) if c.is_ascii_digit() => format!("Path{stem}"),
            _ => stem,
        };
        let name = format!("{stem}Section");
        let file = rel(r, Kind::Data);
        if let Some((_, first)) = taken.iter().find(|(n, _)| *n == name) {
            let msg = format!("the section's typed handle `{name}` is already taken by {first}; (group) folders don't add to the name, so rename a folder");
            diags.error(&file, None, msg);
            continue;
        }
        taken.push((name.clone(), file.clone()));
        let mut prefetch = keyed_param_list(app, r, d);
        prefetch.push("Duration? keepFor".to_string());
        out.push(SectionCx {
            name,
            folder: if r.dir.is_empty() { "the app folder".into() } else { format!("`{}/`", r.dir) },
            file,
            keyed: keyed_label(d),
            expr: provider_expr(id, d),
            verb: if d.stream { "Restarts" } else { "Re-runs" },
            selector: d.selector,
            key: key_expr(app, r, d, ""),
            args: keyed_params(app, r, d),
            prefetch_args: format!(", {{{}}}", prefetch.join(", ")),
        });
    }
    out
}

/// How `AppRoutes.matchUrl` reads each route: its path, then what it builds from the
/// parsed URL. Most specific first (static parts, then `:params`, then catch-alls), which is
/// the order go_router tries them in.
fn matchers(app: &App, fns: &mut BTreeSet<ParamsFn>) -> Vec<MatcherCx> {
    let mut all: Vec<(Vec<u8>, MatcherCx)> = vec![];
    for (id, r) in app.routes.iter().enumerate() {
        let Some(name) = r.name.as_ref().filter(|_| r.is_route()) else { continue };
        let ranks: Vec<u8> = r
            .url
            .iter()
            .filter_map(|s| match s {
                Seg::Static(_) => Some(0),
                Seg::Dynamic(_) => Some(1),
                Seg::CatchAll(..) => Some(2),
                Seg::Group(_) => None,
            })
            .collect();
        let parts: Vec<String> = r
            .url
            .iter()
            .enumerate()
            .filter_map(|(i, s)| match s {
                Seg::Static(s) => Some(dart_str(&locale::at(&r.localized, i).map_or(s.clone(), Localized::matcher_part))),
                Seg::Dynamic(n) => Some(dart_str(&format!(":{n}"))),
                Seg::CatchAll(n, optional) => Some(dart_str(&format!("*{n}{}", if *optional { "?" } else { "" }))),
                Seg::Group(_) => None,
            })
            .collect();
        let params = app.url_params(r);
        let mut lines = vec![];
        if !params.is_empty() {
            fns.insert(ParamsFn::Route(id));
            lines.push(format!("final p = {}(s);", ParamsFn::Route(id).name()));
        }
        // The data of each section above, outermost first, then the route's own: the very
        // providers the page and its layouts watch.
        let mut data = vec![];
        for &sid in &r.sections {
            let sec = &app.routes[sid];
            let d = sec.data.as_ref().expect("a section has data");
            // The route takes the section's segments, and the query parameters it is keyed by.
            data.push(format!("{}{}", provider_expr(sid, d), key_expr(app, sec, d, "p.")));
        }
        if let Some(d) = &r.data {
            data.push(format!("{}{}", provider_expr(id, d), key_expr(app, r, d, "p.")));
        }
        let route = if params.is_empty() {
            format!("const {name}Route()")
        } else {
            let args: Vec<String> = params.iter().map(|(n, _)| format!("{n}: p.{n}")).collect();
            format!("{name}Route({})", args.join(", "))
        };
        let map: Vec<String> = params.iter().map(|(n, _)| format!("{}: p.{n}", dart_str(n))).collect();
        all.push((
            ranks,
            MatcherCx {
                pattern: format!("[{}]", parts.join(", ")),
                lines,
                route,
                params: format!("{{{}}}", map.join(", ")),
                data: format!("[{}]", data.join(", ")),
                case_sensitive: r.case_sensitive,
            },
        ));
    }
    all.sort_by(|a, b| a.0.cmp(&b.0));
    all.into_iter().map(|(_, m)| m).collect()
}

fn typed_route(app: &App, id: usize, r: &Route) -> Option<RouteCx> {
    let name = r.name.clone()?;
    if !r.is_route() {
        return None;
    }
    let data = r.data.as_ref().map(|d| {
        let keyed = keyed_label(d);
        TypedDataCx {
            file: rel(r, Kind::Data),
            keyed,
            expr: provider_expr(id, d),
            verb: if d.stream { "Restarts" } else { "Re-runs" },
            selector: d.selector,
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
        location: with_query(r, format!("joinLocation(AppRoutes.base, {})", location(app, r, false))),
        location_for: (!r.localized.is_empty())
            .then(|| with_query(r, format!("joinLocation(AppRoutes.base, {})", location(app, r, true)))),
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

/// What a route's `data.dart` can be keyed by: its segments and query parameters; for a
/// section, the segments above it and the query parameters its layout reads.
fn data_params(app: &App, r: &Route) -> Vec<(String, String)> {
    if r.is_section() {
        let mut out = app.typed_segs(r);
        out.extend(r.layout_query.iter().cloned());
        out
    } else {
        app.url_params(r)
    }
}

/// The query parameters among [`data_params`].
fn data_query(r: &Route) -> &[(String, String)] {
    if r.is_section() { &r.layout_query } else { &r.query }
}

/// The named parameters for the parameters `data.dart` is keyed by: `required int id, int? page`.
fn keyed_param_list(app: &App, r: &Route, d: &Data) -> Vec<String> {
    let typed = data_params(app, r);
    d.keys
        .iter()
        .filter_map(|k| typed.iter().find(|(n, _)| n == k))
        .map(|(n, ty)| match (data_query(r).iter().any(|(q, _)| q == n), ty.starts_with("List<")) {
            (true, true) => format!("{ty} {n} = const []"),
            (true, false) => format!("{ty} {n}"),
            _ => format!("required {ty} {n}"),
        })
        .collect()
}

/// `, {required int id, int? page}` for the parameters `data.dart` is keyed by.
fn keyed_params(app: &App, r: &Route, d: &Data) -> String {
    let params = keyed_param_list(app, r, d);
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
    // An enum is matched by the case the route's paths are.
    let case = if owner.case_sensitive { "" } else { ", caseSensitive: false" };
    let types: Vec<String> = params.iter().map(|(n, t)| format!("{t} {n}")).collect();
    let values: Vec<String> = params
        .iter()
        .map(|(n, t)| {
            // `int` → Segment.asInt, `int?` → Query.asInt, `List<int>` → Query.asIntList,
            // a catch-all `List<String>` → Segment.asRest, `List<int>` → Segment.asIntRest;
            // an enum → Segment.asEnum, Query.asEnum, Query.asEnumList, Segment.asEnumRest.
            if catch_all(n) {
                return match resolve::list_item(t) {
                    Some(item) if enums::enum_base(item).is_some() => {
                        format!("{n}: Segment.asEnumRest(s, '{n}', {item}.values{case})")
                    }
                    Some(item) if item != "String" => format!("{n}: Segment.as{}Rest(s, '{n}')", upper_first(item)),
                    _ => format!("{n}: Segment.asRest(s, '{n}')"),
                };
            }
            let (reader, base, list) = match (t.strip_suffix('?'), t.strip_prefix("List<").and_then(|l| l.strip_suffix('>'))) {
                (_, Some(inner)) => ("Query", inner, "List"),
                (Some(inner), _) => ("Query", inner, ""),
                _ => ("Segment", t.as_str(), ""),
            };
            if enums::enum_base(base).is_some() {
                return format!("{n}: {reader}.asEnum{list}(s, '{n}', {base}.values{case})");
            }
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

fn upper_first(s: &str) -> String {
    let mut c = s.chars();
    c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
}

/// The type a provider's family takes for a key: a catch-all as a `String`, a query list
/// as a `QueryList`.
fn key_ty(rest: &[String], name: &str, ty: &str) -> String {
    if rest.iter().any(|q| q == name) {
        "String".into()
    } else {
        ty.strip_prefix("List<").map_or(ty.into(), |inner| format!("QueryList<{inner}"))
    }
}

/// What `data()` is called with for a key: a catch-all's path parted again, each part read
/// as the list's type (`int.parse` for a `List<int>`: the path was built from parts that parsed).
fn key_arg(rest: &[String], name: &str, ty: &str, value: &str) -> String {
    if !rest.iter().any(|q| q == name) {
        return value.into();
    }
    match resolve::list_item(ty) {
        // The path was built from the names of the parts that parsed.
        Some(item) if enums::enum_base(item).is_some() => format!("restParts({value}).map({item}.values.byName).toList()"),
        Some(item) if item != "String" => format!("restParts({value}).map({item}.parse).toList()"),
        _ => format!("restParts({value})"),
    }
}

/// The parameters a `data()` provider is keyed by, as its `create` function takes them
/// (without the `Ref`), and the named arguments to hand on to `data()`.
///
/// A list key is a `QueryList` (see `list_keys`); `data()` still takes a `List`. A catch-all
/// key is its path as one string (see `key_expr`), taken apart again for `data()`.
fn key_params(app: &App, r: &Route, d: &Data) -> (String, Vec<String>) {
    let types: Vec<(String, String)> = data_params(app, r)
        .into_iter()
        .filter(|(n, _)| d.keys.contains(n))
        .collect();
    let rest = catch_alls(app, r);
    match (types.as_slice(), d.record) {
        ([], _) => (String::new(), vec![]),
        ([(n, t)], false) => (format!("{} {n}", key_ty(&rest, n, t)), vec![format!("{n}: {}", key_arg(&rest, n, t, n))]),
        (many, _) => {
            let fields: Vec<String> = many.iter().map(|(n, t)| format!("{} {n}", key_ty(&rest, n, t))).collect();
            (
                format!("({{{}}}) k", fields.join(", ")),
                many.iter().map(|(n, t)| format!("{n}: {}", key_arg(&rest, n, t, &format!("k.{n}")))).collect(),
            )
        }
    }
}

/// The provider fespalier wraps around a `data()` function, or for a selector the
/// function that picks the app's own provider (`_dataN(keys) => data(keys)`; just the
/// provider with no keys). Nothing of ours sits between the route and that provider.
fn provider(app: &App, cfg: &Config, id: usize, r: &Route) -> Option<ProviderCx> {
    let d = r.data.as_ref().filter(|d| !d.provider)?;
    let (keys, args) = key_params(app, r, d);
    let (params, mut call_args) = if d.selector {
        (keys, vec![])
    } else {
        (if keys.is_empty() { "Ref ref".to_string() } else { format!("Ref ref, {keys}") }, vec!["ref".to_string()])
    };
    call_args.extend(args);
    Some(ProviderCx {
        id,
        kind: if d.stream { "StreamProvider" } else { "FutureProvider" },
        family: !d.keys.is_empty(),
        params,
        call: format!("_i{}.data({})", d.import, call_args.join(", ")),
        no_retry: !d.selector && cfg.data_retry == DataRetry::None,
        selector: d.selector,
    })
}

/// The imports that let the generated file name the types of typed `extra`s and of enum
/// segments and query parameters (see `extra.rs`), one line per library.
fn extra_imports(app: &App, cfg: &Config) -> Vec<String> {
    use std::collections::BTreeMap;
    let dart_uri = |uri: String| uri.replace('\\', "\\\\").replace('$', "\\$").replace('\'', "\\'");
    let mut shown: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut aliased = BTreeSet::new();
    for e in app.routes.iter().filter_map(|r| r.extra.as_ref()).chain(&app.enum_types) {
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

/// What a route has besides its page: the tags of the route table, in `fsp routes` too.
pub fn tags(r: &Route) -> Vec<&'static str> {
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
    if r.present.is_some() {
        tags.push("present");
    } else if r.transition.is_some() {
        tags.push("transition");
    }
    if r.root && r.page.is_some() {
        tags.push("root");
    }
    tags
}

/// The route table in the header of app.g.dart; `fsp routes` prints the same rows.
pub fn table(app: &App) -> Vec<String> {
    let rows: Vec<(String, String, String, &Route)> = app
        .routes
        .iter()
        .filter(|r| r.is_route())
        .map(|r| {
            let tags = tags(r);
            let tags = if tags.is_empty() { String::new() } else { format!("  ({})", tags.join(", ")) };
            let name = format!("{}Route", r.name.as_deref().unwrap_or("?"));
            (resolve::pattern(&r.url), name, format!("{}{tags}", rel(r, if r.page.is_some() { Kind::Page } else { Kind::Redirect })), r)
        })
        .collect();
    let w0 = rows.iter().map(|r| r.0.len()).max().unwrap_or(0);
    let w1 = rows.iter().map(|r| r.1.len()).max().unwrap_or(0);
    let mut out = vec![];
    for (p, n, f, r) in rows {
        out.push(format!("{p:w0$}  {n:w1$}  {f}"));
        // A localized route lists each spelling under it: `  fr  /produits/:id`.
        let locales = locale::locales(&r.localized);
        let w = locales.iter().map(String::len).max().unwrap_or(0);
        for l in &locales {
            out.push(format!("  {l:w$}  {}", locale::pattern_in(&r.url, &r.localized, l)));
        }
    }
    out
}

pub fn rel(r: &Route, kind: Kind) -> String {
    if r.dir.is_empty() { kind.file().to_string() } else { format!("{}/{}", r.dir, kind.file()) }
}

/// A Dart string literal for the route's location, e.g. `'/products/$id'`. With `localized`,
/// each localized segment is the spelling `locationFor`'s locale asks for (`_locale`).
fn location(app: &App, r: &Route, localized: bool) -> String {
    let types = app.typed_segs(r);
    let (rest, fixed) = split_catch_all(&r.url);
    let parts: Vec<String> = fixed
        .iter()
        .enumerate()
        .filter_map(|(i, s)| match s {
            Seg::Static(s) => match locale::at(&r.localized, i).filter(|_| localized) {
                Some(l) => {
                    let map: Vec<String> = l.spellings.iter().map(|p| format!("{}: {}", dart_str(&p.locale), dart_str(&p.path))).collect();
                    Some(format!("${{localizedSegment(_locale, {}, {{{}}})}}", dart_str(s), map.join(", ")))
                }
                None => Some(s.clone()),
            },
            Seg::Dynamic(n) if types.iter().any(|(m, t)| m == n && t == "String") => {
                Some(format!("${{Uri.encodeComponent({n})}}"))
            }
            // An enum is written as its name.
            Seg::Dynamic(n) if types.iter().any(|(m, t)| m == n && enums::enum_base(t).is_some()) => Some(format!("${{{n}.name}}")),
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

#[cfg(test)]
mod order_tests {
    use super::*;
    use crate::synth::Rng;

    /// What `check_order` did before it kept the catching URLs apart: every URL against every one before it.
    fn brute(urls: &[Shape]) -> Vec<Option<usize>> {
        (0..urls.len()).map(|j| urls[..j].iter().position(|u| !same(*u, urls[j]) && catches(*u, urls[j]))).collect()
    }

    fn url(rng: &mut Rng) -> Vec<Seg> {
        let mut url: Vec<Seg> = (0..rng.below(4))
            .map(|_| match rng.below(5) {
                0 => Seg::Dynamic("x".into()),
                1 => Seg::Dynamic("y".into()),
                n => Seg::Static(["a", "b", "c"][n - 2].into()),
            })
            .collect();
        match rng.below(6) {
            0 => url.push(Seg::CatchAll("rest".into(), false)),
            1 => url.push(Seg::CatchAll("rest".into(), true)),
            _ => {}
        }
        url
    }

    /// Some of the URL's static segments get spellings: `a`, `b` and `c` are also each other and `d`, `e`.
    fn localize(rng: &mut Rng, url: &[Seg]) -> Vec<Localized> {
        url.iter()
            .enumerate()
            .filter_map(|(at, s)| match s {
                Seg::Static(canonical) if rng.below(2) == 0 => {
                    let names = ["a", "b", "c", "d", "e"];
                    let spellings = (0..1 + rng.below(3))
                        .map(|k| locale::Spelling { locale: format!("l{k}"), path: names[rng.below(5)].into(), span: Default::default() })
                        .collect();
                    Some(Localized { at, canonical: canonical.clone(), file: "route.dart".into(), spellings })
                }
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_indexed_check_finds_what_the_quadratic_one_did() {
        let mut rng = Rng::new(7);
        for _ in 0..300 {
            let owned: Vec<Vec<Seg>> = (0..rng.below(40)).map(|_| url(&mut rng)).collect();
            let urls: Vec<Shape> = owned.iter().map(|u| (u.as_slice(), &[][..])).collect();
            assert_eq!(first_catchers(&urls), brute(&urls), "{owned:?}");
        }
    }

    #[test]
    fn the_indexed_check_finds_what_the_quadratic_one_did_with_localized_segments() {
        let mut rng = Rng::new(11);
        for _ in 0..300 {
            let owned: Vec<(Vec<Seg>, Vec<Localized>)> = (0..rng.below(40))
                .map(|_| {
                    let u = url(&mut rng);
                    let l = localize(&mut rng, &u);
                    (u, l)
                })
                .collect();
            let urls: Vec<Shape> = owned.iter().map(|(u, l)| (u.as_slice(), l.as_slice())).collect();
            assert_eq!(first_catchers(&urls), brute(&urls), "{owned:?}");
        }
    }

    #[test]
    fn a_localized_static_segment_is_caught_by_a_param_and_by_a_wider_spelling_set() {
        let spelled = |canonical: &str, others: &[&str]| Localized {
            at: 0,
            canonical: canonical.into(),
            file: "route.dart".into(),
            spellings: others.iter().enumerate().map(|(k, p)| locale::Spelling { locale: format!("l{k}"), path: (*p).into(), span: Default::default() }).collect(),
        };
        let (a, b, any) = (vec![Seg::Static("a".into()), Seg::Dynamic("x".into())], vec![Seg::Static("b".into()), Seg::Dynamic("x".into())], vec![Seg::Dynamic("y".into()), Seg::Dynamic("x".into())]);
        // `a/:x` also answers `/b/:x`, so it catches `b/:x`; `b/:x` alone doesn't catch `a/:x`.
        let (la, lb, none) = (vec![spelled("a", &["b"])], vec![], vec![]);
        assert_eq!(first_catchers(&[(&a, &la), (&b, &lb)]), vec![None, Some(0)]);
        assert_eq!(first_catchers(&[(&b, &lb), (&a, &la)]), vec![None, None]);
        // A param catches it whatever the spelling.
        assert_eq!(first_catchers(&[(&any, &none), (&a, &la)]), vec![None, Some(0)]);
    }

    #[test]
    fn a_param_catches_a_later_static_path_and_not_an_earlier_one() {
        let (any, about, docs) = (
            vec![Seg::Dynamic("slug".into())],
            vec![Seg::Static("about".into())],
            vec![Seg::Static("docs".into()), Seg::CatchAll("rest".into(), false)],
        );
        let urls: Vec<Shape> = [&about, &any, &about, &docs].iter().map(|u| (u.as_slice(), &[][..])).collect();
        assert_eq!(first_catchers(&urls), vec![None, None, Some(1), None]);
    }
}
