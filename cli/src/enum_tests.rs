//! Enum segments, query parameters and catch-alls: `Category category`, `Sort? sort`,
//! `List<Category> path`. (The plain types are tested in `tests.rs`, `paths_tests.rs` and
//! `rest_types_tests.rs`.)

use std::fs;

use crate::config::Config;
use crate::{analyze, dart, routes};

/// A project whose files are given relative to `lib/`: `app/shop/$category/page.dart`,
/// `models/category.dart`. The package is called `demo`.
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

fn diags(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    diags(files)
        .into_iter()
        .filter(|d| d.starts_with('✗'))
        .collect()
}

fn code_with(files: &[(&str, &str)], cfg: &Config) -> String {
    let dir = project(files);
    let (code, diags, _) = analyze(&dir.path().join("lib/app"), cfg).unwrap();
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

const CATEGORY: &str = "enum Category { shoes, hats }\n";

/// A page with the given constructor parameters and fields.
fn page(name: &str, ctor: &str, fields: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key{ctor}}}); {fields} }}"
    )
}

fn shop(imports: &str, ty: &str) -> String {
    format!(
        "{imports}\n{}",
        page(
            "Shop",
            ", required this.category",
            &format!("final {ty} category;")
        )
    )
}

#[test]
fn reads_enums_and_exports() {
    let m = dart::parse(
        "import 'a.dart';\nexport 'b.dart' show B;\nexport \"c.dart\";\nenum Category { shoes, hats }\nenum Mode with M implements I { a(1), b(2); const Mode(this.n); final int n; }\nclass NotAnEnum {}\nenum _Private { x }\n",
    );
    assert_eq!(m.enums, ["Category", "Mode", "_Private"]);
    assert_eq!(m.exports, ["b.dart", "c.dart"]);
}

#[test]
fn an_enum_declared_in_the_view_is_a_segment() {
    let p = format!("{CATEGORY}{}", shop("", "Category"));
    let c = code(&[("app/shop/$category/page.dart", &p)]);
    has(
        &c,
        &[
            // The generated file reaches it through the view's own import.
            "({_i0.Category category}) _params2(GoRouterState s) => (category: Segment.asEnum(s, 'category', _i0.Category.values));",
            // The typed route's field has the enum's type, and the location writes its name.
            "final _i0.Category category;",
            "const ShopRoute({required this.category});",
            "joinLocation(AppRoutes.base, '/shop/${category.name}')",
            // A bad name is a BadSegment, which renders not-found like `/products/abc`.
            "() => _params2(state),",
            "() => notFound(state.uri),",
            "RouteParam('category', 'Category')",
            // What AppRoutes.match parses.
            "final p = _params2(s);",
            "{'category': p.category}",
        ],
    );
    lacks(&c, &["Uri.encodeComponent", "show Category"]);
}

#[test]
fn an_enum_from_a_relative_import_is_imported_into_the_generated_file() {
    let c = code(&[
        (
            "app/shop/$category/page.dart",
            &shop("import '../../../models/category.dart';", "Category"),
        ),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            // The way extra types are: `show`n from the view's imports, and the path is the
            // generated file's.
            "import 'models/category.dart' show Category;",
            "(category: Segment.asEnum(s, 'category', Category.values))",
            "final Category category;",
        ],
    );
}

#[test]
fn package_imports_and_barrel_files_are_followed() {
    let c = code(&[
        (
            "app/shop/$category/page.dart",
            &shop("import 'package:demo/models/models.dart';", "Category"),
        ),
        (
            "models/models.dart",
            "export 'src/category.dart' show Category;\nexport 'src/other.dart';\n",
        ),
        ("models/src/category.dart", CATEGORY),
        ("models/src/other.dart", "class Other {}\n"),
    ]);
    has(
        &c,
        &[
            "import 'package:demo/models/models.dart' show Category;",
            "Segment.asEnum(s, 'category', Category.values)",
        ],
    );
    // Files that export each other don't loop.
    let e = errors(&[
        (
            "app/shop/$category/page.dart",
            &shop("import 'a.dart';", "Category"),
        ),
        ("app/shop/$category/a.dart", "export 'b.dart';\n"),
        ("app/shop/$category/b.dart", "export 'a.dart';\n"),
    ]);
    assert!(
        e.iter().any(|m| m.contains("no enum called `Category`")),
        "{e:?}"
    );
}

