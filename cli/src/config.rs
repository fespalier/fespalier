//! The optional `fespalier:` section of the project's pubspec.yaml:
//!
//! ```yaml
//! fespalier:
//!   app_dir: lib/app        # default
//!   output: lib/app.g.dart  # default
//!   format: false           # default; true runs `dart format` on the output
//!   output_manifest: lib/app.routes.g.dart   # default: none, the manifest is in `output`
//!   meta: optional          # default; `required` makes a route without meta.dart an error
//!   meta_unique: [code]     # default: none; no two routes may pass the same literal `code:` to `meta`
//!   case_sensitive: true    # default; false matches `/Products` too (a route.dart sets it per folder)
//!   remount: never          # default; on_segments or on_location give a page a fresh state when its URL changes (a route.dart sets it per folder)
//!   deferred: false         # default; true loads each page's code on demand on the web (a route.dart sets it per folder)
//!   data_retry: inherit     # default; `none` gives generated data() providers `retry: null`
//!   keep_previous: true     # default; false shows loading.dart whenever data.dart loads (not while an optimistic() write settles)
//!   push_updates_url: false # default; true puts a `push`ed route's URL in the browser's address bar
//!   file_style: snake       # default; `kebab` makes `fsp init` and `fsp new` write not-found.dart
//!   semantics_ids: false    # default; true gives each page `Semantics(identifier: 'route:/...')`, for Maestro
//!   scroll_restoration: false # default; true keeps a page's scroll positions for the browser's back and forward
//!   main: auto              # default; `generated` always writes lib/app.main.g.dart, `manual` never (see `entry.rs`)
//!   telemetry: false        # default; true reports navigations, guards, data, actions and deferred loads to FespalierTelemetry
//!   links:                  # default: none; what `fsp links` writes (see `links.rs`)
//!     domains: [shop.example.com]
//!     scheme: myshop
//!     scheme_host: true     # since 0.11.0; `false`: myshop:///path, no host
//!     paths: [/, /orders/*] # since 0.11.0; default: every linkable route
//!     android_package: com.example.shop
//!     android_sha256: ["AB:CD:..."]
//!     ios_app_id: TEAMID.com.example.shop   # or `flavors:` (since 0.11.0), one app per flavour
//!     out: links            # default
//!   lints:                  # one level per lint (see `lint.rs`)
//!     unknown_path: warning # default; `error` fails `gen` and `check`, `off` skips the check
//!   maestro:                # default: none; what `fsp maestro` writes (see `maestro.rs`)
//!     url: http://localhost:8080   # or `app_id: com.example.shop`, one of the two
//!     link: http://localhost:8080/#
//!     out: .maestro/routes  # default
//!     guard_flow: .maestro/sign-in.yaml
//!     timeout: 20000        # default, in milliseconds
//!     samples:              # the value of each dynamic folder
//!       products/$id: 1
//!   size:                   # default: none; what `fsp size` checks (see `size.rs`)
//!     build: build/web      # default; the `flutter build web` output
//!     main: 3 MB            # main.dart.js
//!     route: 64 KB          # each deferred route's own and shared chunks together
//!     routes:               # per route, by pattern; wins over `route`
//!       /checkout: 8 KB
//!   test:                   # default: none, and `fsp test` works without it (see `smoke.rs`)
//!     out: test/routes      # default; `test`, `integration_test` or a folder below one
//!     setup: test/routes/setup.dart   # default: <out>/setup.dart, used when it exists
//!     timeout: 30000        # default, in milliseconds of the test's fake clock
//!     samples:              # default: the maestro ones
//!       products/$id: 1
//!     skip: [/admin]        # patterns as `fsp routes` prints them
//!   tasks:                  # default: none; what `fsp dev`, `fsp build` and `fsp run` run (see `tasks.rs`)
//!     dev:
//!       before: dart run build_runner build -d   # one command, or a list; the first that fails stops
//!       with:                                    # long-running, next to flutter, one pane each
//!         build_runner: dart run build_runner watch -d
//!       run: flutter run                         # default; fsp adds --machine, -d and the args after --
//!       env: { API_URL: "http://localhost:8080" }
//!       hot_reload: true                         # default
//!     codegen: dart run build_runner build -d    # `fsp run codegen`
//!   adapters: [fespalier_sentry]   # default: none; packages that plug into the generated main() (see `adapters.rs`)
//! ```
//!
//! Both paths are relative to the project root and live under `lib/`, because
//! the generated file imports the app files as ordinary package code.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_yaml_ng::Value;

use crate::samples;
pub use crate::samples::SampleValue;
use crate::scan::FileStyle;

pub const DEFAULT_APP_DIR: &str = "lib/app";
pub const DEFAULT_OUTPUT: &str = "lib/app.g.dart";
/// Where `fsp links` writes, relative to the project root.
pub const DEFAULT_LINKS_OUT: &str = "links";
/// Where `fsp maestro` writes, relative to the project root.
pub const DEFAULT_MAESTRO_OUT: &str = ".maestro/routes";
/// How long (in milliseconds) a flow waits for the page it opened.
pub const DEFAULT_MAESTRO_TIMEOUT: u32 = 20_000;
/// Where `fsp size` reads the web build, relative to the project root.
pub const DEFAULT_SIZE_BUILD: &str = "build/web";

/// Where `fsp test` writes, relative to the project root.
pub const DEFAULT_TEST_OUT: &str = "test/routes";
/// How long (in milliseconds of a test's fake clock) a smoke test waits for its page.
pub const DEFAULT_TEST_TIMEOUT: u32 = 30_000;

/// What the providers fespalier generates for `data()` functions do when they fail.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataRetry {
    /// Riverpod's own retry: the `ProviderScope(retry:)` or `ProviderContainer(retry:)`
    /// of the app decides.
    Inherit,
    /// `retry: (retryCount, error) => null`: a failure is final until `error.dart`'s retry.
    None,
}

/// When a page gets a fresh state because its URL changed: the runtime's `Remount`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Remount {
    /// Never: `/c/1` to `/c/2` keeps the page and its state (`go_router` keys a page by its path
    /// template).
    #[default]
    Never,
    /// When a segment's value changes; a different query keeps the state.
    OnSegments,
    /// On any change of the location, query included.
    OnLocation,
}

