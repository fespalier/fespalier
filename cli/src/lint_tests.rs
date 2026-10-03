//! The string-path lint (`lint.rs`): which calls are sites, how a path is read and matched,
//! the mount point, the ignore comments, the levels and where a diagnostic points.

use std::fs;
use std::path::Path;

use crate::config::{Config, LintLevel, Pubspec};
use crate::diag::{self, Diags};
use crate::lint::{self, MountAt, Piece, SiteKind, Sites, Table};
use crate::session::Session;

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn typed(name: &str, field: &str, ty: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, required this.{field}}}); final {ty} {field}; }}"
    )
}

fn f(rel: &str, body: String) -> (String, String) {
    (rel.to_string(), body)
}

/// A shop: static, dynamic (an `int`) and catch-all routes, a group, a redirect and a route
/// that is a sibling of the page above it.
fn std_app() -> Vec<(String, String)> {
    vec![
        f("page.dart", page("Home")),
        f("products/page.dart", page("Products")),
        f("products/$id/page.dart", typed("Product", "id", "int")),
        f("products/$id/reviews/page.dart", page("Reviews")),
        f(
            "docs/$$rest/page.dart",
            typed("Doc", "rest", "List<String>"),
        ),
        f(
            "files/$$$rest/page.dart",
            typed("File", "rest", "List<String>"),
        ),
        f("cart/page.dart", page("Cart")),
        f("(shop)/about/page.dart", page("About")),
        f(
            "old/redirect.dart",
            "String redirect(Ref ref) => '/cart';".into(),
        ),
        f("orders/page.dart", page("Orders")),
        f("orders/$id/page.dart", typed("Order", "id", "String")),
        f("orders/$id/refund/confirm/page.dart", page("Confirm")),
        f(
            "orders/$id/refund/confirm/route.dart",
            "const nest = false;".into(),
        ),
    ]
}

/// A project with `app` under `lib/app/` and `lib` under `lib/`.
fn make(pubspec: &str, app: &[(String, String)], lib: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        format!("name: demo\n{pubspec}"),
    )
    .unwrap();
    for (rel, body) in app {
        write(dir.path(), &format!("lib/app/{rel}"), body);
    }
    for (rel, body) in lib {
        write(dir.path(), rel, body);
    }
    dir
}

fn write(root: &Path, rel: &str, body: &str) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, body).unwrap();
}

/// One `context.go(...)` per expression, the first on line 2.
fn gos(exprs: &[&str]) -> String {
    let body: String = exprs
        .iter()
        .map(|e| format!("  context.go({e});\n"))
        .collect();
    format!("void f(BuildContext context) {{\n{body}}}\n")
}