#[test]
fn a_prefixed_enum_keeps_its_import_under_a_prefix_of_its_own() {
    let c = code(&[
        (
            "app/shop/$category/page.dart",
            &shop("import '../../../models/category.dart' as m;", "m.Category"),
        ),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            "import 'models/category.dart' as _es2_m;",
            "({_es2_m.Category category}) _params2",
            "Segment.asEnum(s, 'category', _es2_m.Category.values)",
            "final _es2_m.Category category;",
            // The manifest names the type as the app does.
            "RouteParam('category', 'Category')",
        ],
    );
    // Through the prefix only: the same name from another import isn't this one.
    let e = errors(&[
        (
            "app/shop/$category/page.dart",
            &shop(
                "import '../../../models/category.dart';\nimport '../../../models/other.dart' as m;",
                "m.Category",
            ),
        ),
        ("models/category.dart", CATEGORY),
        ("models/other.dart", "class Other {}"),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("`m.Category category`: no enum called `m.Category`")),
        "{e:?}"
    );
}

#[test]
fn a_type_that_is_not_a_found_enum_is_an_error_that_suggests_string() {
    let class = ("models/category.dart", "class Category {}");
    let cases = [
        // Not declared anywhere.
        ("", None),
        // A class is not an enum.
        ("import '../../../models/category.dart';", Some(class)),
        // From a package, whose files aren't read.
        ("import 'package:other/other.dart';", None),
        // From a file the view doesn't import.
        ("", Some(("models/category.dart", CATEGORY))),
    ];
    for (imports, extra) in cases {
        let page = shop(imports, "Category");
        let mut files = vec![("app/shop/$category/page.dart", page.as_str())];
        files.extend(extra);
        let e = errors(&files);
        assert_eq!(e.len(), 1, "{imports}: {e:?}");
        assert!(
            e[0].starts_with(
                "✗ shop/$category/page.dart:2  `Category category`: no enum called `Category`"
            ),
            "{e:?}"
        );
        assert!(
            e[0].contains("take a `String category` and parse it in the page"),
            "{e:?}"
        );
    }
}

#[test]
fn a_private_enum_is_an_error() {
    let p = format!("enum _Mode {{ a }}\n{}", shop("", "_Mode"));
    let e = errors(&[("app/shop/$category/page.dart", &p)]);
    assert!(
        e.iter()
            .any(|m| m.contains("`_Mode category`: `_Mode` is private to its file")),
        "{e:?}"
    );
}

#[test]
fn what_is_not_a_type_name_keeps_the_old_errors() {
    for ty in [
        "List<int>",
        "int?",
        "Object",
        "DateTime",
        "Map<String, int>",
    ] {
        let e = errors(&[("app/shop/$category/page.dart", &shop("", ty))]);
        assert!(
            e.iter().any(|m| m.contains(&format!(
                "`{ty} category`: segments are String, int, double or bool, or an enum"
            ))),
            "{ty}: {e:?}"
        );
    }
    // A plain type that is no enum's is not looked for: String, int, double, bool stay as they were.
    for ty in ["String", "int", "double", "bool"] {
        assert!(
            errors(&[("app/shop/$category/page.dart", &shop("", ty))]).is_empty(),
            "{ty}"
        );
    }
}

