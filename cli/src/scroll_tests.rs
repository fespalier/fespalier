//! `scroll_restoration`: each page's view is wrapped in `RouteScrollMemory(state: state, ...)`,
//! the per-history-entry `PageStorage` the runtime hands back when the browser brings an entry
//! back. Layouts and redirects are not pages, so they are left alone. With the key off, nothing
//! changes.

use std::fs;

use crate::build;
use crate::config::{Config, Pubspec};

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

fn on() -> Config {
    Config {
        scroll_restoration: true,
        ..Config::default()
    }
}

fn code_with(cfg: &Config, files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn scroll(files: &[(&str, &str)]) -> String {
    code_with(&on(), files)
}

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

fn lacks(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

fn config(yaml: &str) -> anyhow::Result<Config> {
    Ok(Pubspec::parse(yaml)?.config)
}

fn widget(name: &str, fields: &str, params: &str) -> String {
    format!(
        "class {name} extends StatelessWidget {{ const {name}({{super.key{params}}}); {fields} }}"
    )
}

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";
const FADE: &str =
    "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";

/// How many pages are wrapped.
fn wrapped(code: &str) -> usize {
    code.matches("RouteScrollMemory(\n").count()
}

#[test]
fn a_plain_page_is_wrapped() {
    let c = scroll(&[("page.dart", HOME)]);
    has(
        &c,
        &[
            "builder: (context, state) => RouteScrollMemory(\n",
            "state: state,\n",
            "child: const _i0.HomePage(),\n",
        ],
    );
    // The page keeps its own `const`; the wrapper is not const (it takes the runtime `state`).
    lacks(&c, &["const RouteScrollMemory"]);
    assert_eq!(wrapped(&c), 1, "{c}");
}

#[test]
fn a_data_page_is_wrapped_around_data_view() {
    let c = scroll(&[
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
    ]);
    let memory = c.find("RouteScrollMemory(").unwrap();
    let view = c.find("DataView(").unwrap();
    assert!(memory < view, "{c}");
    has(&c, &["data: (d) => _i1.APage(n: d),"]);
    assert_eq!(wrapped(&c), 1, "{c}");
}

#[test]
fn a_deferred_page_is_wrapped_around_deferred_view() {
    let c = scroll(&[
        ("page.dart", HOME),
        ("c/page.dart", &widget("CPage", "", "")),
        ("c/route.dart", "const deferred = true;"),
    ]);
    let view = c.find("child: DeferredView(").unwrap();
    assert!(c[..view].rfind("RouteScrollMemory(").is_some(), "{c}");
    assert_eq!(wrapped(&c), 2, "{c}");
}

#[test]
fn a_page_with_segments_is_wrapped_around_build_with_params() {
    let c = scroll(&[(
        "products/$id/page.dart",
        &widget("ProductPage", "final int id;", ", required this.id"),
    )]);
    let memory = c.find("RouteScrollMemory(").unwrap();
    let params = c.find("buildWithParams(").unwrap();
    assert!(memory < params, "{c}");
    has(&c, &["(v) => _i0.ProductPage(id: v.id),"]);
}

#[test]
fn a_remount_page_is_wrapped_inside_the_remount_key() {
    let c = scroll(&[
        ("page.dart", HOME),
        (
            "c/$id/page.dart",
            &widget("CPage", "final int id;", ", required this.id"),
        ),
        ("c/$id/route.dart", "const remount = Remount.onSegments;"),
    ]);
    // The key belongs to the page the router builds; the wrapper is the child it gets.
    let page = c.find("remountPage(").unwrap();
    let key = c.find("remountKey(state, Remount.onSegments").unwrap();
    let memory = c[key..].find("RouteScrollMemory(").unwrap() + key;
    assert!(page < key && key < memory, "{c}");
    assert_eq!(wrapped(&c), 2, "{c}");
}

#[test]
fn a_transition_receives_the_wrapped_page() {
    let c = scroll(&[("transition.dart", FADE), ("page.dart", HOME)]);
    let transition = c.find("_i1.transition(").unwrap();
    let memory = c.find("RouteScrollMemory(").unwrap();
    assert!(transition < memory, "{c}");
    has(&c, &["child: const _i0.HomePage(),"]);
}

#[test]
fn a_page_in_a_tab_is_wrapped_and_the_layout_is_not() {
    let c = scroll(&[
        (
            "layout.dart",
            "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }",
        ),
        ("page.dart", HOME),
        ("search/page.dart", &widget("SearchPage", "", "")),
    ]);
    has(&c, &["StatefulShellRoute.indexedStack("]);
    assert_eq!(wrapped(&c), 2, "{c}");
}

#[test]
fn layouts_and_redirects_are_not_wrapped() {
    let c = scroll(&[
        ("page.dart", HOME),
        (
            "layout.dart",
            "class RootLayout extends StatelessWidget { const RootLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    assert_eq!(wrapped(&c), 1, "{c}");
}

#[test]
fn a_not_found_view_is_not_wrapped() {
    let c = scroll(&[
        ("page.dart", HOME),
        ("not_found.dart", &widget("Missing", "", "")),
    ]);
    assert_eq!(wrapped(&c), 1, "{c}");
}

#[test]
fn off_by_default_changes_nothing() {
    let files = [
        ("page.dart", HOME),
        (
            "products/$id/page.dart",
            &widget("ProductPage", "final int id;", ", required this.id"),
        ),
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
    ];
    let dir = project(&files);
    let built = |dir: &tempfile::TempDir| {
        let cfg = Config::load(dir.path()).unwrap();
        build(&dir.path().join("lib/app"), &cfg).unwrap().0
    };
    let off = built(&dir);
    lacks(&off, &["RouteScrollMemory", "scroll_restoration"]);
    // The key set to `false` is the same file, byte for byte.
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  scroll_restoration: false\n",
    )
    .unwrap();
    assert_eq!(built(&dir), off);
}

#[test]
fn scroll_restoration_parses_and_defaults_to_off() {
    assert!(!Config::default().scroll_restoration);
    assert!(!config("name: demo\n").unwrap().scroll_restoration);
    assert!(
        !config("fespalier:\n  format: true\n")
            .unwrap()
            .scroll_restoration
    );
    assert!(
        config("fespalier:\n  scroll_restoration: true\n")
            .unwrap()
            .scroll_restoration
    );
    let c = config("fespalier:\n  scroll_restoration: false\n").unwrap();
    assert_eq!(c, Config::default());
}

#[test]
fn scroll_restoration_rejects_other_values() {
    let e = format!(
        "{:#}",
        config("fespalier:\n  scroll_restoration: sometimes\n").unwrap_err()
    );
    assert!(
        e.contains(
            "fespalier.scroll_restoration: invalid type: string \"sometimes\", expected a boolean"
        ),
        "{e}"
    );
    // The unknown-key message lists it, so a misspelling points at the right name.
    let e = format!(
        "{:#}",
        config("fespalier:\n  scroll_restore: true\n").unwrap_err()
    );
    assert!(
        e.contains("unknown field `scroll_restore`") && e.contains("`scroll_restoration`"),
        "{e}"
    );
}

#[test]
fn the_pubspec_key_reaches_the_generated_file() {
    let dir = project(&[("page.dart", HOME)]);
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  scroll_restoration: true\n",
    )
    .unwrap();
    crate::gen_with(dir.path(), &Config::load(dir.path()).unwrap(), true).unwrap();
    let c = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(&c, &["RouteScrollMemory(", "state: state,"]);
}
