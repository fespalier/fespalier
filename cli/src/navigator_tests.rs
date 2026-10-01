//! Navigators and shells: `navigator.dart` (#1), `present.dart` (#2), a tab layout's
//! `container` and the shell's own page (#3).

use std::fs;

use crate::config::Config;
use crate::{analyze, build, manifest};

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
fn diags(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn code(files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

/// Whether the code has each snippet, whatever its indentation.
fn has(code: &str, needles: &[&str]) {
    let flat = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let code_flat = flat(code);
    for n in needles {
        assert!(code_flat.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

const ROOT: &str = "const navigator = RouteNavigator.root;";
const SHELL: &str = "const navigator = RouteNavigator.shell;";

const TABS: &str = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";

const LAYOUT: &str = "class BoxLayout extends StatelessWidget { const BoxLayout({super.key, required this.child}); final Widget child; }";

const FADE: &str =
    "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";

const SHEET: &str =
    "Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);";

/// How many times `needle` appears.
fn count(code: &str, needle: &str) -> usize {
    code.matches(needle).count()
}

/// The generated code between the first `from` and the first `to` after it.
fn between<'a>(code: &'a str, from: &str, to: &str) -> &'a str {
    let start = code
        .find(from)
        .unwrap_or_else(|| panic!("missing `{from}` in:\n{code}"));
    let end = code[start..].find(to).map_or(code.len(), |i| start + i);
    &code[start..end]
}

// --- the key -------------------------------------------------------------------

#[test]
fn the_router_owns_a_root_navigator_key_that_mount_can_take() {
    let c = code(&[("page.dart", &page("Home"))]);
    has(
        &c,
        &[
            "static GlobalKey<NavigatorState> _rootNavigatorKey = _newRootNavigatorKey();",
            "static GlobalKey<NavigatorState> _newRootNavigatorKey() =>\n      GlobalKey<NavigatorState>(debugLabel: 'root');",
            "static GlobalKey<NavigatorState> get rootNavigatorKey => _rootNavigatorKey;",
            "    GlobalKey<NavigatorState>? navigatorKey,\n  }) {\n    final routes = mount(navigatorKey: navigatorKey);",
            "navigatorKey: rootNavigatorKey,\n      routes: routes,",
            "static List<RouteBase> mount({\n    String at = '/',\n    GlobalKey<NavigatorState>? navigatorKey,\n  }) {\n    _base = at;\n    _rootNavigatorKey = navigatorKey ?? _newRootNavigatorKey();",
        ],
    );
    // Nothing declares a root route, so no route names the key.
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey"), 0, "{c}");
}

// --- navigator.dart --------------------------------------------------------------

#[test]
fn a_root_folder_puts_its_route_and_every_descendant_on_the_root_navigator() {
    let c = code(&[
        ("layout.dart", LAYOUT),
        ("page.dart", &page("Home")),
        ("orders/page.dart", &page("Orders")),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
        ),
        ("orders/$id/navigator.dart", ROOT),
        ("orders/$id/cancel/page.dart", &page("Cancel")),
        ("orders/$id/cancel/reason/page.dart", &page("Reason")),
        ("orders/history/page.dart", &page("History")),
    ]);
    // The declaring route and both levels below it; the folders around it stay on their navigator.
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey,"), 3, "{c}");
    assert!(
        !between(&c, "path: 'orders'", "path: ':id'")
            .contains("parentNavigatorKey: rootNavigatorKey"),
        "{c}"
    );
    has(
        &c,
        &[
            "path: ':id',\n                    parentNavigatorKey: rootNavigatorKey,",
            "path: 'cancel',\n                        parentNavigatorKey: rootNavigatorKey,",
        ],
    );
    // The route table marks them.
    has(
        &c,
        &[
            "OrderRoute    orders/$id/page.dart  (root)",
            "ReasonRoute   orders/$id/cancel/reason/page.dart  (root)",
        ],
    );
}

#[test]
fn the_route_table_marks_root_routes() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("photo/page.dart", &page("Photo")),
        ("photo/navigator.dart", ROOT),
        ("photo/zoom/page.dart", &page("Zoom")),
    ]);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let rows = crate::routes::table(&app);
    assert!(
        rows.iter()
            .any(|r| r.contains("/photo ") && r.trim_end().ends_with("(root)")),
        "{rows:?}"
    );
    assert!(
        rows.iter()
            .any(|r| r.contains("/photo/zoom") && r.trim_end().ends_with("(root)")),
        "{rows:?}"
    );
    assert!(
        rows.iter()
            .any(|r| r.starts_with("/ ") && !r.contains("root")),
        "{rows:?}"
    );
}