#[test]
fn the_files_of_a_segment_agree_on_the_enum() {
    let files = |data_ty: &str, data_imports: &str| {
        [
            (
                "app/shop/$category/page.dart",
                shop("import '../../../models/category.dart';", "Category"),
            ),
            (
                "app/shop/$category/data.dart",
                format!(
                    "{data_imports}\nFuture<int> data(Ref ref, {{required {data_ty} category}}) async => 1;"
                ),
            ),
            (
                "models/category.dart",
                format!("{CATEGORY}enum Size {{ s, m }}"),
            ),
            ("models/other.dart", "enum Category { a }".to_string()),
        ]
    };
    let run = |f: [(&str, String); 4]| {
        let f: Vec<(&str, &str)> = f.iter().map(|(p, b)| (*p, b.as_str())).collect();
        errors(&f)
    };
    // The same enum, however it is spelled, is one type.
    assert!(
        run(files(
            "m.Category",
            "import '../../../models/category.dart' as m;"
        ))
        .is_empty()
    );
    assert!(
        run(files(
            "Category",
            "import 'package:demo/models/category.dart';"
        ))
        .is_empty()
    );
    // Another enum is another type: the error the plain types give.
    let e = run(files("Size", "import '../../../models/category.dart';"));
    assert_eq!(
        e,
        vec![
            "✗ shop/$category/page.dart:2  `$category` is Size in shop/$category/data.dart:2 but Category here"
        ]
    );
    // Even one of the same name.
    let e = run(files("Category", "import '../../../models/other.dart';"));
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("`$category` is Category in shop/$category/data.dart:2 but Category here (two different enums: lib/models/other.dart and lib/models/category.dart)"), "{e:?}");
    // And an enum is not a String.
    let e = run(files("String", ""));
    assert!(
        e.iter()
            .any(|m| m.contains("is String in shop/$category/data.dart:2 but Category here")),
        "{e:?}"
    );
}

#[test]
fn data_providers_are_keyed_by_the_enum() {
    let data = "import '../../../models/category.dart';\nFuture<List<String>> data(Ref ref, {required Category category, int? page}) async => [];";
    let p = format!(
        "import '../../../models/category.dart';\n{}",
        page(
            "Shop",
            ", required this.category, this.page, required this.data",
            "final Category category; final int? page; final List<String> data;"
        )
    );
    let c = code(&[
        ("app/shop/$category/page.dart", &p),
        ("app/shop/$category/data.dart", data),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            // An enum is hashable, so it keys the family as it is.
            "(Ref ref, ({Category category, int? page}) k) => _i0.data(ref, category: k.category, page: k.page),",
            "static final watch = (WidgetRef ref, {required Category category, int? page}) => ref.watch(data((category: category, page: page)));",
            // What AppRoutes.dataAt watches: the very provider, keyed by the parsed enum.
            "_data2((category: p.category, page: p.page))",
        ],
    );
    // A provider of the app's own.
    let data = "import '../../../models/category.dart';\nfinal data = FutureProvider.family<List<String>, Category>((ref, c) async => []);";
    let p = format!(
        "import '../../../models/category.dart';\n{}",
        page(
            "Shop",
            ", required this.category, required this.data",
            "final Category category; final List<String> data;"
        )
    );
    let c = code(&[
        ("app/shop/$category/page.dart", &p),
        ("app/shop/$category/data.dart", data),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            "_i0.data(v.category)",
            "static final watch = (WidgetRef ref, {required Category category}) => ref.watch(data(category));",
        ],
    );
}

#[test]
fn an_enum_query_parameter_is_optional_and_null_when_it_names_nothing() {
    let p = format!(
        "{CATEGORY}enum Sort {{ price, name }}\n{}",
        page(
            "Shop",
            ", required this.category, this.sort, this.sorts = const []",
            "final Category category; final Sort? sort; final List<Sort> sorts;"
        )
    );
    let c = code(&[("app/shop/$category/page.dart", &p)]);
    has(
        &c,
        &[
            "({_i0.Category category, _i0.Sort? sort, List<_i0.Sort> sorts}) _params2(GoRouterState s) => (category: Segment.asEnum(s, 'category', _i0.Category.values), sort: Query.asEnum(s, 'sort', _i0.Sort.values), sorts: Query.asEnumList(s, 'sorts', _i0.Sort.values));",
            "const ShopRoute({required this.category, this.sort, this.sorts = const []});",
            "final _i0.Sort? sort;",
            "final List<_i0.Sort> sorts;",
            // `withQuery` writes an enum by its name.
            "withQuery(joinLocation(AppRoutes.base, '/shop/${category.name}'), {'sort': sort, 'sorts': sorts})",
            "query: [RouteParam('sort', 'Sort?'), RouteParam('sorts', 'List<Sort>')]",
        ],
    );
}

