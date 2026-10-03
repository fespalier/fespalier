//! Menus and breadcrumbs from nav.dart files (`AppMenu`).

use std::fs;

use crate::config::Config;
use crate::{analyze, build, routes, scaffold};

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

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

fn has_not(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

fn at(code: &str, needle: &str) -> usize {
    code.find(needle)
        .unwrap_or_else(|| panic!("missing `{needle}` in:\n{code}"))
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }".into()
}

const NAV: &str = "const nav = Nav(label: 'X');";

fn nav(label: &str, extra: &str) -> String {
    format!("const nav = Nav(label: '{label}'{extra});")
}

const TABS: &str = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";

const INNER: &str = "class InnerLayout extends StatelessWidget { const InnerLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }";

/// The text of the `AppMenu` declarations: everything from the class on.
fn menu(code: &str) -> &str {
    &code[at(code, "abstract final class AppMenu")..]
}

#[test]
fn an_app_without_a_nav_dart_has_no_menu() {
    let c = code(&[("page.dart", &page("Home")), ("a/page.dart", &page("A"))]);
    has_not(&c, &["AppMenu", "nav.dart", "NavNode", "_nav"]);
}

#[test]
fn the_menu_imports_the_runtime_and_the_nav_files() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("nav.dart", NAV),
        ("a/page.dart", &page("A")),
        ("a/nav.dart", NAV),
    ]);
    has(
        &c,
        &[
            "import 'package:fespalier/nav.dart';",
            "import 'app/nav.dart' as _i1;",
            "import 'app/a/nav.dart' as _i3;",
            "/// The folders with a nav.dart, as menus: drawers, tab bars and breadcrumbs (since 0.8.0).",
            "static List<NavItem> watch(WidgetRef ref, {String? under}) =>\n      watchNav(ref, tree, AppRoutes.matchUrl, _trails, under: under);",
            "static List<NavItem> breadcrumbs(WidgetRef ref) =>\n      watchNavTrail(ref, AppRoutes.matchUrl, _trails);",
        ],
    );
}

#[test]
fn the_app_folder_is_flat_and_the_entries_below_sit_beside_it() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("nav.dart", &nav("Home", "")),
        ("shop/page.dart", &page("Shop")),
        ("shop/nav.dart", &nav("Shop", ", order: 1")),
        ("shop/sale/page.dart", &page("Sale")),
        ("shop/sale/nav.dart", &nav("Sale", "")),
    ]);
    let m = menu(&c);
    // Home and Shop are both at the top; Sale is inside Shop.
    has(
        m,
        &[
            "static const List<NavNode> tree = [_nav0, _nav1];",
            "const _nav0 = NavNode(\n  folder: '',\n  nav: _i1.nav,\n  route: _navRoute0,\n  flat: true,\n);",
            "const _nav1 = NavNode(\n  folder: 'shop',\n  nav: _i3.nav,\n  route: _navRoute1,\n  children: [_nav2],\n);",
            "const _nav2 = NavNode(\n  folder: 'shop/sale',\n  nav: _i5.nav,\n  route: _navRoute2,\n);",
            "TypedLocation _navRoute0(Map<String, Object?> p) => const HomeRoute();",
        ],
    );
}

#[test]
fn siblings_sort_by_order_then_by_folder() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("zebra/page.dart", &page("Zebra")),
        ("zebra/nav.dart", &nav("Zebra", "")),
        ("apple/page.dart", &page("Apple")),
        ("apple/nav.dart", &nav("Apple", "")),
        ("last/page.dart", &page("Last")),
        ("last/nav.dart", &nav("Last", ", order: 9")),
        ("first/page.dart", &page("First")),
        ("first/nav.dart", &nav("First", ", order: -1")),
    ]);
    // First (-1), then Apple and Zebra (0, by folder), then Last (9). (Folders are numbered in
    // the order they are scanned: apple 1, first 2, last 3, zebra 4.)
    has(
        menu(&c),
        &["static const List<NavNode> tree = [_nav2, _nav1, _nav4, _nav3];"],
    );
}

