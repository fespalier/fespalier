//! Per-folder `caseSensitive`: a `route.dart` with `const caseSensitive = false;` applies to
//! its folder and everything below it, and the nearest one wins over the pubspec's
//! `case_sensitive`. (The pubspec option itself is tested in `paths_tests.rs`.)

use std::fs;

use crate::build;
use crate::config::Config;

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

fn diags_with(cfg: &Config, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    diags_with(&Config::default(), files)
        .into_iter()
        .filter(|d| d.starts_with('✗'))
        .collect()
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

fn insensitive() -> Config {
    Config {
        case_sensitive: false,
        ..Config::default()
    }
}

/// The `GoRoute` with this path: from `path: <path>,` to the next route's.
fn route<'c>(code: &'c str, path: &str) -> &'c str {
    let start = code
        .find(&format!("path: {path},"))
        .unwrap_or_else(|| panic!("no route {path} in:\n{code}"));
    let rest = &code[start..];
    let end = rest[1..].find("GoRoute(").map_or(rest.len(), |i| i + 1);
    &rest[..end]
}

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

fn is_insensitive(code: &str, path: &str) -> bool {
    // Before its builder: a route's own `caseSensitive:` sits right below its `path:`.
    let r = route(code, path);
    r[..r.find("uilder").unwrap_or(r.len())].contains("caseSensitive: false,")
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn page_with(name: &str, params: &str, fields: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, {params}}}); {fields} }}"
    )
}

const OFF: &str = "const caseSensitive = false;\n";
const ON: &str = "const caseSensitive = true;\n";

const NOT_FOUND: &str = "class NotFoundPage extends StatelessWidget { const NotFoundPage({super.key, required this.uri}); final Uri uri; }";

#[test]
fn a_route_dart_makes_its_folder_and_everything_below_it_case_insensitive() {
    let c = code(&[
        ("about/page.dart", &page("About")),
        ("shop/route.dart", OFF),
        ("shop/page.dart", &page("Shop")),
        ("shop/cart/page.dart", &page("Cart")),
        (
            "shop/items/$id/page.dart",
            &page_with("Item", "required this.id", "final String id;"),
        ),
    ]);
    // Nested routes are relative paths, so each one carries the flag of its own folder.
    assert!(is_insensitive(&c, "joinLocation(at, '/shop')"), "{c}");
    assert!(is_insensitive(&c, "'cart'"), "{c}");
    assert!(
        is_insensitive(&c, "'items/:id'") || is_insensitive(&c, "'items'"),
        "{c}"
    );
    assert!(!is_insensitive(&c, "joinLocation(at, '/about')"), "{c}");
    // Siblings keep the default: exactly the three shop routes carry the flag.
    assert_eq!(c.matches("caseSensitive: false,").count(), 3, "{c}");
}