#[test]
fn a_data_dart_can_take_an_enum_query_parameter() {
    let data = "import '../../models/category.dart';\nFuture<int> data(Ref ref, {Category? only, List<Category> not = const []}) async => 1;";
    let p = "import '../../models/category.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, required this.n, this.only, this.not = const []}); final int n; final Category? only; final List<Category> not; }";
    let c = code(&[
        ("app/shop/page.dart", p),
        ("app/shop/data.dart", data),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            "Query.asEnum(s, 'only', Category.values)",
            "Query.asEnumList(s, 'not', Category.values)",
            // A list is a QueryList in the key, enum or not.
            "(Ref ref, ({Category? only, QueryList<Category> not}) k) => _i0.data(ref, only: k.only, not: k.not),",
            "QueryList(p.not)",
        ],
    );
    // The query is not a segment: what data.dart can't find is an error at the parameter.
    let data = "Future<int> data(Ref ref, {Category? only}) async => 1;";
    let e = errors(&[
        (
            "app/shop/page.dart",
            &page("Shop", ", required this.n", "final int n;"),
        ),
        ("app/shop/data.dart", data),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].starts_with("✗ shop/data.dart:1  `Category? only`: no enum called `Category`"),
        "{e:?}"
    );
    assert!(e[0].contains("take a `String? only`"), "{e:?}");
    let data = "Future<int> data(Ref ref, {List<Category> only = const []}) async => 1;";
    let e = errors(&[
        (
            "app/shop/page.dart",
            &page("Shop", ", required this.n", "final int n;"),
        ),
        ("app/shop/data.dart", data),
    ]);
    assert!(
        e.iter().any(|m| m.contains("take a `List<String> only`")),
        "{e:?}"
    );
}

#[test]
fn an_optional_parameter_of_another_type_is_still_left_alone() {
    // `Color?` is nothing fsp can find an enum for: as before, it keeps its default.
    let p = page(
        "Home",
        ", this.color, this.tint = const []",
        "final Color? color; final List<Color> tint;",
    );
    let c = code(&[("app/page.dart", &p)]);
    has(&c, &["const HomeRoute()"]);
    lacks(&c, &["color"]);
}

#[test]
fn an_enum_query_parameter_must_agree_between_files() {
    let data =
        "import '../../models/category.dart';\nFuture<int> data(Ref ref, {Size? only}) async => 1;";
    let p = "import '../../models/category.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, required this.n, this.only}); final int n; final Category? only; }";
    let files = [
        ("app/shop/page.dart", p),
        ("app/shop/data.dart", data),
        (
            "models/category.dart",
            "enum Category { a }\nenum Size { s }",
        ),
    ];
    let e = errors(&files);
    assert_eq!(
        e,
        vec!["✗ shop/page.dart:2  `?only` is Size? in shop/data.dart:2 but Category? here"]
    );
}

#[test]
fn a_catch_all_can_be_a_list_of_an_enum() {
    let p = format!(
        "{CATEGORY}{}",
        page(
            "Browse",
            ", required this.path",
            "final List<Category> path;"
        )
    );
    let c = code(&[("app/browse/$$path/page.dart", &p)]);
    has(
        &c,
        &[
            "({List<_i0.Category> path}) _params2(GoRouterState s) => (path: Segment.asEnumRest(s, 'path', _i0.Category.values));",
            "final List<_i0.Category> path;",
            // Each part written as its name, encoded on its own, by the same function as any part.
            "return joinLocation(AppRoutes.base, '/browse${restPath(path)}');",
            "assert(path.isNotEmpty, 'BrowseRoute needs at least one part in `path`",
            "RouteParam('path', 'List<Category>', catchAll: true)",
        ],
    );
    // Optional too.
    let p = format!(
        "{CATEGORY}{}",
        page(
            "Browse",
            ", this.path = const []",
            "final List<Category> path;"
        )
    );
    let c = code(&[("app/browse/$$$path/page.dart", &p)]);
    has(
        &c,
        &[
            "const BrowseRoute({this.path = const []});",
            "Segment.asEnumRest(s, 'path', _i0.Category.values)",
        ],
    );
    // A list of something that isn't an enum is still the old error.
    let e = errors(&[(
        "app/browse/$$path/page.dart",
        &page("Browse", ", required this.path", "final List<Object> path;"),
    )]);
    assert!(e.iter().any(|m| m.contains("a catch-all segment is the rest of the path, a `List` of String, int, double, num, bool or DateTime, or of an enum")));
    let e = errors(&[(
        "app/browse/$$path/page.dart",
        &page(
            "Browse",
            ", required this.path",
            "final List<Category> path;",
        ),
    )]);
    assert!(
        e.iter().any(
            |m| m.contains("`List<Category> path`: no enum called `Category`")
                && m.contains("take a `List<String> path`")
        ),
        "{e:?}"
    );
}

