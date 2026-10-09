//! The feature table of `fsp create`: the one place that says what `--features x` adds to a new
//! app. The plan, `--list-features`, the CI matrix and the `--local-packages` overrides all read
//! this table, and the tests in `create_tests.rs` check it against `packages/` and the
//! companions' own pubspecs, so a package or a dependency cannot be forgotten.

/// A dependency that is not fespalier's: a version range, or a git commit (never a tag: a tag
/// `ref: v…` would be read as fespalier's own version by `cli/tests/versions.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `name: "<range>"`. The range is third party: it is written outside any release-please
    /// annotation, and never holds fespalier's version.
    Range(&'static str),
    /// `git: {url, ref: <commit>}`, pinned by the full 40-digit commit.
    Git {
        url: &'static str,
        commit: &'static str,
    },
}

/// One third-party package a feature adds to `dependencies:`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThirdParty {
    pub name: &'static str,
    pub source: Source,
}

/// When a step of `startup()` runs, relative to the others: the composer sorts by it (then by
/// the table's order). Telemetry sinks go first, because `docs/observability.md` has the sink
/// installed before anything that reports through it (`restoreAuth` included).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[allow(
    dead_code,
    reason = "the auth feature that needs the Session phase lands later; the composer and its tests already read it"
)]
pub enum Phase {
    /// A telemetry sink (`FespalierTelemetry.install`, `combine`).
    Telemetry,
    /// Restoring the session (`restoreAuth`).
    Session,
    /// Everything else.
    Rest,
}

/// What a step is in the body of `startup()`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepKind {
    /// A statement, ending with `;`, run before the overrides are returned.
    Statement,
    /// An element of the `List<Override>` that `startup()` returns, with its trailing comma.
    Override,
}

/// One piece of `lib/app/startup.dart`.
#[derive(Debug, Clone, Copy)]
pub struct Step {
    pub kind: StepKind,
    pub phase: Phase,
    /// A `//` comment line above it (without the `//`); empty for none.
    pub comment: &'static str,
    /// Dart formatted as `dart format` leaves it, for the indent it is written at: one line, or
    /// several when `dart format` would wrap it (the lines after the first are indented
    /// relative to it, and the composer adds the indent of the list it goes in).
    pub code: &'static str,
    /// Whether `code` awaits: `startup()` is then `async`. The tests check it against `code`.
    pub awaits: bool,
}

/// What a feature adds to the files that every feature shares: `lib/app/startup.dart`,
/// `lib/app/app.dart` and `lib/main.dart`. `compose.rs` merges the fragments of all the chosen
/// features, so no feature writes one of those files itself.
#[derive(Debug, Clone, Copy)]
pub struct Startup {
    /// Library URIs `startup.dart` imports (`package:fespalier/fespalier.dart`), or a URI and the
    /// rest of the directive (`package:flutter/foundation.dart show kIsWeb`).
    pub imports: &'static [&'static str],
    pub steps: &'static [Step],
    /// Top-level declarations of `startup.dart` (formatted Dart, `{name}` is the app's package
    /// name), written after the imports: a value the steps and the observers share.
    pub decls: &'static [&'static str],
    /// A whole `zone()` function (formatted Dart) for `startup.dart`; at most one feature has it.
    /// It passes `{body}` where the app's body goes (see [`body_wrapper`](Self::body_wrapper)).
    pub zone: Option<&'static str>,
    /// A `zone()` that is used only when no feature has a [`zone`](Self::zone) of its own: the
    /// zone of a library that another zone makes redundant. At most one feature has it.
    pub weak_zone: Option<&'static str>,
    /// The name of a top-level `Future<void> f(Future<void> Function() body)` (in
    /// [`decls`](Self::decls)) that must run before the app's `body` inside the zone: the zone of
    /// another feature passes `{body}` through it. A library that has to start with the process
    /// and not with the app (a test that builds the app does not start it) is wrapped this way.
    pub body_wrapper: Option<&'static str>,
    /// Dart expressions of telemetry sinks. The composer installs them all in one slot, first
    /// thing in `startup()`: `FespalierTelemetry.install(sink)`, and `combine([...])` for several.
    pub sinks: &'static [&'static str],
    /// Elements of the `providerObservers` list (each with its trailing comma).
    pub provider_observers: &'static [&'static str],
    /// Elements of the `routerObservers` list (each with its trailing comma).
    pub router_observers: &'static [&'static str],
    /// Library URIs `app.dart` imports besides its own.
    pub app_imports: &'static [&'static str],
    /// Library URIs `main.dart` imports besides its own.
    pub main_imports: &'static [&'static str],
}