impl Remount {
    /// How the Dart enum spells it: `Remount.onSegments`.
    pub fn dart(self) -> &'static str {
        match self {
            Remount::Never => "never",
            Remount::OnSegments => "onSegments",
            Remount::OnLocation => "onLocation",
        }
    }

    /// How the config, `fsp routes --json` and the diagnostics spell it: `on_segments`.
    pub fn config_name(self) -> &'static str {
        match self {
            Remount::Never => "never",
            Remount::OnSegments => "on_segments",
            Remount::OnLocation => "on_location",
        }
    }

    /// The value a `route.dart` writes, `Remount.onSegments` (an import prefix is fine:
    /// `fsp.Remount.onSegments`), read back from the source text. `None` for anything else.
    pub fn from_source(value: &str) -> Option<Remount> {
        let ident = |p: &str| {
            p.chars()
                .next()
                .is_some_and(|c| c.is_alphabetic() || c == '_')
                && p.chars().all(|c| c.is_alphanumeric() || c == '_')
        };
        let parts: Vec<&str> = value.split('.').collect();
        let which = match parts.as_slice() {
            ["Remount", which] => which,
            [prefix, "Remount", which] if ident(prefix) => which,
            _ => return None,
        };
        [Remount::Never, Remount::OnSegments, Remount::OnLocation]
            .into_iter()
            .find(|r| r.dart() == *which)
    }
}

/// Whether `fsp gen` writes the generated `main()` (`lib/app.main.g.dart`, class `AppMain`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MainMode {
    /// Written when the app folder's root has an `app.dart`, `startup.dart` or `splash.dart`.
    #[default]
    Auto,
    /// Always written; without an `app.dart` the app is `MaterialApp.router(routerConfig: router)`.
    Generated,
    /// Never written, and the three root files are not read.
    Manual,
}

/// How a lint reports: not at all, as a warning, or as an error.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LintLevel {
    /// The check does not run.
    Off,
    /// Shown, and never fails a command.
    #[default]
    Warning,
    /// Shown, and `gen`, `check` and `watch` fail (the output is still written).
    Error,
}

/// The `lints:` section: one level per lint.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Lints {
    /// A string path passed to the router that matches no route (`lint.rs`).
    pub unknown_path: LintLevel,
}

/// The `lints:` section as the pubspec has it.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LintsConfig {
    unknown_path: Option<LintLevel>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// The pubspec's `name`: the package the app's files are imported by (`package:shop/…`).
    /// `None` without a pubspec, or a name in it.
    pub package: Option<String>,
    /// Normalized, `/`-separated, no trailing slash: `lib/app`.
    pub app_dir: String,
    /// Normalized, `/`-separated: `lib/app.g.dart`.
    pub output: String,
    /// Run `dart format` on the generated file (when `dart` is on PATH).
    pub format: bool,
    /// Where the route manifest (`AppManifest`) goes when it is its own library:
    /// normalized, `/`-separated, under `lib/`. `None` puts it in `output`.
    pub output_manifest: Option<String>,
    /// `meta: required`: every route needs a meta.dart.
    pub meta_required: bool,
    /// `meta_unique: [code, slug]`: each of these named arguments of `meta`'s constructor call
    /// must differ between routes, wherever it is a literal.
    pub meta_unique: Vec<String>,
    /// Whether routes match paths by case; `false` emits `caseSensitive: false` on each. The
    /// default for folders with no `route.dart` at or above them.
    pub case_sensitive: bool,
    /// When a page gets a fresh state because its URL changed; the default for folders with
    /// no `route.dart` at or above them that says `const remount`.
    pub remount: Remount,
    /// Whether pages load their code on demand (`import ... deferred as`); the default for
    /// folders with no `route.dart` at or above them that says `const deferred`.
    pub deferred: bool,
    pub data_retry: DataRetry,
    /// Keep rendering the old value or error while `data.dart` reloads.
    pub keep_previous: bool,
    /// `GoRouter.optionURLReflectsImperativeAPIs`, which `AppRoutes.router()` assigns: a
    /// `push`ed route shows its URL in the browser's address bar.
    pub push_updates_url: bool,
    /// `semantics_ids`: each page wears `Semantics(identifier: 'route:<pattern>')`, and
    /// `AppRoutes.mount()` turns the semantics tree on on the web, so a driver that reads the
    /// screen from the outside (Maestro) finds the page.
    pub semantics_ids: bool,
    /// `scroll_restoration`: each page is wrapped in `RouteScrollMemory`, which keeps a
    /// `PageStorage` bucket per history entry and hands it back only when the browser brings
    /// that entry back (since 0.8.1).
    pub scroll_restoration: bool,
    /// `telemetry`: the generated file passes each guard, data provider, action and deferred
    /// library a `const TelemetrySite`, and `AppRoutes.attach` follows the router's navigations.
    /// Off, the file is exactly what it was without the key.
    pub telemetry: bool,
    /// How `fsp init` and `fsp new` spell a multi-word file kind. Reading takes both.
    pub file_style: FileStyle,
    /// The `links:` section, as written. Only `fsp links` reads it, and it checks the values
    /// then ([`LinksConfig::validate`]), so a mistake in it never stops `fsp gen`.
    pub links: Option<LinksConfig>,
    /// The `lints:` section: how each lint over the app's own code reports.
    pub lints: Lints,
    /// The `maestro:` section, as written. Only `fsp maestro` reads it, and it checks the values
    /// then ([`MaestroConfig::validate`]), so a mistake in it never stops `fsp gen`.
    pub maestro: Option<MaestroConfig>,
    /// The `size:` section, as written. Only `fsp size` reads it, and it checks the values
    /// then ([`SizeConfig::validate`]), so a mistake in it never stops `fsp gen`.
    pub size: Option<SizeConfig>,
    /// The `test:` section, as written. Only `fsp test` reads it, and it checks the values
    /// then ([`TestConfig::validate`]), so a mistake in it never stops `fsp gen`.
    pub test: Option<TestConfig>,
    /// The `tasks:` section, as written. Only `fsp dev`, `fsp build` and `fsp run` read it, and
    /// they check it then ([`crate::tasks::Tasks::from_config`]), so a mistake in it never stops
    /// `fsp gen` (since 0.9.0).
    pub tasks: Option<Value>,
    /// `main:`: whether the generated `main()` is written (see [`MainMode`]).
    pub main: MainMode,
    /// `adapters:`: Dart packages, in order, that plug into the generated `main()` through
    /// `package:<name>/fespalier_adapter.dart` (see `adapters.rs`, since 0.9.0).
    pub adapters: Vec<String>,
    /// `fespalier_forms` is under `dependencies:` (since 0.11.0): `form()` needs it, and the
    /// generated file imports it. `true` without a pubspec, so a test needs none; the output
    /// still depends on the pubspec alone.
    pub forms_dependency: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            package: None,
            app_dir: DEFAULT_APP_DIR.into(),
            output: DEFAULT_OUTPUT.into(),
            format: false,
            output_manifest: None,
            meta_required: false,
            meta_unique: vec![],
            case_sensitive: true,
            remount: Remount::Never,
            deferred: false,
            data_retry: DataRetry::Inherit,
            keep_previous: true,
            push_updates_url: false,
            semantics_ids: false,
            scroll_restoration: false,
            telemetry: false,
            file_style: FileStyle::Snake,
            links: None,
            lints: Lints::default(),
            maestro: None,
            size: None,
            test: None,
            tasks: None,
            main: MainMode::Auto,
            adapters: vec![],
            forms_dependency: true,
        }
    }
}

