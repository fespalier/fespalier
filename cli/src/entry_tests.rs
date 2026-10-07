//! The generated entry point (since 0.8.1): `lib/app.main.g.dart` from the root files `app.dart`,
//! `startup.dart` and `splash.dart`, and `fespalier: main:`.

use std::fs;

use crate::config::{Config, MainMode, Pubspec};
use crate::entry::{self, MainHooks};
use crate::{analyze_with_main, enums, resolve, scan};

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";
const APP: &str = "class App extends StatelessWidget { const App({super.key, required this.router}); final GoRouter router; }";
const SPLASH: &str = "class Splash extends StatelessWidget { const Splash({super.key, this.error, this.retry}); final Object? error; final VoidCallback? retry; }";

/// A throwaway project whose pubspec carries `yaml` (extra top-level keys).
fn project(yaml: &str, files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        format!("name: demo\n{yaml}"),
    )
    .unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// What `gen` makes of a project: `app.g.dart`, the generated main, and the diagnostics as
/// `✗ file:line  message` (errors) and `! file  message` (warnings).
struct Gen {
    app_g: String,
    main: Option<String>,
    diags: Vec<String>,
}

fn run_yaml(yaml: &str, files: &[(&str, &str)]) -> Gen {
    let dir = project(yaml, files);
    let cfg = Config::load(dir.path()).unwrap();
    let (app_g, main, diags, _) = analyze_with_main(&dir.path().join("lib/app"), &cfg).unwrap();
    Gen {
        app_g,
        main,
        diags: diags.0.iter().map(ToString::to_string).collect(),
    }
}

fn run_gen(files: &[(&str, &str)]) -> Gen {
    run_yaml("", files)
}

/// The generated main of a project that checks cleanly.
fn main_of(files: &[(&str, &str)]) -> String {
    let g = run_gen(files);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    g.main.expect("a main is written")
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    run_gen(files).diags
}

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

