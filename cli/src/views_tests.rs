//! View files written as functions (`Widget page(...)`), and the two spellings of
//! a multi-word file kind (`not_found.dart` / `not-found.dart`).

use std::fs;

use crate::config::Config;
use crate::scaffold::{self, NewArgs};
use crate::{build, init};

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
    configured("", files)
}

fn configured(fespalier: &str, files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), format!("name: demo\n{fespalier}")).unwrap();
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

fn class(name: &str) -> String {
    format!("class {name} extends StatelessWidget {{ const {name}({{super.key}}); }}")
}

// --- function views ------------------------------------------------------------------

#[test]
fn a_page_function_is_bound_like_a_constructor() {
    let c = code(&[
        ("page.dart", HOME),
        ("orders/$orderId/data.dart", "Future<Order> data(Ref ref, {required String orderId}) async => throw 1;"),
        (
            "orders/$orderId/page.dart",
            "Widget page({required String orderId, required Order order, int? tab}) => Text('$orderId');",
        ),
    ]);
    // Segment by name, query by name, the data by type: the same rules as a constructor.
    has(
        &c,
        &["_i", ".page(orderId: v.orderId, order: d, tab: v.tab)", "final class OrdersOrderIdRoute extends TypedLocation"],
    );
}

#[test]
fn a_page_function_takes_positional_parameters_and_data_by_name() {
    let c = code(&[
        ("page.dart", HOME),
        ("$id/data.dart", "Future<String> data(Ref ref, {required int id}) async => '';"),
        ("$id/page.dart", "Widget page(int id, String data) => Text(data);"),
    ]);
    has(&c, &[".page(v.id, d)"]);
}

#[test]
fn binding_errors_point_at_the_function_parameter() {
    let e = diags(&[("page.dart", HOME), ("a/page.dart", "Widget page({required int nope}) => Text('');")]);
    assert_eq!(e, vec!["✗ a/page.dart:1  can't fill `nope`: it isn't a segment of this path (it has none) or a query parameter (optional and nullable)"]);
    // Hooks and ref live in the widget the function returns.
    let e = diags(&[("page.dart", "Widget page(WidgetRef ref) => Text('');")]);
    assert!(e.len() == 1 && e[0].contains("can't fill `ref`") && e[0].contains("put hooks and `ref` in the widget it returns"), "{e:?}");
    let e = diags(&[("page.dart", "Widget page(BuildContext context) => Text('');")]);
    assert!(e.len() == 1 && e[0].contains("can't fill `context`") && e[0].contains("BuildContext"), "{e:?}");
}

#[test]
fn a_page_function_must_return_a_widget() {
    let e = diags(&[("page.dart", "void page() {}")]);
    assert_eq!(e, vec!["✗ page.dart:1  `page()` must return a Widget, not void"]);
    let e = diags(&[("page.dart", "Future<Widget> page() async => Text('');")]);
    assert!(e.len() == 1 && e[0].contains("must return a Widget"), "{e:?}");
    // A specific widget type, or nothing written, is fine.
    code(&[("page.dart", "Text page() => const Text('');")]);
    code(&[("page.dart", "page() => const Text('');")]);
}

#[test]
fn data_that_the_function_ignores_is_warned_about() {
    let e = diags(&[
        ("page.dart", HOME),
        ("a/data.dart", "Future<String> data(Ref ref) async => '';"),
        ("a/page.dart", "Widget page() => Text('');"),
    ]);
    assert_eq!(e, vec!["! a/page.dart:1  page() doesn't take what data.dart yields; add a `String data` parameter"]);
}