#[test]
fn data_keyed_by_an_enum_catch_all_is_keyed_by_its_path() {
    let data = "import '../../../models/category.dart';\nFuture<int> data(Ref ref, {required List<Category> path}) async => path.length;";
    let p = "import '../../../models/category.dart';\nclass BrowsePage extends StatelessWidget { const BrowsePage({super.key, required this.path, required this.data}); final List<Category> path; final int data; }";
    let c = code(&[
        ("app/browse/$$path/page.dart", p),
        ("app/browse/$$path/data.dart", data),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            "restKey(v.path)",
            // The path was built from the names of the parts that parsed.
            "(Ref ref, String path) => _i0.data(ref, path: restParts(path).map(Category.values.byName).toList()),",
            "static final watch = (WidgetRef ref, {required List<Category> path}) => ref.watch(data(restKey(path)));",
        ],
    );
}

#[test]
fn case_follows_the_routes_case_sensitive() {
    let p = format!("{CATEGORY}{}", shop("", "Category"));
    let cfg = Config {
        case_sensitive: false,
        ..Config::default()
    };
    let c = code_with(&[("app/shop/$category/page.dart", &p)], &cfg);
    has(
        &c,
        &["Segment.asEnum(s, 'category', _i0.Category.values, caseSensitive: false)"],
    );
    // A route.dart decides for its folder and below.
    let c = code(&[
        ("app/shop/$category/page.dart", &p),
        ("app/shop/route.dart", "const caseSensitive = false;"),
        (
            "app/other/$category/page.dart",
            &page(
                "Other",
                ", required this.category",
                "final String category;",
            ),
        ),
    ]);
    has(
        &c,
        &["Segment.asEnum(s, 'category', _i1.Category.values, caseSensitive: false)"],
    );
    let c = code(&[("app/shop/$category/page.dart", &p)]);
    has(&c, &["Segment.asEnum(s, 'category', _i0.Category.values)"]);
    lacks(&c, &["caseSensitive: false)"]);
    // Query parameters and catch-alls too.
    let q = format!(
        "{CATEGORY}{}",
        page(
            "Shop",
            ", this.only, required this.path",
            "final Category? only; final List<Category> path;"
        )
    );
    let c = code_with(&[("app/shop/$$path/page.dart", &q)], &cfg);
    has(
        &c,
        &[
            "Segment.asEnumRest(s, 'path', _i0.Category.values, caseSensitive: false)",
            "Query.asEnum(s, 'only', _i0.Category.values, caseSensitive: false)",
        ],
    );
}

