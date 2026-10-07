//! `leave.dart` (since 0.11.0): `LeaveResult leave(BuildContext context, Ref ref, {...})`, asked
//! before the folder's page goes. The generator binds its parameters like a guard's, emits it as
//! the `onExit` of the folder's `GoRoute`, and wraps the page in `leaveScope`.

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

fn diags(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags.0.iter().map(ToString::to_string).collect()
}

fn code(files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

/// The code with every run of whitespace a single space, so indentation doesn't matter.
fn flat(code: &str) -> String {
    code.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn has(code: &str, needles: &[&str]) {
    let flat_code = flat(code);
    for n in needles {
        assert!(flat_code.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }".into()
}

const IMPORT: &str =
    "import 'package:fespalier/fespalier.dart';\nimport 'package:flutter/widgets.dart';\n";

fn leave(body: &str) -> String {
    format!("{IMPORT}{body}")
}

// ---- the emitted route ----

#[test]
fn a_leave_is_the_on_exit_of_its_route_and_wraps_its_page() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        (
            "items/$id/leave.dart",
            &leave(
                "LeaveResult leave(BuildContext context, Ref ref, {required int id, required PageLeave page}) => true;",
            ),
        ),
    ]);
    has(
        &c,
        &[
            "GoRoute( path: 'items/:id',",
            "onExit: (context, state) => leaveExit(context, state, 'items/\\$id/leave.dart', (ref, page) => leaveWithParams(() => _leave2(state), (v) => _i2.leave(context, ref, id: v.id, page: page))),",
            "builder: (context, state) => buildWithParams(",
            "(v) => leaveScope(state, _i1.ItemPage(id: v.id)),",
            "({int id}) _leave2(GoRouterState s) => (id: Segment.asInt(s, 'id'));",
        ],
    );
    // The home page has no leave.dart, so it is built as before.
    assert_eq!(c.matches("leaveExit(").count(), 1, "{c}");
    assert_eq!(c.matches("leaveScope(").count(), 1, "{c}");
    // Only the page that parsed is wrapped: not-found is not a page that asks.
    assert!(flat(&c).contains("() => notFound(state.uri), )"), "{c}");
    assert!(
        !flat(&c).contains("leaveScope(state, buildWithParams"),
        "{c}"
    );
}

#[test]
fn a_leave_that_reads_no_url_needs_no_parser() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave({required PageLeave page}) => !page.isDirty;"),
        ),
    ]);
    has(
        &c,
        &[
            "onExit: (context, state) => leaveExit(context, state, 'leave.dart', (ref, page) => _i1.leave(page: page)),",
        ],
    );
    assert!(!c.contains("_leave0"), "{c}");
}

#[test]
fn context_and_ref_are_each_optional_and_in_that_order() {
    for (params, call) in [
        ("", "_i1.leave(page: page)"),
        ("BuildContext context, ", "_i1.leave(context, page: page)"),
        ("Ref ref, ", "_i1.leave(ref, page: page)"),
        (
            "BuildContext context, Ref ref, ",
            "_i1.leave(context, ref, page: page)",
        ),
    ] {
        let c = code(&[
            ("page.dart", &page("Home")),
            (
                "leave.dart",
                &leave(&format!(
                    "bool leave({params}{{required PageLeave page}}) => true;"
                )),
            ),
        ]);
        has(&c, &[&format!("(ref, page) => {call}),")]);
    }
}

#[test]
fn a_leave_binds_segments_above_its_folder_query_uri_and_extra() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("orders/$orderId/page.dart", &page("Order")),
        ("orders/$orderId/edit/page.dart", &page("Edit")),
        (
            "orders/$orderId/edit/leave.dart",
            &leave(
                "LeaveResult leave(BuildContext context, {required int orderId, String? tab, Uri? uri, Object? extra, required PageLeave page}) => true;",
            ),
        ),
    ]);
    has(
        &c,
        &[
            "(ref, page) => leaveWithParams(() => _leave",
            "_i3.leave(context, orderId: v.orderId, tab: v.tab, uri: state.uri, extra: extraOrNull(state), page: page)",
            "Segment.asInt(s, 'orderId')",
            "Query.asString(s, 'tab')",
        ],
    );
}

#[test]
fn a_leave_is_not_inherited_by_the_pages_below() {
    let c = code(&[
        ("orders/$id/page.dart", &item()),
        (
            "orders/$id/leave.dart",
            &leave("LeaveResult leave({required PageLeave page}) => true;"),
        ),
        ("orders/$id/edit/page.dart", &page("Edit")),
    ]);
    assert_eq!(c.matches("leaveExit(").count(), 1, "{c}");
    assert_eq!(c.matches("leaveScope(").count(), 1, "{c}");
}

