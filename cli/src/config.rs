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
//!   data_retry: inherit     # default; `none` gives generated data() providers `retry: null`
//!   keep_previous: true     # default; false shows loading.dart whenever data.dart loads
//!   push_updates_url: false # default; true puts a `push`ed route's URL in the browser's address bar
//!   file_style: snake       # default; `kebab` makes `fsp init` and `fsp new` write not-found.dart
//!   links:                  # default: none; what `fsp links` writes (see `links.rs`)
//!     domains: [shop.example.com]
//!     scheme: myshop
//!     android_package: com.example.shop
//!     android_sha256: ["AB:CD:..."]
//!     ios_app_id: TEAMID.com.example.shop
//!     out: links            # default
//!   lints:                  # one level per lint (see `lint.rs`)
//!     unknown_path: warning # default; `error` fails `gen` and `check`, `off` skips the check
//! ```
//!
//! Both paths are relative to the project root and live under `lib/`, because
//! the generated file imports the app files as ordinary package code.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_yaml_ng::Value;

use crate::scan::FileStyle;

pub const DEFAULT_APP_DIR: &str = "lib/app";
pub const DEFAULT_OUTPUT: &str = "lib/app.g.dart";
/// Where `fsp links` writes, relative to the project root.
pub const DEFAULT_LINKS_OUT: &str = "links";

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
    pub data_retry: DataRetry,
    /// Keep rendering the old value or error while `data.dart` reloads.
    pub keep_previous: bool,
    /// `GoRouter.optionURLReflectsImperativeAPIs`, which `AppRoutes.router()` assigns: a
    /// `push`ed route shows its URL in the browser's address bar.
    pub push_updates_url: bool,
    /// How `fsp init` and `fsp new` spell a multi-word file kind. Reading takes both.
    pub file_style: FileStyle,
    /// The `links:` section, as written. Only `fsp links` reads it, and it checks the values
    /// then ([`LinksConfig::validate`]), so a mistake in it never stops `fsp gen`.
    pub links: Option<LinksConfig>,
    /// The `lints:` section: how each lint over the app's own code reports.
    pub lints: Lints,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            app_dir: DEFAULT_APP_DIR.into(),
            output: DEFAULT_OUTPUT.into(),
            format: false,
            output_manifest: None,
            meta_required: false,
            meta_unique: vec![],
            case_sensitive: true,
            remount: Remount::Never,
            data_retry: DataRetry::Inherit,
            keep_previous: true,
            push_updates_url: false,
            file_style: FileStyle::Snake,
            links: None,
            lints: Lints::default(),
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
    data_retry: Option<DataRetry>,
    keep_previous: Option<bool>,
    push_updates_url: Option<bool>,
    file_style: Option<FileStyle>,
    links: Option<LinksConfig>,
    lints: Option<LintsConfig>,
}

/// The `links:` section of the `fespalier:` config, as the pubspec has it.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinksConfig {
    domains: Option<Vec<String>>,
    scheme: Option<String>,
    android_package: Option<String>,
    android_sha256: Option<Vec<String>>,
    ios_app_id: Option<String>,
    out: Option<String>,
}

/// The Android half of the `links:` section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AndroidLinks {
    /// The application id: `com.example.shop`.
    pub package: String,
    /// The signing certificates' SHA-256 fingerprints, upper-case, each once.
    pub sha256: Vec<String>,
}

