//! A route that is a sibling of the page above it, not its child: `const nest = false;` in the
//! folder's route.dart, or a `(group)` that repeats a segment (#12). (The rest of the
//! generator's tests are in `tests.rs`.)

use std::fs;

use crate::config::Config;
use crate::{analyze, build, routes};

fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// Every diagnostic, errors and warnings, as `file:line message` text.
fn diags_with(cfg: &Config, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn diags(files: &[(&str, &str)]) -> Vec<String> {
    diags_with(&Config::default(), files)
}

fn code_with(cfg: &Config, files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn code(files: &[(&str, &str)]) -> String {
    code_with(&Config::default(), files)
}

/// Whether the code has each snippet, whatever its indentation.
fn has(code: &str, needles: &[&str]) {
    let flat = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let code_flat = flat(code);
    for n in needles {
        assert!(code_flat.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn lacks(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

fn at(code: &str, needle: &str) -> usize {
    code.find(needle)
        .unwrap_or_else(|| panic!("missing `{needle}` in:\n{code}"))
}

/// The `GoRoute(` that has `path: '<path>'`, up to the next one: what that route builds.
fn route_of<'c>(code: &'c str, path: &str) -> &'c str {
    let code = &code[..at(code, "static Widget notFound")];
    let from = at(code, &format!("path: {path}"));
    let rest = &code[from..];
    let len = rest[1..].find("GoRoute(").map_or(rest.len(), |n| n + 1);
    &rest[..len]
}

/// The alias (`_i3`) the generated file gives an import.
fn alias(code: &str, file: &str) -> String {
    let at = at(code, &format!("{file}' as "));
    let rest = &code[at + file.len() + "' as ".len()..];
    rest[..rest.find(';').unwrap()].to_string()
}

/// A page that is a function, taking what `params` lists (`required String id`).
fn view(params: &str) -> String {
    format!("Widget page({{{params}}}) => const SizedBox();")
}

const NEST_OFF: &str = "const nest = false;";
const GUARD: &str = "GuardResult guard(ProviderContainer c) => null;";
const GUARD_ID: &str = "GuardResult guard(ProviderContainer c, {required String id}) => null;";
const FADE: &str =
    "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";
const LAYOUT: &str = "class BoxLayout extends StatelessWidget { const BoxLayout({super.key, required this.child}); final Widget child; }";

/// Three pages: `/orders/:id`, `/orders/:id/refund` and `/orders/:id/refund/confirm`.
fn orders() -> Vec<(&'static str, String)> {
    vec![
        ("orders/$id/page.dart", view("required String id")),
        ("orders/$id/refund/page.dart", view("required String id")),
        (
            "orders/$id/refund/confirm/page.dart",
            view("required String id"),
        ),
    ]
}

fn files<'a>(
    base: &'a [(&'static str, String)],
    more: &'a [(&'a str, &'a str)],
) -> Vec<(&'a str, &'a str)> {
    let mut all: Vec<(&str, &str)> = base.iter().map(|(p, b)| (*p, b.as_str())).collect();
    all.extend_from_slice(more);
    all
}

// ---- the shape ----

#[test]
fn folders_nest_under_the_page_above_by_default() {
    let c = code(&files(&orders(), &[]));
    // `confirm` is a child of `refund`: a deep link builds `refund` below it.
    has(
        &c,
        &["path: 'refund',", "routes: [ GoRoute( path: 'confirm',"],
    );
    lacks(&c, &["'refund/confirm'", "(sibling)"]);
}

#[test]
fn nest_false_makes_the_route_a_sibling_with_a_compound_path() {
    let c = code(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", NEST_OFF)],
    ));
    // Both are children of `/orders/:id`, `refund/confirm` before or after `refund`.
    has(
        &c,
        &[
            "path: joinLocation(at, '/orders/:id'),",
            "path: 'refund/confirm',",
            "path: 'refund',",
        ],
    );
    lacks(&c, &["path: 'confirm'"]);
    // `refund` has no children left: the stack of `/orders/1/refund/confirm` is two pages.
    assert!(!route_of(&c, "'refund',").contains("routes:"), "{c}");
    // What the route is, for `fsp routes` and the header of the generated file.
    has(
        &c,
        &[
            "//   /orders/:id/refund/confirm  OrdersIdRefundConfirmRoute  orders/$id/refund/confirm/page.dart  (sibling)",
        ],
    );
    lacks(&c, &["orders/$id/refund/page.dart  (sibling)"]);
}

