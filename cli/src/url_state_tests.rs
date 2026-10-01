//! `XRoute.of(context)`, `XRoute.maybeOf(context)` and `copyWith`: the URL as typed state.
//! What the generated code does at run time is checked by the examples' widget tests
//! (`examples/shop/test/url_state_test.dart`, `examples/features/test/url_state_test.dart`);
//! these tests pin what the generator writes. (The rest of the generator's tests are in
//! `tests.rs`.)

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
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn code_with(files: &[(&str, &str)], cfg: &Config) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn code(files: &[(&str, &str)]) -> String {
    code_with(files, &Config::default())
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

fn widget(class: &str, fields: &str, params: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key{params}}}); {fields} }}"
    )
}

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";
const SORT: &str = "enum Sort { price, name }\n";

/// A search page: an optional string, an optional int, an enum and a list.
fn search() -> String {
    format!(
        "{SORT}{}",
        widget(
            "SearchPage",
            "final String? q; final int? page; final Sort? sort; final List<String> tags;",
            ", this.q, this.page, this.sort, this.tags = const []",
        )
    )
}

/// The signature of `copyWith` as the generated code spells it, and the `_copyWith` behind it.
const SEARCH_COPY_WITH: &str = "SearchRoute Function({String? q, int? page, _i0.Sort? sort, List<String> tags}) get copyWith => _copyWith;";
const SEARCH_BODY: &str = "SearchRoute _copyWith({Object? q = _keep, Object? page = _keep, Object? sort = _keep, Object? tags = _keep}) =>\n      SearchRoute(q: _kept<String?>(q, this.q), page: _kept<int?>(page, this.page), sort: _kept<_i0.Sort?>(sort, this.sort), tags: _kept<List<String>>(tags, this.tags));";

#[test]
fn every_route_reads_its_own_location_with_of_and_maybe_of() {
    let c = code(&[("page.dart", HOME), ("search/page.dart", &search())]);
    has(
        &c,
        &[
            "static HomeRoute of(BuildContext context) => routeOf<HomeRoute>(context, AppRoutes.matchUrl);",
            "static HomeRoute? maybeOf(BuildContext context) => maybeRouteOf<HomeRoute>(context, AppRoutes.matchUrl);",
            "static SearchRoute of(BuildContext context) => routeOf<SearchRoute>(context, AppRoutes.matchUrl);",
            "static SearchRoute? maybeOf(BuildContext context) => maybeRouteOf<SearchRoute>(context, AppRoutes.matchUrl);",
        ],
    );
}

#[test]
fn copy_with_takes_every_query_parameter_and_is_typed_by_the_field() {
    let c = code(&[("search/page.dart", &search())]);
    // The public signature is the fields' own types: a function-typed getter, so it is
    // never `dynamic`, and `page: null` is a value of `int?`.
    has(&c, &[SEARCH_COPY_WITH, SEARCH_BODY]);
    // The constructor stays `const`: the sentinel does not touch it.
    has(
        &c,
        &["const SearchRoute({this.q, this.page, this.sort, this.tags = const []});"],
    );
}

#[test]
fn null_and_omitted_are_told_apart_by_a_private_const_sentinel() {
    let c = code(&[("search/page.dart", &search())]);
    has(
        &c,
        &[
            "final class _Keep {\n  const _Keep();\n}",
            "const _keep = _Keep();",
            "T _kept<T>(Object? value, T current) => identical(value, _keep) ? current : value as T;",
        ],
    );
    // Every default is the sentinel, and only the private one (a caller can't name it).
    assert_eq!(c.matches("= _keep").count(), 4, "{c}");
    assert_eq!(c.matches("final class _Keep").count(), 1, "{c}");
    // Never a public widening of the signature.
    lacks(
        &c,
        &["dynamic page", "Object? page,\n  })", "Route copyWith("],
    );
}

#[test]
fn required_segments_are_in_copy_with_but_cannot_be_cleared() {
    let c = code(&[(
        "products/$id/page.dart",
        &widget(
            "ProductPage",
            "final int id; final int? tab;",
            ", required this.id, this.tab",
        ),
    )]);
    // `int id` is not nullable in the signature, so `copyWith(id: null)` does not compile.
    has(
        &c,
        &[
            "ProductRoute Function({int id, int? tab}) get copyWith => _copyWith;",
            "ProductRoute _copyWith({Object? id = _keep, Object? tab = _keep}) =>\n      ProductRoute(id: _kept<int>(id, this.id), tab: _kept<int?>(tab, this.tab));",
        ],
    );
}

#[test]
fn a_list_is_cleared_with_an_empty_one_not_with_null() {
    let c = code(&[("search/page.dart", &search())]);
    has(&c, &["List<String> tags}) get copyWith"]);
    lacks(&c, &["List<String>? tags"]);
}

