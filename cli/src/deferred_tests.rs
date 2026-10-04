//! Deferred routes (since 0.7.0): a `route.dart` with `const deferred = true;` (or `deferred: true`
//! in the pubspec) makes the page.dart of its folder and everything below it a `deferred as`
//! import, built in a `DeferredView` (or handed to the `DataView` that already waits for data).

use std::fs;

use crate::config::{Config, Pubspec};
use crate::{analyze, build, routes};

fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// The files are given relative to `lib/app/`, except those that start with `lib/`.
fn app_files<'a>(files: &[(&'a str, &'a str)]) -> Vec<(String, &'a str)> {
    files
        .iter()
        .map(|(p, b)| {
            let rel = match p.strip_prefix("lib/") {
                Some(rest) => rest.to_string(),
                None => format!("app/{p}"),
            };
            (rel, *b)
        })
        .collect()
}

fn project_of(files: &[(&str, &str)]) -> tempfile::TempDir {
    let owned = app_files(files);
    let refs: Vec<(&str, &str)> = owned.iter().map(|(p, b)| (p.as_str(), *b)).collect();
    project(&refs)
}

fn diags_with(cfg: &Config, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project_of(files);
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
    let dir = project_of(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn code(files: &[(&str, &str)]) -> String {
    code_with(&Config::default(), files)
}

fn defer_all() -> Config {
    Config {
        deferred: true,
        ..Config::default()
    }
}

/// Whether each route's page is deferred, by folder, in the order of the route table.
fn deferred_of(cfg: &Config, files: &[(&str, &str)]) -> Vec<(String, bool)> {
    let dir = project_of(files);
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    app.routes
        .iter()
        .filter(|r| r.is_route())
        .map(|r| (r.dir.clone(), r.defers_page()))
        .collect()
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

fn lacks(code: &str, needles: &[&str]) {
    let flat_code = flat(code);
    for n in needles {
        assert!(
            !flat_code.contains(&flat(n)),
            "unexpected `{n}` in:\n{code}"
        );
    }
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }".into()
}

fn widget(class: &str, fields: &str, params: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key{params}}}); {fields} }}"
    )
}

const DEFER: &str = "const deferred = true;\n";
const KEEP: &str = "const deferred = false;\n";

/// The matching line of the route table: `/a  ARoute  a/page.dart  (deferred)`.
fn table_row(code: &str, pattern: &str) -> String {
    code.lines()
        .find(|l| l.starts_with(&format!("//   {pattern} ")))
        .unwrap_or_else(|| panic!("no row for {pattern} in:\n{code}"))
        .to_string()
}

// ---- the config ----

#[test]
fn deferred_is_off_by_default_and_changes_nothing() {
    assert!(!Config::default().deferred);
    assert!(!Pubspec::parse("name: demo\n").unwrap().config.deferred);
    let c = code(&[
        ("page.dart", &page("Home")),
        ("route.dart", "const linkable = true;"),
        (
            "layout.dart",
            &widget("RootLayout", "final Widget child;", ", required this.child"),
        ),
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
    ]);
    lacks(
        &c,
        &[
            "deferred",
            "DeferredView",
            "DeferredLibrary",
            "library:",
            "loadDeferred",
            "_lib",
        ],
    );
    // The same text as before deferred routes existed.
    has(
        &c,
        &[
            "static PrefetchHandle preload(WidgetRef ref, Uri uri, {Duration? keepFor}) => ref.prefetchAll(dataAt(uri) ?? const [], keepFor: keepFor);",
        ],
    );
}

#[test]
fn the_pubspec_key_is_a_bool() {
    let c = |yaml: &str| Pubspec::parse(yaml).map(|p| p.config.deferred);
    assert!(c("fespalier:\n  deferred: true\n").unwrap());
    assert!(!c("fespalier:\n  deferred: false\n").unwrap());
    assert!(!c("fespalier:\n  format: true\n").unwrap());
    for bad in ["maybe", "on_demand", "[1]"] {
        let e = format!(
            "{:#}",
            c(&format!("fespalier:\n  deferred: {bad}\n")).unwrap_err()
        );
        assert!(e.contains("invalid pubspec.yaml"), "{bad}: {e}");
        assert!(e.contains("expected a boolean"), "{bad}: {e}");
    }
}