fn has_not(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

// --- the config --------------------------------------------------------------

fn cfg(yaml: &str) -> anyhow::Result<Config> {
    Ok(Pubspec::parse(&format!("name: demo\n{yaml}"))?.config)
}

#[test]
fn main_defaults_to_auto_and_reads_each_value() {
    assert_eq!(Config::default().main, MainMode::Auto);
    assert_eq!(cfg("").unwrap().main, MainMode::Auto);
    for (value, mode) in [
        ("auto", MainMode::Auto),
        ("generated", MainMode::Generated),
        ("manual", MainMode::Manual),
    ] {
        let c = cfg(&format!("fespalier:\n  main: {value}\n")).unwrap();
        assert_eq!(c.main, mode, "{value}");
    }
}

#[test]
fn a_bad_main_value_names_the_choices() {
    let err = format!("{:#}", cfg("fespalier:\n  main: always\n").unwrap_err());
    assert!(
        err.contains("unknown variant `always`, expected one of `auto`, `generated`, `manual`"),
        "{err}"
    );
}

#[test]
fn the_main_file_sits_beside_the_output() {
    let at = |output: &str| {
        cfg(&format!("fespalier:\n  output: {output}\n"))
            .unwrap()
            .output_main()
    };
    assert_eq!(Config::default().output_main(), "lib/app.main.g.dart");
    assert_eq!(
        at("lib/router/routes.g.dart"),
        "lib/router/routes.main.g.dart"
    );
    assert_eq!(at("lib/x.dart"), "lib/x.main.g.dart");
}

#[test]
fn the_manifest_cannot_be_the_main_file() {
    let err = format!(
        "{:#}",
        cfg("fespalier:\n  output_manifest: lib/app.main.g.dart\n").unwrap_err()
    );
    assert!(
        err.contains("`fespalier.output_manifest` is `lib/app.main.g.dart`, the file the generated main() goes in (`output` with `.main.g.dart`); pick another name"),
        "{err}"
    );
}

// --- when a main is written --------------------------------------------------

#[test]
fn auto_writes_nothing_without_a_root_file() {
    let g = run_gen(&[("page.dart", HOME)]);
    assert!(g.main.is_none());
    assert!(g.diags.is_empty(), "{:?}", g.diags);
}

#[test]
fn auto_writes_for_any_one_root_file() {
    let startup = "Future<void> startup() async {}";
    for (file, body) in [
        ("app.dart", APP),
        ("startup.dart", startup),
        ("splash.dart", "Widget splash() => const SizedBox();"),
    ] {
        let g = run_gen(&[("page.dart", HOME), (file, body)]);
        assert!(g.main.is_some(), "{file}: {:?}", g.diags);
    }
}

#[test]
fn manual_reads_and_writes_nothing_and_says_so() {
    let g = run_yaml(
        "fespalier:\n  main: manual\n",
        &[
            ("page.dart", HOME),
            ("app.dart", "this is not dart at all"),
            ("startup.dart", "Future<void> startup() async {}"),
            ("splash.dart", SPLASH),
        ],
    );
    assert!(g.main.is_none());
    let want = |file: &str| {
        format!(
            "! {file}  `main: manual` is set in pubspec.yaml, so {file} is not read and no lib/app.main.g.dart is written"
        )
    };
    for file in ["app.dart", "startup.dart", "splash.dart"] {
        assert!(g.diags.contains(&want(file)), "{file}: {:?}", g.diags);
    }
}

#[test]
fn generated_writes_the_default_app_with_no_root_file() {
    let g = run_yaml("fespalier:\n  main: generated\n", &[("page.dart", HOME)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    let main = g.main.unwrap();
    has(
        &main,
        &[
            "import 'package:flutter/material.dart';",
            "static Widget app(GoRouter router) => MaterialApp.router(routerConfig: router);",
            "static Widget root({GoRouter Function() router = AppRoutes.router}) => StartupGate(",
            "static Future<void> run() => _main();",
            "    router: router,\n    app: app,\n  );",
        ],
    );
    has_not(&main, &["_i0", "_splash", "_router", "zone", "kIsWeb"]);
}

// --- the shape of the file ---------------------------------------------------

const STARTUP_FULL: &str = "\
import 'package:fespalier/startup.dart';
Future<List<Override>> startup() async => [];
Future<void> zone(Future<void> Function() body) => body();
List<ProviderObserver> get providerObservers => [];
List<NavigatorObserver> get routerObservers => [];
Duration? retry(int retryCount, Object error) => null;
";

#[test]
fn the_richest_main_names_every_piece() {
    let main = main_of(&[
        ("page.dart", HOME),
        ("app.dart", APP),
        ("startup.dart", STARTUP_FULL),
        ("splash.dart", SPLASH),
    ]);
    has(
        &main,
        &[
            "// GENERATED by fespalier from lib/app/. Do not edit; run `fsp gen`.",
            "// ignore_for_file: type=lint, unused_import",
            "import 'package:fespalier/fespalier.dart';",
            "import 'package:fespalier/startup.dart';",
            "import 'package:flutter/widgets.dart';",
            "import 'app.g.dart';",
            "import 'app/app.dart' as _i0;",
            "import 'app/startup.dart' as _i1;",
            "import 'app/splash.dart' as _i2;",
            "abstract final class AppMain {",
            "static Future<void> run() => _i1.zone(_main);",
            "    WidgetsFlutterBinding.ensureInitialized();\n    runApp(root());",
            "overrides: _i1.startup,",
            "splash: _splash,",
            "observers: _providerObservers,",
            "retry: _i1.retry,",
            "router: router,",
            "app: app,",
            "static Widget app(GoRouter router) => _i0.App(router: router);",
            "GoRouter _router() => AppRoutes.router(observers: _i1.routerObservers);",
            "List<ProviderObserver> _providerObservers() => _i1.providerObservers;",
            "Widget _splash(Object? error, StackTrace? stackTrace, VoidCallback? retry) =>\n    _i2.Splash(error: error, retry: retry);",
            "router = _router}) => StartupGate(",
            "everything runs inside startup.dart's `zone()`: the binding,",
        ],
    );
    has_not(
        &main,
        &["kIsWeb", "loadDeferred", "material.dart", "startup: "],
    );
}

#[test]
fn without_a_zone_run_is_main() {
    let main = main_of(&[
        ("page.dart", HOME),
        ("startup.dart", "Future<void> startup() async {}"),
    ]);
    has(&main, &["static Future<void> run() => _main();"]);
    has_not(&main, &["zone"]);
}

#[test]
fn a_zone_that_returns_a_future_or_is_awaited_as_one() {
    let main = main_of(&[
        ("page.dart", HOME),
        (
            "startup.dart",
            "FutureOr<void> zone(Future<void> Function() body) => body();",
        ),
    ]);
    has(
        &main,
        &["static Future<void> run() => Future<void>.sync(() => _i0.zone(_main));"],
    );
}

#[test]
fn deferred_routes_are_loaded_before_the_first_frame_off_the_web() {
    let deferred = "const deferred = true;";
    let main = main_of(&[
        ("page.dart", HOME),
        ("route.dart", deferred),
        ("app.dart", APP),
    ]);
    has(
        &main,
        &[
            "import 'package:flutter/foundation.dart' show kIsWeb;",
            "    if (!kIsWeb) await AppRoutes.loadDeferred();\n    runApp(root());",
            "the binding,\n  /// the code of the deferred routes (loaded before the first frame, off the web), then [root].",
        ],
    );
    // No deferred route, no such call (AppRoutes has no loadDeferred then).
    let plain = main_of(&[("page.dart", HOME), ("app.dart", APP)]);
    has_not(&plain, &["kIsWeb", "loadDeferred"]);
}

#[test]
fn a_startup_that_returns_no_overrides_is_passed_as_startup() {
    for ret in ["void", "Future<void>", "FutureOr<void>"] {
        let main = main_of(&[
            ("page.dart", HOME),
            ("startup.dart", &format!("{ret} startup() {{}}")),
        ]);
        has(&main, &["    startup: _i0.startup,"]);
        has_not(&main, &["overrides:"]);
    }
    for ret in [
        "List<Override>",
        "Future<List<Override>>",
        "FutureOr<List<Override>>",
        "Future<List<p.Override>>",
    ] {
        let main = main_of(&[
            ("page.dart", HOME),
            ("startup.dart", &format!("{ret} startup() => [];")),
        ]);
        has(&main, &["    overrides: _i0.startup,"]);
        has_not(&main, &["    startup: "]);
    }
}

#[test]
fn no_startup_means_neither_line() {
    let main = main_of(&[
        ("page.dart", HOME),
        (
            "startup.dart",
            "List<ProviderObserver> get providerObservers => [];",
        ),
    ]);
    has_not(&main, &["startup: ", "overrides: "]);
    has(&main, &["observers: _providerObservers,"]);
}

#[test]
fn no_splash_means_no_splash_line_or_function() {
    let main = main_of(&[("page.dart", HOME), ("app.dart", APP)]);
    has_not(&main, &["splash:", "_splash", "import 'app/splash.dart'"]);
}

#[test]
fn no_observers_or_retry_means_none_of_their_lines() {
    let main = main_of(&[
        ("page.dart", HOME),
        ("startup.dart", "Future<void> startup() async {}"),
    ]);
    has_not(
        &main,
        &["observers:", "_providerObservers", "retry:", "_router"],
    );
}

#[test]
fn router_observers_build_the_router_when_app_dart_has_no_router() {
    let main = main_of(&[
        ("page.dart", HOME),
        (
            "startup.dart",
            "List<NavigatorObserver> get routerObservers => [];",
        ),
    ]);
    has(
        &main,
        &[
            "GoRouter _router() => AppRoutes.router(observers: _i0.routerObservers);",
            "static Widget root({GoRouter Function() router = _router}) => StartupGate(",
        ],
    );
}

#[test]
fn app_dart_may_build_the_router() {
    let app = format!("{APP}\nGoRouter router() => AppRoutes.router(restorationScopeId: 'r');");
    let main = main_of(&[("page.dart", HOME), ("app.dart", &app)]);
    has(
        &main,
        &[
            "GoRouter _router() => _i0.router();",
            "router = _router}) => StartupGate(",
        ],
    );
}

#[test]
fn neither_router_nor_observers_leaves_the_default() {
    let main = main_of(&[("page.dart", HOME), ("app.dart", APP)]);
    has(&main, &["router = AppRoutes.router}) => StartupGate("]);
    has_not(&main, &["_router"]);
}

#[test]
fn app_dart_may_be_a_function_or_name_the_router_otherwise() {
    let main = main_of(&[
        ("page.dart", HOME),
        (
            "app.dart",
            "Widget app({required GoRouter router}) => const SizedBox();",
        ),
    ]);
    has(
        &main,
        &["static Widget app(GoRouter router) => _i0.app(router: router);"],
    );

    let by_type = "class App extends StatelessWidget { const App({super.key, required this.myRouter}); final GoRouter myRouter; }";
    let main = main_of(&[("page.dart", HOME), ("app.dart", by_type)]);
    has(&main, &["_i0.App(myRouter: router)"]);

    let positional = "class App extends StatelessWidget { const App(this.router, {super.key}); final RouterConfig<Object> router; }";
    let main = main_of(&[("page.dart", HOME), ("app.dart", positional)]);
    has(&main, &["_i0.App(router)"]);
}

#[test]
fn optional_parameters_of_the_app_are_left_to_their_defaults() {
    let app = "class App extends StatelessWidget { const App({super.key, required this.router, this.title = 'x'}); final GoRouter router; final String title; }";
    let main = main_of(&[("page.dart", HOME), ("app.dart", app)]);
    has(&main, &["_i0.App(router: router)"]);
}

#[test]
fn main_hooks_wrap_main_outside_the_zone() {
    let dir = project(
        "",
        &[
            ("page.dart", HOME),
            ("startup.dart", STARTUP_FULL),
            ("app.dart", APP),
        ],
    );
    let cfg = Config::load(dir.path()).unwrap();
    let app_dir = dir.path().join("lib/app");
    let mut diags = crate::diag::Diags::default();
    let tree = scan::scan(&app_dir, &mut diags).unwrap();
    let libs = enums::Libs::for_app(&app_dir, &cfg);
    let app = resolve::resolve(&tree, true, cfg.remount, false, &libs, &mut diags);
    let emit = |hooks: MainHooks| {
        let mut diags = crate::diag::Diags::default();
        let main = entry::emit(&tree, &app, &cfg, &hooks, &mut diags).unwrap();
        assert!(diags.0.is_empty(), "{:?}", diags.0);
        main
    };
    let main = emit(MainHooks {
        wrappers: vec!["_o.zone".into()],
        before_run: vec!["await _o.open();".into()],
        provider_observers: vec!["_o.observers()".into()],
        ..MainHooks::default()
    });
    has(
        &main,
        &[
            "static Future<void> run() => _o.zone(() => _i1.zone(_main));",
            "    WidgetsFlutterBinding.ensureInitialized();\n    await _o.open();\n    runApp(root());",
            "List<ProviderObserver> _providerObservers() => [..._o.observers(), ..._i1.providerObservers];",
        ],
    );
    // Two wrappers fold from the inside: the first is the outermost.
    let main = emit(MainHooks {
        wrappers: vec!["_a".into(), "_b".into()],
        ..MainHooks::default()
    });
    has(
        &main,
        &["static Future<void> run() => _a(() => _b(() => _i1.zone(_main)));"],
    );
    // With nothing in them the hooks change nothing.
    assert_eq!(emit(MainHooks::default()), main_of_files(&dir));
}

/// The main of an already written project, as `gen` makes it.
fn main_of_files(dir: &tempfile::TempDir) -> String {
    let cfg = Config::load(dir.path()).unwrap();
    analyze_with_main(&dir.path().join("lib/app"), &cfg)
        .unwrap()
        .1
        .unwrap()
}

#[test]
fn wrappers_without_a_zone_wrap_main_itself() {
    let dir = project("", &[("page.dart", HOME), ("app.dart", APP)]);
    let cfg = Config::load(dir.path()).unwrap();
    let app_dir = dir.path().join("lib/app");
    let mut diags = crate::diag::Diags::default();
    let tree = scan::scan(&app_dir, &mut diags).unwrap();
    let libs = enums::Libs::for_app(&app_dir, &cfg);
    let app = resolve::resolve(&tree, true, cfg.remount, false, &libs, &mut diags);
    let hooks = MainHooks {
        wrappers: vec!["_o.zone".into()],
        ..MainHooks::default()
    };
    let main = entry::emit(&tree, &app, &cfg, &hooks, &mut diags).unwrap();
    has(&main, &["static Future<void> run() => _o.zone(_main);"]);
}

#[test]
fn the_main_file_goes_beside_a_moved_output() {
    let g = run_yaml(
        "fespalier:\n  output: lib/router/routes.g.dart\n",
        &[("page.dart", HOME), ("app.dart", APP)],
    );
    let main = g.main.unwrap();
    has(
        &main,
        &[
            "import 'routes.g.dart';",
            "import '../app/app.dart' as _i0;",
        ],
    );
}

// --- app.g.dart does not depend on it ----------------------------------------

#[test]
fn app_g_dart_is_the_same_with_and_without_the_root_files() {
    let with_nothing = run_gen(&[("page.dart", HOME)]);
    let with_everything = run_gen(&[
        ("page.dart", HOME),
        ("app.dart", APP),
        ("startup.dart", STARTUP_FULL),
        ("splash.dart", SPLASH),
    ]);
    assert!(with_everything.main.is_some());
    assert_eq!(with_nothing.app_g, with_everything.app_g);
    let manual = run_yaml(
        "fespalier:\n  main: manual\n",
        &[("page.dart", HOME), ("app.dart", APP)],
    );
    assert_eq!(with_nothing.app_g, manual.app_g);
    let generated = run_yaml("fespalier:\n  main: generated\n", &[("page.dart", HOME)]);
    assert_eq!(with_nothing.app_g, generated.app_g);
}

// --- diagnostics -------------------------------------------------------------

#[test]
fn root_files_below_the_root_are_ignored_with_a_warning() {
    for file in ["app.dart", "startup.dart", "splash.dart"] {
        let other = "class OtherPage extends StatelessWidget { const OtherPage({super.key}); }";
        let g = run_gen(&[
            ("page.dart", HOME),
            ("sub/page.dart", other),
            (&format!("sub/{file}"), "const x = 1;"),
        ]);
        assert_eq!(
            g.diags,
            [format!(
                "! sub/{file}  {file} is only read at the root of the app folder, so this one is ignored"
            )]
        );
        assert!(g.main.is_none());
    }
}

#[test]
fn app_dart_needs_a_widget() {
    assert_eq!(
        errors(&[("page.dart", HOME), ("app.dart", "const x = 1;")]),
        ["✗ app.dart  expected a public widget class"]
    );
    let two = "class A extends StatelessWidget {}\nclass B extends StatelessWidget {}";
    let d = errors(&[("page.dart", HOME), ("app.dart", two)]);
    assert!(
        d[0].ends_with(
            "expected one public widget class, found A, B; make the others private (`_Name`)"
        ),
        "{d:?}"
    );
}

#[test]
fn app_dart_needs_the_router() {
    let d = errors(&[
        ("page.dart", HOME),
        (
            "app.dart",
            "class App extends StatelessWidget { const App({super.key}); }",
        ),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].ends_with("the app's widget gets the router: add `required this.router` (a `GoRouter`) and pass it to `MaterialApp.router(routerConfig: router)`. If this file is not the app around the router, move it out of the app folder's root or set `main: manual`"),
        "{d:?}"
    );
    assert!(d[0].starts_with("✗ app.dart:1  "), "{d:?}");
}

#[test]
fn app_dart_takes_no_other_required_parameter() {
    let app = "class App extends StatelessWidget {\n  const App({super.key, required this.router, required this.flavor});\n  final GoRouter router;\n  final String flavor;\n}";
    let d = errors(&[("page.dart", HOME), ("app.dart", app)]);
    assert_eq!(
        d,
        [
            "✗ app.dart:2  `flavor`: app.dart's widget is built by the generated main(), which only gives it `router`; make `flavor` optional, or work it out inside the widget"
        ]
    );
}

#[test]
fn the_router_must_be_a_router() {
    let app = "class App extends StatelessWidget {\n  const App({super.key, required this.router});\n  final String router;\n}";
    let d = errors(&[("page.dart", HOME), ("app.dart", app)]);
    assert_eq!(
        d,
        ["✗ app.dart:2  `router` must be a `GoRouter` (or a `RouterConfig<Object>`), not String"]
    );
}

#[test]
fn router_fn_has_a_fixed_shape() {
    for bad in [
        "GoRouter router(int x) => AppRoutes.router();",
        "String router() => '';",
    ] {
        let app = format!("{APP}\n{bad}");
        let d = errors(&[("page.dart", HOME), ("app.dart", &app)]);
        assert_eq!(d.len(), 1, "{d:?}");
        assert!(
            d[0].ends_with("router() builds the app's router: declare it `GoRouter router()`, with no parameters, and return `AppRoutes.router(...)`"),
            "{d:?}"
        );
    }
}

#[test]
fn startup_dart_must_export_something() {
    assert_eq!(
        errors(&[("page.dart", HOME), ("startup.dart", "const x = 1;")]),
        [
            "✗ startup.dart  startup.dart exports none of `startup()`, `zone()`, `providerObservers`, `routerObservers` or `retry()`; add one, or delete the file"
        ]
    );
}

#[test]
fn startup_takes_no_parameters_and_returns_something_known() {
    let d = errors(&[
        ("page.dart", HOME),
        ("startup.dart", "Future<void> startup(Ref ref) async {}"),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].ends_with("startup() takes no parameters: it runs before the ProviderScope exists, so return the overrides it makes (`Future<List<Override>> startup()`) instead"),
        "{d:?}"
    );
    for bad in ["Future<int> startup() async => 1;", "startup() {}"] {
        let d = errors(&[("page.dart", HOME), ("startup.dart", bad)]);
        assert_eq!(d.len(), 1, "{bad}: {d:?}");
        assert!(
            d[0].ends_with("startup() must return `Future<void>` or `void`, or the providers it overrides: `Future<List<Override>>` or `List<Override>`"),
            "{d:?}"
        );
    }
}

#[test]
fn zone_has_a_fixed_shape() {
    for bad in [
        "Future<void> zone() async {}",
        "Future<void> zone(Future<void> Function() body, int x) async {}",
        "void zone(Future<void> Function() body) {}",
        "Future<void> zone(void Function() body) async {}",
    ] {
        let d = errors(&[("page.dart", HOME), ("startup.dart", bad)]);
        assert_eq!(d.len(), 1, "{bad}: {d:?}");
        assert!(
            d[0].ends_with("zone() wraps all of main(): declare it `Future<void> zone(Future<void> Function() body)` and call `body()` inside it"),
            "{bad}: {d:?}"
        );
    }
}

#[test]
fn retry_has_a_fixed_shape() {
    let d = errors(&[
        ("page.dart", HOME),
        ("startup.dart", "Duration? retry(int count) => null;"),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].ends_with("retry() is the ProviderScope's retry policy: `Duration? retry(int retryCount, Object error)`"),
        "{d:?}"
    );
}

#[test]
fn the_observer_lists_are_not_functions() {
    for (name, ty) in [
        ("providerObservers", "ProviderObserver"),
        ("routerObservers", "NavigatorObserver"),
    ] {
        let d = errors(&[
            ("page.dart", HOME),
            ("startup.dart", &format!("List<{ty}> {name}() => [];")),
        ]);
        assert_eq!(d.len(), 1, "{d:?}");
        assert!(
            d[0].ends_with(&format!(
                "`{name}` is a list, not a function: `List<{ty}> get {name} => [...];`"
            )),
            "{d:?}"
        );
    }
}

#[test]
fn router_observers_clash_with_a_router_of_app_dart() {
    let app = format!("{APP}\nGoRouter router() => AppRoutes.router();");
    let d = errors(&[
        ("page.dart", HOME),
        ("app.dart", &app),
        (
            "startup.dart",
            "final routerObservers = <NavigatorObserver>[];",
        ),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].ends_with("app.dart's router() builds the router itself, so `routerObservers` is not used: pass them to `AppRoutes.router(observers: ...)` there, and remove this one"),
        "{d:?}"
    );
}

#[test]
fn splash_asks_only_for_error_stack_trace_and_retry_and_nullable() {
    let d = errors(&[
        ("page.dart", HOME),
        ("startup.dart", "Future<void> startup() async {}"),
        (
            "splash.dart",
            "class Splash extends StatelessWidget { const Splash({super.key, required this.theme}); final String theme; }",
        ),
    ]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(
        d[0].ends_with("splash.dart is built before the app, so it can ask only for `error`, `stackTrace` and `retry` (each null while startup() runs); `theme` is none of them"),
        "{d:?}"
    );
    for (name, ty, written) in [
        ("error", "Object", "Object?"),
        ("stackTrace", "StackTrace", "StackTrace?"),
        ("retry", "VoidCallback", "VoidCallback?"),
    ] {
        let splash = format!(
            "class Splash extends StatelessWidget {{ const Splash({{super.key, required this.{name}}}); final {ty} {name}; }}"
        );
        let d = errors(&[
            ("page.dart", HOME),
            ("startup.dart", "Future<void> startup() async {}"),
            ("splash.dart", &splash),
        ]);
        assert_eq!(d.len(), 1, "{name}: {d:?}");
        assert!(
            d[0].ends_with(&format!(
                "splash.dart is shown while startup() runs too, when there is no `{name}`: make it `{written} {name}`"
            )),
            "{name}: {d:?}"
        );
    }
}

#[test]
fn a_splash_with_nothing_to_show_it_for_is_a_warning() {
    let g = run_gen(&[("page.dart", HOME), ("splash.dart", SPLASH)]);
    assert_eq!(
        g.diags,
        [
            "! splash.dart  splash.dart is shown while startup() runs and when it fails, and startup.dart has no startup(), so it is never shown"
        ]
    );
    assert!(g.main.is_some());
}

#[test]
fn splash_may_be_a_function_and_gets_only_what_it_asks_for() {
    let main = main_of(&[
        ("page.dart", HOME),
        ("startup.dart", "Future<void> startup() async {}"),
        (
            "splash.dart",
            "Widget splash({Object? error, StackTrace? stackTrace, void Function()? retry}) => const SizedBox();",
        ),
    ]);
    has(
        &main,
        &["_i1.splash(error: error, stackTrace: stackTrace, retry: retry);"],
    );
    let main = main_of(&[
        ("page.dart", HOME),
        ("startup.dart", "Future<void> startup() async {}"),
        (
            "splash.dart",
            "class Splash extends StatelessWidget { const Splash({super.key}); }",
        ),
    ]);
    has(&main, &["const _i1.Splash();"]);
}

// --- gen writes it -----------------------------------------------------------

#[test]
fn gen_writes_the_main_file_and_names_it() {
    let dir = project("", &[("page.dart", HOME), ("app.dart", APP)]);
    let first = crate::generate(dir.path(), true).unwrap();
    assert!(first.wrote);
    assert_eq!(first.output, "lib/app.g.dart, lib/app.main.g.dart");
    assert_eq!(
        first.line(),
        "✓ 1 route → lib/app.g.dart, lib/app.main.g.dart"
    );
    let written = fs::read_to_string(dir.path().join("lib/app.main.g.dart")).unwrap();
    assert!(
        written.contains("abstract final class AppMain {"),
        "{written}"
    );
    let again = crate::generate(dir.path(), true).unwrap();
    assert!(!again.wrote);
    assert_eq!(
        again.line(),
        "✓ 1 route, lib/app.g.dart, lib/app.main.g.dart unchanged"
    );
}

#[test]
fn gen_writes_no_main_without_root_files_and_check_writes_nothing() {
    let dir = project("", &[("page.dart", HOME)]);
    let o = crate::generate(dir.path(), true).unwrap();
    assert_eq!(o.output, "lib/app.g.dart");
    assert!(!dir.path().join("lib/app.main.g.dart").exists());

    let dir = project("", &[("page.dart", HOME), ("app.dart", APP)]);
    crate::generate(dir.path(), false).unwrap();
    assert!(!dir.path().join("lib/app.g.dart").exists());
    assert!(!dir.path().join("lib/app.main.g.dart").exists());
}

#[test]
fn an_error_leaves_every_file_unchanged_and_names_them() {
    let dir = project(
        "fespalier:\n  output_manifest: lib/app.routes.g.dart\n",
        &[
            ("page.dart", HOME),
            ("app.dart", "class App extends StatelessWidget {}"),
        ],
    );
    let err = crate::generate(dir.path(), true).unwrap_err().to_string();
    assert_eq!(
        err,
        "1 error(s); lib/app.g.dart, lib/app.routes.g.dart and lib/app.main.g.dart left unchanged"
    );
    let dir = project("", &[("page.dart", HOME), ("app.dart", "const x = 1;")]);
    let err = crate::generate(dir.path(), true).unwrap_err().to_string();
    assert_eq!(
        err,
        "1 error(s); lib/app.g.dart and lib/app.main.g.dart left unchanged"
    );
    assert!(!dir.path().join("lib/app.main.g.dart").exists());
}

#[test]
fn the_manifest_library_and_the_main_file_are_both_written() {
    let dir = project(
        "fespalier:\n  output_manifest: lib/app.routes.g.dart\n",
        &[("page.dart", HOME), ("app.dart", APP)],
    );
    let o = crate::generate(dir.path(), true).unwrap();
    assert_eq!(
        o.output,
        "lib/app.g.dart, lib/app.routes.g.dart, lib/app.main.g.dart"
    );
}

// --- fsp init ----------------------------------------------------------------

#[test]
fn init_writes_app_dart_and_the_generated_main() {
    let dir = project("", &[]);
    crate::init::run(dir.path()).unwrap();
    let app = fs::read_to_string(dir.path().join("lib/app/app.dart")).unwrap();
    assert!(app.contains("class App extends StatelessWidget"), "{app}");
    assert!(app.contains("title: 'demo'"), "{app}");
    assert!(app.contains("routerConfig: router"), "{app}");
    let main = fs::read_to_string(dir.path().join("lib/app.main.g.dart")).unwrap();
    assert!(
        main.contains("static Widget app(GoRouter router) => _i0.App(router: router);"),
        "{main}"
    );
}

#[test]
fn init_keeps_an_existing_app_dart_and_never_touches_main_dart() {
    let dir = project("", &[("app.dart", APP)]);
    fs::write(dir.path().join("lib/main.dart"), "// mine\n").unwrap();
    crate::init::run(dir.path()).unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("lib/app/app.dart")).unwrap(),
        APP
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("lib/main.dart")).unwrap(),
        "// mine\n"
    );
}

#[test]
fn init_with_main_manual_writes_no_app_dart() {
    let dir = project("fespalier:\n  main: manual\n", &[]);
    crate::init::run(dir.path()).unwrap();
    assert!(!dir.path().join("lib/app/app.dart").exists());
    assert!(!dir.path().join("lib/app.main.g.dart").exists());
    assert!(dir.path().join("lib/app/page.dart").exists());
}

/// What `fsp init` writes is what `dart format` leaves alone, whatever the package is called
/// (a long name makes the formatter put each argument on a line). Without `dart`, nothing to
/// compare it with.
#[test]
fn init_app_dart_is_dart_format_clean_for_short_and_long_names() {
    for name in [
        "demo",
        "twenty_two_chars_name_",
        "a_much_longer_package_name_for_the_app",
    ] {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("pubspec.yaml"), format!("name: {name}\n")).unwrap();
        crate::init::run(dir.path()).unwrap();
        let path = dir.path().join("lib/app/app.dart");
        let written = fs::read_to_string(&path).unwrap();
        assert!(written.contains(&format!("title: '{name}'")), "{written}");
        let (formatted, warning) = crate::format::format_dart(&written, &path);
        if warning.is_some() {
            return;
        }
        assert_eq!(written, formatted, "{name}");
    }
}

