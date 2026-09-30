//! `extra` for layouts, guards and redirects, and `extra_codec.dart`. (Pages' typed
//! `extra` is in `paths_tests.rs`.)

use std::fs;

use crate::config::Config;
use crate::extra::{agree, fits, takes_any};
use crate::{build, gen_with};

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

/// The `_iN` prefix the generated code gives a file, e.g. `imp(&c, "shop/guard.dart")`.
fn imp(code: &str, file: &str) -> String {
    let needle = format!("'app/{}' as ", file.replace('$', "\\$"));
    let i = code.find(&needle).unwrap_or_else(|| panic!("no import of {file} in:\n{code}")) + needle.len();
    code[i..].split(';').next().unwrap().to_string()
}

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";
const IMPORTS: &str = "import 'package:flutter/widgets.dart';\nimport '../../models.dart';\n";

/// A page called `{name}Page` taking `extra` of type `ty` (or none).
fn page(name: &str, ty: Option<&str>) -> String {
    match ty {
        Some(ty) => format!("{IMPORTS}class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, this.extra}}); final {ty} extra; }}"),
        None => format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}"),
    }
}

/// `shop/$id/page.dart`: an `id` segment and an `extra` of type `ty`.
fn item(ty: &str) -> String {
    format!("{IMPORTS}class ItemPage extends StatelessWidget {{ const ItemPage({{super.key, required this.id, this.extra}}); final int id; final {ty} extra; }}")
}

fn layout(ty: &str) -> String {
    format!("{IMPORTS}class ShopLayout extends StatelessWidget {{ const ShopLayout({{super.key, required this.child, this.extra}}); final Widget child; final {ty} extra; }}")
}

fn guard(ty: &str) -> String {
    format!("{IMPORTS}GuardResult guard(ProviderContainer c, {{{ty} extra}}) => null;")
}

// ---- the parameter is bound ----

#[test]
fn a_layout_takes_the_extra_of_the_location() {
    let c = code(&[("page.dart", HOME), ("shop/layout.dart", &layout("Product?")), ("shop/page.dart", &page("Shop", None))]);
    // Read where the layout is built, from the state of the location it is at.
    let l = imp(&c, "shop/layout.dart");
    has(&c, &[&format!("{l}.ShopLayout(child: child, extra: extraOrNull(state))"), "layoutPage(\n"]);
    lacks(&c, &["extraOf(state)"]);
}

#[test]
fn a_function_layout_takes_the_extra_too() {
    let f = "import '../../models.dart';\nWidget layout(Widget child, {Product? extra}) => Column(children: [child]);";
    let c = code(&[("page.dart", HOME), ("shop/layout.dart", f), ("shop/page.dart", &page("Shop", Some("Product?")))]);
    let l = imp(&c, "shop/layout.dart");
    has(&c, &[&format!("{l}.layout(child, extra: extraOrNull(state))"), "{Product? extra}"]);
    // The same rules: nullable, and the type of the routes below it.
    let e = errors(&[("page.dart", HOME), ("shop/layout.dart", "Widget layout(Widget child, {Product extra}) => child;"), ("shop/page.dart", &page("Shop", None))]);
    assert!(e.iter().any(|m| m.contains("declare it nullable")), "{e:?}");
    let e = errors(&[("page.dart", HOME), ("shop/layout.dart", "Widget layout(Widget child, {Order? extra}) => child;"), ("shop/page.dart", &page("Shop", Some("Product?")))]);
    assert!(e.iter().any(|m| m.starts_with("✗ shop/layout.dart:") && m.contains("`/shop`")), "{e:?}");
}

