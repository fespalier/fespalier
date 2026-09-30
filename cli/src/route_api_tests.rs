//! Typed data helpers on routes, section-level data.dart and not_found.dart in
//! any folder. (The rest of the generator's tests are in `tests.rs`.)

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
    diags.0.iter().map(|d| d.to_string()).collect()
}

/// Just the errors: a warning (a page that doesn't take its data) isn't one.
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

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

fn widget(class: &str, fields: &str, params: &str) -> String {
    format!("class {class} extends StatelessWidget {{ const {class}({{super.key{params}}}); {fields} }}")
}

// --- typed helpers ---------------------------------------------------------------------

#[test]
fn data_routes_get_typed_watch_read_and_prefetch() {
    let c = code(&[
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("a/page.dart", &widget("APage", "final int n;", ", required this.n")),
        ("$id/data.dart", "Future<String> data(Ref ref, {required int id, String? q}) async => '';"),
        ("$id/page.dart", &widget("ItemPage", "final String s;", ", required this.s")),
    ]);
    has(
        &c,
        &[
            // No key: nothing to pass. The types are the provider's, inferred: never spelled.
            "static final watch = (WidgetRef ref) => ref.watch(data);",
            "static final read = (WidgetRef ref) => ref.readData(data);",
            "void prefetch(WidgetRef ref, {Duration? keepFor}) => ref.prefetchData(data, keepFor: keepFor);",
            // A segment and a query parameter, as the record key.
            "static final watch = (WidgetRef ref, {required int id, String? q}) => ref.watch(data((id: id, q: q)));",
            "static final read = (WidgetRef ref, {required int id, String? q}) => ref.readData(data((id: id, q: q)));",
            "ref.prefetchData(data((id: id, q: q)), keepFor: keepFor);",
            // What was already there stays.
            "Future<void> refresh(WidgetRef ref) => ref.refresh(data((id: id, q: q)).future);",
        ],
    );
}

#[test]
fn a_single_key_is_passed_bare_and_routes_without_data_get_no_helpers() {
    let c = code(&[
        ("$id/data.dart", "Future<int> data(Ref ref, {required int id}) async => id;"),
        ("$id/page.dart", &widget("ItemPage", "final int n;", ", required this.n")),
        ("plain/page.dart", HOME.replace("Home", "Plain").as_str()),
    ]);
    has(&c, &["static final watch = (WidgetRef ref, {required int id}) => ref.watch(data(id));"]);
    // Only ItemRoute has the helpers.
    assert_eq!(c.matches("static final watch").count(), 1, "{c}");
    assert_eq!(c.matches("void prefetch(").count(), 1, "{c}");
}

#[test]
fn helpers_work_for_a_provider_written_by_hand() {
    let c = code(&[
        ("data.dart", "final data = FutureProvider<int>((ref) async => 1);"),
        ("page.dart", &widget("HomePage", "final int n;", ", required this.n")),
    ]);
    has(&c, &["static final watch = (WidgetRef ref) => ref.watch(data);", "ref.prefetchData(data,"]);
}

#[test]
fn names_the_helpers_use_are_reserved() {
    let e = diags(&[("$watch/page.dart", HOME), ("$ref/page.dart", HOME), ("$read/page.dart", HOME)]).join("\n");
    for name in ["watch", "ref", "read"] {
        assert!(e.contains(&format!("`${name}` is reserved")), "{e}");
    }
    // The same goes for query parameters: they're fields of the route class.
    let e = diags(&[("page.dart", &widget("HomePage", "final bool? read;", ", this.read"))]).join("\n");
    assert!(e.contains("`read` can't be a query parameter"), "{e}");
    let e = diags(&[("page.dart", &widget("HomePage", "final String? go;", ", this.go"))]).join("\n");
    assert!(e.contains("`go` can't be a query parameter"), "{e}");
}

// --- section data ----------------------------------------------------------------------

