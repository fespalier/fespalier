//! `fsp test`: the config errors, which routes get a test and which are skipped (and why), the
//! text of the file, the setup file's contract, where the samples come from, `--check`, that the
//! file survives `dart format`, and that the shop example's committed file is current.

use std::fs;
use std::path::{Path, PathBuf};

use crate::config::{DEFAULT_TEST_OUT, DEFAULT_TEST_TIMEOUT, Pubspec, Test};
use crate::maestro::Skip;
use crate::smoke::{self, Built};

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn typed_page(name: &str, param: &str, ty: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, required this.{param}}}); final {ty} {param}; }}"
    )
}

/// A file of the app folder.
fn f(rel: &str, body: impl AsRef<str>) -> (String, String) {
    (rel.to_string(), body.as_ref().to_string())
}

const GUARD: &str = "String? guard(Ref ref) => null;";

/// A pubspec with `lines` under `fespalier:` (each indented for you) and `test:` lines under it.
fn pubspec(extra: &[&str], test: &[&str]) -> String {
    let more: String = extra.iter().map(|l| format!("  {l}\n")).collect();
    let body: String = if test.is_empty() {
        String::new()
    } else {
        let lines: String = test.iter().map(|l| format!("    {l}\n")).collect();
        format!("  test:\n{lines}")
    };
    format!("name: demo\nfespalier:\n{more}{body}")
}

