//! Every place that spells out the release version must agree with
//! `cli/Cargo.toml`: the Dart package, the release-please manifest, the `ref:` that `fsp init`
//! prints, the install instructions in the READMEs, and the `dart run fespalier` launcher
//! (which must read the version from the package, not spell it out).
//!
//! release-please owns the version. The lines that carry it are annotated (`# ...` in TOML and
//! YAML, `// ...` in Rust, an HTML comment in markdown, or a start/end block around a fenced
//! example; see `release-please-config.json`) and each file is listed there in the object form
//! `{ "type": "generic", "path": ... }`. The release PR bumps every annotated line together. This
//! file checks that nothing was forgotten in either direction, that the readers the release
//! workflows use (`scripts/read-version.sh`) still find each version behind the trailing
//! annotation, and what `release_checksums.dart` may pin in each state of a release.
//!
//! When this fails after a version bump, update the places it names.

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test helpers: a failed unwrap is a failed test"
)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

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

/// The value of a top-level `version:` line, without quotes or a trailing `# comment` (the
/// release-please annotation). The same rule as `scripts/read-version.sh pubspec`,
/// `scripts/pin_checksums.py` and the launcher's `parsePubspecVersion`.
fn pubspec_version(yaml: &str) -> String {
    yaml.lines()
        .find_map(|l| l.strip_prefix("version:"))
        .map(|v| {
            let v = v.trim_start().trim_start_matches(['"', '\'']);
            v.split(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '#'))
                .next()
                .unwrap_or("")
                .to_string()
        })
        .filter(|v| !v.is_empty())
        .expect("no top-level `version:`")
}

#[test]
fn pubspec_version_tolerates_quotes_and_the_release_please_annotation() {
    assert_eq!(pubspec_version("name: x\nversion: 1.2.3\n"), "1.2.3");
    assert_eq!(pubspec_version("version: \"1.2.3\"\n"), "1.2.3");
    assert_eq!(
        pubspec_version("version: '1.2.3-dev.1' # note\n"),
        "1.2.3-dev.1"
    );
    assert_eq!(
        pubspec_version("name: x\nversion: 1.2.3 # x-release-please-version\n"),
        "1.2.3"
    );
    assert_eq!(pubspec_version("version: 1.2.3 #x\n"), "1.2.3");
}

/// `major.minor.patch` of a version, ignoring a pre-release suffix.
fn triple(version: &str) -> (u64, u64, u64) {
    let core = version.split(['-', '+']).next().unwrap();
    let mut parts = core.split('.').map(|p| {
        p.parse::<u64>()
            .unwrap_or_else(|_| panic!("not a version: {version}"))
    });
    (
        parts.next().unwrap(),
        parts.next().unwrap(),
        parts.next().unwrap(),
    )
}