// --- adapters (since 0.9.0) --------------------------------------------------

/// A pubspec that depends on the adapters it lists.
fn with_adapters(list: &str, extra: &str) -> String {
    format!(
        "dependencies:\n  fespalier_sentry: ^1.0.0\n  fespalier_connectivity: ^1.0.0\nfespalier:\n  adapters: {list}\n{extra}"
    )
}

#[test]
fn no_key_an_empty_list_and_a_bare_key_are_no_adapters() {
    assert!(Config::default().adapters.is_empty());
    assert!(cfg("").unwrap().adapters.is_empty());
    assert!(
        cfg("fespalier:\n  adapters: []\n")
            .unwrap()
            .adapters
            .is_empty()
    );
    assert!(
        cfg("fespalier:\n  adapters:\n")
            .unwrap()
            .adapters
            .is_empty()
    );
}

#[test]
fn adapters_are_read_in_order() {
    let c = cfg(&with_adapters(
        "[fespalier_connectivity, fespalier_sentry]",
        "",
    ))
    .unwrap();
    assert_eq!(c.adapters, ["fespalier_connectivity", "fespalier_sentry"]);
    let block = "dependencies:\n  a_b2: any\nfespalier:\n  adapters:\n    - a_b2\n";
    assert_eq!(cfg(block).unwrap().adapters, ["a_b2"]);
}

