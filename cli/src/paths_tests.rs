//! Catch-all segments, case-insensitive paths and typed `extra`. (The rest of the
//! generator's tests are in `tests.rs`.)

use std::fs;

use crate::build;
use crate::config::{Config, Pubspec};
use crate::scaffold;
use crate::scan::{Seg, parse_segment};

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

/// Just the errors: a warning (a page that doesn't take its data) isn't one.
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

fn at(code: &str, needle: &str) -> usize {
    code.find(needle)
        .unwrap_or_else(|| panic!("missing `{needle}` in:\n{code}"))
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn page_with(name: &str, params: &str, fields: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, {params}}}); {fields} }}"
    )
}

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

const DOCS: &str = "class DocsPage extends StatelessWidget { const DocsPage({super.key, required this.rest}); final List<String> rest; }";

// ---- catch-all segments ----

#[test]
fn folder_names_parse_into_catch_alls() {
    assert_eq!(
        parse_segment("$$rest"),
        Ok(Seg::CatchAll("rest".into(), false))
    );
    assert_eq!(
        parse_segment("$$$path"),
        Ok(Seg::CatchAll("path".into(), true))
    );
    assert_eq!(parse_segment("$id"), Ok(Seg::Dynamic("id".into())));
    for bad in ["$$", "$$$", "$$Rest", "$$1a", "$$a-b", "$$$$x"] {
        let msg = parse_segment(bad).unwrap_err();
        assert!(msg.contains("catch-all"), "{bad}: {msg}");
    }
    assert!(parse_segment("$$extra").unwrap_err().contains("reserved"));
    assert!(parse_segment("$extra").unwrap_err().contains("reserved"));
}

#[test]
fn a_catch_all_is_a_go_router_parameter_with_its_own_pattern() {
    let c = code(&[("page.dart", HOME), ("docs/$$rest/page.dart", DOCS)]);
    has(
        &c,
        &[
            "//   /docs/*rest  DocsRoute",
            "path: 'docs/:rest(.+)'",
            "const DocsRoute({required this.rest});",
            "final List<String> rest;",
            "({List<String> rest}) _params",
            "(rest: Segment.asRest(s, 'rest'));",
            "_i1.DocsPage(rest: v.rest)",
            // Each part is encoded on its own.
            "joinLocation(AppRoutes.base, '/docs${restPath(rest)}')",
            "assert(rest.isNotEmpty,",
        ],
    );
}

#[test]
fn a_catch_all_at_the_root_and_at_the_top_level_of_a_mount() {
    let c = code(&[(
        "$$all/page.dart",
        &page_with("All", "required this.all", "final List<String> all;"),
    )]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/:all(.+)')",
            "joinLocation(AppRoutes.base, '/${restKey(all)}')",
        ],
    );
    let c = code(&[("docs/$$rest/page.dart", DOCS)]);
    has(&c, &["path: joinLocation(at, '/docs/:rest(.+)')"]);
}

#[test]
fn a_catch_all_is_tried_after_static_and_dynamic_siblings() {
    // `$$rest` sorts before the others by name, and must still come last.
    let c = code(&[
        ("docs/$$rest/page.dart", DOCS),
        (
            "docs/$id/page.dart",
            &page_with("Doc", "required this.id", "final String id;"),
        ),
        ("docs/new/page.dart", &page("NewDoc")),
        ("docs/page.dart", &page("Index")),
    ]);
    let (new, id, rest) = (
        at(&c, "path: 'new'"),
        at(&c, "path: ':id'"),
        at(&c, "path: ':rest(.+)'"),
    );
    assert!(new < id && id < rest, "{c}");
}