#[test]
fn nest_true_is_the_default_and_says_nothing() {
    let on = code(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", "const nest = true;")],
    ));
    assert_eq!(on, code(&files(&orders(), &[])));
}

#[test]
fn a_leaving_route_keeps_its_own_children_nested() {
    let c = code(&files(
        &orders(),
        &[
            ("orders/$id/refund/confirm/route.dart", NEST_OFF),
            (
                "orders/$id/refund/confirm/receipt/page.dart",
                &view("required String id"),
            ),
        ],
    ));
    has(
        &c,
        &[
            "path: 'refund/confirm',",
            "routes: [ GoRoute( path: 'receipt',",
        ],
    );
    // Below `confirm`, so a deep link to the receipt builds `/orders/1`, then `confirm`, then it.
    assert!(at(&c, "path: 'receipt'") > at(&c, "path: 'refund/confirm'"));
    lacks(&c, &["'refund/confirm/receipt'"]);
}

#[test]
fn the_route_hoists_out_of_a_folder_without_a_page_too() {
    // `refund/` has a page; `(flow)/` and `steps/` between it and `confirm` don't. The path
    // joins the static ones and not the group.
    let mut f = orders();
    f.push((
        "orders/$id/refund/(flow)/steps/pay/page.dart",
        view("required String id"),
    ));
    f.push((
        "orders/$id/refund/(flow)/steps/pay/route.dart",
        NEST_OFF.into(),
    ));
    f.retain(|(p, _)| *p != "orders/$id/refund/confirm/page.dart");
    let c = code(&files(&f, &[]));
    has(&c, &["path: 'refund/steps/pay',"]);
    lacks(&c, &["path: 'pay',"]);
}

#[test]
fn the_route_climbs_to_the_nearest_page_that_stays() {
    // `a` > `b` > `c`, each with a page: `b` and `c` both leave, so `c` is beside `b`, and
    // both are beside `a`: the parent is the nearest route that doesn't leave.
    let c = code(&[
        ("page.dart", &view("")),
        ("a/page.dart", &view("")),
        ("a/b/page.dart", &view("")),
        ("a/b/route.dart", NEST_OFF),
        ("a/b/c/page.dart", &view("")),
        ("a/b/c/route.dart", NEST_OFF),
    ]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/'),",
            "path: 'a',",
            "path: 'a/b',",
            "path: 'a/b/c',",
        ],
    );
    let (a, b, cc) = (
        at(&c, "path: 'a',"),
        at(&c, "path: 'a/b',"),
        at(&c, "path: 'a/b/c',"),
    );
    // None of them is in the `routes:` of another.
    for (path, _) in [("a", a), ("a/b", b), ("a/b/c", cc)] {
        assert!(
            !route_of(&c, &format!("'{path}',")).contains("routes:"),
            "{path}\n{c}"
        );
    }
}

#[test]
fn leaving_the_root_page_drops_the_home_page_from_the_stack() {
    // `/` is a page that everything nests under; `login` leaves it, so `/login` builds only itself.
    let c = code(&[
        ("page.dart", &view("")),
        ("products/page.dart", &view("")),
        ("login/page.dart", &view("")),
        ("login/route.dart", NEST_OFF),
    ]);
    has(
        &c,
        &["path: joinLocation(at, '/login'),", "path: 'products',"],
    );
    // Beside `/`, so at the top, where a path is joined to the mount point.
    assert!(
        !route_of(&c, "joinLocation(at, '/')").contains("'login'"),
        "{c}"
    );
}

#[test]
fn routes_that_leave_the_root_page_are_ordered_static_before_dynamic() {
    // Beside `/`, with nothing above to sort them: `$slug` is the first folder, but `login` is
    // tried before it, or `/login` would be a slug.
    let c = code(&[
        ("page.dart", &view("")),
        ("$slug/page.dart", &view("required String slug")),
        ("$slug/route.dart", NEST_OFF),
        ("login/page.dart", &view("")),
        ("login/route.dart", NEST_OFF),
    ]);
    let (login, slug) = (
        at(&c, "path: joinLocation(at, '/login')"),
        at(&c, "path: joinLocation(at, '/:slug')"),
    );
    assert!(
        at(&c, "path: joinLocation(at, '/'),") < login && login < slug,
        "{c}"
    );
}