#[test]
fn without_one_the_pubspec_decides_and_a_route_dart_can_turn_it_back_on() {
    let files = [
        ("about/page.dart", page("About")),
        ("files/route.dart", ON.to_string()),
        ("files/page.dart", page("Files")),
        ("files/a/page.dart", page("A")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(p, b)| (*p, b.as_str())).collect();
    let c = code_with(&insensitive(), &files);
    assert!(is_insensitive(&c, "joinLocation(at, '/about')"), "{c}");
    assert!(!is_insensitive(&c, "joinLocation(at, '/files')"), "{c}");
    assert!(!is_insensitive(&c, "'a'"), "{c}");
    assert_eq!(c.matches("caseSensitive: false,").count(), 1, "{c}");
}

#[test]
fn the_nearest_route_dart_wins() {
    let c = code(&[
        ("route.dart", OFF),
        ("page.dart", &page("Home")),
        ("admin/route.dart", ON),
        ("admin/page.dart", &page("Admin")),
        ("admin/tools/page.dart", &page("Tools")),
        ("admin/tools/deep/route.dart", OFF),
        ("admin/tools/deep/page.dart", &page("Deep")),
        ("blog/page.dart", &page("Blog")),
    ]);
    let flags: Vec<(&str, bool)> = [
        ("joinLocation(at, '/')", true),
        ("'admin'", false),
        ("'tools'", false),
        ("'deep'", true),
        ("'blog'", true),
    ]
    .into_iter()
    .map(|(p, insensitive)| (p, insensitive == is_insensitive(&c, p)))
    .collect();
    assert!(flags.iter().all(|(_, ok)| *ok), "{flags:?}\n{c}");
}

#[test]
fn a_group_and_a_folder_without_a_page_pass_it_on() {
    let c = code(&[
        ("(shop)/route.dart", OFF),
        ("(shop)/cart/page.dart", &page("Cart")),
        ("(shop)/pay/page.dart", &page("Pay")),
        ("docs/route.dart", OFF),
        ("docs/guide/page.dart", &page("Guide")),
        ("other/page.dart", &page("Other")),
    ]);
    for p in ["'/cart'", "'/pay'", "'/docs/guide'", "'/other'"] {
        let want = !p.contains("other");
        assert_eq!(
            is_insensitive(&c, &format!("joinLocation(at, {p})")),
            want,
            "{p}\n{c}"
        );
    }
}

#[test]
fn a_route_is_matched_as_one_path_so_the_deepest_folder_decides_for_all_of_it() {
    // `docs/` has no page, so `docs/Guide` is one GoRoute (`/docs/Guide`): go_router has a
    // single flag for it, and it is the flag of the folder that holds the page.
    let c = code(&[
        ("docs/route.dart", OFF),
        ("docs/Guide/route.dart", ON),
        ("docs/Guide/page.dart", &page("Guide")),
        ("docs/faq/page.dart", &page("Faq")),
    ]);
    assert!(
        !is_insensitive(&c, "joinLocation(at, '/docs/Guide')"),
        "{c}"
    );
    assert!(is_insensitive(&c, "joinLocation(at, '/docs/faq')"), "{c}");
}

#[test]
fn an_optional_catch_all_and_a_redirect_carry_the_flag_too() {
    let files = page_with("Files", "this.path = const []", "final List<String> path;");
    let c = code(&[
        ("route.dart", OFF),
        ("files/$$$path/page.dart", &files),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    // `/files` and `/files/:path(.+)`, and the redirect.
    for p in [
        "joinLocation(at, '/files')",
        "joinLocation(at, '/files/:path(.+)')",
        "joinLocation(at, '/old')",
    ] {
        assert!(is_insensitive(&c, p), "{p}\n{c}");
    }
}

#[test]
fn a_tab_layout_holds_routes_that_keep_their_own_flag() {
    let layout = "const tabs = ['a', 'b'];\nclass TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";
    let c = code(&[
        ("(tabs)/layout.dart", layout),
        ("(tabs)/a/route.dart", OFF),
        ("(tabs)/a/page.dart", &page("A")),
        ("(tabs)/b/page.dart", &page("B")),
    ]);
    assert!(is_insensitive(&c, "joinLocation(at, '/a')"), "{c}");
    assert!(!is_insensitive(&c, "joinLocation(at, '/b')"), "{c}");
}

#[test]
fn not_found_scopes_compare_their_folder_by_its_own_setting() {
    let c = code(&[
        ("not_found.dart", NOT_FOUND),
        ("page.dart", &page("Home")),
        ("shop/route.dart", OFF),
        ("shop/not_found.dart", NOT_FOUND),
        ("shop/page.dart", &page("Shop")),
        ("shop/$id/not_found.dart", NOT_FOUND),
        (
            "shop/$id/page.dart",
            &page_with("Item", "required this.id", "final int id;"),
        ),
        ("help/not_found.dart", NOT_FOUND),
        ("help/page.dart", &page("Help")),
        ("shop/strict/route.dart", ON),
        ("shop/strict/not_found.dart", NOT_FOUND),
        ("shop/strict/page.dart", &page("Strict")),
    ]);
    has(
        &c,
        &[
            "(['shop', 'strict'], (uri) => _i",
            "(['shop', ':id'], (uri) => _i",
            "(['help'], (uri) => _i",
        ],
    );
    // Each scope says how its own prefix is compared.
    for (prefix, case_sensitive) in [
        ("['shop', 'strict']", true),
        ("['shop', ':id']", false),
        ("['shop']", false),
        ("['help']", true),
    ] {
        let line = c
            .lines()
            .find(|l| l.trim_start().starts_with(&format!("({prefix},")))
            .unwrap_or_else(|| panic!("{prefix} in:\n{c}"));
        assert!(
            line.ends_with(&format!("caseSensitive: {case_sensitive}),")),
            "{line}"
        );
    }
    // The root's own setting (its route.dart, else the config) compares the mount point.
    assert!(
        !c.contains("        caseSensitive: false,\n      );"),
        "{c}"
    );
}

#[test]
fn a_root_route_dart_decides_the_mount_point_comparison() {
    let files = [
        ("route.dart", OFF),
        ("page.dart", &page("Home")[..]),
        ("a/not_found.dart", NOT_FOUND),
        ("a/page.dart", &page("A")[..]),
    ];
    let files: Vec<(&str, &str)> = files.to_vec();
    let c = code(&files);
    assert!(c.contains("        caseSensitive: false,\n      );"), "{c}");
    // ...over the config, either way.
    let mut on: Vec<(&str, &str)> = files.clone();
    on[0] = ("route.dart", ON);
    let c = code_with(&insensitive(), &on);
    assert!(
        !c.contains("        caseSensitive: false,\n      );"),
        "{c}"
    );
    assert!(
        c.contains("(['a'], (uri) => _i") && c.contains("caseSensitive: true),"),
        "{c}"
    );
}

#[test]
fn route_dart_is_read_not_imported() {
    let c = code(&[("route.dart", OFF), ("page.dart", &page("Home"))]);
    assert!(!c.contains("route.dart"), "{c}");
}

#[test]
fn a_route_dart_can_sit_in_a_folder_of_its_own() {
    // A folder that only says how the folders below are matched: not a warning.
    let c = code(&[
        ("(legacy)/route.dart", OFF),
        ("(legacy)/a/page.dart", &page("A")),
    ]);
    assert!(is_insensitive(&c, "joinLocation(at, '/a')"), "{c}");
}

#[test]
fn it_must_be_a_bool_literal() {
    for (body, why) in [
        ("const caseSensitive = 'false';", "a string"),
        ("const caseSensitive = 0;", "a number"),
        ("const caseSensitive = !true;", "an expression"),
        ("const caseSensitive = kStrict;", "another constant"),
        ("const caseSensitive = null;", "null"),
    ] {
        let e = errors(&[("shop/route.dart", body), ("shop/page.dart", &page("Shop"))]);
        assert!(
            e.iter().any(|m| m.starts_with("✗ shop/route.dart:1  ")),
            "{why}: {e:?}"
        );
        assert!(
            e.iter().any(
                |m| m.contains("`caseSensitive` must be a `true` or `false` literal")
                    || m.contains("expected `const caseSensitive")
            ),
            "{why}: {e:?}"
        );
    }
    // `final` and a declared type are still literals.
    for body in [
        "final caseSensitive = false;",
        "const bool caseSensitive = false;",
    ] {
        assert!(
            errors(&[("shop/route.dart", body), ("shop/page.dart", &page("Shop"))]).is_empty(),
            "{body}"
        );
    }
}

#[test]
fn a_route_dart_without_the_constant_is_an_error() {
    let e = errors(&[
        ("shop/route.dart", "const other = true;"),
        ("shop/page.dart", &page("Shop")),
    ]);
    assert_eq!(
        e,
        [
            "✗ shop/route.dart  expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;`, `const deferred = true;` or `const freshness = Freshness(staleTime: Duration(minutes: 5));`"
        ]
    );
    // A getter isn't a constant: the generator can't read its value.
    for body in ["", "bool get caseSensitive => false;"] {
        let e = errors(&[("shop/route.dart", body), ("shop/page.dart", &page("Shop"))]);
        assert_eq!(e.len(), 1, "{e:?}");
    }
}

#[test]
fn declaring_it_twice_is_an_error_at_the_second() {
    let e = errors(&[
        (
            "shop/route.dart",
            "const caseSensitive = false;\nconst caseSensitive = true;",
        ),
        ("shop/page.dart", &page("Shop")),
    ]);
    assert_eq!(
        e,
        ["✗ shop/route.dart:2  `caseSensitive` is declared twice"]
    );
}

#[test]
fn a_bad_route_dart_leaves_the_setting_it_would_have_overridden() {
    // The error stops the generator anyway; what is left is the inherited value, not a guess.
    let dir = project(&[
        ("shop/route.dart", "const caseSensitive = maybe;"),
        ("shop/page.dart", &page("Shop")),
    ]);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &insensitive()).unwrap();
    assert!(diags.has_errors());
    assert!(is_insensitive(&code, "joinLocation(at, '/shop')"), "{code}");
}
