//! Every place that spells out the release version must agree with
//! `cli/Cargo.toml`: the Dart package, the `ref:` that `fsp init` prints, the
//! install instructions in the READMEs, and the `dart run fespalier` launcher
//! (which must read the version from the package, not spell it out).
//!
//! When this fails after a version bump, update the places it names.

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test helpers: a failed unwrap is a failed test"
)]

use std::fs;
use std::path::{Path, PathBuf};

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

/// The value of a top-level `version:` line.
fn pubspec_version(yaml: &str) -> String {
    yaml.lines()
        .find_map(|l| l.strip_prefix("version:"))
        .map(|v| v.trim().trim_matches(['"', '\'']).to_string())
        .expect("no top-level `version:`")
}

/// Every version that follows `marker` (`ref: v`, `--tag v`, ...) in `text`, as `(line, version)`.
fn versions_after(text: &str, marker: &str) -> Vec<(usize, String)> {
    let mut out = vec![];
    for (i, line) in text.lines().enumerate() {
        let mut rest = line;
        while let Some(at) = rest.find(marker) {
            rest = &rest[at + marker.len()..];
            let v: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
                .collect();
            out.push((i + 1, v));
        }
    }
    out
}

#[test]
fn the_dart_package_has_the_cli_version() {
    let cargo = env!("CARGO_PKG_VERSION");
    let pubspec = pubspec_version(&read("packages/fespalier/pubspec.yaml"));
    assert_eq!(
        pubspec, cargo,
        "packages/fespalier/pubspec.yaml `version:` must equal cli/Cargo.toml"
    );
}

#[test]
fn fsp_init_prints_a_ref_for_this_version() {
    let cargo = env!("CARGO_PKG_VERSION");
    let refs = versions_after(&read("cli/src/init.rs"), "ref: v");
    assert!(
        !refs.is_empty(),
        "cli/src/init.rs no longer prints a `ref: v…`; update this test"
    );
    for (line, v) in refs {
        assert_eq!(v, cargo, "cli/src/init.rs:{line}: `ref: v{v}`");
    }
}

#[test]
fn the_readmes_pin_this_version() {
    let cargo = env!("CARGO_PKG_VERSION");
    for file in ["README.md", "packages/fespalier/README.md"] {
        let text = read(file);
        for marker in ["ref: v", "--tag v", "FSP_VERSION=v"] {
            for (line, v) in versions_after(&text, marker) {
                assert_eq!(v, cargo, "{file}:{line}: `{marker}{v}`");
            }
        }
    }
    // The main README documents all three: the git dependency, cargo install, and FSP_VERSION.
    let readme = read("README.md");
    for marker in ["ref: v", "--tag v", "FSP_VERSION=v"] {
        assert!(
            !versions_after(&readme, marker).is_empty(),
            "README.md no longer mentions `{marker}…`; update this test"
        );
    }
}

#[test]
fn the_launcher_reads_its_version_from_the_package() {
    // No release number may be spelled out in code (comments may give examples),
    // so `dart run fespalier` can only ever run the fsp that matches its own pubspec.yaml.
    for file in [
        "packages/fespalier/bin/fespalier.dart",
        "packages/fespalier/lib/src/launcher.dart",
    ] {
        let text = read(file);
        for (i, line) in text.lines().enumerate() {
            let code = line.trim_start();
            if code.starts_with("//") {
                continue;
            }
            let has_version = code
                .split(|c: char| !(c.is_ascii_digit() || c == '.'))
                .any(|w| {
                    w.split('.').count() == 3
                        && w.split('.')
                            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
                });
            assert!(
                !has_version,
                "{file}:{}: a version is spelled out here; read it from pubspec.yaml instead: {line}",
                i + 1
            );
        }
    }
    let launcher = read("packages/fespalier/lib/src/launcher.dart");
    assert!(
        launcher.contains("pubspec.yaml") && launcher.contains("parsePubspecVersion"),
        "the launcher must read pubspec.yaml"
    );
    assert!(
        read("packages/fespalier/bin/fespalier.dart").contains("Launcher.forThisMachine"),
        "bin/fespalier.dart must use the launcher"
    );
}

#[test]
fn the_pinned_checksums_belong_to_this_version() {
    // `release_checksums.dart` is written by the release workflow (scripts/pin_checksums.py). It
    // holds no pins on a development build, and the pins of exactly the package's version once
    // released. After a version bump, reset it: `python3 scripts/pin_checksums.py --reset`.
    let file = "packages/fespalier/lib/src/release_checksums.dart";
    let text = read(file);
    let pinned = text
        .lines()
        .find_map(|l| l.strip_prefix("const pinnedVersion = '"))
        .and_then(|l| l.strip_suffix("';"))
        .unwrap_or_else(|| panic!("{file} has no `const pinnedVersion = '…';` line; it is generated by scripts/pin_checksums.py"));
    let hashes: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter_map(|l| l.strip_prefix('\'')?.strip_suffix("',"))
        .filter(|h| h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()))
        .collect();
    if pinned.is_empty() {
        assert!(
            hashes.is_empty(),
            "{file} has checksums but no pinnedVersion"
        );
        return;
    }
    let pubspec = pubspec_version(&read("packages/fespalier/pubspec.yaml"));
    assert_eq!(
        pinned, pubspec,
        "{file} pins fsp {pinned} but packages/fespalier/pubspec.yaml is at {pubspec}; run `python3 scripts/pin_checksums.py --reset` after a version bump"
    );
    assert_eq!(
        hashes.len(),
        5,
        "{file} must pin the five release targets, found {}",
        hashes.len()
    );
    for h in &hashes {
        assert!(
            h.chars().all(|c| !c.is_ascii_uppercase()),
            "{file}: checksums are lower-case hex: {h}"
        );
    }
}