/// What fespalier reads from pubspec.yaml.
#[derive(Debug, Default)]
pub struct Pubspec {
    pub name: Option<String>,
    /// `fespalier` is listed under `dependencies`.
    pub has_dependency: bool,
    pub config: Config,
}

#[derive(Deserialize)]
struct RawPubspec {
    name: Option<String>,
    dependencies: Option<Value>,
    fespalier: Option<RawConfig>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    app_dir: Option<String>,
    output: Option<String>,
    format: Option<bool>,
    output_manifest: Option<String>,
    meta: Option<String>,
    meta_unique: Option<Vec<String>>,
    case_sensitive: Option<bool>,
    remount: Option<Remount>,
    deferred: Option<bool>,
    data_retry: Option<DataRetry>,
    keep_previous: Option<bool>,
    push_updates_url: Option<bool>,
    file_style: Option<FileStyle>,
    links: Option<LinksConfig>,
    lints: Option<LintsConfig>,
    semantics_ids: Option<bool>,
    scroll_restoration: Option<bool>,
    telemetry: Option<bool>,
    maestro: Option<MaestroConfig>,
    size: Option<SizeConfig>,
    test: Option<TestConfig>,
    main: Option<MainMode>,
    tasks: Option<Value>,
    adapters: Option<Vec<String>>,
}

/// The `links:` section of the `fespalier:` config, as the pubspec has it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinksConfig {
    domains: Option<Vec<String>>,
    scheme: Option<String>,
    scheme_host: Option<bool>,
    paths: Option<Vec<String>>,
    android_package: Option<String>,
    android_sha256: Option<Vec<String>>,
    ios_app_id: Option<String>,
    flavors: Option<Flavors>,
    out: Option<String>,
}

/// One entry of `links: flavors:` (since 0.11.0): the apps of one build flavour.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FlavorConfig {
    android_package: Option<String>,
    android_sha256: Option<Vec<String>>,
    ios_app_id: Option<String>,
}

/// `links: flavors:` in the order the pubspec writes it (a map would sort it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flavors(Vec<(String, FlavorConfig)>);

impl<'de> Deserialize<'de> for Flavors {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = Flavors;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a map from a flavour name to its apps")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                mut map: A,
            ) -> Result<Flavors, A::Error> {
                let mut out = vec![];
                while let Some(entry) = map.next_entry::<String, FlavorConfig>()? {
                    out.push(entry);
                }
                Ok(Flavors(out))
            }
        }
        d.deserialize_map(V)
    }
}

/// One Android app of the `links:` section: a flavour's, or the flat keys' (no name).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AndroidApp {
    /// The flavour's name; `None` for the flat `android_package` key.
    pub flavor: Option<String>,
    /// The application id: `com.example.shop`.
    pub package: String,
    /// The signing certificates' SHA-256 fingerprints, upper-case, each once.
    pub sha256: Vec<String>,
}

/// One iOS app of the `links:` section: a flavour's, or the flat key's (no name).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IosApp {
    /// The flavour's name; `None` for the flat `ios_app_id` key.
    pub flavor: Option<String>,
    /// `TEAMID.com.example.shop`.
    pub app_id: String,
}

/// One entry of `links: paths:`: what a platform opens, instead of every linkable route.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkPath {
    /// `/about`: this path alone. The segments, none for `/`.
    Exact(Vec<String>),
    /// `/orders/*`: everything below `/orders/`. The segments before the `*`, none for `/*`.
    Prefix(Vec<String>),
}

/// The `links:` section, checked: what `fsp links` writes files for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Links {
    /// Lower-case host names, each once; the first is the one the sitemap is on.
    pub domains: Vec<String>,
    /// A custom URL scheme, besides `https`.
    pub scheme: Option<String>,
    /// Whether the scheme's filter and the default Maestro link have the domain as the host
    /// (`myshop://shop.example.com/orders/2`, the default) or none (`myshop:///orders/2`).
    pub scheme_host: bool,
    /// The paths the platforms open; `None` lists every linkable route.
    pub paths: Option<Vec<LinkPath>>,
    /// The Android apps, in the order the pubspec has them; `assetlinks.json` has one each.
    pub apps_android: Vec<AndroidApp>,
    /// The iOS apps, in the order the pubspec has them; the association file lists all.
    pub apps_ios: Vec<IosApp>,
    /// Normalized, `/`-separated, no trailing slash, relative to the project root; empty for
    /// the root itself.
    pub out: String,
}