#[test]
fn the_nearest_navigator_dart_wins() {
    // `.shell` needs a layout between it and the root folder above.
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/profile/page.dart", &page("Profile")),
        ("(tabs)/profile/edit/page.dart", &page("Edit")),
        ("(tabs)/profile/edit/navigator.dart", ROOT),
        ("(tabs)/profile/edit/flow/layout.dart", LAYOUT),
        ("(tabs)/profile/edit/flow/step/page.dart", &page("Step")),
        ("(tabs)/profile/edit/flow/step/navigator.dart", SHELL),
        (
            "(tabs)/profile/edit/flow/step/more/page.dart",
            &page("More"),
        ),
        ("(tabs)/profile/edit/flow/step/more/navigator.dart", ROOT),
    ]);
    // edit: root. The layout below it is a shell on the root navigator; the step in it is on the
    // layout's navigator; more, below the step, goes back to the root one.
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey,"), 3, "{c}");
}

#[test]
fn a_layout_below_a_root_override_is_a_shell_on_the_root_navigator() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/profile/page.dart", &page("Profile")),
        ("(tabs)/profile/wizard/navigator.dart", ROOT),
        ("(tabs)/profile/wizard/page.dart", &page("Wizard")),
        ("(tabs)/profile/wizard/steps/layout.dart", LAYOUT),
        ("(tabs)/profile/wizard/steps/one/page.dart", &page("One")),
        ("(tabs)/profile/wizard/steps/two/page.dart", &page("Two")),
    ]);
    // The ShellRoute is the one that names the key; the routes inside sit on its own navigator
    // (go_router refuses a parentNavigatorKey below a ShellRoute that isn't its own).
    has(
        &c,
        &[
            "ShellRoute(\n                    parentNavigatorKey: rootNavigatorKey,\n                    pageBuilder: (context, state, child) =>",
        ],
    );
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey,"), 2, "{c}");
    let shell = between(
        &c,
        "ShellRoute(",
        "restorationScopeId: 'layout:(tabs)/profile/wizard/steps/'",
    );
    assert_eq!(
        count(shell, "parentNavigatorKey: rootNavigatorKey"),
        1,
        "{shell}"
    );
}

#[test]
fn a_tab_layout_below_a_root_override_is_a_stateful_shell_on_the_root_navigator() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("account/page.dart", &page("Account")),
        ("account/full/navigator.dart", ROOT),
        ("account/full/page.dart", &page("Full")),
        ("account/full/tabs/layout.dart", TABS),
        ("account/full/tabs/a/page.dart", &page("A")),
        ("account/full/tabs/b/page.dart", &page("B")),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute.indexedStack(\n            parentNavigatorKey: rootNavigatorKey,\n            pageBuilder:",
        ],
    );
}

#[test]
fn navigator_dart_works_in_a_page_less_group() {
    let c = code(&[
        ("account/page.dart", &page("Account")),
        ("account/(full)/navigator.dart", ROOT),
        ("account/(full)/photo/page.dart", &page("Photo")),
        ("account/(full)/username/page.dart", &page("Username")),
        ("account/security/page.dart", &page("Security")),
    ]);
    // Both routes of the group, and only those.
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey,"), 2, "{c}");
    let security = between(&c, "path: 'security'", "\n  }\n");
    assert!(
        !security.contains("parentNavigatorKey: rootNavigatorKey"),
        "{security}"
    );
    has(
        &c,
        &["path: 'photo',\n            parentNavigatorKey: rootNavigatorKey,"],
    );
}

