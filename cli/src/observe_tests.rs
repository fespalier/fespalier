//! `observe.dart` (since 0.8.1): `onEnter`, `onLeave` and `onFocus` for every page at and below
//! a folder. The generator binds their parameters like a guard's, hands the runtime the hooks of
//! each page in `RouteMatcher.observe`, and attaches them in `AppRoutes.attach`.

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

const IMPORT: &str = "import 'package:fespalier/fespalier.dart';\n";

fn hooks(body: &str) -> String {
    format!("{IMPORT}{body}")
}

// ---- binding ----

#[test]
fn a_hook_binds_the_segments_above_its_folder_and_the_typed_route() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onEnter(Ref ref, {required TypedLocation route, Uri? uri}) {}"),
        ),
        ("items/$id/page.dart", &item()),
        (
            "items/$id/observe.dart",
            &hooks(
                "void onEnter(Ref ref, {required int id}) {}\n\
                 void onFocus({required int id}) {}\n\
                 void onLeave(Ref ref, {required int id}) {}",
            ),
        ),
    ]);
    has(
        &c,
        &[
            // The home page has the root hooks only.
            "RouteMatcher([], (s) => UrlMatch(s.uri, const HomeRoute(), const {}, const []), observe: (s, m) {",
            "RouteHooks('observe.dart', onEnter: (ref, scope) => _i1.onEnter(ref, uri: s.uri, route: m.route)),",
            // The item page has the root's, then its folder's, outermost first.
            "final o2 = _observe2(s);",
            "RouteHooks('items/\\$id/observe.dart', onEnter: (ref, scope) => _i3.onEnter(ref, id: o2.id), onLeave: (ref) => _i3.onLeave(ref, id: o2.id), onFocus: (_) => _i3.onFocus(id: o2.id)),",
            "({int id}) _observe2(GoRouterState s) => (id: Segment.asInt(s, 'id'));",
            "static List<RouteHooks> _observeAt(Uri uri) => observeRoutes(uri, base, _matchers);",
            "static void attach(GoRouter router, [ProviderContainer? container]) {",
            "observeAttach(router, _observeAt, container: container);",
            "attach(router);",
        ],
    );
    // The outer file's hooks come first in the list.
    let flat = flat(&c);
    let outer = flat.find("RouteHooks('observe.dart'").unwrap();
    let inner = flat.find("RouteHooks('items/\\$id/observe.dart'").unwrap();
    assert!(outer < inner);
}

#[test]
fn a_query_parameter_of_a_hook_is_parsed_from_the_url() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onEnter({String? tab, List<int> ids}) {}"),
        ),
    ]);
    has(
        &c,
        &[
            "_observe0(GoRouterState s) => (tab: Query.asString(s, 'tab'), ids: Query.asIntList(s, 'ids'));",
        ],
    );
}

#[test]
fn a_hook_without_ref_gets_an_ignored_one() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onFocus() {}")),
    ]);
    has(&c, &["onFocus: (_) => _i1.onFocus()"]);
}

#[test]
fn a_folder_without_a_page_applies_to_the_pages_below_it() {
    let c = code(&[
        ("(shop)/observe.dart", &hooks("void onEnter() {}")),
        ("(shop)/cart/page.dart", &page("Cart")),
        ("about/page.dart", &page("About")),
    ]);
    // Cart has it, About has not.
    let flat = flat(&c);
    assert_eq!(flat.matches("RouteHooks('(shop)/observe.dart'").count(), 1);
}

#[test]
fn a_page_below_a_nest_false_route_still_inherits_the_observers_above() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter() {}")),
        ("refund/page.dart", &page("Refund")),
        ("refund/confirm/page.dart", &page("Confirm")),
        ("refund/confirm/route.dart", "const nest = false;\n"),
    ]);
    // Three pages, each with the root's hooks.
    assert_eq!(flat(&c).matches("RouteHooks('observe.dart'").count(), 3);
}

#[test]
fn an_app_without_an_observe_file_emits_nothing_of_it() {
    let c = code(&[("page.dart", &page("Home"))]);
    assert!(!c.contains("observe:"), "{c}");
    assert!(!c.contains("_observeAt"), "{c}");
    assert!(!c.contains("RouteHooks"), "{c}");
    assert!(!c.contains("static void attach"), "{c}");
    assert!(
        c.contains("      if (kFespalierDevTools) devToolsAttach(router);\n      return router;\n"),
        "{c}"
    );
}

#[test]
fn a_page_with_a_case_insensitive_matcher_gets_observe_after_case_sensitive() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter() {}")),
        ("docs/page.dart", &page("Docs")),
        ("docs/route.dart", "const caseSensitive = false;\n"),
    ]);
    has(
        &c,
        &["const {}, const []), caseSensitive: false, observe: (s, m) {"],
    );
}

// ---- the route table ----

#[test]
fn the_routes_say_which_pages_are_observed() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        ("items/$id/observe.dart", &hooks("void onEnter() {}")),
    ]);
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let rows = routes::table(&app);
    assert!(
        rows.iter()
            .any(|r| r.contains("items/$id/page.dart  (observe)")),
        "{rows:?}"
    );
    assert!(
        !rows.iter().any(|r| r.contains("  page.dart  (")),
        "{rows:?}"
    );
    let json = routes::json_lines(&app, "lib/app");
    let tagged: Vec<&String> = json.iter().filter(|l| l.contains("\"observe\"")).collect();
    assert_eq!(tagged.len(), 1, "{json:?}");
    assert!(
        tagged[0].contains("\"pattern\":\"/items/:id\""),
        "{tagged:?}"
    );
}