#[test]
fn loading_views_see_the_enum_and_not_found_sees_its_name() {
    let import = "import '../../../models/category.dart';";
    let loading = format!(
        "{import}\nclass ShopLoading extends StatelessWidget {{ const ShopLoading({{super.key, required this.category}}); final Category category; }}"
    );
    let not_found = "class ShopNotFound extends StatelessWidget { const ShopNotFound({super.key, required this.category}); final String category; }";
    let p = format!(
        "{import}\n{}",
        page(
            "Shop",
            ", required this.category, required this.data",
            "final Category category; final int data;"
        )
    );
    let data =
        format!("{import}\nFuture<int> data(Ref ref, {{required Category category}}) async => 1;");
    let c = code(&[
        ("app/shop/$category/page.dart", &p),
        ("app/shop/$category/data.dart", &data),
        ("app/shop/$category/loading.dart", &loading),
        ("app/shop/$category/not_found.dart", not_found),
        ("models/category.dart", CATEGORY),
    ]);
    has(
        &c,
        &[
            "ShopLoading(category: v.category)",
            "ShopNotFound(category: state.pathParameters['category']!)",
        ],
    );
    // A not_found.dart gets what the URL spells, which is why it is shown.
    let nf = format!(
        "{import}\nclass ShopNotFound extends StatelessWidget {{ const ShopNotFound({{super.key, required this.category}}); final Category category; }}"
    );
    let e = errors(&[
        ("app/shop/$category/page.dart", &p),
        ("app/shop/$category/data.dart", &data),
        ("app/shop/$category/not_found.dart", &nf),
        ("models/category.dart", CATEGORY),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("gets the segment as the URL spells it, a String")),
        "{e:?}"
    );
}

#[test]
fn guards_and_layouts_read_enum_segments_too() {
    let guard = "import '../../../models/category.dart';\nGuardResult guard(ProviderContainer c, {required Category category}) => null;";
    let layout = "import '../../../models/category.dart';\nclass ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child, required this.category}); final Widget child; final Category category; }";
    let c = code(&[
        (
            "app/shop/$category/page.dart",
            &shop("import '../../../models/category.dart';", "Category"),
        ),
        ("app/shop/$category/guard.dart", guard),
        ("app/shop/$category/layout.dart", layout),
        ("models/category.dart", CATEGORY),
    ]);
    has(&c, &["Segment.asEnum(s, 'category', Category.values)"]);
    // The page and the guard share the route's parser; the layout has its own.
    assert_eq!(
        c.matches("Segment.asEnum(s, 'category', Category.values)")
            .count(),
        2,
        "{c}"
    );
}

#[test]
fn routes_show_the_type_name() {
    let dir = project(&[
        (
            "app/shop/$category/page.dart",
            &format!(
                "{CATEGORY}enum Sort {{ a }}\n{}",
                page(
                    "Shop",
                    ", required this.category, this.sorts = const []",
                    "final Category category; final List<Sort> sorts;"
                )
            ),
        ),
        (
            "app/browse/$$path/page.dart",
            &format!(
                "import '../../../models/category.dart' as m;\n{}",
                page(
                    "Browse",
                    ", required this.path",
                    "final List<m.Category> path;"
                )
            ),
        ),
        ("models/category.dart", CATEGORY),
    ]);
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let json = routes::json_lines(&app, "lib/app");
    let shop: serde_json::Value =
        serde_json::from_str(json.iter().find(|l| l.contains("/shop/")).unwrap()).unwrap();
    assert_eq!(
        shop["params"],
        serde_json::json!([
            {"name": "category", "type": "Category", "in": "path"},
            {"name": "sorts", "type": "List<Sort>", "in": "query"},
        ])
    );
    // A prefix is the file's business, not the route's.
    let browse: serde_json::Value =
        serde_json::from_str(json.iter().find(|l| l.contains("/browse/")).unwrap()).unwrap();
    assert_eq!(
        browse["params"],
        serde_json::json!([{"name": "path", "type": "List<Category>", "in": "path"}])
    );
    // The generated code has the spelling its own file needs.
    let folder = app
        .routes
        .iter()
        .position(|r| r.dir == "shop/$category")
        .unwrap();
    assert!(
        app.seg_type(folder).starts_with("_i") && app.seg_type(folder).ends_with(".Category"),
        "{}",
        app.seg_type(folder)
    );
    assert_eq!(app.display_type(app.seg_type(folder)), "Category");
}

