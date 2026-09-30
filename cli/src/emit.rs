//! Writes `lib/app.g.dart`: one readable, committed file that federates the
//! tree into `AppRoutes.router()` / `AppRoutes.mount(at:)` plus typed routes.
//!
//! This module works out every expression; `templates/app.g.dart.jinja` owns
//! the layout of the file.

use std::collections::BTreeSet;

use serde::Serialize;

use crate::resolve::{self, App, Bind, Data, Route, Transition};
use crate::diag::Diags;
use crate::scan::{Kind, Seg};
use crate::templates;

#[derive(Serialize)]
struct FileCx {
    table: Vec<String>,
    imports: Vec<String>,
    tree: Vec<TreeCx>,
    not_found: String,
    routes: Vec<RouteCx>,
    params_fns: Vec<ParamsFnCx>,
    providers: Vec<ProviderCx>,
}

/// A GoRoute, or a ShellRoute when `layout` is set.
#[derive(Serialize)]
struct TreeCx {
    layout: Option<CallCx>,
    path: String,
    redirect: Option<CallCx>,
    seg_fn: Option<String>,
    page: String,
    data: Option<ViewDataCx>,
    transition: Option<TransitionCx>,
    routes: Vec<TreeCx>,
    /// Starts with a `:segment` (or, for a ShellRoute, holds a route that does).
    #[serde(skip)]
    dynamic: bool,
    /// For a GoRoute: its URL and page file, to check matching order.
    #[serde(skip)]
    serves: Option<(Vec<Seg>, String)>,
}

/// go_router takes the first route that matches, so `/about` must come
/// before `/:id`. The sort is stable: otherwise folders keep their order.
fn static_first(mut routes: Vec<TreeCx>) -> Vec<TreeCx> {
    routes.sort_by_key(|r| r.dynamic);
    routes
}

/// A call that may need the route's segments parsed first.
#[derive(Serialize)]
struct CallCx {
    seg_fn: Option<String>,
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
}