/// A flavour name as Gradle and Xcode take it: lower-case letters, digits and `_`.
fn is_flavor_name(s: &str) -> bool {
    s.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// One `paths:` entry: `/about`, `/orders/*`, `/`.
fn link_path(raw: &str) -> Option<LinkPath> {
    let rest = raw.strip_prefix('/')?;
    if rest.is_empty() {
        return Some(LinkPath::Exact(vec![]));
    }
    let mut segs: Vec<String> = vec![];
    let parts: Vec<&str> = rest.split('/').collect();
    let mut prefix = false;
    for (i, part) in parts.iter().enumerate() {
        if *part == "*" && i + 1 == parts.len() {
            prefix = true;
            continue;
        }
        if part.is_empty()
            || part.contains(['*', '?', '#', '\\', '%'])
            || part.chars().any(char::is_whitespace)
        {
            return None;
        }
        segs.push((*part).to_string());
    }
    Some(if prefix {
        LinkPath::Prefix(segs)
    } else {
        LinkPath::Exact(segs)
    })
}

/// The fingerprints of `key`, upper-case, each once.
fn fingerprints(key: &str, raw: Option<&[String]>) -> Result<Vec<String>> {
    let mut out: Vec<String> = vec![];
    for raw in raw.unwrap_or_default() {
        let f = raw.trim().to_ascii_uppercase();
        if !is_fingerprint(&f) {
            bail!(
                "`{key}.android_sha256`: `{raw}` is not a SHA-256 fingerprint; write 32 hex pairs separated by `:`, as `keytool -list -v` prints them (`AB:CD:...`)"
            );
        }
        if !out.contains(&f) {
            out.push(f);
        }
    }
    Ok(out)
}

/// The Android app of one set of keys (`key` is where they are in the pubspec), if any.
fn android_app(
    key: &str,
    flavor: Option<&str>,
    package: Option<&str>,
    sha256: Option<&[String]>,
) -> Result<Option<AndroidApp>> {
    let sha = fingerprints(key, sha256)?;
    match (package, sha.is_empty()) {
        (Some(package), false) => {
            if !is_application_id(package) {
                bail!(
                    "`{key}.android_package` must be an Android application id like `com.example.shop` (two or more parts separated by dots, each starting with a letter, with letters, digits and `_`), got `{package}`"
                );
            }
            Ok(Some(AndroidApp {
                flavor: flavor.map(str::to_string),
                package: package.to_string(),
                sha256: sha,
            }))
        }
        (Some(_), true) => bail!(
            "`{key}.android_package` needs `android_sha256`: assetlinks.json lists the fingerprints of the certificates the app is signed with (`keytool -list -v -keystore <keystore>`; with Play App Signing, the one in the Play Console)"
        ),
        (None, false) => bail!(
            "`{key}.android_sha256` needs `android_package`: the application id assetlinks.json is for"
        ),
        (None, true) => Ok(None),
    }
}

/// The iOS app of one set of keys, if any.
fn ios_app(key: &str, flavor: Option<&str>, id: Option<&str>) -> Result<Option<IosApp>> {
    let Some(id) = id else { return Ok(None) };
    if !is_app_id(id) {
        bail!(
            "`{key}.ios_app_id` must be the Team ID, a dot and the bundle id, like `ABCDE12345.com.example.shop` (the Team ID is 10 upper-case letters and digits), got `{id}`"
        );
    }
    Ok(Some(IosApp {
        flavor: flavor.map(str::to_string),
        app_id: id.to_string(),
    }))
}

impl LinksConfig {
    /// Checks the values, naming the key at fault.
    pub fn validate(&self) -> Result<Links> {
        let mut domains: Vec<String> = vec![];
        for raw in self.domains.as_deref().unwrap_or_default() {
            let Some(host) = host_name(raw) else {
                bail!(
                    "`fespalier.links.domains`: `{raw}` is not a host name; write it as `shop.example.com`, with no scheme, port or path (an international name in punycode)"
                );
            };
            if !domains.contains(&host) {
                domains.push(host);
            }
        }
        let Some(first) = domains.first() else {
            bail!(
                "`fespalier.links.domains` is required: list the host names the app opens, e.g. `domains: [shop.example.com]`"
            );
        };
        if first.starts_with("*.") {
            bail!(
                "`fespalier.links.domains`: the sitemap's URLs are on the first domain, so it can't be the wildcard `{first}`; list a host name first"
            );
        }

        let flavors = self.flavors.as_ref().filter(|f| !f.0.is_empty());
        let (mut apps_android, mut apps_ios) = (vec![], vec![]);
        match flavors {
            None => {
                apps_android.extend(android_app(
                    "fespalier.links",
                    None,
                    self.android_package.as_deref(),
                    self.android_sha256.as_deref(),
                )?);
                apps_ios.extend(ios_app(
                    "fespalier.links",
                    None,
                    self.ios_app_id.as_deref(),
                )?);
            }
            Some(Flavors(list)) => {
                if self.android_package.is_some()
                    || self.android_sha256.is_some()
                    || self.ios_app_id.is_some()
                {
                    bail!(
                        "`fespalier.links` takes `android_package`, `android_sha256` and `ios_app_id` for one app, or `flavors:` for several, not both"
                    );
                }
                for (name, f) in list {
                    if !is_flavor_name(name) {
                        bail!(
                            "`fespalier.links.flavors`: `{name}` is not a flavour name; use lower-case letters, digits and `_`, starting with a letter (the name Gradle and Xcode give it, like `prod`)"
                        );
                    }
                    if f.android_package.is_none()
                        && f.android_sha256.is_none()
                        && f.ios_app_id.is_none()
                    {
                        bail!(
                            "`fespalier.links.flavors.{name}` sets neither `android_package` nor `ios_app_id`"
                        );
                    }
                    let key = format!("fespalier.links.flavors.{name}");
                    if let Some(a) = android_app(
                        &key,
                        Some(name),
                        f.android_package.as_deref(),
                        f.android_sha256.as_deref(),
                    )? {
                        if let Some(other) = apps_android.iter().find(|o| o.package == a.package) {
                            bail!(
                                "`fespalier.links.flavors`: `{}` is the `android_package` of both `{}` and `{name}`",
                                a.package,
                                other.flavor.as_deref().unwrap_or_default()
                            );
                        }
                        apps_android.push(a);
                    }
                    if let Some(a) = ios_app(&key, Some(name), f.ios_app_id.as_deref())? {
                        if let Some(other) = apps_ios.iter().find(|o| o.app_id == a.app_id) {
                            bail!(
                                "`fespalier.links.flavors`: `{}` is the `ios_app_id` of both `{}` and `{name}`",
                                a.app_id,
                                other.flavor.as_deref().unwrap_or_default()
                            );
                        }
                        apps_ios.push(a);
                    }
                }
            }
        }

        if let Some(scheme) = &self.scheme {
            if !is_scheme(scheme) {
                bail!(
                    "`fespalier.links.scheme` must be a custom URL scheme in lower case, like `myshop` (letters, digits, `+`, `-` and `.`, starting with a letter), not `http` or `https`, got `{scheme}`"
                );
            }
            if apps_android.is_empty() && apps_ios.is_empty() {
                bail!(
                    "`fespalier.links.scheme` is written into the Android and iOS files: set `android_package` (with `android_sha256`) or `ios_app_id` too"
                );
            }
        } else if self.scheme_host.is_some() {
            bail!("`fespalier.links.scheme_host` needs `scheme`");
        }
        let paths = match &self.paths {
            None => None,
            Some(raw) if raw.is_empty() => {
                bail!("`fespalier.links.paths` is empty: leave it out to list every linkable route")
            }
            Some(raw) => {
                let mut out: Vec<LinkPath> = vec![];
                for entry in raw {
                    let Some(p) = link_path(entry) else {
                        bail!(
                            "`fespalier.links.paths`: `{entry}` is not a path pattern; write `/about` (that path) or `/orders/*` (everything below `/orders/`), starting with `/`, with `*` only as the whole last segment"
                        );
                    };
                    if !out.contains(&p) {
                        out.push(p);
                    }
                }
                Some(out)
            }
        };
        let out = match &self.out {
            None => DEFAULT_LINKS_OUT.to_string(),
            Some(raw) => project_folder("links.out", raw)?,
        };
        Ok(Links {
            domains,
            scheme: self.scheme.clone(),
            scheme_host: self.scheme_host.unwrap_or(true),
            paths,
            apps_android,
            apps_ios,
            out,
        })
    }
}

/// The `maestro:` section of the `fespalier:` config, as the pubspec has it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MaestroConfig {
    app_id: Option<String>,
    url: Option<String>,
    link: Option<String>,
    out: Option<String>,
    guard_flow: Option<String>,
    timeout: Option<i64>,
    samples: Option<BTreeMap<String, Value>>,
}

