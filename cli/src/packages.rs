//! The packages whose files `fsp` reads besides the app's own (since 0.22.0): its `path:`
//! dependencies and theirs, found from the pubspecs alone. Never `.dart_tool/`, the pub cache or
//! `pubspec.lock`, so what `fsp` makes of them is the same before and after `pub get`.
//!
//! The app's pubspec decides every name it lists: `dependencies`, then `dev_dependencies`, then
//! `dependency_overrides`, which win (from `pubspec_overrides.yaml` when that file has the key, as
//! pub reads it). A name it lists with another source (hosted, git, `sdk:`) is not followed, even
//! where a path dependency names it with a `path:`. A path dependency's own `dependencies` with a
//! `path:` (relative to its folder) are followed too, breadth first, the first one for a name
//! winning; its `dev_dependencies` and overrides are not, as pub ignores them. A package is followed
//! only when its folder has a `pubspec.yaml` whose `name:` is the name it is listed under.

use std::collections::{BTreeMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

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
        let overrides_file = yaml(&project.join("pubspec_overrides.yaml"));
        let overrides = overrides_file
            .as_ref()
            .and_then(|o| o.get("dependency_overrides"))
            .or_else(|| pubspec.get("dependency_overrides"));
        // What the app's pubspec says of each name: a folder, or `None` for any other source.
        let mut decided: Vec<(String, Option<PathBuf>)> = vec![];
        for section in [pubspec.get("dependencies"), pubspec.get("dev_dependencies")] {
            for (name, spec) in entries(section) {
                if !decided.iter().any(|(n, _)| *n == name) {
                    decided.push((name, path_of(spec).map(|p| project.join(p))));
                }
            }
        }
        for (name, spec) in entries(overrides) {
            let dir = path_of(spec).map(|p| project.join(p));
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
                    queue.push_back((dep, dir.join(p)));
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