impl Startup {
    /// A feature that adds nothing to the shared files.
    pub const NONE: Startup = Startup {
        imports: &[],
        steps: &[],
        decls: &[],
        zone: None,
        weak_zone: None,
        body_wrapper: None,
        sinks: &[],
        provider_observers: &[],
        router_observers: &[],
        app_imports: &[],
        main_imports: &[],
    };
}

/// What `--features <id>` adds.
#[derive(Debug, Clone, Copy)]
pub struct Recipe {
    /// What the user types: lower case, digits and `_`.
    pub id: &'static str,
    /// One line, for `--list-features`.
    pub description: &'static str,
    /// The `packages/<name>` companions it depends on, by git at fespalier's tag.
    pub companions: &'static [&'static str],
    /// Dependencies of other repositories.
    pub third_party: &'static [ThirdParty],
    /// Dependencies of other repositories that only its tests need (`dev_dependencies:`).
    pub dev_third_party: &'static [ThirdParty],
    /// The lowest Flutter it works on, `major.minor`.
    pub flutter_floor: &'static str,
    /// Lines of the `fespalier:` section of the pubspec, each as written under the key.
    pub config: &'static [&'static str],
    /// `(template, path)`: files it writes, the path relative to the app.
    pub files: &'static [(&'static str, &'static str)],
    /// Files of the base app that it takes out because it writes its own in their place (the
    /// tabs layout replaces the root layout and the home page). Paths of the base app only.
    pub replaces: &'static [&'static str],
    /// What it adds to `startup.dart`, `app.dart` and `main.dart`.
    pub startup: Startup,
    /// Features it needs; they are added when not asked for.
    pub requires: &'static [&'static str],
    /// Features it cannot be combined with.
    pub conflicts: &'static [&'static str],
}

