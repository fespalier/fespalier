//! What `fsp create` will do, decided without touching the disk, a process or the clock.
//!
//! [`build`] is a function of the [`Request`] and a feature table: the same request gives the
//! same [`Plan`], byte for byte, which is what the golden files in `tests/golden/create/` pin.
//! Everything that needs the machine (is the folder empty, which Flutter is installed, where
//! is the checkout) is read by `create.rs` and handed in as data. The one version of fespalier
//! the pubspec names is [`REF`], taken from this crate's own version, so a release moves it
//! with no edit.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use serde::Serialize;

use super::recipes::{Recipe, Source, companion_closure};
use crate::{init, templates};

/// The tag of fespalier every dependency of a new app is pinned to: this `fsp`'s own version.
pub const REF: &str = concat!("v", env!("CARGO_PKG_VERSION"));

/// Where the packages live.
pub const REPO_URL: &str = "https://github.com/fespalier/fespalier";

/// The lowest Flutter fespalier supports (`major.minor`), and so the lowest a new app declares.
pub const BASE_FLOOR: &str = "3.32";

/// The platforms `flutter create --platforms` knows.
pub const PLATFORMS: [&str; 6] = ["android", "ios", "linux", "macos", "web", "windows"];

/// The description of an app made without `--description`.
const DEFAULT_DESCRIPTION: &str = "A new fespalier app.";

/// What is at the folder the app goes to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirState {
    Absent,
    Empty,
    NotEmpty,
    NotADirectory,
}

/// A Flutter version: `3.47.5`, from `flutter --version --machine`'s `frameworkVersion`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct FlutterVersion {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl FlutterVersion {
    /// `3.47.5`, `3.47.0-0.1.pre` and `3.47` read; anything else is `None`.
    #[must_use]
    pub fn parse(text: &str) -> Option<Self> {
        let core = text.trim().split(['-', '+']).next()?;
        let mut parts = core.split('.').map(|p| p.parse::<u32>().ok());
        let major = parts.next()??;
        let minor = parts.next()??;
        let patch = parts.next().unwrap_or(Some(0))?;
        parts.next().is_none().then_some(Self {
            major,
            minor,
            patch,
        })
    }

    /// Whether this is `floor` (`major.minor`) or newer.
    #[must_use]
    pub fn at_least(self, floor: &str) -> bool {
        floor_of(floor).is_none_or(|f| (self.major, self.minor) >= f)
    }
}

impl std::fmt::Display for FlutterVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// `3.32` as `(3, 32)`.
#[must_use]
pub fn floor_of(floor: &str) -> Option<(u32, u32)> {
    let (major, minor) = floor.split_once('.')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}

/// What the person asked for and what the machine looks like, read once by `create.rs`.
#[derive(Debug, Clone)]
pub struct Request {
    /// The folder to make, as given.
    pub dir: PathBuf,
    pub dir_state: DirState,
    /// `--project-name`; the folder's name when absent.
    pub name: Option<String>,
    pub org: Option<String>,
    pub platforms: Vec<String>,
    pub description: Option<String>,
    /// `--features`, as typed.
    pub features: Vec<String>,
    /// `--local-packages`: an absolute path to a checkout of fespalier.
    pub local_packages: Option<String>,
    pub no_pub_get: bool,
    pub offline: bool,
    /// The installed Flutter, or `None` when nothing was asked of it (`--dry-run`).
    pub flutter: Option<FlutterVersion>,
}

/// How a planned file meets what `flutter create` wrote before it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// A file `flutter create` does not write.
    New,
    /// A file `flutter create` wrote, replaced.
    Overwrite,
}

