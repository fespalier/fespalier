//! `ci/web-routes/examples.json` is what `just examples-web` (CI's `examples-web` job) opens in a
//! browser: one entry per Flutter example (the justfile's `examples` list, which is the folders of
//! `examples/` with a `pubspec.yaml`), at least one URL each, and every route that takes no
//! parameter is opened by one of its URLs, or skipped with a reason. A route added to an example
//! fails here until the spec opens it, and a URL that no route answers says why (`notFound` or
//! `handWritten`).

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test helpers: a failed unwrap is a failed test"
)]

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::Value;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn read(rel: &str) -> String {
    let path = root().join(rel);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// The justfile's `examples := "..."` list, in its order.
fn examples() -> Vec<String> {
    read("justfile")
        .lines()
        .find_map(|l| l.strip_prefix("examples := "))
        .expect("the justfile has no `examples := ` line")
        .trim_matches('"')
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

fn spec() -> Value {
    serde_json::from_str(&read("ci/web-routes/examples.json")).expect("examples.json is JSON")
}

/// The Flutter examples on disk: the folders of `examples/` with a `pubspec.yaml` of their own.
/// `examples/cose/server` is a Rust crate inside one of them and `examples/wire-sizes` is Rust
/// only, so neither counts (the justfile's `examples` list leaves them out the same way).
fn example_folders() -> BTreeSet<String> {
    fs::read_dir(root().join("examples"))
        .expect("reading examples/")
        .map(|entry| entry.unwrap())
        .filter(|entry| entry.path().join("pubspec.yaml").is_file())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect()
}

/// What `fsp routes --json` prints for an example: its route patterns, and apart from them the
/// other spellings its `paths` give some of them (`/:lang/produits` for `/:lang/products`).
fn patterns(example: &str) -> (BTreeSet<String>, BTreeSet<String>) {
    let out = Command::new(env!("CARGO_BIN_EXE_fsp"))
        .args(["routes", "--json", "--project"])
        .arg(root().join("examples").join(example))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "fsp routes --json on examples/{example}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let mut patterns = BTreeSet::new();
    let mut spellings = BTreeSet::new();
    for line in String::from_utf8(out.stdout).unwrap().lines() {
        let route: Value = serde_json::from_str(line).unwrap();
        patterns.insert(route["pattern"].as_str().unwrap().to_string());
        for spelling in route["paths"]
            .as_object()
            .into_iter()
            .flat_map(|p| p.values())
        {
            spellings.insert(spelling.as_str().unwrap().to_string());
        }
    }
    (patterns, spellings)
}

/// Whether `path` is answered by `pattern`: `:name` is one segment, `*name` one or more and
/// `*name?` any number (the catch-all is last). Whether a segment parses (an `int`, an enum) is
/// the app's business, so `/items/abc` matches `/items/:id`.
fn matches(pattern: &str, path: &str) -> bool {
    let pattern: Vec<&str> = pattern.split('/').filter(|s| !s.is_empty()).collect();
    let path: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    for (i, segment) in pattern.iter().enumerate() {
        if let Some(name) = segment.strip_prefix('*') {
            return path.len() >= i + usize::from(!name.ends_with('?'));
        }
        if path
            .get(i)
            .is_none_or(|got| !segment.starts_with(':') && got != segment)
        {
            return false;
        }
    }
    path.len() == pattern.len()
}

#[test]
fn the_spec_has_one_entry_per_example() {
    let spec = spec();
    let entries: BTreeSet<String> = spec["examples"]
        .as_object()
        .expect("examples.json has an `examples` object")
        .keys()
        .cloned()
        .collect();
    let listed: BTreeSet<String> = examples().into_iter().collect();
    assert_eq!(
        entries, listed,
        "the entries of ci/web-routes/examples.json (left) and the justfile's `examples` (right) differ"
    );
    assert_eq!(
        example_folders(),
        listed,
        "the Flutter examples in examples/ (left, the folders with a pubspec.yaml) and the justfile's `examples` (right) differ"
    );
}

#[test]
fn the_examples_web_job_runs_every_example() {
    let ci = read(".github/workflows/ci.yml");
    let job = ci
        .split("\n  examples-web:\n")
        .nth(1)
        .expect("ci.yml has no `examples-web` job");
    let matrix: Vec<String> = job
        .lines()
        .skip_while(|l| l.trim() != "example:")
        .skip(1)
        .map_while(|l| l.trim().strip_prefix("- "))
        .map(str::to_string)
        .collect();
    assert_eq!(
        examples(),
        matrix,
        "the justfile's `examples` (left) and the examples-web job's matrix in ci.yml (right) differ"
    );
}

#[test]
fn every_url_says_what_it_shows() {
    let spec = spec();
    for example in examples() {
        let entry = &spec["examples"][&example];
        let urls = entry["urls"]
            .as_array()
            .unwrap_or_else(|| panic!("{example}: no `urls` in examples.json"));
        assert!(
            !urls.is_empty(),
            "{example}: `urls` is empty: an example with no URL checks nothing"
        );
        for url in urls {
            let path = url["path"].as_str().unwrap_or("");
            assert!(
                path.starts_with('/'),
                "{example}: {url} has no `path` starting with `/`"
            );
            let expect = url["expect"].as_str().unwrap_or("");
            assert!(
                !expect.trim().is_empty(),
                "{example}: {url} has no `expect`, the text the page must show"
            );
            for flag in ["notFound", "handWritten"] {
                assert!(
                    url.get(flag).is_none_or(|v| v == &Value::Bool(true)),
                    "{example}: the `{flag}` of {path} is not `true`"
                );
            }
            if let Some(known) = url.get("known") {
                for field in ["problem", "reason"] {
                    assert!(
                        known[field].as_str().is_some_and(|s| !s.trim().is_empty()),
                        "{example}: the `known` of {path} needs a `{field}`: the substring of the problem it expects, \
                         and what is broken with the fix item"
                    );
                }
            }
        }
        for allow in entry["allow"].as_array().into_iter().flatten() {
            let kinds = ["console", "blocked"]
                .iter()
                .filter(|kind| allow[**kind].as_str().is_some_and(|s| !s.is_empty()))
                .count();
            assert_eq!(
                kinds, 1,
                "{example}: {allow} needs exactly one of `console` and `blocked`, a regular expression"
            );
            assert!(
                allow["reason"]
                    .as_str()
                    .is_some_and(|s| !s.trim().is_empty()),
                "{example}: {allow} gives no `reason`"
            );
        }
    }
}

#[test]
fn every_route_without_parameters_is_opened_or_skipped() {
    let spec = spec();
    for example in examples() {
        let entry = &spec["examples"][&example];
        let opened: BTreeSet<&str> = entry["urls"]
            .as_array()
            .unwrap_or_else(|| panic!("{example}: no `urls` in examples.json"))
            .iter()
            .map(|u| u["path"].as_str().unwrap().split('?').next().unwrap())
            .collect();
        let skipped: BTreeMap<&str, &str> = entry["skip"]
            .as_array()
            .map(|s| {
                s.iter()
                    .map(|k| {
                        (
                            k["pattern"].as_str().unwrap(),
                            k["reason"].as_str().unwrap(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        let mount = entry["mount"].as_str().unwrap_or("");

        let (patterns, _) = patterns(&example);
        for pattern in &patterns {
            if pattern.contains(':') || pattern.contains('*') {
                continue;
            }
            let url = match (mount, pattern.as_str()) {
                ("", _) => pattern.clone(),
                (_, "/") => mount.to_string(),
                _ => format!("{mount}{pattern}"),
            };
            assert!(
                opened.contains(url.as_str()) || skipped.contains_key(pattern.as_str()),
                "{example}: the route {pattern} is neither opened by a URL of ci/web-routes/examples.json \
                 ({url}) nor in its `skip` with a reason"
            );
        }
        for (pattern, reason) in skipped {
            assert!(
                patterns.contains(pattern),
                "{example}: `skip` names {pattern}, which is no route of the example"
            );
            assert!(
                !reason.trim().is_empty(),
                "{example}: the skip of {pattern} gives no reason"
            );
        }
    }
}

#[test]
fn every_url_matches_a_route_or_says_why_not() {
    let spec = spec();
    for example in examples() {
        let entry = &spec["examples"][&example];
        let mount = entry["mount"].as_str().unwrap_or("");
        let (patterns, spellings) = patterns(&example);
        for url in entry["urls"].as_array().unwrap() {
            let path = url["path"].as_str().unwrap().split('?').next().unwrap();
            // Under a `mount` only the paths below it are the tree's.
            let inside = match mount {
                "" => Some(path),
                _ if path == mount => Some("/"),
                _ => path
                    .strip_prefix(mount)
                    .filter(|rest| rest.starts_with('/')),
            };
            let routed = inside.is_some_and(|p| {
                patterns
                    .iter()
                    .chain(&spellings)
                    .any(|pattern| matches(pattern, p))
            });
            let explained = ["notFound", "handWritten"]
                .iter()
                .any(|flag| url[*flag] == Value::Bool(true));
            assert!(
                routed || explained,
                "{example}: no route of the example answers {path}: add `\"notFound\": true` to its URL if \
                 the page is the not-found page on purpose, or `\"handWritten\": true` if a route written by \
                 hand outside the tree answers it"
            );
        }
    }
}