#[test]
fn leave_is_asked_by_a_page_that_is_deferred_too_and_never_imported_deferred() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("heavy/page.dart", &page("Heavy")),
        ("heavy/route.dart", "const deferred = true;\n"),
        (
            "heavy/leave.dart",
            &leave("LeaveResult leave({required PageLeave page}) => true;"),
        ),
    ]);
    assert!(c.contains("heavy/leave.dart"), "{c}");
    assert!(
        c.contains("leaveScope(state, DeferredView("),
        "{}",
        flat(&c)
    );
    assert!(
        c.contains("import 'app/heavy/leave.dart' as _i")
            || c.contains("import 'app/heavy/leave.dart' as _i"),
        "{c}"
    );
    assert!(!c.contains("app/heavy/leave.dart' deferred"), "{c}");
    assert!(c.contains("app/heavy/page.dart' deferred as"), "{c}");
}

#[test]
fn leave_wraps_inside_a_transition_and_a_remount() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        (
            "items/$id/route.dart",
            "const remount = Remount.onLocation;\n",
        ),
        (
            "items/$id/leave.dart",
            &leave("LeaveResult leave({required PageLeave page}) => true;"),
        ),
    ]);
    // The wrapper is innermost: remountPage holds the page, the page holds leaveScope.
    has(
        &c,
        &["remountPage( context, state, remountKey(state, Remount.onLocation), buildWithParams("],
    );
}

#[test]
fn a_tab_layouts_own_page_and_the_pages_in_its_tabs_can_each_have_one() {
    let c = code(&[
        (
            "(tabs)/layout.dart",
            "import 'package:flutter/widgets.dart';\nimport 'package:fespalier/fespalier.dart';\nclass TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; @override Widget build(BuildContext context) => navigationShell; }",
        ),
        ("(tabs)/home/page.dart", &page("Home")),
        (
            "(tabs)/home/leave.dart",
            &leave("LeaveResult leave({required PageLeave page}) => true;"),
        ),
        ("(tabs)/more/page.dart", &page("More")),
    ]);
    assert_eq!(c.matches("leaveExit(").count(), 1, "{c}");
    has(
        &c,
        &[
            "onExit: (context, state) => leaveExit(context, state, '(tabs)/home/leave.dart', (ref, page) => _i2.leave(page: page)),",
            "builder: (context, state) => leaveScope(state, const _i1.HomePage()),",
        ],
    );
}

// ---- the route table ----

#[test]
fn the_routes_say_which_pages_are_asked() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        (
            "items/$id/leave.dart",
            &leave("LeaveResult leave({required int id, required PageLeave page}) => true;"),
        ),
    ]);
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let rows = routes::table(&app);
    assert!(
        rows.iter()
            .any(|r| r.contains("items/$id/page.dart  (leave)")),
        "{rows:?}"
    );
    let json = routes::json_lines(&app, "lib/app");
    let tagged: Vec<&String> = json.iter().filter(|l| l.contains("\"leave\"")).collect();
    assert_eq!(tagged.len(), 1, "{json:?}");
    assert!(
        tagged[0].contains("\"pattern\":\"/items/:id\""),
        "{tagged:?}"
    );
}

#[test]
fn the_graph_marks_a_page_that_asks() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave({required PageLeave page}) => true;"),
        ),
    ]);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let json = crate::graph::render(&app, &Config::default(), crate::graph::Format::Json);
    assert!(json.contains("\"leave\""), "{json}");
}

#[test]
fn an_app_without_a_leave_file_emits_nothing_of_it() {
    let c = code(&[("page.dart", &page("Home"))]);
    assert!(!c.contains("leaveScope"), "{c}");
    assert!(!c.contains("leaveExit"), "{c}");
    assert!(!c.contains("onExit"), "{c}");
}

// ---- diagnostics ----

#[test]
fn l1_a_file_without_leave_is_an_error() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("leave.dart", &leave("bool helper() => true;")),
    ]);
    assert_eq!(
        d,
        [
            "✗ leave.dart  expected `LeaveResult leave(BuildContext context, Ref ref, {...})`: true lets the page go, false keeps it"
        ]
    );
}