#[test]
fn a_layout_on_the_root_navigator_or_with_a_shell_transition_still_gets_it() {
    // A layout hosted on the root navigator (`navigator.dart` beside it).
    let c = code(&[
        ("page.dart", HOME),
        ("shop/layout.dart", &layout("Product?")),
        ("shop/navigator.dart", "const navigator = RouteNavigator.root;"),
        ("shop/page.dart", &page("Shop", Some("Product?"))),
    ]);
    let l = imp(&c, "shop/layout.dart");
    has(&c, &["ShellRoute(\n", "parentNavigatorKey: rootNavigatorKey,", &format!("{l}.ShopLayout(child: child, extra: extraOrNull(state))")]);
    // A shell transition builds the layout's page: the layout is its `child`, still inside `state`'s builder.
    let t = "Page<void> transition(LocalKey key, Widget child, {bool shell = false}) => MaterialPage(key: key, child: child);";
    let c = code(&[("page.dart", HOME), ("transition.dart", t), ("shop/layout.dart", &layout("Product?")), ("shop/page.dart", &page("Shop", None))]);
    let l = imp(&c, "shop/layout.dart");
    let tr = imp(&c, "transition.dart");
    has(&c, &[&format!("pageBuilder: (context, state, child) => {tr}.transition("), &format!("{l}.ShopLayout(child: child, extra: extraOrNull(state))")]);
    // And a tab layout, on the root navigator with a transition, gets it beside its shell.
    let tabs = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell, this.extra}); final StatefulNavigationShell navigationShell; final Object? extra; }";
    let c = code(&[("page.dart", HOME), ("transition.dart", t), ("t/layout.dart", tabs), ("t/navigator.dart", "const navigator = RouteNavigator.root;"), ("t/a/page.dart", &page("A", None)), ("t/b/page.dart", &page("B", None))]);
    has(&c, &["parentNavigatorKey: rootNavigatorKey,", "TabsLayout(navigationShell: navigationShell, extra: extraOrNull(state))"]);
}

#[test]
fn router_passes_the_navigator_key_and_the_extra_codec() {
    let c = code(&[("page.dart", HOME), ("extra_codec.dart", CODEC)]);
    has(&c, &["final routes = mount(navigatorKey: navigatorKey);", "extraCodec: _i1.extraCodec,", "navigatorKey: rootNavigatorKey,"]);
}

#[test]
fn a_tab_layout_and_a_section_layout_take_it_too() {
    let tabs = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell, this.extra}); final StatefulNavigationShell navigationShell; final Object? extra; }";
    let c = code(&[("layout.dart", tabs), ("a/page.dart", &page("A", None)), ("b/page.dart", &page("B", None))]);
    has(&c, &["_i0.TabsLayout(navigationShell: navigationShell, extra: extraOrNull(state))"]);
    let section = "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child, required this.id, this.extra}); final Widget child; final int id; final Object? extra; }";
    let c = code(&[("$id/layout.dart", section), ("$id/page.dart", &page("Item", None))]);
    has(&c, &["extra: extraOrNull(state)", "buildWithParams("]);
}

#[test]
fn a_guard_takes_the_extra() {
    let c = code(&[("page.dart", HOME), ("shop/guard.dart", &guard("Product?")), ("shop/page.dart", &page("Shop", None))]);
    let g = imp(&c, "shop/guard.dart");
    has(&c, &[&format!("{g}.guard(ProviderScope.containerOf(context, listen: false), extra: extraOrNull(state))")]);
    // Inherited by a route in a folder below it, and by a page-less group's routes.
    let c = code(&[
        ("(members)/guard.dart", &guard("Object?")),
        ("(members)/inbox/page.dart", &page("Inbox", None)),
        ("page.dart", HOME),
    ]);
    has(&c, &["extra: extraOrNull(state)"]);
}

#[test]
fn a_redirect_takes_the_extra_and_its_route_passes_one() {
    let r = "import '../models.dart';\nString redirect({Product? extra}) => extra == null ? '/' : '/shop';";
    let c = code(&[("page.dart", HOME), ("old/redirect.dart", r)]);
    let f = imp(&c, "old/redirect.dart");
    has(
        &c,
        &[
            &format!("{f}.redirect(extra: extraOrNull(state))"),
            "void go(BuildContext context, {Product? extra}) => context.go(location, extra: extra);",
            "import 'app/models.dart' show Product;",
        ],
    );
}

#[test]
fn a_guard_reads_it_beside_segments_and_the_uri() {
    let g = "GuardResult guard(ProviderContainer c, {required int id, required Uri uri, Object? extra}) => null;";
    let c = code(&[("$id/guard.dart", g), ("$id/page.dart", &item("Object?"))]);
    has(&c, &["id: v.id, uri: state.uri, extra: extraOrNull(state)"]);
}

#[test]
fn extra_is_a_named_parameter_of_a_guard() {
    let e = errors(&[("guard.dart", "GuardResult guard(ProviderContainer c, Object? extra) => null;"), ("page.dart", HOME)]);
    assert!(e.iter().any(|m| m.contains("guard() takes `extra` as a named parameter")), "{e:?}");
}