#[test]
fn a_heading_holds_the_entries_below_it_and_needs_no_page() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "team/layout.dart",
            "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("team/nav.dart", &nav("Team", "")),
        ("team/members/page.dart", &page("Members")),
        ("team/members/nav.dart", &nav("Members", "")),
    ]);
    let m = menu(&c);
    has(
        m,
        &[
            "const _nav1 = NavNode(\n  folder: 'team',\n  nav: _i2.nav,\n  children: [_nav2],\n);",
            "MembersRoute: [_nav1, _nav2],",
        ],
    );
    has_not(m, &["_navRoute1"]);
}

#[test]
fn a_heading_with_nothing_below_it_is_left_out_with_a_warning() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("nav.dart", NAV),
        (
            "team/layout.dart",
            "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("team/nav.dart", NAV),
        ("team/x/page.dart", &page("X")),
    ]);
    assert_eq!(
        d,
        vec![
            "! team/nav.dart  nav.dart in a folder with no page.dart or redirect.dart is a heading for the nav.dart files below it, and there are none; it is ignored"
        ],
    );
    let c = {
        let dir = project(&[
            ("page.dart", &page("Home")),
            ("nav.dart", NAV),
            (
                "team/layout.dart",
                "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.child}); final Widget child; }",
            ),
            ("team/nav.dart", NAV),
            ("team/x/page.dart", &page("X")),
        ]);
        build(&dir.path().join("lib/app"), &Config::default())
            .unwrap()
            .0
    };
    has_not(menu(&c), &["folder: 'team'"]);
}

#[test]
fn a_folder_with_only_a_nav_dart_warns_once() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("nav.dart", NAV),
        ("lonely/nav.dart", NAV),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].contains("is a heading for the nav.dart files below it"),
        "{d:?}"
    );
}

#[test]
fn a_tab_layouts_own_page_is_flat_and_the_branches_know_their_index() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/page.dart", &page("Start")),
        ("(tabs)/nav.dart", &nav("Start", "")),
        ("(tabs)/b-second/page.dart", &page("Second")),
        ("(tabs)/b-second/nav.dart", &nav("Second", "")),
        ("(tabs)/a-third/page.dart", &page("Third")),
        ("(tabs)/a-third/nav.dart", &nav("Third", "")),
        ("(tabs)/layout.dart", TABS),
    ]);
    let m = menu(&c);
    // Own page is branch 0, then the folders in order: a-third (1), b-second (2); the menu
    // follows the tabs because `order` ties.
    has(
        m,
        &[
            "static const List<NavNode> tree = [_nav1, _nav2, _nav3];",
            "folder: '(tabs)',\n  nav: _i2.nav,\n  route: _navRoute1,\n  flat: true,\n  tabs: {'(tabs)': 0},",
            "folder: '(tabs)/a-third',\n  nav: _i4.nav,\n  route: _navRoute2,\n  tabs: {'(tabs)': 1},",
            "folder: '(tabs)/b-second',\n  nav: _i6.nav,\n  route: _navRoute3,\n  tabs: {'(tabs)': 2},",
        ],
    );
}

#[test]
fn a_nested_tab_layout_adds_its_own_index() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/home/page.dart", &page("Home")),
        ("(tabs)/home/nav.dart", NAV),
        ("(tabs)/library/layout.dart", INNER),
        ("(tabs)/library/nav.dart", NAV),
        ("(tabs)/library/books/page.dart", &page("Books")),
        ("(tabs)/library/books/nav.dart", NAV),
        ("(tabs)/library/authors/page.dart", &page("Authors")),
        ("(tabs)/library/authors/nav.dart", NAV),
    ]);
    let m = menu(&c);
    has(
        m,
        &[
            "tabs: {'(tabs)': 1},",
            "folder: '(tabs)/library/authors',",
            "tabs: {'(tabs)/library': 0},",
            "tabs: {'(tabs)/library': 1},",
        ],
    );
}

