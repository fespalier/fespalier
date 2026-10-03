//! The menus the `nav.dart` files describe (since 0.8.1): which folders are entries, how they
//! nest, which routes show a breadcrumb trail, what asks which guards. The result is the
//! `AppMenu` block at the end of `app.g.dart`; `package:fespalier/nav.dart` reads it at runtime.
//!
//! Without a `nav.dart` there is nothing here and the generated file has no trace of it.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

use crate::diag::Diags;
use crate::emit::dart_str;
use crate::resolve::{App, Bind, Branch, HookFirst, Route};

/// What the template needs for `AppMenu`: the roots, the breadcrumb trails of each route, and
/// the declarations (already spelled as Dart) the tree is made of.
#[derive(Serialize)]
pub struct MenuCx {
    /// The topmost entries, in menu order: `_nav0`, `_nav1`.
    pub roots: Vec<String>,
    /// The route class of each page and the entries from the top of the tree down to it.
    pub trails: Vec<TrailCx>,
    /// `const _nav1 = NavNode(...);`, one declaration each.
    pub nodes: Vec<String>,
    /// `const _within30 = <Type>[...];`
    pub withins: Vec<String>,
    /// `TypedLocation _navRoute1(Map<String, Object?> p) => ...;`
    pub routes: Vec<String>,
    /// `String _navLabel1(BuildContext context, Map<String, Object?> p) => ...;`
    pub labels: Vec<String>,
    /// `GuardResult _navGuard1(Ref ref, TypedLocation route) => ...;`
    pub guards: Vec<String>,
}

#[derive(Serialize)]
pub struct TrailCx {
    /// `OrderRoute`.
    pub route: String,
    /// `_nav0`, `_nav5`: outermost first.
    pub nodes: Vec<String>,
}

/// The menu of an app, or `None` when no folder has a (usable) `nav.dart`. A `nav.dart` in a
/// folder with no page that has none below it is left out, with a warning.
pub fn build(app: &App, diags: &mut Diags) -> Option<MenuCx> {
    if !app.routes.iter().any(|r| r.nav.is_some()) {
        return None;
    }
    let parents = parents(app);
    let mut kept: BTreeSet<usize> = (0..app.routes.len())
        .filter(|&id| app.routes[id].nav.is_some())
        .collect();
    let mut menu_parent: BTreeMap<usize, Option<usize>> = kept
        .iter()
        .map(|&id| (id, menu_parent(app, &parents, id)))
        .collect();

    // A heading holds the entries below it: with none, it is nothing. Dropping one can leave
    // the heading above it with none.
    loop {
        let empty: Vec<usize> = kept
            .iter()
            .copied()
            .filter(|&id| {
                !has_route(&app.routes[id]) && !menu_parent.values().any(|p| *p == Some(id))
            })
            .collect();
        if empty.is_empty() {
            break;
        }
        for id in empty {
            kept.remove(&id);
            menu_parent.remove(&id);
            let file = app.routes[id].nav.as_ref().map_or("", |n| n.file.as_str());
            diags.warn(
                file,
                None,
                "nav.dart in a folder with no page.dart or redirect.dart is a heading for the nav.dart files below it, and there are none; it is ignored",
            );
        }
    }
    if kept.is_empty() {
        return None;
    }

    let tabs = tab_indexes(app, &kept);
    let sort = |ids: &mut Vec<usize>| {
        ids.sort_by_key(|&id| {
            let nav = app.routes[id].nav.as_ref().map_or(0, |n| n.order);
            // The nearest tab layout the entry is a branch of: the deepest folder.
            let tab = tabs
                .get(&id)
                .and_then(|t| t.iter().max_by_key(|(dir, _)| dir.len()))
                .map_or(usize::MAX, |(_, i)| *i);
            (nav, tab, app.routes[id].dir.clone())
        });
    };
    let mut roots: Vec<usize> = kept
        .iter()
        .copied()
        .filter(|id| menu_parent[id].is_none())
        .collect();
    sort(&mut roots);
    let mut children: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for (&id, parent) in &menu_parent {
        if let Some(p) = parent {
            children.entry(*p).or_default().push(id);
        }
    }
    for list in children.values_mut() {
        sort(list);
    }

    let mut cx = MenuCx {
        roots: roots.iter().map(|&id| node_name(id)).collect(),
        trails: vec![],
        nodes: vec![],
        withins: vec![],
        routes: vec![],
        labels: vec![],
        guards: vec![],
    };
    let mut withins: BTreeMap<usize, Vec<String>> = BTreeMap::new();
    for &id in &kept {
        let r = &app.routes[id];
        let Some(nav) = r.nav.as_ref() else { continue };
        let mut fields = vec![
            format!("folder: {}", dart_str(&r.dir)),
            format!("nav: _i{}.nav", nav.import),
        ];
        if has_route(r) {
            fields.push(format!("route: _navRoute{id}"));
            cx.routes.push(route_fn(app, id, r));
        }
        if let Some(&(_, s)) = r.segs.last() {
            let dir = &app.routes[s].dir;
            withins.entry(s).or_insert_with(|| {
                app.routes
                    .iter()
                    .filter(|o| o.name.is_some() && o.is_route())
                    .filter(|o| o.dir == *dir || o.dir.starts_with(&format!("{dir}/")))
                    .map(|o| format!("{}Route", o.name.as_deref().unwrap_or_default()))
                    .collect()
            });
            fields.push(format!("within: _within{s}"));
        }
        if let Some(args) = &nav.label_args {
            fields.push(format!("label: _navLabel{id}"));
            cx.labels.push(label_fn(app, id, r, args));
        }
        if has_route(r)
            && let Some(g) = guard_fn(app, &parents, id, r)
        {
            fields.push(format!("guard: _navGuard{id}"));
            cx.guards.push(g);
        }
        if flat(r) {
            fields.push("flat: true".into());
        }
        if let Some(t) = tabs.get(&id) {
            let entries: Vec<String> = t
                .iter()
                .map(|(d, i)| format!("{}: {i}", dart_str(d)))
                .collect();
            fields.push(format!("tabs: {{{}}}", entries.join(", ")));
        }
        if let Some(kids) = children.get(&id) {
            let names: Vec<String> = kids.iter().map(|&k| node_name(k)).collect();
            fields.push(format!("children: [{}]", names.join(", ")));
        }
        let body: String = fields.iter().map(|f| format!("  {f},\n")).collect();
        cx.nodes
            .push(format!("const {} = NavNode(\n{body});", node_name(id)));
    }
    cx.withins = withins
        .iter()
        .map(|(s, types)| format!("const _within{s} = <Type>[{}];", types.join(", ")))
        .collect();

    // The entries above each page, for breadcrumbs and for what is selected.
    for (id, r) in app.routes.iter().enumerate() {
        let Some(name) = r.name.as_ref().filter(|_| r.is_route()) else {
            continue;
        };
        let nodes: Vec<String> = chain(&parents, id)
            .into_iter()
            .filter(|a| kept.contains(a))
            .map(node_name)
            .collect();
        if !nodes.is_empty() {
            cx.trails.push(TrailCx {
                route: format!("{name}Route"),
                nodes,
            });
        }
    }
    Some(cx)
}