#[test]
fn layout_loading_error_and_not_found_can_be_functions() {
    let c = code(&[
        ("layout.dart", "Widget layout({required Widget child}) => child;"),
        ("page.dart", HOME),
        ("not_found.dart", "Widget notFound({required Uri uri}) => Text('$uri');"),
        ("items/$id/data.dart", "Future<int> data(Ref ref, {required int id}) async => id;"),
        ("items/$id/page.dart", "Widget page({required int id, required int data}) => Text('$id');"),
        ("items/$id/loading.dart", "Widget loading({required int id}) => Text('$id');"),
        ("items/$id/error.dart", "Widget error({required Object error, required VoidCallback retry}) => Text('$error');"),
    ]);
    has(&c, &[".layout(child: child)", ".notFound(uri: uri)", ".loading(id: v.id)", ".error(error: e, retry: retry)", ".page(id: v.id, data: d)"]);
    // The snake_case spelling of the not-found function is accepted too.
    let c = code(&[("page.dart", HOME), ("not_found.dart", "Widget not_found(Uri uri) => Text('$uri');")]);
    has(&c, &[".not_found(uri)"]);
}

#[test]
fn a_tab_layout_can_be_a_function() {
    let c = code(&[
        ("(tabs)/layout.dart", "const tabs = ['a', 'b'];\nWidget layout({required StatefulNavigationShell shell}) => shell;"),
        ("(tabs)/a/page.dart", "Widget page() => Text('a');"),
        ("(tabs)/b/page.dart", "Widget page() => Text('b');"),
    ]);
    has(&c, &["StatefulShellRoute", ".layout(shell: navigationShell)"]);
}