#[test]
fn a_root_route_is_not_lifted_out_of_a_shell_it_sits_directly_in() {
    // The first route of a tab: go_router can't open the tab on it.
    let e = diags(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("home/navigator.dart", ROOT),
        ("search/page.dart", &page("Search")),
    ]);
    assert!(
        e.iter().any(|m| m.contains("home/page.dart:1")
            && m.contains("root navigator")
            && m.contains("directly in a tab layout")),
        "{e:?}"
    );
    // Also with an initialLocation, and beside other routes of a plain layout: it is still a
    // direct child of a shell.
    let e = diags(&[
        ("(box)/layout.dart", LAYOUT),
        ("(box)/a/page.dart", &page("A")),
        ("(box)/b/page.dart", &page("B")),
        ("(box)/b/navigator.dart", ROOT),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("(box)/b/page.dart:1") && m.contains("directly in a layout")),
        "{e:?}"
    );
    // A layout that is itself on the root navigator, directly in another shell.
    let e = diags(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("home/inner/layout.dart", LAYOUT),
        ("home/inner/navigator.dart", ROOT),
        ("home/inner/x/page.dart", &page("X")),
        ("other/page.dart", &page("Other")),
    ]);
    assert!(e.is_empty(), "below a page it is fine: {e:?}");
    let e = diags(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("inner/layout.dart", LAYOUT),
        ("inner/navigator.dart", ROOT),
        ("inner/x/page.dart", &page("X")),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("inner/layout.dart") && m.contains("directly in a tab layout")),
        "{e:?}"
    );
}

#[test]
fn a_root_route_below_a_page_in_a_tab_is_fine() {
    // The page that stays in the tab is the parent go_router builds underneath.
    let e = diags(&[
        ("layout.dart", TABS),
        ("profile/page.dart", &page("Profile")),
        ("profile/edit/page.dart", &page("Edit")),
        ("profile/edit/navigator.dart", ROOT),
    ]);
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn shell_below_a_root_route_is_an_error_unless_a_layout_sits_between() {
    let e = diags(&[
        ("orders/page.dart", &page("Orders")),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
        ),
        ("orders/$id/navigator.dart", ROOT),
        ("orders/$id/chat/page.dart", &page("Chat")),
        ("orders/$id/chat/navigator.dart", SHELL),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("orders/$id/chat/navigator.dart")
                && m.contains("`RouteNavigator.shell` can't go back")),
        "{e:?}"
    );
    // The same folder with a layout between is fine.
    let e = diags(&[
        ("orders/page.dart", &page("Orders")),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
        ),
        ("orders/$id/navigator.dart", ROOT),
        ("orders/$id/box/layout.dart", LAYOUT),
        ("orders/$id/box/chat/page.dart", &page("Chat")),
        ("orders/$id/box/chat/navigator.dart", SHELL),
    ]);
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn navigator_dart_is_checked_like_tabs() {
    let bad = |body: &str| {
        diags(&[
            ("page.dart", &page("Home")),
            ("photo/page.dart", &page("Photo")),
            ("photo/navigator.dart", body),
        ])
    };
    let e = bad("const navigator = RouteNavigator.dialog;");
    assert!(
        e.iter().any(|m| m.contains("photo/navigator.dart:1")
            && m.contains("`RouteNavigator.root` or `RouteNavigator.shell`")),
        "{e:?}"
    );
    let e = bad("final navigator = RouteNavigator.root;");
    assert!(
        e.iter().any(|m| m.contains("`navigator` must be `const`")),
        "{e:?}"
    );
    let e = bad("const other = RouteNavigator.root;");
    assert!(
        e.iter()
            .any(|m| m.contains("expected `const navigator = RouteNavigator.root;`")),
        "{e:?}"
    );
    let e = bad("const navigator = kDebugMode ? RouteNavigator.root : RouteNavigator.shell;");
    assert!(
        e.iter()
            .any(|m| m.contains("must be `RouteNavigator.root` or `RouteNavigator.shell`")),
        "{e:?}"
    );
    // An import prefix and spacing are fine.
    assert!(bad("import 'package:fespalier/fespalier.dart' as f;\nconst navigator = f.RouteNavigator . root;").is_empty());
}

// --- present.dart ---------------------------------------------------------------