/// The `links:` section, checked: what `fsp links` writes files for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Links {
    /// Lower-case host names, each once; the first is the one the sitemap is on.
    pub domains: Vec<String>,
    /// A custom URL scheme, besides `https`.
    pub scheme: Option<String>,
    /// Set with `android_package`: the Android files are written.
    pub android: Option<AndroidLinks>,
    /// Set with `ios_app_id` (`TEAMID.com.example.shop`): the iOS files are written.
    pub ios_app_id: Option<String>,
    /// Normalized, `/`-separated, no trailing slash, relative to the project root; empty for
    /// the root itself.
    pub out: String,
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

        let sha: Vec<String> = {
            let mut out: Vec<String> = vec![];
            for raw in self.android_sha256.as_deref().unwrap_or_default() {
                let f = raw.trim().to_ascii_uppercase();
                if !is_fingerprint(&f) {
                    bail!(
                        "`fespalier.links.android_sha256`: `{raw}` is not a SHA-256 fingerprint; write 32 hex pairs separated by `:`, as `keytool -list -v` prints them (`AB:CD:...`)"
                    );
                }
                if !out.contains(&f) {
                    out.push(f);
                }
            }
            out
        };
        let android = match (&self.android_package, sha.is_empty()) {
            (Some(package), false) => {
                if !is_application_id(package) {
                    bail!(
                        "`fespalier.links.android_package` must be an Android application id like `com.example.shop` (two or more parts separated by dots, each starting with a letter, with letters, digits and `_`), got `{package}`"
                    );
                }
                Some(AndroidLinks {
                    package: package.clone(),
                    sha256: sha,
                })
            }
            (Some(_), true) => bail!(
                "`fespalier.links.android_package` needs `android_sha256`: assetlinks.json lists the fingerprints of the certificates the app is signed with (`keytool -list -v -keystore <keystore>`; with Play App Signing, the one in the Play Console)"
            ),
            (None, false) => bail!(
                "`fespalier.links.android_sha256` needs `android_package`: the application id assetlinks.json is for"
            ),
            (None, true) => None,
        };

        if let Some(id) = &self.ios_app_id
            && !is_app_id(id)
        {
            bail!(
                "`fespalier.links.ios_app_id` must be the Team ID, a dot and the bundle id, like `ABCDE12345.com.example.shop` (the Team ID is 10 upper-case letters and digits), got `{id}`"
            );
        }
        if let Some(scheme) = &self.scheme {
            if !is_scheme(scheme) {
                bail!(
                    "`fespalier.links.scheme` must be a custom URL scheme in lower case, like `myshop` (letters, digits, `+`, `-` and `.`, starting with a letter), not `http` or `https`, got `{scheme}`"
                );
            }
            if android.is_none() && self.ios_app_id.is_none() {
                bail!(
                    "`fespalier.links.scheme` is written into the Android and iOS files: set `android_package` (with `android_sha256`) or `ios_app_id` too"
                );
            }
        }
        let out = match &self.out {
            None => DEFAULT_LINKS_OUT.to_string(),
            Some(raw) => links_out(raw)?,
        };
        Ok(Links {
            domains,
            scheme: self.scheme.clone(),
            android,
            ios_app_id: self.ios_app_id.clone(),
            out,
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

/// A folder inside the project, `/`-separated; `.` is the project root itself (`""`).
fn links_out(raw: &str) -> Result<String> {
    let parts: Vec<&str> = raw
        .split(['/', '\\'])
        .filter(|p| !p.is_empty() && *p != ".")
        .collect();
    if raw.trim().is_empty()
        || raw.starts_with(['/', '\\'])
        || raw.contains(':')
        || parts.contains(&"..")
    {
        bail!(
            "`fespalier.links.out` must be a folder inside the project (relative, no `..`), got `{raw}`"
        );
    }
    Ok(parts.join("/"))
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
        let mut config = Config::default();
        if let Some(c) = raw.fespalier {
            config.format = c.format.unwrap_or(false);
            config.case_sensitive = c.case_sensitive.unwrap_or(true);
            config.remount = c.remount.unwrap_or(config.remount);
            config.data_retry = c.data_retry.unwrap_or(config.data_retry);
            config.keep_previous = c.keep_previous.unwrap_or(config.keep_previous);
            config.push_updates_url = c.push_updates_url.unwrap_or(config.push_updates_url);
            config.file_style = c.file_style.unwrap_or(config.file_style);
            config.links = c.links;
            config.lints.unknown_path = c.lints.and_then(|l| l.unknown_path).unwrap_or_default();
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
        Ok(Pubspec {
            name: raw.name,
            has_dependency,
            config,
        })
    }
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

fn parent(path: &str) -> &str {
    path.rsplit_once('/').map_or("", |(dir, _)| dir)
}

/// `to` as a relative path from directory `from` (both `/`-separated).
fn relative_dir(from: &str, to: &str) -> String {
    let from: Vec<&str> = from.split('/').filter(|p| !p.is_empty()).collect();
    let to: Vec<&str> = to.split('/').filter(|p| !p.is_empty()).collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts = vec![".."; from.len() - common];
    parts.extend(&to[common..]);
    parts.join("/")
}