impl ParamsFn {
    fn name(self) -> String {
        match self {
            ParamsFn::Route(id) => format!("_params{id}"),
            ParamsFn::Layout(id) => format!("_layout{id}"),
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
}

pub fn emit(app: &App, diags: &mut Diags) -> String {
    let mut fns = BTreeSet::new();
    let tree = routes_of(app, 0, true, "", &mut fns);
    check_order(&tree, diags);
    let cx = FileCx {
        table: table(app),
        imports: app.imports.iter().map(|rel| format!("app/{}", rel.replace('$', "\\$"))).collect(),
        tree,
        not_found: match &app.not_found {
            Some(w) => w.call(|_| "uri".into()),
            None => "DefaultNotFound(uri)".into(),
        },
        routes: app.routes.iter().enumerate().filter_map(|(id, r)| typed_route(app, id, r)).collect(),
        params_fns: fns.into_iter().map(|f| params_fn(app, f)).collect(),
        providers: app.routes.iter().enumerate().filter_map(|(id, r)| provider(app, id, r)).collect(),
    };
    templates::render("app.g.dart", &cx)
}

/// How builder code spells each binding. `v` holds the parsed segments.
fn in_builder(b: &Bind) -> String {
    match b {
        Bind::Segment(s) | Bind::Query(s) => format!("v.{s}"),
        Bind::Data => "d".into(),
        Bind::Child => "child".into(),
        Bind::Error => "e".into(),
        Bind::StackTrace => "st".into(),
        Bind::Retry => "retry".into(),
        Bind::Uri => "uri".into(),
        Bind::PageKey => "state.pageKey".into(),
        Bind::State => "state".into(),
    }
}

/// RouteBase entries for a folder. Page-less folders fold their segment into
/// their children's paths; `layout.dart` wraps the result in a ShellRoute.
fn routes_of(app: &App, id: usize, top: bool, prefix: &str, fns: &mut BTreeSet<ParamsFn>) -> Vec<TreeCx> {
    let r = &app.routes[id];
    let own = match &r.seg {
        None | Some(Seg::Group(_)) => String::new(),
        Some(Seg::Static(s)) => s.clone(),
        Some(Seg::Dynamic(n)) => format!(":{n}"),
    };
    let path = match (prefix.is_empty(), own.is_empty()) {
        (_, true) => prefix.trim_end_matches('/').to_string(),
        (true, false) => own,
        (false, false) => format!("{prefix}{own}"),
    };

    let mut out = match &r.page {
        Some(page) => {
            let routes = static_first(r.children.iter().flat_map(|&c| routes_of(app, c, false, "", fns)).collect());
            let seg_fn = (!app.url_params(r).is_empty()).then(|| {
                fns.insert(ParamsFn::Route(id));
                ParamsFn::Route(id).name()
            });
            let redirect = r.guard.as_ref().map(|g| {
                let keys: Vec<String> = g.keys.iter().map(|k| format!("{k}: v.{k}")).collect();
                let mut args = vec!["ProviderScope.containerOf(context, listen: false)".to_string()];
                args.extend(keys);
                CallCx {
                    seg_fn: (!g.keys.is_empty()).then(|| seg_fn.clone().unwrap()),
                    call: format!("_i{}.guard({})", g.import, args.join(", ")),
                }
            });
            let data = r.data.as_ref().map(|d| ViewDataCx {
                provider: format!("{}{}", provider_expr(id, d), key_expr(d, "v.")),
                loading: r.loading.as_ref().map_or("const DefaultLoading()".into(), |w| w.call(in_builder)),
                error: r.error.as_ref().map_or("DefaultError(error: e, retry: retry)".into(), |w| w.call(in_builder)),
            });
            vec![TreeCx {
                layout: None,
                path: if top { format!("joinLocation(at, '/{path}')") } else { format!("'{path}'") },
                redirect,
                seg_fn,
                page: page.call(in_builder),
                data,
                transition: r.transition.as_ref().map(transition_cx),
                routes,
                dynamic: path.starts_with(':'),
                serves: Some((r.url.clone(), rel(r, Kind::Page))),
            }]
        }
        None => {
            let next = if path.is_empty() { String::new() } else { format!("{path}/") };
            static_first(r.children.iter().flat_map(|&c| routes_of(app, c, top, &next, fns)).collect())
        }
    };

    if let (Some(layout), false) = (&r.layout, out.is_empty()) {
        let reads_url = layout.args.iter().any(|a| matches!(a.bind, Bind::Segment(_) | Bind::Query(_)));
        let seg_fn = reads_url.then(|| {
            fns.insert(ParamsFn::Layout(id));
            ParamsFn::Layout(id).name()
        });
        out = vec![TreeCx {
            layout: Some(CallCx { seg_fn, call: layout.call(in_builder) }),
            path: String::new(),
            redirect: None,
            seg_fn: None,
            page: String::new(),
            data: None,
            transition: None,
            dynamic: out.iter().any(|r| r.dynamic),
            serves: None,
            routes: out,
        }];
    }
    out
}

/// go_router tries routes depth-first, in order, and takes the first full
/// match. Static routes are sorted first, but a ShellRoute's routes can't be
/// interleaved with its siblings', so `(group)/about` can still end up behind
/// a `/:slug` outside the group. Report any page that is always caught first.
fn check_order(tree: &[TreeCx], diags: &mut Diags) {
    fn walk<'t>(t: &'t [TreeCx], out: &mut Vec<&'t (Vec<Seg>, String)>) {
        for r in t {
            out.extend(r.serves.as_ref());
            walk(&r.routes, out);
        }
    }
    let mut order = vec![];
    walk(tree, &mut order);
    let catches = |a: &[Seg], b: &[Seg]| {
        a.len() == b.len() && a.iter().zip(b).all(|(x, y)| matches!(x, Seg::Dynamic(_)) || x == y)
    };
    for (j, (url, file)) in order.iter().enumerate() {
        if let Some((first, first_file)) = order[..j].iter().find(|(u, _)| u != url && catches(u, url)) {
            diags.error(
                file,
                None,
                format!(
                    "{} is unreachable: {first_file} ({}) comes first and matches it; move one of them into or out of its (group)",
                    resolve::pattern(url),
                    resolve::pattern(first)
                ),
            );
        }
    }
}

fn provider_expr(id: usize, d: &Data) -> String {
    if d.provider { format!("_i{}.data", d.import) } else { format!("_data{id}") }
}

/// The family argument: nothing, `(v.id)`, or `((a: v.a, b: v.b))`.
fn key_expr(d: &Data, prefix: &str) -> String {
    match (d.keys.as_slice(), d.record) {
        ([], _) => String::new(),
        ([k], false) => format!("({prefix}{k})"),
        (keys, _) => {
            let fields: Vec<String> = keys.iter().map(|k| format!("{k}: {prefix}{k}")).collect();
            format!("(({}))", fields.join(", "))
        }
    }
}

fn typed_route(app: &App, id: usize, r: &Route) -> Option<RouteCx> {
    let name = r.name.clone()?;
    r.page.as_ref()?;
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
            key: key_expr(d, ""),
        }
    });
    Some(RouteCx {
        pattern: resolve::pattern(&r.url),
        file: rel(r, Kind::Page),
        name,
        fields: app
            .url_params(r)
            .into_iter()
            .map(|(name, ty)| {
                let param = if r.query.iter().any(|(q, _)| *q == name) {
                    if ty.starts_with("List<") { format!("this.{name} = const []") } else { format!("this.{name}") }
                } else {
                    format!("required this.{name}")
                };
                FieldCx { name, ty, param }
            })
            .collect(),
        data,
        location: with_query(r, format!("joinLocation(AppRoutes.base, {})", location(app, r))),
    })
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
    };
    let types: Vec<String> = params.iter().map(|(n, t)| format!("{t} {n}")).collect();
    let values: Vec<String> = params
        .iter()
        .map(|(n, t)| {
            // `int` → Segment.asInt, `int?` → Query.asInt, `List<int>` → Query.asIntList.
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

/// The provider fespalier wraps around a `data()` function.
fn provider(app: &App, id: usize, r: &Route) -> Option<ProviderCx> {
    let d = r.data.as_ref().filter(|d| !d.provider)?;
    let types: Vec<(String, String)> =
        app.url_params(r).into_iter().filter(|(n, _)| d.keys.contains(n)).collect();
    let (params, args) = match (types.as_slice(), d.record) {
        ([], _) => ("Ref ref".to_string(), vec![]),
        ([(n, t)], false) => (format!("Ref ref, {t} {n}"), vec![format!("{n}: {n}")]),
        (many, _) => {
            let fields: Vec<String> = many.iter().map(|(n, t)| format!("{t} {n}")).collect();
            (format!("Ref ref, ({{{}}}) k", fields.join(", ")), many.iter().map(|(n, _)| format!("{n}: k.{n}")).collect())
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
    })
}

fn table(app: &App) -> Vec<String> {
    let rows: Vec<(String, String, String)> = app
        .routes
        .iter()
        .filter(|r| r.page.is_some())
        .map(|r| {
            let mut tags = vec![];
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
            (resolve::pattern(&r.url), name, format!("{}{tags}", rel(r, Kind::Page)))
        })
        .collect();
    let w0 = rows.iter().map(|r| r.0.len()).max().unwrap_or(0);
    let w1 = rows.iter().map(|r| r.1.len()).max().unwrap_or(0);
    rows.into_iter().map(|(p, n, f)| format!("{p:w0$}  {n:w1$}  {f}")).collect()
}

fn rel(r: &Route, kind: Kind) -> String {
    if r.dir.is_empty() { kind.file().to_string() } else { format!("{}/{}", r.dir, kind.file()) }
}

/// A Dart string literal for the route's location, e.g. `'/products/$id'`.
fn location(app: &App, r: &Route) -> String {
    let types = app.typed_segs(r);
    let parts: Vec<String> = r
        .url
        .iter()
        .filter_map(|s| match s {
            Seg::Static(s) => Some(s.clone()),
            Seg::Dynamic(n) if types.iter().any(|(m, t)| m == n && t == "String") => {
                Some(format!("${{Uri.encodeComponent({n})}}"))
            }
            Seg::Dynamic(n) => Some(format!("${n}")),
            Seg::Group(_) => None,
        })
        .collect();
    format!("'/{}'", parts.join("/"))
}
