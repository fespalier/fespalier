//! `ci/web-routes/examples.json` is what `just examples-web` (CI's `examples-web` job) opens in a
//! browser: one entry per example of the justfile's `examples` list, and every route that takes
//! no parameter is opened by one of its URLs, or skipped with a reason. A route added to an
//! example fails here until the spec opens it.

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
fn every_route_without_parameters_is_opened_or_skipped() {
    let spec = spec();
    for example in examples() {
        let entry = &spec["examples"][&example];
        let urls = entry["urls"]
            .as_array()
            .unwrap_or_else(|| panic!("{example}: no `urls` in examples.json"));
        for url in urls {
            let expect = url["expect"].as_str().unwrap_or("");
            assert!(
                !expect.trim().is_empty(),
                "{example}: {url} has no `expect`, the text the page must show"
            );
        }
        let opened: BTreeSet<&str> = urls
            .iter()
            .map(|u| u["path"].as_str().unwrap().split('?').next().unwrap())
            .collect();
        let skipped: BTreeMap<&str, &str> = entry["skip"]
            .as_array()
            .map(|s| {
                s.iter()
                    .map(|k| (k["pattern"].as_str().unwrap(), k["reason"].as_str().unwrap()))
                    .collect()
            })
            .unwrap_or_default();
        let mount = entry["mount"].as_str().unwrap_or("");

        let out = Command::new(env!("CARGO_BIN_EXE_fsp"))
            .args(["routes", "--json", "--project"])
            .arg(root().join("examples").join(&example))
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "fsp routes --json on examples/{example}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let mut patterns = BTreeSet::new();
        for line in String::from_utf8(out.stdout).unwrap().lines() {
            let route: Value = serde_json::from_str(line).unwrap();
            let pattern = route["pattern"].as_str().unwrap().to_string();
            patterns.insert(pattern.clone());
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