#[test]
fn present_builds_its_own_page_only_and_implies_the_root_navigator_below() {
    let c = code(&[
        ("transition.dart", FADE),
        ("layout.dart", LAYOUT),
        (
            "products/$id/page.dart",
            "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id}); final int id; }",
        ),
        (
            "products/$id/buy/page.dart",
            "class BuyPage extends StatelessWidget { const BuyPage({super.key, required this.id}); final int id; }",
        ),
        ("products/$id/buy/present.dart", SHEET),
        ("products/$id/buy/confirm/page.dart", &page("Confirm")),
    ]);
    // The sheet's page is the app's, verbatim, with the same binding as transition.dart.
    has(
        &c,
        &[
            "path: 'buy',\n                parentNavigatorKey: rootNavigatorKey,\n                pageBuilder: (context, state) => _i4.present(\n                  state.pageKey,\n                  buildWithParams(",
        ],
    );
    // Its child keeps the nearest transition.dart for its own page, and is on the root navigator too.
    has(
        &c,
        &[
            "path: 'confirm',\n                    parentNavigatorKey: rootNavigatorKey,\n                    pageBuilder: (context, state) => _i0.transition(",
        ],
    );
    // The parent is untouched.
    let product = between(&c, "path: joinLocation(at, '/products/:id')", "path: 'buy'");
    assert!(
        !product.contains("parentNavigatorKey: rootNavigatorKey"),
        "{product}"
    );
    assert_eq!(count(&c, "_i4.present("), 1, "{c}");
    has(&c, &["/products/:id/buy  BuyRoute", "(present, root)"]);
    assert!(
        c.contains("ConfirmRoute") && c.contains("(transition, root)"),
        "{c}"
    );
}

#[test]
fn present_is_bound_like_transition() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("sheet/page.dart", &page("Sheet")),
        (
            "sheet/present.dart",
            "Page<void> present(GoRouterState state, Widget child, LocalKey key) => S(state, child, key);",
        ),
    ]);
    has(
        &c,
        &[
            "_i2.present(\n          state,\n          const _i1.SheetPage(),\n          state.pageKey,\n        )",
        ],
    );
    let e = diags(&[
        ("page.dart", &page("Home")),
        ("sheet/page.dart", &page("Sheet")),
        (
            "sheet/present.dart",
            "Page<void> present(LocalKey key, Widget child, int extra) => S(key, child);",
        ),
    ]);
    assert!(
        e.iter().any(|m| m.contains("sheet/present.dart:1")
            && m.contains("can't fill `extra`: present() gets `key`, `child` and `state`")),
        "{e:?}"
    );
    let e = diags(&[
        ("page.dart", &page("Home")),
        ("sheet/page.dart", &page("S")),
        (
            "sheet/present.dart",
            "Widget present(Widget child) => child;",
        ),
    ]);
    assert!(
        e.iter().any(|m| m.contains("present() must return a Page")),
        "{e:?}"
    );
    let e = diags(&[
        ("page.dart", &page("Home")),
        ("sheet/page.dart", &page("S")),
        (
            "sheet/present.dart",
            "Page<void> other(LocalKey key, Widget child) => S();",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("expected `Page<void> present(LocalKey key, Widget child)`")),
        "{e:?}"
    );
    let e = diags(&[
        ("page.dart", &page("Home")),
        ("sheet/page.dart", &page("S")),
        (
            "sheet/present.dart",
            "Page<void> present(LocalKey key) => S();",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("present() must take the page as `Widget child`")),
        "{e:?}"
    );
}

#[test]
fn present_is_not_inherited_by_folders_below() {
    let c = code(&[
        ("transition.dart", FADE),
        ("a/page.dart", &page("A")),
        ("a/present.dart", SHEET),
        ("a/b/page.dart", &page("B")),
    ]);
    assert_eq!(count(&c, "present("), 1, "{c}");
    assert_eq!(count(&c, ".transition("), 1, "{c}");
}

#[test]
fn a_navigator_dart_beside_present_dart_overrides_the_implied_root() {
    // The sheet stays on the navigator it is in (say, a tab's), and so do its children.
    let c = code(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("home/sheet/page.dart", &page("Sheet")),
        ("home/sheet/present.dart", SHEET),
        ("home/sheet/navigator.dart", SHELL),
        ("home/sheet/child/page.dart", &page("Child")),
    ]);
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey"), 0, "{c}");
    assert_eq!(count(&c, ".present("), 1, "{c}");
    has(&c, &["(present)"]);
    assert!(!c.contains("(present, root)"), "{c}");
}