#[test]
fn an_entry_with_segments_is_in_the_routes_that_have_them() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        ("items/$id/nav.dart", NAV),
        ("items/$id/more/page.dart", &page("More")),
        ("items/$id/more/nav.dart", NAV),
        ("other/page.dart", &page("Other")),
    ]);
    let m = menu(&c);
    has(
        m,
        &[
            "const _within2 = <Type>[ItemRoute, MoreRoute];",
            "route: _navRoute2,\n  within: _within2,",
            "route: _navRoute3,\n  within: _within2,",
            "TypedLocation _navRoute2(Map<String, Object?> p) => ItemRoute(id: p['id'] as int);",
        ],
    );
    // One list for both.
    assert_eq!(m.matches("const _within").count(), 1, "{m}");
}

#[test]
fn the_trails_are_the_entries_above_each_page() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("nav.dart", NAV),
        ("a/page.dart", &page("A")),
        ("a/nav.dart", NAV),
        ("a/b/page.dart", &page("B")),
        ("(g)/c/page.dart", &page("C")),
        ("(g)/c/nav.dart", NAV),
    ]);
    has(
        menu(&c),
        &[
            "HomeRoute: [_nav0],",
            "CRoute: [_nav0, _nav2],",
            "ARoute: [_nav0, _nav3],",
            "BRoute: [_nav0, _nav3],",
        ],
    );
}

#[test]
fn a_route_with_no_entry_above_it_has_no_trail() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("a/page.dart", &page("A")),
        ("a/nav.dart", NAV),
        ("b/page.dart", &page("B")),
    ]);
    let m = menu(&c);
    has(m, &["ARoute: [_nav1],"]);
    has_not(m, &["HomeRoute:", "BRoute:"]);
}

#[test]
fn a_route_that_leaves_its_page_keeps_the_entries_of_its_folders() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("orders/$id/page.dart", &item()),
        ("orders/$id/nav.dart", NAV),
        ("orders/$id/refund/route.dart", "const nest = false;"),
        ("orders/$id/refund/page.dart", &page("Refund")),
        ("orders/$id/refund/nav.dart", NAV),
    ]);
    has(menu(&c), &["RefundRoute: [_nav2, _nav3],"]);
}

#[test]
fn a_label_function_gets_the_segments_it_asks_for() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        ("items/$id/nav.dart", NAV),
        (
            "items/$id/nav.dart",
            "const nav = Nav(label: 'Item'); String label(BuildContext context, {required int id}) => 'Item $id';",
        ),
        ("plain/page.dart", &page("Plain")),
        (
            "plain/nav.dart",
            "const nav = Nav(label: 'Plain'); String label(BuildContext context) => 'Plain';",
        ),
    ]);
    let m = menu(&c);
    has(
        m,
        &[
            "label: _navLabel2,",
            "String _navLabel2(BuildContext context, Map<String, Object?> p) =>\n    _i2.label(context, id: p['id'] as int);",
            "String _navLabel3(BuildContext context, Map<String, Object?> p) => _i4.label(context);",
        ],
    );
}

#[test]
fn a_label_function_types_the_segment_like_any_other_file() {
    let d = diags(&[
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
        (
            "items/$id/nav.dart",
            "const nav = Nav(label: 'Item'); String label(BuildContext context, {required String id}) => id;",
        ),
    ]);
    assert!(
        d.iter()
            .any(|m| m.contains("`$id` is") && m.contains("int") && m.contains("String")),
        "{d:?}"
    );
}

const GUARD_REF: &str = "GuardResult guard(Ref ref, {required Uri uri}) => null;";

#[test]
fn a_ref_guard_is_asked_with_the_entrys_location() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("(members)/guard.dart", GUARD_REF),
        ("(members)/inbox/page.dart", &page("Inbox")),
        ("(members)/inbox/nav.dart", NAV),
    ]);
    has(
        menu(&c),
        &[
            "guard: _navGuard2,",
            "GuardResult _navGuard2(Ref ref, TypedLocation route) =>\n    _i1.guard(ref, uri: Uri.parse(route.location));",
        ],
    );
}