#[test]
fn a_class_and_a_function_in_one_file_is_an_error_naming_both() {
    let e = diags(&[("page.dart", &format!("{}\nWidget page() => const HomePage();", class("HomePage")))]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ page.dart:2") && e[0].contains("HomePage") && e[0].contains("`page()`"), "{e:?}");
    // A private class, or one that isn't a widget, is just a helper.
    code(&[("page.dart", "class _Helper extends StatelessWidget { const _Helper(); }\nWidget page() => const _Helper();")]);
    code(&[("page.dart", "class Options {}\nWidget page() => Text('');")]);
    // Other public functions are helpers too.
    code(&[("page.dart", "String title() => 'x';\nWidget page() => Text(title());")]);
}

#[test]
fn a_file_with_neither_is_still_an_error() {
    assert_eq!(diags(&[("page.dart", "String title() => 'x';")]), vec!["✗ page.dart  expected a public widget class"]);
}

#[test]
fn both_spellings_of_a_functions_name_are_an_error() {
    let e = diags(&[("page.dart", HOME), ("not_found.dart", "Widget notFound(Uri uri) => Text('');\nWidget not_found(Uri uri) => Text('');")]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("both `notFound()` and `not_found()`"), "{e:?}");
}

// --- route names ---------------------------------------------------------------------

#[test]
fn a_function_route_is_named_after_its_folder_ignoring_groups() {
    let c = code(&[
        ("page.dart", HOME),
        ("(kyc)/shop/name/page.dart", "Widget page() => const Text('shop');"),
        ("(kyc)/person/name/page.dart", "Widget page() => const Text('person');"),
        ("orders/$orderId/cancel/page.dart", "Widget page({required String orderId}) => Text(orderId);"),
        ("old-things/page.dart", "Widget page() => const Text('x');"),
    ]);
    has(
        &c,
        &[
            "final class ShopNameRoute extends TypedLocation",
            "final class PersonNameRoute extends TypedLocation",
            "final class OrdersOrderIdCancelRoute extends TypedLocation",
            "final class OldThingsRoute extends TypedLocation",
        ],
    );
}

#[test]
fn route_name_overrides_the_folder_name() {
    let c = code(&[
        ("page.dart", HOME),
        ("(kyc)/shop/name/page.dart", "const routeName = 'KycShopName';\nWidget page() => const Text('shop');"),
        // It works for a class too.
        ("cart/page.dart", &format!("const routeName = 'Basket';\n{}", class("CartPage"))),
    ]);
    has(&c, &["final class KycShopNameRoute extends TypedLocation", "final class BasketRoute extends TypedLocation"]);
    assert!(!c.contains(" ShopNameRoute extends"), "{c}");
    assert!(!c.contains("CartRoute"), "{c}");
}

#[test]
fn colliding_route_names_suggest_route_name() {
    // Two different URLs, one name: `/x/y` and `/x-y` are both `XY`.
    let e = diags(&[
        ("page.dart", HOME),
        ("x/y/page.dart", "Widget page() => const Text('1');"),
        ("x-y/page.dart", "Widget page() => const Text('2');"),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].starts_with("✗ x-y/page.dart:1  route name `XYRoute` is already taken by x/y/page.dart; give one a different name with `const routeName = 'Name';` in x-y/page.dart"),
        "{e:?}"
    );
    // routeName settles it.
    code(&[
        ("page.dart", HOME),
        ("x/y/page.dart", "Widget page() => const Text('1');"),
        ("x-y/page.dart", "const routeName = 'DashedXY';\nWidget page() => const Text('2');"),
    ]);
    // A function route can clash with a class route as well.
    let e = diags(&[("page.dart", HOME), ("home/page.dart", "Widget page() => const Text('1');")]);
    assert!(e.len() == 1 && e[0].contains("route name `HomeRoute` is already taken by page.dart"), "{e:?}");
    let e = diags(&[("page.dart", HOME), ("a/page.dart", "const routeName = 'Home';\nWidget page() => const Text('1');")]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("route name `HomeRoute` is already taken by page.dart; change its `routeName`"), "{e:?}");
}

#[test]
fn route_name_must_be_a_usable_name() {
    let e = diags(&[("page.dart", "const routeName = 'kyc';\nWidget page() => const Text('1');")]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ page.dart:1") && e[0].contains("UpperCamelCase"), "{e:?}");
    let e = diags(&[("page.dart", "const routeName = 'My-Name';\nWidget page() => const Text('1');")]);
    assert!(e.len() == 1 && e[0].contains("UpperCamelCase"), "{e:?}");
    let e = diags(&[("page.dart", "const n = 'A';\nconst routeName = n;\nWidget page() => const Text('1');")]);
    assert!(e.len() == 1 && e[0].contains("plain string literal"), "{e:?}");
}

#[test]
fn the_root_function_route_is_called_root() {
    let c = code(&[("page.dart", "Widget page() => const Text('home');")]);
    has(&c, &["final class RootRoute extends TypedLocation"]);
}

#[test]
fn one_screen_serves_two_routes_with_different_constants() {
    let screen = "import 'screen.dart';\n";
    let c = code(&[
        ("page.dart", HOME),
        ("(kyc)/shop/name/page.dart", &format!("{screen}Widget page() => const NameScreen(audience: Audience.shop);")),
        ("(kyc)/person/name/page.dart", &format!("{screen}Widget page({{String? back}}) => NameScreen(audience: Audience.person, back: back);")),
    ]);
    has(&c, &[".page()", ".page(back: v.back)", "ShopNameRoute", "PersonNameRoute"]);
    // Two functions, one import each: they don't clash.
    assert!(c.contains("import 'app/(kyc)/shop/name/page.dart' as _i") && c.contains("import 'app/(kyc)/person/name/page.dart' as _i"), "{c}");
}

// --- fsp new --function --------------------------------------------------------------

fn args(route: &str) -> NewArgs {
    NewArgs {
        route: route.into(),
        name: None,
        function: true,
        not_found: false,
        data: false,
        loading: false,
        error: false,
        layout: false,
        guard: false,
        transition: false,
    }
}

fn read(dir: &tempfile::TempDir, rel: &str) -> String {
    fs::read_to_string(dir.path().join("lib/app").join(rel)).unwrap()
}

#[test]
fn new_function_scaffolds_functions_that_pass_gen() {
    let dir = project(&[("page.dart", HOME)]);
    let a = NewArgs { loading: true, error: true, layout: true, not_found: true, data: true, ..args("orders/[orderId]") };
    scaffold::new_route(dir.path(), &a).unwrap();
    let page = read(&dir, "orders/$orderId/page.dart");
    assert!(page.contains("Widget page({required String data})") && !page.contains("routeName"), "{page}");
    assert!(read(&dir, "orders/$orderId/layout.dart").contains("Widget layout({required Widget child}) => child;"));
    assert!(read(&dir, "orders/$orderId/loading.dart").contains("Widget loading() =>"));
    assert!(read(&dir, "orders/$orderId/error.dart").contains("Widget error({required Object error, required VoidCallback retry})"));
    assert!(read(&dir, "orders/$orderId/not_found.dart").contains("Widget notFound({required Uri uri})"));
    let (_, diags, routes) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.iter().all(|d| d.level != crate::diag::Level::Error), "{:?}", diags.0);
    assert_eq!(routes, 2);
}

#[test]
fn new_function_with_segments_and_name_writes_route_name() {
    let dir = project(&[("page.dart", HOME)]);
    let a = NewArgs { name: Some("KycShopName".into()), ..args("(kyc)/shop/[id]/name") };
    scaffold::new_route(dir.path(), &a).unwrap();
    let page = read(&dir, "(kyc)/shop/$id/name/page.dart");
    assert!(page.contains("const routeName = 'KycShopName';"), "{page}");
    assert!(page.contains("Widget page({required String id}) =>"), "{page}");
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    has(&code, &["final class KycShopNameRoute extends TypedLocation", ".page(id: v.id)"]);

    // Without --name, the folder names the route.
    let dir = project(&[("page.dart", HOME)]);
    scaffold::new_route(dir.path(), &args("(kyc)/shop/name")).unwrap();
    assert!(!read(&dir, "(kyc)/shop/name/page.dart").contains("routeName"));
    let e = scaffold::new_route(dir.path(), &NewArgs { name: Some("kyc".into()), ..args("other") }).unwrap_err().to_string();
    assert!(e.contains("UpperCamelCase"), "{e}");
}

#[test]
fn new_without_function_still_writes_classes() {
    let dir = project(&[("page.dart", HOME)]);
    scaffold::new_route(dir.path(), &NewArgs { function: false, ..args("docs") }).unwrap();
    assert!(read(&dir, "docs/page.dart").contains("class DocsPage extends HookConsumerWidget"));
    scaffold::new_route(dir.path(), &NewArgs { function: false, not_found: true, ..args("docs") }).unwrap();
    assert!(read(&dir, "docs/not_found.dart").contains("class DocsNotFound extends StatelessWidget"));
}

// --- not_found.dart / not-found.dart --------------------------------------------------

const NF: &str = "class NotFoundPage extends StatelessWidget { const NotFoundPage({super.key, required this.uri}); final Uri uri; }";

#[test]
fn not_found_is_read_in_either_spelling() {
    let snake = code(&[("page.dart", HOME), ("not_found.dart", NF), ("shop/page.dart", &class("ShopPage")), ("shop/not_found.dart", NF)]);
    let kebab = code(&[("page.dart", HOME), ("not-found.dart", NF), ("shop/page.dart", &class("ShopPage")), ("shop/not-found.dart", NF)]);
    // Identical, apart from the import of the file as it is spelled on disk.
    assert_eq!(snake.replace("/not_found.dart'", "/not-found.dart'"), kebab);
    has(&kebab, &["import 'app/not-found.dart'", "import 'app/shop/not-found.dart'", "NotFoundPage(uri: uri)"]);
    // Mixed in one tree is fine.
    code(&[("page.dart", HOME), ("not-found.dart", NF), ("shop/page.dart", &class("ShopPage")), ("shop/not_found.dart", NF)]);
}

#[test]
fn diagnostics_name_the_file_as_spelled_on_disk() {
    let e = diags(&[
        ("page.dart", HOME),
        ("not-found.dart", "class N extends StatelessWidget { const N({super.key, required this.x}); final int x; }"),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ not-found.dart:1  can't fill `x`") && e[0].contains("not_found.dart only gets"), "{e:?}");
    let e = diags(&[("page.dart", HOME), ("a/$$rest/not-found.dart", NF), ("a/$$rest/page.dart", &class("RestPage"))]);
    assert!(e.iter().any(|m| m.starts_with("✗ a/$$rest/not-found.dart") && m.contains("catch-all")), "{e:?}");
}

#[test]
fn both_spellings_in_one_folder_are_an_error_for_each_file() {
    let dir = project(&[("page.dart", HOME), ("not_found.dart", NF), ("not-found.dart", NF)]);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let e: Vec<String> = diags.0.iter().map(|d| d.to_string()).collect();
    assert_eq!(e.len(), 2, "{e:?}");
    assert!(e.iter().any(|m| m.starts_with("✗ not-found.dart:1  `not-found.dart` and `not_found.dart` are the same view")), "{e:?}");
    assert!(e.iter().any(|m| m.starts_with("✗ not_found.dart:1  `not_found.dart` and `not-found.dart` are the same view")), "{e:?}");
    // Each has a span, so each gets a code frame.
    assert!(diags.0.iter().all(|d| d.span.is_some()));
    // Only where they share a folder.
    code(&[("page.dart", HOME), ("not_found.dart", NF), ("a/page.dart", &class("APage")), ("a/not-found.dart", NF)]);
}

// --- file_style ----------------------------------------------------------------------

#[test]
fn file_style_is_read_from_the_config() {
    use crate::scan::FileStyle;
    assert_eq!(Config::default().file_style, FileStyle::Snake);
    let cfg = |y: &str| crate::config::Pubspec::parse(y).map(|p| p.config.file_style);
    assert_eq!(cfg("name: x\nfespalier:\n  file_style: kebab\n").unwrap(), FileStyle::Kebab);
    assert_eq!(cfg("name: x\nfespalier:\n  file_style: snake\n").unwrap(), FileStyle::Snake);
    assert_eq!(cfg("name: x\nfespalier:\n  format: true\n").unwrap(), FileStyle::Snake);
    let e = format!("{:#}", cfg("name: x\nfespalier:\n  file_style: camel\n").unwrap_err());
    assert!(e.contains("kebab") && e.contains("snake"), "{e}");
}

#[test]
fn init_writes_the_style_the_project_chose() {
    let dir = configured("fespalier:\n  file_style: kebab\n", &[]);
    init::run(dir.path()).unwrap();
    assert!(dir.path().join("lib/app/not-found.dart").exists());
    assert!(!dir.path().join("lib/app/not_found.dart").exists());
    let code = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(&code, &["import 'app/not-found.dart'"]);
    // Running again changes nothing, and leaves no second spelling behind.
    init::run(dir.path()).unwrap();

    // The default is unchanged.
    let dir = configured("", &[]);
    init::run(dir.path()).unwrap();
    assert!(dir.path().join("lib/app/not_found.dart").exists());
    assert!(!dir.path().join("lib/app/not-found.dart").exists());
}

#[test]
fn init_does_not_add_a_second_spelling() {
    // A kebab project whose not-found already exists as snake_case, and the other way round.
    let dir = configured("fespalier:\n  file_style: kebab\n", &[("not_found.dart", NF)]);
    init::run(dir.path()).unwrap();
    assert!(!dir.path().join("lib/app/not-found.dart").exists());
    let dir = configured("", &[("not-found.dart", NF)]);
    init::run(dir.path()).unwrap();
    assert!(!dir.path().join("lib/app/not_found.dart").exists());
}

#[test]
fn new_not_found_follows_file_style() {
    let dir = configured("fespalier:\n  file_style: kebab\n", &[("page.dart", HOME)]);
    let created = scaffold::new_route(dir.path(), &NewArgs { function: false, not_found: true, ..args("shop") }).unwrap();
    assert_eq!(created, vec!["lib/app/shop/page.dart".to_string(), "lib/app/shop/not-found.dart".to_string()]);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::load(dir.path()).unwrap()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    has(&code, &["import 'app/shop/not-found.dart'"]);
    // A second run doesn't add the snake_case one.
    let e = scaffold::new_route(dir.path(), &NewArgs { function: false, not_found: true, ..args("shop") }).unwrap_err().to_string();
    assert!(e.contains("nothing to create"), "{e}");
    assert!(!dir.path().join("lib/app/shop/not_found.dart").exists());
}