fn lint_diags(project: &Path) -> Diags {
    let cfg = Config::load(project).unwrap();
    let (_, diags, app) = crate::analyze(&project.join(&cfg.app_dir), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    lint::check(project, &cfg, &Table::new(&app), &mut Sites::default())
}

fn shown(project: &Path) -> Vec<String> {
    lint_diags(project)
        .0
        .iter()
        .map(ToString::to_string)
        .collect()
}

fn messages(project: &Path) -> Vec<String> {
    lint_diags(project).0.into_iter().map(|d| d.msg).collect()
}

/// The messages for `exprs` given to `context.go` in a file outside the app folder.
fn of_paths(pubspec: &str, exprs: &[&str]) -> Vec<String> {
    let dir = make(pubspec, &std_app(), &[("lib/screens/s.dart", &gos(exprs))]);
    messages(dir.path())
}

fn unmatched(path: &str) -> String {
    format!("no route matches `{path}`, so it shows not-found [unknown_path]")
}

fn piece(s: &str) -> Piece {
    Piece::Text(s.to_string())
}

// --- Sites --------------------------------------------------------------------------------

#[test]
fn sites_finds_each_call_shape() {
    let src = r"
void f() {
  context.go('/a');
  GoRouter.of(context).push('/b', extra: 1);
  router.replace('/c');
  x.pushReplacement('/d');
  context.push<int>('/e');
  context?.go('/f');
  router..go('/g')..push('/h');
  RouteLink(uri: Uri.parse('/i'), child: a);
  fsp.RouteLink(uri: Uri.parse('/j'), child: a);
  const RouteLink(uri: Uri.parse('/k'), child: a);
  AppRoutes.router(initialLocation: '/l');
  GoRouter(initialLocation: '/m');
  AppRoutes.mount(at: '/shop');
  AppRoutes.mount();
  AppRoutes.mount(at: base);
  onPressed: () => context.go('/n');
}
";
    let found: Vec<(SiteKind, String)> = lint::sites(src)
        .into_iter()
        .map(|s| (s.kind, s.text))
        .collect();
    let nav = |t: &str| (SiteKind::Navigate, t.to_string());
    assert_eq!(
        found,
        [
            nav("/a"),
            nav("/b"),
            nav("/c"),
            nav("/d"),
            nav("/e"),
            nav("/f"),
            nav("/g"),
            nav("/h"),
            (SiteKind::RouteLinkUri, "/i".into()),
            (SiteKind::RouteLinkUri, "/j".into()),
            (SiteKind::RouteLinkUri, "/k".into()),
            (SiteKind::InitialLocation, "/l".into()),
            (SiteKind::InitialLocation, "/m".into()),
            (
                SiteKind::Mount(MountAt::Literal(vec![piece("/shop")])),
                String::new()
            ),
            (SiteKind::Mount(MountAt::Default), String::new()),
            (SiteKind::Mount(MountAt::Unknown), String::new()),
            nav("/n"),
        ]
    );
}

#[test]
fn sites_skips_what_is_not_a_router_path() {
    let src = r"
void f() {
  go('/x');
  context.goNamed('x');
  context.pushNamed('x');
  Navigator.pushNamed(context, '/x');
  const HomeRoute().go(context);
  ProductRoute(id: 2).push(context);
  TabOptions(initialLocation: '/x');
  AppRoutes.match(Uri.parse('/x'));
  AppRoutes.matchUrl(Uri.parse('/x'));
  AppRoutes.dataAt(Uri.parse('/x'));
  context.go('/a' + b);
  context.go(path);
  context.go(extra: '/x');
  final u = Uri(path: '/x');
  final v = Uri.parse('/x');
  RouteLink(uri: .parse('/x'), child: a);
  RouteLink(child: a);
  Other(uri: Uri.parse('/x'));
}
";
    assert_eq!(lint::sites(src), vec![]);
}

fn pieces_of(expr: &str) -> Vec<Piece> {
    let src = format!("void f() {{ context.go({expr}); }}");
    lint::sites(&src).remove(0).pieces
}

#[test]
fn literals_decode_escapes_raw_strings_and_adjacent_parts() {
    assert_eq!(pieces_of(r"'/a\'b\$c'"), [piece("/a'b$c")]);
    assert_eq!(pieces_of(r"r'/raw$x'"), [piece("/raw$x")]);
    assert_eq!(pieces_of("'''/multi'''"), [piece("/multi")]);
    assert_eq!(pieces_of("'/a' '/b'"), [piece("/a/b")]);
    assert_eq!(pieces_of(r#""/x/$id""#), [piece("/x/"), Piece::Hole]);
    assert_eq!(
        pieces_of("'/a/${id}/b'"),
        [piece("/a/"), Piece::Hole, piece("/b")]
    );
    assert_eq!(
        pieces_of(r"'/t\tn\n\x41B\u{1F600}'"),
        [piece("/t\tn\nAB\u{1F600}")]
    );
    let s = lint::sites("void f() { context.go('/a/${id}/b'); }").remove(0);
    assert_eq!(s.text, "/a/${id}/b");
}

// --- Matching -----------------------------------------------------------------------------

#[test]
fn a_path_that_matches_a_route_is_fine() {
    let fine = [
        "'/'",
        "'/products'",
        "'/products/'",
        "'/products/2'",
        "'/products/2/reviews'",
        "'/docs/a'",
        "'/docs/a/b/c'",
        "'/files'",
        "'/files/a/b'",
        "'/about'",
        "'/old'",
        "'/orders/7'",
        "'/orders/7/refund/confirm'",
        "'/products?q=1#top'",
        "'/products/2?sort=x'",
        "'/products/2#reviews'",
        "'/products//2'",
        "'/cart'",
        "'/c%61rt'",
    ];
    assert_eq!(of_paths("", &fine), Vec::<String>::new());
}

#[test]
fn a_path_that_matches_nothing_is_warned_about() {
    assert_eq!(
        of_paths("", &["'/nope/x'", "'/docs'", "'/Products'"]),
        [
            unmatched("/nope/x"),
            unmatched("/docs"),
            "no route matches `/Products`, so it shows not-found; did you mean `/products`? [unknown_path]"
                .to_string(),
        ]
    );
    // Case off: by the pubspec, or by a `route.dart` for one folder.
    assert_eq!(
        of_paths(
            "fespalier:\n  case_sensitive: false\n",
            &["'/Products'", "'/PRODUCTS/2'"]
        ),
        Vec::<String>::new()
    );
    let mut app = std_app();
    app.push(f("shout/page.dart", page("Shout")));
    app.push(f("shout/route.dart", "const caseSensitive = false;".into()));
    let dir = make(
        "",
        &app,
        &[("lib/screens/s.dart", &gos(&["'/SHOUT'", "'/Cart'"]))],
    );
    assert_eq!(
        messages(dir.path()),
        ["no route matches `/Cart`, so it shows not-found; did you mean `/cart`? [unknown_path]"]
    );
}

#[test]
fn localized_spellings_match_alone_and_mixed() {
    let mut app = std_app();
    app.push(f("help/page.dart", page("Help")));
    app.push(f(
        "help/route.dart",
        "const paths = {'fr': 'aide', 'de': 'hilfe'};".into(),
    ));
    app.push(f("help/routing/page.dart", page("Routing")));
    app.push(f(
        "help/routing/route.dart",
        "const paths = {'fr': 'routage'};".into(),
    ));
    app.push(f("help/routing/examples/page.dart", page("Examples")));
    app.push(f("menu/page.dart", page("Menu")));
    app.push(f(
        "menu/route.dart",
        "const caseSensitive = false;\nconst paths = {'fr': 'café'};".into(),
    ));
    let src = gos(&[
        "'/help'",
        "'/aide'",
        "'/hilfe/routing'",
        "'/aide/routage/examples'",
        "'/aide/routing/examples'",
        "'/AIDE'",
        "'/café'",
        "'/caf%C3%A9'",
        "'/CAFÉ'",
        "'/produits'",
    ]);
    let dir = make("", &app, &[("lib/screens/s.dart", &src)]);
    // `/AIDE` is a route whose own `route.dart` is case-sensitive: only `menu` is not.
    assert_eq!(
        messages(dir.path()),
        [
            "no route matches `/AIDE`, so it shows not-found; did you mean `/aide`? [unknown_path]",
            "no route matches `/produits`, so it shows not-found; did you mean `/products`? [unknown_path]",
        ]
    );
}

#[test]
fn interpolated_paths_are_checked_up_to_the_first_hole() {
    assert_eq!(
        of_paths(
            "",
            &[
                "'/products/$id'",
                "'/prodcts/$id'",
                "'/prod$x'",
                "'$base/x'",
                "'${AppRoutes.base}/x'",
                "'/products/$id/revews'",
                "'/x?ref=$id'",
                "'/docs/$a/$b'",
                "'/nope/$a'",
            ]
        ),
        [
            "no route starts with `/prodcts/`, so `/prodcts/$id` shows not-found whatever it interpolates [unknown_path]".to_string(),
            unmatched("/x?ref=$id"),
            "no route starts with `/nope/`, so `/nope/$a` shows not-found whatever it interpolates [unknown_path]".to_string(),
        ]
    );
}

#[test]
fn skipped_shapes() {
    assert_eq!(
        of_paths(
            "",
            &[
                "'details'",
                "'./x'",
                "'https://a.b/x'",
                "'//x'",
                "'/a/../b'",
                "'/a/./b'",
                "'/a%zz'",
                "'/a%'",
                "''",
                "'/products/%FF'",
            ]
        ),
        Vec::<String>::new()
    );
}

#[test]
fn the_suggestion_is_the_nearest_spelling() {
    assert_eq!(
        of_paths(
            "",
            &[
                "'/prodcts/2'",
                "'/prodcts/2?x=1'",
                "'/prodcts/2#top'",
                "'/prodcts/2/revews'",
                "'/xyz'",
                "'/products/2/reviw'",
            ]
        ),
        [
            "no route matches `/prodcts/2`, so it shows not-found; did you mean `/products/2`? [unknown_path]".to_string(),
            "no route matches `/prodcts/2?x=1`, so it shows not-found; did you mean `/products/2?x=1`? [unknown_path]".to_string(),
            "no route matches `/prodcts/2#top`, so it shows not-found; did you mean `/products/2#top`? [unknown_path]".to_string(),
            unmatched("/prodcts/2/revews"),
            unmatched("/xyz"),
            "no route matches `/products/2/reviw`, so it shows not-found; did you mean `/products/2/reviews`? [unknown_path]".to_string(),
        ]
    );
}

/// The messages for `exprs` given to `context.go`, on top of `std_app()` plus `extra` routes.
fn with_routes(pubspec: &str, extra: Vec<(String, String)>, exprs: &[&str]) -> Vec<String> {
    let mut app = std_app();
    app.extend(extra);
    let dir = make(pubspec, &app, &[("lib/screens/s.dart", &gos(exprs))]);
    messages(dir.path())
}

fn wrong(path: &str, pattern: &str, part: &str, reason: &str) -> String {
    format!(
        "`{path}` reaches {pattern}, but `{part}` {reason}, so it shows not-found [unknown_path]"
    )
}

#[test]
fn segment_types_are_checked() {
    assert_eq!(
        of_paths("", &["'/products/abc'"]),
        [
            "`/products/abc` reaches /products/:id, but `abc` is not an int, so it shows not-found [unknown_path]"
        ]
    );
    // What `int.tryParse` reads, a `String` segment, and a text that is not judged.
    let fine = [
        "'/products/+2'",
        "'/products/0x1F'",
        "'/products/%EF%BB%BF2'",
        "'/products/2%20'",
        "'/orders/abc'",
        "'/docs/a/b'",
    ];
    assert_eq!(of_paths("", &fine), Vec::<String>::new());
    // The query is not read, the fragment neither.
    assert_eq!(
        of_paths("", &["'/products/2?id=abc#x'"]),
        Vec::<String>::new()
    );
    // A hole after the `?` still judges the path before it, and shows the literal as written.
    assert_eq!(
        of_paths("", &["'/products/abc?q=$x'"]),
        [
            "`/products/abc?q=$x` reaches /products/:id, but `abc` is not an int, so it shows not-found [unknown_path]"
        ]
    );
}

#[test]
fn catch_all_parts_are_checked() {
    let extra = vec![
        f(
            "compare/$$ids/page.dart",
            typed("Compare", "ids", "List<int>"),
        ),
        f("nums/$$$rest/page.dart", typed("Nums", "rest", "List<int>")),
    ];
    assert_eq!(
        with_routes(
            "",
            extra,
            &["'/compare/3/x'", "'/compare/3/7'", "'/nums'", "'/nums/1/2'"]
        ),
        [
            "`/compare/3/x` reaches /compare/*ids, but its part `x` is not an int, so it shows not-found [unknown_path]"
        ]
    );
}

#[test]
fn enum_segments_list_values_and_suggest() {
    let page = "import 'package:demo/models/category.dart';\nclass ShopPage extends StatelessWidget { const ShopPage({super.key, required this.category}); final Category category; }";
    let enum_file = "enum Category { shoes, hats }\n";
    let many = "enum Category { a, b, c, d, e, f, g, h }\n";
    let run = |pubspec: &str, decl: &str, exprs: &[&str]| {
        let dir = make(
            pubspec,
            &[f("shop/$category/page.dart", page.to_string())],
            &[
                ("lib/models/category.dart", decl),
                ("lib/screens/s.dart", &gos(exprs)),
            ],
        );
        messages(dir.path())
    };
    assert_eq!(
        run(
            "",
            enum_file,
            &["'/shop/socks'", "'/shop/shoos'", "'/shop/hats'"]
        ),
        [
            "`/shop/socks` reaches /shop/:category, but `socks` is not a value of Category (shoes, hats), so it shows not-found [unknown_path]",
            "`/shop/shoos` reaches /shop/:category, but `shoos` is not a value of Category (shoes, hats), so it shows not-found; did you mean `/shop/shoes`? [unknown_path]",
        ]
    );
    // Names are exact when the route is case-sensitive; with case off, any case is a value.
    assert_eq!(run("", enum_file, &["'/shop/SHOES'"]).len(), 1);
    assert_eq!(
        run(
            "fespalier:\n  case_sensitive: false\n",
            enum_file,
            &["'/shop/SHOES'", "'/shop/Hats'", "'/shop/ShoEs'"]
        ),
        Vec::<String>::new()
    );
    assert_eq!(
        run("", many, &["'/shop/z'"]),
        [
            "`/shop/z` reaches /shop/:category, but `z` is not a value of Category (a, b, c, d, e, f, ...), so it shows not-found [unknown_path]"
        ]
    );
}

#[test]
fn the_first_fitting_route_decides() {
    // `a/$id` ranks before `$slug/x`, which would take `/a/x`; the runtime does not try the next
    // route when the first one's segment does not parse.
    let extra = vec![
        f("a/$id/page.dart", typed("A", "id", "int")),
        f("$slug/x/page.dart", typed("Slug", "slug", "String")),
    ];
    assert_eq!(
        with_routes("", extra, &["'/a/x'", "'/a/2'", "'/b/x'"]),
        [wrong("/a/x", "/a/:id", "x", "is not an int")]
    );
    // A static sibling takes `new` before `:id` does.
    let extra = vec![
        f("a/$id/page.dart", typed("A", "id", "int")),
        f("a/new/page.dart", page("New")),
    ];
    assert_eq!(
        with_routes("", extra, &["'/a/new'", "'/a/zz'"]),
        [wrong("/a/zz", "/a/:id", "zz", "is not an int")]
    );
    // A root catch-all ranks after `products/:id`.
    let app = vec![
        f("$$rest/page.dart", typed("Rest", "rest", "List<String>")),
        f("products/$id/page.dart", typed("Product", "id", "int")),
    ];
    let src = gos(&["'/products/abc'", "'/other/x'", "'/products/2'"]);
    let dir = make("", &app, &[("lib/screens/s.dart", &src)]);
    assert_eq!(
        messages(dir.path()),
        [wrong(
            "/products/abc",
            "/products/:id",
            "abc",
            "is not an int"
        )]
    );
}

#[test]
fn prefix_types_are_checked() {
    assert_eq!(
        of_paths(
            "",
            &[
                "'/products/abc/$tab'",
                "'/products/$id'",
                "'/products/2/$tab'",
                "'/products/abc$x'",
            ]
        ),
        [
            "no route starts with `/products/abc/`: `abc` is not an int at /products/:id, so `/products/abc/$tab` shows not-found whatever it interpolates [unknown_path]"
        ]
    );
    let extra = vec![f(
        "compare/$$ids/page.dart",
        typed("Compare", "ids", "List<int>"),
    )];
    assert_eq!(
        with_routes("", extra, &["'/compare/3/x/$y'", "'/compare/3/$y'"]),
        [
            "no route starts with `/compare/3/x/`: its part `x` is not an int at /compare/*ids, so `/compare/3/x/$y` shows not-found whatever it interpolates [unknown_path]"
        ]
    );
}

#[test]
fn a_redirect_route_is_type_checked_too() {
    let extra = vec![f(
        "legacy/$id/redirect.dart",
        "String redirect(Ref ref, {required int id}) => '/products/$id';".into(),
    )];
    assert_eq!(
        with_routes("", extra, &["'/legacy/abc'", "'/legacy/3'"]),
        [wrong("/legacy/abc", "/legacy/:id", "abc", "is not an int")]
    );
}

#[test]
fn type_findings_are_silenced_and_levelled() {
    let src = r"void f(BuildContext context) {
  // fsp:ignore unknown_path
  context.go('/products/abc');
  context.go('/products/def');
}
";
    let dir = make(
        "fespalier:\n  lints:\n    unknown_path: error\n",
        &std_app(),
        &[("lib/screens/s.dart", src)],
    );
    assert_eq!(
        shown(dir.path()),
        [format!(
            "✗ lib/screens/s.dart:4  {}",
            wrong("/products/def", "/products/:id", "def", "is not an int")
        )]
    );
}

// --- The mount point ----------------------------------------------------------------------

fn with_main(main: &str, exprs: &[&str]) -> Vec<String> {
    let dir = make(
        "",
        &std_app(),
        &[("lib/main.dart", main), ("lib/screens/s.dart", &gos(exprs))],
    );
    messages(dir.path())
}

#[test]
fn mount_at_a_literal_strips_it_and_skips_the_host() {
    let main = "final r = GoRouter(routes: [...legacy, ...AppRoutes.mount(at: '/shop')]);";
    assert_eq!(
        with_main(
            main,
            &[
                "'/shop/products'",
                "'/shop/nope/x'",
                "'/legacy/x'",
                "'/products'",
                "'/shop'",
                "'/shop/'"
            ]
        ),
        [unmatched("/shop/nope/x")]
    );
    // The root's case setting compares the mount point.
    let dir = make(
        "fespalier:\n  case_sensitive: false\n",
        &std_app(),
        &[
            ("lib/main.dart", main),
            (
                "lib/screens/s.dart",
                &gos(&["'/Shop/Products'", "'/Shop/nope'"]),
            ),
        ],
    );
    assert_eq!(messages(dir.path()), [unmatched("/Shop/nope")]);
    // An interpolated path is read below the mount point too.
    assert_eq!(
        with_main(
            main,
            &[
                "'/shop/prodcts/$id'",
                "'/shop/products/$id'",
                "'/shop/$x'",
                "'/elsewhere/$x'"
            ]
        ),
        [
            "no route starts with `/shop/prodcts/`, so `/shop/prodcts/$id` shows not-found whatever it interpolates [unknown_path]"
        ]
    );
}

#[test]
fn an_unreadable_mount_turns_the_check_off() {
    let bad = ["'/nope/x'"];
    assert_eq!(
        with_main("final r = AppRoutes.mount(at: base);", &bad),
        Vec::<String>::new()
    );
    assert_eq!(
        with_main(
            "a() => AppRoutes.mount(at: '/a'); b() => AppRoutes.mount(at: '/b');",
            &bad
        ),
        Vec::<String>::new()
    );
    assert_eq!(
        with_main("final r = AppRoutes.mount(at: '$base/shop');", &bad),
        Vec::<String>::new()
    );
    assert_eq!(
        with_main("final r = AppRoutes.mount();", &bad),
        [unmatched("/nope/x")]
    );
    assert_eq!(
        with_main(
            "a() => AppRoutes.mount(at: '/a'); b() => AppRoutes.mount(at: '/a/');",
            &["'/a/nope'"]
        ),
        [unmatched("/a/nope")]
    );
}

// --- Silencing ------------------------------------------------------------------------------

#[test]
fn ignore_comments_silence_one_site_or_a_file() {
    let src = r"void f(BuildContext context) {
  // fsp:ignore unknown_path
  context.go('/a');
  context.go('/b'); // fsp:ignore unknown_path -- not built yet
  context.go('/c');
  context.go(
    // fsp:ignore unknown_path
    '/d',
  );
  // fsp:ignore unknown_path
  context.go(
    '/e',
    extra: 1,
  );
  context.go('/f'); // fsp:ignore other_lint
  // fsp:ignore other_lint, unknown_path
  context.go('/g');
  context.go('/h');
  context.go('/i');
}
";
    let dir = make("", &std_app(), &[("lib/screens/s.dart", src)]);
    // `/c` is right below a trailing comment, which covers only its own line.
    assert_eq!(
        messages(dir.path()),
        [
            unmatched("/c"),
            unmatched("/f"),
            unmatched("/h"),
            unmatched("/i")
        ]
    );

    let file = format!("// fsp:ignore-file unknown_path\n{src}");
    let dir = make("", &std_app(), &[("lib/screens/s.dart", &file)]);
    assert_eq!(messages(dir.path()), Vec::<String>::new());
    let other = format!("// fsp:ignore-file other_lint\n{}", gos(&["'/zzz'"]));
    let dir = make("", &std_app(), &[("lib/screens/s.dart", &other)]);
    assert_eq!(messages(dir.path()), [unmatched("/zzz")]);
}

// --- Levels and where it points ----------------------------------------------------------------

#[test]
fn levels() {
    let src = gos(&["'/nope/x'"]);
    let dir = make("", &std_app(), &[("lib/screens/s.dart", &src)]);
    assert_eq!(
        shown(dir.path()),
        [format!("! lib/screens/s.dart:2  {}", unmatched("/nope/x"))]
    );

    let dir = make(
        "fespalier:\n  lints:\n    unknown_path: error\n",
        &std_app(),
        &[("lib/screens/s.dart", &src)],
    );
    assert_eq!(
        shown(dir.path()),
        [format!("✗ lib/screens/s.dart:2  {}", unmatched("/nope/x"))]
    );

    let dir = make(
        "fespalier:\n  lints:\n    unknown_path: off\n",
        &std_app(),
        &[("lib/screens/s.dart", &src)],
    );
    assert_eq!(shown(dir.path()), Vec::<String>::new());
    // Off reads nothing: a file that cannot be read does not matter, and nothing is kept.
    let cfg = Config::load(dir.path()).unwrap();
    let mut kept = Sites::default();
    assert!(
        lint::check(dir.path(), &cfg, &Table::default(), &mut kept)
            .0
            .is_empty()
    );
}

#[test]
fn the_config_reads_levels_and_names_its_mistakes() {
    let level = |yaml: &str| Pubspec::parse(yaml).unwrap().config.lints.unknown_path;
    assert_eq!(level("name: a\n"), LintLevel::Warning);
    assert_eq!(
        level("name: a\nfespalier:\n  lints: {}\n"),
        LintLevel::Warning
    );
    assert_eq!(
        level("name: a\nfespalier:\n  lints:\n    unknown_path: error\n"),
        LintLevel::Error
    );
    assert_eq!(
        level("name: a\nfespalier:\n  lints:\n    unknown_path: off\n"),
        LintLevel::Off
    );
    assert_eq!(
        level("name: a\nfespalier:\n  lints:\n    unknown_path: warning\n"),
        LintLevel::Warning
    );
    let err = |yaml: &str| format!("{:#}", Pubspec::parse(yaml).unwrap_err());
    let bad = err("name: a\nfespalier:\n  lints:\n    unknown_path: warn\n");
    assert!(
        bad.starts_with("invalid pubspec.yaml: fespalier.lints.unknown_path: unknown variant `warn`, expected one of `off`, `warning`, `error`"),
        "{bad}"
    );
    let unknown = err("name: a\nfespalier:\n  lints:\n    nope: error\n");
    assert!(
        unknown.starts_with(
            "invalid pubspec.yaml: fespalier.lints: unknown field `nope`, expected `unknown_path`"
        ),
        "{unknown}"
    );
    let top = err("name: a\nfespalier:\n  nope: 1\n");
    assert!(top.contains("`links`, `lints`"), "{top}");
}

#[test]
fn files_outside_the_app_folder_are_shown_from_the_project() {
    let dir = make(
        "",
        &std_app(),
        &[
            (
                "lib/screens/home.dart",
                "void f() {\n\n  go2(); context.go('/nope/x');\n}\n",
            ),
            (
                "lib/app/cart/widgets.dart",
                "void f() { context.go('/nope/y'); }\n",
            ),
        ],
    );
    let diags = lint_diags(dir.path());
    assert_eq!(
        diags.0.iter().map(ToString::to_string).collect::<Vec<_>>(),
        [
            format!("! cart/widgets.dart:1  {}", unmatched("/nope/y")),
            format!("! lib/screens/home.dart:3  {}", unmatched("/nope/x")),
        ]
    );
    let app_dir = dir.path().join("lib/app");
    let json: Vec<serde_json::Value> = diags
        .0
        .iter()
        .map(|d| serde_json::from_str(&diag::json_line(&app_dir, "lib/app", d)).unwrap())
        .collect();
    assert_eq!(json[0]["file"], "lib/app/cart/widgets.dart");
    assert_eq!(json[0]["line"], 1);
    assert_eq!(json[0]["column"], 23);
    assert_eq!(json[1]["file"], "lib/screens/home.dart");
    assert_eq!(json[1]["line"], 3);
    // `  go2(); context.go(` is 20 characters before the quote.
    assert_eq!(json[1]["column"], 21);
    assert_eq!(json[1]["severity"], "warning");
}

// --- Which files ----------------------------------------------------------------------------

#[test]
fn generated_and_test_files_are_not_read() {
    let bad = gos(&["'/nope/x'"]);
    let dir = make(
        "",
        &std_app(),
        &[
            ("lib/app.g.dart", &bad),
            ("lib/x.g.dart", &bad),
            ("lib/.hidden/y.dart", &bad),
            ("test/a_test.dart", &bad),
            ("integration_test/a_test.dart", &bad),
            ("bin/a.dart", &bad),
            ("lib/notes.txt", &bad),
        ],
    );
    assert_eq!(shown(dir.path()), Vec::<String>::new());
    // The configured output is generated too, whatever it is called.
    let dir = make(
        "fespalier:\n  output: lib/router.dart\n",
        &std_app(),
        &[("lib/router.dart", &bad)],
    );
    assert_eq!(shown(dir.path()), Vec::<String>::new());
}

#[test]
fn a_file_with_no_call_shape_is_not_parsed() {
    let dir = make(
        "",
        &std_app(),
        &[
            ("lib/a.dart", "class A {}\n"),
            ("lib/b.dart", &gos(&["'/x'"])),
        ],
    );
    let cfg = Config::load(dir.path()).unwrap();
    let (_, _, app) = crate::analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    let mut kept = Sites::default();
    let again = |kept: &mut Sites| lint::check(dir.path(), &cfg, &Table::new(&app), kept);
    assert_eq!(again(&mut kept).0.len(), 1);
    assert_eq!(kept.len(), 1, "only lib/b.dart holds sites to keep");
    fs::remove_file(dir.path().join("lib/b.dart")).unwrap();
    assert!(again(&mut kept).0.is_empty());
    assert_eq!(kept.len(), 0, "a file that is gone is dropped");
}

// --- Through `gen_core` ---------------------------------------------------------------------------

fn run(dir: &Path, write: bool) -> (anyhow::Result<crate::Outcome>, Vec<String>) {
    let cfg = Config::load(dir).unwrap();
    let mut shown = vec![];
    let result = crate::gen_core(dir, &cfg, write, &mut Session::default(), |_, d| {
        shown = d.0.iter().map(ToString::to_string).collect();
    });
    (result, shown)
}

#[test]
fn a_tree_with_errors_is_not_linted() {
    let mut app = std_app();
    app.push(f("broken/page.dart", "// no widget here".into()));
    let dir = make("", &app, &[("lib/screens/s.dart", &gos(&["'/nope/x'"]))]);
    let (result, shown) = run(dir.path(), true);
    assert!(result.is_err());
    assert_eq!(shown.len(), 1, "{shown:?}");
    assert!(shown[0].starts_with("✗ broken/page.dart"), "{shown:?}");
}

#[test]
fn error_level_writes_the_output_and_fails() {
    let dir = make(
        "fespalier:\n  lints:\n    unknown_path: error\n",
        &std_app(),
        &[("lib/screens/s.dart", &gos(&["'/nope/x'", "'/nope/y'"]))],
    );
    let (result, shown) = run(dir.path(), true);
    assert_eq!(
        format!("{:#}", result.unwrap_err()),
        "2 error(s) in string paths (`lints: unknown_path: error`); lib/app.g.dart is up to date"
    );
    assert_eq!(shown.len(), 2);
    assert!(dir.path().join("lib/app.g.dart").is_file());
    // Written and current: the next run has nothing to write, and still fails.
    let (result, _) = run(dir.path(), true);
    assert!(result.is_err());
    let again = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(again.contains("class AppRoutes"));

    let fresh = make(
        "fespalier:\n  lints:\n    unknown_path: error\n",
        &std_app(),
        &[("lib/screens/s.dart", &gos(&["'/nope/x'"]))],
    );
    let (result, _) = run(fresh.path(), false);
    assert_eq!(
        format!("{:#}", result.unwrap_err()),
        "1 error(s) in string paths (`lints: unknown_path: error`)"
    );
    assert!(
        !fresh.path().join("lib/app.g.dart").exists(),
        "check writes nothing"
    );
}

#[test]
fn a_warning_never_fails_a_run() {
    let dir = make(
        "",
        &std_app(),
        &[("lib/screens/s.dart", &gos(&["'/nope/x'"]))],
    );
    let (result, shown) = run(dir.path(), true);
    assert!(result.is_ok());
    assert_eq!(shown.len(), 1);
}

#[test]
fn scaffolding_caps_an_error_at_a_warning() {
    let cfg = Pubspec::parse("name: a\nfespalier:\n  lints:\n    unknown_path: error\n")
        .unwrap()
        .config;
    assert_eq!(cfg.lints.unknown_path, LintLevel::Error);
    assert_eq!(cfg.for_scaffolding().lints.unknown_path, LintLevel::Warning);
    let off = Config {
        lints: crate::config::Lints {
            unknown_path: LintLevel::Off,
        },
        ..Config::default()
    };
    assert_eq!(off.for_scaffolding().lints.unknown_path, LintLevel::Off);
}
