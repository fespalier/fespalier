//! `data.dart` selecting a provider that exists (`ProviderListenable<AsyncValue<T>> data(...)
//! => productProvider(id)`) instead of wrapping one. (The rest of the generator's tests
//! are in `tests.rs`.)

use std::fs;

use crate::build;
use crate::config::{Config, DataRetry};

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
    diags.0.iter().map(|d| d.to_string()).collect()
}

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

const PRODUCT: &str = "class ProductPage extends StatelessWidget {\n  const ProductPage({super.key, required this.product});\n  final ProductView product;\n}";
const SELECT_ONE: &str = "ProviderListenable<AsyncValue<ProductView>> data({required String productId}) => productProvider(productId);";

#[test]
fn the_return_type_makes_a_selector_and_nothing_wraps_it() {
    let c = code(&[
        ("products/$productId/data.dart", SELECT_ONE),
        ("products/$productId/page.dart", PRODUCT),
    ]);
    has(
        &c,
        &[
            // The page is bound by type: T is what AsyncValue<T> holds.
            "data: (d) => _i1.ProductPage(product: d),",
            // Watched directly; invalidated through the runtime's check that it is a provider.
            "watch: (ref) => ref.watch(_data2(v.productId)),",
            "refresh: (ref) => ref.invalidateSelected(_data2(v.productId)),",
            // A closure, so its type comes from what data() returns.
            "final _data2 = (String productId) => _i0.data(productId: productId);",
            "static final data = _data2;",
            "static final read = (WidgetRef ref, {required String productId}) => ref.readSelected(data(productId));",
            "static final watch = (WidgetRef ref, {required String productId}) => ref.watch(data(productId));",
            "PrefetchHandle prefetch(WidgetRef ref, {Duration? keepFor}) => ref.prefetchData(data(productId), keepFor: keepFor);",
            "Future<void> refresh(WidgetRef ref) => ref.refreshSelected(data(productId));",
        ],
    );
    // No provider of ours in front of the app's.
    lacks(
        &c,
        &[
            "FutureProvider",
            "StreamProvider",
            ".autoDispose",
            ".future",
            "ref.invalidate(",
            "(Ref ref",
        ],
    );
}

#[test]
fn the_function_and_provider_forms_are_unchanged() {
    let c = code(&[
        (
            "a/$id/data.dart",
            "Future<int> data(Ref ref, {required int id}) async => id;",
        ),
        (
            "a/$id/page.dart",
            "class APage extends StatelessWidget { const APage(this.n, {super.key}); final int n; }",
        ),
    ]);
    has(
        &c,
        &[
            "ref.invalidate(_data",
            "ref.readData(",
            "ref.refresh(data(id).future)",
        ],
    );
    lacks(&c, &["Selected"]);
}

#[test]
fn no_keys_select_the_provider_as_it_is() {
    let c = code(&[
        (
            "products/data.dart",
            "ProviderListenable<AsyncValue<List<ProductView>>> data() => productsProvider;",
        ),
        (
            "products/page.dart",
            "class ProductsPage extends StatelessWidget { const ProductsPage({super.key, required this.items}); final List<ProductView> items; }",
        ),
    ]);
    has(
        &c,
        &[
            "final _data1 = _i0.data();",
            "static final data = _data1;",
            "watch: (ref) => ref.watch(_data1),",
            "refresh: (ref) => ref.invalidateSelected(_data1),",
            "static final watch = (WidgetRef ref) => ref.watch(data);",
            "Future<void> refresh(WidgetRef ref) => ref.refreshSelected(data);",
            "data: (d) => _i1.ProductsPage(items: d),",
        ],
    );
}

#[test]
fn several_keys_and_query_parameters_key_a_record() {
    let c = code(&[
        (
            "shops/$shop/items/$id/data.dart",
            "ProviderListenable<AsyncValue<Item>> data({required String shop, required int id, int? page, List<String> tags = const []}) => itemProvider(shop, id, page, tags);",
        ),
        (
            "shops/$shop/items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.item}); final Item item; }",
        ),
    ]);
    has(
        &c,
        &[
            // The same key the function form has, list wrapped for value equality; the
            // app's function gets it back as named arguments.
            "final _data4 = (({String shop, int id, int? page, QueryList<String> tags}) k) => _i0.data(shop: k.shop, id: k.id, page: k.page, tags: k.tags);",
            "ref.watch(_data4((shop: v.shop, id: v.id, page: v.page, tags: QueryList(v.tags))))",
            "/// shops/$shop/items/$id/data.dart as a Riverpod provider keyed by `(shop, id, page, tags)`.",
            "Future<void> refresh(WidgetRef ref) => ref.refreshSelected(data((shop: shop, id: id, page: page, tags: QueryList(tags))));",
        ],
    );
}