/// What each flow starts: the app on a device, or a page in a browser.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// Android and iOS: the flow's `appId:`.
    App(String),
    /// The web: the flow's `url:`.
    Web(String),
}

/// The `maestro:` section, checked: what `fsp maestro` writes flows for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Maestro {
    pub target: Target,
    /// What a route's path is appended to, as the flow opens it: `myshop://shop.example.com`,
    /// `http://localhost:8080/#`; no trailing `/`.
    pub link: String,
    /// An Android and iOS flow opening an `https` link: Maestro's `autoVerify` skips the
    /// "Open with" dialog of Android.
    pub https_app_link: bool,
    /// Normalized, `/`-separated, no trailing slash, relative to the project root; empty for
    /// the root itself.
    pub out: String,
    /// A flow that gets past the guards (signs in), normalized and relative to the project root.
    pub guard_flow: Option<String>,
    /// How long a flow waits for its page, in milliseconds.
    pub timeout: u32,
    /// The value of each dynamic folder (its path below the app folder), as the pubspec orders them.
    pub samples: Vec<(String, SampleValue)>,
}

/// `${APP_ID}`: a Maestro variable, which `maestro test -e APP_ID=...` fills in.
fn is_variable(s: &str) -> bool {
    s.strip_prefix("${")
        .and_then(|r| r.strip_suffix('}'))
        .is_some_and(|name| {
            name.chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

/// `com.example.shop`: two or more dot-separated parts, each starting with a letter. Bundle ids
/// take `-` too.
fn is_bundle_or_application_id(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|p| {
            p.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-'))
        })
}

/// `http://localhost:8080`: an http or https URL with a host, and no query or fragment.
fn is_http_url(s: &str) -> bool {
    let Some(rest) = s
        .strip_prefix("http://")
        .or_else(|| s.strip_prefix("https://"))
    else {
        return false;
    };
    !rest.split('/').next().unwrap_or_default().is_empty()
        && !s.contains(char::is_whitespace)
        && !s.contains(['?', '#'])
}

/// `<scheme>://` and something after it, with no whitespace and no query. A `#` may only end it
/// (`http://localhost:8080/#`, a hash-strategy app's route prefix).
fn is_link_prefix(s: &str) -> bool {
    let Some((scheme, rest)) = s.split_once("://") else {
        return false;
    };
    let scheme_ok = scheme
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'));
    let body = rest.strip_suffix('#').unwrap_or(rest);
    scheme_ok
        && !rest.is_empty()
        && !s.contains(char::is_whitespace)
        && !s.contains('?')
        && !body.contains('#')
}

impl MaestroConfig {
    /// The `samples:` as the pubspec has them (`fsp test` falls back to them).
    pub fn raw_samples(&self) -> Option<&BTreeMap<String, Value>> {
        self.samples.as_ref()
    }

    /// Checks the values, naming the key at fault. `links` is the `links:` section, which the
    /// default `link` comes from when the flows are for an app.
    pub fn validate(&self, links: Option<&LinksConfig>) -> Result<Maestro> {
        let target = match (&self.app_id, &self.url) {
            (None, None) => bail!(
                "`fespalier.maestro` needs `app_id` (Android and iOS) or `url` (the web): what each flow's `appId:` or `url:` is"
            ),
            (Some(_), Some(_)) => bail!(
                "`fespalier.maestro` takes `app_id` or `url`, not both: a flow is for Android and iOS or for the web"
            ),
            (Some(id), None) => {
                if !is_variable(id) && !is_bundle_or_application_id(id) {
                    bail!(
                        "`fespalier.maestro.app_id` must be an application or bundle id like `com.example.shop`, or a Maestro variable like `${{APP_ID}}`, got `{id}`"
                    );
                }
                Target::App(id.clone())
            }
            (None, Some(url)) => {
                if !is_variable(url) && !is_http_url(url) {
                    bail!(
                        "`fespalier.maestro.url` must be an http or https URL like `http://localhost:8080`, or a Maestro variable like `${{URL}}`, got `{url}`"
                    );
                }
                Target::Web(url.clone())
            }
        };
        let link = match &self.link {
            Some(raw) => {
                if !is_variable(raw) && !is_link_prefix(raw) {
                    bail!(
                        "`fespalier.maestro.link` must be a URL like `myshop://shop.example.com` or `http://localhost:8080/#`, with no query, or a Maestro variable like `${{LINK}}`, got `{raw}`"
                    );
                }
                raw.strip_suffix('/').unwrap_or(raw).to_string()
            }
            None => match (&target, links) {
                (Target::Web(url), _) => url.strip_suffix('/').unwrap_or(url).to_string(),
                (Target::App(_), Some(links)) => {
                    let links = links.validate()?;
                    let host = links.domains.first().cloned().unwrap_or_default();
                    match links.scheme {
                        Some(scheme) if !links.scheme_host => format!("{scheme}://"),
                        Some(scheme) => format!("{scheme}://{host}"),
                        None => format!("https://{host}"),
                    }
                }
                (Target::App(_), None) => bail!(
                    "`fespalier.maestro.link` is required with `app_id` when there is no `links:` section: write what a route's path goes after, e.g. `link: myshop://shop.example.com`"
                ),
            },
        };
        let out = match &self.out {
            None => DEFAULT_MAESTRO_OUT.to_string(),
            Some(raw) => project_folder("maestro.out", raw)?,
        };
        let guard_flow = match &self.guard_flow {
            None => None,
            Some(raw) => {
                let file = project_path(raw).filter(|p| {
                    let name = p.rsplit('/').next().unwrap_or_default();
                    name.strip_suffix(".yaml")
                        .or_else(|| name.strip_suffix(".yml"))
                        .is_some_and(|stem| !stem.is_empty())
                });
                match file {
                    Some(p) => Some(p),
                    None => bail!(
                        "`fespalier.maestro.guard_flow` must be a .yaml or .yml file inside the project (relative, no `..`), got `{raw}`"
                    ),
                }
            }
        };
        let timeout = match self.timeout {
            None => DEFAULT_MAESTRO_TIMEOUT,
            Some(n) => match u32::try_from(n)
                .ok()
                .filter(|n| (1000..=600_000).contains(n))
            {
                Some(n) => n,
                None => bail!(
                    "`fespalier.maestro.timeout` is in milliseconds, from 1000 to 600000, got `{n}`"
                ),
            },
        };
        let samples = samples::parse("fespalier.maestro.samples", self.samples.as_ref())?;
        Ok(Maestro {
            https_app_link: matches!(target, Target::App(_)) && link.starts_with("https://"),
            target,
            link,
            out,
            guard_flow,
            timeout,
            samples,
        })
    }
}

/// The `size:` section of the `fespalier:` config, as the pubspec has it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SizeConfig {
    build: Option<String>,
    main: Option<Value>,
    route: Option<Value>,
    routes: Option<BTreeMap<String, Value>>,
}

/// The `size:` section, checked: what `fsp size` reports and checks against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Size {
    /// Normalized, `/`-separated, relative to the project root: `build/web`.
    pub build: String,
    /// The budget for `main.dart.js`, in bytes.
    pub main: Option<u64>,
    /// The budget for each deferred route's own and shared chunks together, in bytes.
    pub route: Option<u64>,
    /// The budget of single routes by pattern, as the pubspec orders them; each wins over
    /// `route`.
    pub routes: Vec<(String, u64)>,
}