fn node_name(id: usize) -> String {
    format!("_nav{id}")
}

/// A folder's parent folder, by route id.
fn parents(app: &App) -> Vec<Option<usize>> {
    let mut out = vec![None; app.routes.len()];
    for (id, r) in app.routes.iter().enumerate() {
        for &c in &r.children {
            out[c] = Some(id);
        }
    }
    out
}

/// The folder and the ones above it, outermost first.
fn chain(parents: &[Option<usize>], id: usize) -> Vec<usize> {
    let mut out = vec![id];
    let mut at = id;
    while let Some(p) = parents[at] {
        out.push(p);
        at = p;
    }
    out.reverse();
    out
}

/// Serves a URL of its own, so the entry has a route to go to.
fn has_route(r: &Route) -> bool {
    r.is_route() && r.name.is_some()
}

/// The app folder's entry and a tab layout's own page sit beside the entries below them
/// instead of holding them.
fn flat(r: &Route) -> bool {
    has_route(r) && (r.dir.is_empty() || (r.tabs.is_some() && r.page.is_some()))
}

/// The nearest folder above with a nav.dart that is not flat: where the entry nests. What
/// would nest in a flat one is its sibling, so it takes that one's parent.
fn menu_parent(app: &App, parents: &[Option<usize>], id: usize) -> Option<usize> {
    let mut at = parents[id];
    while let Some(a) = at {
        let r = &app.routes[a];
        if r.nav.is_some() && !flat(r) {
            return Some(a);
        }
        at = parents[a];
    }
    None
}