/// The message of a pubspec that is refused, without the file's path.
fn refused(yaml: &str) -> String {
    format!("{:#}", cfg(yaml).unwrap_err())
}

#[test]
fn a_bad_adapters_list_says_what_it_wants() {
    // A string is not a list, and neither is a map or a list inside one.
    assert_eq!(
        refused("fespalier:\n  adapters: fespalier_sentry\n"),
        "invalid pubspec.yaml: fespalier.adapters: invalid type: string \"fespalier_sentry\", expected a sequence at line 3 column 13"
    );
    assert_eq!(
        refused("fespalier:\n  adapters:\n    - fespalier_sentry: {x: 1}\n"),
        "invalid pubspec.yaml: fespalier.adapters[0]: invalid type: map, expected a string at line 4 column 7"
    );
    assert!(
        refused("fespalier:\n  adapters:\n    - [a]\n").contains("invalid type: sequence"),
        "a nested list"
    );
    // Each name is a Dart package name; a YAML number arrives as its text.
    for raw in ["Sentry", "fespalier-sentry", "3", "_x", "a.b", "a b"] {
        assert_eq!(
            refused(&format!("fespalier:\n  adapters: [\"{raw}\"]\n")),
            format!(
                "`fespalier.adapters` lists Dart packages by name, like `fespalier_sentry`; `{raw}` is not one"
            ),
            "{raw}"
        );
    }
    assert!(refused("fespalier:\n  adapters: [3]\n").ends_with("`3` is not one"));
    assert_eq!(
        refused(&with_adapters("[fespalier_sentry, fespalier_sentry]", "")),
        "`fespalier.adapters` lists `fespalier_sentry` twice"
    );
    assert_eq!(
        refused("dependencies:\n  fespalier: any\nfespalier:\n  adapters: [fespalier]\n"),
        "`fespalier.adapters` lists packages that plug into fespalier's generated main(); `fespalier` is the framework itself, not an adapter"
    );
    let not_there = "`fespalier.adapters` lists `fespalier_flags`, which is not under `dependencies:` in pubspec.yaml; add it there (next to fespalier, at the same git ref)";
    assert_eq!(refused(&with_adapters("[fespalier_flags]", "")), not_there);
    // No dependencies at all, and one under `dev_dependencies:` only, are the same.
    assert_eq!(
        refused("fespalier:\n  adapters: [fespalier_flags]\n"),
        not_there
    );
    assert_eq!(
        refused(
            "dev_dependencies:\n  fespalier_flags: any\nfespalier:\n  adapters: [fespalier_flags]\n"
        ),
        not_there
    );
    // `main: manual` and `generated` are both fine with adapters (since 0.11.0).
    assert!(cfg(&with_adapters("[fespalier_sentry]", "  main: manual\n")).is_ok());
    assert!(cfg("fespalier:\n  main: manual\n  adapters: []\n").is_ok());
    assert!(cfg(&with_adapters("[fespalier_sentry]", "  main: generated\n")).is_ok());
}

