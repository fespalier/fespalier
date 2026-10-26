//! The packages whose files `fsp` reads besides the app's own (since 0.22.0): its `path:`
//! dependencies and theirs, found from the pubspecs alone. Never `.dart_tool/`, the pub cache or
//! `pubspec.lock`, so what `fsp` makes of them is the same before and after `pub get`.
//!
//! The app's pubspec decides every name it lists: `dependencies`, then `dev_dependencies`, then
//! `dependency_overrides`, which win (from `pubspec_overrides.yaml` when that file has the key, as
//! pub reads it). So do the overrides of the root of its pub workspace when it says `resolution:
//! workspace` (the root's folder, its `pubspec_overrides.yaml` replacing its section the same way);
//! those written in another member's pubspec are not read, as the members are not looked for. A name
//! it lists with another source (hosted, git, `sdk:`) is not followed, even where a path dependency
//! names it with a `path:`. A path dependency's own `dependencies` with a
//! `path:` (relative to its folder) are followed too, breadth first, the first one for a name
//! winning; its `dev_dependencies` and overrides are not, as pub ignores them. A package is followed
//! only when its folder has a `pubspec.yaml` whose `name:` is the name it is listed under.
//!
//! A `path:` is joined to the folder of the pubspec that lists it and its `.` and `..` are resolved
//! in the text, as pub does (`p.normalize`), never through the file system: `../deep` from a
//! dependency that is a symlink is next to the link, not next to what it points at. The app's own
//! folder is the one `fsp` was given.

use std::collections::{BTreeMap, HashSet, VecDeque};
use std::path::{Component, Path, PathBuf};

use serde_yaml_ng::Value;

/// Name → the package's folder: the folder of the pubspec that lists it joined with its `path:`.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Packages(BTreeMap<String, PathBuf>);

impl Packages {
    /// The path packages of the project at `project`, whose own package is `own`.
    pub fn read(project: &Path, own: Option<&str>) -> Packages {
        let Some(pubspec) = yaml(&project.join("pubspec.yaml")) else {
            return Packages::default();
        };
        // What the app's pubspec says of each name: a folder, or `None` for any other source.
        let mut decided: Vec<(String, Option<PathBuf>)> = vec![];
        for section in [pubspec.get("dependencies"), pubspec.get("dev_dependencies")] {
            for (name, spec) in entries(section) {
                if !decided.iter().any(|(n, _)| *n == name) {
                    decided.push((name, path_of(spec).map(|p| join(project, p))));
                }
            }
        }
        // The overrides replace the source of their name: the workspace root's first, which pub
        // applies to every member, then the app's own (pub refuses a name that both override).
        let root = workspace_root(project, &pubspec);
        let all = root
            .iter()
            .flat_map(|(dir, pubspec)| overrides(dir, pubspec))
            .chain(overrides(project, &pubspec));
        for (name, dir) in all {
            match decided.iter_mut().find(|(n, _)| *n == name) {
                Some(entry) => entry.1 = dir,
                None => decided.push((name, dir)),
            }
        }
        let mut queue: VecDeque<(String, PathBuf)> = decided
            .iter()
            .filter_map(|(n, d)| Some((n.clone(), d.clone()?)))
            .collect();
        let mut seen: HashSet<String> = HashSet::new();
        let mut out = BTreeMap::new();
        while let Some((name, dir)) = queue.pop_front() {
            if Some(name.as_str()) == own || !seen.insert(name.clone()) {
                continue;
            }
            let Some(theirs) = yaml(&dir.join("pubspec.yaml")) else {
                continue;
            };
            if theirs.get("name").and_then(Value::as_str) != Some(name.as_str()) {
                continue;
            }
            for (dep, spec) in entries(theirs.get("dependencies")) {
                if decided.iter().any(|(n, _)| *n == dep) {
                    continue;
                }
                if let Some(p) = path_of(spec) {
                    queue.push_back((dep, join(&dir, p)));
                }
            }
            out.insert(name, dir);
        }
        Packages(out)
    }

    /// The names followed, sorted.
    #[cfg(test)]
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.0.keys().map(String::as_str)
    }

    /// The folder of the path package `name`.
    pub fn root(&self, name: &str) -> Option<&Path> {
        self.0.get(name).map(PathBuf::as_path)
    }
}