#[test]
fn nothing_takes_an_extra_unless_it_asks() {
    let plain = "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child}); final Widget child; }";
    let c = code(&[("page.dart", HOME), ("shop/layout.dart", plain), ("shop/page.dart", &page("Shop", None))]);
    lacks(&c, &["extraOf", "extraOrNull", "extra:"]);
}

// ---- it must be nullable ----

#[test]
fn a_layout_guard_or_redirect_extra_must_be_nullable() {
    let want = |e: &[String]| e.iter().any(|m| m.contains("a deep link or a reload leaves it null") && m.contains("`Product? extra`"));
    let e = errors(&[("page.dart", HOME), ("shop/layout.dart", &layout("Product")), ("shop/page.dart", &page("Shop", None))]);
    assert!(want(&e) && e[0].starts_with("✗ shop/layout.dart:"), "{e:?}");
    let e = errors(&[("page.dart", HOME), ("shop/guard.dart", &guard("Product")), ("shop/page.dart", &page("Shop", None))]);
    assert!(want(&e) && e[0].starts_with("✗ shop/guard.dart:"), "{e:?}");
    let e = errors(&[("page.dart", HOME), ("old/redirect.dart", "import '../models.dart';\nString redirect({Product extra}) => '/';")]);
    assert!(want(&e) && e[0].starts_with("✗ old/redirect.dart:"), "{e:?}");
    for ty in ["Product?", "Object?", "dynamic"] {
        assert!(errors(&[("page.dart", HOME), ("shop/guard.dart", &guard(ty)), ("shop/page.dart", &page("Shop", None))]).is_empty(), "{ty}");
    }
}

// ---- the types agree ----

#[test]
fn a_guard_must_take_the_type_of_the_pages_it_guards() {
    let run = |g: &str, p: &str| errors(&[("page.dart", HOME), ("shop/guard.dart", &guard(g)), ("shop/$id/page.dart", &item(p))]);
    // The same type (nullability aside), or a guard that takes anything.
    for g in ["Product?", "Object?", "dynamic"] {
        assert!(run(g, "Product?").is_empty(), "{g}");
    }
    // A guard for one type would miss the rest of what a route for `Object?` gets.
    assert!(run("Product?", "Object?").iter().any(|m| m.contains("(shop/$id/page.dart takes `Object?`)")));
    let e = run("Order?", "Product?");
    assert_eq!(e.len(), 1, "{e:?}");
    // At the guard's parameter, naming both types and the route.
    assert!(e[0].starts_with("✗ shop/guard.dart:3  `extra` is `Order?` here, but the routes it covers take other types: "), "{e:?}");
    assert!(e[0].contains("`/shop/:id` (shop/$id/page.dart takes `Product?`)"), "{e:?}");
    assert!(e[0].contains("a guard sees the extra of every route it covers, so declare it as `Object?`"), "{e:?}");
}

#[test]
fn a_layout_above_routes_with_different_types_must_take_object() {
    let files = |ty: &str| {
        vec![
            ("page.dart", HOME.to_string()),
            ("shop/layout.dart", layout(ty)),
            ("shop/a/page.dart", page("A", Some("Product?"))),
            ("shop/b/page.dart", page("B", Some("Order?"))),
            ("shop/c/page.dart", page("C", None)),
        ]
    };
    let run = |ty: &str| {
        let files = files(ty);
        errors(&files.iter().map(|(a, b)| (*a, b.as_str())).collect::<Vec<_>>())
    };
    assert!(run("Object?").is_empty());
    assert!(run("dynamic").is_empty());
    // Product? fits `/shop/a` but not `/shop/b`; the route without an extra is no conflict.
    let e = run("Product?");
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ shop/layout.dart:"), "{e:?}");
    assert!(e[0].contains("`/shop/b` (shop/b/page.dart takes `Order?`)"), "{e:?}");
    assert!(!e[0].contains("/shop/a") && !e[0].contains("/shop/c"), "{e:?}");
    assert!(e[0].contains("a layout sees the extra of every route it covers, so declare it as `Object?`"), "{e:?}");
    // A type that fits neither lists both.
    let e = run("Cart?");
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("`/shop/a`") && e[0].contains("`/shop/b`"), "{e:?}");
}

#[test]
fn a_layout_with_one_type_below_it_takes_that_type() {
    let files = [("page.dart", HOME.to_string()), ("shop/a/page.dart", page("A", Some("Product?"))), ("shop/b/page.dart", page("B", None))];
    let with = |ty: &str| {
        let mut all = files.to_vec();
        all.push(("shop/layout.dart", layout(ty)));
        errors(&all.iter().map(|(a, b)| (*a, b.as_str())).collect::<Vec<_>>())
    };
    assert!(with("Product?").is_empty());
    assert_eq!(with("Order?").len(), 1);
}