#[test]
fn under_a_top_level_page_less_folder_the_path_is_joined_to_the_mount_point() {
    let c = code(&[
        ("shop/orders/page.dart", &view("")),
        ("shop/orders/refund/page.dart", &view("")),
        ("shop/orders/refund/route.dart", NEST_OFF),
    ]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/shop/orders'),",
            "path: joinLocation(at, '/shop/orders/refund'),",
        ],
    );
}

// ---- the `(group)` shape, which exists without a declaration ----

#[test]
fn a_group_that_repeats_a_segment_gives_the_same_shape() {
    let mut f = orders();
    f.retain(|(p, _)| *p != "orders/$id/refund/confirm/page.dart");
    f.push((
        "orders/$id/(refund-confirm)/refund/confirm/page.dart",
        view("required String id"),
    ));
    let c = code(&files(&f, &[]));
    has(&c, &["path: 'refund/confirm',", "path: 'refund',"]);
    assert!(!route_of(&c, "'refund',").contains("routes:"), "{c}");
    // Nothing marks it: it is a route like any other.
    lacks(&c, &["(sibling)"]);
}

#[test]
fn the_group_shape_and_the_declaration_make_the_same_go_router_paths() {
    let declared = code(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", NEST_OFF)],
    ));
    let mut f = orders();
    f.retain(|(p, _)| *p != "orders/$id/refund/confirm/page.dart");
    f.push((
        "orders/$id/(refund-confirm)/refund/confirm/page.dart",
        view("required String id"),
    ));
    let grouped = code(&files(&f, &[]));
    // The same GoRoutes, as many of them and with the same paths and parents; the
    // order of the two siblings is the folders' (a `(` sorts before an `r`).
    let paths = |c: &str| {
        let mount = &c[at(c, "return [")..at(c, "static Widget notFound")];
        let mut p: Vec<String> = mount
            .lines()
            .filter(|l| {
                l.trim_start().starts_with("path: ") || l.trim_start().starts_with("routes: [")
            })
            .map(|l| format!("{}{}", l.len() - l.trim_start().len(), l.trim()))
            .collect();
        p.sort();
        p
    };
    assert_eq!(paths(&declared), paths(&grouped));
}

// ---- what the route still has from the folders it skips ----

#[test]
fn a_guard_of_the_page_it_leaves_runs_for_the_route() {
    let mut f = orders();
    f.retain(|(p, _)| *p != "orders/$id/refund/confirm/page.dart");
    f.push((
        "orders/$id/refund/(flow)/confirm/page.dart",
        view("required String id"),
    ));
    let c = code(&files(
        &f,
        &[
            ("orders/$id/guard.dart", GUARD_ID),
            ("orders/$id/refund/guard.dart", GUARD_ID),
            ("orders/$id/refund/(flow)/guard.dart", GUARD),
            ("orders/$id/refund/(flow)/confirm/guard.dart", GUARD),
            ("orders/$id/refund/(flow)/confirm/route.dart", NEST_OFF),
        ],
    ));
    let refund = alias(&c, "app/orders/\\$id/refund/guard.dart");
    let flow = alias(&c, "app/orders/\\$id/refund/(flow)/guard.dart");
    let own = alias(&c, "app/orders/\\$id/refund/(flow)/confirm/guard.dart");
    let route = route_of(&c, "'refund/confirm'");
    // Parent first: the page's guard (with its `id`, parsed for it), then the page-less
    // folder's, then the route's own. `$id`'s guard is on the route above, as before.
    let order: Vec<usize> = [&refund, &flow, &own]
        .iter()
        .map(|a| at(route, &format!("{a}.guard(")))
        .collect();
    assert!(order.windows(2).all(|w| w[0] < w[1]), "{order:?}\n{route}");
    has(
        route,
        &[&format!(
            "{refund}.guard(ProviderScope.containerOf(context, listen: false), id: v.id)"
        )],
    );
    assert!(
        !route.contains(&alias(&c, "app/orders/\\$id/guard.dart")),
        "{route}"
    );
    // The page's own route keeps just its guard.
    let page = route_of(&c, "'refund',");
    assert!(!page.contains(&format!("{flow}.guard(")), "{page}");
}