// ---- what a route.dart says, and who inherits it ----

#[test]
fn route_dart_defers_its_folder_and_below_and_the_nearest_wins() {
    let files = [
        ("page.dart", page("Home").as_str().to_owned()),
        ("a/route.dart", DEFER.into()),
        ("a/page.dart", page("A")),
        ("a/b/route.dart", KEEP.into()),
        ("a/b/page.dart", page("B")),
        ("a/b/deep/page.dart", page("Deep")),
        ("a/c/page.dart", page("C")),
        ("d/page.dart", page("D")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(p, b)| (*p, b.as_str())).collect();
    let all = deferred_of(&Config::default(), &files);
    let of = |dir: &str| all.iter().find(|(d, _)| d == dir).unwrap().1;
    assert!(!of(""));
    assert!(of("a"));
    assert!(!of("a/b"), "the nearest route.dart wins over the one above");
    assert!(!of("a/b/deep"), "and covers what is below it");
    assert!(of("a/c"));
    assert!(!of("d"), "a sibling is not covered");

    // The pubspec's `deferred: true` is the default, and a route.dart says otherwise below it.
    let all = deferred_of(&defer_all(), &files);
    let of = |dir: &str| all.iter().find(|(d, _)| d == dir).unwrap().1;
    assert!(of(""));
    assert!(of("a"));
    assert!(!of("a/b"));
    assert!(!of("a/b/deep"));
    assert!(of("a/c"));
    assert!(of("d"));
}

#[test]
fn a_group_and_a_folder_without_a_page_pass_it_on() {
    let files = [
        ("(shop)/route.dart", DEFER),
        ("(shop)/cart/page.dart", &page("Cart")),
        ("docs/route.dart", DEFER),
        ("docs/guide/page.dart", &page("Guide")),
        ("other/page.dart", &page("Other")),
    ];
    let all = deferred_of(&Config::default(), &files);
    let of = |dir: &str| all.iter().find(|(d, _)| d == dir).unwrap().1;
    assert!(of("(shop)/cart"));
    assert!(of("docs/guide"));
    assert!(!of("other"));
}

#[test]
fn a_route_dart_with_only_deferred_is_not_empty_and_sits_beside_the_others() {
    assert!(errors(&[("route.dart", DEFER), ("page.dart", &page("Home"))]).is_empty());
    let c = code(&[
        (
            "shop/route.dart",
            "import 'package:fespalier/fespalier.dart';\n\nconst caseSensitive = false;\nconst linkable = false;\nconst remount = Remount.never;\nconst deferred = true;\n",
        ),
        ("shop/page.dart", &page("Shop")),
    ]);
    has(&c, &["import 'app/shop/page.dart' deferred as _i0;"]);
}

// ---- what is generated ----

#[test]
fn a_deferred_page_is_imported_deferred_and_built_in_a_deferred_view() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("a/route.dart", DEFER),
        ("a/page.dart", &page("A")),
    ]);
    has(
        &c,
        &[
            "import 'app/page.dart' as _i0;",
            "import 'app/a/page.dart' deferred as _i1;",
            "DeferredView( library: _lib1, page: () => _i1.APage(), loading: () => const DefaultLoading(), error: (e, st, retry) => DefaultError(error: e, retry: retry), )",
            // The eager page is as before.
            "builder: (context, state) => const _i0.HomePage(),",
        ],
    );
    // A deferred class can't be named in a constant expression.
    lacks(&c, &["const _i1.APage()"]);
    has(
        &c,
        &["final _lib1 = DeferredLibrary(_i1.loadLibrary, 'a/page.dart');"],
    );
}