impl Action {
    #[must_use]
    pub fn word(self) -> &'static str {
        match self {
            Action::New => "new",
            Action::Overwrite => "overwrite",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlannedFile {
    /// Relative to the app, `/`-separated.
    pub path: String,
    pub content: String,
    pub action: Action,
}

/// Everything `fsp create` does, in the order it does it.
#[derive(Debug, Clone)]
pub struct Plan {
    /// The folder to make, as given.
    pub dir: PathBuf,
    /// The Dart package name.
    pub name: String,
    /// The features, in the table's order, requirements included.
    pub features: Vec<&'static str>,
    /// Things worth saying: a feature that was added because another needs it.
    pub notes: Vec<String>,
    /// The arguments of `flutter` that make the platform folders, before the folder itself.
    pub flutter_create: Vec<String>,
    /// Written over the result of `flutter create`, in this order.
    pub files: Vec<PlannedFile>,
    /// The arguments of `flutter` that resolve the dependencies; `None` with `--no-pub-get`.
    pub pub_get: Option<Vec<String>>,
}

/// `fsp create --list-features --json`: one line per feature.
#[derive(Debug, Clone, Serialize)]
pub struct FeatureInfo {
    pub id: &'static str,
    pub description: &'static str,
    pub flutter: &'static str,
    pub requires: Vec<&'static str>,
    pub conflicts: Vec<&'static str>,
    pub companions: Vec<&'static str>,
}

#[must_use]
pub fn list_features(table: &[Recipe]) -> Vec<FeatureInfo> {
    table
        .iter()
        .map(|r| FeatureInfo {
            id: r.id,
            description: r.description,
            flutter: r.flutter_floor,
            requires: r.requires.to_vec(),
            conflicts: r.conflicts.to_vec(),
            companions: r.companions.to_vec(),
        })
        .collect()
}

/// Words a package may not be named: Dart's keywords, built-in identifiers and the like (what
/// `flutter create` refuses too).
const RESERVED: &[&str] = &[
    "abstract",
    "as",
    "assert",
    "async",
    "await",
    "base",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "covariant",
    "default",
    "deferred",
    "do",
    "dynamic",
    "else",
    "enum",
    "export",
    "extends",
    "extension",
    "external",
    "factory",
    "false",
    "final",
    "finally",
    "for",
    "get",
    "hide",
    "if",
    "implements",
    "import",
    "in",
    "interface",
    "is",
    "late",
    "library",
    "mixin",
    "new",
    "null",
    "of",
    "on",
    "operator",
    "part",
    "required",
    "rethrow",
    "return",
    "sealed",
    "set",
    "show",
    "static",
    "super",
    "switch",
    "sync",
    "this",
    "throw",
    "true",
    "try",
    "type",
    "typedef",
    "var",
    "void",
    "when",
    "while",
    "with",
    "yield",
];

/// Names an app cannot have because a package it depends on is called that.
const TAKEN: [&str; 5] = [
    "flutter",
    "flutter_test",
    "flutter_lints",
    "test",
    "fespalier",
];

/// Why `name` is not a name for an app's package, or `Ok`.
pub fn check_package_name(name: &str) -> Result<(), String> {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return Err("it is empty".to_string());
    };
    if !first.is_ascii_lowercase() {
        return Err("a package name starts with a lower case letter".to_string());
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    {
        return Err(
            "a package name has only lower case letters, digits and underscores".to_string(),
        );
    }
    if RESERVED.contains(&name) {
        return Err(format!("`{name}` is a Dart keyword"));
    }
    if TAKEN.contains(&name) {
        return Err(format!("the app depends on a package called `{name}`"));
    }
    Ok(())
}

/// The package name a folder gives: its own name, lower cased, with `-` and spaces as `_`.
fn name_of_dir(dir: &Path) -> Result<String> {
    let Some(base) = dir.file_name().and_then(|n| n.to_str()) else {
        bail!(
            "cannot name the app after `{}`: pass --project-name",
            dir.display()
        );
    };
    let name: String = base
        .chars()
        .map(|c| {
            if c == '-' || c == ' ' {
                '_'
            } else {
                c.to_ascii_lowercase()
            }
        })
        .collect();
    match check_package_name(&name) {
        Ok(()) => Ok(name),
        Err(why) => {
            bail!("`{base}` does not make a Dart package name ({why}): pass --project-name <name>")
        }
    }
}

/// `text` as a YAML scalar: as it is when that reads back the same, else in single quotes.
fn scalar(text: &str) -> String {
    let plain = text
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric() || c == '/')
        && !text.ends_with(' ')
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || " ._,()/+-".contains(c));
    if plain {
        text.to_string()
    } else {
        format!("'{}'", text.replace('\'', "''"))
    }
}

/// The features asked for, resolved against `table`: unknown ones refused, requirements added
/// (each with a note), conflicts refused, in the table's order.
pub fn resolve_features<'t>(
    table: &'t [Recipe],
    wanted: &[String],
) -> Result<(Vec<&'t Recipe>, Vec<String>)> {
    let mut chosen: Vec<&Recipe> = vec![];
    let mut notes = vec![];
    let mut queue: Vec<(String, Option<&str>)> = wanted.iter().map(|w| (w.clone(), None)).collect();
    queue.reverse();
    while let Some((id, needed_by)) = queue.pop() {
        if chosen.iter().any(|r| r.id == id) {
            continue;
        }
        let Some(recipe) = table.iter().find(|r| r.id == id) else {
            if table.is_empty() {
                bail!("unknown feature `{id}`: `fsp create` has no optional features yet");
            }
            let known: Vec<&str> = table.iter().map(|r| r.id).collect();
            bail!(
                "unknown feature `{id}`; the features are {} (`fsp create --list-features`)",
                known.join(", ")
            );
        };
        if let Some(by) = needed_by {
            notes.push(format!("`{by}` needs `{id}`: added it"));
        }
        chosen.push(recipe);
        for required in recipe.requires.iter().rev() {
            queue.push(((*required).to_string(), Some(recipe.id)));
        }
    }
    chosen.sort_by_key(|r| table.iter().position(|t| t.id == r.id));
    for a in &chosen {
        for b in &chosen {
            if a.id != b.id && a.conflicts.contains(&b.id) {
                bail!("`{}` and `{}` cannot be combined", a.id, b.id);
            }
        }
    }
    Ok((chosen, notes))
}