#[test]
fn several_guards_run_in_order_until_one_refuses() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("(members)/guard.dart", GUARD_REF),
        ("(members)/admin/page.dart", &page("Admin")),
        (
            "(members)/admin/guard.dart",
            "GuardResult guard(ProviderContainer c) => null;",
        ),
        ("(members)/admin/nav.dart", NAV),
    ]);
    has(
        menu(&c),
        &[
            "GuardResult _navGuard2(Ref ref, TypedLocation route) {\n  return firstRedirect([\n    () => _i1.guard(ref, uri: Uri.parse(route.location)),\n    () => _i3.guard(ref.container),\n  ]);\n}",
        ],
    );
}

#[test]
fn a_guard_that_reads_a_segment_gets_the_routes_field() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "shops/$shop/page.dart",
            "class ShopPage extends StatelessWidget { const ShopPage({super.key, required this.shop}); final String shop; }",
        ),
        (
            "shops/$shop/guard.dart",
            "GuardResult guard(ProviderContainer c, {required String shop}) => null;",
        ),
        ("shops/$shop/nav.dart", NAV),
    ]);
    has(
        menu(&c),
        &[
            "GuardResult _navGuard2(Ref ref, TypedLocation route) {\n  final r = route as ShopRoute;\n  return _i2.guard(ref.container, shop: r.shop);\n}",
        ],
    );
}

#[test]
fn a_guards_query_and_extra_are_empty() {
    let c = code(&[
        ("page.dart", &page("Home")),
        (
            "a/guard.dart",
            "GuardResult guard(Ref ref, {String? from, List<String> tags = const [], Object? extra}) => null;",
        ),
        ("a/page.dart", &page("A")),
        ("a/nav.dart", NAV),
    ]);
    has(
        menu(&c),
        &["_i2.guard(ref, from: null, tags: const [], extra: null)"],
    );
}

#[test]
fn guards_are_those_of_the_folder_and_above_not_of_its_siblings() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("a/guard.dart", GUARD_REF),
        ("a/page.dart", &page("A")),
        ("a/nav.dart", NAV),
        ("b/page.dart", &page("B")),
        ("b/nav.dart", NAV),
    ]);
    let m = menu(&c);
    has(m, &["_navGuard1"]);
    has_not(m, &["_navGuard3"]);
}

#[test]
fn nav_dart_diagnostics() {
    let with = |nav_src: &str| {
        diags(&[
            ("page.dart", &page("Home")),
            ("a/page.dart", &page("A")),
            ("a/nav.dart", nav_src),
        ])
    };
    assert_eq!(
        with("final x = 1;"),
        vec!["✗ a/nav.dart  expected `const nav = Nav(label: '...');`"]
    );
    assert_eq!(
        with("const nav = Nav(label: 'A');\nconst nav = Nav(label: 'B');"),
        vec!["✗ a/nav.dart:2  `nav` is declared twice"]
    );
    assert_eq!(
        with("final nav = Nav(label: 'A');"),
        vec![
            "✗ a/nav.dart:1  `nav` must be `const` (AppMenu lists it in a const tree): write `const nav = Nav(...);`"
        ]
    );
    assert_eq!(
        with("const nav = Other(label: 'A');"),
        vec![
            "✗ a/nav.dart:1  `nav` must be a `Nav(...)` call, so fsp can read its `order`: `const nav = Nav(label: 'Products', order: 1);`"
        ]
    );
    assert_eq!(
        with("const nav = Nav(label: 'A', order: 1.5);"),
        vec![
            "✗ a/nav.dart:1  `order` must be a whole-number literal, like `order: 2`: fsp sorts the menu with it"
        ]
    );
    assert_eq!(
        with("const o = 1;\nconst nav = Nav(label: 'A', order: o);"),
        vec![
            "✗ a/nav.dart:2  `order` must be a whole-number literal, like `order: 2`: fsp sorts the menu with it"
        ]
    );
    assert_eq!(
        with("const nav = Nav(label: 'A');\nint label(BuildContext context) => 1;"),
        vec![
            "✗ a/nav.dart:2  label() must return a String: `String label(BuildContext context) => ...`"
        ]
    );
    assert_eq!(
        with("const nav = Nav(label: 'A');\nString label() => 'A';"),
        vec![
            "✗ a/nav.dart:2  label() must take `BuildContext context` first: the menu calls it while it builds"
        ]
    );
    assert_eq!(
        with(
            "const nav = Nav(label: 'A');\nString label(BuildContext context, {required int id}) => 'A';"
        ),
        vec![
            "✗ a/nav.dart:2  label() gets no segments here (this folder and the ones above it have none); remove `id`"
        ]
    );
}