#[test]
fn a_transition_of_a_skipped_folder_still_applies() {
    let c = code(&files(
        &orders(),
        &[
            ("orders/$id/refund/transition.dart", FADE),
            ("orders/$id/refund/confirm/route.dart", NEST_OFF),
        ],
    ));
    let t = alias(&c, "app/orders/\\$id/refund/transition.dart");
    has(
        route_of(&c, "'refund/confirm'"),
        &[&format!("{t}.transition(")],
    );
    has(
        &c,
        &["orders/$id/refund/confirm/page.dart  (transition, sibling)"],
    );
}

#[test]
fn the_skipped_page_and_its_data_are_not_built_or_read_for_the_route() {
    let data = "Future<String> data(Ref ref, {required String id}) async => id;";
    let refund = "Widget page({required String id, required String data}) => const SizedBox();";
    let mut f = orders();
    f.retain(|(p, _)| *p != "orders/$id/refund/page.dart");
    f.push(("orders/$id/refund/page.dart", refund.to_string()));
    let c = code(&files(
        &f,
        &[
            ("orders/$id/refund/data.dart", data),
            ("orders/$id/refund/confirm/route.dart", NEST_OFF),
        ],
    ));
    let page = alias(&c, "app/orders/\\$id/refund/page.dart");
    let confirm = route_of(&c, "'refund/confirm'");
    lacks(
        confirm,
        &[&format!("{page}."), "_data", "DataView", "SectionView"],
    );
    // The page's own route does read it.
    has(route_of(&c, "'refund',"), &[&format!("{page}.page(")]);
}

#[test]
fn the_segments_of_the_skipped_folders_are_parsed_and_typed() {
    // `$id` is an `int` for the page below it, `$step` for the one that leaves `refund`.
    let c = code(&[
        ("orders/$id/page.dart", &view("required int id")),
        ("orders/$id/refund/page.dart", &view("required int id")),
        (
            "orders/$id/refund/$step/page.dart",
            &view("required int id, required String step"),
        ),
        ("orders/$id/refund/$step/route.dart", NEST_OFF),
    ]);
    has(
        &c,
        &[
            "path: 'refund/:step',",
            "//   /orders/:id/refund/:step  OrdersIdRefundStepRoute  orders/$id/refund/$step/page.dart  (sibling)",
            "({int id, String step}) _params",
            "(id: Segment.asInt(s, 'id'), step: Segment.asString(s, 'step'))",
            "class OrdersIdRefundStepRoute",
            "joinLocation(AppRoutes.base, '/orders/$id/refund/${Uri.encodeComponent(step)}')",
        ],
    );
    // A segment that doesn't parse shows not-found, as it does for a nested route.
    has(
        route_of(&c, "'refund/:step'"),
        &["() => notFound(state.uri)"],
    );
}

#[test]
fn typed_routes_and_locations_do_not_change() {
    let nested = code(&files(&orders(), &[]));
    let sibling = code(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", NEST_OFF)],
    ));
    let typed = |c: &str, name: &str| {
        let from = at(c, &format!("class {name} "));
        let to = c[from..].find("\n}\n").unwrap();
        c[from..from + to].to_string()
    };
    assert_eq!(
        typed(&nested, "OrdersIdRefundConfirmRoute"),
        typed(&sibling, "OrdersIdRefundConfirmRoute")
    );
    has(
        &sibling,
        &["joinLocation(AppRoutes.base, '/orders/${Uri.encodeComponent(id)}/refund/confirm')"],
    );
}

#[test]
fn match_and_the_manifest_list_the_route_at_its_url() {
    let dir = project(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", NEST_OFF)],
    ));
    let (code, diags, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    has(
        &code,
        &[
            "RouteMatcher(['orders', ':id', 'refund', 'confirm'], (s) {",
            "type: OrdersIdRefundConfirmRoute,",
            "path: '/orders/:id/refund/confirm',",
            "folder: 'orders/\\$id/refund/confirm',",
        ],
    );
    // `fsp routes`: the table and the JSON mark it; no other route is.
    let table = routes::table(&app);
    assert_eq!(
        table.iter().filter(|l| l.contains("(sibling)")).count(),
        1,
        "{table:?}"
    );
    assert!(
        table[2].starts_with("/orders/:id/refund/confirm"),
        "{table:?}"
    );
    let rows: Vec<serde_json::Value> = routes::json_lines(&app, "lib/app")
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let tags: Vec<_> = rows.iter().map(|r| r["tags"].to_string()).collect();
    assert_eq!(tags, ["[]", "[]", "[\"sibling\"]"], "{rows:?}");
    assert_eq!(rows[2]["pattern"], "/orders/:id/refund/confirm");
    assert_eq!(rows[2]["folder"], "orders/$id/refund/confirm");
}