#[test]
fn the_unknown_key_list_ends_with_adapters() {
    let err = refused("fespalier:\n  nope: 1\n");
    assert!(
        err.contains("`main`, `tasks`, `adapters` at line 3 column 3"),
        "{err}"
    );
}

#[test]
fn adapters_write_a_main_with_no_root_file() {
    let yaml = with_adapters("[fespalier_sentry]", "");
    let g = run_yaml(&yaml, &[("page.dart", HOME)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    let main = g.main.expect("an adapter wants a generated main()");
    has(
        &main,
        &[
            "static Future<void> run() => AppAdapters.zone(_main);",
            "    WidgetsFlutterBinding.ensureInitialized();\n    if (AppAdapters.beforeRun() case final ready?) await ready;\n    final launch = AppAdapters.launch();\n    _launch = launch is Future<InboundLaunch?> ? await launch : launch;\n    runApp(root());",
            "static InboundLaunch? get launch => _launch;",
            "static Widget root({GoRouter Function() router = _router}) => AppAdapters.wrap(StartupGate(\n    extraOverrides: _extraOverrides,\n    observers: _providerObservers,\n    attach: AppRoutes.attach,\n    router: router,\n    app: app,\n  ));",
            "everything runs inside the adapters' zones: the binding,",
            "static List<NavigatorObserver> routerObservers() => [...AppAdapters.routerObservers()];",
            "GoRouter _router() => AppRoutes.router(launch: AppMain.launch, observers: AppMain.routerObservers());",
            "List<Override> _extraOverrides() => [...AppAdapters.overrides()];",
            "List<ProviderObserver> _providerObservers() => [...AppAdapters.providerObservers()];",
        ],
    );
    has_not(&main, &["fespalier_adapter.dart", "_a0"]);
    // Without the key the same app writes no main at all.
    let plain = run_gen(&[("page.dart", HOME)]);
    assert!(plain.main.is_none());
}

#[test]
fn manual_main_with_adapters_writes_app_adapters_and_no_main() {
    let yaml = with_adapters(
        "[fespalier_sentry, fespalier_connectivity]",
        "  main: manual\n",
    );
    let g = run_yaml(&yaml, &[("page.dart", HOME)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    assert!(g.main.is_none());
    has(
        &g.app_g,
        &[
            "import 'package:fespalier/startup.dart' show FespalierAdapters, Override;\nimport 'package:fespalier_sentry/fespalier_adapter.dart' as _a0;\nimport 'package:fespalier_connectivity/fespalier_adapter.dart' as _a1;\n",
            "abstract final class AppAdapters {",
            "static final _all = FespalierAdapters([_a0.adapter, _a1.adapter]);",
            "static Future<void> zone(Future<void> Function() body) => _all.zone(body);",
            "static Future<void>? beforeRun() => _all.beforeRun();",
            "static List<Override> overrides() => _all.overrides();",
            "static List<ProviderObserver> providerObservers() => _all.providerObservers();",
            "static List<NavigatorObserver> routerObservers() => _all.routerObservers();",
            "static Widget wrap(Widget root) => _all.wrap(root);",
        ],
    );
}

#[test]
fn no_adapters_no_app_adapters() {
    let g = run_gen(&[("page.dart", HOME)]);
    has_not(
        &g.app_g,
        &["AppAdapters", "FespalierAdapters", "fespalier_adapter.dart"],
    );
    let g = run_yaml("fespalier:\n  main: manual\n", &[("page.dart", HOME)]);
    has_not(&g.app_g, &["AppAdapters"]);
}

#[test]
fn attach_is_emitted_for_adapters_alone() {
    let g = run_yaml(
        &with_adapters("[fespalier_sentry]", ""),
        &[("page.dart", HOME)],
    );
    has(
        &g.app_g,
        &[
            "  /// Lets DevTools and the adapters follow [router]: [router] calls it,",
            "static void attach(GoRouter router, [ProviderContainer? container]) {",
            "    if (container != null) AppAdapters._all.attach(router, container);",
            "      attach(router);\n      return router;",
        ],
    );
    // Without adapters (and no observe or telemetry) there is no `attach` to call.
    let plain = run_gen(&[("page.dart", HOME)]);
    has_not(&plain.app_g, &["static void attach", "ProviderContainer"]);
}

#[test]
fn two_adapters_around_startup_dart_are_the_documented_main() {
    let yaml = with_adapters("[fespalier_sentry, fespalier_connectivity]", "");
    let g = run_yaml(
        &yaml,
        &[
            ("page.dart", HOME),
            ("app.dart", APP),
            ("startup.dart", STARTUP_FULL),
        ],
    );
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    let main = g.main.unwrap();
    has(
        &main,
        &[
            "import 'package:flutter/widgets.dart';\n\nimport 'app.g.dart';",
            "everything runs inside the adapters' zones and startup.dart's `zone()`: the binding,",
            // The first adapter is the outermost: zone, wrapper.
            "static Future<void> run() => AppAdapters.zone(() => _i1.zone(_main));",
            "    WidgetsFlutterBinding.ensureInitialized();\n    if (AppAdapters.beforeRun() case final ready?) await ready;\n    final launch = AppAdapters.launch();\n    _launch = launch is Future<InboundLaunch?> ? await launch : launch;\n    runApp(root());",
            "static InboundLaunch? get launch => _launch;",
            "=> AppAdapters.wrap(StartupGate(\n    extraOverrides: _extraOverrides,\n    overrides: _i1.startup,\n    observers: _providerObservers,\n    retry: _i1.retry,\n    attach: AppRoutes.attach,\n    router: router,\n    app: app,\n  ));",
            "static Widget app(GoRouter router) => _i0.App(router: router);",
            // The adapters' observers come first, then startup.dart's.
            "static List<NavigatorObserver> routerObservers() => [...AppAdapters.routerObservers(), ..._i1.routerObservers];",
            "GoRouter _router() => AppRoutes.router(launch: AppMain.launch, observers: AppMain.routerObservers());",
            "List<Override> _extraOverrides() => [...AppAdapters.overrides()];",
            "List<ProviderObserver> _providerObservers() => [...AppAdapters.providerObservers(), ..._i1.providerObservers];",
        ],
    );
}

#[test]
fn an_app_dart_router_that_ignores_the_adapters_observers_is_warned_about() {
    let yaml = with_adapters("[fespalier_sentry]", "");
    let own = format!("{APP}\nGoRouter router() => AppRoutes.router(restorationScopeId: 'r');");
    let g = run_yaml(&yaml, &[("page.dart", HOME), ("app.dart", &own)]);
    assert_eq!(g.diags.len(), 2, "{:?}", g.diags);
    assert!(
        g.diags[0].starts_with("! app.dart:")
            && g.diags[0].ends_with("app.dart's router() builds the router itself, so the adapters' router observers are not added: pass `observers: AppMain.routerObservers()` to `AppRoutes.router(...)` there"),
        "{:?}",
        g.diags
    );
    // It is a warning: the main is still written, with the router app.dart builds.
    let main = g.main.unwrap();
    has(
        &main,
        &[
            "GoRouter _router() => _i0.router();",
            "static List<NavigatorObserver> routerObservers() => [...AppAdapters.routerObservers()];",
        ],
    );
    // A router() that passes them on has nothing to be told.
    let passes = format!(
        "import '../app.main.g.dart';\n{APP}\nGoRouter router() => AppRoutes.router(launch: AppMain.launch, observers: AppMain.routerObservers());"
    );
    let g = run_yaml(&yaml, &[("page.dart", HOME), ("app.dart", &passes)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    // And with no adapters there is no warning, whatever router() does.
    let g = run_gen(&[("page.dart", HOME), ("app.dart", &own)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
}

#[test]
fn an_app_dart_router_that_ignores_the_launch_is_warned_about() {
    let yaml = with_adapters("[fespalier_sentry]", "");
    let own = format!(
        "import '../app.main.g.dart';\n{APP}\nGoRouter router() => AppRoutes.router(observers: AppMain.routerObservers());"
    );
    let g = run_yaml(&yaml, &[("page.dart", HOME), ("app.dart", &own)]);
    assert_eq!(g.diags.len(), 1, "{:?}", g.diags);
    assert!(
        g.diags[0].starts_with("! app.dart:")
            && g.diags[0].ends_with("app.dart's router() builds the router itself, so the adapters' launch is not used: pass `launch: AppMain.launch` to `AppRoutes.router(...)` there"),
        "{:?}",
        g.diags
    );
    // The launch is still asked: app.dart may read AppMain.launch some other way.
    has(
        &g.main.unwrap(),
        &["static InboundLaunch? get launch => _launch;"],
    );
}

#[test]
fn the_gate_gets_attach_wherever_app_routes_has_one() {
    let observe = "void onEnter(Ref ref, {required TypedLocation route}) {}\n";
    let g = run_gen(&[
        ("page.dart", HOME),
        ("app.dart", APP),
        ("observe.dart", observe),
    ]);
    has(&g.main.unwrap(), &["    attach: AppRoutes.attach,\n"]);
    let g = run_yaml(
        "fespalier:\n  telemetry: true\n",
        &[("page.dart", HOME), ("app.dart", APP)],
    );
    has(&g.main.unwrap(), &["    attach: AppRoutes.attach,\n"]);
    let g = run_gen(&[("page.dart", HOME), ("app.dart", APP)]);
    has_not(&g.main.unwrap(), &["attach:"]);
}

#[test]
fn launch_is_asked_only_with_adapters() {
    let g = run_gen(&[("page.dart", HOME), ("app.dart", APP)]);
    let main = g.main.unwrap();
    has_not(&main, &["launch", "InboundLaunch"]);
}

#[test]
fn on_enter_only_with_adapters() {
    let with = run_yaml(
        &with_adapters("[fespalier_sentry]", ""),
        &[("page.dart", HOME)],
    );
    has(
        &with.app_g,
        &[
            "        onEnter: onEnter,\n",
            "static FutureOr<OnEnterResult> onEnter(",
            ") => AppAdapters._all.onEnter(context, current, next, router);",
            "import 'dart:async';",
            "  static FutureOr<InboundLaunch?> launch() => _all.launch();",
            "    }, links: true);",
        ],
    );
    let plain = run_gen(&[("page.dart", HOME)]);
    has_not(
        &plain.app_g,
        &["onEnter", "OnEnterResult", "dart:async", "links:"],
    );
    // Without adapters the router still takes a launch.
    has(
        &plain.app_g,
        &[
            "InboundLaunch? launch,",
            "return launchRouter(launch, (launch) {",
            "overridePlatformDefaultLocation: launch != null,",
            "    });\n  }",
        ],
    );
}

#[test]
fn links_flag_with_telemetry() {
    let tel = run_yaml("fespalier:\n  telemetry: true\n", &[("page.dart", HOME)]);
    has(&tel.app_g, &["    }, links: true);"]);
    let adapters = run_yaml(
        &with_adapters("[fespalier_sentry]", ""),
        &[("page.dart", HOME)],
    );
    has(&adapters.app_g, &["    }, links: true);"]);
    let neither = run_gen(&[("page.dart", HOME)]);
    has_not(&neither.app_g, &["links: true"]);
}

#[test]
fn the_hooks_fill_the_new_places_and_leave_the_old_ones_alone() {
    let dir = project(
        "",
        &[
            ("page.dart", HOME),
            ("startup.dart", STARTUP_FULL),
            ("app.dart", APP),
        ],
    );
    let cfg = Config::load(dir.path()).unwrap();
    let app_dir = dir.path().join("lib/app");
    let mut diags = crate::diag::Diags::default();
    let tree = scan::scan(&app_dir, &mut diags).unwrap();
    let libs = enums::Libs::for_app(&app_dir, &cfg);
    let app = resolve::resolve(&tree, true, cfg.remount, false, &libs, &mut diags);
    let emit = |hooks: MainHooks| {
        let mut diags = crate::diag::Diags::default();
        entry::emit(&tree, &app, &cfg, &hooks, &mut diags).unwrap()
    };
    let main = emit(MainHooks {
        overrides: vec!["_o.overrides()".into()],
        router_observers: vec!["_o.observers()".into()],
        root_wrappers: vec!["_o.wrap".into()],
        ..MainHooks::default()
    });
    has(
        &main,
        &[
            "=> _o.wrap(StartupGate(\n    extraOverrides: _extraOverrides,\n    overrides: _i1.startup,",
            "  ));\n",
            "static List<NavigatorObserver> routerObservers() => [..._o.observers(), ..._i1.routerObservers];",
            "GoRouter _router() => AppRoutes.router(observers: AppMain.routerObservers());",
            "List<Override> _extraOverrides() => [..._o.overrides()];",
            // The zone is startup.dart's alone: no adapter wrapped it.
            "static Future<void> run() => _i1.zone(_main);",
            "everything runs inside startup.dart's `zone()`: the binding,",
        ],
    );
    // With every field empty the file is what the root files alone say.
    let plain = emit(MainHooks::default());
    has_not(
        &plain,
        &[
            "extraOverrides",
            "routerObservers()",
            "_extraOverrides",
            "_a0",
        ],
    );
}

#[test]
fn adapters_with_each_root_file_combination() {
    let yaml = with_adapters("[fespalier_sentry]", "");
    // app.dart alone: the router is AppRoutes.router with the adapters' observers.
    let g = run_yaml(&yaml, &[("page.dart", HOME), ("app.dart", APP)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    has(
        &g.main.unwrap(),
        &[
            "static Future<void> run() => AppAdapters.zone(_main);",
            "static Widget app(GoRouter router) => _i0.App(router: router);",
            "static List<NavigatorObserver> routerObservers() => [...AppAdapters.routerObservers()];",
        ],
    );
    // startup.dart with a zone, and none of its observers: startup's zone is inside the adapter's.
    let startup = "Future<void> zone(Future<void> Function() body) => body();";
    let g = run_yaml(&yaml, &[("page.dart", HOME), ("startup.dart", startup)]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    has(
        &g.main.unwrap(),
        &[
            "static Future<void> run() => AppAdapters.zone(() => _i0.zone(_main));",
            "everything runs inside the adapters' zones and startup.dart's `zone()`: the binding,",
            "static List<NavigatorObserver> routerObservers() => [...AppAdapters.routerObservers()];",
        ],
    );
    // startup.dart's own provider observers come after the adapters'.
    let observers = "List<ProviderObserver> get providerObservers => [];";
    let g = run_yaml(&yaml, &[("page.dart", HOME), ("startup.dart", observers)]);
    has(
        &g.main.unwrap(),
        &[
            "List<ProviderObserver> _providerObservers() => [...AppAdapters.providerObservers(), ..._i0.providerObservers];",
        ],
    );
}

#[test]
fn an_observe_dart_gets_the_container_from_the_generated_main() {
    let g = run_gen(&[
        ("page.dart", HOME),
        ("app.dart", APP),
        (
            "observe.dart",
            "import 'package:fespalier/fespalier.dart';\nvoid onEnter() {}",
        ),
    ]);
    assert!(g.diags.is_empty(), "{:?}", g.diags);
    has(&g.main.unwrap(), &["    attach: AppRoutes.attach,"]);
    let plain = run_gen(&[("page.dart", HOME), ("app.dart", APP)]);
    has_not(&plain.main.unwrap(), &["attach: AppRoutes.attach"]);
}