fn looks_like_a_version(word: &str) -> bool {
    word.split('.').count() == 3
        && word
            .split('.')
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

fn has_a_version(line: &str) -> bool {
    line.split(|c: char| !(c.is_ascii_digit() || c == '.'))
        .any(looks_like_a_version)
}

/// The 1-based lines that release-please's `Generic` updater rewrites: a line carrying the
/// inline annotation, and every line from a start marker to the end marker.
fn annotated_lines(text: &str) -> Vec<usize> {
    let mut out = vec![];
    let mut in_block = false;
    for (i, line) in text.lines().enumerate() {
        if line.contains("x-release-please-version") {
            out.push(i + 1);
        } else if in_block {
            out.push(i + 1);
            if line.contains("x-release-please-end") {
                in_block = false;
            }
        } else if line.trim_start().starts_with("<!--")
            && line.contains("x-release-please-start-version")
        {
            in_block = true;
        }
    }
    out
}

#[test]
fn annotated_lines_follow_the_generic_updaters_rules() {
    let text = "a 1.0.0\nb 1.0.0 # x-release-please-version\n<!-- x-release-please-start-version -->\n```\nref: v1.0.0\n```\n<!-- x-release-please-end -->\nc 1.0.0\n";
    assert_eq!(annotated_lines(text), vec![2, 4, 5, 6, 7]);
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

const MARKERS: [&str; 3] = ["ref: v", "--tag v", "FSP_VERSION=v"];

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
fn the_devtools_extension_has_the_cli_version() {
    // `config.yaml` is what DevTools shows as the extension's version. It is release-please's like
    // the pubspec's, so it is annotated, and listed in release-please-config.json (checked below).
    let cargo = env!("CARGO_PKG_VERSION");
    let config = read("packages/fespalier/extension/devtools/config.yaml");
    assert_eq!(
        pubspec_version(&config),
        cargo,
        "packages/fespalier/extension/devtools/config.yaml `version:` must equal cli/Cargo.toml"
    );
    let line = config
        .lines()
        .position(|l| l.starts_with("version:"))
        .expect("config.yaml has a version")
        + 1;
    assert!(
        annotated_lines(&config).contains(&line),
        "packages/fespalier/extension/devtools/config.yaml:{line}: the version is not annotated"
    );
}

#[test]
fn the_release_please_manifest_has_the_cli_version() {
    let cargo = env!("CARGO_PKG_VERSION");
    let manifest: serde_json::Value =
        serde_json::from_str(&read(".release-please-manifest.json")).expect("manifest is JSON");
    assert_eq!(
        manifest["."], cargo,
        ".release-please-manifest.json must equal cli/Cargo.toml (release-please owns it; never hand-edit)"
    );
}

#[test]
fn the_release_workflows_extractions_find_every_version() {
    // `release.yml`, `release-pins.yml` and the pin job read the versions with
    // scripts/read-version.sh. Run exactly that, so the PR-time check and the tag-time guard
    // cannot drift apart (an end-anchored sed once read an annotated line as empty and
    // published nothing: org releasing.md, trap 6).
    let cargo = env!("CARGO_PKG_VERSION");
    for what in ["cargo", "pubspec", "manifest", "lock"] {
        let out = match Command::new("bash")
            .arg(root().join("scripts/read-version.sh"))
            .arg(what)
            .output()
        {
            Ok(out) => out,
            Err(e) => {
                eprintln!(
                    "skipping: no bash to run scripts/read-version.sh ({e}); CI runs it on Linux"
                );
                return;
            }
        };
        assert!(
            out.status.success(),
            "read-version.sh {what} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            cargo,
            "read-version.sh {what}"
        );
    }
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
        for marker in MARKERS {
            for (line, v) in versions_after(&text, marker) {
                assert_eq!(v, cargo, "{file}:{line}: `{marker}{v}`");
            }
        }
    }
    // The main README documents all three: the git dependency, cargo install, and FSP_VERSION.
    let readme = read("README.md");
    for marker in MARKERS {
        assert!(
            !versions_after(&readme, marker).is_empty(),
            "README.md no longer mentions `{marker}…`; update this test"
        );
    }
}

#[test]
fn every_spelled_out_version_is_annotated_for_release_please() {
    // A version on a line release-please does not rewrite simply never moves, and nothing
    // reports it (org releasing.md, trap 3). The tests above would catch it, but only on the
    // release PR, after the fact; this names the cause.
    for file in [
        "cli/src/init.rs",
        "README.md",
        "packages/fespalier/README.md",
        // the agent skills' install pins (skills/README.md, "Versions")
        "skills/fespalier/SKILL.md",
        "skills/fespalier-migration/references/go-router-adoption.md",
    ] {
        let text = read(file);
        let annotated = annotated_lines(&text);
        for marker in MARKERS {
            for (line, v) in versions_after(&text, marker) {
                assert!(
                    annotated.contains(&line),
                    "{file}:{line}: `{marker}{v}` is not annotated, so release-please would leave it behind"
                );
            }
        }
    }
    let cargo = read("cli/Cargo.toml");
    let line = cargo
        .lines()
        .position(|l| l.starts_with("version"))
        .expect("cli/Cargo.toml has a version")
        + 1;
    assert!(
        annotated_lines(&cargo).contains(&line),
        "cli/Cargo.toml:{line}: the package version is not annotated"
    );
    let pubspec = read("packages/fespalier/pubspec.yaml");
    let line = pubspec
        .lines()
        .position(|l| l.starts_with("version:"))
        .expect("the pubspec has a version")
        + 1;
    assert!(
        annotated_lines(&pubspec).contains(&line),
        "packages/fespalier/pubspec.yaml:{line}: the version is not annotated"
    );
}

/// Files under the repository that carry an annotation, for the listing check below.
fn annotated_files(dir: &Path, out: &mut Vec<String>) {
    const SKIP: [&str; 10] = [
        "target",
        ".git",
        "node_modules",
        "build",
        ".dart_tool",
        ".gradle",
        ".idea",
        ".claude",
        ".github",
        "scripts",
    ];
    for entry in fs::read_dir(dir).unwrap().flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            if !SKIP.contains(&name.as_str()) {
                annotated_files(&path, out);
            }
            continue;
        }
        let rel = path
            .strip_prefix(root())
            .unwrap()
            .to_string_lossy()
            .replace('\\', "/");
        // this file spells the markers out as test data; the changelog is release-please's own
        if rel == "cli/tests/versions.rs" || rel == "CHANGELOG.md" {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        let annotated = annotated_lines(&text);
        let carries = text.lines().enumerate().any(|(i, l)| {
            annotated.contains(&(i + 1))
                && (has_a_version(l) || l.contains("x-release-please-start-version"))
        });
        if carries {
            out.push(rel);
        }
    }
}