#[test]
fn the_nearest_loading_and_error_are_the_views_of_the_code_load() {
    let error = "class RootError extends StatelessWidget { const RootError({super.key, required this.error, required this.retry, required this.id}); final Object error; final VoidCallback retry; final int id; }";
    let loading = widget("RootLoading", "", "");
    let c = code(&[
        ("loading.dart", &loading),
        (
            "items/error.dart",
            &widget(
                "ItemError",
                "final Object error; final VoidCallback retry; final int id;",
                ", required this.error, required this.retry, required this.id",
            ),
        ),
        ("items/route.dart", DEFER),
        ("items/$id/page.dart", &item()),
        ("page.dart", &page("Home")),
    ]);
    // An error view that asks for a segment gets it from the route.
    has(
        &c,
        &[
            "loading: () => const _i1.RootLoading(),",
            "error: (e, st, retry) => _i2.ItemError(error: e, retry: retry, id: v.id),",
        ],
    );
    let _ = error;
}

#[test]
fn a_deferred_data_page_hands_its_library_to_the_data_view() {
    let c = code(&[
        ("a/route.dart", DEFER),
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
    ]);
    has(
        &c,
        &[
            "DataView( watch: (ref) => watchData(ref, 'd1', _data1), refresh: (ref) => ref.invalidate(_data1), data: (d) => _i1.APage(n: d), loading: () => const DefaultLoading(), error: (e, st, retry) => DefaultError(error: e, retry: retry), keepPrevious: true, library: _lib1, )",
        ],
    );
    lacks(&c, &["DeferredView("]);
}

#[test]
fn app_routes_registers_lists_and_loads_the_deferred_pages() {
    let c = code(&[
        ("a/route.dart", DEFER),
        ("a/page.dart", &page("A")),
        ("b/page.dart", &page("B")),
        ("b/$id/route.dart", DEFER),
        ("b/$id/page.dart", &item()),
    ]);
    has(
        &c,
        &[
            "DeferredLibrary.register(deferred);",
            "static final List<DeferredLibrary> deferred = [_lib1, _lib3];",
            "static Future<void> loadDeferred() => DeferredLibrary.loadAll(deferred);",
            "final _lib3 = DeferredLibrary(_i2.loadLibrary, 'b/\\$id/page.dart');",
        ],
    );
}

#[test]
fn preload_loads_the_code_of_a_deferred_route() {
    let c = code(&[
        ("a/route.dart", DEFER),
        ("a/page.dart", &page("A")),
        ("b/route.dart", DEFER),
        ("b/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "b/page.dart",
            &widget("BPage", "final int n;", ", required this.n"),
        ),
        ("c/page.dart", &page("C")),
    ]);
    has(
        &c,
        &[
            // A route with no data: it had no override; now it loads its code.
            "/// Starts loading this page's code (a/page.dart is deferred); it reads no data, so the handle holds nothing. Never navigates, runs no guard.",
            "PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) { _lib1.preload(); return ref.prefetchAll(const [], keepFor: keepFor); }",
            // A route with data keeps its providers.
            "PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) { _lib2.preload(); return ref.prefetchAll([_data2], keepFor: keepFor); }",
            // The app-wide one goes through the matched route.
            "static PrefetchHandle preload(WidgetRef ref, Uri uri, {Duration? keepFor}) => matchUrl(uri)?.route.preload(ref, keepFor: keepFor) ?? ref.prefetchAll(const [], keepFor: keepFor);",
        ],
    );
    // The route that isn't deferred has no override of its own.
    assert_eq!(
        c.matches("PrefetchHandle preload(WidgetRef ref, {Duration? keepFor})")
            .count(),
        2,
        "{c}"
    );
}

#[test]
fn a_section_page_nests_the_deferred_view_in_its_section_view() {
    let c = code(&[
        (
            "(shop)/data.dart",
            "Future<Shop> data(Ref ref) async => Shop();",
        ),
        (
            "(shop)/layout.dart",
            &widget(
                "ShopLayout",
                "final Widget child; final Shop shop;",
                ", required this.child, required this.shop",
            ),
        ),
        ("(shop)/route.dart", DEFER),
        (
            "(shop)/cart/page.dart",
            &widget("CartPage", "final Shop shop;", ", required this.shop"),
        ),
    ]);
    has(
        &c,
        &[
            "SectionView( watch: (ref) => watchData(ref, 'd1', _data1), data: (s1) => DeferredView( library: _lib2, page: () => _i2.CartPage(shop: s1),",
        ],
    );
    // The layout is never deferred.
    has(&c, &["import 'app/(shop)/layout.dart' as _i"]);
}