#[test]
fn a_not_found_of_the_skipped_folder_still_covers_the_route() {
    let nf = "class RefundNotFound extends StatelessWidget { const RefundNotFound({super.key, required this.uri}); final Uri uri; }";
    let c = code(&files(
        &orders(),
        &[
            ("orders/$id/refund/not_found.dart", nf),
            ("orders/$id/refund/confirm/route.dart", NEST_OFF),
        ],
    ));
    // Unknown paths below `refund` (the scope is its URL) and an unparsable segment of the route.
    has(&c, &["['orders', ':id', 'refund']"]);
    let nf = alias(&c, "app/orders/\\$id/refund/not_found.dart");
    has(
        route_of(&c, "'refund/confirm'"),
        &[&format!("{nf}.RefundNotFound(")],
    );
}

#[test]
fn a_navigator_of_the_skipped_folder_still_applies() {
    // `refund` is on the root navigator, so the route that leaves it is too.
    let c = code(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/page.dart", &view("")),
        (
            "orders/refund/navigator.dart",
            "const navigator = RouteNavigator.root;",
        ),
        ("orders/refund/confirm/page.dart", &view("")),
        ("orders/refund/confirm/route.dart", NEST_OFF),
    ]);
    has(
        route_of(&c, "'refund/confirm'"),
        &["parentNavigatorKey: rootNavigatorKey"],
    );
}

#[test]
fn a_present_of_the_leaving_folder_is_its_own() {
    let present =
        "Page<void> present(LocalKey key, Widget child) => Transitions.sheet(key, child);";
    let c = code(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/page.dart", &view("")),
        ("orders/refund/confirm/page.dart", &view("")),
        ("orders/refund/confirm/present.dart", present),
        ("orders/refund/confirm/route.dart", NEST_OFF),
    ]);
    let block = route_of(&c, "'refund/confirm'");
    has(
        block,
        &["parentNavigatorKey: rootNavigatorKey", ".present("],
    );
    lacks(route_of(&c, "'refund',"), &["rootNavigatorKey"]);
}

#[test]
fn a_root_navigator_route_that_would_be_a_direct_child_of_a_layout_is_an_error() {
    // Nested under `orders`, a route on the root navigator is fine; beside it, in the layout,
    // go_router can't lift it out of the shell.
    let f = [
        ("(shell)/layout.dart", LAYOUT),
        ("(shell)/orders/page.dart", &view("")),
        ("(shell)/orders/new/page.dart", &view("")),
        (
            "(shell)/orders/new/navigator.dart",
            "const navigator = RouteNavigator.root;",
        ),
    ];
    assert_eq!(diags(&f), Vec::<String>::new());
    let mut with = f.to_vec();
    with.push(("(shell)/orders/new/route.dart", NEST_OFF));
    let d = diags(&with);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].starts_with("✗ (shell)/orders/new/page.dart"), "{d:?}");
    assert!(
        d[0].contains("`nest = false` made it a sibling of its page"),
        "{d:?}"
    );
}

#[test]
fn a_localized_skipped_folder_is_in_the_compound_path() {
    let c = code(&files(
        &orders(),
        &[
            (
                "orders/$id/refund/route.dart",
                "const paths = {'fr': 'remboursement'};",
            ),
            (
                "orders/$id/refund/confirm/route.dart",
                "const nest = false;\nconst paths = {'fr': 'confirmer'};",
            ),
        ],
    ));
    // Each localized folder is a parameter that matches every spelling, in one path.
    has(
        &c,
        &[
            ":_l2(refund|remboursement)/:_l3(confirm|confirmer)",
            "fr /orders/:id/remboursement/confirmer",
        ],
    );
}

#[test]
fn case_sensitivity_of_the_compound_path_is_the_leaving_folders() {
    // One go_router path, one flag: the route's folder's, which inherits the skipped folder's.
    let c = code(&files(
        &orders(),
        &[
            (
                "orders/$id/refund/route.dart",
                "const caseSensitive = false;",
            ),
            ("orders/$id/refund/confirm/route.dart", NEST_OFF),
        ],
    ));
    has(route_of(&c, "'refund/confirm'"), &["caseSensitive: false"]);
    let c = code(&files(
        &orders(),
        &[
            (
                "orders/$id/refund/route.dart",
                "const caseSensitive = false;",
            ),
            (
                "orders/$id/refund/confirm/route.dart",
                "const caseSensitive = true;\nconst nest = false;",
            ),
        ],
    ));
    lacks(route_of(&c, "'refund/confirm'"), &["caseSensitive: false"]);
    has(route_of(&c, "'refund',"), &["caseSensitive: false"]);
}