#[test]
fn release_please_config_lists_exactly_the_annotated_files() {
    let config: serde_json::Value =
        serde_json::from_str(&read("release-please-config.json")).expect("config is JSON");
    let package = &config["packages"]["."];
    // The org shape (vaam-apps/.github docs/releasing.md): `simple` derives no component, which
    // is what lets release-please tag its own merged PR (trap 10); the tag is `vX.Y.Z` (the
    // release workflow and the launcher's download URLs depend on it).
    assert_eq!(package["release-type"], "simple");
    assert_eq!(package["include-component-in-tag"], false);
    assert_eq!(package["include-v-in-tag"], true);
    // release.yml attaches the staged binaries to the release release-please creates, then
    // publishes it: that needs a draft, and a tag release-please creates itself (GitHub makes
    // none for a draft), which is also what starts release.yml.
    assert_eq!(package["draft"], true);
    assert_eq!(package["force-tag-creation"], true);

    let mut listed = vec![];
    for entry in package["extra-files"].as_array().expect("extra-files") {
        // A bare string infers an updater from the extension; for yaml that is GenericYaml,
        // which reserialises the whole document (trap 2). Object form only.
        let object = entry.as_object().unwrap_or_else(|| {
            panic!(
                "extra-files entry {entry} must be an object {{\"type\": \"generic\", \"path\": …}}"
            )
        });
        assert_eq!(object["type"], "generic", "{entry}");
        let path = object["path"].as_str().expect("path").to_string();
        let text = read(&path);
        assert!(
            !annotated_lines(&text).is_empty(),
            "{path} is listed in extra-files but has no annotation left, so release-please would change nothing in it"
        );
        listed.push(path);
    }
    listed.sort();

    let mut found = vec![];
    annotated_files(&root(), &mut found);
    found.sort();
    assert_eq!(
        found, listed,
        "files that carry an annotation (left) vs release-please-config.json extra-files (right)"
    );
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
            assert!(
                !has_a_version(line),
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
fn the_pinned_checksums_are_none_or_belong_to_a_version_up_to_this_one() {
    // `release_checksums.dart` is written by the `release-pins` workflow (scripts/pin_checksums.py)
    // onto the release-please PR branch. Whatever state `main` or a release PR is in, the pins
    // are for a version that exists; they are never for a version ahead of the package:
    //
    //   main between releases      pubspec 0.4.0, pins 0.4.0   (the last release's own pins)
    //   release PR, before pin     pubspec 0.4.1, pins 0.4.0   (release-please bumped the
    //                                                          pubspec; nothing is built yet)
    //   release PR, after pin      pubspec 0.4.1, pins 0.4.1
    //   merged                     pubspec 0.4.1, pins 0.4.1   (and the tag is this commit)
    //
    // A package whose version has no pins is a development build: the launcher falls back to
    // the release's `.sha256` with a warning, so stale pins are safe, just unused. That the
    // pins match the published binaries exactly is checked where it can be: by `release-pins`
    // on the PR (verify mode) and by `release.yml` on the tag, before it attaches anything
    // (`scripts/pin_checksums.py --check`).
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
    assert!(
        triple(pinned) <= triple(&pubspec),
        "{file} pins fsp {pinned}, a version ahead of packages/fespalier/pubspec.yaml ({pubspec}); pins are written by the release-pins workflow, never by hand"
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