impl Size {
    /// Whether any budget is set.
    #[must_use]
    pub fn has_budgets(&self) -> bool {
        self.main.is_some() || self.route.is_some() || !self.routes.is_empty()
    }
}

/// A value as the pubspec spells it, for a message.
pub(crate) fn shown_value(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        other => serde_json::to_string(other).unwrap_or_default(),
    }
}

/// A size in bytes: a whole number of bytes of at least 1, or a number and a unit, `B`, `KB`
/// (1,024 bytes) or `MB` (1,048,576 bytes), with at most one space between: `3 MB`, `1.5 MB`,
/// `64KB`, `900 B`. The unit's case matters.
fn parse_size(v: &Value) -> Option<u64> {
    match v {
        Value::Number(n) => n.as_u64().filter(|n| *n >= 1),
        Value::String(s) => {
            let end = s.find(|c: char| !c.is_ascii_digit() && c != '.')?;
            let (number, unit) = s.split_at(end);
            let unit = unit.strip_prefix(' ').unwrap_or(unit);
            let factor = match unit {
                "B" => 1.0,
                "KB" => 1024.0,
                "MB" => 1_048_576.0,
                _ => return None,
            };
            let (whole, fraction) = number.split_once('.').unwrap_or((number, "0"));
            let digits = |p: &str| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit());
            if !digits(whole) || !digits(fraction) {
                return None;
            }
            let bytes = number.parse::<f64>().ok()? * factor;
            (0.5..1e15).contains(&bytes).then(|| {
                #[allow(
                    clippy::cast_possible_truncation,
                    clippy::cast_sign_loss,
                    reason = "checked to be at least 0.5 and below 1e15 just above"
                )]
                let n = bytes.round() as u64;
                n
            })
        }
        _ => None,
    }
}

impl SizeConfig {
    /// Checks the values, naming the key at fault.
    pub fn validate(&self) -> Result<Size> {
        let size = |key: &str, v: &Value| -> Result<u64> {
            parse_size(v).ok_or_else(|| {
                anyhow::anyhow!(
                    "`fespalier.size.{key}` must be a size like `3 MB`, `64 KB` or `900 B` (KB is 1,024 bytes), or a number of bytes, got `{}`",
                    shown_value(v)
                )
            })
        };
        let build = match &self.build {
            None => DEFAULT_SIZE_BUILD.to_string(),
            Some(raw) => project_folder("size.build", raw)?,
        };
        let mut routes = vec![];
        for (pattern, v) in self.routes.iter().flatten() {
            routes.push((pattern.clone(), size(&format!("routes.{pattern}"), v)?));
        }
        Ok(Size {
            build,
            main: self.main.as_ref().map(|v| size("main", v)).transpose()?,
            route: self.route.as_ref().map(|v| size("route", v)).transpose()?,
            routes,
        })
    }
}

/// The `test:` section of the `fespalier:` config, as the pubspec has it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TestConfig {
    out: Option<String>,
    setup: Option<String>,
    timeout: Option<i64>,
    samples: Option<BTreeMap<String, Value>>,
    skip: Option<Vec<String>>,
}

/// The `test:` section, checked: what `fsp test` writes a test file for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Test {
    /// Normalized, `/`-separated, relative to the project root, `test`, `integration_test` or a
    /// folder below one.
    pub out: String,
    /// The setup file as the pubspec names it: normalized and relative to the project root.
    /// `None` is the default, `<out>/setup.dart`, which is used when it exists.
    pub setup: Option<String>,
    /// How long a test waits for its page, in milliseconds of its fake clock.
    pub timeout: u32,
    /// The patterns (as `fsp routes` prints them) that get no test.
    pub skip: Vec<String>,
}

impl Test {
    /// The setup file, as a path relative to the project root: the configured one, or else
    /// `<out>/setup.dart`.
    pub fn setup_path(&self) -> String {
        self.setup
            .clone()
            .unwrap_or_else(|| format!("{}/setup.dart", self.out))
    }
}

impl TestConfig {
    /// The samples as written (`fsp test` falls back to the maestro ones when there are none).
    pub fn raw_samples(&self) -> Option<&BTreeMap<String, Value>> {
        self.samples.as_ref()
    }

    /// Checks the values, naming the key at fault. The samples are checked by the command, with
    /// the routes they are for.
    pub fn validate(&self) -> Result<Test> {
        let out = match &self.out {
            None => DEFAULT_TEST_OUT.to_string(),
            Some(raw) => {
                let out = project_folder("test.out", raw)?;
                if !matches!(out.split('/').next(), Some("test" | "integration_test")) {
                    bail!(
                        "`fespalier.test.out` must be `test`, `integration_test` or a folder below one of them, where `flutter test` finds tests, got `{raw}`"
                    );
                }
                out
            }
        };
        let setup = match &self.setup {
            None => None,
            Some(raw) => {
                let file = project_path(raw).filter(|p| {
                    let name = p.rsplit('/').next().unwrap_or_default();
                    name.strip_suffix(".dart")
                        .is_some_and(|stem| !stem.is_empty())
                });
                match file {
                    Some(p) => Some(p),
                    None => bail!(
                        "`fespalier.test.setup` must be a .dart file inside the project (relative, no `..`), got `{raw}`"
                    ),
                }
            }
        };
        let timeout = match self.timeout {
            None => DEFAULT_TEST_TIMEOUT,
            Some(n) => match u32::try_from(n)
                .ok()
                .filter(|n| (1000..=600_000).contains(n))
            {
                Some(n) => n,
                None => bail!(
                    "`fespalier.test.timeout` is in milliseconds of the test's fake clock, from 1000 to 600000, got `{n}`"
                ),
            },
        };
        Ok(Test {
            out,
            setup,
            timeout,
            skip: self.skip.clone().unwrap_or_default(),
        })
    }
}