/// The index of each entry as a tab, by the folder of the tab layout it is a branch of.
fn tab_indexes(app: &App, kept: &BTreeSet<usize>) -> BTreeMap<usize, BTreeMap<String, usize>> {
    let mut out: BTreeMap<usize, BTreeMap<String, usize>> = BTreeMap::new();
    for (layout, l) in app.routes.iter().enumerate() {
        let Some(branches) = &l.tabs else { continue };
        for (i, b) in branches.iter().enumerate() {
            let folder = match b {
                Branch::Own => layout,
                Branch::Folder(c) => *c,
            };
            if kept.contains(&folder) {
                out.entry(folder).or_default().insert(l.dir.clone(), i);
            }
        }
    }
    out
}

/// `TypedLocation _navRoute5(Map<String, Object?> p) => OrderRoute(id: p['id'] as int);`
fn route_fn(app: &App, id: usize, r: &Route) -> String {
    let name = r.name.as_deref().unwrap_or_default();
    let segs = app.typed_segs(r);
    let call = if segs.is_empty() {
        format!("const {name}Route()")
    } else {
        let args: Vec<String> = segs
            .iter()
            .map(|(n, ty)| format!("{n}: p['{n}'] as {ty}"))
            .collect();
        format!("{name}Route({})", args.join(", "))
    };
    let head = format!("TypedLocation _navRoute{id}(Map<String, Object?> p) =>");
    fit(head, call)
}

/// `String _navLabel5(BuildContext context, Map<String, Object?> p) => _i45.label(context, ...);`
fn label_fn(app: &App, id: usize, r: &Route, args: &[String]) -> String {
    let import = r.nav.as_ref().map_or(0, |n| n.import);
    let mut call_args = vec!["context".to_string()];
    for n in args {
        let ty = r
            .segs
            .iter()
            .find(|(s, _)| s == n)
            .map_or("String", |(_, f)| app.seg_type(*f));
        call_args.push(format!("{n}: p['{n}'] as {ty}"));
    }
    let head = format!("String _navLabel{id}(BuildContext context, Map<String, Object?> p) =>");
    fit(head, format!("_i{import}.label({})", call_args.join(", ")))
}

/// The guards `go_router` runs before the route of folder `id`, which are those of its folder
/// and the ones above it, outermost first, asked for the entry's own location. `None` when
/// there are none.
fn guard_fn(app: &App, parents: &[Option<usize>], id: usize, r: &Route) -> Option<String> {
    let name = r.name.as_deref().unwrap_or_default();
    let mut reads_segment = false;
    let calls: Vec<String> = chain(parents, id)
        .into_iter()
        .filter_map(|g| {
            let folder = &app.routes[g];
            folder.guard.as_ref().map(|guard| (folder, guard))
        })
        .map(|(folder, guard)| {
            let mut args = vec![];
            match guard.first {
                HookFirst::Ref => args.push("ref".to_string()),
                HookFirst::Container => args.push("ref.container".to_string()),
                HookFirst::None => {}
            }
            for a in &guard.args {
                let value = match &a.bind {
                    Bind::Segment(n) => {
                        reads_segment = true;
                        format!("r.{n}")
                    }
                    Bind::Query(n) => {
                        // The entry's location has no query: a list is empty, the rest null.
                        let list = folder
                            .query
                            .iter()
                            .chain(&folder.guard_query)
                            .any(|(q, ty)| q == n && ty.starts_with("List<"));
                        if list { "const []" } else { "null" }.to_string()
                    }
                    Bind::Uri => "Uri.parse(route.location)".to_string(),
                    _ => "null".to_string(),
                };
                args.push(format!("{}: {value}", a.name));
            }
            format!("_i{}.guard({})", guard.import, args.join(", "))
        })
        .collect();
    let head = format!("GuardResult _navGuard{id}(Ref ref, TypedLocation route)");
    let cast = format!("  final r = route as {name}Route;\n");
    match (calls.as_slice(), reads_segment) {
        ([], _) => None,
        ([one], false) => Some(fit(format!("{head} =>"), one.clone())),
        ([one], true) => Some(format!("{head} {{\n{cast}  return {one};\n}}")),
        (many, _) => {
            let mut s = format!("{head} {{\n");
            if reads_segment {
                s.push_str(&cast);
            }
            s.push_str("  return firstRedirect([\n");
            for c in many {
                s.push_str(&format!("    () => {c},\n"));
            }
            s.push_str("  ]);\n}");
            Some(s)
        }
    }
}

/// `head expr;` on one line when it fits in 100 columns, else the expression on the next.
fn fit(head: String, expr: String) -> String {
    if head.len() + 1 + expr.len() < 100 {
        format!("{head} {expr};")
    } else {
        format!("{head}\n    {expr};")
    }
}