/// `(shop)/` is a page-less folder whose layout and data.dart cover the routes in it.
fn shop_files<'a>(layout_fields: &'a str, layout_params: &'a str) -> Vec<(&'static str, String)> {
    vec![
        ("(shop)/data.dart", "Future<Shop> data(Ref ref) async => Shop();".into()),
        ("(shop)/layout.dart", widget("ShopLayout", &format!("final Widget child; {layout_fields}"), &format!(", required this.child{layout_params}"))),
        ("(shop)/cart/page.dart", widget("CartPage", "final Shop shop;", ", required this.shop")),
        ("(shop)/plain/page.dart", widget("PlainPage", "", "")),
    ]
}

fn refs<'a>(files: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    files.iter().map(|(a, b)| (*a, b.as_str())).collect()
}

#[test]
fn a_layouts_data_dart_is_the_data_of_its_section() {
    let files = shop_files("final Shop shop;", ", required this.shop");
    let c = code(&refs(&files));
    has(
        &c,
        &[
            // The layout waits for the data, showing the default loading and error views.
            "builder: (context, state, child) => DataView(",
            "watch: (ref) => ref.watch(_data1),",
            "data: (d) => _i1.ShopLayout(child: child, shop: d),",
            "loading: () => const DefaultLoading(),",
            "error: (e, st, retry) => DefaultError(error: e, retry: retry),",
            // The page below takes it by type, from the provider the layout loaded.
            "SectionView(",
            "data: (s1) => _i2.CartPage(shop: s1),",
            "final _data1 = FutureProvider.autoDispose(",
        ],
    );
    // A page that doesn't ask for it isn't wrapped, and the section has no route class of its own.
    has(&c, &["_i3.PlainPage()"]);
    assert_eq!(c.matches("SectionView(").count(), 1, "{c}");
    lacks(&c, &["class ShopRoute", "static final data = _data1"]);
}

#[test]
fn section_keys_come_from_segments_and_the_layout_reads_the_url() {
    let c = code(&[
        ("$tid/data.dart", "Future<Team> data(Ref ref, {required int tid}) async => Team();"),
        ("$tid/layout.dart", &widget("TeamLayout", "final Widget child; final Team t;", ", required this.child, required this.t")),
        ("$tid/members/page.dart", &widget("MembersPage", "final Team team;", ", required this.team")),
    ]);
    has(
        &c,
        &[
            "() => _layout1(state),",
            "watch: (ref) => ref.watch(_data1(v.tid)),",
            "refresh: (ref) => ref.invalidate(_data1(v.tid)),",
            "data: (d) => _i1.TeamLayout(child: child, t: d),",
            // The page reads the same provider, keyed by its own copy of the segment.
            "watch: (ref) => ref.watch(_data1(v.tid)),\n",
            "data: (s1) => _i2.MembersPage(team: s1),",
            "({int tid}) _layout1(GoRouterState s) => (tid: Segment.asInt(s, 'tid'));",
        ],
    );
}