/// A host name, lower-cased, optionally with a `*.` wildcard in front: two or more labels of
/// ASCII letters, digits and inner hyphens.
fn host_name(raw: &str) -> Option<String> {
    let host = raw.trim().to_ascii_lowercase();
    let labels: Vec<&str> = host
        .strip_prefix("*.")
        .unwrap_or(&host)
        .split('.')
        .collect();
    let label = |l: &&str| {
        (1..=63).contains(&l.len())
            && !l.starts_with('-')
            && !l.ends_with('-')
            && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    };
    (labels.len() >= 2 && labels.iter().all(label)).then_some(host)
}

/// `com.example.shop`: Android's rule for an application id.
fn is_application_id(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() >= 2
        && parts.iter().all(|p| {
            p.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
                && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

/// 32 upper-case hex pairs separated by `:`.
fn is_fingerprint(s: &str) -> bool {
    let pairs: Vec<&str> = s.split(':').collect();
    pairs.len() == 32
        && pairs
            .iter()
            .all(|p| p.len() == 2 && p.chars().all(|c| matches!(c, '0'..='9' | 'A'..='F')))
}

/// `ABCDE12345.com.example.shop`: an Apple Team ID, then the bundle id.
fn is_app_id(s: &str) -> bool {
    let Some((team, bundle)) = s.split_once('.') else {
        return false;
    };
    team.len() == 10
        && team
            .chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
        && !bundle.is_empty()
        && bundle
            .split('.')
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
}

fn is_scheme(s: &str) -> bool {
    s.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '+' | '-' | '.'))
        && !matches!(s, "http" | "https")
}

/// A path inside the project, `/`-separated, without `.` parts; `None` for an absolute one, a
/// drive letter or a `..`. `.` is the project root itself (`""`).
fn project_path(raw: &str) -> Option<String> {
    let parts: Vec<&str> = raw
        .split(['/', '\\'])
        .filter(|p| !p.is_empty() && *p != ".")
        .collect();
    if raw.trim().is_empty()
        || raw.starts_with(['/', '\\'])
        || raw.contains(':')
        || parts.contains(&"..")
    {
        return None;
    }
    Some(parts.join("/"))
}

/// A folder inside the project (the value of `fespalier.<key>`), `/`-separated; `.` is the
/// project root itself (`""`).
fn project_folder(key: &str, raw: &str) -> Result<String> {
    let Some(folder) = project_path(raw) else {
        bail!(
            "`fespalier.{key}` must be a folder inside the project (relative, no `..`), got `{raw}`"
        );
    };
    Ok(folder)
}

impl Config {
    /// Reads the project's config; defaults when there is no pubspec.yaml or
    /// no `fespalier:` section.
    pub fn load(project: &Path) -> Result<Config> {
        Ok(Pubspec::load(project)?.config)
    }

    /// This config for `fsp new` and `fsp init`, which scaffold files and then generate: a lint
    /// that is an error reports as a warning there, so a typo in code they did not write
    /// does not read as a failure of the scaffold.
    #[must_use]
    pub fn for_scaffolding(&self) -> Config {
        let mut cfg = self.clone();
        if cfg.lints.unknown_path == LintLevel::Error {
            cfg.lints.unknown_path = LintLevel::Warning;
        }
        cfg
    }

    /// The import path from the output file's folder to `rel` inside the app
    /// folder: `app/page.dart` for the defaults, `../pages/page.dart` for
    /// `lib/pages` with the output in `lib/router/`.
    pub fn import_path(&self, rel: &str) -> String {
        let dir = relative_dir(parent(&self.output), &self.app_dir);
        if dir.is_empty() {
            rel.to_string()
        } else {
            format!("{dir}/{rel}")
        }
    }

    /// The import path from the manifest file's folder to the main output file:
    /// `app.g.dart` for `lib/app.routes.g.dart`. `None` without `output_manifest`.
    pub fn output_from_manifest(&self) -> Option<String> {
        let manifest = self.output_manifest.as_deref()?;
        let dir = relative_dir(parent(manifest), parent(&self.output));
        let file = self.output.rsplit('/').next().unwrap_or(&self.output);
        Some(if dir.is_empty() {
            file.to_string()
        } else {
            format!("{dir}/{file}")
        })
    }

    /// The import path from the manifest file's folder to `rel` inside the app folder.
    pub fn import_path_from_manifest(&self, rel: &str) -> String {
        let manifest = self.output_manifest.as_deref().unwrap_or(&self.output);
        let dir = relative_dir(parent(manifest), &self.app_dir);
        if dir.is_empty() {
            rel.to_string()
        } else {
            format!("{dir}/{rel}")
        }
    }

    /// The import path, from the output file, of `uri` as written in the file `file`
    /// (relative to the app folder). `dart:` and `package:` imports are as they were.
    pub fn import_from_file(&self, file: &str, uri: &str) -> String {
        if uri.contains(':') {
            return uri.to_string();
        }
        let mut parts: Vec<&str> = self.app_dir.split('/').collect();
        parts.extend(parent(file).split('/').filter(|p| !p.is_empty()));
        for seg in uri.split('/') {
            match seg {
                "" | "." => {}
                ".." => {
                    parts.pop();
                }
                s => parts.push(s),
            }
        }
        let name = parts.pop().unwrap_or_default();
        let dir = relative_dir(parent(&self.output), &parts.join("/"));
        if dir.is_empty() {
            name.to_string()
        } else {
            format!("{dir}/{name}")
        }
    }

    /// Where the generated `main()` goes: `output` with its `.g.dart` (or `.dart`) suffix
    /// replaced by `.main.g.dart`, in the same folder. `lib/app.g.dart` is `lib/app.main.g.dart`.
    pub fn output_main(&self) -> String {
        let stem = self
            .output
            .strip_suffix(".g.dart")
            .or_else(|| self.output.strip_suffix(".dart"))
            .unwrap_or(&self.output);
        format!("{stem}.main.g.dart")
    }

    /// The output path relative to `lib/`, as a `package:` import spells it.
    pub fn output_in_lib(&self) -> &str {
        self.output.strip_prefix("lib/").unwrap_or(&self.output)
    }
}

impl Pubspec {
    pub fn load(project: &Path) -> Result<Pubspec> {
        let path = project.join("pubspec.yaml");
        let yaml = match fs::read_to_string(&path) {
            Ok(y) => y,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Pubspec::default()),
            Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
        };
        Pubspec::parse(&yaml).with_context(|| path.display().to_string())
    }

    pub fn parse(yaml: &str) -> Result<Pubspec> {
        if yaml.trim().is_empty() {
            return Ok(Pubspec::default());
        }
        let raw: RawPubspec = serde_yaml_ng::from_str(yaml).context("invalid pubspec.yaml")?;
        let mut config = Config {
            package: raw.name.clone(),
            ..Config::default()
        };
        if let Some(c) = raw.fespalier {
            config.format = c.format.unwrap_or(false);
            config.case_sensitive = c.case_sensitive.unwrap_or(true);
            config.remount = c.remount.unwrap_or(config.remount);
            config.deferred = c.deferred.unwrap_or(config.deferred);
            config.data_retry = c.data_retry.unwrap_or(config.data_retry);
            config.keep_previous = c.keep_previous.unwrap_or(config.keep_previous);
            config.push_updates_url = c.push_updates_url.unwrap_or(config.push_updates_url);
            config.file_style = c.file_style.unwrap_or(config.file_style);
            config.links = c.links;
            config.lints.unknown_path = c.lints.and_then(|l| l.unknown_path).unwrap_or_default();
            config.semantics_ids = c.semantics_ids.unwrap_or(false);
            config.scroll_restoration = c.scroll_restoration.unwrap_or(false);
            config.telemetry = c.telemetry.unwrap_or(false);
            config.maestro = c.maestro;
            config.size = c.size;
            config.test = c.test;
            config.tasks = c.tasks;
            config.main = c.main.unwrap_or_default();
            config.adapters = adapters(c.adapters.unwrap_or_default(), &raw.dependencies)?;
            if let Some(d) = c.app_dir {
                config.app_dir = lib_path("app_dir", &d)?;
            }
            if let Some(o) = c.output {
                config.output = lib_path("output", &o)?;
                if !config.output.ends_with(".dart") {
                    bail!("`fespalier.output` must be a .dart file, got `{o}`");
                }
            }
            if let Some(m) = c.output_manifest {
                let path = lib_path("output_manifest", &m)?;
                if !path.ends_with(".dart") {
                    bail!("`fespalier.output_manifest` must be a .dart file, got `{m}`");
                }
                if path == config.output {
                    bail!(
                        "`fespalier.output_manifest` and `fespalier.output` are the same file (`{path}`); leave `output_manifest` out to keep the manifest in `output`"
                    );
                }
                config.output_manifest = Some(path);
            }
            if config.output_manifest.as_deref() == Some(config.output_main().as_str()) {
                bail!(
                    "`fespalier.output_manifest` is `{}`, the file the generated main() goes in (`output` with `.main.g.dart`); pick another name",
                    config.output_main()
                );
            }
            for key in c.meta_unique.unwrap_or_default() {
                let ident = key
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
                    && key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
                if !ident {
                    bail!(
                        "`fespalier.meta_unique` lists argument names of `meta`, e.g. `[code, slug]`; `{key}` is not one"
                    );
                }
                if !config.meta_unique.contains(&key) {
                    config.meta_unique.push(key);
                }
            }
            match c.meta.as_deref() {
                None | Some("optional") => {}
                Some("required") => config.meta_required = true,
                Some(other) => {
                    bail!("`fespalier.meta` must be `required` or `optional`, got `{other}`")
                }
            }
        }
        let has_dependency =
            matches!(&raw.dependencies, Some(Value::Mapping(m)) if m.contains_key("fespalier"));
        // A pubspec with no `dependencies:` at all (a test's) says nothing, so it keeps the default.
        if let Some(Value::Mapping(m)) = &raw.dependencies {
            config.forms_dependency = m.contains_key("fespalier_forms");
        }
        Ok(Pubspec {
            name: raw.name,
            has_dependency,
            config,
        })
    }
}