// ---- a catch-all, dynamic segments and the order go_router tries routes in ----

#[test]
fn a_catch_all_can_leave_and_goes_after_the_static_routes() {
    let c = code(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/page.dart", &view("")),
        ("orders/refund/confirm/page.dart", &view("")),
        (
            "orders/refund/$$rest/page.dart",
            &view("required List<String> rest"),
        ),
        ("orders/refund/$$rest/route.dart", NEST_OFF),
    ]);
    has(&c, &["path: 'refund/:rest(.+)',"]);
    let last = at(&c, "path: 'refund/:rest(.+)'");
    assert!(
        last > at(&c, "path: 'refund',") && last > at(&c, "path: 'confirm'"),
        "{c}"
    );
}

#[test]
fn a_catch_all_cannot_have_children_whether_or_not_it_leaves() {
    let d = diags(&[
        ("orders/page.dart", &view("")),
        (
            "orders/$$rest/page.dart",
            &view("required List<String> rest"),
        ),
        ("orders/$$rest/route.dart", NEST_OFF),
        (
            "orders/$$rest/x/page.dart",
            &view("required List<String> rest"),
        ),
    ]);
    assert!(
        d[0].starts_with("✗ orders/$$rest  a catch-all matches the rest of the path"),
        "{d:?}"
    );
}

#[test]
fn a_static_route_that_leaves_is_tried_before_the_dynamic_children_of_its_sibling() {
    // Nested, `confirm` would come before `$step`. Beside `refund`, it must come before the
    // page that holds `$step`, or `/refund/confirm` is a step and the route is unreachable.
    let c = code(&files(
        &orders(),
        &[
            (
                "orders/$id/refund/$step/page.dart",
                &view("required String id, required String step"),
            ),
            ("orders/$id/refund/confirm/route.dart", NEST_OFF),
        ],
    ));
    let (confirm, refund) = (at(&c, "path: 'refund/confirm'"), at(&c, "path: 'refund',"));
    assert!(confirm < refund, "{c}");
    has(&c, &["path: ':step',"]);
}

#[test]
fn a_static_route_that_leaves_stays_after_its_page_when_nothing_below_matches_it() {
    // Which keeps a tab that opens on `refund` opening on it.
    let c = code(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", NEST_OFF)],
    ));
    assert!(
        at(&c, "path: 'refund',") < at(&c, "path: 'refund/confirm'"),
        "{c}"
    );
}

#[test]
fn a_dynamic_route_that_leaves_is_after_the_static_ones() {
    let c = code(&files(
        &orders(),
        &[
            (
                "orders/$id/refund/$step/page.dart",
                &view("required String id, required String step"),
            ),
            ("orders/$id/refund/$step/route.dart", NEST_OFF),
        ],
    ));
    // `refund`, which has `confirm` below it, then `refund/:step`.
    let (page, step) = (at(&c, "path: 'refund',"), at(&c, "path: 'refund/:step'"));
    assert!(page < step, "{c}");
    assert!(at(&c, "path: 'confirm'") < step, "{c}");
}

#[test]
fn a_leaving_route_that_the_page_below_catches_first_is_reported() {
    // `refund/$$rest` is nested in `refund` and takes everything; `refund/:step` beside it
    // can only come after `refund`, so it is never reached.
    let d = diags(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/page.dart", &view("")),
        (
            "orders/refund/$$rest/page.dart",
            &view("required List<String> rest"),
        ),
        (
            "orders/refund/$step/page.dart",
            &view("required String step"),
        ),
        ("orders/refund/$step/route.dart", NEST_OFF),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].contains("/orders/refund/:step is unreachable"),
        "{d:?}"
    );
}

// ---- layouts ----