#[test]
fn a_layout_is_not_held_to_the_type_of_a_redirect_it_never_shows() {
    let r = "import '../../models.dart';\nString redirect({Order? extra}) => '/';";
    let e = errors(&[("page.dart", HOME), ("shop/layout.dart", &layout("Product?")), ("shop/a/page.dart", &page("A", Some("Product?"))), ("shop/old/redirect.dart", r)]);
    assert!(e.is_empty(), "{e:?}");
    // A guard does run before it.
    let e = errors(&[("page.dart", HOME), ("shop/guard.dart", &guard("Product?")), ("shop/old/redirect.dart", r)]);
    assert!(e.iter().any(|m| m.contains("`/shop/old` (shop/old/redirect.dart takes `Order?`)")), "{e:?}");
}

#[test]
fn readers_of_a_route_without_an_extra_must_agree_with_each_other() {
    let files = |g: &str, l: &str| {
        vec![("page.dart", HOME.to_string()), ("shop/guard.dart", guard(g)), ("shop/layout.dart", layout(l)), ("shop/page.dart", page("Shop", None))]
    };
    let run = |g: &str, l: &str| {
        let files = files(g, l);
        errors(&files.iter().map(|(a, b)| (*a, b.as_str())).collect::<Vec<_>>())
    };
    assert!(run("Product?", "Product?").is_empty());
    assert!(run("Product?", "Object?").is_empty());
    // One error, at the inner one: the layout reads what the guard already reads as another type.
    let e = run("Product?", "Order?");
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ shop/layout.dart:") && e[0].contains("(shop/guard.dart takes `Product?`)"), "{e:?}");
}

#[test]
fn the_route_own_type_has_the_last_word() {
    // The guard above agrees with the page, so only the layout that doesn't is reported.
    let e = errors(&[
        ("page.dart", HOME),
        ("shop/guard.dart", &guard("Product?")),
        ("shop/layout.dart", &layout("Order?")),
        ("shop/page.dart", &page("Shop", Some("Product?"))),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ shop/layout.dart:"), "{e:?}");
}

// ---- typed routes ----

#[test]
fn a_route_without_an_extra_takes_the_one_its_guard_or_layout_asks_for() {
    let c = code(&[("page.dart", HOME), ("shop/guard.dart", &guard("Product?")), ("shop/page.dart", &page("Shop", None))]);
    has(&c, &["void go(BuildContext context, {Product? extra}) => context.go(location, extra: extra);", "import 'models.dart' show Product;"]);
    // From a layout, and for the pages below it; the home page is outside it.
    let c = code(&[("page.dart", HOME), ("shop/layout.dart", &layout("Product?")), ("shop/page.dart", &page("Shop", None))]);
    has(&c, &["{Product? extra}"]);
    let home = &c[c.find("final class HomeRoute").unwrap()..c.find("final class ShopRoute").unwrap()];
    lacks(home, &["extra"]);
    // `Object?` says nothing about the type: the route takes no typed extra.
    let c = code(&[("page.dart", HOME), ("shop/guard.dart", &guard("Object?")), ("shop/page.dart", &page("Shop", None))]);
    lacks(&c, &["context.go(location, extra: extra)"]);
}

#[test]
fn a_pages_own_type_is_the_typed_routes() {
    let c = code(&[("page.dart", HOME), ("shop/guard.dart", &guard("Object?")), ("shop/page.dart", &page("Shop", Some("Product?")))]);
    let p = imp(&c, "shop/page.dart");
    has(&c, &["{Product? extra}", &format!("{p}.ShopPage(extra: extraOf(state))"), "extra: extraOrNull(state)"]);
}

#[test]
fn types_named_by_a_guard_and_a_page_do_not_share_aliases() {
    let g = "import '../a.dart' as m;\nGuardResult guard(ProviderContainer c, {m.Thing? extra}) => null;";
    let p = "import 'package:flutter/widgets.dart';\nimport '../../b.dart' as m;\nclass OtherPage extends StatelessWidget { const OtherPage({super.key, this.extra}); final m.Thing? extra; }";
    let c = code(&[("page.dart", HOME), ("guard.dart", g), ("other/page.dart", p)]);
    // The page's own type is spelled under its own alias; the guard's, which types the home
    // page that has none, under an alias of its own: one prefix, two libraries.
    has(&c, &["as _e1_m;", "{_e1_m.Thing? extra}", "import 'a.dart' as _eg0_m;", "{_eg0_m.Thing? extra}"]);
    lacks(&c, &["import 'a.dart' as _e1_m;", "import 'b.dart' as _eg0_m;"]);
}

// ---- extra_codec.dart ----

const CODEC: &str = "import 'package:fespalier/fespalier.dart';\nfinal extraCodec = ExtraCodec({});";

#[test]
fn router_gets_the_extra_codec() {
    let c = code(&[("page.dart", HOME), ("extra_codec.dart", CODEC)]);
    has(&c, &["import 'app/extra_codec.dart' as _i", "extraCodec: _i1.extraCodec,", "routes: routes,"]);
    // Only the standalone router: `mount` embeds routes in a router that has its own.
    let router = &c[c.find("static GoRouter router(").unwrap()..c.find("static List<RouteBase> mount").unwrap()];
    assert!(router.contains("extraCodec: _i1.extraCodec"), "{router}");
    let none = code(&[("page.dart", HOME)]);
    lacks(&none, &["extraCodec"]);
}

#[test]
fn the_extra_codec_can_be_a_const_a_final_or_a_getter() {
    for body in [
        "const extraCodec = MyCodec();",
        "final extraCodec = ExtraCodec({});",
        "const Codec<Object?, Object?> extraCodec = MyCodec();",
        "Codec<Object?, Object?> get extraCodec => const MyCodec();",
    ] {
        let c = code(&[("page.dart", HOME), ("extra_codec.dart", body)]);
        has(&c, &["extraCodec: _i1.extraCodec"]);
    }
}

#[test]
fn the_extra_codec_needs_an_extra_codec() {
    let e = errors(&[("page.dart", HOME), ("extra_codec.dart", "final other = 1;")]);
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].starts_with("✗ extra_codec.dart  expected a top-level `extraCodec`"), "{e:?}");
}

