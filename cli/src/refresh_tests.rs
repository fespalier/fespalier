//! `data_retry` and `keep_previous` in the `fespalier:` config, and `List` query
//! parameters as `data()` keys. (The rest of the generator's tests are in `tests.rs`.)

use std::fs;

use crate::build;
use crate::config::{Config, DataRetry, Pubspec};

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

fn config(yaml: &str) -> anyhow::Result<Config> {
    Ok(Pubspec::parse(yaml)?.config)
}

const PAGE: &str =
    "class APage extends StatelessWidget { const APage(this.n, {super.key}); final int n; }";

const HOME: &str = "class APage extends StatelessWidget { const APage({super.key}); }";

#[test]
fn config_keys_default_to_inherit_and_keep() {
    let c = Config::default();
    assert_eq!((c.data_retry, c.keep_previous), (DataRetry::Inherit, true));
    assert_eq!(
        config("name: demo\nfespalier:\n  format: true\n")
            .unwrap()
            .data_retry,
        DataRetry::Inherit
    );

    let c = config("fespalier:\n  data_retry: none\n  keep_previous: false\n").unwrap();
    assert_eq!((c.data_retry, c.keep_previous), (DataRetry::None, false));
    let c = config("fespalier:\n  data_retry: inherit\n  keep_previous: true\n").unwrap();
    assert_eq!(c, Config::default());
}

#[test]
fn config_rejects_unknown_values() {
    let e = format!(
        "{:#}",
        config("fespalier:\n  data_retry: always\n").unwrap_err()
    );
    assert!(
        e.contains("unknown variant `always`") && e.contains("inherit") && e.contains("none"),
        "{e}"
    );
    let e = format!(
        "{:#}",
        config("fespalier:\n  keep_previous: sometimes\n").unwrap_err()
    );
    assert!(
        e.contains("invalid type") || e.contains("expected a boolean"),
        "{e}"
    );
}

#[test]
fn push_updates_url_parses_and_defaults_to_off() {
    assert!(!Config::default().push_updates_url);
    assert!(!config("name: demo\n").unwrap().push_updates_url);
    assert!(
        !config("fespalier:\n  format: true\n")
            .unwrap()
            .push_updates_url
    );
    let c = config("fespalier:\n  push_updates_url: true\n").unwrap();
    assert!(c.push_updates_url);
    let c = config("fespalier:\n  push_updates_url: false\n").unwrap();
    assert_eq!(c, Config::default());
}

#[test]
fn push_updates_url_rejects_other_values() {
    let e = format!(
        "{:#}",
        config("fespalier:\n  push_updates_url: sometimes\n").unwrap_err()
    );
    assert!(
        e.contains("invalid type") || e.contains("expected a boolean"),
        "{e}"
    );
    // The unknown-key message lists it, so a misspelling points at the right name.
    let e = format!(
        "{:#}",
        config("fespalier:\n  push_update_url: true\n").unwrap_err()
    );
    assert!(
        e.contains("unknown field `push_update_url`") && e.contains("`push_updates_url`"),
        "{e}"
    );
}

#[test]
fn router_assigns_the_url_reflection_explicitly() {
    let files = [("a/page.dart", HOME)];
    let assign = "GoRouter.optionURLReflectsImperativeAPIs = ";
    let c = code(&files);
    has(&c, &[&format!("{assign}false;")]);
    lacks(&c, &[&format!("{assign}true;")]);

    let cfg = Config {
        push_updates_url: true,
        ..Config::default()
    };
    let c = code_with(&cfg, &files);
    has(&c, &[&format!("{assign}true;")]);
    lacks(&c, &[&format!("{assign}false;")]);
    // The assignment comes before the router is built, in `router()` only.
    assert_eq!(c.matches(assign).count(), 1, "{c}");
    assert!(c.find(assign) < c.find("final router = GoRouter("), "{c}");
}

#[test]
fn replace_goes_through_the_runtime_helper() {
    let c = code(&[
        ("a/page.dart", HOME),
        (
            "n/$id/page.dart",
            "class NPage extends StatelessWidget { const NPage({super.key, required this.id, this.extra}); final int id; final String? extra; }",
        ),
    ]);
    has(
        &c,
        &["replaceLocation(context, locationFor(locale), extra: extra)"],
    );
    lacks(&c, &["context.replace("]);
}

#[test]
fn the_pubspec_push_updates_url_reaches_the_generated_file() {
    let dir = project(&[("a/page.dart", HOME)]);
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  push_updates_url: true\n",
    )
    .unwrap();
    crate::gen_with(dir.path(), &Config::load(dir.path()).unwrap(), true).unwrap();
    let c = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(&c, &["GoRouter.optionURLReflectsImperativeAPIs = true;"]);
}