#[test]
fn segment_types_come_from_the_selectors_parameters() {
    let c = code(&[
        (
            "p/$id/data.dart",
            "ProviderListenable<AsyncValue<int>> data({required int id}) => intProvider(id);",
        ),
        (
            "p/$id/page.dart",
            "class PPage extends StatelessWidget { const PPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    has(
        &c,
        &[
            "const PRoute({required this.id});",
            "final int id;",
            "final _data2 = (int id) => _i0.data(id: id);",
        ],
    );
    // The segment's type is settled with the rest of the folder's files.
    let e = errors(&[
        (
            "p/$id/data.dart",
            "ProviderListenable<AsyncValue<int>> data({required int id}) => intProvider(id);",
        ),
        (
            "p/$id/page.dart",
            "class PPage extends StatelessWidget { const PPage(this.n, {super.key, required String id}); final int n; }",
        ),
    ]);
    assert!(e.iter().any(|m| m.contains("`$id` is int")), "{e:?}");
}

#[test]
fn a_page_takes_t_by_type_and_a_mismatch_is_an_error() {
    // T is what a page's parameter is matched against, exactly like `Future<T>`.
    let e = errors(&[
        ("products/$productId/data.dart", SELECT_ONE),
        (
            "products/$productId/page.dart",
            "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.p}); final String p; }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("can't fill `p`") && m.contains("data.dart's ProductView")),
        "{e:?}"
    );

    let e = errors(&[
        ("products/$productId/data.dart", SELECT_ONE),
        (
            "products/$productId/page.dart",
            "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.data}); final String data; }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("`data` is String but data.dart yields ProductView")),
        "{e:?}"
    );
}

#[test]
fn a_parameter_that_is_no_segment_or_query_is_an_error_at_it() {
    let e = errors(&[
        (
            "products/$productId/data.dart",
            "ProviderListenable<AsyncValue<ProductView>> data({required String productId, required String flavour}) => productProvider(productId);",
        ),
        ("products/$productId/page.dart", PRODUCT),
    ]);
    let msg = e
        .iter()
        .find(|m| m.contains("`flavour` isn't a segment of this path"))
        .unwrap_or_else(|| panic!("{e:?}"));
    assert!(
        msg.contains("data.dart:1") && msg.contains("String? flavour"),
        "{msg}"
    );

    // A positional parameter is no segment either.
    let e = errors(&[
        (
            "products/$productId/data.dart",
            "ProviderListenable<AsyncValue<int>> data(String productId) => p(productId);",
        ),
        (
            "products/$productId/page.dart",
            "class ProductPage extends StatelessWidget { const ProductPage(this.n, {super.key}); final int n; }",
        ),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("data() takes segments as named parameters")),
        "{e:?}"
    );
}

#[test]
fn a_selector_takes_no_ref() {
    let e = errors(&[
        (
            "products/$productId/data.dart",
            "ProviderListenable<AsyncValue<ProductView>> data(Ref ref, {required String productId}) => productProvider(productId);",
        ),
        ("products/$productId/page.dart", PRODUCT),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("takes no `Ref`") && m.contains("data.dart:1")),
        "{e:?}"
    );
}

#[test]
fn only_an_async_value_can_be_selected() {
    let e = errors(&[
        (
            "a/data.dart",
            "ProviderListenable<ProductView> data() => productProvider;",
        ),
        ("a/page.dart", PRODUCT),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("must return `ProviderListenable<AsyncValue<T>>`")),
        "{e:?}"
    );
}

#[test]
fn a_section_can_select_a_provider_too() {
    let c = code(&[
        (
            "teams/$teamId/data.dart",
            "ProviderListenable<AsyncValue<Team>> data({required String teamId}) => teamProvider(teamId);",
        ),
        (
            "teams/$teamId/layout.dart",
            "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.team, required this.child}); final Team team; final Widget child; }",
        ),
        (
            "teams/$teamId/settings/page.dart",
            "class SettingsPage extends StatelessWidget { const SettingsPage({super.key, required this.team}); final Team team; }",
        ),
    ]);
    has(
        &c,
        &[
            "final _data2 = (String teamId) => _i0.data(teamId: teamId);",
            "refresh: (ref) => ref.invalidateSelected(_data2(v.teamId)),",
            // The pages below watch the same selected provider.
            "SectionView(\n",
            "watch: (ref) => ref.watch(_data2(v.teamId)),",
        ],
    );
}

#[test]
fn data_retry_none_leaves_a_selected_provider_alone() {
    let files = [
        ("products/$productId/data.dart", SELECT_ONE),
        ("products/$productId/page.dart", PRODUCT),
    ];
    let cfg = Config {
        data_retry: DataRetry::None,
        ..Config::default()
    };
    // Nothing of ours to configure: the app's provider keeps its own retry and keepAlive.
    lacks(
        &code_with(&cfg, &files),
        &["retryCount", "No automatic retry"],
    );
}

#[test]
fn a_selector_keyed_by_a_catch_all_gets_the_list_back() {
    // Lists compare by identity, so the key is the encoded path as one string, as in the
    // function form; the app's own function gets the parts back.
    let data = "ProviderListenable<AsyncValue<Article>> data({required List<String> rest, int? page}) => articleProvider(rest, page);";
    let p = "class DocsPage extends StatelessWidget { const DocsPage({super.key, required this.rest, required this.article}); final List<String> rest; final Article article; }";
    let c = code(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    has(
        &c,
        &[
            "final _data2 = (({String rest, int? page}) k) => _i0.data(rest: restParts(k.rest), page: k.page);",
            "ref.watch(_data2((rest: restKey(v.rest), page: v.page)))",
            "ref.invalidateSelected(_data2((rest: restKey(v.rest), page: v.page)))",
            "Future<void> refresh(WidgetRef ref) => ref.refreshSelected(data((rest: restKey(rest), page: page)));",
        ],
    );
    lacks(&c, &["QueryList"]);

    // Alone, the key is the string itself.
    let data = "ProviderListenable<AsyncValue<Article>> data({required List<String> rest}) => articleProvider(rest);";
    let c = code(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    has(
        &c,
        &[
            "final _data2 = (String rest) => _i0.data(rest: restParts(rest));",
            "ref.watch(_data2(restKey(v.rest)))",
        ],
    );
}