#[test]
fn label_segment_diagnostics() {
    let with = |label: &str| {
        diags(&[
            ("page.dart", &page("Home")),
            ("items/$id/page.dart", &item()),
            (
                "items/$id/nav.dart",
                &format!("const nav = Nav(label: 'A');\n{label}"),
            ),
        ])
    };
    assert_eq!(
        with("String label(BuildContext context, {required int nope}) => 'A';"),
        vec![
            "✗ items/$id/nav.dart:2  label() can ask for the segments of its folder and above ($id); `nope` is none of them"
        ]
    );
    assert_eq!(
        with("String label(BuildContext context, {int id = 1}) => 'A';"),
        vec![
            "✗ items/$id/nav.dart:2  `id` must be `required`: a menu entry always has its segments"
        ]
    );
    assert_eq!(
        with("String label(BuildContext context, int id) => 'A';"),
        vec![
            "✗ items/$id/nav.dart:2  label() takes segments as named parameters, e.g. `{required int id}`"
        ]
    );
    assert!(with("String label(BuildContext context, {required int id}) => 'A';").is_empty());
}

#[test]
fn routes_json_says_it_only_for_a_folder_with_a_nav_dart() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("a/page.dart", &page("A")),
        ("a/nav.dart", "const nav = Nav(label: 'Alpha', order: 3);"),
        ("b/page.dart", &page("B")),
        ("b/nav.dart", "const l = 'x';\nconst nav = Nav(label: l);"),
    ]);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let rows: Vec<serde_json::Value> = routes::json_lines(&app, "lib/app")
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |pattern: &str| rows.iter().find(|r| r["pattern"] == pattern).unwrap();
    assert_eq!(
        by("/a")["nav"],
        serde_json::json!({"file": "lib/app/a/nav.dart", "label": "Alpha", "order": 3})
    );
    assert_eq!(by("/b")["nav"]["label"], serde_json::Value::Null);
    assert!(by("/").get("nav").is_none());
    // The key comes last: the rows of an app without a nav.dart are as they were.
    let line = routes::json_lines(&app, "lib/app")
        .into_iter()
        .find(|l| l.contains("\"/a\""))
        .unwrap();
    assert!(line.trim_end().ends_with("\"order\":3}}"), "{line}");
}

#[test]
fn new_nav_writes_a_label_from_the_folder() {
    let dir = project(&[("page.dart", &page("Home"))]);
    for (route, label) in [
        ("orders", "Orders"),
        ("gift-cards", "Gift cards"),
        ("shops/[shop]", "Shop"),
        ("(account)", "Account"),
    ] {
        let args = scaffold::NewArgs {
            route: route.into(),
            name: None,
            function: false,
            data: false,
            action: false,
            loading: false,
            error: false,
            layout: false,
            not_found: false,
            guard: false,
            transition: false,
            observe: false,
            nav: true,
        };
        let created = scaffold::new_route(dir.path(), &args).unwrap();
        let nav_file = created.iter().find(|f| f.ends_with("nav.dart")).unwrap();
        let written = fs::read_to_string(dir.path().join(nav_file)).unwrap();
        assert_eq!(
            written,
            format!(
                "import 'package:fespalier/nav.dart';\n\n/// How this folder shows in the menus `fsp` generates (`AppMenu`).\nconst nav = Nav(label: '{label}');\n"
            ),
            "{route}"
        );
    }
}