/// A project: `pubspec`, the app's files, and the files outside `lib/app` (the setup file).
fn project_with(
    pubspec: &str,
    files: &[(String, String)],
    others: &[(&str, &str)],
) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), pubspec).unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    for (rel, body) in others {
        let p = dir.path().join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

const OVERRIDES: &str = "List<Override> overrides(String pattern) => [];";
const APP: &str = "Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);";
const SETUP: &str = "test/routes/setup.dart";

/// What `fsp test` would write for a project with these files, `extra` and `test` lines of the
/// pubspec, and a setup file with this source (none for `None`).
fn built(
    extra: &[&str],
    test: &[&str],
    files: &[(String, String)],
    setup: Option<&str>,
) -> anyhow::Result<Built> {
    let others: Vec<(&str, &str)> = setup.map(|s| (SETUP, s)).into_iter().collect();
    let dir = project_with(&pubspec(extra, test), files, &others);
    smoke::build(dir.path())
}

fn text_of(
    extra: &[&str],
    test: &[&str],
    files: &[(String, String)],
    setup: Option<&str>,
) -> String {
    built(extra, test, files, setup).unwrap().text
}

fn error_of(
    extra: &[&str],
    test: &[&str],
    files: &[(String, String)],
    setup: Option<&str>,
) -> String {
    format!(
        "{:#}",
        built(extra, test, files, setup)
            .map(|b| b.text)
            .unwrap_err()
    )
}

fn skipped(skips: &[Skip]) -> Vec<String> {
    skips
        .iter()
        .map(|s| format!("{}: {}", s.pattern, s.reason))
        .collect()
}

fn validated(test: &[&str]) -> anyhow::Result<Test> {
    let c = Pubspec::parse(&pubspec(&[], test))?.config;
    c.test.unwrap_or_default().validate()
}

fn validation_error(test: &[&str]) -> String {
    format!("{:#}", validated(test).unwrap_err())
}

const SEMANTICS: &str = "semantics_ids: true";

// --- the config -----------------------------------------------------------------

#[test]
fn the_defaults() {
    let t = Pubspec::parse("name: demo\n")
        .unwrap()
        .config
        .test
        .unwrap_or_default()
        .validate()
        .unwrap();
    assert_eq!(t.out, DEFAULT_TEST_OUT);
    assert_eq!(t.out, "test/routes");
    assert_eq!(t.timeout, DEFAULT_TEST_TIMEOUT);
    assert_eq!(t.timeout, 30_000);
    assert_eq!(t.setup, None);
    assert_eq!(t.setup_path(), "test/routes/setup.dart");
    assert!(t.skip.is_empty());
}

#[test]
fn the_keys_are_read() {
    let t = validated(&[
        "out: integration_test/routes",
        "setup: test/helpers/setup.dart",
        "timeout: 5000",
        "skip: [/admin]",
    ])
    .unwrap();
    assert_eq!(t.out, "integration_test/routes");
    assert_eq!(t.setup.as_deref(), Some("test/helpers/setup.dart"));
    assert_eq!(t.setup_path(), "test/helpers/setup.dart");
    assert_eq!(t.timeout, 5000);
    assert_eq!(t.skip, ["/admin"]);
}

#[test]
fn an_unknown_key_is_refused_with_the_known_ones() {
    let err = format!(
        "{:#}",
        Pubspec::parse(&pubspec(&[], &["folder: test"])).unwrap_err()
    );
    assert!(
        err.contains(
            "unknown field `folder`, expected one of `out`, `setup`, `timeout`, `samples`, `skip`"
        ),
        "{err}"
    );
}

#[test]
fn out_must_be_a_folder_where_flutter_test_looks() {
    assert_eq!(
        validation_error(&["out: ../x"]),
        "`fespalier.test.out` must be a folder inside the project (relative, no `..`), got `../x`"
    );
    assert_eq!(
        validation_error(&["out: lib/routes"]),
        "`fespalier.test.out` must be `test`, `integration_test` or a folder below one of them, where `flutter test` finds tests, got `lib/routes`"
    );
    assert_eq!(
        validation_error(&["out: ."]),
        "`fespalier.test.out` must be `test`, `integration_test` or a folder below one of them, where `flutter test` finds tests, got `.`"
    );
    assert_eq!(validated(&["out: test"]).unwrap().out, "test");
    assert_eq!(
        validated(&["out: ./integration_test/"]).unwrap().out,
        "integration_test"
    );
}

#[test]
fn setup_must_be_a_dart_file_inside_the_project() {
    for bad in [
        "/etc/setup.dart",
        "../setup.dart",
        "test/setup.txt",
        "test/",
    ] {
        assert_eq!(
            validation_error(&[&format!("setup: {bad}")]),
            format!(
                "`fespalier.test.setup` must be a .dart file inside the project (relative, no `..`), got `{bad}`"
            )
        );
    }
}

#[test]
fn timeout_is_in_milliseconds_of_the_fake_clock() {
    for bad in ["999", "600001", "-5", "0"] {
        assert_eq!(
            validation_error(&[&format!("timeout: {bad}")]),
            format!(
                "`fespalier.test.timeout` is in milliseconds of the test's fake clock, from 1000 to 600000, got `{bad}`"
            )
        );
    }
    assert_eq!(validated(&["timeout: 1000"]).unwrap().timeout, 1000);
    assert_eq!(validated(&["timeout: 600000"]).unwrap().timeout, 600_000);
}

// --- the text -------------------------------------------------------------------

fn home() -> (String, String) {
    f("page.dart", page("Home"))
}

#[test]
fn a_single_route_without_a_setup_file() {
    let text = text_of(&[SEMANTICS], &[], &[home()], None);
    assert_eq!(
        text,
        "\
// Written by `fsp test` from lib/app/: don't edit it, run `fsp test` again.
// dart format off
// ignore_for_file: type=lint, unused_import
//
// A widget smoke test per route: each opens the route at a sample URL with pumpRouter and
// waits, on the test's fake clock, until its page is on screen. No setup file: the tests boot
// without provider overrides.

import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:demo/app.g.dart';

void main() {
  testWidgets(
    '/ at /',
    (tester) => smokeTestRoute(
      tester,
      '/',
      AppRoutes.router(
        initialLocation: '/',
      ),
    ),
  );
}
"
    );
}

#[test]
fn the_setup_files_functions_are_passed_on() {
    let both = text_of(
        &[SEMANTICS],
        &[],
        &[home()],
        Some(&format!("{OVERRIDES}\n{APP}\n")),
    );
    assert!(both.contains(
        "// waits, on the test's fake clock, until its page is on screen. Provider overrides and the app\n// around the router come from test/routes/setup.dart.\n"
    ));
    assert!(both.contains("\nimport 'setup.dart' as setup;\n"));
    assert!(both.contains(
        "      AppRoutes.router(\n        initialLocation: '/',\n      ),\n      overrides: setup.overrides(\n        '/',\n      ),\n      app: setup.app,\n    ),\n"
    ));

    let only_overrides = text_of(&[SEMANTICS], &[], &[home()], Some(OVERRIDES));
    assert!(only_overrides.contains(
        "until its page is on screen. Provider overrides come\n// from test/routes/setup.dart.\n"
    ));
    assert!(
        only_overrides
            .contains("      overrides: setup.overrides(\n        '/',\n      ),\n    ),\n")
    );
    assert!(!only_overrides.contains("app: setup.app"));

    let only_app = text_of(&[SEMANTICS], &[], &[home()], Some(APP));
    assert!(only_app.contains(
        "The app around the router\n// comes from test/routes/setup.dart; the tests boot without provider overrides.\n"
    ));
    assert!(only_app.contains("import 'setup.dart' as setup;"));
    assert!(only_app.contains("      app: setup.app,\n    ),\n"));
    assert!(!only_app.contains("overrides:"));

    let none = text_of(&[SEMANTICS], &[], &[home()], None);
    assert!(!none.contains("setup.dart"));
    assert!(!none.contains("as setup"));
    assert!(!none.contains("setup."));
}

#[test]
fn the_setup_import_is_relative_to_the_test_file() {
    let dir = project_with(
        &pubspec(
            &[SEMANTICS],
            &["out: test/smoke/deep", "setup: test/helpers/setup.dart"],
        ),
        &[home()],
        &[("test/helpers/setup.dart", OVERRIDES)],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert_eq!(b.shown, "test/smoke/deep/routes_test.dart");
    assert!(
        b.text
            .contains("import '../../helpers/setup.dart' as setup;")
    );
    assert!(b.text.contains("come\n// from test/helpers/setup.dart.\n"));
}

#[test]
fn a_non_default_timeout_is_passed_on() {
    let text = text_of(&[SEMANTICS], &["timeout: 5000"], &[home()], None);
    assert!(text.contains(
        "      AppRoutes.router(\n        initialLocation: '/',\n      ),\n      timeout: const Duration(milliseconds: 5000),\n    ),\n"
    ));
    let default = text_of(&[SEMANTICS], &["timeout: 30000"], &[home()], None);
    assert!(!default.contains("timeout:"));
}

#[test]
fn without_semantics_ids_a_class_page_is_found_by_type() {
    let files = [
        f("page.dart", page("Home")),
        f("cart/page.dart", page("Cart")),
        f("about/page.dart", page("About")),
    ];
    let text = text_of(&[], &[], &files, None);
    assert!(text.contains(
        "import 'package:demo/app.g.dart';\nimport 'package:demo/app/page.dart' as _i0;\nimport 'package:demo/app/about/page.dart' as _i1;\nimport 'package:demo/app/cart/page.dart' as _i2;\n\nvoid main() {"
    ), "{text}");
    assert!(text.contains(
        "      AppRoutes.router(\n        initialLocation: '/cart',\n      ),\n      page: find.byType(\n        _i2.CartPage,\n      ),\n    ),\n"
    ));
    assert!(text.contains("page: find.byType(\n        _i0.HomePage,\n      ),"));
}

#[test]
fn a_function_page_needs_semantics_ids() {
    let files = [
        home(),
        f("fn/page.dart", "Widget page() => const SizedBox();"),
    ];
    let b = built(&[], &[], &files, None).unwrap();
    assert_eq!(
        skipped(&b.skips),
        ["/fn: a function page; set `semantics_ids: true` so its test can find it"]
    );
    assert!(!b.text.contains("'/fn'"));
    assert!(b.text.contains(
        "//   skipped /fn: a function page; set `semantics_ids: true` so its test can find it\n"
    ));
    let b = built(&[SEMANTICS], &[], &files, None).unwrap();
    assert!(b.skips.is_empty());
    assert!(b.text.contains("'/fn at /fn'"));
    assert!(!b.text.contains("find.byType"));
}

#[test]
fn every_skip_reason_is_printed_in_the_header_too() {
    let files = [
        home(),
        f("old/redirect.dart", "String redirect() => '/';"),
        f("admin/page.dart", page("Admin")),
        f("(members)/guard.dart", GUARD),
        f("(members)/inbox/page.dart", page("Inbox")),
        f(
            "docs/$$rest/page.dart",
            typed_page("Docs", "rest", "List<String>"),
        ),
        f("products/$id/page.dart", typed_page("Product", "id", "int")),
    ];
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  maestro:\n    url: http://localhost:8080\n    samples:\n      products/$id: 3\n  test:\n    skip: [/admin]\n",
        &files,
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert_eq!(
        skipped(&b.skips),
        [
            "/inbox: guarded by (members)/guard.dart; give test/routes/setup.dart an `overrides(String pattern)` that gets past it",
            "/admin: listed in `fespalier.test.skip`",
            "/docs/*rest: no sample for docs/$$rest in `fespalier.maestro.samples`",
            "/old: a redirect, with no page to see",
        ]
    );
    for s in &b.skips {
        assert!(
            b.text
                .contains(&format!("//   skipped {}: {}\n", s.pattern, s.reason)),
            "{}",
            s.pattern
        );
    }
    assert_eq!(b.routes, 2);
    assert!(b.text.contains("'/products/:id at /products/3'"));
    assert!(!b.text.contains("'/inbox"));
}

#[test]
fn a_guarded_route_is_tested_when_there_are_overrides() {
    let files = [
        home(),
        f("(members)/guard.dart", GUARD),
        f("(members)/inbox/page.dart", page("Inbox")),
        f("(members)/admin/guard.dart", GUARD),
        f("(members)/admin/page.dart", page("Admin")),
    ];
    let b = built(&[SEMANTICS], &[], &files, Some(OVERRIDES)).unwrap();
    assert!(b.skips.is_empty());
    assert!(b.text.contains(
        "  // Guarded by (members)/guard.dart, (members)/admin/guard.dart.\n  testWidgets(\n    '/admin at /admin',"
    ));
    assert!(b.text.contains(
        "  // Guarded by (members)/guard.dart.\n  testWidgets(\n    '/inbox at /inbox',"
    ));
    assert!(
        b.text
            .contains("overrides: setup.overrides(\n        '/inbox',\n      ),")
    );
    // A setup with only `app` doesn't get past a guard.
    let b = built(&[SEMANTICS], &[], &files, Some(APP)).unwrap();
    assert_eq!(b.skips.len(), 2);
}

#[test]
fn a_route_that_is_not_linkable_still_has_a_test() {
    let files = [
        home(),
        f("secret/page.dart", page("Secret")),
        f("secret/route.dart", "const linkable = false;"),
    ];
    let b = built(&[SEMANTICS], &[], &files, None).unwrap();
    assert!(b.skips.is_empty());
    assert!(b.text.contains("'/secret at /secret'"));
}

#[test]
fn the_tests_come_in_the_order_of_the_route_table() {
    let files = [
        f("zebra/page.dart", page("Zebra")),
        f("page.dart", page("Home")),
        f("apple/page.dart", page("Apple")),
    ];
    let text = text_of(&[SEMANTICS], &[], &files, None);
    let at = |needle: &str| text.find(needle).unwrap();
    assert!(at("'/ at /'") < at("'/apple at /apple'"));
    assert!(at("'/apple at /apple'") < at("'/zebra at /zebra'"));
}

#[test]
fn no_route_with_a_page_is_an_error() {
    assert_eq!(
        error_of(
            &[SEMANTICS],
            &[],
            &[f("layout.dart", "Widget layout(Widget child) => child;")],
            None
        ),
        "no route has a page: there is nothing for a test to open"
    );
}

// --- samples --------------------------------------------------------------------

fn product() -> (String, String) {
    f("products/$id/page.dart", typed_page("Product", "id", "int"))
}

#[test]
fn a_sample_is_percent_encoded_and_the_literal_escaped() {
    let files = [
        home(),
        f("x/$id/page.dart", typed_page("X", "id", "String")),
    ];
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  test:\n    samples:\n      x/$id: \"it's$1\"\n",
        &files,
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    // The path is percent-encoded first (`'` is %27, `$` is %24), so no quote or `$` is left in
    // it for the Dart literal to escape (a folder's name can't have one either).
    assert!(b.text.contains("'/x/:id at /x/it%27s%241'"), "{}", b.text);
    assert!(
        b.text
            .contains("AppRoutes.router(\n        initialLocation: '/x/it%27s%241',\n      ),")
    );
}

#[test]
fn test_samples_are_read_from_test_samples() {
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  test:\n    samples:\n      products/$id: 7\n",
        &[home(), product()],
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert!(b.text.contains("'/products/:id at /products/7'"));
}

#[test]
fn without_test_samples_the_maestro_ones_are_used() {
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  maestro:\n    url: http://localhost:8080\n    samples:\n      products/$id: 3\n",
        &[home(), product()],
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert!(b.text.contains("'/products/:id at /products/3'"));
}

#[test]
fn test_samples_win_over_the_maestro_ones() {
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  maestro:\n    url: http://localhost:8080\n    samples:\n      products/$id: 3\n  test:\n    samples:\n      products/$id: 9\n",
        &[home(), product()],
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert!(b.text.contains("'/products/:id at /products/9'"));
    assert!(!b.text.contains("/products/3"));
}

#[test]
fn a_missing_sample_names_the_key_it_would_be_under() {
    let b = built(&[SEMANTICS], &[], &[home(), product()], None).unwrap();
    assert_eq!(
        skipped(&b.skips),
        ["/products/:id: no sample for products/$id in `fespalier.test.samples`"]
    );
    // With a `maestro:` section that has samples, the Maestro key is the one named.
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  maestro:\n    url: http://localhost:8080\n    samples:\n      other/$x: 1\n",
        &[
            home(),
            product(),
            f("other/$x/page.dart", typed_page("Other", "x", "int")),
        ],
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert_eq!(
        skipped(&b.skips),
        ["/products/:id: no sample for products/$id in `fespalier.maestro.samples`"]
    );
}

#[test]
fn a_maestro_section_fsp_maestro_refuses_does_not_stop_fsp_test() {
    // No `url` or `app_id`: `fsp maestro` refuses it, but only its samples are read here.
    let dir = project_with(
        "name: demo\nfespalier:\n  semantics_ids: true\n  maestro:\n    samples:\n      products/$id: 3\n",
        &[home(), product()],
        &[],
    );
    let b = smoke::build(dir.path()).unwrap();
    assert!(b.text.contains("'/products/:id at /products/3'"));
}

#[test]
fn a_bad_sample_is_refused_with_the_key_it_is_under() {
    let files = [home(), product()];
    let dir = project_with(
        "name: demo\nfespalier:\n  test:\n    samples:\n      products/$id: abc\n",
        &files,
        &[],
    );
    assert_eq!(
        format!("{:#}", smoke::build(dir.path()).unwrap_err()),
        "`fespalier.test.samples`: `products/$id` is a `int` segment, and `abc` is not one"
    );
    let dir = project_with(
        "name: demo\nfespalier:\n  test:\n    samples:\n      products/$id: [1]\n",
        &files,
        &[],
    );
    assert_eq!(
        format!("{:#}", smoke::build(dir.path()).unwrap_err()),
        "`fespalier.test.samples`: `products/$id` is one segment; give one value, not a list"
    );
    let dir = project_with(
        "name: demo\nfespalier:\n  maestro:\n    samples:\n      nope/$id: 1\n",
        &files,
        &[],
    );
    assert_eq!(
        format!("{:#}", smoke::build(dir.path()).unwrap_err()),
        "`fespalier.maestro.samples`: `nope/$id` is not a folder of lib/app; write it as `fsp routes` prints it, without `/page.dart` (`products/$id`)"
    );
    let dir = project_with(
        "name: demo\nfespalier:\n  test:\n    samples:\n      products/$id: {a: 1}\n",
        &files,
        &[],
    );
    assert_eq!(
        format!("{:#}", smoke::build(dir.path()).unwrap_err()),
        "`fespalier.test.samples`: the value of `products/$id` must be a text, a number, a boolean or a list of them"
    );
}

// --- the other checks -----------------------------------------------------------

#[test]
fn a_skip_entry_must_be_a_route() {
    assert_eq!(
        error_of(&[SEMANTICS], &["skip: [/nope]"], &[home()], None),
        "`fespalier.test.skip`: `/nope` is not a route; write the pattern as `fsp routes` prints it (`/products/:id`)"
    );
}

#[test]
fn a_package_name_is_required() {
    let dir = project_with("fespalier:\n  semantics_ids: true\n", &[home()], &[]);
    assert_eq!(
        format!("{:#}", smoke::build(dir.path()).unwrap_err()),
        "`fsp test` imports the app as a package (`package:<name>/...`): give pubspec.yaml a `name:`"
    );
}

#[test]
fn a_configured_setup_file_must_exist() {
    assert_eq!(
        error_of(
            &[SEMANTICS],
            &["setup: test/mine/setup.dart"],
            &[home()],
            None
        ),
        "`fespalier.test.setup`: test/mine/setup.dart does not exist"
    );
}

#[test]
fn the_setup_file_must_declare_one_of_the_functions() {
    assert_eq!(
        error_of(&[SEMANTICS], &[], &[home()], Some("int unrelated() => 1;")),
        "test/routes/setup.dart has neither `overrides` nor `app`: write `List<Override> overrides(String pattern) => [...]` (the providers each route's test boots with) or `Widget app(GoRouter router) => ...` (the app around the router)"
    );
}

#[test]
fn the_setup_files_functions_take_one_argument() {
    let overrides = "test/routes/setup.dart: `overrides` must be a function of the route's pattern: `List<Override> overrides(String pattern) => [...]`";
    for bad in [
        "List<Override> overrides() => [];",
        "List<Override> overrides(String a, String b) => [];",
        "List<Override> overrides({required String pattern}) => [];",
        "List<Override> overrides([String? pattern]) => [];",
    ] {
        assert_eq!(
            error_of(&[SEMANTICS], &[], &[home()], Some(bad)),
            overrides,
            "{bad}"
        );
    }
    let app = "test/routes/setup.dart: `app` must be a function of the router: `Widget app(GoRouter router) => MaterialApp.router(routerConfig: router)`";
    for bad in [
        "Widget app() => const SizedBox();",
        "Widget app(GoRouter r, int x) => const SizedBox();",
    ] {
        assert_eq!(
            error_of(&[SEMANTICS], &[], &[home()], Some(bad)),
            app,
            "{bad}"
        );
    }
    // Optional extras are fine: the call passes one argument.
    assert!(
        built(
            &[SEMANTICS],
            &[],
            &[home()],
            Some("List<Override> overrides(String p, [int n = 0]) => [];")
        )
        .is_ok()
    );
}

// --- the file on disk -----------------------------------------------------------

fn run(dir: &Path, check: bool) -> anyhow::Result<()> {
    smoke::run(dir, check)
}

#[test]
fn run_writes_the_file_and_check_follows_it() {
    let dir = project_with(
        &pubspec(&[SEMANTICS], &[]),
        &[home()],
        &[(SETUP, OVERRIDES)],
    );
    let file = dir.path().join("test/routes/routes_test.dart");

    assert_eq!(
        format!("{:#}", run(dir.path(), true).unwrap_err()),
        "test/routes/routes_test.dart is missing; run `fsp test`"
    );
    assert!(!file.exists());

    run(dir.path(), false).unwrap();
    let written = fs::read_to_string(&file).unwrap();
    assert_eq!(written, smoke::build(dir.path()).unwrap().text);
    run(dir.path(), true).unwrap();
    // A second write changes nothing.
    run(dir.path(), false).unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), written);

    fs::write(&file, written.replace("'/ at /'", "'/ at /x'")).unwrap();
    assert_eq!(
        format!("{:#}", run(dir.path(), true).unwrap_err()),
        "test/routes/routes_test.dart is out of date; run `fsp test`"
    );
    // `--check` wrote nothing.
    assert!(fs::read_to_string(&file).unwrap().contains("'/ at /x'"));
    run(dir.path(), false).unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), written);
}

