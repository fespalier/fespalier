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
//!   data_retry: inherit     # default; `none` gives generated data() providers `retry: null`
//!   keep_previous: true     # default; false shows loading.dart whenever data.dart loads
//!   file_style: snake       # default; `kebab` makes `fsp init` and `fsp new` write not-found.dart
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
    pub data_retry: DataRetry,
    /// Keep rendering the old value or error while `data.dart` reloads.
    pub keep_previous: bool,
    /// How `fsp init` and `fsp new` spell a multi-word file kind. Reading takes both.
    pub file_style: FileStyle,
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
            data_retry: DataRetry::Inherit,
            keep_previous: true,
            file_style: FileStyle::Snake,
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
    data_retry: Option<DataRetry>,
    keep_previous: Option<bool>,
    file_style: Option<FileStyle>,
}

impl Config {
    /// Reads the project's config; defaults when there is no pubspec.yaml or
    /// no `fespalier:` section.
    pub fn load(project: &Path) -> Result<Config> {
        Ok(Pubspec::load(project)?.config)
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
            config.data_retry = c.data_retry.unwrap_or(config.data_retry);
            config.keep_previous = c.keep_previous.unwrap_or(config.keep_previous);
            config.file_style = c.file_style.unwrap_or(config.file_style);
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