#[test]
fn only_page_dart_is_deferred() {
    let hook = "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";
    let c = code(&[
        ("route.dart", DEFER),
        ("loading.dart", &widget("RootLoading", "", "")),
        (
            "error.dart",
            &widget(
                "RootError",
                "final Object error; final VoidCallback retry;",
                ", required this.error, required this.retry",
            ),
        ),
        (
            "not_found.dart",
            &widget("Missing", "final Uri uri;", ", required this.uri"),
        ),
        ("transition.dart", hook),
        (
            "layout.dart",
            &widget("RootLayout", "final Widget child;", ", required this.child"),
        ),
        ("page.dart", &page("Home")),
        (
            "a/guard.dart",
            "String? guard(ProviderContainer c) => null;",
        ),
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
        ("old/redirect.dart", "String redirect() => '/a';"),
        (
            "t/layout.dart",
            &widget(
                "TabsLayout",
                "final StatefulNavigationShell shell;",
                ", required this.shell",
            ),
        ),
        ("t/tabs.dart", "const tabs = ['x'];"),
        ("t/page.dart", &page("TabsHome")),
        ("t/x/page.dart", &page("X")),
    ]);
    let imports: Vec<&str> = c
        .lines()
        .filter(|l| l.starts_with("import 'app/"))
        .collect();
    let deferred: Vec<&&str> = imports
        .iter()
        .filter(|l| l.contains(" deferred as "))
        .collect();
    // The four pages (home, a, the tab layout's own, x), and nothing else.
    let want = ["page.dart", "a/page.dart", "t/page.dart", "t/x/page.dart"];
    assert_eq!(deferred.len(), want.len(), "{imports:#?}");
    for w in want {
        assert!(
            deferred.iter().any(|l| l.contains(&format!("'app/{w}'"))),
            "{w}: {imports:#?}"
        );
    }
    for kind in [
        "loading",
        "error",
        "not_found",
        "transition",
        "layout.dart",
        "guard",
        "data",
        "redirect",
        "tabs",
    ] {
        assert!(
            imports
                .iter()
                .filter(|l| l.contains(kind))
                .all(|l| !l.contains("deferred")),
            "{kind}: {imports:#?}"
        );
    }
    // The tab layout's own page is deferred, in its branch.
    has(&c, &["library: _lib"]);
}

#[test]
fn a_redirect_route_has_no_page_to_defer() {
    let all = deferred_of(
        &defer_all(),
        &[
            ("page.dart", &page("Home")),
            ("old/redirect.dart", "String redirect() => '/';"),
        ],
    );
    assert_eq!(all, [(String::new(), true), ("old".to_string(), false)]);
}

#[test]
fn function_views_are_deferred_too() {
    let c = code(&[
        ("route.dart", DEFER),
        ("a/page.dart", "Widget page() => const SizedBox();"),
    ]);
    has(&c, &["page: () => _i0.page(),"]);
}

#[test]
fn a_transition_wraps_the_deferred_view() {
    let c = code(&[
        (
            "transition.dart",
            "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);",
        ),
        ("a/route.dart", DEFER),
        ("a/page.dart", &page("A")),
    ]);
    has(
        &c,
        &[
            "pageBuilder: (context, state) => namedPage('/a', () => _i0.transition( state.pageKey, DeferredView( library: _lib1, page: () => _i1.APage(),",
        ],
    );
}