#[test]
fn present_without_a_page_is_ignored_with_a_warning() {
    let e = diags(&[
        ("page.dart", &page("Home")),
        ("orphan/present.dart", SHEET),
        ("orphan/inner/page.dart", &page("Inner")),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("orphan/present.dart") && m.contains("there is no page.dart here")),
        "{e:?}"
    );
    assert_eq!(e.len(), 1, "{e:?}");
}

#[test]
fn a_sheet_inside_a_tab_goes_to_the_root_navigator_and_its_tab_stays_underneath() {
    let c = code(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("home/buy/page.dart", &page("Buy")),
        ("home/buy/present.dart", SHEET),
    ]);
    has(
        &c,
        &["path: 'buy',\n                parentNavigatorKey: rootNavigatorKey,"],
    );
}

// --- the manifest ---------------------------------------------------------------

#[test]
fn the_manifest_names_how_a_route_is_presented() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("old/redirect.dart", "String redirect() => '/';"),
        ("photo/page.dart", &page("Photo")),
        ("photo/navigator.dart", ROOT),
        ("photo/zoom/page.dart", &page("Zoom")),
        ("photo/zoom/present.dart", SHEET),
        ("photo/zoom/deep/page.dart", &page("Deep")),
    ]);
    let cfg = Config::load(dir.path()).unwrap();
    let (code, diags, app) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let route = |t: &str| between(&code, &format!("type: {t},"), "    ),");
    assert!(!route("HomeRoute").contains("presentation"), "{code}");
    assert!(
        route("OldRoute").contains("presentation: RoutePresentation.redirect,"),
        "{code}"
    );
    assert!(
        route("PhotoRoute").contains("presentation: RoutePresentation.root,"),
        "{code}"
    );
    // present.dart: fespalier can't know it's a sheet, so `custom`; its child is just on the root.
    assert!(
        route("ZoomRoute").contains("presentation: RoutePresentation.custom,"),
        "{code}"
    );
    assert!(
        route("DeepRoute").contains("presentation: RoutePresentation.root,"),
        "{code}"
    );
    // The same in `fsp routes --json`.
    let rows = crate::routes::json_lines(&app, "lib/app");
    let presentation = |pattern: &str| {
        let row = rows
            .iter()
            .map(|r| serde_json::from_str::<serde_json::Value>(r).unwrap())
            .find(|r| r["pattern"] == pattern)
            .unwrap();
        (
            row["presentation"].as_str().unwrap().to_string(),
            row["tags"].clone(),
        )
    };
    assert_eq!(presentation("/"), ("page".into(), serde_json::json!([])));
    assert_eq!(presentation("/old").0, "redirect");
    assert_eq!(
        presentation("/photo"),
        ("root".into(), serde_json::json!(["root"]))
    );
    assert_eq!(
        presentation("/photo/zoom"),
        ("custom".into(), serde_json::json!(["present", "root"]))
    );
    assert_eq!(
        presentation("/photo/zoom/deep"),
        ("root".into(), serde_json::json!(["root"]))
    );
    let _ = manifest::collect(&app);
}

// --- container ------------------------------------------------------------------

const CONTAINER: &str = "Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children) => Fade(children);";