#[test]
fn a_file_fsp_test_did_not_write_is_left_alone() {
    let dir = project_with(&pubspec(&[SEMANTICS], &[]), &[home()], &[]);
    let file = dir.path().join("test/routes/routes_test.dart");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "void main() {}\n").unwrap();
    let expected = "test/routes/routes_test.dart was not written by `fsp test` (its first line isn't ``// Written by `fsp test` ``); move it, or set `fespalier.test.out` to another folder";
    for check in [false, true] {
        assert_eq!(
            format!("{:#}", run(dir.path(), check).unwrap_err()),
            expected
        );
    }
    assert_eq!(fs::read_to_string(&file).unwrap(), "void main() {}\n");
}

#[test]
fn run_creates_the_out_folder() {
    let dir = project_with(
        &pubspec(&[SEMANTICS], &["out: integration_test/a/b"]),
        &[home()],
        &[],
    );
    run(dir.path(), false).unwrap();
    assert!(
        dir.path()
            .join("integration_test/a/b/routes_test.dart")
            .is_file()
    );
}

// --- dart format ----------------------------------------------------------------

/// A package config at this language version, which is what `dart format` picks its style from
/// (3.7 and later: the tall style, which reads `// dart format off`; before: the short one,
/// which doesn't).
fn with_language_version(dir: &Path, version: &str) {
    fs::create_dir_all(dir.join(".dart_tool")).unwrap();
    fs::write(
        dir.join(".dart_tool/package_config.json"),
        format!(
            "{{\"configVersion\": 2, \"packages\": [{{\"name\": \"demo\", \"rootUri\": \"../\", \"packageUri\": \"lib/\", \"languageVersion\": \"{version}\"}}]}}"
        ),
    )
    .unwrap();
}