#[test]
fn a_layout_in_a_skipped_folder_is_an_error_with_a_code_frame() {
    let d = diags(&files(
        &orders(),
        &[
            ("orders/$id/refund/layout.dart", LAYOUT),
            (
                "orders/$id/refund/confirm/route.dart",
                "// the layout would be left behind\nconst nest = false;",
            ),
        ],
    ));
    assert_eq!(d.len(), 1, "{d:?}");
    // On the declaration, so the frame points at it.
    assert!(
        d[0].starts_with("✗ orders/$id/refund/confirm/route.dart:2  `nest = false`"),
        "{d:?}"
    );
    assert!(d[0].contains("orders/$id/refund/layout.dart"), "{d:?}");
    assert!(d[0].contains("escape that layout's shell"), "{d:?}");
}

#[test]
fn a_layout_in_a_page_less_folder_between_is_an_error_too() {
    let d = diags(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/page.dart", &view("")),
        ("orders/refund/(flow)/layout.dart", LAYOUT),
        ("orders/refund/(flow)/confirm/page.dart", &view("")),
        ("orders/refund/(flow)/confirm/route.dart", NEST_OFF),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].contains("orders/refund/(flow)/layout.dart"), "{d:?}");
}

#[test]
fn layouts_above_the_page_and_the_leaving_folders_own_are_fine() {
    // The page's frame is inside the shell, and so is a route beside it; the route's own
    // layout wraps it and what is below it.
    let c = code(&[
        ("(shell)/layout.dart", LAYOUT),
        ("(shell)/orders/page.dart", &view("")),
        ("(shell)/orders/refund/page.dart", &view("")),
        ("(shell)/orders/refund/confirm/layout.dart", LAYOUT),
        ("(shell)/orders/refund/confirm/page.dart", &view("")),
        ("(shell)/orders/refund/confirm/route.dart", NEST_OFF),
        ("(shell)/orders/refund/confirm/receipt/page.dart", &view("")),
    ]);
    // `/orders` > shell of `(shell)` > ... : the compound route is inside the first shell,
    // and holds the second one.
    let first = at(&c, "BoxLayout");
    assert!(first < at(&c, "path: 'refund/confirm'"), "{c}");
    has(&c, &["path: 'refund/confirm',"]);
    let own = c.matches("ShellRoute(").count();
    assert_eq!(own, 2, "{c}");
}

// ---- the errors ----

#[test]
fn nest_false_without_a_page_above_is_an_error() {
    let d = diags(&[
        ("orders/$id/page.dart", &view("required String id")),
        ("orders/$id/route.dart", NEST_OFF),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].starts_with(
            "✗ orders/$id/route.dart:1  `nest = false` takes this route out of the page above it"
        ),
        "{d:?}"
    );
    assert!(d[0].contains("no page.dart above"), "{d:?}");
    // A page above that is further up counts: only folders between are skipped.
    let ok = diags(&[
        ("page.dart", &view("")),
        ("orders/page.dart", &view("")),
        ("orders/route.dart", NEST_OFF),
    ]);
    assert!(ok.is_empty(), "{ok:?}");
}

#[test]
fn nest_false_on_the_app_root_is_an_error() {
    let d = diags(&[("page.dart", &view("")), ("route.dart", NEST_OFF)]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].starts_with("✗ route.dart:1  `nest = false` takes a route out of the page above"),
        "{d:?}"
    );
    assert!(
        d[0].contains("the app folder has nothing above it"),
        "{d:?}"
    );
}

#[test]
fn nest_false_in_a_group_is_an_error_that_names_the_group_shape() {
    let d = diags(&[
        ("orders/page.dart", &view("")),
        ("orders/(extras)/route.dart", NEST_OFF),
        ("orders/(extras)/refund/page.dart", &view("")),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].starts_with("✗ orders/(extras)/route.dart:1"), "{d:?}");
    assert!(d[0].contains("a `(group)` has none"), "{d:?}");
    assert!(d[0].contains("(group)/refund/confirm/page.dart"), "{d:?}");
}

#[test]
fn nest_false_in_a_folder_without_a_route_of_its_own_is_an_error() {
    let d = diags(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/route.dart", NEST_OFF),
        ("orders/refund/confirm/page.dart", &view("")),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].contains("has no page.dart or redirect.dart"), "{d:?}");
}