#[test]
fn l2_leave_returns_a_leave_result() {
    for body in [
        "void leave() {}",
        "String leave() => '';",
        "Future<void> leave() async {}",
        "leave() => true;",
    ] {
        let d = diags(&[("page.dart", &page("Home")), ("leave.dart", &leave(body))]);
        assert!(
            d.len() == 1
                && d[0].starts_with("✗ leave.dart:3  ")
                && d[0].ends_with(
                    "leave() must return `LeaveResult` (`FutureOr<bool>`): true lets the page go, false keeps it"
                ),
            "{body}: {d:?}"
        );
    }
}

#[test]
fn the_four_return_types_are_accepted() {
    for body in [
        "LeaveResult leave() => true;",
        "FutureOr<bool> leave() => true;",
        "Future<bool> leave() async => true;",
        "bool leave() => true;",
    ] {
        let d = diags(&[("page.dart", &page("Home")), ("leave.dart", &leave(body))]);
        assert!(d.is_empty(), "{body}: {d:?}");
    }
}

#[test]
fn l3_a_folder_without_a_page_has_nothing_to_ask() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("orders/leave.dart", &leave("LeaveResult leave() => true;")),
        ("orders/$id/page.dart", &item()),
    ]);
    assert_eq!(
        d,
        [
            "✗ orders/leave.dart  leave.dart is asked before this folder's page goes, and this folder has no page.dart (a layout's shell has no onExit in go_router: put a leave.dart beside each page that needs one)"
        ]
    );
}

#[test]
fn l4_a_redirect_route_never_stays_on_screen() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("old/redirect.dart", "String redirect() => '/';\n"),
        ("old/leave.dart", &leave("LeaveResult leave() => true;")),
    ]);
    assert_eq!(
        d,
        [
            "✗ old/leave.dart  a redirect.dart route never stays on screen, so there is nothing to leave: remove leave.dart"
        ]
    );
}

#[test]
fn l5_a_widget_ref_is_refused() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave(BuildContext context, WidgetRef ref) => true;"),
        ),
    ]);
    assert_eq!(
        d,
        [
            "✗ leave.dart:3  leave() runs outside the page's widget tree (go_router hands it the root navigator's context): take `Ref`"
        ]
    );
}

#[test]
fn l6_a_provider_container_is_refused() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave(ProviderContainer c) => true;"),
        ),
    ]);
    assert_eq!(
        d,
        [
            "✗ leave.dart:3  leave() takes `Ref ref`; `ProviderContainer` is the older form of guards, not of leave()"
        ]
    );
}

#[test]
fn l7_positional_parameters_are_context_then_ref() {
    for body in [
        "LeaveResult leave(Ref ref, BuildContext context) => true;",
        "LeaveResult leave(int x) => true;",
        "LeaveResult leave(BuildContext context, Ref ref, int x) => true;",
        "LeaveResult leave(PageLeave page) => true;",
    ] {
        let d = diags(&[("page.dart", &page("Home")), ("leave.dart", &leave(body))]);
        assert!(
            d.len() == 1
                && d[0].starts_with("✗ leave.dart:3  ")
                && d[0].ends_with(
                    "leave()'s positional parameters are `BuildContext context` then `Ref ref`, each optional; the rest are named"
                ),
            "{body}: {d:?}"
        );
    }
}

#[test]
fn l8_the_page_is_called_page() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave({required PageLeave where}) => true;"),
        ),
    ]);
    assert_eq!(
        d,
        ["✗ leave.dart:3  the page that is going is `PageLeave page`; name the parameter `page`"]
    );
}

#[test]
fn a_parameter_called_page_of_another_type_is_a_query_parameter_or_an_error() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave({int? page}) => true;"),
        ),
    ]);
    has(
        &c,
        &["(ref, page) => leaveWithParams(() => _leave0(state), (v) => _i1.leave(page: v.page))"],
    );
}

#[test]
fn a_typed_route_is_not_something_a_leave_takes() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "leave.dart",
            &leave("LeaveResult leave({required TypedLocation route}) => true;"),
        ),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].starts_with("✗ leave.dart:3  `route` isn't a segment of this path"),
        "{d:?}"
    );
}

#[test]
fn an_extra_that_does_not_fit_the_page_is_an_error() {
    let d = diags(&[
        (
            "page.dart",
            "class HomePage extends StatelessWidget { const HomePage({super.key, this.extra}); final String? extra; }",
        ),
        (
            "leave.dart",
            &leave("LeaveResult leave({int? extra}) => true;"),
        ),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].contains("`extra` is `int?` here, but the routes it covers take other types"),
        "{d:?}"
    );
}
