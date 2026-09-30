//! The optional `fespalier:` section of the project's pubspec.yaml:
//!
//! ```yaml
//! fespalier:
//!   app_dir: lib/app        # default
//!   output: lib/app.g.dart  # default
//!   format: false           # default; true runs `dart format` on the output
//!   case_sensitive: true    # default; false matches `/Products` too
//! ```
//!
//! Both paths are relative to the project root and live under `lib/`, because
//! the generated file imports the app files as ordinary package code.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_yaml_ng::Value;

pub const DEFAULT_APP_DIR: &str = "lib/app";
pub const DEFAULT_OUTPUT: &str = "lib/app.g.dart";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// Normalized, `/`-separated, no trailing slash: `lib/app`.
    pub app_dir: String,
    /// Normalized, `/`-separated: `lib/app.g.dart`.
    pub output: String,
    /// Run `dart format` on the generated file (when `dart` is on PATH).
    pub format: bool,
    /// Whether routes match paths by case; `false` emits `caseSensitive: false` on each.
    pub case_sensitive: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config { app_dir: DEFAULT_APP_DIR.into(), output: DEFAULT_OUTPUT.into(), format: false, case_sensitive: true }
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
    case_sensitive: Option<bool>,
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
        if dir.is_empty() { rel.to_string() } else { format!("{dir}/{rel}") }
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
        if dir.is_empty() { name.to_string() } else { format!("{dir}/{name}") }
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
            if let Some(d) = c.app_dir {
                config.app_dir = lib_path("app_dir", &d)?;
            }
            if let Some(o) = c.output {
                config.output = lib_path("output", &o)?;
                if !config.output.ends_with(".dart") {
                    bail!("`fespalier.output` must be a .dart file, got `{o}`");
                }
            }
        }
        let has_dependency = matches!(&raw.dependencies, Some(Value::Mapping(m)) if m.contains_key("fespalier"));
        Ok(Pubspec { name: raw.name, has_dependency, config })
    }
}

/// Normalizes a project-relative path that must sit under `lib/`.
fn lib_path(key: &str, raw: &str) -> Result<String> {
    let parts: Vec<&str> = raw.split(['/', '\\']).filter(|p| !p.is_empty() && *p != ".").collect();
    if raw.starts_with(['/', '\\']) || parts.contains(&"..") || parts.first() != Some(&"lib") || parts.len() < 2 {
        bail!("`fespalier.{key}` must be a path under lib/ (it is imported as package code), got `{raw}`");
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