#[test]
fn a_container_makes_the_tabs_a_stateful_shell_with_its_own_navigator_container() {
    let c = code(&[
        ("layout.dart", &format!("{TABS}\n{CONTAINER}")),
        ("home/page.dart", &page("Home")),
        ("search/page.dart", &page("Search")),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute(\n        navigatorContainerBuilder: _i0.container,\n        pageBuilder: (context, state, navigationShell) => layoutPage(",
            "branches: [",
            "restorationScopeId: 'layout:/',",
        ],
    );
    assert!(!c.contains("StatefulShellRoute.indexedStack"), "{c}");
}

#[test]
fn without_a_container_the_output_is_the_same_as_before() {
    let c = code(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("search/page.dart", &page("Search")),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute.indexedStack(\n        pageBuilder: (context, state, navigationShell) => layoutPage(\n          context,\n          state,\n          'layout:/',\n          _i0.TabsLayout(navigationShell: navigationShell),\n        ),\n        branches: [",
        ],
    );
    assert!(!c.contains("navigatorContainerBuilder"), "{c}");
}

#[test]
fn container_parameters_are_positional_with_fixed_types() {
    let with = |container: &str| {
        diags(&[
            ("layout.dart", &format!("{TABS}\n{container}")),
            ("home/page.dart", &page("Home")),
            ("search/page.dart", &page("Search")),
        ])
    };
    // Any names will do.
    assert!(with("Widget container(BuildContext a, StatefulNavigationShell b, List<Widget> c) => c.first;").is_empty());
    // A wrong type is an error at the parameter, whatever it is called.
    let e = with(
        "Widget container(BuildContext context, StatefulNavigationShell shell, List<int> children) => x;",
    );
    assert!(e.iter().any(|m| m.contains("layout.dart:2") && m.contains("`children` gets the branch navigators, a List<Widget>, but it's declared List<int>")), "{e:?}");
    let e =
        with("Widget container(BuildContext context, Widget shell, List<Widget> children) => x;");
    assert!(
        e.iter()
            .any(|m| m
                .contains("`shell` gets the StatefulNavigationShell, but it's declared Widget")),
        "{e:?}"
    );
    let e = with(
        "Widget container(int context, StatefulNavigationShell shell, List<Widget> children) => x;",
    );
    assert!(
        e.iter()
            .any(|m| m.contains("`context` gets the BuildContext, but it's declared int")),
        "{e:?}"
    );
    // Untyped, missing, extra or named parameters and a wrong return type.
    let e = with(
        "Widget container(context, StatefulNavigationShell shell, List<Widget> children) => x;",
    );
    assert!(
        e.iter().any(|m| m.contains("give `context` a type")),
        "{e:?}"
    );
    let e = with("Widget container(BuildContext context, StatefulNavigationShell shell) => x;");
    assert!(
        e.iter()
            .any(|m| m.contains("container() takes three positional parameters")),
        "{e:?}"
    );
    let e = with(
        "Widget container(BuildContext context, StatefulNavigationShell shell, {required List<Widget> children}) => x;",
    );
    assert!(
        e.iter()
            .any(|m| m.contains("container() takes three positional parameters")),
        "{e:?}"
    );
    let e = with(
        "int container(BuildContext context, StatefulNavigationShell shell, List<Widget> children) => 1;",
    );
    assert!(
        e.iter()
            .any(|m| m.contains("container() must return a Widget")),
        "{e:?}"
    );
}

#[test]
fn a_container_in_a_plain_layout_is_ignored_with_a_warning() {
    let e = diags(&[
        ("layout.dart", &format!("{LAYOUT}\n{CONTAINER}")),
        ("page.dart", &page("Home")),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].contains("container() is only used by a tab layout"),
        "{e:?}"
    );
}

#[test]
fn nested_tab_layouts_each_take_their_own_container() {
    let c = code(&[
        ("layout.dart", &format!("{TABS}\n{CONTAINER}")),
        ("home/page.dart", &page("Home")),
        ("lib/layout.dart", TABS),
        ("lib/a/page.dart", &page("A")),
        ("lib/b/page.dart", &page("B")),
    ]);
    assert_eq!(
        count(&c, "navigatorContainerBuilder: _i0.container,"),
        1,
        "{c}"
    );
    assert_eq!(count(&c, "StatefulShellRoute.indexedStack("), 1, "{c}");
}

// --- the shell's page -----------------------------------------------------------

#[test]
fn a_shell_takes_the_nearest_transition_under_a_key_that_is_stable() {
    let c = code(&[
        ("transition.dart", FADE),
        ("layout.dart", LAYOUT),
        ("page.dart", &page("Home")),
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/one/page.dart", &page("One")),
        ("(tabs)/two/page.dart", &page("Two")),
    ]);
    // Same restoration id as layoutPage would have set, as the page's key.
    has(
        &c,
        &[
            "ShellRoute(\n        pageBuilder: (context, state, child) => _i1.transition(\n          const ValueKey<String>('layout:/'),\n          _i2.BoxLayout(child: child),\n        ),",
            "StatefulShellRoute.indexedStack(\n            pageBuilder: (context, state, navigationShell) => _i1.transition(\n              const ValueKey<String>('layout:(tabs)/'),\n              _i3.TabsLayout(navigationShell: navigationShell),\n            ),",
            "restorationScopeId: 'layout:/',",
            "restorationScopeId: 'layout:(tabs)/',",
        ],
    );
    assert!(!c.contains("layoutPage("), "{c}");
}

#[test]
fn a_shell_without_a_transition_keeps_layout_page() {
    let c = code(&[("layout.dart", LAYOUT), ("page.dart", &page("Home"))]);
    has(
        &c,
        &[
            "pageBuilder: (context, state, child) => layoutPage(\n          context,\n          state,\n          'layout:/',",
        ],
    );
}

#[test]
fn a_folders_own_transition_covers_its_layout_and_a_nearer_one_wins() {
    let c = code(&[
        ("transition.dart", FADE),
        ("(box)/layout.dart", LAYOUT),
        (
            "(box)/transition.dart",
            "Page<void> transition(LocalKey key, Widget child) => Transitions.slide(key, child);",
        ),
        ("(box)/page.dart", &page("Home")),
        ("(plain)/layout.dart", LAYOUT),
        ("(plain)/about/page.dart", &page("About")),
    ]);
    // (box)'s own transition builds its shell; (plain) inherits the root's.
    let boxed = between(&c, "'layout:(box)/'", ")");
    let _ = boxed;
    has(
        &c,
        &[
            "_i2.transition(\n          const ValueKey<String>('layout:(box)/'),",
            "_i0.transition(\n          const ValueKey<String>('layout:(plain)/'),",
        ],
    );
}

#[test]
fn transition_can_tell_a_shell_from_a_route() {
    // A transition that asks for `bool shell` gets true for a layout's shell, false for a route.
    let t = "Page<void> transition(LocalKey key, Widget child, {bool shell = false}) => T(key, child, shell);";
    let c = code(&[
        ("transition.dart", t),
        ("layout.dart", LAYOUT),
        ("page.dart", &page("Home")),
    ]);
    has(
        &c,
        &[
            "_i1.transition(\n          const ValueKey<String>('layout:/'),\n          _i2.BoxLayout(child: child),\n          shell: true,\n        )",
            "_i1.transition(\n            state.pageKey,\n            const _i0.HomePage(),\n            shell: false,\n          )",
        ],
    );
    let e = diags(&[
        (
            "transition.dart",
            "Page<void> transition(LocalKey key, Widget child, {int shell = 0}) => T();",
        ),
        ("page.dart", &page("Home")),
    ]);
    assert!(
        e.iter().any(|m| m.contains(
            "`shell` gets whether the page is a layout's shell, a bool, but it's declared int"
        )),
        "{e:?}"
    );
}

#[test]
fn a_shell_on_the_root_navigator_still_gets_its_transition() {
    let c = code(&[
        ("transition.dart", FADE),
        ("page.dart", &page("Home")),
        ("wizard/page.dart", &page("Wizard")),
        ("wizard/navigator.dart", ROOT),
        ("wizard/steps/layout.dart", LAYOUT),
        ("wizard/steps/one/page.dart", &page("One")),
    ]);
    has(
        &c,
        &[
            "ShellRoute(\n            parentNavigatorKey: rootNavigatorKey,\n            pageBuilder: (context, state, child) => _i1.transition(\n              const ValueKey<String>('layout:wizard/steps/'),",
        ],
    );
}

// --- next to function views ------------------------------------------------------

#[test]
fn navigator_dart_and_present_dart_work_with_function_pages() {
    let c = code(&[
        ("layout.dart", "Widget layout(Widget child) => child;"),
        ("orders/page.dart", "Widget page() => Text('orders');"),
        (
            "orders/$id/page.dart",
            "Widget page(int id) => Text('$id');",
        ),
        ("orders/$id/navigator.dart", ROOT),
        (
            "orders/$id/buy/page.dart",
            "Widget page(int id) => Text('buy');",
        ),
        ("orders/$id/buy/present.dart", SHEET),
        (
            "orders/$id/buy/confirm/page.dart",
            "Widget page() => Text('ok');",
        ),
    ]);
    has(
        &c,
        &[
            "path: ':id', parentNavigatorKey: rootNavigatorKey,",
            "path: 'buy', parentNavigatorKey: rootNavigatorKey,",
            "path: 'confirm', parentNavigatorKey: rootNavigatorKey,",
            ".present(",
            "(present, root)",
        ],
    );
    assert_eq!(count(&c, "parentNavigatorKey: rootNavigatorKey,"), 3, "{c}");
}

#[test]
fn a_container_works_beside_a_function_layout() {
    let layout = "Widget layout(StatefulNavigationShell shell) => Text('tabs');\n\
                  Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children) => Fade(children);";
    let c = code(&[
        ("layout.dart", layout),
        ("home/page.dart", "Widget page() => Text('home');"),
        ("search/page.dart", "Widget page() => Text('search');"),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute( navigatorContainerBuilder: _i0.container,",
            "_i0.layout(navigationShell)",
        ],
    );
    assert!(!c.contains("StatefulShellRoute.indexedStack"), "{c}");
    // A wrong `container` is still an error at its parameter.
    let e = diags(&[
        (
            "layout.dart",
            "Widget layout(StatefulNavigationShell shell) => Text('tabs');\nWidget container(BuildContext c, Widget s, List<Widget> l) => l.first;",
        ),
        ("home/page.dart", "Widget page() => Text('home');"),
        ("search/page.dart", "Widget page() => Text('search');"),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("`s` gets the StatefulNavigationShell")),
        "{e:?}"
    );
    // In a plain function layout it is ignored, with a warning.
    let e = diags(&[
        (
            "layout.dart",
            "Widget layout(Widget child) => child;\nWidget container(BuildContext c, StatefulNavigationShell s, List<Widget> l) => l.first;",
        ),
        ("page.dart", "Widget page() => Text('home');"),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].contains("container() is only used by a tab layout"),
        "{e:?}"
    );
}

#[test]
fn a_function_layout_shell_takes_the_transition_and_the_root_key() {
    let c = code(&[
        ("transition.dart", FADE),
        ("page.dart", "Widget page() => Text('home');"),
        ("wizard/page.dart", "Widget page() => Text('w');"),
        ("wizard/navigator.dart", ROOT),
        (
            "wizard/steps/layout.dart",
            "Widget layout(Widget child) => child;",
        ),
        ("wizard/steps/one/page.dart", "Widget page() => Text('1');"),
    ]);
    has(
        &c,
        &[
            "ShellRoute( parentNavigatorKey: rootNavigatorKey, pageBuilder: (context, state, child) => _i1.transition( const ValueKey<String>('layout:wizard/steps/'),",
        ],
    );
}

#[test]
fn a_folders_case_sensitivity_reaches_root_and_present_routes() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("route.dart", "const caseSensitive = false;"),
        ("orders/page.dart", &page("Orders")),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
        ),
        ("orders/$id/navigator.dart", ROOT),
        (
            "orders/$id/buy/page.dart",
            "class BuyPage extends StatelessWidget { const BuyPage({super.key, required this.id}); final int id; }",
        ),
        ("orders/$id/buy/present.dart", SHEET),
        ("orders/$id/buy/route.dart", "const caseSensitive = true;"),
    ]);
    // Both keep their key, and each says what its own folder decided.
    has(
        &c,
        &["path: ':id', parentNavigatorKey: rootNavigatorKey, caseSensitive: false,"],
    );
    let buy = between(&c, "path: 'buy'", "pageBuilder");
    assert!(
        buy.contains("parentNavigatorKey: rootNavigatorKey,") && !buy.contains("caseSensitive"),
        "{buy}"
    );
}