#[test]
fn the_graph_marks_an_observed_page() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter() {}")),
    ]);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let json = crate::graph::render(&app, &Config::default(), crate::graph::Format::Json);
    assert!(json.contains("\"observe\""), "{json}");
}

// ---- diagnostics ----

#[test]
fn o1_a_file_with_none_of_the_functions_is_an_error() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void helper() {}")),
    ]);
    assert_eq!(
        d,
        [
            "✗ observe.dart  expected `void onEnter(Ref ref, {...})`, `void onLeave(...)` or `void onFocus(...)`"
        ]
    );
}

#[test]
fn o2_a_hook_returns_void() {
    for (name, body) in [
        ("onEnter", "int onEnter() => 1;"),
        ("onLeave", "Future<void> onLeave() async {}"),
        ("onFocus", "onFocus() {}"),
    ] {
        let d = diags(&[("page.dart", &page("Home")), ("observe.dart", &hooks(body))]);
        let want = format!(
            "{name}() must return `void`: an observe.dart hook runs synchronously, at the end of the frame that shows the page"
        );
        assert!(
            d.len() == 1 && d[0].starts_with("✗ observe.dart:2  ") && d[0].ends_with(&want),
            "{name}: {d:?}"
        );
    }
}

#[test]
fn o3_a_widget_ref_is_refused() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter(WidgetRef ref) {}")),
    ]);
    assert_eq!(
        d,
        ["✗ observe.dart:2  an observe.dart hook runs outside the widget tree: take `Ref`"]
    );
}

#[test]
fn o4_a_provider_container_is_refused() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onLeave(ProviderContainer c) {}"),
        ),
    ]);
    assert_eq!(
        d,
        [
            "✗ observe.dart:2  onLeave() takes `Ref ref` first, or no provider at all; `ProviderContainer` is the older form of guards, not of hooks"
        ]
    );
}

#[test]
fn o5_extra_is_refused() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter({Object? extra}) {}")),
    ]);
    assert_eq!(
        d,
        [
            "✗ observe.dart:2  onEnter() can't take `extra`: a hook runs after the navigation, when the page's `extra` is not kept"
        ]
    );
}

#[test]
fn o6_the_typed_route_must_be_called_route() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onEnter({required TypedLocation where}) {}"),
        ),
    ]);
    assert_eq!(
        d,
        [
            "✗ observe.dart:2  the typed route of the page is `TypedLocation route`; name the parameter `route`"
        ]
    );
}

#[test]
fn a_parameter_called_route_of_another_type_is_a_segment() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/$route/page.dart", &page("Item")),
        (
            "items/$route/observe.dart",
            &hooks("void onEnter({required String route}) {}"),
        ),
    ]);
    has(
        &c,
        &["_observe2(GoRouterState s) => (route: Segment.asString(s, 'route'));"],
    );
}

#[test]
fn o7_an_observe_file_with_no_page_below_is_a_warning() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("empty/observe.dart", &hooks("void onEnter() {}")),
    ]);
    assert_eq!(
        d,
        [
            "! empty/observe.dart  observe.dart observes no pages: there is no page.dart at or below this folder"
        ]
    );
}

#[test]
fn a_redirect_below_is_not_a_page() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("old/observe.dart", &hooks("void onEnter() {}")),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    assert_eq!(
        d,
        [
            "! old/observe.dart  observe.dart observes no pages: there is no page.dart at or below this folder"
        ]
    );
}

#[test]
fn a_segment_that_is_not_above_the_folder_is_the_guards_error() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter({required int id}) {}")),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].contains("`id` isn't a segment of this path (it has none)"),
        "{d:?}"
    );
}

#[test]
fn an_on_enter_without_ref_gets_both_closure_parameters() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("observe.dart", &hooks("void onEnter() {}")),
    ]);
    has(&c, &["onEnter: (ref, scope) => _i1.onEnter()"]);
}

#[test]
fn on_enter_binds_the_page_scope() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onEnter(Ref ref, {required RouteScope scope, Uri? uri}) {}"),
        ),
    ]);
    has(
        &c,
        &["onEnter: (ref, scope) => _i1.onEnter(ref, uri: s.uri, scope: scope)"],
    );
}

#[test]
fn s1_the_scope_must_be_called_scope() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onEnter({required RouteScope where}) {}"),
        ),
    ]);
    assert_eq!(
        d,
        ["✗ observe.dart:2  the page's scope is `RouteScope scope`; name the parameter `scope`"]
    );
}

#[test]
fn s2_the_scope_is_a_named_parameter() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks("void onEnter(Ref ref, RouteScope scope) {}"),
        ),
    ]);
    assert_eq!(
        d,
        [
            "✗ observe.dart:2  take the page's scope as a named parameter: `{required RouteScope scope}`"
        ]
    );
}

#[test]
fn s3_only_on_enter_takes_the_scope() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        (
            "observe.dart",
            &hooks(
                "void onLeave({required RouteScope scope}) {}\n\
                 void onFocus({required RouteScope scope}) {}",
            ),
        ),
    ]);
    assert_eq!(
        d,
        [
            "✗ observe.dart:2  `onLeave()` can't take `RouteScope`: the scope is handed to `onEnter()`, which registers what runs at leave with `scope.onLeave(...)`",
            "✗ observe.dart:3  `onFocus()` can't take `RouteScope`: the scope is handed to `onEnter()`, which registers what runs at leave with `scope.onLeave(...)`",
        ]
    );
}