#[test]
fn a_catch_all_in_a_group_is_tried_after_the_siblings_outside_it() {
    let c = code(&[
        (
            "(wiki)/layout.dart",
            "class WikiLayout extends StatelessWidget { const WikiLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("(wiki)/docs/$$rest/page.dart", DOCS),
        ("docs/new/page.dart", &page("NewDoc")),
    ]);
    // The group is a ShellRoute holding the catch-all, so it goes after the static route.
    assert!(
        at(&c, "path: joinLocation(at, '/docs/new')") < at(&c, "ShellRoute("),
        "{c}"
    );
}

#[test]
fn a_catch_all_behind_a_dynamic_route_in_another_shell_is_unreachable_only_if_it_is_caught() {
    // `/docs/*rest` is caught by an earlier `/:a/:b`? No: it takes any depth, `/:a/:b` only two.
    let layout = "class WikiLayout extends StatelessWidget { const WikiLayout({super.key, required this.child}); final Widget child; }";
    let e = errors(&[
        ("(wiki)/layout.dart", layout),
        ("(wiki)/docs/$$rest/page.dart", DOCS),
        (
            "$a/$b/page.dart",
            &page_with(
                "Pair",
                "required this.a, required this.b",
                "final String a; final String b;",
            ),
        ),
    ]);
    assert!(e.is_empty(), "{e:?}");
    // But `/:a/*rest` outside the group catches all of `/docs/*rest`.
    let e = errors(&[
        ("(wiki)/layout.dart", layout),
        ("(wiki)/docs/$$rest/page.dart", DOCS),
        (
            "$a/$$rest/page.dart",
            &page_with(
                "Deep",
                "required this.a, required this.rest",
                "final String a; final List<String> rest;",
            ),
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("/docs/*rest is unreachable") && m.contains("/:a/*rest")),
        "{e:?}"
    );
}

#[test]
fn two_catch_alls_at_one_place_clash() {
    let e = errors(&[
        ("docs/$$rest/page.dart", DOCS),
        (
            "docs/$$more/page.dart",
            &page_with("More", "required this.more", "final List<String> more;"),
        ),
    ]);
    assert!(e.iter().any(|m| m.contains("unreachable")), "{e:?}");
}

#[test]
fn a_catch_all_takes_the_rest_of_the_path() {
    let sub = "class SubPage extends StatelessWidget { const SubPage({super.key}); }";
    let e = errors(&[
        ("docs/$$rest/page.dart", DOCS),
        ("docs/$$rest/sub/page.dart", sub),
    ]);
    assert!(
        e.iter().any(|m| m.contains("no route can go below it")),
        "{e:?}"
    );
    let nf = "class NoDoc extends StatelessWidget { const NoDoc({super.key}); }";
    let e = errors(&[
        ("docs/$$rest/page.dart", DOCS),
        ("docs/$$rest/not_found.dart", nf),
    ]);
    assert!(
        e.iter().any(|m| m.contains("can't have a not_found.dart")),
        "{e:?}"
    );
}

#[test]
fn a_catch_all_is_a_list_of_simple_values() {
    for ty in [
        "List<String>",
        "List<int>",
        "List<double>",
        "List<num>",
        "List<bool>",
        "List<DateTime>",
    ] {
        let p = page_with("Docs", "required this.rest", &format!("final {ty} rest;"));
        let e = errors(&[("docs/$$rest/page.dart", &p)]);
        assert!(e.is_empty(), "{ty}: {e:?}");
    }
    for ty in [
        "String",
        "int",
        "List<Object>",
        "List<int?>",
        "List<int>?",
        "Set<int>",
        "List<List<int>>",
    ] {
        let p = page_with("Docs", "required this.rest", &format!("final {ty} rest;"));
        let e = errors(&[("docs/$$rest/page.dart", &p)]);
        let want = "a catch-all segment is the rest of the path, a `List` of String, int, double, num, bool or DateTime";
        assert!(e.iter().any(|m| m.contains(want)), "{ty}: {e:?}");
    }
    // Nobody asking for it is fine too: it is still the rest of the path.
    let c = code(&[("docs/$$rest/page.dart", &page("Docs"))]);
    has(
        &c,
        &[
            "const DocsRoute({required this.rest});",
            "final List<String> rest;",
        ],
    );
}

#[test]
fn an_optional_catch_all_serves_the_path_without_it_too() {
    let p = page_with("Files", "this.path = const []", "final List<String> path;");
    let c = code(&[("files/$$$path/page.dart", &p)]);
    has(
        &c,
        &[
            "//   /files/*path?  FilesRoute",
            "path: joinLocation(at, '/files')",
            "path: joinLocation(at, '/files/:path(.+)')",
            "const FilesRoute({this.path = const []});",
            "joinLocation(AppRoutes.base, '/files${restPath(path)}')",
        ],
    );
    // No assertion: an empty list is `/files`.
    lacks(&c, &["assert("]);
    // The shorter route comes first, the catch-all after everything else.
    assert!(at(&c, "path: joinLocation(at, '/files')") < at(&c, "'/files/:path(.+)'"));
    // Both read the same parse function, which reads no parameter for the short one.
    assert_eq!(c.matches("(path: Segment.asRest(s, 'path'))").count(), 1);
}

#[test]
fn an_optional_catch_all_and_a_page_above_it_clash() {
    let p = page_with("Files", "this.path = const []", "final List<String> path;");
    let e = errors(&[
        ("files/page.dart", &page("FilesIndex")),
        ("files/$$$path/page.dart", &p),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("/files is served by both") && m.contains("optional catch-all")),
        "{e:?}"
    );
    // A required one leaves `/files` to the page above.
    let e = errors(&[
        ("files/page.dart", &page("FilesIndex")),
        ("files/$$rest/page.dart", DOCS),
    ]);
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn a_catch_all_can_be_a_guards_or_redirects_parameter() {
    let guard = "GuardResult guard(ProviderContainer c, {required List<String> rest}) => rest.first == 'secret' ? '/login' : null;";
    let c = code(&[
        ("docs/$$rest/page.dart", DOCS),
        ("docs/$$rest/guard.dart", guard),
    ]);
    has(
        &c,
        &["_i1.guard(ProviderScope.containerOf(context, listen: false), rest: v.rest)"],
    );
    let redirect = "String redirect({required List<String> rest}) => '/docs/${rest.join('/')}';";
    let c = code(&[("old/$$rest/redirect.dart", redirect)]);
    has(
        &c,
        &[
            "_i0.redirect(rest: v.rest)",
            "class OldRestRoute",
            "'/old${restPath(rest)}'",
        ],
    );
}

#[test]
fn data_keyed_by_a_catch_all_uses_its_path_as_the_key() {
    let data =
        "Future<String> data(Ref ref, {required List<String> rest}) async => rest.join('/');";
    let p = "class DocsPage extends StatelessWidget { const DocsPage({super.key, required this.rest, required this.data}); final List<String> rest; final String data; }";
    let c = code(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    has(
        &c,
        &[
            // Lists compare by identity, so the provider is keyed by the encoded path.
            "(Ref ref, String rest) => _i0.data(ref, rest: restParts(rest)),",
            "ref.watch(_data2(restKey(v.rest)))",
            "static final watch = (WidgetRef ref, {required List<String> rest}) => ref.watch(data(restKey(rest)));",
        ],
    );
    // A provider of its own would be keyed by the list itself.
    let own = "final data = FutureProvider.family<String, ({List<String> rest})>((ref, k) async => k.rest.join('/'));";
    let e = errors(&[("docs/$$rest/page.dart", p), ("docs/$$rest/data.dart", own)]);
    assert!(
        e.iter()
            .any(|m| m.contains("is a catch-all, a List that a provider can't be keyed by")),
        "{e:?}"
    );
}

#[test]
fn a_catch_all_and_a_list_query_key_the_same_data() {
    // The catch-all is keyed by its path, the query list by a `QueryList`.
    let data = "Future<String> data(Ref ref, {required List<String> rest, List<String> tags = const []}) async => 'x';";
    let p = "class DocsPage extends StatelessWidget { const DocsPage({super.key, required this.rest, required this.data}); final List<String> rest; final String data; }";
    let c = code(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    has(
        &c,
        &[
            "rest: restKey(v.rest)",
            "tags: QueryList(v.tags)",
            "rest: restParts(k.rest)",
            "QueryList<String> tags",
        ],
    );
}

#[test]
fn a_catch_all_can_follow_dynamic_segments_and_a_layout() {
    let layout = "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child}); final Widget child; }";
    let p = page_with(
        "Item",
        "required this.shop, required this.rest",
        "final int shop; final List<String> rest;",
    );
    let c = code(&[
        ("shops/$shop/layout.dart", layout),
        ("shops/$shop/items/$$rest/page.dart", &p),
    ]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/shops/:shop/items/:rest(.+)')",
            "({int shop, List<String> rest}) _params",
            "shop: Segment.asInt(s, 'shop'), rest: Segment.asRest(s, 'rest')",
            "const ItemRoute({required this.shop, required this.rest});",
            "'/shops/$shop/items${restPath(rest)}'",
        ],
    );
}

#[test]
fn a_tab_can_start_at_a_catch_all_only_with_an_initial_location() {
    let tabs = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }\nconst tabOptions = {'docs': TabOptions(initialLocation: '/docs/intro/start')};";
    let e = errors(&[
        ("(t)/layout.dart", tabs),
        ("(t)/docs/$$rest/page.dart", DOCS),
        ("(t)/home/page.dart", &page("Home")),
    ]);
    assert!(e.is_empty(), "{e:?}");
    let e = errors(&[
        (
            "(t)/layout.dart",
            &tabs.replace("/docs/intro/start", "/docs"),
        ),
        ("(t)/docs/$$rest/page.dart", DOCS),
        ("(t)/home/page.dart", &page("Home")),
    ]);
    assert!(e.iter().any(|m| m.contains("initialLocation")), "{e:?}");
}

#[test]
fn a_catch_all_is_listed_by_fsp_routes() {
    let dir = project(&[("docs/$$rest/page.dart", DOCS)]);
    let (_, _, app) = crate::analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let lines = crate::routes::json_lines(&app, "lib/app");
    assert_eq!(lines.len(), 1);
    let v: serde_json::Value = serde_json::from_str(&lines[0]).unwrap();
    assert_eq!(v["pattern"], "/docs/*rest");
    assert_eq!(v["params"][0]["type"], "List<String>");
    assert_eq!(v["params"][0]["in"], "path");
}

#[test]
fn fsp_new_writes_catch_all_folders() {
    for (arg, dir, data) in [
        ("docs/[...rest]", "docs/$$rest", false),
        ("docs/[[...rest]]", "docs/$$$rest", false),
        ("docs/[...rest]", "docs/$$rest", true),
    ] {
        let d = project(&[]);
        fs::create_dir_all(d.path().join("lib/app")).unwrap();
        let args = scaffold::NewArgs {
            route: arg.into(),
            name: None,
            function: false,
            not_found: false,
            data,
            action: false,
            loading: false,
            error: false,
            layout: false,
            guard: false,
            transition: false,
        };
        scaffold::new_route(d.path(), &args).unwrap();
        let folder = d.path().join("lib/app").join(dir);
        if data {
            let data = fs::read_to_string(folder.join("data.dart")).unwrap();
            assert!(data.contains("required List<String> rest"), "{data}");
        } else {
            let page = fs::read_to_string(folder.join("page.dart")).unwrap();
            assert!(page.contains("final List<String> rest;"), "{page}");
        }
        let (_, diags, _) = build(&d.path().join("lib/app"), &Config::default()).unwrap();
        assert!(diags.0.is_empty(), "{:?}", diags.0);
    }
}

// ---- case-insensitive paths ----

#[test]
fn case_sensitive_is_a_pubspec_option() {
    assert!(Pubspec::parse("name: a\n").unwrap().config.case_sensitive);
    assert!(
        Pubspec::parse("name: a\nfespalier:\n  format: true\n")
            .unwrap()
            .config
            .case_sensitive
    );
    assert!(
        Pubspec::parse("name: a\nfespalier:\n  case_sensitive: true\n")
            .unwrap()
            .config
            .case_sensitive
    );
    assert!(
        !Pubspec::parse("name: a\nfespalier:\n  case_sensitive: false\n")
            .unwrap()
            .config
            .case_sensitive
    );
    assert!(Pubspec::parse("name: a\nfespalier:\n  case_sensitive: maybe\n").is_err());
}

#[test]
fn routes_are_case_sensitive_unless_configured() {
    let files = [
        ("page.dart", HOME),
        ("docs/$$rest/page.dart", DOCS),
        ("about/page.dart", &page("About")),
    ];
    let c = code(&files);
    lacks(&c, &["caseSensitive"]);
    let cfg = Config {
        case_sensitive: false,
        ..Config::default()
    };
    let c = code_with(&cfg, &files);
    // Every GoRoute, and the not-found lookup, which compares folder names too.
    assert_eq!(c.matches("caseSensitive: false,").count(), 3, "{c}");
    let nf = "class NoDocs extends StatelessWidget { const NoDocs({super.key, required this.uri}); final Uri uri; }";
    let c = code_with(
        &cfg,
        &[
            ("page.dart", HOME),
            ("docs/page.dart", &page("Docs")),
            ("docs/not_found.dart", nf),
        ],
    );
    has(
        &c,
        &[
            "nearestNotFound(",
            "        caseSensitive: false,\n      );",
        ],
    );
}

// ---- typed extra ----

const MODEL: &str =
    "import 'package:flutter/widgets.dart';\nimport '../../../models/product.dart';\n";

fn product_page(params: &str, fields: &str) -> String {
    format!(
        "{MODEL}class ProductPage extends StatelessWidget {{ const ProductPage({{super.key, required this.id, {params}}}); final int id; {fields} }}"
    )
}

#[test]
fn a_page_can_ask_for_the_extra_object() {
    let p = product_page("this.extra", "final Product? extra;");
    let c = code(&[("products/$id/page.dart", &p)]);
    has(
        &c,
        &[
            "_i0.ProductPage(id: v.id, extra: extraOf(state))",
            // The type is imported wherever page.dart imports from.
            "import 'models/product.dart' show Product;",
            "void go(BuildContext context, {Product? extra, String? locale}) => context.go(locationFor(locale), extra: extra);",
            "Future<T?> push<T extends Object?>(BuildContext context, {Product? extra, String? locale}) =>",
            "context.push<T>(locationFor(locale), extra: extra);",
            "void replace(BuildContext context, {Product? extra, String? locale}) => context.replace(locationFor(locale), extra: extra);",
            "unused_element, undefined_shown_name",
        ],
    );
}

#[test]
fn the_extra_is_not_a_query_parameter_or_a_segment() {
    let p = product_page("this.extra", "final Product? extra;");
    let c = code(&[("products/$id/page.dart", &p)]);
    // Only the segment is read from the URL.
    has(&c, &["({int id}) _params", "(id: Segment.asInt(s, 'id'));"]);
    lacks(&c, &["Query."]);
    let e = errors(&[
        ("extra/page.dart", &page("Extra")),
        ("x/$extra/page.dart", &page("X")),
    ]);
    assert!(
        e.iter().any(|m| m.contains("`$extra` is reserved")),
        "{e:?}"
    );
}

#[test]
fn the_extra_must_be_nullable() {
    let p = product_page("required this.extra", "final Product extra;");
    let e = errors(&[("products/$id/page.dart", &p)]);
    assert!(
        e.iter()
            .any(|m| m.contains("a deep link or a reload leaves it null")
                && m.contains("`Product? extra`")),
        "{e:?}"
    );
    for ty in ["Product?", "Object?", "dynamic"] {
        let p = product_page("required this.extra", &format!("final {ty} extra;"));
        assert!(errors(&[("products/$id/page.dart", &p)]).is_empty(), "{ty}");
    }
}

#[test]
fn the_extra_type_comes_from_wherever_the_page_gets_it() {
    // Declared in page.dart itself.
    let p = "import 'package:flutter/widgets.dart';\nenum Mode { a, b }\nclass ModePage extends StatelessWidget { const ModePage({super.key, this.extra}); final Mode? extra; }";
    let c = code(&[("mode/page.dart", p)]);
    has(
        &c,
        &["extra: extraOf(state)", "{_i0.Mode? extra, String? locale}"],
    );
    lacks(&c, &["undefined_shown_name"]);
    // Under an import prefix, and inside a generic type.
    let p = "import 'package:flutter/widgets.dart';\nimport '../models.dart' as m;\nclass ListPage extends StatelessWidget { const ListPage({super.key, this.extra}); final List<m.Item>? extra; }";
    let c = code(&[("list/page.dart", p)]);
    has(
        &c,
        &[
            "import 'app/models.dart' as _e1_m;",
            "{List<_e1_m.Item>? extra, String? locale}",
        ],
    );
    // Built-in types need nothing.
    let p = "import 'package:flutter/widgets.dart';\nclass TextPage extends StatelessWidget { const TextPage({super.key, this.extra}); final String? extra; }";
    let c = code(&[("text/page.dart", p)]);
    has(&c, &["{String? extra, String? locale}"]);
    lacks(&c, &["show", "undefined_shown_name"]);
}

#[test]
fn loading_and_error_views_take_no_extra() {
    // Layouts, guards and redirects do (see `extra_tests.rs`); a view built while data loads
    // has no route of its own to have passed one to, so an optional one is left at its default.
    let loading = "class ShopLoading extends StatelessWidget { const ShopLoading({super.key, this.extra}); final Object? extra; }";
    let data = "Future<String> data(Ref ref) async => '';";
    let shop = "class ShopPage extends StatelessWidget { const ShopPage({super.key, required this.data}); final String data; }";
    let e = errors(&[
        ("shop/loading.dart", loading),
        ("shop/data.dart", data),
        ("shop/page.dart", shop),
    ]);
    assert!(
        e.is_empty() || e.iter().all(|m| !m.contains("extra")),
        "{e:?}"
    );
    let c = code(&[("page.dart", HOME)]);
    lacks(&c, &["extraOf", "extra:"]);
}

#[test]
fn imports_of_the_extra_type_resolve_from_the_output_folder() {
    let cfg = Pubspec::parse(
        "name: a\nfespalier:\n  app_dir: lib/pages\n  output: lib/router/routes.g.dart\n",
    )
    .unwrap()
    .config;
    assert_eq!(
        cfg.import_from_file("a/b/page.dart", "../m.dart"),
        "../pages/a/m.dart"
    );
    assert_eq!(
        cfg.import_from_file("a/b/page.dart", "../../../models/x.dart"),
        "../models/x.dart"
    );
    assert_eq!(
        cfg.import_from_file("a/page.dart", "package:x/y.dart"),
        "package:x/y.dart"
    );
    assert_eq!(
        cfg.import_from_file("a/page.dart", "dart:async"),
        "dart:async"
    );
    let same = Config::default();
    assert_eq!(
        same.import_from_file("a/page.dart", "./m.dart"),
        "app/a/m.dart"
    );
    assert_eq!(same.import_from_file("page.dart", "../m.dart"), "m.dart");
}