#[test]
fn enums_keep_their_type_in_copy_with() {
    let c = code(&[("search/page.dart", &search())]);
    has(&c, &["_i0.Sort? sort", "_kept<_i0.Sort?>(sort, this.sort)"]);
}

#[test]
fn catch_alls_are_parameters_of_copy_with() {
    let c = code(&[
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
                "final List<int> path;",
                ", this.path = const []",
            ),
        ),
    ]);
    has(
        &c,
        &[
            "DocsRoute Function({List<String> rest}) get copyWith => _copyWith;",
            "DocsRoute(rest: _kept<List<String>>(rest, this.rest))",
        ],
    );
    // A typed catch-all keeps its element type; the optional one still defaults to `const []`.
    has(
        &c,
        &["FilesRoute Function({List<int> path}) get copyWith => _copyWith;"],
    );
}

#[test]
fn a_localized_route_copies_into_the_same_route_and_reads_every_spelling() {
    let c = code(&[
        ("products/route.dart", "const paths = {'fr': 'produits'};"),
        (
            "products/$id/page.dart",
            &widget("ProductPage", "final int id;", ", required this.id"),
        ),
    ]);
    // `of` parses with `AppRoutes.matchUrl`, which knows the spellings; a copy is the same
    // value type, and `locationFor` / `go(locale:)` still choose the spelling.
    has(
        &c,
        &[
            "routeOf<ProductRoute>(context, AppRoutes.matchUrl)",
            "ProductRoute Function({int id}) get copyWith => _copyWith;",
            "String locationFor(String? _locale)",
        ],
    );
}

#[test]
fn of_goes_through_the_parser_that_honours_the_mount_point_and_the_case_setting() {
    let cfg = Config {
        case_sensitive: false,
        ..Config::default()
    };
    let c = code_with(&[("search/page.dart", &search())], &cfg);
    // `AppRoutes.matchUrl` takes the mount point off and passes the case setting down:
    // `of` never builds its own matcher.
    has(
        &c,
        &[
            "static UrlMatch? matchUrl(Uri uri) => matchRoutes(uri, base, _matchers, caseSensitive: false);",
            "routeOf<SearchRoute>(context, AppRoutes.matchUrl)",
        ],
    );
}

#[test]
fn a_tree_without_parameters_has_no_copy_with_and_no_sentinel() {
    let about = HOME.replace("Home", "About");
    let c = code(&[("page.dart", HOME), ("about/page.dart", &about)]);
    has(&c, &["static HomeRoute of(", "static AboutRoute? maybeOf("]);
    lacks(&c, &["copyWith", "_Keep", "_keep", "_kept"]);
}

#[test]
fn the_sentinel_is_written_once_however_many_routes_have_parameters() {
    let c = code(&[
        ("search/page.dart", &search()),
        (
            "products/$id/page.dart",
            &widget("ProductPage", "final int id;", ", required this.id"),
        ),
        (
            "users/$name/page.dart",
            &widget("UserPage", "final String name;", ", required this.name"),
        ),
    ]);
    assert_eq!(c.matches("final class _Keep").count(), 1, "{c}");
    assert_eq!(c.matches("const _keep = _Keep();").count(), 1, "{c}");
    assert_eq!(c.matches("T _kept<T>(").count(), 1, "{c}");
}

#[test]
fn the_output_is_deterministic() {
    let files = [("search/page.dart", search())];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    assert_eq!(code(&files), code(&files));
}

#[test]
fn of_maybe_of_and_copy_with_are_reserved_names() {
    let e = diags(&[
        ("$of/page.dart", HOME),
        ("$maybeOf/page.dart", HOME),
        ("$copyWith/page.dart", HOME),
    ])
    .join("\n");
    for name in ["of", "maybeOf", "copyWith"] {
        assert!(e.contains(&format!("`${name}` is reserved")), "{e}");
    }
    // A catch-all can't take them either.
    let e = diags(&[("docs/$$of/page.dart", HOME)]).join("\n");
    assert!(e.contains("`$$of` is reserved"), "{e}");
    // The route class has these members, so a query parameter can't be called that.
    for name in ["of", "maybeOf", "copyWith"] {
        let e = diags(&[(
            "page.dart",
            &widget(
                "HomePage",
                &format!("final bool? {name};"),
                &format!(", this.{name}"),
            ),
        )])
        .join("\n");
        assert!(
            e.contains(&format!("`{name}` can't be a query parameter")),
            "{e}"
        );
    }
}

#[test]
fn a_sections_data_keys_may_still_be_called_of() {
    // The section's typed handle has no `of`: only the route class does.
    let e = diags(&[
        (
            "(shop)/data.dart",
            "Future<int> data(Ref ref, {int? of}) async => 1;",
        ),
        (
            "(shop)/layout.dart",
            "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("(shop)/a/page.dart", HOME),
    ]);
    assert!(!e.iter().any(|m| m.contains("can't be a key")), "{e:?}");
}