#[test]
fn deferred_binds_the_nearest_loading_and_error_views() {
    // An error.dart above that asks for a segment the deferred route lacks: it must fit
    // every route it covers now, as for a route with data.
    let error = widget(
        "RootError",
        "final Object error; final VoidCallback retry; final int id;",
        ", required this.error, required this.retry, required this.id",
    );
    let files = [
        ("error.dart", error.as_str()),
        ("page.dart", &page("Home") as &str),
    ];
    let messages = errors(&files);
    assert!(messages.is_empty(), "{messages:?}");
    let with = errors(&[
        ("error.dart", &error),
        ("route.dart", DEFER),
        ("page.dart", &page("Home")),
    ]);
    assert_eq!(
        with,
        [
            "✗ error.dart:1  can't fill `id` for /: it isn't one of its segments (it has none), `error`, `stackTrace`, `retry`, or a query parameter (optional and nullable)"
        ]
    );
}

// ---- diagnostics ----

#[test]
fn declaring_it_twice_is_an_error_at_the_second() {
    let e = errors(&[
        (
            "a/route.dart",
            "const deferred = true;\nconst deferred = false;",
        ),
        ("a/page.dart", &page("A")),
    ]);
    assert_eq!(e, ["✗ a/route.dart:2  `deferred` is declared twice"]);
}

#[test]
fn it_must_be_a_literal() {
    let msg = "`deferred` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it";
    for body in [
        "const deferred = 1;",
        "const deferred = 'true';",
        "const deferred = !false;",
        "const deferred = kReleaseMode;",
    ] {
        let e = errors(&[("route.dart", body), ("page.dart", &page("Home"))]);
        assert_eq!(e, [format!("✗ route.dart:1  {msg}")], "{body}");
    }
}

#[test]
fn a_route_dart_with_nothing_it_knows_lists_what_it_does() {
    let e = errors(&[
        ("route.dart", "const other = 1;"),
        ("page.dart", &page("Home")),
    ]);
    assert_eq!(
        e,
        [
            "✗ route.dart  expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;`, `const deferred = true;` or `const freshness = Freshness(staleTime: Duration(minutes: 5));`"
        ]
    );
}

fn sort_page() -> String {
    "enum Sort { name, price }\nclass ProductsPage extends StatelessWidget { const ProductsPage({super.key, this.sort}); final Sort? sort; }".into()
}

const G4: &str = "is declared in this page.dart, which is deferred, and the generated code names it outside the page (as the type of a segment, a query parameter or an `extra`): Dart can't use a deferred library's types there.";

#[test]
fn an_enum_declared_in_a_deferred_page_is_an_error_that_says_what_to_do() {
    let e = errors(&[
        ("products/route.dart", DEFER),
        ("products/page.dart", &sort_page()),
    ]);
    assert_eq!(
        e,
        [format!(
            "✗ products/page.dart:2  `Sort` {G4} Move `Sort` to a file of its own and import it here, or say `const deferred = false;` in this folder's route.dart"
        )]
    );
    // The fix the message names: a file of its own, imported by the page.
    let c = code(&[
        ("products/route.dart", DEFER),
        ("lib/models/sort.dart", "enum Sort { name, price }\n"),
        (
            "products/page.dart",
            "import 'package:demo/models/sort.dart';\nclass ProductsPage extends StatelessWidget { const ProductsPage({super.key, this.sort}); final Sort? sort; }",
        ),
    ]);
    has(&c, &["import 'app/products/page.dart' deferred as _i0;"]);
    // And the other: say it is not deferred.
    let c = code(&[
        ("products/route.dart", KEEP),
        ("products/page.dart", &sort_page()),
    ]);
    lacks(&c, &["deferred"]);
}

#[test]
fn the_pubspec_default_meets_the_same_rule() {
    let e = diags_with(&defer_all(), &[("products/page.dart", &sort_page())]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains(G4), "{e:?}");
}

#[test]
fn a_typed_extra_declared_in_a_deferred_page_is_an_error() {
    let page = "class Detail { const Detail(); }\nclass ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id, this.extra}); final int id; final Detail? extra; }";
    let e = errors(&[("item/$id/route.dart", DEFER), ("item/$id/page.dart", page)]);
    assert_eq!(
        e,
        [format!(
            "✗ item/$id/page.dart:2  `Detail` {G4} Move `Detail` to a file of its own and import it here, or say `const deferred = false;` in this folder's route.dart"
        )]
    );
}

