//! Localized paths: `const paths = {'fr': 'produits'};` in a folder's route.dart. (The
//! rest of the generator's tests are in `tests.rs`.)

use std::fs;

use crate::build;
use crate::config::Config;
use crate::locale::{canonical_path, has_params, is_localized};

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

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    diags(files).into_iter().filter(|d| d.starts_with('✗')).collect()
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

fn lacks(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn page_with(name: &str, params: &str, fields: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, {params}}}); {fields} }}")
}

const NOT_FOUND: &str = "class NotFoundPage extends StatelessWidget { const NotFoundPage({super.key, required this.uri}); final Uri uri; }";
const PRODUCTS: &str = "const paths = {'fr': 'produits', 'de': 'produkte'};\n";

fn id_page() -> String {
    page_with("Product", "required this.id", "final int id;")
}

/// A tree with `products/` localized, and a dynamic child with a nested static one.
fn products() -> Vec<(&'static str, String)> {
    vec![
        ("products/route.dart", PRODUCTS.to_string()),
        ("products/page.dart", page("Products")),
        ("products/$id/page.dart", id_page()),
        ("products/$id/reviews/page.dart", page_with("Reviews", "required this.id", "final int id;")),
        ("products/$id/reviews/route.dart", "const paths = {'fr': 'avis'};".to_string()),
    ]
}

fn refs<'a>(files: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    files.iter().map(|(p, b)| (*p, b.as_str())).collect()
}

// --- routing ---------------------------------------------------------------------

#[test]
fn a_localized_folder_is_one_route_whose_segment_matches_every_spelling() {
    let c = code(&refs(&products()));
    // One GoRoute per page, not one per spelling; the folder's name is the first alternative.
    has(&c, &["path: joinLocation(at, '/:_l0(products|produits|produkte)'),"]);
    assert_eq!(c.matches("_l0(products").count(), 1, "{c}");
}

#[test]
fn nested_routes_carry_their_own_parameter_named_by_their_depth() {
    let c = code(&refs(&products()));
    has(&c, &["path: ':id',", "path: ':_l2(reviews|avis)',"]);
    // A parameter name may not repeat down one branch (go_router asserts): depth keeps them apart.
    assert!(!c.contains("_l1"), "{c}");
}

#[test]
fn a_page_less_localized_folder_folds_into_its_children() {
    let c = code(&[
        ("blog/route.dart", "const paths = {'fr': 'journal'};"),
        ("blog/$slug/page.dart", &page_with("Post", "required this.slug", "final String slug;")),
        ("blog/archive/page.dart", &page("Archive")),
    ]);
    has(&c, &["joinLocation(at, '/:_l0(blog|journal)/archive')", "joinLocation(at, '/:_l0(blog|journal)/:slug')"]);
}

#[test]
fn a_localized_static_route_still_sorts_before_a_dynamic_sibling() {
    // `:_l0(...)` is a parameter to go_router but not a dynamic segment to fsp: the static
    // routes go first, or `/produits` would be caught by `/:slug`.
    let c = code(&[
        ("$slug/page.dart", &page_with("Slug", "required this.slug", "final String slug;")),
        ("about/route.dart", "const paths = {'fr': 'a-propos'};"),
        ("about/page.dart", &page("About")),
    ]);
    let about = c.find(":_l0(about|a-propos)").unwrap();
    let slug = c.find("joinLocation(at, '/:slug')").unwrap();
    assert!(about < slug, "{c}");
}

#[test]
fn a_spelling_with_a_dot_is_escaped_for_the_regular_expression() {
    let c = code(&[("api/route.dart", "const paths = {'fr': 'v1.0'};"), ("api/page.dart", &page("Api"))]);
    // In the Dart source `\\.` is the pattern's `\.`: a literal dot, not any character.
    has(&c, &["'/:_l0(api|v1\\\\.0)'"]);
}

#[test]
fn a_route_dart_with_paths_alone_needs_no_case_setting() {
    assert_eq!(errors(&refs(&products())), Vec::<String>::new());
    let both = code(&[
        ("a/route.dart", "const caseSensitive = false;\nconst paths = {'fr': 'b'};"),
        ("a/page.dart", &page("A")),
    ]);
    has(&both, &["caseSensitive: false,", ":_l0(a|b)"]);
}

