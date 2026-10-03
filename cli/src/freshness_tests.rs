//! Data freshness and the data cache (since 0.8.1): `const freshness = Freshness(...)` in a
//! data.dart or a route.dart (the default of every `data()` function at and below its folder), and
//! `final dataCache = DataCache(...)` in a data.dart. The generator never reads their values: it
//! emits `freshData(...)` / `cachedData(...)` around the provider and refers to the variables,
//! which Dart type-checks.

use std::fs;

use crate::config::{Config, DataRetry};
use crate::{analyze, build, routes};

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

/// Every diagnostic, as the CLI prints it: `✗ file:line  message` or `! file:line  message`.
fn diags(cfg: &Config, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    diags(&Config::default(), files)
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

/// The code with every run of whitespace a single space, so indentation doesn't matter.
fn flat(code: &str) -> String {
    code.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn has(code: &str, needles: &[&str]) {
    let flat_code = flat(code);
    for n in needles {
        assert!(flat_code.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn lacks(code: &str, needles: &[&str]) {
    let flat_code = flat(code);
    for n in needles {
        assert!(
            !flat_code.contains(&flat(n)),
            "unexpected `{n}` in:\n{code}"
        );
    }
}

fn widget(class: &str, fields: &str, params: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key{params}}}); {fields} }}"
    )
}

fn home() -> String {
    widget("HomePage", "", "")
}

/// A page of `/items/:id` that takes the `String` its data.dart yields.
fn item_page() -> String {
    named_item_page("Item")
}

fn named_item_page(name: &str) -> String {
    widget(
        &format!("{name}Page"),
        "final int id; final String label;",
        ", required this.id, required this.label",
    )
}

const ITEM_DATA: &str = "Future<String> data(Ref ref, {required int id}) async => 'x';";

const FRESH: &str = "const freshness = Freshness(staleTime: Duration(minutes: 1));\n";

fn item_data(extra: &str) -> String {
    format!("{extra}\n{ITEM_DATA}")
}

/// The matching line of the route table: `/a  ARoute  a/page.dart  (data, fresh)`.
fn table_row(code: &str, pattern: &str) -> String {
    code.lines()
        .find(|l| l.starts_with(&format!("//   {pattern} ")))
        .unwrap_or_else(|| panic!("no row for {pattern} in:\n{code}"))
        .to_string()
}

// ---- a data.dart's own freshness ----

#[test]
fn freshness_wraps_the_value_and_keeps_the_page_on_a_failed_reload() {
    let c = code(&[
        ("page.dart", &home()),
        ("items/$id/page.dart", &item_page()),
        ("items/$id/data.dart", &item_data(FRESH)),
    ]);
    has(
        &c,
        &[
            "final _data2 = FutureProvider.autoDispose.family(",
            "(Ref ref, int id) => freshData(ref, _i1.freshness, traceData(ref, 'd2', id, _i1.data(ref, id: id))),",
            "keepDataOnError: true,",
        ],
    );
    assert!(table_row(&c, "/items/:id").contains("(data, fresh)"), "{c}");
    lacks(&c, &["cachedData"]);
}

#[test]
fn a_synchronous_data_function_may_have_one() {
    let c = code(&[
        ("page.dart", &home()),
        (
            "n/page.dart",
            &widget("NPage", "final int n;", ", required this.n"),
        ),
        ("n/data.dart", &format!("{FRESH}\nint data(Ref ref) => 1;")),
    ]);
    has(
        &c,
        &["(Ref ref) => freshData(ref, _i1.freshness, traceData(ref, 'd1', null, _i1.data(ref)))"],
    );
}

#[test]
fn freshness_may_be_const_prefixed_or_a_final() {
    for init in [
        "const freshness = Freshness(staleTime: Duration(minutes: 1));",
        "final freshness = Freshness(staleTime: Duration(minutes: 1));",
        "const freshness = const Freshness(staleTime: Duration(minutes: 1));",
        "const freshness = fp.Freshness(staleTime: Duration(minutes: 1));",
        "const freshness = Freshness();",
    ] {
        let c = code(&[
            ("page.dart", &home()),
            ("items/$id/page.dart", &item_page()),
            ("items/$id/data.dart", &item_data(init)),
        ]);
        has(&c, &["freshData(ref, _i1.freshness"]);
    }
}

// ---- a route.dart's freshness: the default below it ----