/// The file is what `dart format` leaves alone in both styles, whatever the length of a route:
/// a short one that would fit on a line, and long ones that would not. Without `dart` on PATH
/// there is nothing to compare it with: skip.
#[test]
fn the_file_is_dart_format_clean_in_both_styles() {
    let long = "class LongPage extends StatelessWidget { const LongPage({super.key, required this.a, required this.b}); final int a; final String b; }";
    let files = [
        home(),
        f("a/page.dart", page("A")),
        f("guarded/guard.dart", GUARD),
        f("guarded/page.dart", page("Guarded")),
        f(
            "an/extremely/long/folder/structure/for/a/route/$a/with/more/$b/page.dart",
            long,
        ),
        f("fn/page.dart", "Widget page() => const SizedBox();"),
    ];
    let test = [
        "timeout: 5000",
        "samples:",
        "  an/extremely/long/folder/structure/for/a/route/$a: 12345678",
        "  an/extremely/long/folder/structure/for/a/route/$a/with/more/$b: a-value-that-is-long",
    ];
    for version in ["3.5", "3.9"] {
        for semantics in [true, false] {
            for setup in [None, Some(OVERRIDES), Some(APP)] {
                let extra: &[&str] = if semantics { &[SEMANTICS] } else { &[] };
                let others: Vec<(&str, &str)> = setup.map(|s| (SETUP, s)).into_iter().collect();
                let dir = project_with(&pubspec(extra, &test), &files, &others);
                with_language_version(dir.path(), version);
                let b = smoke::build(dir.path()).unwrap();
                let path = dir.path().join(&b.shown);
                let (formatted, warning) = crate::format::format_dart(&b.text, &path);
                if warning.is_some() {
                    return;
                }
                let changed = b.text.lines().zip(formatted.lines()).find(|(a, b)| a != b);
                assert!(
                    b.text == formatted,
                    "not dart-format clean under {version} (semantics_ids {semantics}, setup {setup:?}): first change {changed:?}"
                );
            }
        }
    }
}

// --- the shop example -----------------------------------------------------------

#[test]
fn committed_shop_tests_are_up_to_date() {
    let dir = examples("shop");
    let b = smoke::build(&dir).unwrap();
    assert_eq!(b.shown, "test/routes/routes_test.dart");
    let disk = fs::read_to_string(dir.join(&b.shown)).unwrap_or_default();
    assert_eq!(
        b.text, disk,
        "{} is stale; run `fsp test --project examples/shop`",
        b.shown
    );
    assert_eq!(b.routes, 6);
    assert!(b.skips.is_empty());
}