#[test]
fn a_type_of_a_page_that_is_not_deferred_is_fine_for_its_deferred_child() {
    // The enum is in the parent's page, which is eager; the child's page is deferred.
    let parent = "enum Sort { name, price }\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, this.sort}); final Sort? sort; }";
    let child = "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }";
    let c = code(&[
        ("shop/page.dart", parent),
        ("shop/$id/route.dart", DEFER),
        ("shop/$id/page.dart", child),
    ]);
    has(&c, &["import 'app/shop/\\$id/page.dart' deferred as _i1;"]);
}

#[test]
fn an_enum_in_a_file_of_its_own_is_fine() {
    let c = code(&[
        (
            "lib/models/category.dart",
            "enum Category { shoes, hats }\n",
        ),
        ("shop/route.dart", DEFER),
        (
            "shop/$category/page.dart",
            "import 'package:demo/models/category.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, required this.category}); final Category category; }",
        ),
    ]);
    has(&c, &["deferred as _i0;"]);
}

#[test]
fn a_prefix_is_not_a_token_so_i1_is_not_i11() {
    // Twelve pages, in folder order: `a1` is `_i1` and deferred, `b1` is `_i11` and eager, and
    // declares the enum its own query parameter has: `_i11.Sort?` has `_i1` in it, not `_i1.`.
    let mut files: Vec<(String, String)> = vec![("a1/route.dart".into(), DEFER.into())];
    for name in [
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "b0",
    ] {
        files.push((format!("{name}/page.dart"), page(&name.to_uppercase())));
    }
    files.push(("b1/page.dart".into(), sort_page()));
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(p, b)| (p.as_str(), b.as_str()))
        .collect();
    let e = errors(&refs);
    assert!(e.is_empty(), "{e:?}");
    let c = code(&refs);
    has(
        &c,
        &[
            "import 'app/a1/page.dart' deferred as _i1;",
            "import 'app/b1/page.dart' as _i11;",
        ],
    );
    assert!(c.contains("_i11.Sort"), "{c}");
}

// ---- tags, the table, --json ----

#[test]
fn the_tag_comes_last_and_is_only_on_deferred_routes() {
    let c = code(&[
        (
            "transition.dart",
            "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);",
        ),
        ("page.dart", &page("Home")),
        ("a/route.dart", DEFER),
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            &widget("APage", "final int n;", ", required this.n"),
        ),
        ("b/route.dart", DEFER),
        ("b/page.dart", &page("B")),
    ]);
    assert!(
        table_row(&c, "/a").ends_with("(data, transition, deferred)"),
        "{c}"
    );
    assert!(
        table_row(&c, "/b").ends_with("(transition, deferred)"),
        "{c}"
    );
    assert!(table_row(&c, "/").ends_with("(transition)"), "{c}");
}

#[test]
fn the_json_row_says_it_only_for_a_deferred_route() {
    let dir = project_of(&[
        ("page.dart", &page("Home")),
        ("items/route.dart", DEFER),
        ("items/$id/page.dart", &item()),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let rows: Vec<serde_json::Value> = routes::json_lines(&app, "lib/app")
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |pattern: &str| rows.iter().find(|r| r["pattern"] == pattern).unwrap();
    assert_eq!(by("/items/:id")["deferred"], true);
    assert_eq!(by("/items/:id")["tags"].to_string(), "[\"deferred\"]");
    assert!(by("/").get("deferred").is_none());
    assert!(by("/old").get("deferred").is_none());
}

#[test]
fn the_manifest_says_it_only_for_a_deferred_route() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/route.dart", DEFER),
        ("items/$id/page.dart", &item()),
    ]);
    assert_eq!(c.matches("deferred: true,").count(), 1, "{c}");
    has(
        &c,
        &[
            "type: ItemRoute, path: '/items/:id', folder: 'items/\\$id', segments: [RouteParam('id', 'int')], deferred: true,",
        ],
    );
}
