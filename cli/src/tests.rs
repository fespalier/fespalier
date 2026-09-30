use std::fs;
use std::path::{Path, PathBuf};

use crate::{build, gen, scaffold};

fn example() -> PathBuf {
    examples("shop")
}

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples").join(name)
}

/// A throwaway project with the given files under lib/app.
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
    let (_, diags, _) = build(&dir.path().join("lib/app")).unwrap();
    diags.0.iter().map(|d| d.to_string()).collect()
}

fn code(files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app")).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

#[test]
fn example_app_generates_cleanly() {
    let (code, diags, routes) = build(&example().join("lib/app")).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    assert_eq!(routes, 6);
    has(
        &code,
        &[
            "final class ProductRoute extends TypedLocation {",
            "const ProductRoute({required this.id});",
            "final int id;",
            "import 'app/products/\\$id/page.dart'",
            "path: ':id'",
            "path: 'greet/:name'",
            "path: joinLocation(at, '/')",
            "builder: (context, state, child) => _i3.AppLayout(child: child),",
            "({int id}) _params6(GoRouterState s) => (id: Segment.asInt(s, 'id'));",
            "_i8.GreetPage(name: v.name)",
            "data: (d) => _i13.ProductPage(product: d),",
            "error: (e, st, retry) => _i14.ProductError(id: v.id, error: e, retry: retry),",
            // products/data.dart exports its own provider; it's used as-is.
            "watch: (ref) => ref.watch(_i9.data),",
            "static final data = _i9.data;",
            "(Ref ref, int id) => _i12.data(ref, id: id),",
            "Future<void> refresh(WidgetRef ref) => ref.refresh(data(id).future);",
            "redirect: (context, state) => _i7.guard(ProviderScope.containerOf(context, listen: false)),",
            "String get location => joinLocation(AppRoutes.base, '/products/$id');",
            "'/greet/${Uri.encodeComponent(name)}'",
        ],
    );
}

#[test]
fn committed_output_is_up_to_date() {
    for name in ["shop", "features"] {
        let (code, diags, _) = build(&examples(name).join("lib/app")).unwrap();
        assert!(diags.0.is_empty(), "{name}: {:?}", diags.0);
        let committed = fs::read_to_string(examples(name).join("lib/app.g.dart")).unwrap_or_default();
        assert!(committed == code, "examples/{name}/lib/app.g.dart is stale; run `fsp gen --project examples/{name}`");
    }
}

#[test]
fn page_params_are_filled_by_name_then_type() {
    let c = code(&[
        ("$shop/$id/data.dart", "Future<Item> data(Ref ref, {required String shop, required int id}) async => x;"),
        (
            "$shop/$id/page.dart",
            "class ItemPage extends StatelessWidget {\n  const ItemPage(this.item, {super.key, required this.shop, this.note});\n  final Item item;\n  final String shop;\n  final String? note;\n}",
        ),
    ]);
    has(
        &c,
        &[
            "(v) => DataView(",
            // `String? note` is nothing else, so it's the `?note=` query parameter.
            "data: (d) => _i1.ItemPage(d, shop: v.shop, note: v.note),",
            "({String shop, int id, String? note}) _params2(GoRouterState s) => (shop: Segment.asString(s, 'shop'), id: Segment.asInt(s, 'id'), note: Query.asString(s, 'note'));",
            // Several segments key the provider by a record.
            "(Ref ref, ({String shop, int id}) k) => _i0.data(ref, shop: k.shop, id: k.id),",
            "watch: (ref) => ref.watch(_data2((shop: v.shop, id: v.id))),",
            "const ItemRoute({required this.shop, required this.id, this.note});",
            "withQuery(joinLocation(AppRoutes.base, '/${Uri.encodeComponent(shop)}/$id'), {'note': note})",
            "ref.refresh(data((shop: shop, id: id)).future)",
        ],
    );
}

#[test]
fn page_type_must_match_data() {
    let e = diags(&[
        ("page.dart", HOME),
        ("products/data.dart", "Future<List<Product>> data(Ref ref) async => [];"),
        (
            "products/page.dart",
            "class ProductsPage extends StatelessWidget {\n  const ProductsPage({super.key, required this.data});\n  final Product data;\n}",
        ),
    ]);
    assert_eq!(e, vec!["✗ products/page.dart:2  `data` is Product but data.dart yields List<Product>"]);
}

#[test]
fn unfillable_params_are_errors() {
    let e = diags(&[
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget {\n  const ItemPage({super.key, required this.id, required this.nope, this.ok = 1});\n  final int id; final String nope; final int ok;\n}",
        ),
    ]);
    assert_eq!(e, vec!["✗ $id/page.dart:2  can't fill `nope`: it isn't a segment of this path ($id) or a query parameter (optional and nullable)"]);
}