#[test]
fn data_views_keep_the_previous_state_unless_told_not_to() {
    let files = [
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("a/page.dart", PAGE),
        (
            "b/layout.dart",
            "class BLayout extends StatelessWidget { const BLayout({super.key, required this.child}); final Widget child; }",
        ),
        ("b/data.dart", "Future<int> data(Ref ref) async => 1;"),
        (
            "b/c/page.dart",
            "class CPage extends StatelessWidget { const CPage({super.key}); }",
        ),
    ];
    let c = code(&files);
    assert_eq!(c.matches("keepPrevious: true,").count(), 2, "{c}");
    lacks(&c, &["keepPrevious: false"]);

    let cfg = Config {
        keep_previous: false,
        ..Config::default()
    };
    let c = code_with(&cfg, &files);
    assert_eq!(c.matches("keepPrevious: false,").count(), 2, "{c}");
    lacks(&c, &["keepPrevious: true"]);
}

#[test]
fn data_retry_none_gives_providers_a_null_retry() {
    let files = [
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("a/page.dart", PAGE),
        (
            "$id/data.dart",
            "Stream<int> data(Ref ref, {required int id}) => Stream.value(id);",
        ),
        (
            "$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage(this.n, {super.key}); final int n; }",
        ),
    ];
    let c = code(&files);
    lacks(
        &c,
        &["retry: (retryCount, error) => null", "No automatic retry"],
    );
    has(
        &c,
        &["final _data2 = FutureProvider.autoDispose(\n  (Ref ref) => _i2.data(ref),\n);"],
    );

    let cfg = Config {
        data_retry: DataRetry::None,
        ..Config::default()
    };
    let c = code_with(&cfg, &files);
    assert_eq!(
        c.matches("  retry: (retryCount, error) => null,\n);")
            .count(),
        2,
        "{c}"
    );
    has(
        &c,
        &[
            "final _data2 = FutureProvider.autoDispose(\n  (Ref ref) => _i2.data(ref),\n  // No automatic retry: error.dart and its Retry button are the retry UX.\n  retry: (retryCount, error) => null,\n);",
            "= StreamProvider.autoDispose.family(",
        ],
    );

    // A provider the user wrote is theirs, whatever the setting says.
    let c = code_with(
        &cfg,
        &[
            (
                "data.dart",
                "final data = FutureProvider<int>((ref) async => 1);",
            ),
            ("page.dart", PAGE),
        ],
    );
    lacks(&c, &["retryCount"]);
}

#[test]
fn a_list_query_parameter_keys_data_by_value() {
    let c = code(&[
        (
            "search/data.dart",
            "Future<List<String>> data(Ref ref, {String? q, List<String> tags = const []}) async => [];",
        ),
        (
            "search/page.dart",
            "class SearchPage extends StatelessWidget {\n  const SearchPage({super.key, required this.results, this.q, this.tags = const []});\n  final List<String> results; final String? q; final List<String> tags;\n}",
        ),
    ]);
    has(
        &c,
        &[
            // The family key holds a QueryList; data() gets it as the List it is.
            "(Ref ref, ({String? q, QueryList<String> tags}) k) => _i0.data(ref, q: k.q, tags: k.tags),",
            "watch: (ref) => ref.watch(_data1((q: v.q, tags: QueryList(v.tags)))),",
            "data: (d) => _i1.SearchPage(results: d, q: v.q, tags: v.tags),",
            "/// search/data.dart as a Riverpod provider keyed by `(q, tags)`.",
            // The typed helpers take the plain list (empty by default) and wrap it.
            "static final watch = (WidgetRef ref, {String? q, List<String> tags = const []}) => ref.watch(data((q: q, tags: QueryList(tags))));",
            "static final read = (WidgetRef ref, {String? q, List<String> tags = const []}) => ref.readData(data((q: q, tags: QueryList(tags))));",
            "Future<void> refresh(WidgetRef ref) => ref.refresh(data((q: q, tags: QueryList(tags))).future);",
        ],
    );
}

#[test]
fn the_pubspec_reaches_the_generated_file() {
    let dir = project(&[
        ("a/data.dart", "Future<int> data(Ref ref) async => 1;"),
        ("a/page.dart", PAGE),
    ]);
    let yaml = "name: demo\nfespalier:\n  data_retry: none\n  keep_previous: false\n";
    fs::write(dir.path().join("pubspec.yaml"), yaml).unwrap();
    let o = crate::gen_with(dir.path(), &Config::load(dir.path()).unwrap(), true).unwrap();
    assert!(o.wrote);
    let c = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    has(
        &c,
        &[
            "keepPrevious: false,",
            "retry: (retryCount, error) => null,",
        ],
    );
}

#[test]
fn a_lone_list_key_and_other_element_types() {
    let c = code(&[
        (
            "a/data.dart",
            "Future<int> data(Ref ref, {List<int> ids = const []}) async => 1;",
        ),
        ("a/page.dart", PAGE),
    ]);
    has(
        &c,
        &[
            "(Ref ref, QueryList<int> ids) => _i0.data(ref, ids: ids),",
            "ref.watch(_data1(QueryList(v.ids)))",
            "/// a/data.dart as a Riverpod provider keyed by `ids`.",
            "static final watch = (WidgetRef ref, {List<int> ids = const []}) => ref.watch(data(QueryList(ids)));",
        ],
    );
    // Only `data()` parameters that are lists are wrapped.
    let c = code(&[
        (
            "a/data.dart",
            "Future<int> data(Ref ref, {int? page}) async => 1;",
        ),
        ("a/page.dart", PAGE),
    ]);
    lacks(&c, &["QueryList"]);
}
