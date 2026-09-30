//! Navigation: nested tab layouts and per-tab options.

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

fn diags(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags.0.iter().map(|d| d.to_string()).collect()
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

fn at(code: &str, needle: &str) -> usize {
    code.find(needle)
        .unwrap_or_else(|| panic!("missing `{needle}` in:\n{code}"))
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

const TABS: &str = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";

const INNER: &str = "class InnerLayout extends StatelessWidget { const InnerLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }";

#[test]
fn a_tab_layout_nests_in_a_branch_of_another() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/(home)/page.dart", HOME),
        ("(tabs)/library/layout.dart", INNER),
        ("(tabs)/library/books/page.dart", &page("Books")),
        ("(tabs)/library/authors/page.dart", &page("Authors")),
    ]);
    has(
        &c,
        &[
            "_i0.TabsLayout(navigationShell: navigationShell),",
            "_i2.InnerLayout(shell: navigationShell),",
            "path: joinLocation(at, '/library/authors'),",
            "path: joinLocation(at, '/library/books'),",
        ],
    );
    // The outer shell has two branches, the inner one two more inside the second.
    assert_eq!(
        c.matches("StatefulShellRoute.indexedStack(").count(),
        2,
        "{c}"
    );
    assert_eq!(c.matches("StatefulShellBranch(").count(), 4, "{c}");
    assert!(at(&c, "_i0.TabsLayout") < at(&c, "_i2.InnerLayout"), "{c}");
    // The inner shell is the whole of the outer branch it sits in.
    let inner = at(&c, "_i2.InnerLayout");
    assert!(
        c[..inner].rfind("StatefulShellBranch(").unwrap() > at(&c, "'/'),"),
        "{c}"
    );
}

#[test]
fn a_nested_tab_layout_can_sit_in_a_group_below_a_page() {
    // library/page.dart is a GoRoute; the inner tabs are its child routes, so
    // their paths are relative to it.
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/(home)/page.dart", HOME),
        ("(tabs)/library/page.dart", &page("Library")),
        ("(tabs)/library/(sub)/layout.dart", INNER),
        ("(tabs)/library/(sub)/books/page.dart", &page("Books")),
        ("(tabs)/library/(sub)/authors/page.dart", &page("Authors")),
    ]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/library'),",
            "path: 'books',",
            "path: 'authors',",
        ],
    );
    assert_eq!(
        c.matches("StatefulShellRoute.indexedStack(").count(),
        2,
        "{c}"
    );
}

#[test]
fn a_nested_tab_layout_has_its_own_tabs_list_and_start_check() {
    let inner = format!("const tabs = ['books', 'authors'];\n{INNER}");
    let c = code(&[
        ("layout.dart", TABS),
        ("library/layout.dart", &inner),
        ("library/authors/page.dart", &page("Authors")),
        ("library/books/page.dart", &page("Books")),
    ]);
    assert!(
        at(&c, "'/library/books'),") < at(&c, "'/library/authors'),"),
        "{c}"
    );

    // An inner tab made only of a dynamic route has no place to start, like an outer one.
    let e = diags(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("library/layout.dart", INNER),
        ("library/books/page.dart", &page("Books")),
        ("library/$id/page.dart", &page("Item")),
    ]);
    assert!(
        e.iter().any(
            |m| m.contains("library/$id/page.dart:1  /library/:id is the first route of a tab")
        ),
        "{e:?}"
    );
    // A dynamic route below a static one is fine.
    let e = diags(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("library/layout.dart", INNER),
        ("library/books/page.dart", &page("Books")),
        ("library/books/$id/page.dart", &page("Book")),
    ]);
    assert!(e.is_empty(), "{e:?}");

    let e = diags(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        (
            "library/layout.dart",
            &format!("const tabs = ['books', 'nope'];\n{INNER}"),
        ),
        ("library/books/page.dart", &page("Books")),
    ]);
    assert_eq!(
        e,
        vec![
            "✗ library/layout.dart:1  `tabs` lists `nope`, which is not a branch here; the branches are `books`"
        ]
    );
}

// --- tab options -------------------------------------------------------------