/// One entry of `dependencies:` or `dependency_overrides:`, as the template writes it.
#[derive(Serialize)]
struct Dep {
    name: String,
    /// `name:` alone, or `name: "<range>"`.
    head: String,
    /// The lines nested under `name:`.
    lines: Vec<String>,
}

#[derive(Serialize)]
struct Override {
    name: String,
    path: String,
}

#[derive(Serialize)]
struct PubspecCx<'a> {
    name: &'a str,
    description: String,
    floor: String,
    deps: Vec<Dep>,
    config: Vec<&'a str>,
    overrides: Vec<Override>,
}

/// The pubspec of the app: a function of the name, the features and where the packages come from.
fn pubspec(
    name: &str,
    description: &str,
    features: &[&Recipe],
    local: Option<&str>,
) -> Result<String> {
    let mut companions: Vec<&str> = features
        .iter()
        .flat_map(|r| r.companions.iter().copied())
        .collect();
    companions.sort_unstable();
    companions.dedup();
    let package_dep = |package: &str| -> Dep {
        let lines = match local {
            Some(root) => vec![format!(
                "path: {}",
                scalar(&format!("{root}/packages/{package}"))
            )],
            None => vec![
                "git:".to_string(),
                format!("  url: {REPO_URL}"),
                format!("  path: packages/{package}"),
                format!("  ref: {REF}"),
            ],
        };
        Dep {
            name: package.to_string(),
            head: format!("{package}:"),
            lines,
        }
    };
    let mut deps = vec![package_dep("fespalier")];
    deps.extend(companions.iter().map(|c| package_dep(c)));
    for tp in features.iter().flat_map(|r| r.third_party.iter()) {
        let (head, lines) = match tp.source {
            Source::Range(range) => (format!("{}: \"{range}\"", tp.name), vec![]),
            Source::Git { url, commit } => (
                format!("{}:", tp.name),
                vec![
                    "git:".to_string(),
                    format!("  url: {url}"),
                    format!("  ref: {commit}"),
                ],
            ),
        };
        deps.push(Dep {
            name: tp.name.to_string(),
            head,
            lines,
        });
    }
    deps.sort_by(|a, b| a.name.cmp(&b.name));
    deps.dedup_by(|a, b| a.name == b.name);
    if let Some(dep) = deps.iter().find(|d| d.name == name) {
        bail!(
            "the app cannot be named `{name}`: it depends on a package of that name ({})",
            dep.name
        );
    }
    let overrides = match local {
        Some(root) if !companions.is_empty() => {
            let mut all = companion_closure(&companions);
            all.push("fespalier".to_string());
            all.sort();
            all.into_iter()
                .map(|package| Override {
                    path: scalar(&format!("{root}/packages/{package}")),
                    name: package,
                })
                .collect()
        }
        _ => vec![],
    };
    let floor = features
        .iter()
        .map(|r| r.flutter_floor)
        .chain([BASE_FLOOR])
        .max_by_key(|f| floor_of(f))
        .unwrap_or(BASE_FLOOR);
    Ok(templates::render(
        "create/pubspec.yaml",
        PubspecCx {
            name,
            description: scalar(description),
            floor: floor.to_string(),
            deps,
            config: features
                .iter()
                .flat_map(|r| r.config.iter().copied())
                .collect(),
            overrides,
        },
    ))
}

/// The Dart files of the starting app: `fsp init`'s five, the home page with a link in it, and
/// an about page for the link to go to.
fn starter_files(package: &str) -> Vec<PlannedFile> {
    #[derive(Serialize)]
    struct Cx<'a> {
        package: &'a str,
    }
    let new = |path: String, content: String| PlannedFile {
        path,
        content,
        action: Action::New,
    };
    let mut files: Vec<PlannedFile> = init::STARTERS
        .iter()
        .map(|kind| {
            let content = if *kind == "page" {
                templates::render("create/home.dart", Cx { package })
            } else {
                init::starter(kind, package)
            };
            new(format!("lib/app/{kind}.dart"), content)
        })
        .collect();
    files.push(new(
        "lib/app/about/page.dart".to_string(),
        templates::render("create/about.dart", Cx { package }),
    ));
    files.sort_by(|a, b| a.path.cmp(&b.path));
    files
}

