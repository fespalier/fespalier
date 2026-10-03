use std::fs;
use std::path::{Path, PathBuf};

use crate::config::Config;
use crate::{build, generate, init, scaffold};

fn example() -> PathBuf {
    examples("shop")
}

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
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
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
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

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

#[test]
fn example_app_generates_cleanly() {
    let (code, diags, routes) = build(&example().join("lib/app"), &Config::default()).unwrap();
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
            // The root transition.dart covers every route.
            "pageBuilder: (context, state) => _i3.transition(",
            // ...and the root layout's shell too, under a key that doesn't change.
            "pageBuilder: (context, state, child) => _i3.transition(\n          const ValueKey<String>('layout:/'),\n          _i4.AppLayout(child: child),",
            "({int id}) _params6(GoRouterState s) => (id: Segment.asInt(s, 'id'));",
            "_i9.GreetPage(name: v.name)",
            "data: (d) => _i14.ProductPage(product: d),",
            "error: (e, st, retry) => _i15.ProductError(id: v.id, error: e, retry: retry),",
            // products/data.dart exports its own provider; it's used as-is.
            "watch: (ref) => ref.watch(_i10.data),",
            "static final data = _i10.data;",
            "(Ref ref, int id) => traceData(ref, 'd6', id, _i13.data(ref, id: id)),",
            "Future<void> refresh(WidgetRef ref) => ref.refresh(data(id).future);",
            "redirect: (context, state) => traceGuard(state, 'g2@2', _i8.guard(ProviderScope.containerOf(context, listen: false))),",
            "String get location => joinLocation(AppRoutes.base, '/products/$id');",
            "'/greet/${Uri.encodeComponent(name)}'",
        ],
    );
}

/// A view built with no arguments is `const`, so the framework skips rebuilding it while an
/// ancestor rebuilds (a page under the top of the stack, on every navigation). Only a `const`
/// constructor with nothing to pass qualifies.
#[test]
fn views_built_without_arguments_are_const_when_their_constructor_is() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "plain/page.dart",
            "class PlainPage extends StatelessWidget { PlainPage({super.key}); }",
        ),
        (
            "item/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }",
        ),
        ("page_fn/page.dart", "Widget page() => const Placeholder();"),
    ]);
    // The call is `const` only for HomePage; the ones that can't be are plain.
    let line = |name: &str| {
        c.lines()
            .find(|l| l.contains(name))
            .unwrap_or_default()
            .trim()
    };
    assert!(line(".HomePage(").contains("=> const _i"), "{c}");
    assert!(line(".PlainPage(").ends_with(".PlainPage(),"), "{c}");
    assert!(!line(".PlainPage(").contains("const"), "{c}");
    assert!(line(".ItemPage(").contains(".ItemPage(id: v.id)"), "{c}");
    assert!(!line(".ItemPage(").contains("const _i"), "{c}");
    // A view function is a plain call.
    assert!(!line(".page(").contains("const"), "{c}");
    // The empty literals of a matcher are `const` too.
    has(&c, &["const HomeRoute(), const {}, const [])"]);
}

#[test]
fn committed_output_is_up_to_date() {
    for name in ["shop", "features", "tabs", "minimal", "telemetry"] {
        // The examples' own pubspec.yaml: `output_manifest:` and `meta:` change what is written.
        let cfg = Config::load(&examples(name)).unwrap();
        let (code, diags, app) = crate::analyze(&examples(name).join("lib/app"), &cfg).unwrap();
        assert!(diags.0.is_empty(), "{name}: {:?}", diags.0);
        // `format: true` (examples/minimal) commits the output as `dart format` leaves it. Without
        // `dart` on PATH (the generator's CI job) there is nothing to compare it with: skip.
        let code = if cfg.format {
            let (formatted, warning) =
                crate::format::format_dart(&code, &examples(name).join(&cfg.output));
            if warning.is_some() {
                continue;
            }
            formatted
        } else {
            code
        };
        let committed = fs::read_to_string(examples(name).join(&cfg.output)).unwrap_or_default();
        assert!(
            committed == code,
            "examples/{name}/{} is stale; run `fsp gen --project examples/{name}`",
            cfg.output
        );
        // A separate manifest library is checked in too.
        if let Some(path) = &cfg.output_manifest {
            let manifest = crate::manifest::emit(&app, &cfg).unwrap();
            let committed = fs::read_to_string(examples(name).join(path)).unwrap_or_default();
            assert!(
                committed == manifest,
                "examples/{name}/{path} is stale; run `fsp gen --project examples/{name}`"
            );
        }
    }
}

/// The string-path lint finds nothing in the examples, which are real apps: no false positive.
/// `examples/shop` has a string path that matches and a silenced one that does not.
#[test]
fn examples_have_no_unknown_paths() {
    for name in ["shop", "features", "tabs", "minimal", "telemetry"] {
        let cfg = Config::load(&examples(name)).unwrap();
        let (_, diags, app) = crate::analyze(&examples(name).join("lib/app"), &cfg).unwrap();
        assert!(diags.0.is_empty(), "{name}: {:?}", diags.0);
        let found = crate::lint::check(
            &examples(name),
            &cfg,
            &crate::lint::Table::new(&app),
            &mut crate::lint::Sites::default(),
        );
        assert!(found.0.is_empty(), "{name}: {:?}", found.0);
    }
    let shop = Config::load(&examples("shop")).unwrap();
    assert_eq!(shop.lints.unknown_path, crate::config::LintLevel::Error);
    let page = fs::read_to_string(examples("shop").join("lib/app/page.dart")).unwrap();
    let sites = crate::lint::sites(&page);
    assert_eq!(sites.len(), 2, "{sites:?}");
    assert_eq!(sites.iter().filter(|s| s.ignored).count(), 1, "{sites:?}");
}

/// The runtime package has no route tree of its own, and its code is not a site for the lint
/// either: the paths in its documentation are comments.
#[test]
fn the_package_has_no_string_paths() {
    let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packages/fespalier/lib");
    let mut dirs = vec![lib];
    let mut files = 0;
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|e| e == "dart") {
                files += 1;
                let sites = crate::lint::sites(&fs::read_to_string(&path).unwrap());
                assert!(sites.is_empty(), "{}: {sites:?}", path.display());
            }
        }
    }
    assert!(files > 5);
}

#[test]
fn page_params_are_filled_by_name_then_type() {
    let c = code(&[
        (
            "$shop/$id/data.dart",
            "Future<Item> data(Ref ref, {required String shop, required int id}) async => x;",
        ),
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
            "(Ref ref, ({String shop, int id}) k) => traceData(ref, 'd2', k, _i0.data(ref, shop: k.shop, id: k.id)),",
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
        (
            "products/data.dart",
            "Future<List<Product>> data(Ref ref) async => [];",
        ),
        (
            "products/page.dart",
            "class ProductsPage extends StatelessWidget {\n  const ProductsPage({super.key, required this.data});\n  final Product data;\n}",
        ),
    ]);
    assert_eq!(
        e,
        vec!["✗ products/page.dart:2  `data` is Product but data.dart yields List<Product>"]
    );
}

#[test]
fn unfillable_params_are_errors() {
    let e = diags(&[(
        "$id/page.dart",
        "class ItemPage extends StatelessWidget {\n  const ItemPage({super.key, required this.id, required this.nope, this.ok = 1});\n  final int id; final String nope; final int ok;\n}",
    )]);
    assert_eq!(
        e,
        vec![
            "✗ $id/page.dart:2  can't fill `nope`: it isn't a segment of this path ($id) or a query parameter (optional and nullable)"
        ]
    );
}

#[test]
fn segment_types_must_agree() {
    let e = diags(&[
        (
            "$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget {\n  const ItemPage({super.key, required this.id, required this.n});\n  final String id; final int n;\n}",
        ),
    ]);
    assert_eq!(
        e,
        vec!["✗ $id/page.dart:2  `$id` is int in $id/data.dart:1 but String here"]
    );
}

#[test]
fn segments_are_primitive() {
    let e = diags(&[
        (
            "$id/data.dart",
            "Future<int> data(Ref ref, {required List<int> id}) async => 1;",
        ),
        ("$id/page.dart", HOME),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("`List<int> id`: segments are String, int, double or bool")),
        "{e:?}"
    );
}

#[test]
fn inherited_views_must_fit_every_route_they_cover() {
    let e = diags(&[
        (
            "loading.dart",
            "class L extends StatelessWidget { const L({super.key, required this.id}); final int id; }",
        ),
        ("page.dart", HOME),
        ("data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => 1;",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
        ),
    ]);
    // Fine for $id/, but the root route has no $id.
    assert_eq!(e.len(), 2, "{e:?}");
    assert!(
        e[0].starts_with("! page.dart:1  HomePage doesn't take what data.dart yields"),
        "{e:?}"
    );
    assert_eq!(
        e[1],
        "✗ loading.dart:1  can't fill `id` for /: it isn't one of its segments (it has none) or a query parameter (optional and nullable)"
    );
}