const OPTS_FILES: [(&str, &str); 3] = [
    (
        "home/page.dart",
        "class HomePage extends StatelessWidget { const HomePage({super.key}); }",
    ),
    (
        "search/page.dart",
        "class SearchPage extends StatelessWidget { const SearchPage({super.key}); }",
    ),
    (
        "profile/edit/page.dart",
        "class EditPage extends StatelessWidget { const EditPage({super.key}); }",
    ),
];

fn with_options(opts: &str) -> Vec<(String, String)> {
    let mut files: Vec<(String, String)> = OPTS_FILES
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect();
    files.push(("profile/page.dart".into(), page("Profile")));
    files.push(("layout.dart".into(), format!("{opts}\n{TABS}")));
    files
}

fn option_code(opts: &str) -> String {
    let files = with_options(opts);
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(a, b)| (a.as_str(), b.as_str()))
        .collect();
    code(&refs)
}

fn option_diags(opts: &str) -> Vec<String> {
    let files = with_options(opts);
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(a, b)| (a.as_str(), b.as_str()))
        .collect();
    diags(&refs)
}

#[test]
fn tab_options_become_branch_arguments() {
    let c = option_code(
        "const tabOptions = {'search': TabOptions(preload: true), 'profile': const TabOptions(initialLocation: '/profile/edit', preload: true)};",
    );
    // Tabs follow folder order: home, profile, search.
    let (profile, search) = (
        at(&c, "initialLocation: joinLocation"),
        at(&c, "path: joinLocation(at, '/search')"),
    );
    has(
        &c,
        &[
            "StatefulShellBranch(\n            initialLocation: joinLocation(at, '/profile/edit'),\n            preload: true,\n            routes: [",
            "StatefulShellBranch(\n            preload: true,\n            routes: [",
        ],
    );
    assert!(profile < search, "{c}");
    assert_eq!(c.matches("preload: true").count(), 2, "{c}");
    assert_eq!(c.matches("initialLocation: joinLocation").count(), 1, "{c}");
    // No options, nothing extra.
    let plain = option_code("");
    assert!(
        !plain.contains("preload") && !plain.contains("initialLocation: joinLocation"),
        "{plain}"
    );
    // `preload: false` is the default and is left out.
    assert!(
        !option_code("const tabOptions = {'home': TabOptions(preload: false)};")
            .contains("preload")
    );
}

#[test]
fn tab_options_follow_the_tabs_order() {
    let c = option_code(
        "const tabs = ['search', 'profile', 'home'];\nconst tabOptions = {'home': TabOptions(preload: true)};",
    );
    // `home` is now last: its branch is the one with the option.
    assert!(at(&c, "preload: true") > at(&c, "'/profile'"), "{c}");
    assert!(at(&c, "preload: true") < at(&c, "'/home'"), "{c}");
}

#[test]
fn tab_options_are_validated_like_tabs() {
    let e = option_diags("const tabOptions = {'help': TabOptions(preload: true)};");
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  `tabOptions` lists `help`, which is not a branch here; the branches are `home`, `profile`, `search`"
        ]
    );
    let e = option_diags(
        "const tabOptions = {\n'home': TabOptions(),\n'home': TabOptions(preload: true)};",
    );
    assert_eq!(e, vec!["✗ layout.dart:3  `tabOptions` lists `home` twice"]);
    let e = option_diags("const tabOptions = {'home': Other()};");
    assert_eq!(
        e,
        vec!["✗ layout.dart:1  `tabOptions` gives `home` a `Other`; it takes `TabOptions(...)`"]
    );
    let e = option_diags("const tabOptions = {'home': TabOptions(lazy: true)};");
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  `TabOptions` has no `lazy`; it takes `preload` and `initialLocation`"
        ]
    );
    let e = option_diags("const tabOptions = {'home': TabOptions(preload: yes)};");
    assert_eq!(
        e,
        vec!["✗ layout.dart:1  `preload` must be `true` or `false`"]
    );
    let e = option_diags("const tabOptions = {'home': TabOptions(initialLocation: '/a/$b')};");
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  `initialLocation` must be a string literal without `$`, e.g. `'/profile/edit'`"
        ]
    );
    for bad in [
        "const tabOptions = build();",
        "const tabOptions = {'home': TabOptions(true)};",
        "const tabOptions = {home: TabOptions()};",
        "const tabOptions = ['home'];",
    ] {
        let e = option_diags(bad);
        assert_eq!(e.len(), 1, "{bad}: {e:?}");
        assert!(e[0].starts_with("✗ layout.dart:1  `tabOptions` must be a map from tab names to `TabOptions(...)` calls"), "{bad}: {e:?}");
    }
}

