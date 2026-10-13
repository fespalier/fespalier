//! `semantics_ids`: each page's own widget call wears `Semantics(identifier: 'route:<pattern>')`
//! so Maestro (which reads the semantics tree, never a `Key`) can tell which page is built, and
//! `AppRoutes.mount()` turns the semantics tree on on the web. With the key off, nothing changes.

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
        semantics_ids: true,
        ..Config::default()
    }
}

fn code_with(cfg: &Config, files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn ids(files: &[(&str, &str)]) -> String {
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
const SHEET: &str =
    "Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);";

#[test]
fn a_const_page_stays_const_inside_the_semantics() {
    let c = ids(&[("page.dart", HOME)]);
    has(
        &c,
        &[
            "Semantics(identifier: 'route:/', container: true, explicitChildNodes: true, child: const _i0.HomePage())",
        ],
    );
    // `Semantics` has no const constructor: only the page it wraps is const.
    lacks(&c, &["const Semantics"]);
}

#[test]
fn every_wrapper_keeps_its_pages_text_as_separate_nodes() {
    // `container: true` gives the identifier a node, and without `explicitChildNodes: true` that
    // node merges every descendant with no node of its own (the plain `Text` outside a scroll
    // view) into one label that a screen reader reads as a single block.
    let c = ids(&[
        ("page.dart", HOME),
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
        (
            "products/$id/page.dart",
            &widget("ProductPage", "final int id;", ", required this.id"),
        ),
    ]);
    let wrappers = c.matches("Semantics(identifier:").count();
    assert_eq!(wrappers, 3, "{c}");
    assert_eq!(
        c.matches("', container: true, explicitChildNodes: true, child: ")
            .count(),
        wrappers,
        "{c}"
    );
    lacks(&c, &["container: false", "explicitChildNodes: false"]);
}

#[test]
fn a_page_with_segments_is_wrapped_inside_build_with_params() {
    let c = ids(&[(
        "products/$id/page.dart",
        &widget("ProductPage", "final int id;", ", required this.id"),
    )]);
    has(
        &c,
        &[
            "(v) => Semantics(identifier: 'route:/products/:id', container: true, explicitChildNodes: true, child: _i0.ProductPage(id: v.id))",
        ],
    );
    lacks(&c, &["const Semantics"]);
}

#[test]
fn a_data_page_is_wrapped_inside_data_view() {
    let c = ids(&[
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
    ]);
    has(
        &c,
        &[
            "data: (d) => Semantics(identifier: 'route:/a', container: true, explicitChildNodes: true, child: _i1.APage(n: d))",
            "loading: () => const DefaultLoading(),",
            "error: (e, st, retry) => DefaultError(error: e, retry: retry),",
        ],
    );
    // Only the page itself wears it: not the loading and the error view.
    assert_eq!(c.matches("Semantics(identifier:").count(), 1, "{c}");
}

#[test]
fn a_custom_loading_view_does_not_wear_it() {
    let c = ids(&[
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
        ("a/loading.dart", &widget("ALoading", "", "")),
        ("a/error.dart", &widget("AError", "", "")),
    ]);
    assert_eq!(c.matches("Semantics(identifier:").count(), 1, "{c}");
    has(&c, &["loading: () => const _i2.ALoading(),"]);
}

#[test]
fn section_views_wrap_the_semantics_not_the_reverse() {
    let c = ids(&[
        (
            "shop/data.dart",
            "class Shop {}\nFuture<Shop> data(Ref ref) async => Shop();",
        ),
        (
            "shop/layout.dart",
            &widget(
                "ShopLayout",
                "final Widget child; final Shop shop;",
                ", required this.child, required this.shop",
            ),
        ),
        (
            "shop/cart/page.dart",
            &widget("CartPage", "final Shop shop;", ", required this.shop"),
        ),
    ]);
    has(
        &c,
        &[
            "SectionView(",
            "data: (s1) => Semantics(identifier: 'route:/shop/cart', container: true, explicitChildNodes: true, child: _i2.CartPage(shop: s1))",
        ],
    );
    let section = c.find("SectionView(").unwrap();
    let wrapper = c.find("Semantics(identifier: 'route:/shop/cart'").unwrap();
    assert!(section < wrapper, "{c}");
    // The layout is not a page: it has no identifier.
    assert_eq!(c.matches("Semantics(identifier:").count(), 1, "{c}");
}

#[test]
fn transition_and_present_get_the_wrapped_page() {
    let c = ids(&[
        ("transition.dart", FADE),
        ("page.dart", HOME),
        (
            "buy/$id/page.dart",
            &widget("BuyPage", "final int id;", ", required this.id"),
        ),
        ("buy/$id/present.dart", SHEET),
    ]);
    // The wrapper is the child the transition and the sheet receive.
    has(
        &c,
        &[
            "Semantics(identifier: 'route:/', container: true, explicitChildNodes: true, child: const _i0.HomePage())",
            "Semantics(identifier: 'route:/buy/:id', container: true, explicitChildNodes: true, child: _i2.BuyPage(id: v.id))",
        ],
    );
    assert_eq!(c.matches("Semantics(identifier:").count(), 2, "{c}");
    let transition = c.find("_i1.transition(").unwrap();
    assert!(transition < c.find("route:/'").unwrap(), "{c}");
    let present = c.find("_i3.present(").unwrap();
    assert!(present < c.find("route:/buy/:id").unwrap(), "{c}");
}

#[test]
fn catch_all_and_optional_catch_all_ids() {
    let c = ids(&[
        (
            "docs/$$rest/page.dart",
            &widget(
                "DocsPage",
                "final List<String> rest;",
                ", required this.rest",
            ),
        ),
        (
            "files/$$$path/page.dart",
            &widget(
                "FilesPage",
                "final List<String> path;",
                ", required this.path",
            ),
        ),
    ]);
    has(
        &c,
        &[
            "identifier: 'route:/docs/*rest'",
            "identifier: 'route:/files/*path?'",
        ],
    );
    // An optional catch-all is two routes (with and without it); each wears the same id.
    assert_eq!(
        c.matches("identifier: 'route:/files/*path?'").count(),
        2,
        "{c}"
    );
}

#[test]
fn groups_add_nothing_to_the_identifier() {
    let c = ids(&[("(members)/notes/page.dart", HOME)]);
    has(&c, &["identifier: 'route:/notes'"]);
    lacks(&c, &["members'"]);
}

#[test]
fn a_page_in_a_tab_wears_it_too() {
    let c = ids(&[
        (
            "layout.dart",
            "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }",
        ),
        // The layout folder's own page is a tab, and so is each folder.
        ("page.dart", HOME),
        ("search/page.dart", &widget("SearchPage", "", "")),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute.indexedStack(",
            "identifier: 'route:/'",
            "identifier: 'route:/search'",
        ],
    );
    assert_eq!(c.matches("Semantics(identifier:").count(), 2, "{c}");
}

#[test]
fn an_identifier_is_a_dart_literal() {
    // Folder names can't hold a quote, but the literal is escaped like every Dart string the
    // generator writes (`$` and `\` too), and a `const` call stays constant.
    let id = crate::emit::dart_str("route:/it's $x");
    assert_eq!(id, r"'route:/it\'s \$x'");
    assert_eq!(
        crate::emit::with_semantics(&id, "const _i0.A()".into()),
        r"Semantics(identifier: 'route:/it\'s \$x', container: true, explicitChildNodes: true, child: const _i0.A())"
    );
    assert_eq!(
        crate::emit::with_semantics("'route:/'", "_i0.A(n: v.n)".into()),
        "Semantics(identifier: 'route:/', container: true, explicitChildNodes: true, child: _i0.A(n: v.n))"
    );
}

#[test]
fn a_route_without_a_page_wears_nothing() {
    let c = ids(&[
        ("page.dart", HOME),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    assert_eq!(c.matches("Semantics(identifier:").count(), 1, "{c}");
}

#[test]
fn mount_turns_web_semantics_on_only_when_asked() {
    let files = [("page.dart", HOME)];
    let c = code_with(&on(), &files);
    has(&c, &["ensureWebSemantics();"]);
    assert_eq!(c.matches("ensureWebSemantics();").count(), 1, "{c}");
    let mount = c.find("static List<RouteBase> mount(").unwrap();
    let call = c.find("ensureWebSemantics();").unwrap();
    let list = c[mount..].find("return [").unwrap() + mount;
    assert!(mount < call && call < list, "{c}");
    lacks(
        &code_with(&Config::default(), &files),
        &["ensureWebSemantics"],
    );
}

#[test]
fn off_by_default_changes_nothing() {
    let files = [
        ("page.dart", HOME),
        (
            "products/$id/page.dart",
            &widget("ProductPage", "final int id;", ", required this.id"),
        ),
    ];
    let c = code_with(&Config::default(), &files);
    lacks(&c, &["Semantics(", "ensureWebSemantics"]);
    has(&c, &["const _i0.HomePage()"]);
}

#[test]
fn semantics_ids_parses_and_defaults_to_off() {
    assert!(!Config::default().semantics_ids);
    assert!(!config("name: demo\n").unwrap().semantics_ids);
    assert!(
        !config("fespalier:\n  format: true\n")
            .unwrap()
            .semantics_ids
    );
    assert!(
        config("fespalier:\n  semantics_ids: true\n")
            .unwrap()
            .semantics_ids
    );
    let c = config("fespalier:\n  semantics_ids: false\n").unwrap();
    assert_eq!(c, Config::default());
}

#[test]
fn semantics_ids_rejects_other_values() {
    let e = format!(
        "{:#}",
        config("fespalier:\n  semantics_ids: sometimes\n").unwrap_err()
    );
    assert!(
        e.contains(
            "fespalier.semantics_ids: invalid type: string \"sometimes\", expected a boolean"
        ),
        "{e}"
    );
    // The unknown-key message lists it, so a misspelling points at the right name.
    let e = format!(
        "{:#}",
        config("fespalier:\n  semantic_ids: true\n").unwrap_err()
    );
    assert!(
        e.contains("unknown field `semantic_ids`") && e.contains("`semantics_ids`"),
        "{e}"
    );
}

#[test]
fn the_pubspec_semantics_ids_reaches_the_generated_file() {
    let dir = project(&[("page.dart", HOME)]);
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  semantics_ids: true\n",
    )
    .unwrap();
    crate::gen_with(dir.path(), &Config::load(dir.path()).unwrap(), true).unwrap();
    let c = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(&c, &["identifier: 'route:/'", "ensureWebSemantics();"]);
}