/// The features `fsp create` can add (one change per group; the rest follow).
pub const RECIPES: &[Recipe] = &[
    Recipe {
        id: "devtools",
        description: "devtools_options.yaml, so Flutter DevTools shows the fespalier tab (routes, guards, data, actions) without asking.",
        companions: &[],
        third_party: &[],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[
            ("create/devtools_options.yaml", "devtools_options.yaml"),
            ("create/devtools_test.dart", "test/devtools_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup::NONE,
    },
    Recipe {
        id: "adaptive",
        description: "Tabs as a bar, a rail or a drawer by window width (fespalier_adaptive); the same as --template tabs.",
        companions: &["fespalier_adaptive"],
        third_party: &[],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[
            ("create/tabs_layout.dart", "lib/app/(tabs)/layout.dart"),
            (
                "create/tabs_home_page.dart",
                "lib/app/(tabs)/(home)/page.dart",
            ),
            (
                "create/tabs_home_nav.dart",
                "lib/app/(tabs)/(home)/nav.dart",
            ),
            (
                "create/tabs_about_page.dart",
                "lib/app/(tabs)/about/page.dart",
            ),
            (
                "create/tabs_about_nav.dart",
                "lib/app/(tabs)/about/nav.dart",
            ),
            ("create/adaptive_test.dart", "test/adaptive_test.dart"),
        ],
        replaces: &[
            "lib/app/layout.dart",
            "lib/app/page.dart",
            "lib/app/about/page.dart",
        ],
        requires: &[],
        conflicts: &[],
        startup: Startup::NONE,
    },
    Recipe {
        id: "forms",
        description: "A form on an action (fespalier_forms): /contact, with typed fields and errors under them.",
        companions: &["fespalier_forms"],
        third_party: &[],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[
            ("create/contact_action.dart", "lib/app/contact/action.dart"),
            ("create/contact_page.dart", "lib/app/contact/page.dart"),
            ("create/forms_test.dart", "test/forms_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup::NONE,
    },
    Recipe {
        id: "storage",
        description: "A dataCache on disk (fespalier_storage): the last value is on the first frame at the next start.",
        companions: &["fespalier_storage"],
        third_party: &[],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[("create/storage_test.dart", "test/storage_test.dart")],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier/fespalier.dart",
                "package:fespalier_storage/fespalier_storage.dart",
            ],
            steps: &[Step {
                kind: StepKind::Override,
                phase: Phase::Rest,
                comment: "fespalier_storage: a dataCache is saved here (null: nothing is saved).",
                code: "dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),",
                awaits: true,
            }],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "connectivity",
        description: "reconnectSignal and hasNetwork (fespalier_connectivity): refetchOnReconnect works.",
        companions: &["fespalier_connectivity"],
        third_party: &[],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[(
            "create/connectivity_test.dart",
            "test/connectivity_test.dart",
        )],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier/fespalier.dart",
                "package:fespalier_connectivity/fespalier_connectivity.dart",
            ],
            steps: &[Step {
                kind: StepKind::Override,
                phase: Phase::Rest,
                comment: "fespalier_connectivity: refetchOnReconnect follows the network.",
                code: "reconnectSignal.overrideWith(ConnectivitySignal.new),",
                awaits: false,
            }],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "flags",
        description: "A feature flag behind a route guard (fespalier_flags): /labs is there while the labs flag is on.",
        companions: &["fespalier_flags"],
        third_party: &[],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[
            ("create/flags.dart", "lib/flags.dart"),
            ("create/labs_guard.dart", "lib/app/labs/guard.dart"),
            ("create/labs_page.dart", "lib/app/labs/page.dart"),
            ("create/flags_test.dart", "test/flags_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &["package:fespalier_flags/fespalier_flags.dart"],
            steps: &[Step {
                kind: StepKind::Override,
                phase: Phase::Rest,
                comment: "fespalier_flags: where flag values come from (--dart-define=LABS=true turns /labs on).",
                code: "flagSource.overrideWithValue(\n  const ConstFlags({'labs': bool.fromEnvironment('LABS')}),\n),",
                awaits: false,
            }],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "otel",
        description: "OpenTelemetry spans for navigations, guards, data and actions (fespalier_otel, on otel_zone); a release build exports nothing without OTEL_EXPORTER_OTLP_ENDPOINT.",
        companions: &["fespalier_otel"],
        third_party: &[ThirdParty {
            name: "otel_zone",
            source: Source::Git {
                url: "https://github.com/vaam-apps/flutter-otel-zone",
                commit: "a9648533f6f8f0a6bfb341b368e8be0747b7dc21",
            },
        }],
        dev_third_party: &[ThirdParty {
            name: "dartastic_opentelemetry",
            source: Source::Range("^1.1.0-beta.15"),
        }],
        // otel_zone needs Dart 3.9 (it depends on talker_riverpod_logger), which is Flutter 3.35.
        flutter_floor: "3.35",
        config: &["telemetry: true"],
        files: &[("create/otel_test.dart", "test/otel_test.dart")],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier/fespalier.dart",
                "package:fespalier_otel/fespalier_otel.dart",
                "package:flutter/foundation.dart show kIsWeb",
                "package:flutter/widgets.dart show WidgetsFlutterBinding",
                "package:otel_zone/otel_zone.dart",
            ],
            decls: &[
                "/// The name spans carry as `service.name`.\nconst String serviceName = '{name}';",
                "/// The OpenTelemetry SDK. A release build without an endpoint exports nothing: pass\n/// --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://... to send spans to a collector.\nfinal OtelZone observability = OtelZone(\n  OtelZoneConfig(serviceName: serviceName, endpoint: FespalierOtel.endpoint()),\n);",
                "/// Brings the SDK up (it never throws), then runs [body]. This is the start of the process, not\n/// of the app: a test that builds the app does not start the SDK, and the sink that startup()\n/// installs reports once it is up.\nFuture<void> startObservability(Future<void> Function() body) async {\n  WidgetsFlutterBinding.ensureInitialized();\n  await observability.start(\n    serviceVersion: '0.1.0',\n    resourceAttributes: {...FespalierOtel.resourceAttributes},\n  );\n  await body();\n}",
            ],
            body_wrapper: Some("startObservability"),
            // Sentry's zone wins when both are chosen: it is the outermost, and a second zone
            // would send uncaught async errors to Talker only (docs/observability.md).
            weak_zone: Some(
                "/// otel_zone's guarded zone. It never runs its body on the web (docs/observability.md),\n/// so the web runs the body as it is.\nFuture<void> zone(Future<void> Function() body) {\n  Future<void> run() => startObservability(body);\n  return kIsWeb ? run() : observability.runGuarded(run);\n}",
            ),
            sinks: &["FespalierOtel(isReady: () => observability.isReady)"],
            provider_observers: &["?observability.riverpodObserver(),"],
            router_observers: &["?observability.routeObserver(),"],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "sentry",
        description: "Errors and crashes in Sentry, tagged with the route, the file and the action (fespalier_sentry); sends nothing while SENTRY_DSN is empty.",
        companions: &["fespalier_sentry"],
        third_party: &[ThirdParty {
            name: "sentry_flutter",
            source: Source::Range(">=9.26.0 <10.0.0"),
        }],
        dev_third_party: &[],
        flutter_floor: "3.32",
        config: &["telemetry: true"],
        files: &[("create/sentry_test.dart", "test/sentry_test.dart")],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier/fespalier.dart",
                "package:fespalier_sentry/fespalier_sentry.dart",
                "package:flutter/foundation.dart show kIsWeb",
                "package:sentry_flutter/sentry_flutter.dart",
            ],
            zone: Some(
                "/// Sentry starts first and runs the binding, startup() and runApp in its appRunner, so a\n/// crash in any of them is Sentry's. An empty SENTRY_DSN turns Sentry off:\n/// --dart-define=SENTRY_DSN=https://... sends events to your project.\nFuture<void> zone(Future<void> Function() body) => SentryFlutter.init(\n  (options) => FespalierSentry.configure(\n    options,\n    dsn: const String.fromEnvironment('SENTRY_DSN'),\n  ),\n  appRunner: {body},\n);",
            ),
            sinks: &["FespalierSentry()"],
            router_observers: &["if (kIsWeb) FespalierSentry.navigatorObserver(),"],
            ..Startup::NONE
        },
    },
];

/// Every `packages/fespalier_*` (the Flutter packages of this repository, except the DevTools
/// extension's source) that is not a create feature, and why. A package that is neither a
/// recipe's companion nor here fails `create_tests::every_package_is_a_feature_or_has_a_reason`.
/// A feature that lands moves its package out of this list.
#[allow(
    dead_code,
    reason = "only the tests read it: it is the record of why a package is not a feature"
)]
pub const NOT_A_CREATE_FEATURE: &[(&str, &str)] = &[
    (
        "fespalier_analytics",
        "needs a vendor SDK and its console setup (docs/adapters.md); the app brings its backend",
    ),
    (
        "fespalier_auth",
        "not yet: it becomes the `auth` feature in a later release",
    ),
    (
        "fespalier_biometrics",
        "needs `local_auth` and device setup, a compiled recipe in the skills, not a dependency",
    ),
    (
        "fespalier_cratestack",
        "needs a generated CrateStack client that is specific to the app, so there is nothing to scaffold",
    ),
    (
        "fespalier_dio",
        "waits for the planned fespalier_http package, which the `http` feature will use",
    ),
    (
        "fespalier_download",
        "the `download` feature lands with the engine and the adapter",
    ),
    (
        "fespalier_frb",
        "needs a Rust core and flutter_rust_bridge, which are the app's own",
    ),
    (
        "fespalier_http",
        "the `http` feature lands once fespalier_http has DioHttpClient and its docs",
    ),
    (
        "fespalier_image",
        "not yet: it becomes the `image` feature in a later release",
    ),
    (
        "fespalier_maps",
        "needs a tile source, a style and platform setup, which are the app's own",
    ),
    (
        "fespalier_push",
        "needs a vendor SDK and device setup (docs/adapters.md); the app brings its source",
    ),
    (
        "fespalier_riverpod",
        "nothing to scaffold: it adds providers per page instance, used where a page needs them",
    ),
    (
        "fespalier_sign_keypair",
        "needs Flutter 3.44 and a git dependency of another repository",
    ),
    (
        "fespalier_tolgee",
        "not yet: it becomes the `i18n` feature in a later release",
    ),
];

/// The `fespalier_*` packages each companion depends on in its `dependencies:` (not
/// `dev_dependencies:`), besides `fespalier` itself. `--local-packages` overrides all of them: an
/// app resolves a companion's own git dependency on the others at the checkout only when each
/// is overridden. `create_tests` compares this table with the pubspecs.
pub const COMPANION_DEPS: &[(&str, &[&str])] = &[
    ("fespalier_auth", &["fespalier_http"]),
    ("fespalier_cratestack", &["fespalier_dio"]),
    ("fespalier_dio", &["fespalier_http"]),
    ("fespalier_sign_keypair", &["fespalier_auth"]),
];

/// The companions `names` need at the checkout: themselves and everything they depend on, sorted.
#[must_use]
pub fn companion_closure(names: &[&str]) -> Vec<String> {
    let mut all: Vec<String> = vec![];
    let mut stack: Vec<&str> = names.to_vec();
    while let Some(name) = stack.pop() {
        if all.iter().any(|n| n == name) {
            continue;
        }
        all.push(name.to_string());
        if let Some((_, deps)) = COMPANION_DEPS.iter().find(|(n, _)| *n == name) {
            stack.extend(deps.iter().copied());
        }
    }
    all.sort();
    all
}