/// `adapters:`, checked: each a Dart package name, none twice, none `fespalier` itself, and each
/// under `dependencies:` (the generated `app.g.dart` imports `package:<name>/fespalier_adapter.dart`).
fn adapters(names: Vec<String>, dependencies: &Option<Value>) -> Result<Vec<String>> {
    let mut out: Vec<String> = vec![];
    for name in names {
        let ident = name.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if !ident {
            bail!(
                "`fespalier.adapters` lists Dart packages by name, like `fespalier_sentry`; `{name}` is not one"
            );
        }
        if out.contains(&name) {
            bail!("`fespalier.adapters` lists `{name}` twice");
        }
        if name == "fespalier" {
            bail!(
                "`fespalier.adapters` lists packages that plug into fespalier's generated main(); `fespalier` is the framework itself, not an adapter"
            );
        }
        let declared =
            matches!(dependencies, Some(Value::Mapping(m)) if m.contains_key(name.as_str()));
        if !declared {
            bail!(
                "`fespalier.adapters` lists `{name}`, which is not under `dependencies:` in pubspec.yaml; add it there (next to fespalier, at the same git ref)"
            );
        }
        out.push(name);
    }
    Ok(out)
}

/// Normalizes a project-relative path that must sit under `lib/`.
fn lib_path(key: &str, raw: &str) -> Result<String> {
    let parts: Vec<&str> = raw
        .split(['/', '\\'])
        .filter(|p| !p.is_empty() && *p != ".")
        .collect();
    if raw.starts_with(['/', '\\'])
        || parts.contains(&"..")
        || parts.first() != Some(&"lib")
        || parts.len() < 2
    {
        bail!(
            "`fespalier.{key}` must be a path under lib/ (it is imported as package code), got `{raw}`"
        );
    }
    Ok(parts.join("/"))
}

pub(crate) fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(dir, _)| dir)
}

/// `to` as a relative path from directory `from` (both `/`-separated).
pub(crate) fn relative_dir(from: &str, to: &str) -> String {
    let from: Vec<&str> = from.split('/').filter(|p| !p.is_empty()).collect();
    let to: Vec<&str> = to.split('/').filter(|p| !p.is_empty()).collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts = vec![".."; from.len() - common];
    parts.extend(&to[common..]);
    parts.join("/")
}