/// Decides everything. Refuses, in this order: a bad `--project-name`, `--org` or `--platforms`,
/// a folder that is not empty, an unknown or conflicting feature, a Flutter too old.
pub fn build(req: &Request, table: &[Recipe]) -> Result<Plan> {
    let name = match &req.name {
        Some(name) => match check_package_name(name) {
            Ok(()) => name.clone(),
            Err(why) => bail!("`{name}` is not a name for a Dart package: {why}"),
        },
        None => name_of_dir(&req.dir)?,
    };
    if let Some(org) = &req.org
        && (org.is_empty() || org.starts_with('-') || org.chars().any(char::is_whitespace))
    {
        bail!("`{org}` is not an organization like `com.example`");
    }
    for platform in &req.platforms {
        if !PLATFORMS.contains(&platform.as_str()) {
            bail!(
                "unknown platform `{platform}`; the platforms are {}",
                PLATFORMS.join(", ")
            );
        }
    }
    if let Some(description) = &req.description
        && description.contains(['\n', '\r'])
    {
        bail!("--description is one line");
    }
    match req.dir_state {
        DirState::Absent | DirState::Empty => {}
        DirState::NotEmpty => bail!(
            "{} is not empty; `fsp create` makes a new folder (to add fespalier to an existing app, run `fsp init`)",
            req.dir.display()
        ),
        DirState::NotADirectory => bail!("{} exists and is a file", req.dir.display()),
    }
    let (features, notes) = resolve_features(table, &req.features)?;
    if let Some(flutter) = req.flutter {
        if !flutter.at_least(BASE_FLOOR) {
            bail!(
                "Flutter {flutter} is too old: fespalier needs Flutter {BASE_FLOOR} or newer (https://docs.flutter.dev/release/upgrade)"
            );
        }
        for recipe in &features {
            if !flutter.at_least(recipe.flutter_floor) {
                bail!(
                    "`{}` needs Flutter {} or newer, and this is Flutter {flutter}; leave it out, or upgrade",
                    recipe.id,
                    recipe.flutter_floor
                );
            }
        }
    }

    let description = req.description.as_deref().unwrap_or(DEFAULT_DESCRIPTION);
    let local = req
        .local_packages
        .as_deref()
        .map(|p| p.trim_end_matches('/'));
    let mut files = vec![
        PlannedFile {
            path: "pubspec.yaml".to_string(),
            content: pubspec(&name, description, &features, local)?,
            action: Action::Overwrite,
        },
        PlannedFile {
            path: "lib/main.dart".to_string(),
            content: templates::render("create/main.dart", serde_json::json!({ "package": name })),
            action: Action::Overwrite,
        },
    ];
    files.extend(starter_files(&name));
    for recipe in &features {
        for (template, path) in recipe.files {
            files.push(PlannedFile {
                path: (*path).to_string(),
                content: templates::render(template, serde_json::json!({ "package": name })),
                action: Action::New,
            });
        }
    }

    let mut flutter_create = vec![
        "create".to_string(),
        "--no-pub".to_string(),
        "--empty".to_string(),
        format!("--project-name={name}"),
    ];
    if let Some(org) = &req.org {
        flutter_create.push(format!("--org={org}"));
    }
    if !req.platforms.is_empty() {
        flutter_create.push(format!("--platforms={}", req.platforms.join(",")));
    }
    let pub_get = (!req.no_pub_get).then(|| {
        let mut args = vec!["pub".to_string(), "get".to_string()];
        if req.offline {
            args.push("--offline".to_string());
        }
        args
    });
    Ok(Plan {
        dir: req.dir.clone(),
        name,
        features: features.iter().map(|r| r.id).collect(),
        notes,
        flutter_create,
        files,
        pub_get,
    })
}

impl Plan {
    /// The plan as text: what runs, then every file in full. `--dry-run` prints it and the
    /// goldens pin it. `staging` stands for the temporary folder `flutter create` works in.
    #[must_use]
    pub fn describe(&self, staging: &str) -> String {
        let mut out = String::new();
        let features = if self.features.is_empty() {
            "none".to_string()
        } else {
            self.features.join(", ")
        };
        let _ = writeln!(
            out,
            "create {} (package {}, features: {features})",
            self.dir.display(),
            self.name
        );
        for note in &self.notes {
            let _ = writeln!(out, "note  {note}");
        }
        let _ = writeln!(
            out,
            "run   flutter {} {staging}",
            self.flutter_create.join(" ")
        );
        let _ = writeln!(out, "move  {staging} -> {}", self.dir.display());
        if let Some(args) = &self.pub_get {
            let _ = writeln!(out, "run   flutter {}", args.join(" "));
        }
        let _ = writeln!(out, "run   fsp gen");
        let _ = writeln!(out, "run   fsp test");
        for file in &self.files {
            let _ = write!(
                out,
                "\n=== {} ({})\n{}",
                file.path,
                file.action.word(),
                file.content
            );
        }
        out
    }
}
