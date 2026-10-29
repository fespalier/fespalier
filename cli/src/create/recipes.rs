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
    /// `name:` with `sdk: <sdk>` under it: `flutter_localizations` is part of the Flutter SDK.
    Sdk(&'static str),
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

/// A decorator the telemetry features wrap around the app's one transport, innermost first (the
/// order of the variants is the order on the wire, so `Ord` sorts them).
///
/// The wire order of a generated app, outermost to innermost, is the one `docs/http.md` has: an
/// app's own retrier, `SessionTransport` (`authTransport`, which `fespalier_auth` makes over the
/// transport `authSetup` is given), `OtelTransport`, `SentryTransport`, `WriteGuardTransport`, the
/// client. Telemetry sits under the session so each wire send is one span, an auth replay too; the
/// guard sits under telemetry so a retrier above everything still reads its marks (every
/// decorator returns the very response, and rethrows the very error, the guard marked).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum TransportLayer {
    /// `SentryTransport(inner)`: a breadcrumb per request (errors first, no span by default).
    Sentry,
    /// `OtelTransport(inner, isReady: ...)`: one `CLIENT` span per request, once the SDK is up.
    Otel,
}

/// The statement that builds the app's one transport (since 0.21.0): every feature that sends
/// (`http`, `auth`, `image`, `download`) has it, and the composer writes it once. Every package
/// that sends is given this `transport`, which is the client inside a `WriteGuardTransport`
/// (a retrier above reads its marks to leave writes alone) and, when the app has `otel` or
/// `sentry`, inside their decorators ([`TransportLayer`]): the composer rewrites `code` and
/// `comment` then. The session wraps it in `authTransport`, outside all of them.
pub const TRANSPORT: Step = Step {
    kind: StepKind::Statement,
    phase: Phase::Rest,
    comment: "The app's one transport, given to every package that sends: the client inside a write guard.",
    code: "final transport = WriteGuardTransport(HttpClientTransport(http.Client()));",
    awaits: false,
};

/// The expression [`TRANSPORT`] builds before any telemetry layer is put around it.
pub const TRANSPORT_BASE: &str = "WriteGuardTransport(HttpClientTransport(http.Client()))";

/// `package:http`, which the shared transport is built over (`^1.5.0` is the first release with
/// abortable requests, which `fespalier_http` needs).
const HTTP: ThirdParty = ThirdParty {
    name: "http",
    source: Source::Range("^1.5.0"),
};