#[test]
fn the_extra_codec_is_read_at_the_root_only() {
    let d = diags(&[("page.dart", HOME), ("shop/page.dart", &page("Shop", None)), ("shop/extra_codec.dart", CODEC)]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].starts_with("! shop/extra_codec.dart  extra_codec.dart is only read at the root of the app folder"), "{d:?}");
    lacks(&code(&[("page.dart", HOME), ("shop/page.dart", &page("Shop", None))]), &["extraCodec"]);
}

#[test]
fn the_extra_codec_can_be_spelled_in_kebab_case() {
    let c = code(&[("page.dart", HOME), ("extra-codec.dart", CODEC)]);
    has(&c, &["import 'app/extra-codec.dart' as _i1;", "extraCodec: _i1.extraCodec"]);
    // Both spellings in one folder are one file twice.
    let e = errors(&[("page.dart", HOME), ("extra-codec.dart", CODEC), ("extra_codec.dart", CODEC)]);
    assert!(e.iter().any(|m| m.contains("are the same view and both are in this folder")), "{e:?}");
}

#[test]
fn a_folder_of_only_an_extra_codec_is_not_a_route() {
    let dir = project(&[("page.dart", HOME), ("extra_codec.dart", CODEC)]);
    let out = gen_with(dir.path(), &Config::default(), true).unwrap();
    assert_eq!(out.routes, 1);
    let written = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(written.contains("extraCodec: _i1.extraCodec"));
}

// ---- the type rules ----

#[test]
fn any_and_agreeing_types() {
    for ty in ["Object?", "Object", "dynamic"] {
        assert!(takes_any(ty), "{ty}");
    }
    for ty in ["Product?", "List<Object?>?", "Objects?"] {
        assert!(!takes_any(ty), "{ty}");
    }
    // A reader fits a route of its type, or reads anything; never a route for `Object?` while narrower.
    assert!(fits("Product?", "Product"));
    assert!(fits("Object?", "Product?"));
    assert!(fits("dynamic", "Product?"));
    assert!(!fits("Product?", "Object?"));
    assert!(!fits("List<Product>?", "List<Order>?"));
    // Two readers with no route type between them: either takes anything.
    assert!(agree("Product?", "Object?"));
    assert!(agree("Product?", "Product"));
    assert!(!agree("Product?", "Order?"));
}