#[test]
fn fsp_new_below_an_enum_segment_uses_its_name() {
    let dir = project(&[(
        "app/shop/$category/page.dart",
        &format!("{CATEGORY}{}", shop("", "Category")),
    )]);
    let args = crate::scaffold::NewArgs {
        route: "shop/[category]/reviews".into(),
        name: None,
        function: false,
        not_found: false,
        data: true,
        loading: false,
        error: false,
        layout: false,
        guard: false,
        transition: false,
    };
    crate::scaffold::new_route(dir.path(), &args).unwrap();
    // The type is the name the app writes; the new file imports the enum itself.
    let data =
        fs::read_to_string(dir.path().join("lib/app/shop/$category/reviews/data.dart")).unwrap();
    assert!(data.contains("required Category category"), "{data}");
}

#[test]
fn the_libs_find_declarations_the_way_imports_do() {
    use crate::enums::{Libs, Lookup};
    let dir = project(&[
        ("app/shop/page.dart", ""),
        ("models/category.dart", CATEGORY),
        ("models/all.dart", "export 'category.dart';"),
        (
            "models/sub/deeper.dart",
            "import '../all.dart';\nenum Deep { a }",
        ),
    ]);
    let app_dir = dir.path().join("lib/app");
    let find = |src: &str, ty: &str| {
        Libs::for_app(&app_dir, &Config::default()).find("shop/page.dart", src, ty)
    };
    let found = |l: Lookup| match l {
        Lookup::Found(f) => f.decl,
        other => format!("{other:?}"),
    };
    assert_eq!(
        found(find("import '../../models/category.dart';", "Category")),
        "lib/models/category.dart"
    );
    assert_eq!(
        found(find("import '../../models/all.dart';", "Category")),
        "lib/models/category.dart"
    );
    assert_eq!(
        found(find("import 'package:demo/models/all.dart';", "Category")),
        "lib/models/category.dart"
    );
    assert_eq!(
        found(find(
            "import 'package:demo/models/all.dart' as m;",
            "m.Category"
        )),
        "lib/models/category.dart"
    );
    // Enums the imported file only imports are not its own to give.
    assert_eq!(
        found(find("import '../../models/sub/deeper.dart';", "Category")),
        "Missing"
    );
    assert_eq!(
        found(find("import '../../models/sub/deeper.dart';", "Deep")),
        "lib/models/sub/deeper.dart"
    );
    // The file itself, and what isn't readable.
    assert_eq!(
        found(find("enum Mine { a }", "Mine")),
        "lib/app/shop/page.dart"
    );
    assert_eq!(
        found(find("import 'package:other/category.dart';", "Category")),
        "Missing"
    );
    assert_eq!(
        found(find(
            "import 'dart:ui';\nimport '../../../../escape.dart';",
            "Category"
        )),
        "Missing"
    );
    assert_eq!(
        found(find("import '../../models/missing.dart';", "Category")),
        "Missing"
    );
    assert_eq!(found(find("", "_Mode")), "Private");
}

#[test]
fn only_type_names_are_candidates() {
    use crate::enums::{enum_base, is_candidate, query_shape};
    for ty in ["Category", "m.Category", "_Private", "X"] {
        assert!(is_candidate(ty), "{ty}");
    }
    for ty in [
        "int",
        "String",
        "Object",
        "DateTime",
        "List<int>",
        "int?",
        "m.",
        "",
        "x.y.Z",
        "Map<A, B>",
        "Future",
    ] {
        assert!(!is_candidate(ty), "{ty}");
    }
    assert_eq!(query_shape("Sort?"), Some(("Sort", false)));
    assert_eq!(query_shape("List<Sort>"), Some(("Sort", true)));
    assert_eq!(query_shape("List<m.Sort>?"), Some(("m.Sort", true)));
    assert_eq!(query_shape("Sort"), None);
    assert_eq!(query_shape("int?"), None);
    assert_eq!(query_shape("List<int?>"), None);
    assert_eq!(enum_base("_i3.Category"), Some("_i3.Category"));
    assert_eq!(enum_base("List<_es2_m.Category>"), Some("_es2_m.Category"));
    assert_eq!(enum_base("Sort?"), Some("Sort"));
    assert_eq!(enum_base("List<int>"), None);
    assert_eq!(enum_base("DateTime"), None);
    assert_eq!(enum_base("String?"), None);
}