/// What a feature adds to the files that every feature shares: `lib/app/startup.dart`,
/// `lib/app/app.dart`, `lib/main.dart` and the pubspec's `flutter: assets:`, `test:` and Android
/// `minSdk`. `compose.rs` merges the fragments of all the chosen
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
    /// Dart expressions of telemetry sinks, each starting with its class name (`FespalierSentry()`).
    /// The composer installs them all in one slot, first thing in `startup()`:
    /// `FespalierTelemetry.install(sink)`, and `combine([...])` for several. When the generated
    /// `main()` has installed a sink already (`otel: true`, since 0.19.0) it adds each one instead,
    /// once: a top-level `final _sentry = FespalierSentry();` and
    /// `if (!FespalierTelemetry.contains(_sentry)) FespalierTelemetry.add(_sentry);`, because
    /// Retry runs `startup()` again and `add` appends a sink every time.
    pub sinks: &'static [&'static str],
    /// Elements of the `providerObservers` list (each with its trailing comma).
    pub provider_observers: &'static [&'static str],
    /// Elements of the `routerObservers` list (each with its trailing comma).
    pub router_observers: &'static [&'static str],
    /// Library URIs `app.dart` imports besides its own.
    pub app_imports: &'static [&'static str],
    /// Library URIs `main.dart` imports besides its own.
    pub main_imports: &'static [&'static str],
    /// A template for the whole of `lib/app/app.dart`, in place of the starter's, for a feature
    /// that changes what `MaterialApp.router` is given (`{{ package }}` is the app's name). At most
    /// one feature has it, and the composer adds the other features' [`app_imports`](Self::app_imports).
    pub app_template: Option<&'static str>,
    /// Entries of `flutter: assets:` in the pubspec (`assets/i18n/`).
    pub assets: &'static [&'static str],
    /// Routes `fsp test` leaves out of the route smoke tests (`test: skip:` in the pubspec), each
    /// with why: a page that needs more than a bare `pumpRouter` gives it, and has a test of its
    /// own that sets that up.
    pub smoke_skip: &'static [(&'static str, &'static str)],
    /// The lowest Android `minSdk` the feature's plugins run on. Flutter's own default is 21
    /// before Flutter 3.35 (24 since), so `fsp create` raises it in `android/app/build.gradle.kts`
    /// when the app is made with Android and the default is lower.
    pub android_min_sdk: Option<u32>,
    /// The decorator this feature wraps around the app's one transport ([`TRANSPORT`]), with the
    /// imports it needs written only when the app has a transport (a telemetry feature without a
    /// feature that sends has nothing to wrap, and an unused import would fail `flutter analyze`).
    pub transport_layer: Option<TransportLayer>,
    /// Elements of the `List<Override> overrides(String pattern)` of `test/routes/setup.dart`
    /// (each with its trailing comma, a `//` comment above it allowed): what `fsp test`'s route
    /// smoke tests boot with. Any feature that has one makes the composer write that file, and
    /// then a guarded route is no longer skipped on its own: see
    /// [`smoke_guarded`](Self::smoke_guarded).
    pub smoke_overrides: &'static [&'static str],
    /// Library URIs `test/routes/setup.dart` imports for [`smoke_overrides`](Self::smoke_overrides)
    /// (`{name}` is the app's package name).
    pub smoke_imports: &'static [&'static str],
    /// Guarded routes of this feature, each with why `fsp test` leaves it out, listed in
    /// `test: skip:` **only when the app has a setup file**: without one `fsp test` skips a
    /// guarded route by itself, and with one (its `overrides`) it would run the route, which only
    /// a test of the feature's own can get past the guard.
    pub smoke_guarded: &'static [(&'static str, &'static str)],
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
        app_template: None,
        assets: &[],
        smoke_skip: &[],
        android_min_sdk: None,
        transport_layer: None,
        smoke_overrides: &[],
        smoke_imports: &[],
        smoke_guarded: &[],
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
        flutter_floor: "3.35",
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
        flutter_floor: "3.35",
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
        flutter_floor: "3.35",
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
        flutter_floor: "3.35",
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
        flutter_floor: "3.35",
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
        flutter_floor: "3.35",
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
            smoke_guarded: &[(
                "/labs",
                "guarded by the labs flag, which is off: test/flags_test.dart turns it on",
            )],
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
                commit: "64c4661ac6cd09718141864d528892916677cc38",
            },
        }],
        dev_third_party: &[ThirdParty {
            name: "dartastic_opentelemetry",
            source: Source::Range("^1.1.0-beta.17"),
        }],
        // otel_zone needs Dart 3.9 (it depends on talker_riverpod_logger), which is Flutter 3.35,
        // the base floor since 0.16.0.
        flutter_floor: "3.35",
        config: &["telemetry: true", "otel: true"],
        files: &[("create/otel_test.dart", "test/otel_test.dart")],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        // `otel: true` writes the wiring into lib/app.main.g.dart (since 0.19.0): no startup.dart of
        // its own. An app that sends has `OtelTransport` wrapped around its one transport there.
        startup: Startup {
            transport_layer: Some(TransportLayer::Otel),
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
        flutter_floor: "3.35",
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
            transport_layer: Some(TransportLayer::Sentry),
            ..Startup::NONE
        },
    },
    Recipe {
        id: "auth",
        description: "Signed-in routes (fespalier_auth): a guard on /account, a sign-in form, restoreAuth at startup and a backend that says to connect your identity provider.",
        // The sign-in page is a form on an action (docs/auth.md), which needs the forms package.
        // The stub backend keeps bearer tokens (fespalier_oidc's TokenCredential and
        // BearerAuthenticator, and the PasswordSignIn the form sends), and the config takes the
        // app's one transport (fespalier_http builds it in startup.dart, fespalier_transport names
        // its type).
        companions: &[
            "fespalier_auth",
            "fespalier_forms",
            "fespalier_http",
            "fespalier_oidc",
            "fespalier_transport",
        ],
        third_party: &[HTTP],
        // The tests that start the whole app give the keychain an in-memory store.
        dev_third_party: &[ThirdParty {
            name: "flutter_secure_storage",
            source: Source::Range(">=10.0.0 <12.0.0"),
        }],
        flutter_floor: "3.35",
        config: &[],
        files: &[
            ("create/auth_setup.dart", "lib/auth_setup.dart"),
            ("create/auth_guard.dart", "lib/app/(signed-in)/guard.dart"),
            (
                "create/account_page.dart",
                "lib/app/(signed-in)/account/page.dart",
            ),
            ("create/sign_in_action.dart", "lib/app/sign-in/action.dart"),
            ("create/sign_in_guard.dart", "lib/app/sign-in/guard.dart"),
            ("create/sign_in_page.dart", "lib/app/sign-in/page.dart"),
            ("create/auth_test.dart", "test/auth_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier_auth/fespalier_auth.dart",
                "package:fespalier_http/fespalier_http.dart",
                "package:fespalier_transport/fespalier_transport.dart",
                "package:http/http.dart as http",
                "package:{name}/auth_setup.dart",
            ],
            smoke_guarded: &[
                (
                    "/account",
                    "guarded by the session: test/auth_test.dart signs in",
                ),
                (
                    "/sign-in",
                    "guarded, and its form needs the auth config: test/auth_test.dart opens it with one",
                ),
            ],
            steps: &[
                TRANSPORT,
                Step {
                    kind: StepKind::Override,
                    phase: Phase::Session,
                    comment: "fespalier_auth: reads the stored session, with no network, so the first guard is synchronous.",
                    code: "...await restoreAuth(authSetup(transport)),",
                    awaits: true,
                },
            ],
            // flutter_secure_storage, the token store: Android 7.0 (docs/auth.md, "Installing").
            android_min_sdk: Some(24),
            ..Startup::NONE
        },
    },
    Recipe {
        id: "i18n",
        description: "Translated texts (fespalier_tolgee): bundled English and French catalogs, the language from ?lang=, ICU plurals; no key, no network.",
        companions: &["fespalier_tolgee"],
        // The Material strings of each language (docs/i18n-tolgee.md, "The scope").
        third_party: &[ThirdParty {
            name: "flutter_localizations",
            source: Source::Sdk("flutter"),
        }],
        dev_third_party: &[],
        flutter_floor: "3.35",
        config: &[],
        files: &[
            ("create/i18n_en.arb", "assets/i18n/en.arb"),
            ("create/i18n_fr.arb", "assets/i18n/fr.arb"),
            (
                "create/translations_page.dart",
                "lib/app/translations/page.dart",
            ),
            ("create/i18n_test.dart", "test/i18n_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &["package:fespalier_tolgee/fespalier_tolgee.dart"],
            steps: &[Step {
                kind: StepKind::Override,
                phase: Phase::Rest,
                comment: "fespalier_tolgee: the catalogs bundled in assets/i18n/ (a local read, never the network).",
                code: "translationsConfig.overrideWithValue(\n  Translations(\n    bundled: await BundledTranslations.load(locales: const ['en', 'fr']),\n    baseLocale: 'en',\n  ),\n),",
                awaits: true,
            }],
            app_template: Some("create/i18n_app.dart"),
            assets: &["assets/i18n/"],
            // The page reads the translator from the scope, which only the app's own App has.
            smoke_skip: &[(
                "/translations",
                "needs the translation scope: test/i18n_test.dart opens it through the app's own App",
            )],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "image",
        description: "Responsive images (fespalier_image): a ResponsiveImage that asks the CDN for the width its box needs, through a URL template; no signing key.",
        // The CDN fetches through the app's one transport (fespalier_http builds it in startup.dart,
        // fespalier_transport names its type).
        companions: &["fespalier_http", "fespalier_image", "fespalier_transport"],
        third_party: &[HTTP],
        dev_third_party: &[],
        flutter_floor: "3.35",
        config: &[],
        files: &[
            ("create/images.dart", "lib/images.dart"),
            ("create/photo_page.dart", "lib/app/photo/page.dart"),
            ("create/image_test.dart", "test/image_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier_http/fespalier_http.dart",
                "package:fespalier_image/fespalier_image.dart",
                "package:fespalier_transport/fespalier_transport.dart",
                "package:http/http.dart as http",
                "package:{name}/images.dart",
            ],
            steps: &[
                TRANSPORT,
                Step {
                    kind: StepKind::Override,
                    phase: Phase::Rest,
                    comment: "fespalier_image: which CDN the images come from (lib/images.dart), fetched through the transport.",
                    code: "imageCdnProvider.overrideWithValue(appImages(transport)),",
                    awaits: false,
                },
            ],
            // The page needs the CDN, which only startup() (or a test's overrides) gives: the route
            // smoke tests boot with test/routes/setup.dart's, a CDN over a transport that sends
            // nothing, whose loads wait (the page is on screen, which is all they look for).
            smoke_imports: &[
                "package:fespalier_image/fespalier_image.dart",
                "package:fespalier_image/testing.dart",
                "package:fespalier_transport/testing.dart",
                "package:{name}/images.dart",
            ],
            smoke_overrides: &[
                "// The photo's CDN, over a transport that sends nothing: FakeImages holds every load\n// (the page is on screen, which is all a smoke test looks for).\nimageCdnProvider.overrideWithValue(\n  FakeImages().cdn(\n    appImages(\n      FakeTransport(\n        (request, body) => throw StateError('a smoke test sends nothing'),\n      ),\n    ),\n  ),\n),",
            ],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "http",
        description: "The app's one transport and an http.Client over it, and a page that loads JSON through it (fespalier_http): the request is aborted when the page goes away; --dart-define=API_URL sets the server.",
        // The app imports fespalier_transport itself (HttpTransport, WriteGuardTransport in the shared
        // transport, and the FakeTransport a test serves from) and package:http (the client type).
        companions: &["fespalier_http", "fespalier_transport"],
        third_party: &[HTTP],
        dev_third_party: &[],
        flutter_floor: "3.35",
        config: &[],
        files: &[
            ("create/api.dart", "lib/api.dart"),
            ("create/headlines_data.dart", "lib/app/headlines/data.dart"),
            ("create/headlines_page.dart", "lib/app/headlines/page.dart"),
            ("create/http_test.dart", "test/http_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier_http/fespalier_http.dart",
                "package:fespalier_transport/fespalier_transport.dart",
                "package:http/http.dart as http",
                "package:{name}/api.dart",
            ],
            steps: &[
                TRANSPORT,
                Step {
                    kind: StepKind::Override,
                    phase: Phase::Rest,
                    comment: "fespalier_http: the transport lib/api.dart's httpClient sends through (the app's one, whose write guard keeps a retrier from repeating a write).",
                    code: "httpTransport.overrideWithValue(transport),",
                    awaits: false,
                },
            ],
            // A page that loads from a server has no network in `fsp test`'s smoke test.
            smoke_skip: &[(
                "/headlines",
                "needs a transport: test/http_test.dart serves it from a FakeTransport",
            )],
            ..Startup::NONE
        },
    },
    Recipe {
        id: "download",
        description: "Downloads that outlive a screen (fespalier_download, the foreground backend): a /downloads page with a start button and the download's status; --dart-define=DOWNLOAD_URL sets the file.",
        companions: &[
            "fespalier_download",
            "fespalier_http",
            "fespalier_transport",
        ],
        // The foreground backend sends through the app's one transport (fespalier_http builds it
        // in startup.dart, fespalier_transport names its write guard). The package names no plugin for the base
        // folders (application support, cache, documents), so the app adds one.
        //
        // `file` and `platform` are not imported. fespalier_download pulls no path_provider, so
        // nothing else in the app steers away from what path_provider allows at the lowest
        // versions: platform 3.0.0 (it reads `Platform.packageRoot`, gone from Dart 3) and file
        // before 6.1.3 (`File.create` has no `exclusive:` on Dart 3.9, and a Linux or Windows
        // build compiles path_provider's plugins). The packages that bring path_provider carry
        // the same two constraints, and cli/tests/versions.rs checks that none forgets them.
        third_party: &[
            ThirdParty {
                name: "file",
                source: Source::Range(">=6.1.3 <8.0.0"),
            },
            HTTP,
            ThirdParty {
                name: "path_provider",
                source: Source::Range("^2.1.0"),
            },
            ThirdParty {
                name: "platform",
                source: Source::Range("^3.1.4"),
            },
        ],
        dev_third_party: &[],
        flutter_floor: "3.35",
        config: &[],
        files: &[
            ("create/downloads.dart", "lib/downloads.dart"),
            ("create/downloads_page.dart", "lib/app/downloads/page.dart"),
            ("create/download_test.dart", "test/download_test.dart"),
        ],
        replaces: &[],
        requires: &[],
        conflicts: &[],
        startup: Startup {
            imports: &[
                "package:fespalier_download/fespalier_download.dart",
                "package:fespalier_http/fespalier_http.dart",
                "package:fespalier_transport/fespalier_transport.dart",
                "package:http/http.dart as http",
                "package:path_provider/path_provider.dart",
            ],
            decls: &[
                "/// Where each base folder of a download is on this device. fespalier_download names no\n/// plugin for it, so the app does (docs/downloads.md, \"The foreground backend\").\nFuture<String> appBases(DownloadBase base) async => switch (base) {\n  DownloadBase.support => (await getApplicationSupportDirectory()).path,\n  DownloadBase.cache => (await getApplicationCacheDirectory()).path,\n  DownloadBase.documents => (await getApplicationDocumentsDirectory()).path,\n};",
            ],
            steps: &[
                TRANSPORT,
                Step {
                    kind: StepKind::Override,
                    phase: Phase::Rest,
                    comment: "fespalier_download: the engine, over a foreground transfer through the transport (it stops with the app).",
                    code: "downloadsEngine.overrideWithValue(\n  Downloads(\n    backend: HttpDownloadBackend(transport: transport, bases: appBases),\n    store: FileDownloadStore(bases: appBases),\n    files: TransferDownloadFiles(bases: appBases),\n  ),\n),",
                    awaits: false,
                },
            ],
            // The page reads the engine, which only startup() (or a test's overrides) provides.
            smoke_skip: &[(
                "/downloads",
                "needs the downloads engine: test/download_test.dart overrides it with fakes",
            )],
            ..Startup::NONE
        },
    },
];

/// Every `packages/fespalier_*` (the Flutter packages of this repository, except the DevTools
/// extension's source) that is not a create feature, and why. A package that is neither a
/// recipe's companion nor here fails `create_tests::every_package_is_a_feature_or_has_a_reason`.
/// A feature that lands moves its package out of this list. With the companions of the recipes it
/// is every package of this repository, which is how `pins.rs` tells them from others.
pub const NOT_A_CREATE_FEATURE: &[(&str, &str)] = &[
    (
        "fespalier_analytics",
        "needs a vendor SDK and its console setup (docs/adapters.md); the app brings its backend",
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
        "an app that wants Dio adds it itself; the `http` feature scaffolds package:http (fespalier_http), and `TransportAdapter` makes a Dio send through a transport",
    ),
    (
        "fespalier_download_background",
        "needs Flutter 3.47 and platform setup (a manifest, an AppDelegate), which are the app's own; the `download` feature is the foreground backend",
    ),
    (
        "fespalier_frb",
        "needs a Rust core and flutter_rust_bridge, which are the app's own",
    ),
    (
        "fespalier_keypair",
        "needs Flutter 3.44 and a git dependency of another repository; keys and signers a protocol builds on, nothing to scaffold",
    ),
    (
        "fespalier_keypair_dpop",
        "needs Flutter 3.44 and a git dependency of another repository, and an identity provider that is the app's own",
    ),
    (
        "fespalier_launch",
        "needs quick_actions or home_widget and native setup, compiled recipes in the skills, not a dependency",
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
        "fespalier_stream",
        "needs a server that streams events, which is the app's own",
    ),
];

/// The `fespalier_*` packages each companion depends on in its `dependencies:` (not
/// `dev_dependencies:`), besides `fespalier` itself. `--local-packages` overrides all of them: an
/// app resolves a companion's own git dependency on the others at the checkout only when each
/// is overridden. `create_tests` compares this table with the pubspecs.
pub const COMPANION_DEPS: &[(&str, &[&str])] = &[
    ("fespalier_auth", &["fespalier_transport"]),
    ("fespalier_cratestack", &["fespalier_transport"]),
    ("fespalier_dio", &["fespalier_transport"]),
    ("fespalier_download", &["fespalier_transport"]),
    (
        "fespalier_download_background",
        &["fespalier_download", "fespalier_transport"],
    ),
    ("fespalier_frb", &["fespalier_stream"]),
    ("fespalier_http", &["fespalier_transport"]),
    ("fespalier_image", &["fespalier_transport"]),
    (
        "fespalier_keypair_dpop",
        &["fespalier_keypair", "fespalier_oidc"],
    ),
    (
        "fespalier_maps",
        &["fespalier_download", "fespalier_transport"],
    ),
    ("fespalier_oidc", &["fespalier_auth", "fespalier_transport"]),
    ("fespalier_otel", &["fespalier_transport"]),
    ("fespalier_sentry", &["fespalier_transport"]),
    (
        "fespalier_sign_keypair",
        &["fespalier_auth", "fespalier_keypair", "fespalier_transport"],
    ),
    ("fespalier_stream", &["fespalier_transport"]),
    ("fespalier_tolgee", &["fespalier_transport"]),
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