#[test]
fn segment_types_must_agree() {
    let e = diags(&[
        ("$id/data.dart", "Future<int> data(Ref ref, {required int id}) async => id;"),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget {\n  const ItemPage({super.key, required this.id, required this.n});\n  final String id; final int n;\n}",
        ),
    ]);
    assert_eq!(e, vec!["✗ $id/page.dart:2  `$id` is int in $id/data.dart:1 but String here"]);
}

#[test]
fn segments_are_primitive() {
    let e = diags(&[("$id/data.dart", "Future<int> data(Ref ref, {required List<int> id}) async => 1;"), ("$id/page.dart", HOME)]);
    assert!(e.iter().any(|m| m.contains("`List<int> id`: segments are String, int, double or bool")), "{e:?}");
}

#[test]
fn inherited_views_must_fit_every_route_they_cover() {
    let e = diags(&[
        ("loading.dart", "class L extends StatelessWidget { const L({super.key, required this.id}); final int id; }"),
        ("page.dart", HOME),
        ("data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("$id/data.dart", "Future<int> data(Ref ref, {required int id}) async => 1;"),
        ("$id/page.dart", "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }"),
    ]);
    // Fine for $id/, but the root route has no $id.
    assert_eq!(e.len(), 2, "{e:?}");
    assert!(e[0].starts_with("! page.dart:1  HomePage doesn't take what data.dart yields"), "{e:?}");
    assert_eq!(e[1], "✗ loading.dart:1  can't fill `id` for /: it isn't one of its segments (it has none) or a query parameter (optional and nullable)");
}

#[test]
fn error_views_get_error_and_retry_by_name_or_type() {
    let c = code(&[
        ("error.dart", "class E extends StatelessWidget { const E(this.e, this.again, {super.key, this.stackTrace}); final Object e; final VoidCallback again; final StackTrace? stackTrace; }"),
        ("data.dart", "Stream<int> data(Ref ref) => Stream.value(1);"),
        ("page.dart", "class TickPage extends StatelessWidget { const TickPage(this.n, {super.key}); final int n; }"),
    ]);
    has(
        &c,
        &[
            "error: (e, st, retry) => _i2.E(e, retry, stackTrace: st),",
            "final _data0 = StreamProvider.autoDispose(",
            "(Ref ref) => _i0.data(ref),",
            "/// Restarts data.dart",
        ],
    );
}

#[test]
fn user_providers_are_used_as_is() {
    let c = code(&[
        ("$id/data.dart", "final data = AsyncNotifierProvider.autoDispose.family<ItemNotifier, Item, int>(ItemNotifier.new);"),
        ("$id/page.dart", "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.item}); final Item item; }"),
        ("$a/$b/data.dart", "final data = FutureProvider.family<int, ({int a, String b})>((ref, k) async => k.a);"),
        ("$a/$b/page.dart", "class AbPage extends StatelessWidget { const AbPage(this.n, {super.key}); final int n; }"),
    ]);
    has(
        &c,
        &[
            "watch: (ref) => ref.watch(_i2.data(v.id)),",
            "data: (d) => _i3.ItemPage(item: d),",
            "const ItemRoute({required this.id});\n\n  final int id;",
            "watch: (ref) => ref.watch(_i0.data((a: v.a, b: v.b))),",
            "const AbRoute({required this.a, required this.b});\n\n  final int a;\n  final String b;",
        ],
    );
    assert!(!c.contains("_data"), "no wrapper providers expected:\n{c}");
}

#[test]
fn provider_family_must_name_its_segments() {
    let e = diags(&[
        ("$a/$b/data.dart", "final data = FutureProvider.family<int, int>((ref, a) async => a);"),
        ("$a/$b/page.dart", "class AbPage extends StatelessWidget { const AbPage(this.n, {super.key}); final int n; }"),
        ("x/data.dart", "final data = FutureProvider((ref) async => 1);"),
        ("x/page.dart", "class XPage extends StatelessWidget { const XPage(this.n, {super.key}); final int n; }"),
    ]);
    assert!(e.iter().any(|m| m.contains("must be a record naming the ones it uses")), "{e:?}");
    assert!(e.iter().any(|m| m.contains("give the provider its type arguments, e.g. `FutureProvider<Product>`")), "{e:?}");
}

#[test]
fn data_signature_is_checked() {
    let e = diags(&[
        ("$id/data.dart", "data(ref, int id, {required String nope}) => 1;"),
        ("$id/page.dart", HOME),
    ]);
    let joined = e.join("\n");
    for needle in [
        "data() must take `Ref ref` first",
        "data() takes segments as named parameters, e.g. `{required int id}`",
        "`nope` isn't a segment of this path ($id); for a query parameter make it optional and nullable, e.g. `String? nope`",
        "data() needs an explicit return type",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn layouts_get_child_and_segments_above_them() {
    let c = code(&[
        ("$shop/layout.dart", "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child, required this.shop}); final Widget child; final String shop; }"),
        ("$shop/page.dart", "class ShopPage extends StatelessWidget { const ShopPage({super.key}); }"),
        ("$shop/guard.dart", "Future<String?> guard(ProviderContainer c, {required String shop}) async => null;"),
    ]);
    has(
        &c,
        &[
            "builder: (context, state, child) => buildWithParams(\n          () => _layout1(state),\n          (v) => _i1.ShopLayout(child: child, shop: v.shop),",
            "redirect: (context, state) => guardWithParams(\n              () => _params1(state),\n              (v) => _i2.guard(ProviderScope.containerOf(context, listen: false), shop: v.shop),",
            "path: joinLocation(at, '/:shop')",
        ],
    );
}

#[test]
fn misc_rules() {
    let e = diags(&[
        ("page.dart", HOME),
        ("a/guard.dart", "GuardResult guard(ProviderContainer c) => null;"),
        ("b/not_found.dart", "class N extends StatelessWidget {}"),
        ("c/page.dart", "class HomeScreen extends StatelessWidget {}"),
        ("d/page.dart", "class A extends StatelessWidget {}\nclass B extends StatelessWidget {}"),
        ("Bad Name/page.dart", HOME),
        ("$data/page.dart", HOME),
    ]);
    let joined = e.join("\n");
    for needle in [
        "a/guard.dart  guard.dart needs a page.dart",
        "b/not_found.dart  not_found.dart only works at the root",
        "route name `HomeRoute` is already taken by page.dart",
        "d/page.dart:2  expected one public widget class, found A, B",
        "`Bad Name` is not a valid URL segment",
        "`$data` is reserved",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn errors_leave_output_untouched() {
    let dir = project(&[("page.dart", "class P extends StatelessWidget { const P({required this.x}); final int x; }")]);
    assert!(gen(dir.path(), true).is_err());
    assert!(!dir.path().join("lib/app.g.dart").exists());
}

#[test]
fn scaffold_then_generate() {
    let dir = project(&[("page.dart", HOME), ("$id/data.dart", "Future<int> data(Ref ref, {required int id}) async => id;"), ("$id/page.dart", "class ItemPage extends StatelessWidget { const ItemPage(this.n, {super.key}); final int n; }")]);
    let args = |route: &str, data: bool| scaffold::NewArgs {
        route: route.into(),
        name: Some("Order".into()),
        data,
        loading: true,
        error: true,
        layout: true,
        guard: true,
    };
    scaffold::new_route(dir.path(), &args("orders/[orderId]", true)).unwrap();
    let data = fs::read_to_string(dir.path().join("lib/app/orders/$orderId/data.dart")).unwrap();
    assert!(data.contains("Future<String> data(Ref ref, {required String orderId}) async =>\n    'Hello from /orders/$orderId';"), "{data}");
    gen(dir.path(), true).expect("scaffolded route should check cleanly");

    // Under an existing `$id: int`, the scaffold keeps that type.
    let mut nested = args(":id/notes/:noteId", false);
    nested.name = Some("Note".into());
    scaffold::new_route(dir.path(), &nested).unwrap();
    let page = fs::read_to_string(dir.path().join("lib/app/$id/notes/$noteId/page.dart")).unwrap();
    assert!(page.contains("const NotePage({super.key, required this.id, required this.noteId});"), "{page}");
    assert!(page.contains("final int id;\n  final String noteId;"), "{page}");
    gen(dir.path(), true).expect("nested scaffold should check cleanly");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(code.contains("const NoteRoute({required this.id, required this.noteId});"), "{code}");
}

#[test]
fn query_params_reach_every_file_and_key_data() {
    let c = code(&[
        ("search/data.dart", "Future<List<String>> data(Ref ref, {String? q, int? page}) async => [];"),
        (
            "search/page.dart",
            "class SearchPage extends StatelessWidget {\n  const SearchPage({super.key, required this.results, this.q, this.tags = const []});\n  final List<String> results; final String? q; final List<String> tags;\n}",
        ),
        ("search/loading.dart", "class L extends StatelessWidget { const L({super.key, this.page}); final int? page; }"),
        ("search/guard.dart", "GuardResult guard(ProviderContainer c, {bool? admin}) => null;"),
        ("layout.dart", "class Shell extends StatelessWidget { const Shell({super.key, required this.child, this.theme}); final Widget child; final String? theme; }"),
    ]);
    has(
        &c,
        &[
            "({String? q, int? page, List<String> tags, bool? admin}) _params1(GoRouterState s) => (q: Query.asString(s, 'q'), page: Query.asInt(s, 'page'), tags: Query.asStringList(s, 'tags'), admin: Query.asBool(s, 'admin'));",
            "(Ref ref, ({String? q, int? page}) k) => _i1.data(ref, q: k.q, page: k.page),",
            "watch: (ref) => ref.watch(_data1((q: v.q, page: v.page))),",
            "data: (d) => _i2.SearchPage(results: d, q: v.q, tags: v.tags),",
            "loading: () => _i3.L(page: v.page),",
            "(v) => _i4.guard(ProviderScope.containerOf(context, listen: false), admin: v.admin),",
            "const SearchRoute({this.q, this.page, this.tags = const [], this.admin});",
            "final List<String> tags;",
            "String get location => withQuery(joinLocation(AppRoutes.base, '/search'), {'q': q, 'page': page, 'tags': tags, 'admin': admin});",
            // A layout reads the query too, through its own parser.
            "builder: (context, state, child) => buildWithParams(\n          () => _layout0(state),\n          (v) => _i0.Shell(child: child, theme: v.theme),",
            "({String? theme}) _layout0(GoRouterState s) => (theme: Query.asString(s, 'theme'));",
        ],
    );
}

#[test]
fn query_param_rules() {
    let e = diags(&[
        ("a/data.dart", "Future<int> data(Ref ref, {int? page, List<String> tags = const [], required int n}) async => 1;"),
        ("a/page.dart", "class APage extends StatelessWidget { const APage(this.x, {super.key, this.page}); final int x; final String? page; }"),
    ]);
    let joined = e.join("\n");
    for needle in [
        "a/page.dart:1  `?page` is int? in a/data.dart:1 but String? here",
        "`tags`: data can't be keyed by a List; take a `String?` and split it",
        "`n` isn't a segment of this path (it has none); for a query parameter make it optional and nullable, e.g. `String? n`",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn group_folders_share_a_layout_without_adding_to_the_url() {
    let c = code(&[
        ("(marketing)/layout.dart", "class MarketingLayout extends StatelessWidget { const MarketingLayout({super.key, required this.child}); final Widget child; }"),
        ("(marketing)/page.dart", "class HomePage extends StatelessWidget { const HomePage({super.key}); }"),
        ("(marketing)/about/page.dart", "class AboutPage extends StatelessWidget { const AboutPage({super.key}); }"),
        ("(app)/layout.dart", "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }"),
        ("(app)/loading.dart", "class AppLoading extends StatelessWidget { const AppLoading({super.key}); }"),
        ("(app)/$id/data.dart", "Future<int> data(Ref ref, {required int id}) async => id;"),
        ("(app)/$id/page.dart", "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }"),
    ]);
    has(
        &c,
        &[
            "//   /:id    ItemRoute   (app)/$id/page.dart  (data)\n//   /       HomeRoute   (marketing)/page.dart  (layout)",
            // Each group is its own ShellRoute; the URLs have no trace of it.
            // The one holding `/:id` goes last, so `/about` isn't read as an id.
            "      ShellRoute(\n        builder: (context, state, child) => _i5.MarketingLayout(child: child),",
            "      ShellRoute(\n        builder: (context, state, child) => _i1.AppShell(child: child),\n        routes: [\n          GoRoute(\n            path: joinLocation(at, '/:id'),",
            "loading: () => _i0.AppLoading(),",
            "_i5.MarketingLayout(child: child),\n        routes: [\n          GoRoute(\n            path: joinLocation(at, '/'),",
            "GoRoute(\n                path: 'about',",
            "String get location => joinLocation(AppRoutes.base, '/about');",
            "String get location => joinLocation(AppRoutes.base, '/$id');",
            "import 'app/(app)/\\$id/page.dart'",
        ],
    );
}

#[test]
fn groups_cannot_serve_the_same_url_twice() {
    let e = diags(&[
        ("page.dart", HOME),
        ("(a)/page.dart", "class APage extends StatelessWidget { const APage({super.key}); }"),
        ("(a)/x/page.dart", "class XPage extends StatelessWidget { const XPage({super.key}); }"),
        ("(b)/x/page.dart", "class OtherXPage extends StatelessWidget { const OtherXPage({super.key}); }"),
        ("(bad name)/page.dart", HOME),
    ]);
    let joined = e.join("\n");
    for needle in [
        "(a)/page.dart:1  page.dart already serves /; (group) folders don't add to the URL",
        "(b)/x/page.dart:1  (a)/x/page.dart already serves /x",
        "`(bad name)`: a group name uses a-z, 0-9, - _ . ~",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn static_routes_come_before_dynamic_ones() {
    // go_router takes the first match, so `/about` must not be read as `/:slug`.
    let c = code(&[
        ("page.dart", HOME),
        ("$slug/page.dart", "class SlugPage extends StatelessWidget { const SlugPage({super.key, required this.slug}); final String slug; }"),
        ("about/page.dart", "class AboutPage extends StatelessWidget { const AboutPage({super.key}); }"),
        ("(app)/layout.dart", "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }"),
        ("(app)/settings/page.dart", "class SettingsPage extends StatelessWidget { const SettingsPage({super.key}); }"),
        ("(app)/settings/$tab/page.dart", "class TabPage extends StatelessWidget { const TabPage({super.key, required this.tab}); final String tab; }"),
        ("(app)/settings/general/page.dart", "class GeneralPage extends StatelessWidget { const GeneralPage({super.key}); }"),
    ]);
    let at = |needle: &str| c.find(needle).unwrap_or_else(|| panic!("missing `{needle}` in:\n{c}"));
    assert!(at("path: 'about'") < at("path: ':slug'"), "{c}");
    // A shell whose routes all start with a static segment goes with the static ones.
    assert!(at("AppShell(child: child)") < at("path: ':slug'"), "{c}");
    assert!(at("path: 'general'") < at("path: ':tab'"), "{c}");
}

#[test]
fn routes_a_group_cannot_order_are_reported() {
    // `(app)` holds `:id`, so it sorts after `about`, and `/:slug` too; then
    // `/:slug` catches `/settings` before the (app) shell is ever tried.
    let e = diags(&[
        ("page.dart", HOME),
        ("$slug/page.dart", "class SlugPage extends StatelessWidget { const SlugPage({super.key, required this.slug}); final String slug; }"),
        ("(app)/layout.dart", "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }"),
        ("(app)/settings/page.dart", "class SettingsPage extends StatelessWidget { const SettingsPage({super.key}); }"),
        ("(app)/$id/page.dart", "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }"),
    ]);
    assert_eq!(
        e,
        vec![
            "✗ (app)/settings/page.dart  /settings is unreachable: $slug/page.dart (/:slug) comes first and matches it; move one of them into or out of its (group)",
            "✗ (app)/$id/page.dart  /:id is unreachable: $slug/page.dart (/:slug) comes first and matches it; move one of them into or out of its (group)",
        ]
    );
}
