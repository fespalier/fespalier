//! Where an app's pubspec takes fespalier and its companion packages from (since 0.23.0): one
//! repository at one `ref:`, or the `packages/` folder of one checkout. `fsp add` pins a new
//! companion the way `fespalier` is pinned, and `fsp upgrade --app` moves every `ref:` together.
//!
//! Only the packages of this repository count ([`is_ours`]): those this `fsp` knows, and a git
//! dependency on `packages/<name>` of the repository fespalier comes from. A `fespalier_*` package
//! of someone else's is not read.

use serde_yaml_ng::Value;

use crate::create::recipes::{NOT_A_CREATE_FEATURE, RECIPES};

/// The sections of a pubspec a package can be listed in, in the order they are read.
pub const SECTIONS: [&str; 3] = ["dependencies", "dev_dependencies", "dependency_overrides"];

/// Whether `name` is `fespalier` or one of its companions in `packages/`. The two tables of
/// `create/recipes.rs` hold every one (`create_tests` fails when a package is in neither).
#[must_use]
pub fn is_package(name: &str) -> bool {
    name == "fespalier"
        || RECIPES.iter().any(|r| r.companions.contains(&name))
        || NOT_A_CREATE_FEATURE.iter().any(|(n, _)| *n == name)
}

/// Whether `name`, listed as `value`, is fespalier or one of its companions (since 0.23.1): a
/// package this `fsp` knows ([`is_package`]), or a git dependency on `packages/<name>` of the
/// repository `fespalier` (fespalier's own entry) comes from, as a package newer than this `fsp`
/// is. Never by its name alone: `fespalier_extras: ^1.0.0` is someone else's. `fsp add`,
/// `fsp upgrade --app` and `fsp doctor` all read the pubspec through this.
#[must_use]
pub fn is_ours(name: &str, value: &Value, fespalier: Option<&Value>) -> bool {
    if is_package(name) {
        return true;
    }
    let (Some((url, _)), Some((other, Some(path)))) = (fespalier.and_then(git_of), git_of(value))
    else {
        return false;
    };
    same_url(url, other) && path.trim_end_matches('/') == format!("packages/{name}")
}

/// The `url:` and `path:` of a git dependency (`git: <url>` has no path).
fn git_of(value: &Value) -> Option<(&str, Option<&str>)> {
    let git = value.get("git")?;
    let url = git
        .get("url")
        .and_then(Value::as_str)
        .or_else(|| git.as_str())?;
    Some((url, git.get("path").and_then(Value::as_str)))
}

/// Where one package comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Origin {
    /// `git:` with `url:`, `path: packages/<name>` and `ref:`.
    Git { url: String, reference: String },
    /// `path: <root>/<name>`: a checkout's folder.
    Path { root: String },
    /// Anything else (a version range, a git dependency without `ref:` or `path:`), as a person
    /// would describe it.
    Other(String),
}

impl Origin {
    /// How the pubspec spells it, for messages: `git <url> at <ref>`, `path <root>/<name>`.
    #[must_use]
    pub fn describe(&self, name: &str) -> String {
        match self {
            Origin::Git { url, reference } => format!("{url} at {reference}"),
            Origin::Path { root } => format!("path {root}/{name}"),
            Origin::Other(what) => what.clone(),
        }
    }

    /// The lines under `<name>:` that pin `name` the same way (for `Insert` in `pubspec_edit`).
    #[must_use]
    pub fn lines(&self, name: &str) -> Vec<String> {
        match self {
            Origin::Git { url, reference } => vec![
                "git:".to_string(),
                format!("  url: {url}"),
                format!("  path: packages/{name}"),
                format!("  ref: {reference}"),
            ],
            Origin::Path { root } => vec![format!("path: {root}/{name}")],
            Origin::Other(_) => vec![],
        }
    }

    /// The same origin, compared as pub would: a URL with or without `.git` or a final `/`.
    #[must_use]
    pub fn same_as(&self, other: &Origin) -> bool {
        match (self, other) {
            (
                Origin::Git { url, reference },
                Origin::Git {
                    url: url2,
                    reference: reference2,
                },
            ) => same_url(url, url2) && reference == reference2,
            (a, b) => a == b,
        }
    }
}