#[test]
fn a_tab_initial_location_must_be_a_route_in_that_tab() {
    let e = option_diags("const tabOptions = {'profile': TabOptions(initialLocation: '/search')};");
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  `initialLocation` `/search` is not a route in the `profile` tab; go_router needs one of them: `/profile`, `/profile/edit`"
        ]
    );
    let e = option_diags(
        "const tabOptions = {'profile': TabOptions(initialLocation: 'profile/edit')};",
    );
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  `initialLocation` is an app location and starts with `/`, e.g. `/profile/edit`"
        ]
    );
    // A query or a trailing slash is fine.
    let c = option_code(
        "const tabOptions = {'profile': TabOptions(initialLocation: '/profile/edit?x=1')};",
    );
    has(
        &c,
        &["initialLocation: joinLocation(at, '/profile/edit?x=1'),"],
    );
}

#[test]
fn a_tab_initial_location_can_be_a_dynamic_route_and_starts_the_tab() {
    let item = "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }";
    let files = |opts: &str| {
        let layout = format!("{opts}\n{TABS}");
        diags(&[
            ("layout.dart", &layout),
            ("home/page.dart", &page("Home")),
            ("items/$id/page.dart", item),
        ])
    };
    // The tab has only a dynamic route, which go_router can't open a tab on...
    assert!(
        files("")
            .iter()
            .any(|m| m.contains("is the first route of a tab"))
    );
    // ...unless the tab says where to open.
    assert!(
        files("const tabOptions = {'items': TabOptions(initialLocation: '/items/1')};").is_empty()
    );
}

#[test]
fn tab_options_of_a_nested_layout_are_its_own() {
    let inner = format!(
        "const tabOptions = {{'authors': TabOptions(preload: true), 'books': TabOptions(initialLocation: '/library/books')}};\n{INNER}"
    );
    let c = code(&[
        (
            "layout.dart",
            &format!(
                "const tabOptions = {{'library': TabOptions(initialLocation: '/library/authors')}};\n{TABS}"
            ),
        ),
        ("home/page.dart", HOME),
        ("library/layout.dart", &inner),
        ("library/authors/page.dart", &page("Authors")),
        ("library/books/page.dart", &page("Books")),
    ]);
    assert_eq!(c.matches("initialLocation: joinLocation").count(), 2, "{c}");
    assert_eq!(c.matches("preload: true").count(), 1, "{c}");
    let outer = at(&c, "initialLocation: joinLocation(at, '/library/authors')");
    assert!(
        outer < at(&c, ".InnerLayout(") && at(&c, ".InnerLayout(") < at(&c, "preload: true"),
        "{c}"
    );
    // A location that is in another layout's tab doesn't count for the outer tab's sibling.
    let e = diags(&[
        (
            "layout.dart",
            &format!(
                "const tabOptions = {{'home': TabOptions(initialLocation: '/library/books')}};\n{TABS}"
            ),
        ),
        ("home/page.dart", HOME),
        ("library/layout.dart", INNER),
        ("library/books/page.dart", &page("Books")),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
}

#[test]
fn a_tab_option_string_is_escaped_in_the_output() {
    let c = option_code(
        "const tabOptions = {'profile': TabOptions(initialLocation: '/profile/edit?q=it\\'s')};",
    );
    // (the folder has no such route, but the query part is ignored when matching)
    has(
        &c,
        &["initialLocation: joinLocation(at, '/profile/edit?q=it\\'s'),"],
    );
}