#[test]
fn a_parameter_called_data_gets_the_nearest_data() {
    let mut files = shop_files("final Shop data;", ", required this.data");
    files[2] = ("(shop)/cart/page.dart", widget("CartPage", "final Shop data;", ", required this.data"));
    let c = code(&refs(&files));
    has(&c, &["_i1.ShopLayout(child: child, data: d)", "data: (s1) => _i2.CartPage(data: s1),"]);

    // With a data.dart of its own, `data` is that one and the section's is asked for by type.
    let c = code(&[
        ("(shop)/data.dart", "Future<Shop> data(Ref ref) async => Shop();"),
        ("(shop)/layout.dart", &widget("ShopLayout", "final Widget child;", ", required this.child")),
        ("(shop)/item/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("(shop)/item/page.dart", &widget("ItemPage", "final int data; final Shop shop;", ", required this.data, required this.shop")),
    ]);
    has(&c, &["_i3.ItemPage(data: d, shop: s1)"]);
}

#[test]
fn section_data_reaches_nested_sections_and_layouts_below() {
    let c = code(&[
        ("(a)/data.dart", "Future<A> data(Ref ref) async => A();"),
        ("(a)/layout.dart", &widget("ALayout", "final Widget child; final A a;", ", required this.child, required this.a")),
        ("(a)/(b)/data.dart", "Future<B> data(Ref ref) async => B();"),
        ("(a)/(b)/layout.dart", &widget("BLayout", "final Widget child; final A a; final B b;", ", required this.child, required this.a, required this.b")),
        ("(a)/(b)/x/page.dart", &widget("BPage", "final A a; final B b;", ", required this.a, required this.b")),
    ]);
    has(
        &c,
        &[
            // B's layout gets its own section's data and reads A's again.
            "data: (d) => SectionView(",
            "_i3.BLayout(child: child, a: s1, b: d)",
            // The page gets both from providers the layouts loaded.
            "_i4.BPage(a: s1, b: s2)",
        ],
    );
    assert!(c.contains("_data1") && c.contains("_data2"), "{c}");
}

#[test]
fn section_loading_and_error_views_apply() {
    let c = code(&[
        ("(shop)/data.dart", "Future<Shop> data(Ref ref) async => Shop();"),
        ("(shop)/layout.dart", &widget("ShopLayout", "final Widget child;", ", required this.child")),
        ("(shop)/loading.dart", &widget("ShopLoading", "", "")),
        ("(shop)/error.dart", &widget("ShopError", "final Object error; final VoidCallback retry;", ", required this.error, required this.retry")),
        ("(shop)/cart/page.dart", widget("CartPage", "", "").as_str()),
    ]);
    has(&c, &["loading: () => _i1.ShopLoading(),", "error: (e, st, retry) => _i2.ShopError(error: e, retry: retry),"]);
}

#[test]
fn a_tab_layout_can_be_a_section_too() {
    let c = code(&[
        ("(tabs)/data.dart", "Future<Me> data(Ref ref) async => Me();"),
        (
            "(tabs)/layout.dart",
            &widget("TabsLayout", "final StatefulNavigationShell navigationShell; final Me me;", ", required this.navigationShell, required this.me"),
        ),
        ("(tabs)/one/page.dart", &widget("OnePage", "", "")),
        ("(tabs)/two/page.dart", &widget("TwoPage", "", "")),
    ]);
    has(&c, &["StatefulShellRoute.indexedStack(", "builder: (context, state, navigationShell) => DataView(", "_i1.TabsLayout(navigationShell: navigationShell, me: d)"]);
}

#[test]
fn section_data_errors() {
    // No layout beside it, and no page to feed.
    let e = diags(&[("a/data.dart", "Future<int> data(Ref ref) async => 1;"), ("a/b/page.dart", HOME)]).join("\n");
    assert!(e.contains("a/data.dart  data.dart has no page.dart to feed; with a layout.dart beside it"), "{e}");

    // A section takes segments only.
    let e = errors(&[
        ("(s)/data.dart", "Future<int> data(Ref ref, {String? q}) async => 1;"),
        ("(s)/layout.dart", &widget("SLayout", "final Widget child;", ", required this.child")),
        ("(s)/page.dart", HOME),
    ]);
    // A page next to the layout means data.dart feeds the page, as always.
    assert!(e.is_empty(), "{e:?}");
    let e = diags(&[
        ("(s)/data.dart", "Future<int> data(Ref ref, {String? q}) async => 1;"),
        ("(s)/layout.dart", &widget("SLayout", "final Widget child;", ", required this.child")),
        ("(s)/x/page.dart", HOME),
    ])
    .join("\n");
    assert!(e.contains("`q`: a section's data.dart can only take segments"), "{e}");

    // The same type twice is ambiguous by type, but `data` names the nearest.
    let e = diags(&[
        ("(s)/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("(s)/layout.dart", &widget("SLayout", "final Widget child;", ", required this.child")),
        ("(s)/x/data.dart", "Future<int> data(Ref ref) async => 2;"),
        ("(s)/x/page.dart", &widget("XPage", "final int n;", ", required this.n")),
    ])
    .join("\n");
    assert!(
        e.contains("`n` is int, which this folder's data.dart and the section's (s)/data.dart all yield; name the parameter `data`"),
        "{e}"
    );
    let e = errors(&[
        ("(s)/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("(s)/layout.dart", &widget("SLayout", "final Widget child;", ", required this.child")),
        ("(s)/x/data.dart", "Future<int> data(Ref ref) async => 2;"),
        ("(s)/x/page.dart", &widget("XPage", "final int data;", ", required this.data")),
    ]);
    assert!(e.is_empty(), "{e:?}");

    // `data` must be what the section yields.
    let e = diags(&[
        ("(s)/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("(s)/layout.dart", &widget("SLayout", "final Widget child;", ", required this.child")),
        ("(s)/x/page.dart", &widget("XPage", "final String data;", ", required this.data")),
    ])
    .join("\n");
    assert!(e.contains("`data` is String but the section's data.dart ((s)/data.dart) yields int"), "{e}");

    // Two sections above yielding the same type are ambiguous, too.
    let e = diags(&[
        ("(a)/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("(a)/layout.dart", &widget("ALayout", "final Widget child;", ", required this.child")),
        ("(a)/(b)/data.dart", "Future<int> data(Ref ref) async => 2;"),
        ("(a)/(b)/layout.dart", &widget("BLayout", "final Widget child;", ", required this.child")),
        ("(a)/(b)/x/page.dart", &widget("BPage", "final int n;", ", required this.n")),
    ])
    .join("\n");
    assert!(e.contains("`n` is int, which the section's (a)/data.dart and the section's (a)/(b)/data.dart all yield"), "{e}");
}

// --- not_found.dart in any folder ------------------------------------------------------

fn not_found(class: &str) -> String {
    format!("class {class} extends StatelessWidget {{ const {class}({{super.key, required this.uri}}); final Uri uri; }}")
}

#[test]
fn without_nested_not_found_files_nothing_changes() {
    let c = code(&[("page.dart", HOME)]);
    has(&c, &["static Widget notFound(Uri uri) => DefaultNotFound(uri);"]);
    lacks(&c, &["nearestNotFound"]);
}

#[test]
fn not_found_in_a_folder_covers_the_urls_under_it() {
    let c = code(&[
        ("not_found.dart", &not_found("RootNotFound")),
        ("page.dart", HOME),
        ("shop/not_found.dart", &not_found("ShopNotFound")),
        ("shop/page.dart", &widget("ShopPage", "", "")),
        ("shop/$id/not_found.dart", &not_found("ItemNotFound")),
        ("shop/$id/page.dart", &widget("ItemPage", "final int id;", ", required this.id")),
    ]);
    has(
        &c,
        &[
            "static Widget notFound(Uri uri) => nearestNotFound(",
            "base,",
            // Nearest first: the deeper folder, and a dynamic segment matches anything.
            "(['shop', ':id'], (uri) => _i5.ItemNotFound(uri: uri)),\n          (['shop'], (uri) => _i3.ShopNotFound(uri: uri)),",
            "(uri) => _i1.RootNotFound(uri: uri),",
            // An unparsable `$id` shows its own folder's; the shop page's own segments can't fail.
            "() => _i5.ItemNotFound(uri: state.uri),",
        ],
    );
    // errorBuilder still calls notFound, which picks.
    has(&c, &["errorBuilder: (context, state) => notFound(state.uri),"]);
    // /shop has no segment to fail on, so it has no fallback to spell.
    assert_eq!(c.matches("buildWithParams(").count(), 1, "{c}");
}

#[test]
fn a_root_not_found_is_the_fallback_for_routes_below_and_a_folder_one_stays_in_its_folder() {
    let c = code(&[
        ("a/not_found.dart", &not_found("ANotFound")),
        ("a/$x/page.dart", &widget("APage", "final int x;", ", required this.x")),
        ("b/$y/page.dart", &widget("BPage", "final int y;", ", required this.y")),
    ]);
    has(&c, &["() => _i0.ANotFound(uri: state.uri),", "(uri) => DefaultNotFound(uri),"]);
    // b/$y has no not_found.dart above it but the root's (here, the default): `notFound` picks.
    has(&c, &["() => notFound(state.uri),"]);
    assert_eq!(c.matches("buildWithParams(").count(), 2, "{c}");
}

#[test]
fn a_groups_not_found_covers_its_routes_but_not_urls() {
    let c = code(&[
        ("(g)/not_found.dart", &not_found("GNotFound")),
        ("(g)/$n/page.dart", &widget("NPage", "final int n;", ", required this.n")),
        ("other/$m/page.dart", &widget("MPage", "final int m;", ", required this.m")),
    ]);
    // A group adds nothing to the URL, so an unknown URL can't be told to be under it.
    lacks(&c, &["nearestNotFound"]);
    has(&c, &["() => _i0.GNotFound(uri: state.uri),", "() => notFound(state.uri),"]);
}

#[test]
fn two_folders_with_the_same_url_cannot_both_have_one() {
    let e = diags(&[
        ("(a)/x/not_found.dart", &not_found("ANotFound")),
        ("(a)/x/page.dart", HOME),
        ("(b)/x/not_found.dart", &not_found("BNotFound")),
        ("(b)/x/page.dart", &widget("BPage", "", "")),
    ])
    .join("\n");
    assert!(e.contains("/x already has (a)/x/not_found.dart"), "{e}");
}

#[test]
fn a_folders_not_found_only_gets_the_uri() {
    let e = diags(&[
        ("a/not_found.dart", "class N extends StatelessWidget { const N({super.key, required this.uri, required this.x}); final Uri uri; final int x; }"),
        ("a/page.dart", HOME),
    ])
    .join("\n");
    assert!(e.contains("can't fill `x`: not_found.dart only gets `Uri uri`"), "{e}");
}

#[test]
fn a_scaffolded_group_with_layout_and_data_is_a_section() {
    use crate::scaffold::{new_route, NewArgs};
    let dir = project(&[("page.dart", HOME)]);
    let args = |route: &str, data: bool, layout: bool| NewArgs {
        route: route.into(),
        name: None,
        data,
        loading: false,
        error: false,
        layout,
        guard: false,
        transition: false,
    };
    // A group has no page of its own; with its layout, data.dart is the section's.
    new_route(dir.path(), &args("(shop)", true, true)).unwrap();
    new_route(dir.path(), &args("(shop)/cart", false, false)).unwrap();
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    has(&code, &["builder: (context, state, child) => DataView(", "final _data1 = FutureProvider.autoDispose("]);
}

// --- together with guards, redirects and tab options -----------------------------------

#[test]
fn a_redirect_route_that_can_fail_to_parse_shows_the_nearest_not_found() {
    let c = code(&[
        ("old/not_found.dart", &not_found("OldNotFound")),
        ("old/$id/redirect.dart", "String redirect({required int id}) => '/new/$id';"),
        ("new/$id/page.dart", &widget("NewPage", "final int id;", ", required this.id")),
    ]);
    has(&c, &["builder: (context, state) => _i1.OldNotFound(uri: state.uri),"]);
    // A redirect-only route has no data, so no data helpers.
    lacks(&c, &["static final watch", "prefetch("]);
}

#[test]
fn guards_and_section_data_chain_together() {
    let c = code(&[
        ("(s)/guard.dart", "GuardResult guard(ProviderContainer c) => null;"),
        ("(s)/data.dart", "Future<Shop> data(Ref ref) async => Shop();"),
        ("(s)/layout.dart", &widget("ShopLayout", "final Widget child; final Shop shop;", ", required this.child, required this.shop")),
        ("(s)/x/$id/page.dart", &widget("XPage", "final Shop shop; final int id;", ", required this.shop, required this.id")),
    ]);
    has(&c, &["_i2.guard(ProviderScope.containerOf(context, listen: false))", "XPage(shop: s"]);
}

#[test]
fn a_tab_section_keeps_its_tab_options() {
    let layout = format!(
        "const tabOptions = {{'one': TabOptions(preload: true)}};\n{}",
        widget("TabsLayout", "final StatefulNavigationShell navigationShell; final Me me;", ", required this.navigationShell, required this.me")
    );
    let c = code(&[
        ("(tabs)/data.dart", "Future<Me> data(Ref ref) async => Me();"),
        ("(tabs)/layout.dart", &layout),
        ("(tabs)/one/page.dart", &widget("OnePage", "", "")),
        ("(tabs)/two/page.dart", &widget("TwoPage", "", "")),
    ]);
    has(&c, &["builder: (context, state, navigationShell) => DataView(", "preload: true,"]);
}