#[test]
fn a_redirect_folder_can_be_localized_too() {
    let c = code(&[
        ("old/route.dart", "const paths = {'fr': 'ancien'};"),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    has(&c, &["path: joinLocation(at, '/:_l0(old|ancien)'),"]);
}

#[test]
fn the_same_spelling_for_two_locales_and_the_canonical_one_are_fine() {
    let c = code(&[
        ("menu/route.dart", "const paths = {'fr': 'carte', 'de': 'carte', 'en': 'menu'};"),
        ("menu/page.dart", &page("Menu")),
    ]);
    // Each alternative once.
    has(&c, &[":_l0(menu|carte)"]);
}

// --- typed locations -----------------------------------------------------------------

#[test]
fn location_stays_canonical_and_location_for_spells_each_level() {
    let c = code(&refs(&products()));
    has(
        &c,
        &[
            "String get location => joinLocation(AppRoutes.base, '/products/$id/reviews');",
            "String locationFor(String? _locale) {",
            "'/${localizedSegment(_locale, 'products', {'fr': 'produits', 'de': 'produkte'})}/$id/${localizedSegment(_locale, 'reviews', {'fr': 'avis'})}'",
        ],
    );
}

#[test]
fn a_route_without_a_localized_segment_has_no_location_for_of_its_own() {
    let c = code(&[("about/page.dart", &page("About")), ("products/route.dart", PRODUCTS), ("products/page.dart", &page("Products"))]);
    assert_eq!(c.matches("String locationFor(").count(), 1, "{c}");
}

#[test]
fn location_for_keeps_the_query_and_the_catch_all_assert() {
    let c = code(&[
        ("docs/route.dart", "const paths = {'fr': 'documents'};"),
        ("docs/$$rest/page.dart", &page_with("Doc", "required this.rest", "final List<String> rest;")),
    ]);
    has(&c, &["assert(rest.isNotEmpty", "localizedSegment(_locale, 'docs', {'fr': 'documents'})", "restPath(rest)"]);
    let q = code(&[
        ("search/route.dart", "const paths = {'fr': 'recherche'};"),
        ("search/page.dart", &page_with("Search", "this.q", "final String? q;")),
    ]);
    has(&q, &["withQuery(joinLocation(AppRoutes.base, '/${localizedSegment(_locale, 'search', {'fr': 'recherche'})}'), {'q': q})"]);
}

#[test]
fn go_push_and_replace_take_a_locale_on_every_route() {
    // In the base class: a route with no extra inherits them.
    let c = code(&[
        ("products/route.dart", PRODUCTS),
        ("products/page.dart", &page_with("Products", "this.extra", "final String? extra;")),
    ]);
    has(&c, &["void go(BuildContext context, {String? extra, String? locale}) => context.go(locationFor(locale), extra: extra);"]);
}

#[test]
fn a_segment_called_locale_is_not_shadowed() {
    // The override's own parameter is `_locale`, which no segment can be called, so a
    // `$locale` folder (a common way to do i18n without localized paths) keeps working.
    let c = code(&[
        ("products/route.dart", PRODUCTS),
        ("products/$locale/page.dart", &page_with("Shop", "required this.locale", "final String locale;")),
    ]);
    has(&c, &["final String locale;", "localizedSegment(_locale, 'products', {'fr': 'produits', 'de': 'produkte'})}/${Uri.encodeComponent(locale)}"]);
}

// --- the other surfaces -----------------------------------------------------------------

#[test]
fn matchers_and_not_found_prefixes_join_the_spellings_with_a_bar() {
    let mut files = products();
    files.push(("products/not_found.dart", NOT_FOUND.replace("NotFound", "ProductsNotFound")));
    files.push(("not_found.dart", NOT_FOUND.to_string()));
    let c = code(&refs(&files));
    has(
        &c,
        &[
            "RouteMatcher(['products|produits|produkte', ':id', 'reviews|avis']",
            "RouteMatcher(['products|produits|produkte']",
            "(['products|produits|produkte'], (uri) =>",
        ],
    );
}

#[test]
fn the_manifest_lists_the_path_in_each_locale() {
    let c = code(&refs(&products()));
    has(
        &c,
        &[
            "paths: {'fr': '/produits', 'de': '/produkte'},",
            // `reviews/` has no `de` spelling, `products/` has: each level falls back alone.
            "paths: {'fr': '/produits/:id/avis', 'de': '/produkte/:id/reviews'},",
        ],
    );
    // A route without one has no `paths:`.
    let plain = code(&[("about/page.dart", &page("About"))]);
    lacks(&plain, &["paths:"]);
}

#[test]
fn routes_shows_the_spellings_under_the_route() {
    let dir = project(&refs(&products()));
    let cfg = Config::default();
    let (_, _, app) = crate::analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    let rows = crate::routes::table(&app);
    assert_eq!(rows[0].split_whitespace().next(), Some("/products"), "{rows:?}");
    assert_eq!(rows[1], "  fr  /produits");
    assert_eq!(rows[2], "  de  /produkte");
    assert!(rows[3].starts_with("/products/:id "), "{rows:?}");
    assert_eq!(rows[4], "  fr  /produits/:id");
    assert_eq!(rows[5], "  de  /produkte/:id");
}

#[test]
fn routes_json_has_the_paths() {
    let dir = project(&refs(&products()));
    let (_, _, app) = crate::analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let lines = crate::routes::json_lines(&app, "lib/app");
    let row = |pattern: &str| -> serde_json::Value {
        lines.iter().map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()).find(|v| v["pattern"] == pattern).unwrap()
    };
    assert_eq!(row("/products/:id/reviews")["paths"], serde_json::json!({"fr": "/produits/:id/avis", "de": "/produkte/:id/reviews"}));
    assert_eq!(row("/products")["paths"], serde_json::json!({"fr": "/produits", "de": "/produkte"}));
    // A route that isn't localized has no `paths` key: the rows of an app without any are as they were.
    let plain = crate::analyze(&project(&[("about/page.dart", &page("About"))]).path().join("lib/app"), &Config::default()).unwrap().2;
    let lines = crate::routes::json_lines(&plain, "lib/app");
    assert!(serde_json::from_str::<serde_json::Value>(&lines[0]).unwrap().get("paths").is_none(), "{lines:?}");
    assert!(row("/products/:id")["paths"].is_object());
}

// --- what is an error -----------------------------------------------------------------------

#[test]
fn paths_on_a_dynamic_catch_all_group_or_root_folder_is_an_error() {
    let route = "const paths = {'fr': 'x'};";
    let cases: [(&str, &str, &str); 4] = [
        ("$id", "`$id` is a dynamic segment", "products/$id/route.dart"),
        ("$$rest", "is a catch-all", "docs/$$rest/route.dart"),
        ("(shop)", "`(shop)` is a group", "(shop)/route.dart"),
        ("", "the app folder has no URL segment", "route.dart"),
    ];
    for (_, why, file) in cases {
        let page_at = file.replace("route.dart", "page.dart");
        let body = if file.contains("$$rest") { page_with("Doc", "required this.rest", "final List<String> rest;") } else if file.contains("$id") { id_page() } else { page("A") };
        let mut files = vec![(file, route.to_string()), (page_at.as_str(), body)];
        if file.contains("$id") {
            files.push(("products/page.dart", page("Products")));
        }
        let e = errors(&files.iter().map(|(p, b)| (*p, b.as_str())).collect::<Vec<_>>());
        assert_eq!(e.len(), 1, "{file}: {e:?}");
        assert!(e[0].starts_with(&format!("✗ {file}:1  `paths` gives a static folder's name more spellings, but ")), "{e:?}");
        assert!(e[0].contains(why), "{file}: {e:?}");
    }
}

#[test]
fn paths_must_be_a_map_literal() {
    for (body, label) in [
        ("const paths = 'produits';", "a string"),
        ("const paths = ['produits'];", "a list"),
        ("const paths = {...other};", "a spread"),
        ("const paths = {'fr'};", "a set"),
        ("final paths = names();", "a call"),
        ("const paths = other;", "an identifier"),
    ] {
        let e = errors(&[("x/route.dart", body), ("x/page.dart", &page("X"))]);
        assert_eq!(e.len(), 1, "{label}: {e:?}");
        assert!(e[0].contains("`paths` must be a map literal from a locale tag to one spelling"), "{label}: {e:?}");
    }
}

#[test]
fn keys_and_values_must_be_string_literals() {
    let e = errors(&[("x/route.dart", "const paths = {fr: 'produits'};"), ("x/page.dart", &page("X"))]);
    assert_eq!(e, ["✗ x/route.dart:1  a key of `paths` must be a string literal naming a locale, e.g. `'fr'`: fsp reads it from the source"]);
    let e = errors(&[("x/route.dart", "const paths = {'fr': name};"), ("x/page.dart", &page("X"))]);
    assert_eq!(e, ["✗ x/route.dart:1  a value of `paths` must be a plain string literal, e.g. `'produits'`: fsp reads it from the source"]);
    // An interpolation is not a literal either.
    let e = errors(&[("x/route.dart", "const paths = {'fr': 'a$b'};"), ("x/page.dart", &page("X"))]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("a value of `paths` must be a plain string literal"), "{e:?}");
    let e = errors(&[("x/route.dart", "const paths = {'f$r': 'a'};"), ("x/page.dart", &page("X"))]);
    assert!(e[0].contains("a key of `paths` must be a string literal"), "{e:?}");
}

#[test]
fn a_spelling_must_be_one_valid_url_segment() {
    for bad in ["a/b", "", "a b", "a?b", "a#b", "..", ".", "über", "a%20b", "a:b", "a|b", "(a)", "$a"] {
        let body = format!("const paths = {{'fr': {}}};", crate::emit::dart_str(bad));
        let e = errors(&[("x/route.dart", &body), ("x/page.dart", &page("X"))]);
        assert_eq!(e.len(), 1, "`{bad}`: {e:?}");
        assert!(e[0].contains(&format!("`{bad}` is not a valid URL segment for `fr`")), "`{bad}`: {e:?}");
    }
    for good in ["produits", "a-b", "a_b", "v1.0", "A", "~a", "x9"] {
        let body = format!("const paths = {{'fr': '{good}'}};");
        assert_eq!(errors(&[("x/route.dart", &body), ("x/page.dart", &page("X"))]), Vec::<String>::new(), "`{good}`");
    }
}

#[test]
fn a_key_must_be_a_locale_tag_and_appear_once() {
    let e = errors(&[("x/route.dart", "const paths = {'french': 'a', 'f': 'b', '': 'c', 'fr!': 'd'};"), ("x/page.dart", &page("X"))]);
    assert_eq!(e.len(), 4, "{e:?}");
    assert!(e.iter().all(|m| m.contains("isn't a locale tag")), "{e:?}");
    for tag in ["fr", "pt-BR", "pt_BR", "zh-Hant-TW", "de"] {
        let body = format!("const paths = {{'{tag}': 'a'}};");
        assert_eq!(errors(&[("x/route.dart", &body), ("x/page.dart", &page("X"))]), Vec::<String>::new(), "{tag}");
    }
    let e = errors(&[("x/route.dart", "const paths = {\n  'fr': 'a',\n  'FR': 'b',\n  'pt-BR': 'c',\n  'pt_br': 'd',\n};"), ("x/page.dart", &page("X"))]);
    assert_eq!(e, ["✗ x/route.dart:3  `paths` has `FR` twice (the first is on line 2)", "✗ x/route.dart:5  `paths` has `pt_br` twice (the first is on line 4)"]);
}

#[test]
fn an_empty_map_is_a_warning() {
    let d = diags(&[("x/route.dart", "const paths = {};"), ("x/page.dart", &page("X"))]);
    assert_eq!(d, ["! x/route.dart:1  `paths` is empty, so it adds no spelling"]);
}

#[test]
fn paths_declared_twice_is_an_error() {
    let e = errors(&[("x/route.dart", "const paths = {'fr': 'a'};\nconst paths = {'fr': 'b'};"), ("x/page.dart", &page("X"))]);
    assert_eq!(e, ["✗ x/route.dart:2  `paths` is declared twice"]);
}

// --- colliding URLs -----------------------------------------------------------------------------

#[test]
fn a_spelling_that_is_a_sibling_folder_is_an_error_with_a_frame_on_both() {
    let e = errors(&[
        ("about/page.dart", &page("About")),
        ("products/route.dart", "const paths = {\n  'fr': 'about',\n};"),
        ("products/page.dart", &page("Products")),
    ]);
    assert_eq!(e.len(), 2, "{e:?}");
    // On the spelling in route.dart ...
    assert!(e.contains(&"✗ products/route.dart:2  `fr: 'about'` makes /about, which about/page.dart serves too; rename the spelling, or the folder it collides with".to_string()), "{e:?}");
    // ... and on the page it collides with.
    assert!(e.contains(&"✗ about/page.dart:1  /about is also reached through `fr: 'about'` in products/route.dart:2; rename the spelling, or this folder".to_string()), "{e:?}");
}

#[test]
fn a_collision_below_a_localized_folder_is_found_too() {
    let e = errors(&[
        ("a/page.dart", &page("A")),
        ("a/x/page.dart", &page("Ax")),
        ("b/route.dart", "const paths = {'fr': 'a'};"),
        ("b/x/page.dart", &page("Bx")),
    ]);
    assert_eq!(e.len(), 2, "{e:?}");
    assert!(e.iter().any(|m| m.starts_with("✗ b/route.dart:1  `fr: 'a'` makes /a/x, which a/x/page.dart serves too")), "{e:?}");
    assert!(e.iter().any(|m| m.starts_with("✗ a/x/page.dart:1  /a/x is also reached through `fr: 'a'` in b/route.dart:1")), "{e:?}");
}

#[test]
fn two_localized_folders_that_share_a_spelling_collide_at_both_entries() {
    let e = errors(&[
        ("a/route.dart", "const paths = {'fr': 'x'};"),
        ("a/page.dart", &page("A")),
        ("b/route.dart", "const paths = {'de': 'x'};"),
        ("b/page.dart", &page("B")),
    ]);
    assert_eq!(e.len(), 2, "{e:?}");
    assert!(e.iter().any(|m| m.starts_with("✗ a/route.dart:1  `fr: 'x'` makes /x, which b/page.dart (`de: 'x'` in b/route.dart) serves too")), "{e:?}");
    assert!(e.iter().any(|m| m.starts_with("✗ b/route.dart:1  `de: 'x'` makes /x, which a/page.dart (`fr: 'x'` in a/route.dart) serves too")), "{e:?}");
}

#[test]
fn a_spelling_equal_to_its_own_folder_or_another_locales_is_not_a_collision() {
    let c = code(&[
        ("menu/route.dart", "const paths = {'en': 'menu', 'fr': 'carte', 'de': 'carte'};"),
        ("menu/page.dart", &page("Menu")),
        ("carte-du-jour/page.dart", &page("Carte")),
    ]);
    has(&c, &[":_l0(menu|carte)"]);
}

#[test]
fn spellings_that_differ_only_below_a_dynamic_segment_do_not_collide() {
    // /a/:id/x and /b/:id/x are different URLs whatever the ids are.
    assert_eq!(
        errors(&[
            ("a/route.dart", "const paths = {'fr': 'c'};"),
            ("a/$id/x/page.dart", &page_with("Ax", "required this.id", "final String id;")),
            ("b/$id/x/page.dart", &page_with("Bx", "required this.id", "final String id;")),
        ]),
        Vec::<String>::new()
    );
}

#[test]
fn a_localized_route_a_dynamic_sibling_catches_is_reported_once() {
    // `(app)` holds `:id`, so `/:slug` comes before its shell and catches `/settings`. The
    // spellings change nothing about that: one error, at the page.
    let layout = "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }";
    let e = errors(&[
        ("$slug/page.dart", &page_with("Slug", "required this.slug", "final String slug;")),
        ("(app)/layout.dart", layout),
        ("(app)/settings/route.dart", "const paths = {'fr': 'reglages'};"),
        ("(app)/settings/page.dart", &page("Settings")),
        ("(app)/$id/page.dart", &page_with("Item", "required this.id", "final int id;")),
    ]);
    assert_eq!(e.len(), 2, "{e:?}");
    assert!(e[0].starts_with("✗ (app)/settings/page.dart:1  /settings is unreachable: $slug/page.dart (/:slug) comes first"), "{e:?}");
}

#[test]
fn a_static_route_with_more_spellings_catches_one_with_fewer() {
    // `a/`, spelled `x` too, and `a/b/` below it are different URLs, but route order only
    // looks at whole URLs: nothing here is caught, so nothing is reported.
    assert_eq!(
        errors(&[
            ("a/route.dart", "const paths = {'fr': 'x'};"),
            ("a/page.dart", &page("A")),
            ("a/b/page.dart", &page("Ab")),
        ]),
        Vec::<String>::new()
    );
}

// --- tabs ---------------------------------------------------------------------------------------

const TABS: &str =
    "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }";

#[test]
fn a_tab_that_opens_on_a_localized_route_gets_its_canonical_initial_location() {
    // go_router asserts that a tab's first route has no path parameter, which a localized
    // segment is; the tab is opened at its canonical location instead.
    let c = code(&[
        ("layout.dart", TABS),
        ("home/page.dart", &page("Home")),
        ("search/route.dart", "const paths = {'fr': 'recherche'};"),
        ("search/page.dart", &page("Search")),
    ]);
    has(&c, &["initialLocation: joinLocation(at, '/search'),", "path: joinLocation(at, '/:_l0(search|recherche)'),"]);
    // The other tab needs none.
    assert_eq!(c.matches("initialLocation: joinLocation(at").count(), 1, "{c}");
}

#[test]
fn a_tab_options_initial_location_wins_and_may_use_a_spelling() {
    let layout = format!("{TABS}\nconst tabOptions = {{'search': TabOptions(initialLocation: '/recherche')}};");
    let c = code(&[
        ("layout.dart", &layout),
        ("home/page.dart", &page("Home")),
        ("search/route.dart", "const paths = {'fr': 'recherche'};"),
        ("search/page.dart", &page("Search")),
    ]);
    has(&c, &["initialLocation: joinLocation(at, '/recherche'),"]);
    assert_eq!(c.matches("initialLocation: joinLocation(at").count(), 1, "{c}");
    // A spelling nobody has is still not a route of the tab.
    let layout = format!("{TABS}\nconst tabOptions = {{'search': TabOptions(initialLocation: '/buscar')}};");
    let e = errors(&[
        ("layout.dart", &layout),
        ("home/page.dart", &page("Home")),
        ("search/route.dart", "const paths = {'fr': 'recherche'};"),
        ("search/page.dart", &page("Search")),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("`initialLocation` `/buscar` is not a route in the `search` tab"), "{e:?}");
}

#[test]
fn a_localized_tab_below_a_segment_cannot_be_opened_and_says_so() {
    // The tab layout is nested in `shops/$shop`'s page, so its routes' own paths have no
    // parameter and go_router opens the tab on the current `:shop`. A localized first route
    // has one of its own now, and its canonical location can't be written with a `:shop` in it.
    let e = errors(&[
        ("shops/$shop/page.dart", &page_with("Shop", "required this.shop", "final String shop;")),
        ("shops/$shop/(tabs)/layout.dart", TABS),
        ("shops/$shop/(tabs)/home/page.dart", &page_with("Home", "required this.shop", "final String shop;")),
        ("shops/$shop/(tabs)/search/route.dart", "const paths = {'fr': 'recherche'};"),
        ("shops/$shop/(tabs)/search/page.dart", &page_with("Search", "required this.shop", "final String shop;")),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ shops/$shop/(tabs)/search/page.dart:1  /shops/:shop/search is the first route of a tab"), "{e:?}");
    assert!(e[0].contains("a localized segment is a path parameter"), "{e:?}");
}

// --- helpers --------------------------------------------------------------------------------------

#[test]
fn canonical_path_takes_the_first_alternative_of_each_localized_segment() {
    assert_eq!(canonical_path("/:_l0(products|produits)/:id"), "/products/:id");
    assert_eq!(canonical_path(":_l12(a|b|c)/:_l13(x)"), "a/x");
    assert_eq!(canonical_path(r"/:_l0(v1\.0|x)"), "/v1.0");
    assert_eq!(canonical_path("/docs/:rest(.+)"), "/docs/:rest(.+)");
    assert_eq!(canonical_path("/plain"), "/plain");
    // Not ours: a user's segment can't start with `_`, but the text is left alone anyway.
    assert_eq!(canonical_path("/:_l(a|b)"), "/:_l(a|b)");
}

#[test]
fn has_params_ignores_the_parameters_of_localized_segments() {
    assert!(!has_params("/:_l0(products|produits)"));
    assert!(has_params("/:_l0(products|produits)/:id"));
    assert!(has_params(":rest(.+)"));
    assert!(!has_params("products"));
    assert!(is_localized("/:_l0(a|b)"));
    assert!(!is_localized("/:id"));
}