/// `base` joined with the `path:` text `rel`, its `.` and `..` resolved in the text, as pub does. A `..`
/// that has nothing to remove stays at the front of a relative path, and `/..` is `/`.
fn join(base: &Path, rel: &str) -> PathBuf {
    let mut out = PathBuf::new();
    for part in base.join(rel).components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => match out.components().next_back() {
                Some(Component::Normal(_)) => {
                    out.pop();
                }
                Some(Component::RootDir | Component::Prefix(_)) => {}
                Some(Component::CurDir | Component::ParentDir) | None => out.push(".."),
            },
            other => out.push(other),
        }
    }
    if out.as_os_str().is_empty() {
        out.push(".");
    }
    out
}

/// The `dependency_overrides` of the package whose pubspec `pubspec` is in `dir`: those of its
/// `pubspec_overrides.yaml` when that file has the key (an empty key: none), as pub reads them, else
/// the pubspec's. Each is a folder (the `path:` joined to `dir`), or `None` for any other source.
fn overrides(dir: &Path, pubspec: &Value) -> Vec<(String, Option<PathBuf>)> {
    let file = yaml(&dir.join("pubspec_overrides.yaml"));
    let section = file
        .as_ref()
        .and_then(|o| o.get("dependency_overrides"))
        .or_else(|| pubspec.get("dependency_overrides"));
    entries(section)
        .into_iter()
        .map(|(name, spec)| (name, path_of(spec).map(|p| join(dir, p))))
        .collect()
}

/// The root of the pub workspace the app belongs to, and its pubspec: for an app that says
/// `resolution: workspace`, the nearest ancestor folder whose pubspec has a `workspace:` key and is
/// not itself a member (a nested workspace has a root above it). The entries of `workspace:` are not
/// matched, so a root that does not list the app is taken all the same (pub refuses that setup).
pub(crate) fn workspace_root(project: &Path, pubspec: &Value) -> Option<(PathBuf, Value)> {
    let member = |p: &Value| p.get("resolution").and_then(Value::as_str) == Some("workspace");
    if !member(pubspec) {
        return None;
    }
    // A relative project has no end to climb to: stop after as many folders as its absolute path has.
    let depth = std::path::absolute(project).ok()?.components().count();
    let mut dir = project.to_path_buf();
    for _ in 0..depth {
        dir = join(&dir, "..");
        if let Some(up) = yaml(&dir.join("pubspec.yaml"))
            && up.get("workspace").is_some()
            && !member(&up)
        {
            return Some((dir, up));
        }
    }
    None
}

/// The file pub reads the overrides of the root of the app's pub workspace from, when the app says
/// `resolution: workspace`: the root's `pubspec_overrides.yaml` when that has the key, else its
/// `pubspec.yaml`. With its path as a person opens it from where `fsp` runs, for a message (the
/// root's folder found from the project's path, so for the app in `apps/shop` it is `pubspec.yaml`
/// from the root of the workspace, `../../pubspec.yaml` from the app and a full path for a full
/// project path), and its text (since 0.24.1; `fsp add` and `fsp upgrade --app` read the root's
/// overrides through this).
pub(crate) fn workspace_overrides_file(
    project: &Path,
    pubspec: &Value,
) -> Option<(String, String)> {
    let (root, _) = workspace_root(project, pubspec)?;
    let shown = |file: &str| join(&root, file).display().to_string();
    let has_key = |text: &str| {
        serde_yaml_ng::from_str::<Value>(text)
            .is_ok_and(|v| v.get("dependency_overrides").is_some())
    };
    if let Ok(text) = std::fs::read_to_string(root.join("pubspec_overrides.yaml"))
        && has_key(&text)
    {
        return Some((shown("pubspec_overrides.yaml"), text));
    }
    let text = std::fs::read_to_string(root.join("pubspec.yaml")).ok()?;
    Some((shown("pubspec.yaml"), text))
}

/// A YAML file, `None` when it is missing or not YAML.
fn yaml(path: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_yaml_ng::from_str(&text).ok()
}

/// The entries of a `dependencies:`-like section, in the file's order.
fn entries(section: Option<&Value>) -> Vec<(String, &Value)> {
    match section {
        Some(Value::Mapping(m)) => m
            .iter()
            .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v)))
            .collect(),
        _ => vec![],
    }
}

/// The `path:` of a dependency, `None` for any other source.
fn path_of(spec: &Value) -> Option<&str> {
    spec.get("path")?.as_str()
}
