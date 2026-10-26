//! Where an app's pubspec takes fespalier and its companion packages from (since 0.23.0): one
//! repository at one `ref:`, or the `packages/` folder of one checkout. `fsp add` pins a new
//! companion the way `fespalier` is pinned, and `fsp upgrade --app` moves every `ref:` together.
//!
//! Only the packages of this repository count ([`is_ours`]): those this `fsp` knows, and a git
//! dependency on `packages/<name>` of the repository fespalier comes from, when `<name>` is a
//! `fespalier_` name. A `fespalier_*` package of someone else's is not read, and neither is another
//! package of a repository that holds fespalier as well (a fork's own, a monorepo's).

use serde_yaml_ng::Value;

use crate::create::plan::REPO_URL;
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
/// package this `fsp` knows ([`is_package`]), or a `fespalier_` package that is a git dependency on
/// `packages/<name>` of the repository `fespalier` (fespalier's own entry) comes from, as a package
/// newer than this `fsp` is. Neither the name alone (`fespalier_extras: ^1.0.0` is someone else's)
/// nor the place alone (`acme_ui` in `packages/acme_ui` of a fork or a monorepo that holds fespalier
/// is its owner's). Every package of this repository is `packages/fespalier_*`. The repository is
/// told however its url is spelled ([`same_repository`], since 0.24.1), so a package spelled over
/// https next to a fespalier over ssh is read, and then said to come from another url, which pub
/// refuses too. `fsp add`, `fsp upgrade --app` and `fsp doctor` all read the pubspec through this.
#[must_use]
pub fn is_ours(name: &str, value: &Value, fespalier: Option<&Value>) -> bool {
    if is_package(name) {
        return true;
    }
    if !name.starts_with("fespalier_") {
        return false;
    }
    let (Some((url, _)), Some((other, Some(path)))) = (fespalier.and_then(git_of), git_of(value))
    else {
        return false;
    };
    same_repository(url, other) && in_packages(path, name)
}

/// Whether `name`, listed as `value`, is a package of a checkout of this repository (since 0.24.1):
/// a `path:` to a folder `<root>/packages/<name>`, for `fespalier` or a `fespalier_` name. The
/// place and the name, as [`is_ours`] tells a git dependency: what `fsp doctor` keeps an `override`
/// row for when the package is newer than this `fsp`, while `fespalier_extras: {path: ../extras}`
/// gets none.
#[must_use]
pub fn in_checkout(name: &str, value: &Value) -> bool {
    let fespalier_s = name == "fespalier" || name.starts_with("fespalier_");
    fespalier_s
        && value
            .get("path")
            .and_then(Value::as_str)
            .is_some_and(|path| {
                let folder = folder(path);
                let tail = format!("packages/{name}");
                folder == tail || folder.ends_with(&format!("/{tail}"))
            })
}

/// A folder the way pub's git source reads it: `./packages/x`, `packages//x/` and
/// `packages/./x` are `packages/x`, and a `..` takes the segment before it away.
#[must_use]
pub fn folder(path: &str) -> String {
    let path = path.trim();
    let mut parts: Vec<&str> = vec![];
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." if parts.last().is_some_and(|last| *last != "..") => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    if path.starts_with('/') {
        format!("/{joined}")
    } else {
        joined
    }
}

/// Whether `path` names the folder `packages/<name>` of a repository ([`folder`] first).
#[must_use]
pub fn in_packages(path: &str, name: &str) -> bool {
    folder(path) == format!("packages/{name}")
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

/// Whether two urls name one repository, however each is spelled: with or without `.git` (in any
/// case) or a final `/`, over `http`, `https`, `ssh://git@host/...` or `git@host:...`, with or
/// without `www.`, a port (`ssh://git@github.com:22/...`) or a user name
/// (`https://user@github.com/...`), in any case. Not what pub reads as one source (two spellings
/// are two sources to it, which [`same_url`] keeps apart): what tells which packages are
/// fespalier's ([`is_ours`], since 0.24.1) and whether fespalier comes from its official repository
/// ([`is_official`]). The host and the path still have to be the same: a fork, another host and a
/// longer name are other repositories.
#[must_use]
pub fn same_repository(a: &str, b: &str) -> bool {
    repository_key(a) == repository_key(b)
}

/// `host/path` of a repository url, lower case, with no scheme, user name, port, `www.`, `.git` or
/// final `/`.
fn repository_key(url: &str) -> String {
    let mut url = url.trim().to_ascii_lowercase();
    // `.git` and `/` in any order and number (`.git/`, `.git.git`).
    loop {
        let trimmed = url.trim_end_matches('/');
        let trimmed = trimmed.strip_suffix(".git").unwrap_or(trimmed);
        if trimmed.len() == url.len() {
            break;
        }
        url.truncate(trimmed.len());
    }
    let rest = match url.split_once("://") {
        Some((_, rest)) => rest.to_string(),
        // `git@host:owner/repo` is `git@host/owner/repo`.
        None => url.replacen(':', "/", 1),
    };
    let (authority, path) = rest.split_once('/').unwrap_or((&rest, ""));
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    let host = match host.rsplit_once(':') {
        Some((host, port)) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => host,
        _ => host,
    };
    let host = host.strip_prefix("www.").unwrap_or(host);
    format!("{host}/{path}")
}

/// Whether `url` names fespalier's own repository ([`REPO_URL`]), however it is spelled
/// ([`same_repository`]): what a note about "a fork" must not say of the official repository
/// (since 0.23.1).
#[must_use]
pub fn is_official(url: &str) -> bool {
    same_repository(url, REPO_URL)
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
            (Some(url), Some(path), Some(reference)) if in_packages(&path, name) => {
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