#[test]
fn nest_must_be_a_bool_literal_and_declared_once() {
    for body in [
        "const nest = maybe;",
        "const nest = 'no';",
        "const nest = !true;",
        "const nest = flag;",
    ] {
        let d = diags(&files(
            &orders(),
            &[("orders/$id/refund/confirm/route.dart", body)],
        ));
        assert_eq!(d.len(), 1, "{body}: {d:?}");
        assert!(d[0].starts_with("✗ orders/$id/refund/confirm/route.dart:1  `nest` must be a `true` or `false` literal"), "{body}: {d:?}");
    }
    let d = diags(&files(
        &orders(),
        &[(
            "orders/$id/refund/confirm/route.dart",
            "const nest = false;\nconst nest = false;",
        )],
    ));
    assert_eq!(
        d,
        ["✗ orders/$id/refund/confirm/route.dart:2  `nest` is declared twice"]
    );
}

#[test]
fn a_route_dart_with_only_nest_is_fine_and_a_bad_one_leaves_the_route_nested() {
    let ok = diags(&files(
        &orders(),
        &[("orders/$id/refund/confirm/route.dart", NEST_OFF)],
    ));
    assert!(ok.is_empty(), "{ok:?}");
    // The error stops the generator anyway; the route stays where the folders put it.
    let dir = project(&files(
        &orders(),
        &[(
            "orders/$id/refund/confirm/route.dart",
            "const nest = maybe;",
        )],
    ));
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.has_errors());
    assert!(code.contains("path: 'confirm'"), "{code}");
}

#[test]
fn the_other_two_settings_of_route_dart_work_beside_nest() {
    let c = code(&files(
        &orders(),
        &[(
            "orders/$id/refund/confirm/route.dart",
            "const nest = false;\nconst caseSensitive = false;",
        )],
    ));
    has(route_of(&c, "'refund/confirm'"), &["caseSensitive: false"]);
}

// ---- other kinds of route ----

#[test]
fn a_redirect_route_can_leave_too() {
    let c = code(&[
        ("orders/page.dart", &view("")),
        ("orders/refund/page.dart", &view("")),
        (
            "orders/refund/old/redirect.dart",
            "String redirect() => '/orders';",
        ),
        ("orders/refund/old/route.dart", NEST_OFF),
    ]);
    has(
        &c,
        &[
            "path: 'refund/old',",
            "orders/refund/old/redirect.dart  (redirect, sibling)",
        ],
    );
    assert!(!route_of(&c, "'refund',").contains("routes:"), "{c}");
}

#[test]
fn a_tab_keeps_the_route_in_its_branch_and_opens_on_its_page() {
    let tabs = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";
    let c = code(&[
        ("(tabs)/layout.dart", tabs),
        ("(tabs)/orders/page.dart", &view("")),
        ("(tabs)/orders/refund/page.dart", &view("")),
        ("(tabs)/orders/refund/route.dart", NEST_OFF),
        ("(tabs)/search/page.dart", &view("")),
    ]);
    // Both are in the `orders` branch, the page first: that is what the tab opens on.
    let (page, sibling, search) = (
        at(&c, "path: joinLocation(at, '/orders')"),
        at(&c, "path: joinLocation(at, '/orders/refund')"),
        at(&c, "path: joinLocation(at, '/search')"),
    );
    assert!(page < sibling && sibling < search, "{c}");
    assert_eq!(c.matches("StatefulShellBranch(").count(), 2, "{c}");
    assert!(
        !route_of(&c, "joinLocation(at, '/orders')").contains("routes:"),
        "{c}"
    );
}

#[test]
fn the_route_still_has_the_data_of_the_sections_above_it() {
    let layout = "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.team, required this.child}); final String team; final Widget child; }";
    let data = "Future<String> data(Ref ref, {required String teamId}) async => teamId;";
    let page = "Widget page({required String team}) => const SizedBox();";
    let dir = project(&[
        ("teams/$teamId/layout.dart", layout),
        ("teams/$teamId/data.dart", data),
        ("teams/$teamId/members/page.dart", page),
        ("teams/$teamId/members/invite/page.dart", page),
        ("teams/$teamId/members/invite/route.dart", NEST_OFF),
    ]);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    // The matcher (`AppRoutes.match`, `dataAt`) lists the section's provider for it, like for any
    // route below the section.
    let from = at(
        &code,
        "RouteMatcher(['teams', ':teamId', 'members', 'invite']",
    );
    let matcher = &code[from..from + 400];
    assert!(matcher.contains("_data"), "{matcher}");
    has(
        &code,
        &["path: joinLocation(at, '/teams/:teamId/members/invite'),"],
    );
}
