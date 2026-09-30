use std::fs;
use std::path::{Path, PathBuf};

use crate::{build, gen, scaffold};

fn example() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples/shop")
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

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app")).unwrap();
    diags.0.iter().map(|d| d.to_string()).collect()
}

const HOME: &str = "class HomePage extends Screen<Params> { const HomePage(super.data); }";

#[test]
fn example_app_generates_cleanly() {
    let (code, diags, routes) = build(&example().join("lib/app")).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    assert_eq!(routes, 6);
    for needle in [
        "final class ProductRoute extends TypedLocation {",
        "const ProductRoute({required this.id});",
        "_i", // prefixed imports
        "import 'app/products/\\$id/page.dart'",
        "path: ':id'",
        "path: 'greet/:name'",
        "path: joinLocation(at, '/')",
        "ShellRoute(",
        "Segment.asInt(s, 'id')",
        "class GreetParams extends Params {",
        "Future<void> refresh(WidgetRef ref)",
        "redirect: (context, state) => guardWithParams(",
        "FutureProvider.autoDispose.family(",
    ] {
        assert!(code.contains(needle), "missing `{needle}` in:\n{code}");
    }
}

#[test]
fn committed_output_is_up_to_date() {
    let (code, _, _) = build(&example().join("lib/app")).unwrap();
    let committed = fs::read_to_string(example().join("lib/app.g.dart")).unwrap_or_default();
    assert!(committed == code, "examples/shop/lib/app.g.dart is stale; run `trellis gen --project examples/shop`");
}

#[test]
fn page_type_must_match_data() {
    let e = errors(&[
        ("page.dart", HOME),
        ("products/data.dart", "Future<List<Product>> data(Ref ref, Params p) async => [];"),
        ("products/page.dart", "class ProductsPage extends Screen<Product> {}"),
    ]);
    assert_eq!(e, vec!["✗ products/page.dart:1  Screen<Product> but data.dart yields List<Product>"]);
}

#[test]
fn page_without_data_receives_params() {
    let e = errors(&[
        ("$id/params.dart", "class ItemParams extends Params { final int id; }"),
        ("$id/page.dart", "class ItemPage extends Screen<String> {}"),
    ]);
    assert_eq!(e, vec!["✗ $id/page.dart:1  Screen<String> but there is no data.dart, so this page receives ItemParams"]);
}

#[test]
fn params_must_cover_every_segment() {
    let e = errors(&[
        ("$shop/$id/params.dart", "class ItemParams extends Params {\n  final int id;\n  final int extra;\n}"),
        ("$shop/$id/page.dart", "class ItemPage extends Screen<ItemParams> {}"),
    ]);
    // $shop gets a generated ShopParams (no page there, so named from the path).
    assert!(e.iter().any(|m| m.contains("ItemParams must extend ShopParams")), "{e:?}");
    assert!(e.iter().any(|m| m.contains("field `extra` has no `$extra` segment")), "{e:?}");
}

#[test]
fn inherited_loading_must_accept_child_params() {
    let e = errors(&[
        ("loading.dart", "class L extends Loading<HomeParams> {}"),
        ("$id/params.dart", "class ItemParams extends Params { final int id; }"),
        ("$id/data.dart", "Future<int> data(Ref ref, ItemParams p) async => 1;"),
        ("$id/page.dart", "class ItemPage extends Screen<int> {}"),
    ]);
    assert_eq!(e, vec!["✗ loading.dart  loading view takes HomeParams, but it also covers $id/ whose params are ItemParams"]);
}

#[test]
fn data_signature_is_checked() {
    let e = errors(&[
        ("data.dart", "data(ref, {required Params p}) => 1;"),
        ("page.dart", HOME),
    ]);
    assert!(e.iter().any(|m| m.contains("data() must take exactly (Ref ref, Params params)")), "{e:?}");
    assert!(e.iter().any(|m| m.contains("explicit return type")), "{e:?}");
}

#[test]
fn stream_data_uses_stream_provider() {
    let dir = project(&[
        ("data.dart", "Stream<int> data(Ref ref, Params p) => Stream.value(1);"),
        ("page.dart", "class TickPage extends Screen<int> {}"),
    ]);
    let (code, diags, _) = build(&dir.path().join("lib/app")).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    assert!(code.contains("StreamProvider.autoDispose.family("));
    assert!(code.contains("/// Restarts ./data.dart"));
}

#[test]
fn misc_rules() {
    let e = errors(&[
        ("page.dart", HOME),
        ("a/guard.dart", "GuardResult guard(ProviderContainer c, Params p) => null;"),
        ("b/not_found.dart", "class N extends NotFoundView {}"),
        ("c/page.dart", "class HomeScreen extends Screen<Params> {}"),
        ("Bad Name/page.dart", HOME),
    ]);
    let joined = e.join("\n");
    assert!(joined.contains("a/guard.dart  guard.dart needs a page.dart"), "{joined}");
    assert!(joined.contains("b/not_found.dart  not_found.dart only works at the root"), "{joined}");
    assert!(joined.contains("route name `HomeRoute` is already taken by page.dart"), "{joined}");
    assert!(joined.contains("`Bad Name` is not a valid URL segment"), "{joined}");
}

#[test]
fn errors_leave_output_untouched() {
    let dir = project(&[("page.dart", "class P extends Screen<Nope> {}")]);
    assert!(gen(dir.path(), true).is_err());
    assert!(!dir.path().join("lib/app.g.dart").exists());
}

#[test]
fn scaffold_then_generate() {
    let dir = project(&[("page.dart", HOME)]);
    let args = |route: &str, data: bool| scaffold::NewArgs {
        route: route.into(),
        name: Some("Order".into()),
        data,
        loading: true,
        error: true,
        layout: false,
        guard: true,
    };
    scaffold::new_route(dir.path(), &args("orders/[orderId]", true)).unwrap();
    let params = fs::read_to_string(dir.path().join("lib/app/orders/$orderId/params.dart")).unwrap();
    assert!(params.contains("class OrderParams extends Params {"), "{params}");
    gen(dir.path(), true).expect("scaffolded route should check cleanly");

    // A nested route under it inherits OrderParams through a package import.
    let mut nested = args("orders/:orderId/items/:itemId", false);
    nested.name = Some("Item".into());
    scaffold::new_route(dir.path(), &nested).unwrap();
    let p = fs::read_to_string(dir.path().join("lib/app/orders/$orderId/items/$itemId/params.dart")).unwrap();
    assert!(p.contains("import 'package:demo/app/orders/\\$orderId/params.dart';"), "{p}");
    assert!(p.contains("ItemParams({required super.orderId, required this.itemId})"), "{p}");
    gen(dir.path(), true).expect("nested scaffold should check cleanly");
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(code.contains("const ItemRoute({required this.orderId, required this.itemId});"), "{code}");
}
