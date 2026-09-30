//! Writes `lib/app.g.dart`: one readable, committed file that federates the
//! tree into `AppRoutes.router()` / `AppRoutes.mount(at:)` plus typed routes.
//!
//! This module works out every expression; `templates/app.g.dart.jinja` owns
//! the layout of the file.

use std::collections::BTreeSet;

use serde::Serialize;

use crate::resolve::{App, Bind, Data, Route};
use crate::scan::{Kind, Seg};
use crate::templates;

#[derive(Serialize)]
struct FileCx {
    table: Vec<String>,
    imports: Vec<String>,
    tree: Vec<TreeCx>,
    not_found: String,
    routes: Vec<RouteCx>,
    seg_fns: Vec<SegFnCx>,
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
    routes: Vec<TreeCx>,
}

/// A call that may need the route's segments parsed first.
#[derive(Serialize)]
struct CallCx {
    seg_fn: Option<String>,
    call: String,
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
}

#[derive(Serialize)]
struct TypedDataCx {
    file: String,
    keyed: String,
    expr: String,
    verb: &'static str,
    key: String,
}

#[derive(Serialize)]
struct SegFnCx {
    id: usize,
    record: String,
    parse: String,
}

#[derive(Serialize)]
struct ProviderCx {
    id: usize,
    kind: &'static str,
    family: bool,
    params: String,
    call: String,
}

pub fn emit(app: &App) -> String {
    let mut seg_fns = BTreeSet::new();
    let tree = routes_of(app, 0, true, "", &mut seg_fns);
    let cx = FileCx {
        table: table(app),
        imports: app.imports.iter().map(|rel| format!("app/{}", rel.replace('$', "\\$"))).collect(),
        tree,
        not_found: match &app.not_found {
            Some(w) => w.call(|_| "uri".into()),
            None => "DefaultNotFound(uri)".into(),
        },
        routes: app.routes.iter().enumerate().filter_map(|(id, r)| typed_route(app, id, r)).collect(),
        seg_fns: seg_fns.into_iter().map(|id| seg_fn(app, id)).collect(),
        providers: app.routes.iter().enumerate().filter_map(|(id, r)| provider(app, id, r)).collect(),
    };
    templates::render("app.g.dart", &cx)
}

/// How builder code spells each binding. `v` holds the parsed segments.
fn in_builder(b: &Bind) -> String {
    match b {
        Bind::Segment(s) => format!("v.{s}"),
        Bind::Data => "d".into(),
        Bind::Child => "child".into(),
        Bind::Error => "e".into(),
        Bind::StackTrace => "st".into(),
        Bind::Retry => "retry".into(),
        Bind::Uri => "uri".into(),
    }
}

/// RouteBase entries for a folder. Page-less folders fold their segment into
/// their children's paths; `layout.dart` wraps the result in a ShellRoute.
fn routes_of(app: &App, id: usize, top: bool, prefix: &str, seg_fns: &mut BTreeSet<usize>) -> Vec<TreeCx> {
    let r = &app.routes[id];
    let own = match &r.seg {
        None => String::new(),
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
            let routes = r.children.iter().flat_map(|&c| routes_of(app, c, false, "", seg_fns)).collect();
            let seg_fn = (!r.segs.is_empty()).then(|| {
                seg_fns.insert(id);
                format!("_seg{id}")
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
                routes,
            }]
        }
        None => {
            let next = if path.is_empty() { String::new() } else { format!("{path}/") };
            r.children.iter().flat_map(|&c| routes_of(app, c, top, &next, seg_fns)).collect()
        }
    };

    if let (Some(layout), false) = (&r.layout, out.is_empty()) {
        let seg_fn = layout.segments().next().is_some().then(|| {
            seg_fns.insert(id);
            format!("_seg{id}")
        });
        out = vec![TreeCx {
            layout: Some(CallCx { seg_fn, call: layout.call(in_builder) }),
            path: String::new(),
            redirect: None,
            seg_fn: None,
            page: String::new(),
            data: None,
            routes: out,
        }];
    }
    out
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
        pattern: pattern(app, r),
        file: rel(r, Kind::Page),
        name,
        fields: app.typed_segs(r).into_iter().map(|(name, ty)| FieldCx { name, ty }).collect(),
        data,
        location: location(app, r),
    })
}

fn seg_fn(app: &App, id: usize) -> SegFnCx {
    let segs = app.typed_segs(&app.routes[id]);
    let types: Vec<String> = segs.iter().map(|(n, t)| format!("{t} {n}")).collect();
    let values: Vec<String> = segs
        .iter()
        .map(|(n, t)| {
            let reader = match t.as_str() {
                "int" => "asInt",
                "double" => "asDouble",
                "bool" => "asBool",
                _ => "asString",
            };
            format!("{n}: Segment.{reader}(s, '{n}')")
        })
        .collect();
    SegFnCx { id, record: format!("({{{}}})", types.join(", ")), parse: format!("({})", values.join(", ")) }
}

/// The provider fespalier wraps around a `data()` function.
fn provider(app: &App, id: usize, r: &Route) -> Option<ProviderCx> {
    let d = r.data.as_ref().filter(|d| !d.provider)?;
    let types: Vec<(String, String)> =
        app.typed_segs(r).into_iter().filter(|(n, _)| d.keys.contains(n)).collect();
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
            let tags = if tags.is_empty() { String::new() } else { format!("  ({})", tags.join(", ")) };
            let name = format!("{}Route", r.name.as_deref().unwrap_or("?"));
            (pattern(app, r), name, format!("{}{tags}", rel(r, Kind::Page)))
        })
        .collect();
    let w0 = rows.iter().map(|r| r.0.len()).max().unwrap_or(0);
    let w1 = rows.iter().map(|r| r.1.len()).max().unwrap_or(0);
    rows.into_iter().map(|(p, n, f)| format!("{p:w0$}  {n:w1$}  {f}")).collect()
}

fn rel(r: &Route, kind: Kind) -> String {
    if r.dir.is_empty() { kind.file().to_string() } else { format!("{}/{}", r.dir, kind.file()) }
}

/// Segments from the root to `r`, found by walking its folder's ancestors.
fn segments(app: &App, r: &Route) -> Vec<Seg> {
    let mut segs = vec![];
    let mut dir = String::new();
    for part in r.dir.split('/').filter(|s| !s.is_empty()) {
        dir = if dir.is_empty() { part.to_string() } else { format!("{dir}/{part}") };
        if let Some(s) = app.routes.iter().find(|x| x.dir == dir).and_then(|n| n.seg.clone()) {
            segs.push(s);
        }
    }
    segs
}

fn pattern(app: &App, r: &Route) -> String {
    let parts: Vec<String> = segments(app, r)
        .into_iter()
        .map(|s| match s {
            Seg::Static(s) => s,
            Seg::Dynamic(n) => format!(":{n}"),
        })
        .collect();
    format!("/{}", parts.join("/"))
}

/// A Dart string literal for the route's location, e.g. `'/products/$id'`.
fn location(app: &App, r: &Route) -> String {
    let types = app.typed_segs(r);
    let parts: Vec<String> = segments(app, r)
        .into_iter()
        .map(|s| match s {
            Seg::Static(s) => s,
            Seg::Dynamic(n) if types.iter().any(|(m, t)| *m == n && t == "String") => {
                format!("${{Uri.encodeComponent({n})}}")
            }
            Seg::Dynamic(n) => format!("${n}"),
        })
        .collect();
    format!("'/{}'", parts.join("/"))
}