fn tree_with_route(route: &str) -> Vec<(&'static str, String)> {
    vec![
        ("page.dart", home()),
        ("teams/route.dart", route.to_string()),
        ("teams/$id/page.dart", item_page()),
        ("teams/$id/data.dart", ITEM_DATA.to_string()),
        ("teams/$id/tasks/page.dart", widget("TasksPage", "", "")),
    ]
}

fn borrowed<'a>(files: &'a [(&'static str, String)]) -> Vec<(&'a str, &'a str)> {
    files.iter().map(|(p, b)| (*p, b.as_str())).collect()
}

#[test]
fn route_dart_is_the_default_of_the_data_below_and_is_imported_only_then() {
    let files = tree_with_route(FRESH);
    let c = code(&borrowed(&files));
    // The data.dart is `_i1`, the page `_i2`, and the route.dart is imported after them, for this.
    has(
        &c,
        &[
            "freshData(ref, _i3.freshness, traceData(ref, 'd2', id, _i1.data(ref, id: id)))",
            "keepDataOnError: true,",
        ],
    );
    has(&c, &["teams/route.dart' as _i3"]);
    assert!(table_row(&c, "/teams/:id").contains("(data, fresh)"), "{c}");
}

#[test]
fn the_nearest_route_dart_wins_and_a_data_dart_beats_both() {
    let files = [
        ("page.dart", home()),
        (
            "route.dart",
            "const freshness = Freshness(staleTime: Duration(days: 1));".to_string(),
        ),
        ("a/route.dart", FRESH.to_string()),
        ("a/$id/page.dart", named_item_page("A")),
        ("a/$id/data.dart", ITEM_DATA.to_string()),
        ("b/$id/page.dart", named_item_page("B")),
        (
            "b/$id/data.dart",
            item_data("const freshness = Freshness();"),
        ),
    ];
    let dir = project(&borrowed(&files));
    let (c, all, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    // One `freshData` per data.dart: `a`'s from `a/route.dart`, `b`'s from its own.
    assert_eq!(c.matches("freshData(ref, ").count(), 2, "{c}");
    has(&c, &["a/route.dart' as", "b/\\$id/data.dart' as"]);
    // The root route.dart is overridden everywhere it could apply, so it applies to nothing.
    assert_eq!(all.0.len(), 1, "{:?}", all.0);
    assert!(
        all.0[0]
            .to_string()
            .starts_with("! route.dart:1  `freshness` here applies to no data.dart"),
        "{:?}",
        all.0
    );
}

#[test]
fn a_selector_a_provider_and_a_stream_below_skip_it_silently() {
    let files = [
        ("page.dart", home()),
        ("route.dart", FRESH.to_string()),
        (
            "sel/page.dart",
            widget("SelPage", "final int n;", ", required this.n"),
        ),
        (
            "sel/data.dart",
            "final countProvider = FutureProvider<int>((ref) async => 1);\nProviderListenable<AsyncValue<int>> data() => countProvider;".to_string(),
        ),
        (
            "prov/page.dart",
            widget("ProvPage", "final int n;", ", required this.n"),
        ),
        (
            "prov/data.dart",
            "final data = FutureProvider<int>((ref) async => 1);".to_string(),
        ),
        (
            "live/page.dart",
            widget("LivePage", "final int n;", ", required this.n"),
        ),
        (
            "live/data.dart",
            "Stream<int> data(Ref ref) => Stream.value(1);".to_string(),
        ),
        (
            "once/page.dart",
            widget("OncePage", "final int n;", ", required this.n"),
        ),
        (
            "once/data.dart",
            "Future<int> data(Ref ref) async => 1;".to_string(),
        ),
    ];
    // Not a warning either: it covers `once`.
    let c = code(&borrowed(&files));
    assert_eq!(c.matches("freshData(ref, ").count(), 1, "{c}");
    assert!(table_row(&c, "/once").contains("fresh"), "{c}");
    for skipped in ["/sel", "/prov", "/live"] {
        assert!(!table_row(&c, skipped).contains("fresh"), "{c}");
    }
}

#[test]
fn a_route_dart_freshness_that_covers_nothing_is_a_warning() {
    let files = [
        ("page.dart", home()),
        ("a/route.dart", FRESH.to_string()),
        ("a/page.dart", widget("APage", "", "")),
    ];
    let all = diags(&Config::default(), &borrowed(&files));
    assert_eq!(
        all,
        vec![
            "! a/route.dart:1  `freshness` here applies to no data.dart: none at or below this folder is a data() function that returns a Future or a value without a `freshness` of its own; drop it"
        ]
    );
}

// ---- the diagnostics ----

fn data_error(data: &str, page: &str) -> Vec<String> {
    errors(&[
        ("page.dart", &home()),
        ("n/page.dart", page),
        ("n/data.dart", data),
    ])
}

fn int_page() -> String {
    widget("NPage", "final int n;", ", required this.n")
}

#[test]
fn e1_to_e2_freshness_must_be_one_call_and_declared_once() {
    let e = data_error(
        "const freshness = Duration(minutes: 1);\nFuture<int> data(Ref ref) async => 1;",
        &int_page(),
    );
    assert_eq!(
        e,
        vec![
            "✗ n/data.dart:1  `freshness` must be a `Freshness(...)`: write `const freshness = Freshness(staleTime: Duration(minutes: 5));`"
        ]
    );
    let e = data_error(
        &format!("{FRESH}const freshness = Freshness();\nFuture<int> data(Ref ref) async => 1;"),
        &int_page(),
    );
    assert_eq!(e, vec!["✗ n/data.dart:2  `freshness` is declared twice"]);
}

#[test]
fn e3_to_e5_freshness_is_for_a_function_that_loads_once() {
    let stream = data_error(
        &format!("{FRESH}Stream<int> data(Ref ref) => Stream.value(1);"),
        &int_page(),
    );
    assert_eq!(
        stream,
        vec![
            "✗ n/data.dart:1  `freshness` is for a data() that loads once, and this one returns a `Stream`, which is live: nothing in it goes stale. Drop `freshness`, or return a `Future`"
        ]
    );
    let selector = data_error(
        &format!(
            "final p = FutureProvider<int>((ref) async => 1);\n{FRESH}ProviderListenable<AsyncValue<int>> data() => p;"
        ),
        &int_page(),
    );
    assert_eq!(
        selector,
        vec![
            "✗ n/data.dart:2  `freshness` applies to the provider fespalier makes of a data() function, and this data.dart selects a provider of your own; call `freshData(ref, const Freshness(...), value)` inside that provider instead"
        ]
    );
    let provider = data_error(
        &format!("{FRESH}final data = FutureProvider<int>((ref) async => 1);"),
        &int_page(),
    );
    assert_eq!(
        provider,
        vec![
            "✗ n/data.dart:1  `freshness` applies to the provider fespalier makes of a data() function, and this data.dart exports its own `data` provider; call `freshData(ref, const Freshness(...), value)` inside it instead"
        ]
    );
}

const CACHE: &str =
    "final dataCache = DataCache<String>.json(toJson: (v) => v, fromJson: (j) => j! as String);\n";

#[test]
fn e6_to_e10_data_cache() {
    let bad = data_error(
        "final dataCache = 3;\nFuture<int> data(Ref ref) async => 1;",
        &int_page(),
    );
    assert_eq!(
        bad,
        vec![
            "✗ n/data.dart:1  `dataCache` must be a `DataCache(...)` or `DataCache.json(...)`: write `final dataCache = DataCache<Product>.json(toJson: ..., fromJson: ...);`"
        ]
    );
    let twice = data_error(
        &format!("{CACHE}{CACHE}Future<String> data(Ref ref) async => '';"),
        &widget("NPage", "final String n;", ", required this.n"),
    );
    assert_eq!(
        twice,
        vec!["✗ n/data.dart:2  `dataCache` is declared twice"]
    );
    let stream = data_error(
        &format!("{CACHE}Stream<int> data(Ref ref) => Stream.value(1);"),
        &int_page(),
    );
    assert_eq!(
        stream,
        vec![
            "✗ n/data.dart:1  `dataCache` saves the last value of a data() that loads once, and this one returns a `Stream`; drop `dataCache`, or return a `Future`"
        ]
    );
    let selector = data_error(
        &format!(
            "final p = FutureProvider<int>((ref) async => 1);\n{CACHE}ProviderListenable<AsyncValue<int>> data() => p;"
        ),
        &int_page(),
    );
    assert_eq!(
        selector,
        vec![
            "✗ n/data.dart:2  `dataCache` applies to the provider fespalier makes of a data() function, and this data.dart selects a provider of your own; persist that provider with Riverpod's `persist` (from package:fespalier/persist.dart) instead"
        ]
    );
    let provider = data_error(
        &format!("{CACHE}final data = FutureProvider<int>((ref) async => 1);"),
        &int_page(),
    );
    assert_eq!(
        provider,
        vec![
            "✗ n/data.dart:1  `dataCache` applies to the provider fespalier makes of a data() function, and this data.dart exports its own `data` provider; persist it with Riverpod's `persist` (from package:fespalier/persist.dart) instead"
        ]
    );
}

#[test]
fn route_dart_errors_e1_e2_e11_and_e12() {
    let e = |route: &str| {
        errors(&[
            ("page.dart", &home()),
            ("a/route.dart", route),
            ("a/page.dart", &widget("APage", "", "")),
        ])
    };
    assert_eq!(
        e("const freshness = 5;"),
        vec![
            "✗ a/route.dart:1  `freshness` must be a `Freshness(...)`: write `const freshness = Freshness(staleTime: Duration(minutes: 5));`"
        ]
    );
    assert_eq!(
        e(&format!("{FRESH}{FRESH}")),
        vec!["✗ a/route.dart:2  `freshness` is declared twice"]
    );
    let e11 = e(&format!(
        "{FRESH}final dataCache = DataCache<int>.json(toJson: (v) => v, fromJson: (j) => j! as int);"
    ));
    assert_eq!(
        e11,
        vec![
            "✗ a/route.dart:2  `dataCache` belongs in the data.dart whose value it saves, not in a route.dart: each data type has its own encode and decode"
        ]
    );
    assert_eq!(
        e("const unknown = 1;"),
        vec![
            "✗ a/route.dart  expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;`, `const deferred = true;` or `const freshness = Freshness(staleTime: Duration(minutes: 5));`"
        ]
    );
}

// ---- the cache ----

fn cached(keys_data: &str, route_dir: &str, page: &str) -> String {
    code(&[
        ("page.dart", &home()),
        (&format!("{route_dir}/page.dart"), page),
        (&format!("{route_dir}/data.dart"), keys_data),
    ])
}

#[test]
fn a_cache_without_keys_is_cached_data() {
    let c = cached(
        &format!("{CACHE}Future<String> data(Ref ref) async => '';"),
        "motd",
        &widget("MotdPage", "final String text;", ", required this.text"),
    );
    has(
        &c,
        &[
            "final _data1 = cachedData(",
            "(Ref ref) => traceData(ref, 'd1', null, _i1.data(ref)),",
            "cache: _i1.dataCache,",
            "name: 'motd',",
            "keepDataOnError: true,",
        ],
    );
    lacks(&c, &["keyParts", "freshData", "FutureProvider.autoDispose"]);
    assert!(table_row(&c, "/motd").contains("(data, cached)"), "{c}");
}

#[test]
fn a_cache_with_one_key_lists_it_and_escapes_the_name() {
    let c = cached(
        &format!("{CACHE}Future<String> data(Ref ref, {{required int id}}) async => '';"),
        "products/$id",
        &item_page(),
    );
    has(
        &c,
        &[
            "final _data2 = cachedDataFamily(",
            "(Ref ref, int id) => traceData(ref, 'd2', id, _i1.data(ref, id: id)),",
            "name: 'products/\\$id',",
            "keyParts: (int id) => [id],",
        ],
    );
}

#[test]
fn a_cache_with_several_keys_lists_them_in_path_order() {
    let c = code(&[
        ("page.dart", &home()),
        (
            "shops/$shop/items/$id/page.dart",
            &widget(
                "ItemPage",
                "final String shop; final int id; final String label;",
                ", required this.shop, required this.id, required this.label",
            ),
        ),
        (
            "shops/$shop/items/$id/data.dart",
            &format!(
                "{CACHE}Future<String> data(Ref ref, {{required int id, required String shop}}) async => '';"
            ),
        ),
    ]);
    has(
        &c,
        &["keyParts: (({String shop, int id}) k) => [k.shop, k.id],"],
    );
}

#[test]
fn a_catch_all_and_a_query_list_key_the_cache_by_what_the_provider_is_keyed_by() {
    let c = code(&[
        ("page.dart", &home()),
        (
            "docs/$$path/page.dart",
            &widget(
                "DocPage",
                "final List<String> path; final String body;",
                ", required this.path, required this.body",
            ),
        ),
        (
            "docs/$$path/data.dart",
            &format!(
                "{CACHE}Future<String> data(Ref ref, {{required List<String> path}}) async => '';"
            ),
        ),
        (
            "find/page.dart",
            &widget(
                "FindPage",
                "final List<String>? tags; final String body;",
                ", this.tags, required this.body",
            ),
        ),
        (
            "find/data.dart",
            &format!("{CACHE}Future<String> data(Ref ref, {{List<String>? tags}}) async => '';"),
        ),
    ]);
    has(
        &c,
        &[
            "keyParts: (String path) => [path],",
            "keyParts: (QueryList<String> tags) => [tags],",
        ],
    );
}

#[test]
fn retry_none_and_freshness_go_with_the_cache() {
    let cfg = Config {
        data_retry: DataRetry::None,
        ..Config::default()
    };
    let c = code_with(
        &cfg,
        &[
            ("page.dart", &home()),
            ("items/$id/page.dart", &item_page()),
            (
                "items/$id/data.dart",
                &item_data(&format!("{CACHE}{FRESH}")),
            ),
        ],
    );
    has(
        &c,
        &[
            "final _data2 = cachedDataFamily(",
            "cache: _i1.dataCache,",
            "freshness: _i1.freshness,",
            "// No automatic retry: error.dart and its Retry button are the retry UX.",
            "retry: (retryCount, error) => null,",
        ],
    );
    assert!(
        table_row(&c, "/items/:id").contains("(data, fresh, cached)"),
        "{c}"
    );
    lacks(&c, &["freshData("]);
}

// ---- sections, and apps that opt in to nothing ----

#[test]
fn a_section_with_freshness_keeps_its_layout_on_the_value() {
    let c = code(&[
        ("page.dart", &home()),
        (
            "teams/$id/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final String label;",
                ", required this.child, required this.label",
            ),
        ),
        ("teams/$id/data.dart", &item_data(FRESH)),
        ("teams/$id/info/page.dart", &widget("InfoPage", "", "")),
    ]);
    has(&c, &["freshData(ref, _i", "keepDataOnError: true,"]);
}

#[test]
fn an_app_that_opts_in_to_nothing_is_as_it_was() {
    let c = code(&[
        ("page.dart", &home()),
        ("items/$id/page.dart", &item_page()),
        ("items/$id/data.dart", ITEM_DATA),
    ]);
    lacks(
        &c,
        &[
            "freshData",
            "cachedData",
            "keepDataOnError",
            "freshness",
            "dataCache",
            ", fresh",
            "cached)",
        ],
    );
    has(
        &c,
        &["(Ref ref, int id) => traceData(ref, 'd2', id, _i1.data(ref, id: id)),"],
    );
}

// ---- fsp routes --json ----

#[test]
fn routes_json_has_the_fields_only_for_opted_in_routes() {
    let dir = project(&[
        ("page.dart", &home()),
        ("a/route.dart", FRESH),
        ("a/$id/page.dart", &named_item_page("A")),
        ("a/$id/data.dart", ITEM_DATA),
        ("b/$id/page.dart", &named_item_page("B")),
        (
            "b/$id/data.dart",
            &item_data(&format!("{CACHE}const freshness = Freshness();")),
        ),
        ("c/$id/page.dart", &named_item_page("C")),
        ("c/$id/data.dart", ITEM_DATA),
    ]);
    let (_, d, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(d.0.is_empty(), "{:?}", d.0);
    let rows: Vec<serde_json::Value> = routes::json_lines(&app, "lib/app")
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |pattern: &str| rows.iter().find(|r| r["pattern"] == pattern).unwrap();
    assert_eq!(by("/a/:id")["freshness"], "lib/app/a/route.dart");
    assert!(by("/a/:id").get("cache").is_none());
    assert_eq!(by("/b/:id")["freshness"], "lib/app/b/$id/data.dart");
    assert_eq!(by("/b/:id")["cache"], true);
    assert_eq!(
        by("/b/:id")["tags"].to_string(),
        "[\"data\",\"fresh\",\"cached\"]"
    );
    assert!(by("/c/:id").get("freshness").is_none());
    assert!(by("/c/:id").get("cache").is_none());
    assert!(by("/").get("freshness").is_none());
}