/// Two repository URLs that name one repository.
#[must_use]
pub fn same_url(a: &str, b: &str) -> bool {
    let norm = |u: &str| {
        u.trim()
            .trim_end_matches('/')
            .trim_end_matches(".git")
            .to_ascii_lowercase()
    };
    norm(a) == norm(b)
}

/// One package of this repository listed in a pubspec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pin {
    pub name: String,
    /// One of [`SECTIONS`].
    pub section: &'static str,
    pub origin: Origin,
}

/// The packages of this repository a pubspec lists, and where `fespalier` comes from.
#[derive(Debug, Clone)]
pub struct Pins {
    /// `fespalier` under `dependencies:`.
    pub fespalier: Origin,
    /// Every package of this repository, `fespalier` included, in the order of [`SECTIONS`] and
    /// then of the file.
    pub all: Vec<Pin>,
}

/// Where `name` comes from, listed as `value`.
#[must_use]
pub fn origin_of(name: &str, value: &Value) -> Origin {
    let text = |v: Option<&Value>| v.and_then(Value::as_str).map(str::to_string);
    if let Some(git) = value.get("git") {
        let url = text(git.get("url")).or_else(|| text(Some(git)));
        let path = text(git.get("path"));
        let reference = text(git.get("ref"));
        return match (url, path, reference) {
            (Some(url), Some(path), Some(reference))
                if path.trim_end_matches('/') == format!("packages/{name}") =>
            {
                Origin::Git { url, reference }
            }
            (Some(url), Some(path), None) => {
                Origin::Other(format!("git {url} ({path}) with no ref:"))
            }
            (Some(url), Some(path), Some(reference)) => {
                Origin::Other(format!("git {url} at {reference}, path {path}"))
            }
            (Some(url), None, _) => Origin::Other(format!("git {url} with no path:")),
            (None, _, _) => Origin::Other("a git dependency with no url:".to_string()),
        };
    }
    if let Some(path) = text(value.get("path")) {
        let path = path.trim_end_matches('/');
        return match path.rsplit_once('/') {
            Some((root, last)) if last == name => Origin::Path {
                root: root.to_string(),
            },
            None if path == name => Origin::Path {
                root: ".".to_string(),
            },
            _ => Origin::Other(format!("path {path}")),
        };
    }
    match value {
        Value::String(range) => Origin::Other(format!("version {range}")),
        Value::Null => Origin::Other("no source (a hosted package)".to_string()),
        _ => Origin::Other("a source fsp does not read".to_string()),
    }
}

/// Reads the pins of a parsed pubspec. Refuses one that does not depend on `fespalier`.
pub fn read(pubspec: &Value) -> Result<Pins, String> {
    let own = pubspec.get("dependencies").and_then(|d| d.get("fespalier"));
    let mut all = vec![];
    for section in SECTIONS {
        let Some(Value::Mapping(map)) = pubspec.get(section) else {
            continue;
        };
        for (name, value) in map {
            let Some(name) = name.as_str() else { continue };
            if !is_ours(name, value, own) {
                continue;
            }
            all.push(Pin {
                name: name.to_string(),
                section,
                origin: origin_of(name, value),
            });
        }
    }
    let fespalier = all
        .iter()
        .find(|p| p.section == "dependencies" && p.name == "fespalier")
        .map(|p| p.origin.clone())
        .ok_or_else(|| {
            "pubspec.yaml does not list fespalier under dependencies: (`fsp init` says what to add)"
                .to_string()
        })?;
    if let Origin::Other(what) = &fespalier {
        return Err(format!(
            "fespalier comes from {what}; fsp reads a git dependency (url:, path: packages/fespalier, ref:) or a path: to a checkout's packages/fespalier"
        ));
    }
    Ok(Pins { fespalier, all })
}

impl Pins {
    /// The packages of `dependencies:` and `dev_dependencies:` that are not pinned as `fespalier`
    /// is, each with how it is pinned: what `fsp add` refuses to add to.
    #[must_use]
    pub fn out_of_line(&self) -> Vec<String> {
        self.all
            .iter()
            .filter(|p| p.section != "dependency_overrides" && !p.origin.same_as(&self.fespalier))
            .map(|p| format!("{} ({}): {}", p.name, p.section, p.origin.describe(&p.name)))
            .collect()
    }

    /// Whether `name` is listed in `section`.
    #[must_use]
    pub fn has(&self, section: &str, name: &str) -> bool {
        self.all
            .iter()
            .any(|p| p.section == section && p.name == name)
    }
}
