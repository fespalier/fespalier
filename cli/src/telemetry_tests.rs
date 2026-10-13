//! `telemetry: true` (since 0.8.1): the generated file tells the runtime where each guard, data
//! provider, action and deferred library is, with a `const TelemetrySite`, and attaches
//! telemetry to the router. Off, which is the default, the file is what it always was.

use std::fs;
use std::path::{Path, PathBuf};

use crate::config::{Config, Pubspec};

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
}

/// The generated code of an example with `telemetry` set to `on`.
fn example(name: &str, on: bool) -> String {
    let cfg = Config {
        telemetry: on,
        ..Config::load(&examples(name)).unwrap()
    };
    let (code, diags, _) = crate::analyze(&examples(name).join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

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

fn code_with(telemetry: bool, files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let cfg = Config {
        telemetry,
        ..Config::default()
    };
    let (code, diags, _) = crate::build(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn flat(code: &str) -> String {
    code.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn has(code: &str, needles: &[&str]) {
    let flat_code = flat(code);
    for n in needles {
        assert!(flat_code.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id, required this.data}); final int id; final String data; }".into()
}

// ---- the config ----

#[test]
fn the_key_is_off_by_default_and_a_bool() {
    assert!(!Config::default().telemetry);
    let cfg = |yaml: &str| Pubspec::parse(yaml).map(|p| p.config);
    assert!(!cfg("name: demo\n").unwrap().telemetry);
    assert!(!cfg("fespalier:\n  telemetry: false\n").unwrap().telemetry);
    assert!(cfg("fespalier:\n  telemetry: true\n").unwrap().telemetry);
}

#[test]
fn o8_a_value_that_is_not_a_bool_is_refused() {
    let e = format!(
        "{:#}",
        Pubspec::parse("fespalier:\n  telemetry: yes please\n").unwrap_err()
    );
    assert!(
        e.contains("invalid type: string \"yes please\", expected a boolean"),
        "{e}"
    );
}

// ---- off means unchanged ----

#[test]
fn off_is_the_committed_output() {
    for name in ["shop", "features", "tabs"] {
        let committed = fs::read_to_string(examples(name).join("lib/app.g.dart")).unwrap();
        assert_eq!(example(name, false), committed, "{name}");
        assert!(!committed.contains("Telemetry"), "{name}");
        assert!(!committed.contains("telemetry"), "{name}");
        assert!(!committed.contains("static void attach"), "{name}");
        // The data providers are `traceData(..., data(...))`, as before 0.9.0.
        assert!(!committed.contains("traceDataCall"), "{name}");
        if name != "tabs" {
            assert!(committed.contains("traceData(ref, '"), "{name}");
        }
    }
}

// ---- on ----

#[test]
fn every_guard_data_provider_and_action_is_told_where_it_is() {
    let on = example("shop", true);
    // Every traced call carries its site.
    // Since 0.9.0 the data call is a closure the sink may run its span around.
    for needle in ["traceGuard(", "traceDataCall("] {
        let calls: Vec<&str> = on.lines().filter(|l| l.contains(needle)).collect();
        assert!(!calls.is_empty(), "no {needle} in the shop");
        for l in calls {
            assert!(l.contains("telemetry: const TelemetrySite("), "{l}");
        }
    }
    // Every action is, on the line after its `site:`.
    let features = example("features", true);
    let lines: Vec<&str> = features.lines().collect();
    let mut actions = 0;
    for (i, l) in lines.iter().enumerate() {
        if l.trim_start().starts_with("site: 'a") {
            actions += 1;
            assert!(
                lines[i + 1]
                    .trim_start()
                    .starts_with("telemetry: const TelemetrySite("),
                "{}",
                lines[i + 1]
            );
            assert!(lines[i + 1].contains(", name: '"), "{}", lines[i + 1]);
        }
    }
    assert!(actions > 0);
    // Every deferred library knows its page's pattern.
    for l in on.lines().filter(|l| l.contains("= DeferredLibrary(")) {
        assert!(l.contains(", route: '/"), "{l}");
    }
    has(
        &on,
        &[
            "static void attach(GoRouter router, [ProviderContainer? container]) {",
            "if (kFespalierDevTools) devToolsAttach(router);",
            "telemetryAttach(router, base: () => _base);",
            "attach(router);",
        ],
    );
}

#[test]
fn a_site_names_its_file_and_the_pattern_of_its_route() {
    let c = code_with(
        true,
        &[
            ("page.dart", &page("Home")),
            ("items/$id/page.dart", &item()),
            (
                "items/$id/data.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<String> data(Ref ref, {required int id}) async => 'x';",
            ),
            (
                "items/$id/guard.dart",
                "import 'package:fespalier/fespalier.dart';\nGuardResult guard(Ref ref, {required int id}) => null;",
            ),
            (
                "items/$id/action.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<void> rename(Ref ref, {required int id, required String input}) async {}",
            ),
        ],
    );
    has(
        &c,
        &[
            // `$` in a file name is escaped, as in every Dart string the generator writes.
            "telemetry: const TelemetrySite('items/\\$id/data.dart', route: '/items/:id')",
            "telemetry: const TelemetrySite('items/\\$id/guard.dart', route: '/items/:id')",
            "telemetry: const TelemetrySite('items/\\$id/action.dart', route: '/items/:id', name: 'rename')",
        ],
    );
}

#[test]
fn a_section_names_its_folders_pattern() {
    let c = code_with(
        true,
        &[
            (
                "teams/$teamId/layout.dart",
                "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.child, required this.data}); final Widget child; final String data; }",
            ),
            (
                "teams/$teamId/data.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<String> data(Ref ref, {required String teamId}) async => 'x';",
            ),
            (
                "teams/$teamId/action.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<void> rename(Ref ref, {required String teamId, required String input}) async {}",
            ),
            ("teams/$teamId/members/page.dart", &page("Members")),
        ],
    );
    has(
        &c,
        &[
            "telemetry: const TelemetrySite('teams/\\$teamId/data.dart', route: '/teams/:teamId')",
            "telemetry: const TelemetrySite('teams/\\$teamId/action.dart', route: '/teams/:teamId', name: 'rename')",
        ],
    );
}

#[test]
fn a_redirect_and_an_inherited_guard_are_told_apart() {
    let c = code_with(
        true,
        &[
            ("page.dart", &page("Home")),
            (
                "(members)/guard.dart",
                "import 'package:fespalier/fespalier.dart';\nGuardResult guard(Ref ref) => null;",
            ),
            ("(members)/account/page.dart", &page("Account")),
            ("old/redirect.dart", "String redirect() => '/';"),
        ],
    );
    has(
        &c,
        &[
            // The guard sits in a page-less folder; the span is the route it guards.
            "telemetry: const TelemetrySite('(members)/guard.dart', route: '/account')",
            "telemetry: const TelemetrySite('old/redirect.dart', route: '/old')",
        ],
    );
}

#[test]
fn a_tree_without_guards_data_or_actions_only_attaches() {
    let c = code_with(true, &[("page.dart", &page("Home"))]);
    has(&c, &["telemetryAttach(router, base: () => _base);"]);
    assert!(!c.contains("TelemetrySite("), "{c}");
    assert!(!c.contains("observeAttach"), "{c}");
}

#[test]
fn observe_and_telemetry_share_attach() {
    let c = code_with(
        true,
        &[
            ("page.dart", &page("Home")),
            (
                "observe.dart",
                "import 'package:fespalier/fespalier.dart';\nvoid onEnter() {}",
            ),
        ],
    );
    has(
        &c,
        &[
            "/// Lets DevTools, the observe.dart hooks and telemetry follow [router]",
            "observeAttach(router, _observeAt, container: container);",
            "telemetryAttach(router, base: () => _base);",
        ],
    );
}

#[test]
fn off_with_the_key_written_out_is_the_same_as_without_it() {
    let files: &[(&str, &str)] = &[("page.dart", &page("Home"))];
    let dir = project(files);
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  telemetry: false\n",
    )
    .unwrap();
    let cfg = Config {
        package: None,
        ..Config::load(dir.path()).unwrap()
    };
    let (code, _, _) = crate::build(&dir.path().join("lib/app"), &cfg).unwrap();
    assert_eq!(code, code_with(false, files));
}

// ---- the data span is current while data() runs (since 0.9.0) ----

const FRESH: &str = "const freshness = Freshness(staleTime: Duration(minutes: 1));\n";
const CACHE: &str =
    "final dataCache = DataCache<String>.json(toJson: (v) => v, fromJson: (j) => j! as String);\n";

fn motd_page() -> &'static str {
    "class MotdPage extends StatelessWidget { const MotdPage({super.key, required this.text}); final String text; }"
}

#[test]
fn a_data_provider_calls_data_inside_a_closure() {
    let c = code_with(
        true,
        &[
            ("page.dart", &page("Home")),
            ("items/$id/page.dart", &item()),
            (
                "items/$id/data.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<String> data(Ref ref, {required int id}) async => 'x';",
            ),
        ],
    );
    has(
        &c,
        &[
            "final _data2 = FutureProvider.autoDispose.family(",
            "(Ref ref, int id) => traceDataCall(ref, 'd2', id, () => _i1.data(ref, id: id), telemetry: const TelemetrySite('items/\\$id/data.dart', route: '/items/:id')),",
        ],
    );
    assert!(!c.contains("traceData("), "{c}");
}

#[test]
fn a_provider_with_no_key_and_one_with_a_record_key_do_too() {
    let c = code_with(
        true,
        &[
            ("page.dart", &page("Home")),
            ("motd/page.dart", motd_page()),
            (
                "motd/data.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<String> data(Ref ref) async => 'x';",
            ),
            (
                "shops/$shop/items/$id/page.dart",
                "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final String data; }",
            ),
            (
                "shops/$shop/items/$id/data.dart",
                "import 'package:fespalier/fespalier.dart';\nFuture<String> data(Ref ref, {required String shop, required int id}) async => 'x';",
            ),
        ],
    );
    has(
        &c,
        &[
            "(Ref ref) => traceDataCall(ref, 'd1', null, () => _i1.data(ref), telemetry: const TelemetrySite('motd/data.dart', route: '/motd')),",
            "(Ref ref, ({String shop, int id}) k) => traceDataCall(ref, 'd5', k, () => _i3.data(ref, shop: k.shop, id: k.id), telemetry: const TelemetrySite('shops/\\$shop/items/\\$id/data.dart', route: '/shops/:shop/items/:id')),",
        ],
    );
}

#[test]
fn freshness_and_a_data_cache_keep_the_closure() {
    let c = code_with(
        true,
        &[
            ("page.dart", &page("Home")),
            ("items/$id/page.dart", &item()),
            (
                "items/$id/data.dart",
                &format!(
                    "import 'package:fespalier/fespalier.dart';\n{FRESH}Future<String> data(Ref ref, {{required int id}}) async => 'x';"
                ),
            ),
            ("motd/page.dart", motd_page()),
            (
                "motd/data.dart",
                &format!(
                    "import 'package:fespalier/fespalier.dart';\n{CACHE}Future<String> data(Ref ref) async => 'x';"
                ),
            ),
        ],
    );
    has(
        &c,
        &[
            "(Ref ref, int id) => freshData(ref, _i1.freshness, traceDataCall(ref, 'd2', id, () => _i1.data(ref, id: id), telemetry: const TelemetrySite('items/\\$id/data.dart', route: '/items/:id'))),",
            "final _data3 = cachedData(",
            "(Ref ref) => traceDataCall(ref, 'd3', null, () => _i3.data(ref), telemetry: const TelemetrySite('motd/data.dart', route: '/motd')),",
        ],
    );
    assert!(!c.contains("traceData("), "{c}");
}

#[test]
fn off_keeps_trace_data_around_the_value() {
    let files: &[(&str, &str)] = &[
        ("page.dart", &page("Home")),
        ("motd/page.dart", motd_page()),
        (
            "motd/data.dart",
            "import 'package:fespalier/fespalier.dart';\nFuture<String> data(Ref ref) async => 'x';",
        ),
    ];
    let off = code_with(false, files);
    has(
        &off,
        &["(Ref ref) => traceData(ref, 'd1', null, _i1.data(ref)),"],
    );
    assert!(!off.contains("traceDataCall"), "{off}");
    assert!(!off.contains("TelemetrySite"), "{off}");
    let on = code_with(true, files);
    assert!(on.contains("traceDataCall("), "{on}");
}