#[test]
fn error_views_get_error_and_retry_by_name_or_type() {
    let c = code(&[
        (
            "error.dart",
            "class E extends StatelessWidget { const E(this.e, this.again, {super.key, this.stackTrace}); final Object e; final VoidCallback again; final StackTrace? stackTrace; }",
        ),
        ("data.dart", "Stream<int> data(Ref ref) => Stream.value(1);"),
        (
            "page.dart",
            "class TickPage extends StatelessWidget { const TickPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    has(
        &c,
        &[
            "error: (e, st, retry) => _i2.E(e, retry, stackTrace: st),",
            "final _data0 = StreamProvider.autoDispose(",
            "(Ref ref) => traceData(ref, 'd0', null, _i0.data(ref)),\n);",
            "/// Restarts data.dart",
        ],
    );
}

#[test]
fn user_providers_are_used_as_is() {
    let c = code(&[
        (
            "$id/data.dart",
            "final data = AsyncNotifierProvider.autoDispose.family<ItemNotifier, Item, int>(ItemNotifier.new);",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.item}); final Item item; }",
        ),
        (
            "$a/$b/data.dart",
            "final data = FutureProvider.family<int, ({int a, String b})>((ref, k) async => k.a);",
        ),
        (
            "$a/$b/page.dart",
            "class AbPage extends StatelessWidget { const AbPage(this.n, {super.key}); final int n; }",
        ),
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
fn provider_family_record_cannot_carry_a_query_parameter() {
    let e = diags(&[
        (
            "$id/data.dart",
            "final data = FutureProvider.family<int, ({int id, int? page})>((ref, k) async => k.id);",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    let joined = e.join("\n");
    assert!(
        joined.contains("`page` isn't a segment of this path ($id); a provider you write can be keyed by segments only"),
        "{joined}"
    );
    // The field is already nullable: the message must not tell the reader to make it so.
    assert!(
        !joined.contains("make it optional and nullable"),
        "{joined}"
    );
    assert!(
        joined.contains("Future<int> data(Ref ref, {int? page})"),
        "{joined}"
    );
}

#[test]
fn an_optional_parameter_of_a_non_query_type_is_not_told_to_be_optional() {
    let e = diags(&[
        (
            "$id/data.dart",
            "Future<int> data(Ref ref, {required int id, Object? page}) async => id;",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    let joined = e.join("\n");
    assert!(joined.contains("its type `Object?` isn't one"), "{joined}");
    assert!(
        !joined.contains("make it optional and nullable"),
        "{joined}"
    );
}

#[test]
fn uppercase_ascii_folder_names_are_accepted_and_the_messages_say_so() {
    let c = code(&[
        ("Products/page.dart", HOME),
        (
            "(Admin)/Users/page.dart",
            "class UsersPage extends StatelessWidget { const UsersPage({super.key}); }",
        ),
    ]);
    has(
        &c,
        &[
            "joinLocation(at, '/Products')",
            "joinLocation(at, '/Users')",
        ],
    );
    let e = diags(&[("(bad name)/page.dart", HOME), ("Bad Name/page.dart", HOME)]);
    let joined = e.join("\n");
    assert!(
        joined.contains("a group name uses a-z, A-Z, 0-9, - _ . ~"),
        "{joined}"
    );
    assert!(joined.contains("(use a-z, A-Z, 0-9, - _ . ~;"), "{joined}");
}

#[test]
fn provider_family_must_name_its_segments() {
    let e = diags(&[
        (
            "$a/$b/data.dart",
            "final data = FutureProvider.family<int, int>((ref, a) async => a);",
        ),
        (
            "$a/$b/page.dart",
            "class AbPage extends StatelessWidget { const AbPage(this.n, {super.key}); final int n; }",
        ),
        (
            "x/data.dart",
            "final data = FutureProvider((ref) async => 1);",
        ),
        (
            "x/page.dart",
            "class XPage extends StatelessWidget { const XPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("must be a record naming the ones it uses")),
        "{e:?}"
    );
    assert!(
        e.iter()
            .any(|m| m
                .contains("give the provider its type arguments, e.g. `FutureProvider<Product>`")),
        "{e:?}"
    );
}

#[test]
fn data_signature_is_checked() {
    let e = diags(&[
        (
            "$id/data.dart",
            "data(ref, int id, {required String nope}) => 1;",
        ),
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
        (
            "$shop/layout.dart",
            "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child, required this.shop}); final Widget child; final String shop; }",
        ),
        (
            "$shop/page.dart",
            "class ShopPage extends StatelessWidget { const ShopPage({super.key}); }",
        ),
        (
            "$shop/guard.dart",
            "Future<String?> guard(ProviderContainer c, {required String shop}) async => null;",
        ),
    ]);
    has(
        &c,
        &[
            "pageBuilder: (context, state, child) => layoutPage(\n          context,\n          state,\n          'layout:\\$shop/',\n          buildWithParams(\n            () => _layout1(state),\n            (v) => _i1.ShopLayout(child: child, shop: v.shop),",
            "redirect: (context, state) => traceGuard(state, 'g1@1', guardWithParams(\n              () => _params1(state),\n              (v) => _i2.guard(ProviderScope.containerOf(context, listen: false), shop: v.shop),",
            "path: joinLocation(at, '/:shop')",
        ],
    );
}

#[test]
fn misc_rules() {
    let e = diags(&[
        ("page.dart", HOME),
        (
            "a/guard.dart",
            "GuardResult guard(ProviderContainer c) => null;",
        ),
        ("c/page.dart", "class HomeScreen extends StatelessWidget {}"),
        (
            "d/page.dart",
            "class A extends StatelessWidget {}\nclass B extends StatelessWidget {}",
        ),
        ("Bad Name/page.dart", HOME),
        ("$data/page.dart", HOME),
    ]);
    let joined = e.join("\n");
    for needle in [
        "a/guard.dart  guard.dart guards no routes",
        "route name `HomeRoute` is already taken by page.dart",
        "d/page.dart:2  expected one public widget class, found A, B",
        "`Bad Name` is not a valid URL segment",
        "`$data` is reserved",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn generated_providers_inherit_the_apps_retry_policy() {
    // Riverpod 3 retries failed providers with backoff for ~40 s. The wrappers fespalier
    // writes leave that to the app's ProviderScope (`data_retry: none` opts out; see
    // refresh_tests.rs).
    let c = code(&[
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "a/page.dart",
            "class APage extends StatelessWidget { const APage(this.n, {super.key}); final int n; }",
        ),
        (
            "$id/data.dart",
            "Stream<int> data(Ref ref, {required int id}) => Stream.value(id);",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    assert!(!c.contains("retryCount"), "{c}");
    has(
        &c,
        &[
            "= FutureProvider.autoDispose(",
            "= StreamProvider.autoDispose.family(",
        ],
    );

    // A provider the user wrote is theirs: no wrapper, nothing added.
    let c = code(&[
        (
            "data.dart",
            "final data = FutureProvider<int>((ref) async => 1);",
        ),
        (
            "page.dart",
            "class HomePage extends StatelessWidget { const HomePage(this.n, {super.key}); final int n; }",
        ),
    ]);
    assert!(!c.contains("retryCount") && !c.contains("_data"), "{c}");
}

#[test]
fn syntax_errors_are_warned_about() {
    let e = diags(&[(
        "cart/page.dart",
        "class CartPage extends StatelessWidget {{\n  const CartPage({super.key});\n}\n",
    )]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].starts_with("! cart/page.dart:1  couldn't fully parse this file; if it doesn't compile, the Dart compiler will say where"),
        "{e:?}"
    );

    // Any file kind, and the warning points at the first problem, not at the class.
    let e = diags(&[
        ("page.dart", HOME),
        (
            "data.dart",
            "Future<int> data(Ref ref) async => 1;\nFuture<int> other( async => ;;\n",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.starts_with("! data.dart:2  couldn't fully parse")),
        "{e:?}"
    );

    // A warning, not an error: generation goes ahead.
    let dir = project(&[(
        "page.dart",
        "class HomePage extends StatelessWidget {{ const HomePage({super.key}); }",
    )]);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(!diags.has_errors(), "{:?}", diags.0);
    assert!(code.contains("const _i0.HomePage()"), "{code}");
}

#[test]
fn valid_newer_syntax_and_primary_constructors_do_not_warn() {
    let c = code(&[
        (
            "page.dart",
            "class HomePage extends StatelessWidget {\n  const HomePage({super.key});\n  Widget build(BuildContext c) => Column(mainAxisAlignment: .center, children: [?null, ...[]]);\n}",
        ),
        (
            "a/page.dart",
            "class APage({super.key, final String? q}) extends StatelessWidget {}",
        ),
        (
            "b/page.dart",
            "class const BPage({super.key}) extends StatelessWidget {}",
        ),
    ]);
    has(&c, &["_i1.APage(q: v.q)", "const _i2.BPage()"]);
}

fn reserved(role: &str, src: &str, files: &[(&str, &str)]) -> Vec<String> {
    let mut all = vec![(role, src)];
    all.extend_from_slice(files);
    diags(&all)
}

#[test]
fn reserved_names_are_type_checked() {
    let e = reserved(
        "not_found.dart",
        "class NotFoundPage extends StatelessWidget {\n  const NotFoundPage({super.key, required this.uri});\n  final String uri;\n}",
        &[],
    );
    assert_eq!(
        e,
        vec!["✗ not_found.dart:2  `uri` gets the requested Uri, but it's declared String"]
    );

    let layout = |ty: &str| {
        format!(
            "class L extends StatelessWidget {{ const L({{super.key, required this.child}}); final {ty} child; }}"
        )
    };
    for (ty, ok) in [
        ("Widget", true),
        ("Widget?", true),
        ("Object", true),
        ("dynamic", true),
        ("Text", false),
        ("String", false),
    ] {
        let e = reserved("layout.dart", &layout(ty), &[("a/page.dart", &page("A"))]);
        if ok {
            assert!(e.is_empty(), "{ty}: {e:?}");
        } else {
            assert_eq!(
                e,
                vec![format!(
                    "✗ layout.dart:1  `child` gets the page as a Widget, but it's declared {ty}"
                )],
                "{ty}"
            );
        }
    }

    let shell = |ty: &str| {
        format!(
            "class L extends StatelessWidget {{ const L({{super.key, required this.shell}}); final {ty} shell; }}"
        )
    };
    assert!(
        reserved(
            "layout.dart",
            &shell("StatefulNavigationShell"),
            &[("a/page.dart", &page("A"))]
        )
        .is_empty()
    );
    let e = reserved("layout.dart", &shell("int"), &[("a/page.dart", &page("A"))]);
    assert_eq!(
        e,
        vec!["✗ layout.dart:1  `shell` gets the StatefulNavigationShell, but it's declared int"]
    );
}

#[test]
fn error_view_names_are_type_checked() {
    let error = |fields: &str, params: &str| {
        let src = format!(
            "class E extends StatelessWidget {{ const E({{super.key, {params}}}); {fields} }}"
        );
        reserved(
            "error.dart",
            &src,
            &[
                ("data.dart", "Future<int> data(Ref ref) async => 1;"),
                (
                    "page.dart",
                    "class HomePage extends StatelessWidget { const HomePage(this.n, {super.key}); final int n; }",
                ),
            ],
        )
    };
    for (fields, params) in [
        (
            "final Object error; final StackTrace stackTrace; final VoidCallback retry;",
            "required this.error, required this.stackTrace, required this.retry",
        ),
        (
            "final Object? error; final StackTrace? stackTrace; final void Function() retry;",
            "required this.error, this.stackTrace, required this.retry",
        ),
        (
            "final dynamic error; final void Function()? retry;",
            "required this.error, this.retry",
        ),
        (
            "final Object error; final Function retry;",
            "required this.error, required this.retry",
        ),
    ] {
        let e = error(fields, params);
        // `Function` isn't one of the known callback spellings: that one is reported.
        if fields.contains("final Function retry") {
            assert_eq!(
                e,
                vec![
                    "✗ error.dart:1  `retry` gets the retry callback, a VoidCallback, but it's declared Function"
                ],
                "{e:?}"
            );
        } else {
            assert!(e.is_empty(), "{fields}: {e:?}");
        }
    }
    let e = error(
        "final String error; final int stackTrace; final Future<void> retry;",
        "required this.error, required this.stackTrace, required this.retry",
    );
    assert_eq!(
        e,
        vec![
            "✗ error.dart:1  `error` gets the error, an Object, but it's declared String",
            "✗ error.dart:1  `stackTrace` gets the StackTrace, but it's declared int",
            "✗ error.dart:1  `retry` gets the retry callback, a VoidCallback, but it's declared Future<void>",
        ]
    );
    // No field type to go by: nothing to check.
    let e = error(
        "var error; var retry;",
        "required this.error, required this.retry",
    );
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn transition_names_are_type_checked() {
    for (sig, ok) in [
        ("Widget child, LocalKey key, GoRouterState state", true),
        ("Widget child, Key key", true),
        ("Widget child, ValueKey<String> key", true),
        ("Widget child, Object key", true),
        ("Widget child, {GoRouterState? state}", true),
        ("Widget child, String key", false),
        ("String child", false),
        ("Widget child, {required int state}", false),
    ] {
        let src = format!("Page<void> transition({sig}) => x;");
        let e = diags(&[("transition.dart", &src), ("page.dart", HOME)]);
        assert_eq!(e.is_empty(), ok, "{sig}: {e:?}");
        if !ok {
            assert!(
                e[0].starts_with("✗ transition.dart:1  `")
                    && e[0].contains("` gets ")
                    && e[0].contains(", but it's declared "),
                "{e:?}"
            );
        }
    }
    let e = diags(&[
        (
            "transition.dart",
            "Page<void> transition(String key, Widget child) => x;",
        ),
        ("page.dart", HOME),
    ]);
    assert_eq!(
        e,
        vec![
            "✗ transition.dart:1  `key` gets the page's key, a ValueKey<String>, but it's declared String"
        ]
    );
}

#[test]
fn one_error_for_a_url_served_twice() {
    let cart = "class CartPage extends StatelessWidget {\n  const CartPage({super.key});\n}";
    let e = diags(&[("(dup)/cart/page.dart", cart), ("cart/page.dart", cart)]);
    assert_eq!(
        e,
        vec![
            "✗ cart/page.dart:1  /cart is served by both (dup)/cart/page.dart and cart/page.dart; (group) folders don't add to the URL, so move or rename one"
        ]
    );

    // Different URLs, same class name: the route name is what clashes.
    let e = diags(&[("a/page.dart", cart), ("b/page.dart", cart)]);
    assert_eq!(
        e,
        vec![
            "✗ b/page.dart:1  route name `CartRoute` is already taken by a/page.dart; rename the class"
        ]
    );
}

#[test]
fn an_empty_page_is_one_error() {
    for src in ["", "// TODO\n", "class _Private extends StatelessWidget {}"] {
        let e = diags(&[("page.dart", HOME), ("cart/page.dart", src)]);
        assert_eq!(
            e,
            vec!["✗ cart/page.dart  expected a public widget class"],
            "{src:?}"
        );
    }
    // Still told about a folder that holds nothing at all.
    let e = diags(&[
        ("page.dart", HOME),
        ("empty/notes.txt", "hi"),
        ("nothing/_private/x.dart", ""),
    ]);
    assert_eq!(
        e,
        vec![
            "! empty  folder has no page.dart and no routes below it; skipped",
            "! nothing  folder has no page.dart and no routes below it; skipped",
        ]
    );
}

#[test]
fn errors_leave_output_untouched() {
    let dir = project(&[(
        "page.dart",
        "class P extends StatelessWidget { const P({required this.x}); final int x; }",
    )]);
    assert!(generate(dir.path(), true).is_err());
    assert!(!dir.path().join("lib/app.g.dart").exists());
}

#[test]
fn scaffold_then_generate() {
    let dir = project(&[
        ("page.dart", HOME),
        (
            "$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    let args = |route: &str, data: bool| scaffold::NewArgs {
        route: route.into(),
        name: Some("Order".into()),
        function: false,
        not_found: false,
        data,
        action: false,
        loading: true,
        error: true,
        layout: true,
        guard: true,
        transition: false,
        observe: false,
    };
    scaffold::new_route(dir.path(), &args("orders/[orderId]", true)).unwrap();
    let data = fs::read_to_string(dir.path().join("lib/app/orders/$orderId/data.dart")).unwrap();
    assert!(data.contains("Future<String> data(Ref ref, {required String orderId}) async =>\n    'Hello from /orders/$orderId';"), "{data}");
    generate(dir.path(), true).expect("scaffolded route should check cleanly");

    // Under an existing `$id: int`, the scaffold keeps that type.
    let mut nested = args(":id/notes/:noteId", false);
    nested.name = Some("Note".into());
    scaffold::new_route(dir.path(), &nested).unwrap();
    let page = fs::read_to_string(dir.path().join("lib/app/$id/notes/$noteId/page.dart")).unwrap();
    assert!(
        page.contains("const NotePage({super.key, required this.id, required this.noteId});"),
        "{page}"
    );
    assert!(
        page.contains("final int id;\n  final String noteId;"),
        "{page}"
    );
    generate(dir.path(), true).expect("nested scaffold should check cleanly");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(
        code.contains("const NoteRoute({required this.id, required this.noteId});"),
        "{code}"
    );
}

#[test]
fn query_params_reach_every_file_and_key_data() {
    let c = code(&[
        (
            "search/data.dart",
            "Future<List<String>> data(Ref ref, {String? q, int? page}) async => [];",
        ),
        (
            "search/page.dart",
            "class SearchPage extends StatelessWidget {\n  const SearchPage({super.key, required this.results, this.q, this.tags = const []});\n  final List<String> results; final String? q; final List<String> tags;\n}",
        ),
        (
            "search/loading.dart",
            "class L extends StatelessWidget { const L({super.key, this.page}); final int? page; }",
        ),
        (
            "search/guard.dart",
            "GuardResult guard(ProviderContainer c, {bool? admin}) => null;",
        ),
        (
            "layout.dart",
            "class Shell extends StatelessWidget { const Shell({super.key, required this.child, this.theme}); final Widget child; final String? theme; }",
        ),
    ]);
    has(
        &c,
        &[
            "({String? q, int? page, List<String> tags, bool? admin}) _params1(GoRouterState s) => (q: Query.asString(s, 'q'), page: Query.asInt(s, 'page'), tags: Query.asStringList(s, 'tags'), admin: Query.asBool(s, 'admin'));",
            "(Ref ref, ({String? q, int? page}) k) => traceData(ref, 'd1', k, _i1.data(ref, q: k.q, page: k.page)),",
            "watch: (ref) => ref.watch(_data1((q: v.q, page: v.page))),",
            "data: (d) => _i2.SearchPage(results: d, q: v.q, tags: v.tags),",
            "loading: () => _i3.L(page: v.page),",
            "(v) => _i4.guard(ProviderScope.containerOf(context, listen: false), admin: v.admin),",
            "const SearchRoute({this.q, this.page, this.tags = const [], this.admin});",
            "final List<String> tags;",
            "String get location => withQuery(joinLocation(AppRoutes.base, '/search'), {'q': q, 'page': page, 'tags': tags, 'admin': admin});",
            // A layout reads the query too, through its own parser.
            "pageBuilder: (context, state, child) => layoutPage(\n          context,\n          state,\n          'layout:/',\n          buildWithParams(\n            () => _layout0(state),\n            (v) => _i0.Shell(child: child, theme: v.theme),",
            "({String? theme}) _layout0(GoRouterState s) => (theme: Query.asString(s, 'theme'));",
        ],
    );
}

#[test]
fn query_param_rules() {
    let e = diags(&[
        (
            "a/data.dart",
            "Future<int> data(Ref ref, {int? page, required int n}) async => 1;",
        ),
        (
            "a/page.dart",
            "class APage extends StatelessWidget { const APage(this.x, {super.key, this.page}); final int x; final String? page; }",
        ),
    ]);
    let joined = e.join("\n");
    for needle in [
        "a/page.dart:1  `?page` is int? in a/data.dart:1 but String? here",
        "`n` isn't a segment of this path (it has none); for a query parameter make it optional and nullable, e.g. `String? n`",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn group_folders_share_a_layout_without_adding_to_the_url() {
    let c = code(&[
        (
            "(marketing)/layout.dart",
            "class MarketingLayout extends StatelessWidget { const MarketingLayout({super.key, required this.child}); final Widget child; }",
        ),
        (
            "(marketing)/page.dart",
            "class HomePage extends StatelessWidget { const HomePage({super.key}); }",
        ),
        (
            "(marketing)/about/page.dart",
            "class AboutPage extends StatelessWidget { const AboutPage({super.key}); }",
        ),
        (
            "(app)/layout.dart",
            "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }",
        ),
        (
            "(app)/loading.dart",
            "class AppLoading extends StatelessWidget { const AppLoading({super.key}); }",
        ),
        (
            "(app)/$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "(app)/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
        ),
    ]);
    has(
        &c,
        &[
            "//   /:id    ItemRoute   (app)/$id/page.dart  (data)\n//   /       HomeRoute   (marketing)/page.dart  (layout)",
            // Each group is its own ShellRoute; the URLs have no trace of it.
            // The one holding `/:id` goes last, so `/about` isn't read as an id.
            "      ShellRoute(\n        pageBuilder: (context, state, child) => layoutPage(\n          context,\n          state,\n          'layout:(marketing)/',\n          _i5.MarketingLayout(child: child),",
            "      ShellRoute(\n        pageBuilder: (context, state, child) => layoutPage(\n          context,\n          state,\n          'layout:(app)/',\n          _i1.AppShell(child: child),\n        ),\n        routes: [\n          GoRoute(\n            path: joinLocation(at, '/:id'),",
            "loading: () => const _i0.AppLoading(),",
            "_i5.MarketingLayout(child: child),\n        ),\n        routes: [\n          GoRoute(\n            path: joinLocation(at, '/'),",
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
        (
            "(a)/page.dart",
            "class APage extends StatelessWidget { const APage({super.key}); }",
        ),
        (
            "(a)/x/page.dart",
            "class XPage extends StatelessWidget { const XPage({super.key}); }",
        ),
        (
            "(b)/x/page.dart",
            "class OtherXPage extends StatelessWidget { const OtherXPage({super.key}); }",
        ),
        ("(bad name)/page.dart", HOME),
    ]);
    let joined = e.join("\n");
    for needle in [
        "(a)/page.dart:1  / is served by both page.dart and (a)/page.dart; (group) folders don't add to the URL, so move or rename one",
        "(b)/x/page.dart:1  /x is served by both (a)/x/page.dart and (b)/x/page.dart; (group) folders don't add to the URL, so move or rename one",
        "`(bad name)`: a group name uses a-z, A-Z, 0-9, - _ . ~",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn static_routes_come_before_dynamic_ones() {
    // go_router takes the first match, so `/about` must not be read as `/:slug`.
    let c = code(&[
        ("page.dart", HOME),
        (
            "$slug/page.dart",
            "class SlugPage extends StatelessWidget { const SlugPage({super.key, required this.slug}); final String slug; }",
        ),
        (
            "about/page.dart",
            "class AboutPage extends StatelessWidget { const AboutPage({super.key}); }",
        ),
        (
            "(app)/layout.dart",
            "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }",
        ),
        (
            "(app)/settings/page.dart",
            "class SettingsPage extends StatelessWidget { const SettingsPage({super.key}); }",
        ),
        (
            "(app)/settings/$tab/page.dart",
            "class TabPage extends StatelessWidget { const TabPage({super.key, required this.tab}); final String tab; }",
        ),
        (
            "(app)/settings/general/page.dart",
            "class GeneralPage extends StatelessWidget { const GeneralPage({super.key}); }",
        ),
    ]);
    let at = |needle: &str| {
        c.find(needle)
            .unwrap_or_else(|| panic!("missing `{needle}` in:\n{c}"))
    };
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
        (
            "$slug/page.dart",
            "class SlugPage extends StatelessWidget { const SlugPage({super.key, required this.slug}); final String slug; }",
        ),
        (
            "(app)/layout.dart",
            "class AppShell extends StatelessWidget { const AppShell({super.key, required this.child}); final Widget child; }",
        ),
        (
            "(app)/settings/page.dart",
            "class SettingsPage extends StatelessWidget { const SettingsPage({super.key}); }",
        ),
        (
            "(app)/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }",
        ),
    ]);
    assert_eq!(
        e,
        vec![
            "✗ (app)/settings/page.dart:1  /settings is unreachable: $slug/page.dart (/:slug) comes first and matches it; move one of them into or out of its (group)",
            "✗ (app)/$id/page.dart:1  /:id is unreachable: $slug/page.dart (/:slug) comes first and matches it; move one of them into or out of its (group)",
        ]
    );
}

const FADE: &str =
    "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

#[test]
fn transition_applies_to_every_page_below_it() {
    let c = code(&[
        ("transition.dart", FADE),
        ("page.dart", HOME),
        ("about/page.dart", &page("About")),
        (
            "$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
        ),
    ]);
    has(
        &c,
        &[
            "//   /:id    ItemRoute   $id/page.dart  (data, transition)",
            "//   /about  AboutRoute  about/page.dart  (transition)",
            "import 'app/transition.dart' as _i1;",
            // The page is exactly what `builder:` would have returned.
            "pageBuilder: (context, state) => _i1.transition(\n          state.pageKey,\n          const _i0.HomePage(),\n        ),",
            "pageBuilder: (context, state) => _i1.transition(\n              state.pageKey,\n              buildWithParams(\n                () => _params1(state),\n                (v) => DataView(",
            "data: (d) => _i3.ItemPage(data: d),",
            "                () => notFound(state.uri),\n              ),\n            ),\n",
        ],
    );
    assert!(!c.contains("builder: (context, state) =>"), "{c}");
}

/// The `transition.dart` import (`_iN`) a page's `pageBuilder` calls.
fn transition_of(code: &str, class: &str) -> String {
    let at = code
        .find(&format!(".{class}()"))
        .unwrap_or_else(|| panic!("missing {class} in:\n{code}"));
    let before = &code[..at];
    let call = before.rfind(".transition(").unwrap();
    let start = before[..call].rfind("_i").unwrap();
    let ix = &before[start + 2..call];
    let file = code
        .lines()
        .find(|l| l.ends_with(&format!("as _i{ix};")))
        .unwrap();
    file.trim_start_matches("import 'app/")
        .split('\'')
        .next()
        .unwrap()
        .to_string()
}

#[test]
fn nearest_transition_wins() {
    let c = code(&[
        ("transition.dart", FADE),
        ("page.dart", HOME),
        ("admin/transition.dart", FADE),
        ("admin/page.dart", &page("Admin")),
        ("admin/users/page.dart", &page("Users")),
        ("blog/page.dart", &page("Blog")),
        ("(auth)/transition.dart", FADE),
        ("(auth)/login/page.dart", &page("Login")),
    ]);
    for (class, from) in [
        ("HomePage", "transition.dart"),
        ("BlogPage", "transition.dart"),
        // A folder's own transition covers its page and the routes below.
        ("AdminPage", "admin/transition.dart"),
        ("UsersPage", "admin/transition.dart"),
        ("LoginPage", "(auth)/transition.dart"),
    ] {
        assert_eq!(transition_of(&c, class), from, "{class} in:\n{c}");
    }
}

#[test]
fn transition_in_a_group_leaves_other_routes_alone() {
    let c = code(&[
        ("page.dart", HOME),
        ("(auth)/transition.dart", FADE),
        ("(auth)/login/page.dart", &page("Login")),
    ]);
    has(
        &c,
        &[
            "//   /       HomeRoute   page.dart\n",
            "(transition)",
            "builder: (context, state) => const _i0.HomePage(),",
        ],
    );
    assert_eq!(c.matches("pageBuilder:").count(), 1, "{c}");
    assert_eq!(transition_of(&c, "LoginPage"), "(auth)/transition.dart");
}

#[test]
fn transition_params_are_filled_by_name_then_type() {
    let c = code(&[
        (
            "transition.dart",
            "CustomTransitionPage<void> transition(Widget page, LocalKey k, {GoRouterState? state, Duration? duration, bool slow = false}) => x;",
        ),
        ("page.dart", HOME),
    ]);
    has(
        &c,
        &[
            "_i1.transition(\n          const _i0.HomePage(),\n          state.pageKey,\n          state: state,\n        ),",
        ],
    );
    assert!(!c.contains("duration") && !c.contains("slow"), "{c}");

    let c = code(&[
        (
            "transition.dart",
            "Page<void> transition({required Widget child, required ValueKey<String> key}) => x;",
        ),
        ("page.dart", HOME),
    ]);
    has(
        &c,
        &["child: const _i0.HomePage(),\n          key: state.pageKey,"],
    );
}

#[test]
fn transition_errors() {
    for (src, needle) in [
        (
            "Widget transition(LocalKey key, Widget child) => child;",
            "transition.dart:1  transition() must return a Page, e.g. `Page<void>`",
        ),
        (
            "transition(LocalKey key, Widget child) => x;",
            "transition() must return a Page",
        ),
        (
            "Page<void> fade(LocalKey key, Widget child) => x;",
            "transition.dart  expected `Page<void> transition(LocalKey key, Widget child)`",
        ),
        (
            "Page<void> transition(Widget child, Duration d) => x;",
            "transition.dart:1  can't fill `d`: transition() gets `key`, `child` and `state`",
        ),
        (
            "Page<void> transition(LocalKey key) => x;",
            "transition.dart:1  transition() must take the page as `Widget child`",
        ),
    ] {
        let e = diags(&[("transition.dart", src), ("page.dart", HOME)]).join("\n");
        assert!(e.contains(needle), "missing `{needle}` in:\n{e}");
    }
}

#[test]
fn scaffold_writes_a_transition() {
    let dir = project(&[("page.dart", HOME)]);
    let args = scaffold::NewArgs {
        route: "docs".into(),
        name: None,
        function: false,
        not_found: false,
        data: false,
        action: false,
        loading: false,
        error: false,
        layout: false,
        guard: false,
        transition: true,
        observe: false,
    };
    scaffold::new_route(dir.path(), &args).unwrap();
    let t = fs::read_to_string(dir.path().join("lib/app/docs/transition.dart")).unwrap();
    assert!(
        t.contains(
            "Page<void> transition(LocalKey key, Widget child) =>\n    Transitions.fade(key, child);"
        ),
        "{t}"
    );
    generate(dir.path(), true).expect("scaffolded transition should check cleanly");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(
        &code,
        &[
            "(transition)",
            "pageBuilder: (context, state) => _i2.transition(",
        ],
    );
}

// --- tab layouts -----------------------------------------------------------

const TABS: &str = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";

/// Where `needle` first appears in `code`; panics with the code if it doesn't.
fn at(code: &str, needle: &str) -> usize {
    code.find(needle)
        .unwrap_or_else(|| panic!("missing `{needle}` in:\n{code}"))
}

#[test]
fn tab_layout_makes_a_branch_of_each_folder() {
    let c = code(&[
        ("layout.dart", TABS),
        ("page.dart", HOME),
        ("search/page.dart", &page("Search")),
        ("(account)/profile/page.dart", &page("Profile")),
        ("(account)/profile/edit/page.dart", &page("Edit")),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute.indexedStack(\n        pageBuilder: (context, state, navigationShell) => layoutPage(\n          context,\n          state,\n          'layout:/',\n          _i1.TabsLayout(navigationShell: navigationShell),\n        ),\n        branches: [",
            "StatefulShellBranch(\n            routes: [\n              GoRoute(\n                path: joinLocation(at, '/'),\n                builder: (context, state) => const _i0.HomePage(),\n              ),\n            ],\n            restorationScopeId: 'tab:/.',\n          ),",
            "path: joinLocation(at, '/search'),",
            // A group is a branch too, and adds nothing to the URL.
            "path: joinLocation(at, '/profile'),",
            "path: 'edit',",
        ],
    );
    assert_eq!(c.matches("StatefulShellBranch(").count(), 3, "{c}");
    assert!(
        !c.contains("ShellRoute(\n"),
        "no plain ShellRoute expected:\n{c}"
    );
    // The folder's own page first, then the subfolders in folder order: (account), search.
    assert!(
        at(&c, "'/'),") < at(&c, "'/profile'),") && at(&c, "'/profile'),") < at(&c, "'/search'),"),
        "{c}"
    );
    // The own page doesn't nest the other tabs, and nothing else is a child of it.
    assert_eq!(c.matches("routes: [").count(), 3 + 1, "{c}");
}

#[test]
fn tab_order_can_be_set_with_a_tabs_list() {
    let layout = format!("const tabs = ['search', '.', '(account)'];\n{TABS}");
    let c = code(&[
        ("layout.dart", &layout),
        ("page.dart", HOME),
        ("search/page.dart", &page("Search")),
        ("(account)/profile/page.dart", &page("Profile")),
    ]);
    assert!(
        at(&c, "'/search'),") < at(&c, "'/'),") && at(&c, "'/'),") < at(&c, "'/profile'),"),
        "{c}"
    );

    // Typed and `const`-less lists work too.
    let layout = format!("final List<String> tabs = <String>[\"b\", 'a'];\n{TABS}");
    let c = code(&[
        ("layout.dart", &layout),
        ("a/page.dart", &page("A")),
        ("b/page.dart", &page("B")),
    ]);
    assert!(at(&c, "'/b'),") < at(&c, "'/a'),"), "{c}");
}

#[test]
fn tabs_list_errors_point_at_layout_dart() {
    let files = |tabs: &str| {
        diags(&[
            ("layout.dart", &format!("{tabs}\n{TABS}")),
            ("page.dart", HOME),
            ("search/page.dart", &page("Search")),
            ("profile/page.dart", &page("Profile")),
        ])
    };
    assert_eq!(
        files("const tabs = ['.', 'search', 'profile', 'help'];"),
        vec![
            "✗ layout.dart:1  `tabs` lists `help`, which is not a branch here; the branches are `.`, `profile`, `search`"
        ]
    );
    assert_eq!(
        files("const tabs = ['.', 'search'];"),
        vec![
            "✗ layout.dart:1  `tabs` is missing the branch `profile`; list every branch once (`.`, `profile`, `search`)"
        ]
    );
    assert_eq!(
        files("const tabs = ['.', 'search', 'profile', 'search'];"),
        vec!["✗ layout.dart:1  `tabs` lists `search` twice"]
    );
    // '.' means the folder's own page, so it must have one.
    let e = diags(&[
        (
            "layout.dart",
            &format!("const tabs = ['.', 'a', 'b'];\n{TABS}"),
        ),
        ("a/page.dart", &page("A")),
        ("b/page.dart", &page("B")),
    ]);
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  `tabs` lists `.`, which is not a branch here; the branches are `a`, `b`"
        ]
    );
    // Not a folder with routes.
    let e = diags(&[
        (
            "layout.dart",
            &format!("const tabs = ['a', 'empty'];\n{TABS}"),
        ),
        ("a/page.dart", &page("A")),
        (
            "empty/layout.dart",
            "class L extends StatelessWidget { const L({super.key, required this.child}); final Widget child; }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("`tabs` lists `empty`, which is not a branch here")),
        "{e:?}"
    );
    // Something other than string literals.
    for bad in [
        "const tabs = ['a', name];",
        "const tabs = ['a', 'b$x'];",
        "const tabs = buildTabs();",
    ] {
        let e = diags(&[
            ("layout.dart", &format!("{bad}\n{TABS}")),
            ("a/page.dart", &page("A")),
        ]);
        assert_eq!(
            e,
            vec![
                "✗ layout.dart:1  `tabs` must be a list of string literals naming the branches, e.g. `const tabs = ['home', 'search'];`"
            ],
            "{bad}"
        );
    }
}

#[test]
fn a_layout_takes_a_child_or_a_shell_not_both() {
    let e = diags(&[
        (
            "layout.dart",
            "class Both extends StatelessWidget { const Both({super.key, required this.child, required this.shell}); final Widget child; final StatefulNavigationShell shell; }",
        ),
        ("a/page.dart", &page("A")),
    ]);
    assert_eq!(
        e,
        vec![
            "✗ layout.dart:1  Both asks for both a `child` and a navigation shell; a tab layout takes only the `StatefulNavigationShell`"
        ]
    );
}

#[test]
fn shell_is_found_by_name_or_by_type() {
    for ctor in [
        "const L(this.nav, {super.key}); final StatefulNavigationShell nav;",
        "const L({super.key, required this.shell}); final StatefulNavigationShell shell;",
        "const L({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell;",
    ] {
        let layout = format!("class L extends StatelessWidget {{ {ctor} }}");
        let c = code(&[("layout.dart", &layout), ("a/page.dart", &page("A"))]);
        let arg = if ctor.contains("this.nav,") {
            "_i0.L(navigationShell)"
        } else if ctor.contains("this.shell") {
            "_i0.L(shell: navigationShell)"
        } else {
            "_i0.L(navigationShell: navigationShell)"
        };
        has(&c, &["StatefulShellRoute.indexedStack(", arg]);
    }
}

#[test]
fn a_tab_holds_nested_routes_data_guards_and_transitions() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("transition.dart", FADE),
        ("(tabs)/(home)/page.dart", HOME),
        (
            "(tabs)/shop/loading.dart",
            "class Busy extends StatelessWidget { const Busy({super.key}); }",
        ),
        (
            "(tabs)/shop/data.dart",
            "Future<List<String>> data(Ref ref) async => [];",
        ),
        (
            "(tabs)/shop/page.dart",
            "class ShopPage extends StatelessWidget { const ShopPage(this.items, {super.key}); final List<String> items; }",
        ),
        (
            "(tabs)/shop/cart/guard.dart",
            "GuardResult guard(ProviderContainer c) => null;",
        ),
        ("(tabs)/shop/cart/page.dart", &page("Cart")),
        (
            "(tabs)/shop/$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "(tabs)/shop/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
        ),
        (
            "(tabs)/help/layout.dart",
            "class HelpLayout extends StatelessWidget { const HelpLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("(tabs)/help/page.dart", &page("Help")),
    ]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/shop'),",
            // Nested inside the tab, relative to the page, static before dynamic.
            "path: 'cart',",
            "redirect: (context, state) => traceGuard(state, 'g6@6', _i11.guard(ProviderScope.containerOf(context, listen: false))),",
            "path: ':id',",
            "data: (d) => _i9.ItemPage(data: d),",
            "data: (d) => _i6.ShopPage(d),",
            "loading: () => const _i7.Busy(),",
            "pageBuilder: (context, state) => _i0.transition(",
            // A plain layout inside a tab is still a ShellRoute, within the branch.
            "ShellRoute(\n                pageBuilder: (context, state, child) => _i0.transition(\n                  const ValueKey<String>('layout:(tabs)/help/'),\n                  _i4.HelpLayout(child: child),\n                ),",
        ],
    );
    assert!(at(&c, "path: 'cart',") < at(&c, "path: ':id',"), "{c}");
    assert_eq!(c.matches("StatefulShellBranch(").count(), 3, "{c}");
}

#[test]
fn tab_layouts_read_segments_and_query_like_other_layouts() {
    let c = code(&[
        (
            "$shop/page.dart",
            "class ShopPage extends StatelessWidget { const ShopPage({super.key, required this.shop}); final int shop; }",
        ),
        (
            "$shop/(tabs)/layout.dart",
            "class ShopTabs extends StatelessWidget { const ShopTabs({super.key, required this.shell, required this.shop, this.theme}); final StatefulNavigationShell shell; final int shop; final String? theme; }",
        ),
        ("$shop/(tabs)/orders/page.dart", &page("Orders")),
        ("$shop/(tabs)/profile/page.dart", &page("Profile")),
    ]);
    has(
        &c,
        &[
            "StatefulShellRoute.indexedStack(\n            pageBuilder: (context, state, navigationShell) => layoutPage(\n              context,\n              state,\n              'layout:\\$shop/(tabs)/',\n              buildWithParams(\n                () => _layout2(state),\n                (v) => _i1.ShopTabs(shell: navigationShell, shop: v.shop, theme: v.theme),\n                () => notFound(state.uri),\n              ),\n            ),",
            "({int shop, String? theme}) _layout2(GoRouterState s) => (shop: Segment.asInt(s, 'shop'), theme: Query.asString(s, 'theme'));",
            // Below the page that holds `$shop`, the tabs' paths are relative to it.
            "path: joinLocation(at, '/:shop'),",
            "path: 'orders',",
            "path: 'profile',",
        ],
    );
    assert_eq!(c.matches("StatefulShellBranch(").count(), 2, "{c}");
}

#[test]
fn a_tab_cannot_start_on_a_path_with_a_segment() {
    // go_router opens a tab on its first GoRoute and refuses `:shop` in its path.
    let e = diags(&[
        ("$shop/layout.dart", TABS),
        ("$shop/page.dart", &page("Shop")),
        ("$shop/orders/page.dart", &page("Orders")),
        ("(all)/layout.dart", TABS),
        ("(all)/$id/page.dart", &page("Item")),
    ]);
    let joined = e.join("\n");
    for needle in [
        "$shop/page.dart:1  /:shop is the first route of a tab, and go_router can't open a tab on a path with a `:segment` in it;",
        "(all)/$id/page.dart:1  /:id is the first route of a tab",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
    // The tabs after the first one are fine, as are static routes ahead of dynamic ones.
    let e = diags(&[
        ("layout.dart", TABS),
        ("items/page.dart", &page("Items")),
        ("items/$id/page.dart", &page("Item")),
        ("users/$name/page.dart", &page("User")),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].contains("users/$name/page.dart:1  /users/:name is the first route of a tab"),
        "{e:?}"
    );
}

#[test]
fn a_tab_layout_below_a_page_uses_relative_paths() {
    let c = code(&[
        ("account/page.dart", &page("Account")),
        ("account/(tabs)/layout.dart", TABS),
        ("account/(tabs)/orders/page.dart", &page("Orders")),
        ("account/(tabs)/prefs/page.dart", &page("Prefs")),
    ]);
    has(
        &c,
        &[
            "path: joinLocation(at, '/account'),",
            "StatefulShellRoute.indexedStack(",
            "path: 'orders',",
            "path: 'prefs',",
        ],
    );
    assert!(!c.contains("joinLocation(at, '/account/"), "{c}");
}

#[test]
fn route_order_is_checked_across_branches() {
    // Distinct URLs in different tabs never clash, dynamic ones included: what
    // matters is that a tab's `/:id` comes after the static routes it could catch.
    let c = code(&[
        ("layout.dart", TABS),
        ("page.dart", HOME),
        ("about/page.dart", &page("About")),
        ("items/page.dart", &page("Items")),
        (
            "items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final String id; }",
        ),
        ("users/page.dart", &page("Users")),
        (
            "users/$name/page.dart",
            "class UserPage extends StatelessWidget { const UserPage({super.key, required this.name}); final String name; }",
        ),
    ]);
    has(&c, &["path: ':id',", "path: ':name',"]);

    // Static goes before dynamic inside a tab, but the tabs themselves keep their
    // order, so a tab holding `/:slug` ahead of one holding `/about` is reported.
    let slug = "class SlugPage extends StatelessWidget { const SlugPage({super.key, required this.slug}); final String slug; }";
    let files = |layout: &str| {
        diags(&[
            ("(tabs)/layout.dart", layout),
            ("(tabs)/(main)/page.dart", HOME),
            ("(tabs)/(main)/$slug/page.dart", slug),
            ("(tabs)/about/page.dart", &page("About")),
        ])
    };
    assert_eq!(
        files(TABS),
        vec![
            "✗ (tabs)/about/page.dart:1  /about is unreachable: (tabs)/(main)/$slug/page.dart (/:slug) comes first and matches it; move one of them into or out of its (group)"
        ]
    );

    // Listing `about` first fixes it.
    let e = files(&format!("const tabs = ['about', '(main)'];\n{TABS}"));
    assert!(e.is_empty(), "{e:?}");
}

// --- configuration ---------------------------------------------------------

fn config(yaml: &str) -> anyhow::Result<Config> {
    Ok(crate::config::Pubspec::parse(yaml)?.config)
}

/// A project whose pubspec carries `extra` (a `fespalier:` section), with the
/// given files under `app_dir`.
fn configured(extra: &str, app_dir: &str, files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        format!("name: demo\n{extra}"),
    )
    .unwrap();
    for (rel, body) in files {
        let p = dir.path().join(app_dir).join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

#[test]
fn config_defaults_and_custom_paths() {
    // The pubspec's name is the one thing a bare pubspec changes: the package DevTools opens
    // the app's files by.
    let demo = Config {
        package: Some("demo".into()),
        ..Config::default()
    };
    assert_eq!(config("name: demo\n").unwrap(), demo);
    assert_eq!(config("").unwrap(), Config::default());
    assert_eq!(config("name: demo\nfespalier:\n").unwrap(), demo);
    assert_eq!(config("fespalier:\n").unwrap().package, None);
    let c = config("name: demo\nfespalier:\n  app_dir: lib/pages/\n").unwrap();
    assert_eq!(
        (c.app_dir.as_str(), c.output.as_str()),
        ("lib/pages", "lib/app.g.dart")
    );
    let c =
        config("fespalier:\n  app_dir: ./lib/pages\n  output: lib/router/routes.g.dart\n").unwrap();
    assert_eq!(
        (c.app_dir.as_str(), c.output.as_str()),
        ("lib/pages", "lib/router/routes.g.dart")
    );
    assert_eq!(c.output_in_lib(), "router/routes.g.dart");
    // Other pubspec keys don't matter.
    let p = crate::config::Pubspec::parse("name: demo\ndependencies:\n  fespalier:\n    path: ../x\nflutter:\n  uses-material-design: true\n").unwrap();
    assert!(p.has_dependency);
    assert_eq!(p.name.as_deref(), Some("demo"));
    assert!(
        !crate::config::Pubspec::parse("name: demo\ndev_dependencies:\n  fespalier: any\n")
            .unwrap()
            .has_dependency
    );
}

#[test]
fn config_errors_are_clear() {
    let e = format!(
        "{:#}",
        config("fespalier:\n  app_dirr: lib/x\n").unwrap_err()
    );
    assert!(e.contains("unknown field `app_dirr`"), "{e}");
    for bad in ["app", "../app", "lib/../app", "/lib/app", "lib", "test/app"] {
        let e = format!(
            "{:#}",
            config(&format!("fespalier:\n  app_dir: {bad}\n")).unwrap_err()
        );
        assert!(
            e.contains("`fespalier.app_dir` must be a path under lib/"),
            "{bad}: {e}"
        );
        let e = format!(
            "{:#}",
            config(&format!("fespalier:\n  output: {bad}\n")).unwrap_err()
        );
        assert!(
            e.contains("`fespalier.output` must be a path under lib/"),
            "{bad}: {e}"
        );
    }
    let e = format!(
        "{:#}",
        config("fespalier:\n  output: lib/routes\n").unwrap_err()
    );
    assert!(e.contains("must be a .dart file"), "{e}");
    // Loading from disk names the file.
    let dir = configured("fespalier:\n  bogus: 1\n", "lib/app", &[]);
    let e = format!("{:#}", Config::load(dir.path()).unwrap_err());
    assert!(
        e.contains("pubspec.yaml") && e.contains("unknown field `bogus`"),
        "{e}"
    );
}

#[test]
fn import_paths_are_relative_to_the_output() {
    let at = |app_dir: &str, output: &str| Config {
        app_dir: app_dir.into(),
        output: output.into(),
        ..Config::default()
    };
    assert_eq!(Config::default().import_path("page.dart"), "app/page.dart");
    assert_eq!(
        at("lib/pages", "lib/router/routes.g.dart").import_path("a/page.dart"),
        "../pages/a/page.dart"
    );
    assert_eq!(
        at("lib/features/app", "lib/features/routes.g.dart").import_path("page.dart"),
        "app/page.dart"
    );
    assert_eq!(
        at("lib/app", "lib/a/b/routes.g.dart").import_path("page.dart"),
        "../../app/page.dart"
    );
    assert_eq!(
        at("lib/app", "lib/app/routes.g.dart").import_path("page.dart"),
        "page.dart"
    );
}

#[test]
fn custom_app_dir_and_output() {
    let dir = configured(
        "fespalier:\n  app_dir: lib/pages\n  output: lib/router/routes.g.dart\n",
        "lib/pages",
        &[
            ("page.dart", HOME),
            (
                "$id/page.dart",
                "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final String id; }",
            ),
        ],
    );
    let o = generate(dir.path(), true).unwrap();
    assert_eq!(o.routes, 2);
    assert!(!dir.path().join("lib/app.g.dart").exists());
    let code = fs::read_to_string(dir.path().join("lib/router/routes.g.dart")).unwrap();
    has(
        &code,
        &[
            "// GENERATED by fespalier from lib/pages/. Do not edit; run `fsp gen`.",
            "/// The file tree under lib/pages/, ready to mount.",
            "import '../pages/page.dart' as _i0;",
            "import '../pages/\\$id/page.dart' as _i1;",
        ],
    );
    assert!(!code.contains("'app/"), "{code}");
    // A second run has nothing to write.
    assert!(!generate(dir.path(), true).unwrap().wrote);
}

#[test]
fn diagnostics_show_the_configured_folder() {
    let dir = configured(
        "fespalier:\n  app_dir: lib/pages\n",
        "lib/pages",
        &[(
            "page.dart",
            "class P extends StatelessWidget { const P({required this.x}); final int x; }",
        )],
    );
    let e = generate(dir.path(), true).unwrap_err().to_string();
    assert!(e.contains("lib/app.g.dart left unchanged"), "{e}");
    let missing = configured("fespalier:\n  app_dir: lib/pages\n", "lib/app", &[]);
    let e = generate(missing.path(), true).unwrap_err().to_string();
    assert!(e.contains("lib/pages not found"), "{e}");
}

#[test]
fn scaffold_honours_app_dir() {
    let dir = configured(
        "fespalier:\n  app_dir: lib/pages\n  output: lib/router.g.dart\n",
        "lib/pages",
        &[("page.dart", HOME)],
    );
    let args = scaffold::NewArgs {
        route: "docs/[slug]".into(),
        name: None,
        function: false,
        not_found: false,
        data: false,
        action: false,
        loading: false,
        error: false,
        layout: true,
        guard: false,
        transition: false,
        observe: false,
    };
    scaffold::new_route(dir.path(), &args).unwrap();
    assert!(dir.path().join("lib/pages/docs/$slug/page.dart").exists());
    assert!(dir.path().join("lib/pages/docs/$slug/layout.dart").exists());
    assert!(!dir.path().join("lib/app").exists());
    generate(dir.path(), true).expect("scaffolded route should check cleanly");
    let code = fs::read_to_string(dir.path().join("lib/router.g.dart")).unwrap();
    has(
        &code,
        &["import 'pages/docs/\\$slug/page.dart'", "from lib/pages/."],
    );
}

// --- init ------------------------------------------------------------------

#[test]
fn init_creates_starters_that_pass_gen() {
    let dir = configured("", "lib", &[]);
    init::run(dir.path()).unwrap();
    for f in ["layout", "page", "not_found", "transition"] {
        assert!(dir.path().join(format!("lib/app/{f}.dart")).exists(), "{f}");
    }
    let layout = fs::read_to_string(dir.path().join("lib/app/layout.dart")).unwrap();
    assert!(
        layout.contains("const AppLayout({super.key, required this.child});"),
        "{layout}"
    );
    assert!(
        layout.contains(
            "Scaffold(\n    body: SafeArea(\n      child: Material(type: MaterialType.transparency, child: child),"
        ),
        "{layout}"
    );
    let page = fs::read_to_string(dir.path().join("lib/app/page.dart")).unwrap();
    assert!(
        page.contains("class HomePage")
            && page.contains("Center(child: Text('Hello from fespalier'))"),
        "{page}"
    );
    let nf = fs::read_to_string(dir.path().join("lib/app/not_found.dart")).unwrap();
    assert!(
        nf.contains("const NotFoundPage({super.key, required this.uri});"),
        "{nf}"
    );
    assert!(nf.contains("'Nothing at ${uri.path}'"), "{nf}");
    let tr = fs::read_to_string(dir.path().join("lib/app/transition.dart")).unwrap();
    assert!(
        tr.contains("Page<void> transition(LocalKey key, Widget child) =>"),
        "{tr}"
    );
    assert!(tr.contains("Transitions.material(key, child)"), "{tr}");

    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(
        &code,
        &[
            "_i2.AppLayout(child: child)",
            "const _i0.HomePage()",
            "_i3.NotFoundPage(uri: uri)",
            "_i1.transition(",
        ],
    );
    // And the result is stable under check.
    assert!(!generate(dir.path(), false).unwrap().wrote);
}

#[test]
fn init_skips_existing_files_and_honours_config() {
    let dir = configured(
        "fespalier:\n  app_dir: lib/pages\n  output: lib/router/routes.g.dart\n",
        "lib/pages",
        &[("page.dart", HOME)],
    );
    init::run(dir.path()).unwrap();
    // The existing page is untouched.
    assert_eq!(
        fs::read_to_string(dir.path().join("lib/pages/page.dart")).unwrap(),
        HOME
    );
    assert!(dir.path().join("lib/pages/layout.dart").exists());
    assert!(dir.path().join("lib/pages/not_found.dart").exists());
    assert!(dir.path().join("lib/pages/transition.dart").exists());
    assert!(!dir.path().join("lib/app").exists());
    let code = fs::read_to_string(dir.path().join("lib/router/routes.g.dart")).unwrap();
    has(
        &code,
        &[
            "import '../pages/layout.dart'",
            "import '../pages/page.dart'",
            "import '../pages/not_found.dart'",
        ],
    );
    // Running again changes nothing.
    init::run(dir.path()).unwrap();
}

#[test]
fn init_needs_a_pubspec_with_a_name() {
    let empty = tempfile::tempdir().unwrap();
    let e = init::run(empty.path()).unwrap_err().to_string();
    assert!(e.contains("no pubspec.yaml"), "{e}");
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "description: x\n").unwrap();
    assert!(
        init::run(dir.path())
            .unwrap_err()
            .to_string()
            .contains("no `name:`")
    );
}

// ---- guards and redirects ----

const NOOP_GUARD: &str = "GuardResult guard(ProviderContainer c) => null;";
const REF_GUARD: &str = "GuardResult guard(Ref ref) => null;";

/// How many routes call a guard.
fn guard_calls(code: &str) -> usize {
    code.matches(".guard(ProviderScope").count()
}

/// The `_iN` prefix the generated code gives a file, e.g. `imp(&c, "old/guard.dart")`.
fn imp(code: &str, file: &str) -> String {
    let needle = format!("'app/{}' as ", file.replace('$', "\\$"));
    let i = at(code, &needle) + needle.len();
    code[i..].split(';').next().unwrap().to_string()
}

#[test]
fn a_guard_in_a_page_less_folder_guards_every_route_below_it() {
    let c = code(&[
        ("admin/guard.dart", NOOP_GUARD),
        ("admin/users/page.dart", &page("Users")),
        ("admin/reports/page.dart", &page("Reports")),
        ("admin/reports/$id/page.dart", &page("Report")),
        ("open/page.dart", &page("Open")),
    ]);
    // /admin/users and /admin/reports each start with it; /admin/reports/:id is
    // nested in /admin/reports, so it goes through its parent's redirect once.
    assert_eq!(guard_calls(&c), 2, "{c}");
    has(
        &c,
        &[
            "path: joinLocation(at, '/admin/users'),",
            "path: joinLocation(at, '/admin/reports'),",
        ],
    );
    let users = at(&c, "'/admin/users'");
    let open = at(&c, "'/open'");
    assert!(c[users..open].contains(".guard(ProviderScope"), "{c}");
    assert!(!c[open..].contains(".guard("), "{c}");
    // A page-less folder has no route of its own, so there is nothing to nest under.
    assert!(!c.contains("path: joinLocation(at, '/admin')"), "{c}");
}

#[test]
fn a_root_guard_covers_the_whole_app() {
    let c = code(&[
        ("guard.dart", NOOP_GUARD),
        ("a/page.dart", &page("A")),
        ("(g)/b/page.dart", &page("B")),
    ]);
    assert_eq!(guard_calls(&c), 2, "{c}");

    // With a root page, everything else nests inside it and shares its redirect.
    let c = code(&[
        ("guard.dart", NOOP_GUARD),
        ("page.dart", HOME),
        ("a/page.dart", &page("A")),
    ]);
    assert_eq!(guard_calls(&c), 1, "{c}");
}

#[test]
fn guards_run_outermost_first() {
    let c = code(&[
        (
            "(members)/guard.dart",
            "GuardResult guard(ProviderContainer c) => null; // members",
        ),
        (
            "(members)/team/guard.dart",
            "GuardResult guard(ProviderContainer c) => null; // team",
        ),
        (
            "(members)/team/lead/guard.dart",
            "GuardResult guard(ProviderContainer c) => null; // lead",
        ),
        ("(members)/team/lead/page.dart", &page("Lead")),
    ]);
    let first = at(&c, "redirect: (context, state) => firstRedirect([");
    let call = |file: &str| at(&c[first..], &format!("{}.guard(", imp(&c, file)));
    let (group, team, lead) = (
        call("(members)/guard.dart"),
        call("(members)/team/guard.dart"),
        call("(members)/team/lead/guard.dart"),
    );
    assert!(group < team && team < lead, "{c}");
    assert_eq!(c.matches("firstRedirect(").count(), 1, "{c}");
}

#[test]
fn a_folders_own_guard_and_page_keep_todays_output_plus_inherited_ones() {
    // Alone: the same single redirect as before.
    let alone = code(&[
        ("shop/guard.dart", NOOP_GUARD),
        ("shop/page.dart", &page("Shop")),
    ]);
    let g = imp(&alone, "shop/guard.dart");
    has(
        &alone,
        &[&format!(
            "redirect: (context, state) => traceGuard(state, 'g1@1', {g}.guard(ProviderScope.containerOf(context, listen: false))),"
        )],
    );
    assert!(!alone.contains("firstRedirect"), "{alone}");

    // With a guard above: inherited first, its own last.
    let both = code(&[
        ("guard.dart", NOOP_GUARD),
        ("shop/guard.dart", NOOP_GUARD),
        ("shop/page.dart", &page("Shop")),
        ("shop/cart/page.dart", &page("Cart")),
    ]);
    // The root has no page, so /shop carries both; /shop/cart nests inside it.
    assert_eq!(guard_calls(&both), 2, "{both}");
    let (root, own) = (imp(&both, "guard.dart"), imp(&both, "shop/guard.dart"));
    assert!(
        at(&both, &format!("{root}.guard(")) < at(&both, &format!("{own}.guard(")),
        "{both}"
    );
    assert_eq!(both.matches("firstRedirect(").count(), 1, "{both}");
}

#[test]
fn inherited_guards_read_segments_at_their_folder_and_query_by_name() {
    let c = code(&[
        (
            "$shop/guard.dart",
            "GuardResult guard(ProviderContainer c, {required String shop, String? ref, Uri? uri}) => null;",
        ),
        (
            "$shop/items/$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "$shop/items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
        ),
    ]);
    has(
        &c,
        &[
            // Its own parse function: only what the guard asks for.
            "({String shop, String? ref}) _guard1(GoRouterState s) => (shop: Segment.asString(s, 'shop'), ref: Query.asString(s, 'ref'));",
            "redirect: (context, state) => traceGuard(state, 'g1@3', guardWithParams(\n          () => _guard1(state),\n          (v) => _i0.guard(ProviderScope.containerOf(context, listen: false), shop: v.shop, ref: v.ref, uri: state.uri),",
        ],
    );
    // `?ref` belongs to the guard: it doesn't become a field of the routes below.
    assert!(!c.contains("this.ref"), "{c}");
    assert!(
        c.contains("const ItemRoute({required this.shop, required this.id});"),
        "{c}"
    );
}

#[test]
fn a_guard_can_take_only_the_uri() {
    let c = code(&[
        (
            "guard.dart",
            "GuardResult guard(ProviderContainer c, {required Uri uri}) => null;",
        ),
        ("a/page.dart", &page("A")),
    ]);
    has(
        &c,
        &[
            "redirect: (context, state) => traceGuard(state, 'g0@1', _i0.guard(ProviderScope.containerOf(context, listen: false), uri: state.uri)),",
        ],
    );
    assert!(!c.contains("_guard0"), "{c}");
}

#[test]
fn a_guard_that_takes_a_ref_runs_through_ref_guard() {
    let c = code(&[
        (
            "guard.dart",
            "GuardResult guard(Ref ref, {required Uri uri}) => null;",
        ),
        ("a/page.dart", &page("A")),
    ]);
    let g = imp(&c, "guard.dart");
    // The site is a const string: the guard's route, then the route it runs on.
    has(
        &c,
        &[&format!(
            "redirect: (context, state) => traceGuard(state, 'g0@1', refGuard(context, 'g0@1', (ref) => {g}.guard(ref, uri: state.uri))),"
        )],
    );
    assert!(!c.contains("containerOf"), "{c}");
    assert!(!c.contains("_guard0"), "{c}");
}

#[test]
fn a_ref_guard_gets_its_segments_in_the_closure() {
    let c = code(&[
        (
            "$shop/guard.dart",
            "Future<String?> guard(Ref r, {required String shop, String? ref, Uri? uri}) async => null;",
        ),
        ("$shop/items/page.dart", &page("Items")),
    ]);
    // A query parameter may be called `ref`: it is a label, the closure's `ref` a variable.
    has(
        &c,
        &[
            "(v) => refGuard(context, 'g1@",
            "(ref) => _i0.guard(ref, shop: v.shop, ref: v.ref, uri: state.uri)",
        ],
    );
}

#[test]
fn ref_and_container_guards_chain_in_order_and_each_keeps_its_own_form() {
    let c = code(&[
        ("(members)/guard.dart", REF_GUARD),
        ("(members)/team/guard.dart", NOOP_GUARD),
        ("(members)/team/page.dart", &page("Team")),
    ]);
    let (outer, own) = (
        imp(&c, "(members)/guard.dart"),
        imp(&c, "(members)/team/guard.dart"),
    );
    has(
        &c,
        &[
            "firstRedirect([",
            &format!(
                "() => traceGuard(state, 'g1@2', refGuard(context, 'g1@2', (ref) => {outer}.guard(ref))),"
            ),
            &format!(
                "() => traceGuard(state, 'g2@2', {own}.guard(ProviderScope.containerOf(context, listen: false))),"
            ),
        ],
    );
    assert!(
        at(&c, &format!("{outer}.guard(ref)")) < at(&c, &format!("{own}.guard(")),
        "{c}"
    );
}

#[test]
fn two_routes_under_one_guard_each_get_a_site() {
    let c = code(&[
        ("(members)/guard.dart", REF_GUARD),
        ("(members)/inbox/page.dart", &page("Inbox")),
        ("(members)/admin/page.dart", &page("Admin")),
    ]);
    // One guard, two routes: two sites, so each keeps its own subscription.
    let sites: Vec<&str> = c
        .match_indices("refGuard(context, '")
        .map(|(i, m)| c[i + m.len()..].split('\'').next().unwrap())
        .collect();
    assert_eq!(sites.len(), 2, "{c}");
    assert_ne!(sites[0], sites[1], "{c}");
    assert!(sites.iter().all(|s| s.starts_with("g1@")), "{sites:?}");
}

#[test]
fn a_ref_guard_is_not_forced_into_a_future() {
    // The return type is the author's: a sync guard stays a sync call.
    for ret in [
        "GuardResult",
        "FutureOr<String?>",
        "Future<String?>",
        "String?",
    ] {
        let body = if ret == "Future<String?>" {
            "async => null"
        } else {
            "=> null"
        };
        let c = code(&[
            ("guard.dart", &format!("{ret} guard(Ref ref) {body};")),
            ("a/page.dart", &page("A")),
        ]);
        assert!(c.contains("(ref) => _i0.guard(ref)"), "{ret}: {c}");
        assert!(!c.contains("async"), "{ret}: {c}");
        assert!(!c.contains("await"), "{ret}: {c}");
    }
}

#[test]
fn a_redirect_that_takes_a_ref_evaluates_once() {
    let c = code(&[
        ("a/redirect.dart", "String redirect(Ref ref) => '/b';"),
        (
            "b/redirect.dart",
            "Future<String> redirect(Ref ref, {required Uri uri}) async => '/a';",
        ),
        (
            "c/$id/redirect.dart",
            "FutureOr<String> redirect(Ref ref, {required int id}) => '/a';",
        ),
    ]);
    has(
        &c,
        &[
            "redirect: (context, state) => traceGuard(state, 'r1', refRedirect(context, (ref) => _i0.redirect(ref))),",
            "redirect: (context, state) => traceGuard(state, 'r2', refRedirect(context, (ref) => _i1.redirect(ref, uri: state.uri))),",
            "(v) => refRedirect(context, (ref) => _i2.redirect(ref, id: v.id)),",
        ],
    );
    // A redirect route never stays on screen, so it has no site to keep.
    assert!(!c.contains("refGuard("), "{c}");
}

#[test]
fn a_redirect_route_chains_a_ref_guard_above_it_and_its_own_ref() {
    let c = code(&[
        ("(members)/guard.dart", REF_GUARD),
        (
            "(members)/old/redirect.dart",
            "String redirect(Ref ref) => '/inbox';",
        ),
        ("(members)/inbox/page.dart", &page("Inbox")),
    ]);
    let old = at(&c, "path: joinLocation(at, '/old')");
    let chain = &c[old..old + c[old..].find("]),\n").unwrap()];
    assert!(
        chain.contains("firstRedirect([")
            && chain.contains("refGuard(context, 'g1@")
            && chain.contains("refRedirect(context, (ref) => "),
        "{chain}"
    );
    assert!(chain.find("refGuard(").unwrap() < chain.find("refRedirect(").unwrap());
}

#[test]
fn a_guard_and_a_redirect_in_one_folder_keep_their_forms() {
    let c = code(&[
        ("old/guard.dart", REF_GUARD),
        ("old/redirect.dart", "String redirect() => '/new';"),
        ("new/page.dart", &page("New")),
    ]);
    has(
        &c,
        &[
            "refGuard(context, 'g2@2', (ref) => _i1.guard(ref))",
            "_i2.redirect()",
        ],
    );
}

#[test]
fn a_hook_that_takes_a_widget_ref_is_told_to_take_a_ref() {
    let joined = diags(&[
        ("a/guard.dart", "GuardResult guard(WidgetRef ref) => null;"),
        ("a/page.dart", &page("A")),
        ("b/redirect.dart", "String redirect(WidgetRef ref) => '/a';"),
    ])
    .join("\n");
    for needle in [
        "a guard runs outside the widget tree: take `Ref`",
        "a redirect runs outside the widget tree: take `Ref`",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
    // Only that message: the parameter is not also read as a segment.
    assert!(!joined.contains("isn't a segment"), "{joined}");
    assert!(!joined.contains("`ref`"), "{joined}");
}

#[test]
fn a_view_file_may_hold_other_public_classes_if_one_is_a_widget() {
    // The README says "one public widget class": a class that isn't a widget beside it is fine,
    // and only an ambiguous file is an error.
    let c = code(&[(
        "a/page.dart",
        "class Helper {}\nclass APage extends StatelessWidget { const APage({super.key}); }",
    )]);
    has(&c, &["_i0.APage("]);
    let e = diags(&[(
        "b/page.dart",
        "class BPage extends StatelessWidget { const BPage({super.key}); }\nclass Other {}\nclass Third {}",
    ), (
        "c/page.dart",
        "class One extends StatelessWidget {}\nclass Two extends StatelessWidget {}",
    )])
    .join("\n");
    assert!(
        e.contains("c/page.dart:2  expected one public widget class, found One, Two; make the others private (`_Name`)"),
        "{e}"
    );
}

#[test]
fn only_a_guard_that_reads_params_is_skipped_for_an_unparsable_segment() {
    // `$id` is an int, so `/items/abc` doesn't parse. A guard that asks for `id` goes through
    // `guardWithParams`, which skips it; one that asks for neither segments nor query is called
    // as it is, so it still runs.
    let c = code(&[
        (
            "items/$id/guard.dart",
            "GuardResult guard(ProviderContainer c, {required Uri uri}) => null;",
        ),
        (
            "items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }",
        ),
        (
            "things/$id/guard.dart",
            "GuardResult guard(ProviderContainer c, {required int id}) => null;",
        ),
        (
            "things/$id/page.dart",
            "class ThingPage extends StatelessWidget { const ThingPage({super.key, required this.id}); final int id; }",
        ),
    ]);
    has(
        &c,
        &[
            "redirect: (context, state) => traceGuard(state, 'g2@2', _i1.guard(ProviderScope.containerOf(context, listen: false), uri: state.uri)),",
            "(v) => _i3.guard(ProviderScope.containerOf(context, listen: false), id: v.id),",
        ],
    );
    assert_eq!(c.matches("guardWithParams(").count(), 1, "{c}");
}

#[test]
fn a_guard_on_a_page_puts_its_query_on_the_typed_route() {
    let c = code(&[
        (
            "search/guard.dart",
            "GuardResult guard(ProviderContainer c, {bool? admin, Uri? uri}) => null;",
        ),
        ("search/page.dart", &page("Search")),
    ]);
    has(
        &c,
        &[
            "(v) => _i1.guard(ProviderScope.containerOf(context, listen: false), admin: v.admin, uri: state.uri),",
            "const SearchRoute({this.admin});",
        ],
    );
}

#[test]
fn inherited_guard_errors() {
    let joined = diags(&[
        // Below its folder there is `$id`, but the guard's folder has no segments.
        (
            "admin/guard.dart",
            "GuardResult guard(ProviderContainer c, {required int id}) => null;",
        ),
        ("admin/$id/page.dart", &page("Admin")),
        // `uri` is a Uri.
        (
            "b/guard.dart",
            "GuardResult guard(ProviderContainer c, {required String uri}) => null;",
        ),
        ("b/page.dart", &page("B")),
        // A `Ref` (or the older container) comes first, and the return type is a GuardResult.
        ("c/guard.dart", "String guard({int? x}) => 'x';"),
        ("c/page.dart", &page("C")),
        ("d/guard.dart", "void other() {}"),
        ("d/page.dart", &page("D")),
        ("e/guard.dart", "GuardResult guard(WidgetRef ref) => null;"),
        ("e/page.dart", &page("E")),
    ])
    .join("\n");
    for needle in [
        "`id` isn't a segment of this path (it has none) at or above its folder; guard() can also take `Uri uri`",
        "`uri` gets the requested Uri, but it's declared String",
        "guard() must take `Ref ref` first (or `ProviderContainer c`, the older form)",
        "expected `GuardResult guard(Ref ref, {...segments})`",
        "a guard runs outside the widget tree: take `Ref`",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn an_inherited_guard_cant_ask_for_a_segment_below_it() {
    let e = diags(&[
        (
            "$shop/guard.dart",
            "GuardResult guard(ProviderContainer c, {required String shop, required int id}) => null;",
        ),
        ("$shop/items/$id/page.dart", &page("Item")),
    ]);
    assert!(
        e.iter()
            .any(|d| d.contains("`id` isn't a segment of this path ($shop)")),
        "{e:?}"
    );
}

#[test]
fn a_guard_types_the_segments_it_reads() {
    let e = diags(&[
        (
            "$id/guard.dart",
            "GuardResult guard(ProviderContainer c, {required int id}) => null;",
        ),
        (
            "$id/x/page.dart",
            "class XPage extends StatelessWidget { const XPage({super.key, required this.id}); final String id; }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|d| d.contains("`$id` is int in $id/guard.dart:1 but String here")),
        "{e:?}"
    );
}

#[test]
fn a_guard_with_nothing_to_guard_is_warned_about() {
    let e = diags(&[("page.dart", HOME), ("lonely/guard.dart", NOOP_GUARD)]);
    assert!(
        e.iter()
            .any(|d| d.contains("lonely/guard.dart") && d.contains("guards no routes")),
        "{e:?}"
    );
    // One warning is enough: not the "folder has no page.dart" one as well.
    assert_eq!(e.len(), 1, "{e:?}");
}

#[test]
fn guards_above_a_tab_layout_cover_every_tab() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/guard.dart", NOOP_GUARD),
        ("(tabs)/search/page.dart", &page("Search")),
        ("(tabs)/profile/page.dart", &page("Profile")),
        ("(tabs)/profile/edit/page.dart", &page("Edit")),
    ]);
    // One per tab's first-level route; /profile/edit nests inside /profile.
    assert_eq!(guard_calls(&c), 2, "{c}");
    assert!(!c.contains("firstRedirect"), "{c}");

    // A guard in the tab layout's own folder, which has a page: it covers the
    // page and the tabs beside it.
    let c = code(&[
        ("layout.dart", TABS),
        ("page.dart", HOME),
        ("guard.dart", NOOP_GUARD),
        ("search/page.dart", &page("Search")),
    ]);
    assert_eq!(guard_calls(&c), 2, "{c}");
}

#[test]
fn a_guard_inside_a_shell_stays_on_the_page_routes() {
    let c = code(&[
        (
            "(members)/layout.dart",
            "class MembersLayout extends StatelessWidget { const MembersLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("(members)/guard.dart", NOOP_GUARD),
        ("(members)/inbox/page.dart", &page("Inbox")),
    ]);
    // No `redirect` on the ShellRoute: go_router would run it, but the GoRoute is where it's explicit.
    let shell = at(&c, "ShellRoute(");
    let route = at(&c, "GoRoute(");
    assert!(!c[shell..route].contains("redirect:"), "{c}");
    assert!(
        c[route..].contains("redirect: (context, state) => traceGuard(state, 'g1@2', _i1.guard("),
        "{c}"
    );
}

// ---- redirect.dart ----

#[test]
fn redirect_dart_makes_a_route_that_only_redirects() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "old/$id/redirect.dart",
            "String redirect({required String id}) => '/new/$id';",
        ),
    ]);
    has(
        &c,
        &[
            "//   /old/:id  OldIdRoute  old/$id/redirect.dart  (redirect)",
            "path: 'old/:id',",
            "redirect: (context, state) => traceGuard(state, 'r2', guardWithParams(",
            "(v) => _i1.redirect(id: v.id),",
            // A typed route, so links to the old URL stay typed.
            "/// `/old/:id` → old/$id/redirect.dart\nfinal class OldIdRoute extends TypedLocation {",
            "const OldIdRoute({required this.id});",
            "String get location => joinLocation(AppRoutes.base, '/old/${Uri.encodeComponent(id)}');",
        ],
    );
    // A String segment always parses, so the route has no page and no builder at all.
    let route = at(&c, "path: 'old/:id'");
    let end = route + c[route..].find("),\n").unwrap();
    assert!(!c[route..end].contains("builder"), "{c}");
}

#[test]
fn a_redirect_with_a_typed_segment_shows_not_found_when_it_does_not_parse() {
    let c = code(&[(
        "old/$id/redirect.dart",
        "String redirect({required int id, String? tab}) => '/new/$id';",
    )]);
    has(
        &c,
        &[
            "(v) => _i0.redirect(id: v.id, tab: v.tab),",
            "builder: (context, state) => notFound(state.uri),",
            "const OldIdRoute({required this.id, this.tab});",
            "final int id;",
            "withQuery(joinLocation(AppRoutes.base, '/old/$id'), {'tab': tab})",
        ],
    );
}

#[test]
fn a_redirect_takes_an_optional_container_and_the_uri() {
    let c = code(&[
        ("a/redirect.dart", "String redirect() => '/b';"),
        (
            "b/redirect.dart",
            "Future<String> redirect(ProviderContainer c, {required Uri uri}) async => '/a';",
        ),
    ]);
    has(
        &c,
        &[
            "redirect: (context, state) => traceGuard(state, 'r1', _i0.redirect()),",
            "redirect: (context, state) => traceGuard(state, 'r2', _i1.redirect(ProviderScope.containerOf(context, listen: false), uri: state.uri)),",
        ],
    );
}

#[test]
fn a_redirect_route_starts_with_the_guards_above_it() {
    let c = code(&[
        ("(members)/guard.dart", NOOP_GUARD),
        (
            "(members)/old/redirect.dart",
            "String redirect() => '/inbox';",
        ),
        ("(members)/inbox/page.dart", &page("Inbox")),
    ]);
    let old = at(&c, "path: joinLocation(at, '/old')");
    let chain = &c[old..old + c[old..].find("]),\n").unwrap()];
    let (g, r) = (
        imp(&c, "(members)/guard.dart"),
        imp(&c, "(members)/old/redirect.dart"),
    );
    let (g, r) = (format!("{g}.guard("), format!("{r}.redirect("));
    assert!(
        chain.contains("firstRedirect([") && chain.contains(&g) && chain.contains(&r),
        "{c}"
    );
    assert!(chain.find(&g) < chain.find(&r), "{c}");
}

#[test]
fn a_folder_with_a_guard_and_a_redirect_runs_the_guard_first() {
    let c = code(&[
        ("old/guard.dart", NOOP_GUARD),
        ("old/redirect.dart", "String redirect() => '/new';"),
        ("new/page.dart", &page("New")),
    ]);
    let old = at(&c, "'/old'");
    let (g, r) = (imp(&c, "old/guard.dart"), imp(&c, "old/redirect.dart"));
    assert!(
        c[old..].find(&format!("{g}.guard(")) < c[old..].find(&format!("{r}.redirect(")),
        "{c}"
    );
    assert_eq!(c.matches("firstRedirect(").count(), 1, "{c}");
}

#[test]
fn routes_below_a_redirect_are_beside_it_not_inside() {
    let c = code(&[
        ("old/redirect.dart", "String redirect() => '/new';"),
        ("old/deep/page.dart", &page("Deep")),
        (
            "old/$id/redirect.dart",
            "String redirect({required String id}) => '/new/$id';",
        ),
    ]);
    // A redirect always redirects, so anything nested in it could never be reached.
    has(
        &c,
        &[
            "path: joinLocation(at, '/old'),",
            "path: joinLocation(at, '/old/deep'),",
            "path: joinLocation(at, '/old/:id'),",
        ],
    );
    assert!(
        at(&c, "'/old/deep'") < at(&c, "'/old/:id'"),
        "static before dynamic:\n{c}"
    );
}

#[test]
fn redirect_dart_takes_part_in_route_order_checks() {
    // `(g)/settings` can't be sorted around the root `$slug` page.
    let e = diags(&[
        ("$slug/page.dart", &page("Slug")),
        (
            "(g)/layout.dart",
            "class GLayout extends StatelessWidget { const GLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("(g)/settings/redirect.dart", "String redirect() => '/';"),
        ("(g)/$other/page.dart", &page("Other")),
    ]);
    assert!(
        e.iter()
            .any(|d| d.contains("/settings is unreachable")
                && d.contains("(g)/settings/redirect.dart")),
        "{e:?}"
    );

    let e = diags(&[
        ("a/page.dart", &page("A")),
        ("(g)/a/redirect.dart", "String redirect() => '/';"),
        ("x/page.dart", &page("Old")),
        ("y/redirect.dart", "String redirect() => '/';"),
        ("old/page.dart", &page("Old")),
    ]);
    let joined = e.join("\n");
    assert!(
        joined.contains("/a is served by both (g)/a/redirect.dart and a/page.dart"),
        "{joined}"
    );
}

#[test]
fn a_redirect_route_is_named_after_its_path() {
    let e = diags(&[
        ("old/redirect.dart", "String redirect() => '/';"),
        (
            "x/page.dart",
            "class OldPage extends StatelessWidget { const OldPage({super.key}); }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|d| d.contains("route name `OldRoute` is already taken by")),
        "{e:?}"
    );

    let c = code(&[
        ("redirect.dart", "String redirect() => '/home';"),
        ("home/page.dart", &page("Home")),
        ("2024/redirect.dart", "String redirect() => '/home';"),
        (
            "(g)/see-you/$name/redirect.dart",
            "String redirect({required String name}) => '/home';",
        ),
    ]);
    has(
        &c,
        &[
            "final class RootRoute extends",
            "final class Path2024Route extends",
            "final class SeeYouNameRoute extends",
        ],
    );
}

#[test]
fn redirect_dart_errors() {
    let joined = diags(&[
        // Either a page or a redirect.
        ("a/page.dart", &page("A")),
        ("a/redirect.dart", "String redirect() => '/';"),
        // The function and its return type.
        ("b/redirect.dart", "void nothing() {}"),
        ("c/redirect.dart", "int redirect() => 1;"),
        // Parameters: segments of this path, optional query, uri.
        (
            "$d/redirect.dart",
            "String redirect({required int nope}) => '/';",
        ),
        (
            "e/redirect.dart",
            "String redirect(String positional) => '/';",
        ),
        (
            "f/redirect.dart",
            "String redirect({required Uri uri, required String other}) => '/';",
        ),
        (
            "g/redirect.dart",
            "String redirect({required String uri}) => '/';",
        ),
        // data.dart has no page to feed here either.
        ("h/redirect.dart", "String redirect() => '/';"),
        ("h/data.dart", "Future<int> data(Ref ref) async => 1;"),
    ])
    .join("\n");
    for needle in [
        "a/redirect.dart  a folder has a page.dart or a redirect.dart, not both",
        "b/redirect.dart  expected `String redirect({...segments})`",
        "redirect() must return the location to go to: a String",
        "`nope` isn't a segment of this path ($d) at or above its folder; redirect() can also take `Uri uri`",
        "redirect() takes segments as named parameters",
        "`other` isn't a segment of this path (it has none)",
        "`uri` gets the requested Uri, but it's declared String",
        "h/data.dart  data.dart has no page.dart to feed",
    ] {
        assert!(joined.contains(needle), "missing `{needle}` in:\n{joined}");
    }
}

#[test]
fn a_tab_layout_folder_cant_hold_a_redirect() {
    let e = diags(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/redirect.dart", "String redirect() => '/search';"),
        ("(tabs)/search/page.dart", &page("Search")),
        ("(tabs)/home/page.dart", &page("Home")),
    ]);
    assert!(
        e.iter()
            .any(|d| d.contains("a tab layout folder can't hold a redirect.dart")),
        "{e:?}"
    );
}

#[test]
fn redirect_routes_are_routes_in_the_count_and_the_table() {
    let dir = project(&[
        ("page.dart", HOME),
        ("old/redirect.dart", "String redirect() => '/';"),
    ]);
    let (code, diags, routes) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    assert_eq!(routes, 2);
    has(
        &code,
        &[
            "//   /     HomeRoute  page.dart",
            "//   /old  OldRoute   old/redirect.dart  (redirect)",
        ],
    );
}

#[test]
fn a_redirect_inside_a_tab_keeps_the_tab_shape() {
    let c = code(&[
        ("(tabs)/layout.dart", TABS),
        ("(tabs)/search/page.dart", &page("Search")),
        (
            "(tabs)/find/redirect.dart",
            "String redirect() => '/search';",
        ),
    ]);
    assert_eq!(c.matches("StatefulShellBranch(").count(), 2, "{c}");
}

#[test]
fn static_routes_sort_before_dynamic_ones_below_a_folded_folder() {
    // `shops` has no page, so its children's paths are `shops/:id` and `shops/new`.
    let c = code(&[
        ("shops/$id/page.dart", &page("Shop")),
        ("shops/new/page.dart", &page("New")),
    ]);
    assert!(at(&c, "'/shops/new'") < at(&c, "'/shops/:id'"), "{c}");
}
