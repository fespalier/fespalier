//! Every place that spells out the release version must agree with
//! `cli/Cargo.toml`: the Dart package, the release-please manifest, the `ref:` that `fsp init`
//! prints, the install instructions in the READMEs and the docs pages (`docs/*.md`), and the
//! `dart run fespalier` launcher (which must read the version from the package, not spell it
//! out).
//!
//! release-please owns the version. The lines that carry it are annotated (`# ...` in TOML and
//! YAML, `// ...` in Rust, an HTML comment in markdown, or a start/end block around a fenced
//! example; see `release-please-config.json`) and each file is listed there in the object form
//! `{ "type": "generic", "path": ... }`. The release PR bumps every annotated line together. This
//! file checks that nothing was forgotten in either direction, that the readers the release
//! workflows use (`scripts/read-version.sh`) still find each version behind the trailing
//! annotation, that nothing release-please rewrites is anyone else's version (a third-party
//! range inside an annotated region would be replaced by ours), and what `release_checksums.dart`
//! may pin in each state of a release.
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

/// The documentation pages under `docs/` (`docs/*.md`, as repo-relative paths, sorted), so a
/// page added later is read by the README checks below without anyone listing it.
fn doc_pages() -> Vec<String> {
    let mut pages: Vec<String> = fs::read_dir(root().join("docs"))
        .expect("docs/ exists")
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| {
            Path::new(name)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("md"))
        })
        .map(|name| format!("docs/{name}"))
        .collect();
    pages.sort();
    assert!(!pages.is_empty(), "docs/ holds no pages");
    pages
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

/// The first `major.minor.patch` on `line` and where it starts: the one release-please's
/// `Generic` updater replaces.
fn first_version(line: &str) -> Option<(usize, &str)> {
    let bytes = line.as_bytes();
    let is_part = |b: u8| b.is_ascii_digit() || b == b'.';
    let mut at = 0;
    while at < bytes.len() {
        if !is_part(bytes[at]) {
            at += 1;
            continue;
        }
        let end = (at..bytes.len())
            .find(|&i| !is_part(bytes[i]))
            .unwrap_or(bytes.len());
        if looks_like_a_version(&line[at..end]) {
            return Some((at, &line[at..end]));
        }
        at = end;
    }
    None
}

fn has_a_version(line: &str) -> bool {
    first_version(line).is_some()
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

/// What may stand right before the version release-please replaces on an annotated line: fespalier's
/// own `ref:` or tag, or the assignment of a `version`.
const OWN_VERSION_PREFIXES: [&str; 6] = [
    "ref: v",
    "--tag v",
    "FSP_VERSION=v",
    "version: ",
    "version = \"",
    "fespalierVersion = '",
];

/// The annotated lines whose first version is not fespalier's own, as `(line, text)`. The updater
/// replaces the first `major.minor.patch` on every line it reaches, whatever that number belongs
/// to, so a dependency's range on such a line is overwritten by the release's version. The shape
/// is what tells them apart, never the value: once overwritten, the range holds the release's own
/// number.
fn foreign_versions(text: &str) -> Vec<(usize, String)> {
    let annotated = annotated_lines(text);
    text.lines()
        .enumerate()
        .filter(|(i, _)| annotated.contains(&(i + 1)))
        .filter_map(|(i, line)| {
            let (at, _) = first_version(line)?;
            let before = &line[..at];
            let own = OWN_VERSION_PREFIXES.iter().any(|p| before.ends_with(p));
            (!own).then(|| (i + 1, line.trim().to_string()))
        })
        .collect()
}

#[test]
fn a_third_party_range_in_an_annotated_region_is_found() {
    // Line 6 is `sentry_flutter` as written, 7 is what release-please made of it in 0.9.0 (the
    // release's own number, so no comparison of values sees it) and 12 is a range on a line with
    // the inline annotation. The same range outside any annotated region (1 and 10) is left alone.
    let text = "needs 9.26.0\n<!-- x-release-please-start-version -->\n```yaml\n  fespalier:\n      ref: v1.0.0\n  sentry_flutter: \">=9.26.0 <10.0.0\"\n  sentry_flutter: \">=1.0.0 <10.0.0\"\n```\n<!-- x-release-please-end -->\nsentry_flutter: \">=9.26.0 <10.0.0\"\nversion: 1.0.0 # x-release-please-version\nother: \">=2.0.0 <3.0.0\" # x-release-please-version\n";
    let lines: Vec<usize> = foreign_versions(text)
        .iter()
        .map(|(line, _)| *line)
        .collect();
    assert_eq!(lines, vec![6, 7, 12]);
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
fn the_runtime_knows_its_version() {
    // `fespalierVersion` is what the telemetry adapter reports as `fespalier.version`. It is
    // release-please's like the pubspec's, so it is annotated and listed in the config.
    let cargo = env!("CARGO_PKG_VERSION");
    let file = "packages/fespalier/lib/src/version.dart";
    let text = read(file);
    let (i, line) = text
        .lines()
        .enumerate()
        .find(|(_, l)| l.starts_with("const String fespalierVersion = '"))
        .unwrap_or_else(|| panic!("{file} has no `const String fespalierVersion = '…';` line"));
    let value = line
        .trim_start_matches("const String fespalierVersion = '")
        .split('\'')
        .next()
        .unwrap();
    assert_eq!(value, cargo, "{file}:{} must equal cli/Cargo.toml", i + 1);
    assert!(
        annotated_lines(&text).contains(&(i + 1)),
        "{file}:{}: the version is not annotated",
        i + 1
    );
}

/// The companion packages that are released with fespalier (the OpenTelemetry adapter, and the
/// ones that follow it): each has the version of the CLI and pins fespalier by a `ref: v…`.
const COMPANIONS: [&str; 27] = [
    "packages/fespalier_otel/pubspec.yaml",
    "packages/fespalier_transport/pubspec.yaml",
    "packages/fespalier_auth/pubspec.yaml",
    "packages/fespalier_oidc/pubspec.yaml",
    "packages/fespalier_keypair/pubspec.yaml",
    "packages/fespalier_keypair_dpop/pubspec.yaml",
    "packages/fespalier_sign_keypair/pubspec.yaml",
    "packages/fespalier_adaptive/pubspec.yaml",
    "packages/fespalier_flags/pubspec.yaml",
    "packages/fespalier_storage/pubspec.yaml",
    "packages/fespalier_connectivity/pubspec.yaml",
    "packages/fespalier_image/pubspec.yaml",
    "packages/fespalier_http/pubspec.yaml",
    "packages/fespalier_dio/pubspec.yaml",
    "packages/fespalier_cratestack/pubspec.yaml",
    "packages/fespalier_sentry/pubspec.yaml",
    "packages/fespalier_tolgee/pubspec.yaml",
    "packages/fespalier_forms/pubspec.yaml",
    "packages/fespalier_maps/pubspec.yaml",
    "packages/fespalier_download/pubspec.yaml",
    "packages/fespalier_download_background/pubspec.yaml",
    "packages/fespalier_push/pubspec.yaml",
    "packages/fespalier_biometrics/pubspec.yaml",
    "packages/fespalier_analytics/pubspec.yaml",
    "packages/fespalier_frb/pubspec.yaml",
    "packages/fespalier_riverpod/pubspec.yaml",
    "packages/fespalier_launch/pubspec.yaml",
];

#[test]
fn the_companion_packages_have_the_cli_version() {
    // A companion is released with fespalier: its own version, and the tag of the fespalier it
    // depends on (the same repository dependency an app writes, so the two resolve to one package).
    // A dependency that is not on pub.dev and is not fespalier's (a package pinned by commit) must
    // never be written as `ref: v…`: every one in these files is read as fespalier's own version.
    let cargo = env!("CARGO_PKG_VERSION");
    for file in COMPANIONS {
        let text = read(file);
        assert_eq!(
            pubspec_version(&text),
            cargo,
            "{file} `version:` must equal cli/Cargo.toml"
        );
        let annotated = annotated_lines(&text);
        let version_line = text
            .lines()
            .position(|l| l.starts_with("version:"))
            .unwrap_or_else(|| panic!("{file} has a version"))
            + 1;
        assert!(
            annotated.contains(&version_line),
            "{file}:{version_line}: the version is not annotated"
        );
        let refs = versions_after(&text, "ref: v");
        // fespalier_transport depends on nothing at all, on purpose (its own test checks it), so
        // it pins nothing; fespalier_keypair depends on no other fespalier package either (it has
        // no auth concept), only on flutter-sign-keypair, pinned by commit.
        assert!(
            !refs.is_empty()
                || file.contains("fespalier_transport")
                || file.contains("fespalier_keypair/"),
            "{file} no longer pins fespalier with a `ref: v…`"
        );
        for (line, v) in refs {
            assert_eq!(v, cargo, "{file}:{line}: `ref: v{v}`");
            assert!(
                annotated.contains(&line),
                "{file}:{line}: the ref is not annotated"
            );
        }
    }
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
    let mut files: Vec<String> = [
        "README.md",
        "packages/fespalier/README.md",
        "packages/fespalier_otel/README.md",
        "packages/fespalier_transport/README.md",
        "packages/fespalier_auth/README.md",
        "packages/fespalier_oidc/README.md",
        "packages/fespalier_keypair/README.md",
        "packages/fespalier_keypair_dpop/README.md",
        "packages/fespalier_sign_keypair/README.md",
        "packages/fespalier_adaptive/README.md",
        "packages/fespalier_flags/README.md",
        "packages/fespalier_storage/README.md",
        "packages/fespalier_connectivity/README.md",
        "packages/fespalier_image/README.md",
        "packages/fespalier_http/README.md",
        "packages/fespalier_dio/README.md",
        "packages/fespalier_cratestack/README.md",
        "packages/fespalier_sentry/README.md",
        "packages/fespalier_tolgee/README.md",
        "packages/fespalier_forms/README.md",
        "packages/fespalier_maps/README.md",
        "packages/fespalier_download/README.md",
        "packages/fespalier_download_background/README.md",
        "packages/fespalier_push/README.md",
        "packages/fespalier_biometrics/README.md",
        "packages/fespalier_analytics/README.md",
        "packages/fespalier_frb/README.md",
        "packages/fespalier_riverpod/README.md",
        "packages/fespalier_launch/README.md",
    ]
    .map(String::from)
    .to_vec();
    files.extend(doc_pages());
    for file in &files {
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
    let mut files: Vec<String> = [
        "cli/src/init.rs",
        "README.md",
        "packages/fespalier/README.md",
        "packages/fespalier_otel/pubspec.yaml",
        "packages/fespalier_otel/README.md",
        "packages/fespalier_transport/pubspec.yaml",
        "packages/fespalier_transport/README.md",
        "packages/fespalier_auth/pubspec.yaml",
        "packages/fespalier_auth/README.md",
        "packages/fespalier_oidc/pubspec.yaml",
        "packages/fespalier_oidc/README.md",
        "packages/fespalier_keypair/pubspec.yaml",
        "packages/fespalier_keypair/README.md",
        "packages/fespalier_keypair_dpop/pubspec.yaml",
        "packages/fespalier_keypair_dpop/README.md",
        "packages/fespalier_sign_keypair/pubspec.yaml",
        "packages/fespalier_sign_keypair/README.md",
        "packages/fespalier_adaptive/pubspec.yaml",
        "packages/fespalier_adaptive/README.md",
        "packages/fespalier_flags/pubspec.yaml",
        "packages/fespalier_flags/README.md",
        "packages/fespalier_storage/pubspec.yaml",
        "packages/fespalier_storage/README.md",
        "packages/fespalier_connectivity/pubspec.yaml",
        "packages/fespalier_connectivity/README.md",
        "packages/fespalier_image/pubspec.yaml",
        "packages/fespalier_image/README.md",
        "packages/fespalier_http/pubspec.yaml",
        "packages/fespalier_http/README.md",
        "packages/fespalier_dio/pubspec.yaml",
        "packages/fespalier_dio/README.md",
        "packages/fespalier_cratestack/pubspec.yaml",
        "packages/fespalier_cratestack/README.md",
        "packages/fespalier_sentry/pubspec.yaml",
        "packages/fespalier_sentry/README.md",
        "packages/fespalier_tolgee/pubspec.yaml",
        "packages/fespalier_tolgee/README.md",
        "packages/fespalier_forms/pubspec.yaml",
        "packages/fespalier_forms/README.md",
        "packages/fespalier_maps/pubspec.yaml",
        "packages/fespalier_maps/README.md",
        "packages/fespalier_download/pubspec.yaml",
        "packages/fespalier_download/README.md",
        "packages/fespalier_download_background/pubspec.yaml",
        "packages/fespalier_download_background/README.md",
        "packages/fespalier_push/pubspec.yaml",
        "packages/fespalier_analytics/pubspec.yaml",
        "packages/fespalier_push/README.md",
        "packages/fespalier_biometrics/pubspec.yaml",
        "packages/fespalier_biometrics/README.md",
        "packages/fespalier_analytics/README.md",
        "packages/fespalier_frb/pubspec.yaml",
        "packages/fespalier_frb/README.md",
        "packages/fespalier_riverpod/pubspec.yaml",
        "packages/fespalier_riverpod/README.md",
        "packages/fespalier_launch/pubspec.yaml",
        "packages/fespalier_launch/README.md",
        // the agent skills' install pins (skills/README.md, "Versions")
        "skills/fespalier/SKILL.md",
        "skills/fespalier-migration/references/go-router-adoption.md",
    ]
    .map(String::from)
    .to_vec();
    files.extend(doc_pages());
    for file in &files {
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
fn release_please_rewrites_only_fespaliers_versions() {
    // The `Generic` updater replaces the first `major.minor.patch` on each line from a start
    // marker to the end marker and on each line with the inline annotation, with no way to tell
    // whose it is. A third-party range there is overwritten at the next release: 0.9.0 turned
    // the READMEs' `sentry_flutter: ">=9.26.0 <10.0.0"` into `">=0.9.0 <10.0.0"`, and 0.9.1 into
    // `">=0.9.1 <10.0.0"`. The tests above never saw it: they read only the versions behind
    // `ref: v`, `--tag v` and `FSP_VERSION=v`, and a range already holding the release's number
    // equals it. So every line the updater reaches must carry fespalier's own version.
    let config: serde_json::Value =
        serde_json::from_str(&read("release-please-config.json")).expect("config is JSON");
    let mut rewritten = vec![];
    for entry in config["packages"]["."]["extra-files"]
        .as_array()
        .expect("extra-files")
    {
        let path = entry["path"].as_str().expect("path");
        for (line, text) in foreign_versions(&read(path)) {
            rewritten.push(format!("{path}:{line}: {text}"));
        }
    }
    assert!(
        rewritten.is_empty(),
        "release-please would overwrite a version that is not fespalier's:\n{}\nKeep a \
         dependency's range outside a start/end block and off a line with the annotation (in \
         prose, or after the block's end marker); a new shape of fespalier's own goes in \
         OWN_VERSION_PREFIXES",
        rewritten.join("\n")
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

/// The value of the `FLUTTER_VERSION:` line of a workflow's top-level `env:`.
fn flutter_version(workflow: &str) -> String {
    let text = read(workflow);
    text.lines()
        .find_map(|l| l.trim().strip_prefix("FLUTTER_VERSION:"))
        .map(|v| v.split('#').next().unwrap_or("").trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| panic!("{workflow} has no `FLUTTER_VERSION:` line"))
}

#[test]
fn the_weekly_maestro_workflow_builds_with_the_flutter_of_ci() {
    // `maestro-web.yml` builds the same web app as ci.yml's `web-routes` job: a Flutter bump in
    // one file only would make the weekly run test something CI does not.
    assert_eq!(
        flutter_version(".github/workflows/maestro-web.yml"),
        flutter_version(".github/workflows/ci.yml"),
        "FLUTTER_VERSION differs between maestro-web.yml (left) and ci.yml (right)"
    );
}

#[test]
fn the_post_publish_smoke_runs_the_flutter_of_ci() {
    // `post-publish-smoke.yml` checks the app `fsp create` makes on the Flutter that CI tests it on.
    assert_eq!(
        flutter_version(".github/workflows/post-publish-smoke.yml"),
        flutter_version(".github/workflows/ci.yml"),
        "FLUTTER_VERSION differs between post-publish-smoke.yml (left) and ci.yml (right)"
    );
}

/// The `dir:` entries of the matrix of one ci.yml job, in order.
fn job_matrix(ci: &str, job: &str) -> Vec<String> {
    let body = ci
        .split_once(&format!("\n  {job}:\n"))
        .unwrap_or_else(|| panic!("ci.yml has no `{job}` job"))
        .1;
    let dirs = body
        .split_once("\n        dir:\n")
        .unwrap_or_else(|| panic!("the {job} job has no `dir:` matrix"))
        .1;
    dirs.lines()
        .map_while(|l| l.trim().strip_prefix("- "))
        .map(str::to_string)
        .collect()
}

/// The text of one ci.yml job: from its `  <job>:` key to the next job key (a line indented two spaces that is
/// neither blank nor a comment), so a job added after it is not read as part of it.
fn job_text<'a>(ci: &'a str, job: &str) -> &'a str {
    let body = ci
        .split_once(&format!("\n  {job}:\n"))
        .unwrap_or_else(|| panic!("ci.yml has no `{job}` job"))
        .1;
    let mut len = 0;
    for line in body.split_inclusive('\n') {
        let indent = line.len() - line.trim_start_matches(' ').len();
        let is_key = !line.trim().is_empty() && !line.trim_start().starts_with('#');
        if is_key && indent < 4 {
            break;
        }
        len += line.len();
    }
    &body[..len]
}

/// ci.yml parsed as YAML.
fn ci_yaml() -> serde_yaml_ng::Value {
    serde_yaml_ng::from_str(&read(".github/workflows/ci.yml")).expect("ci.yml is YAML")
}

/// The steps of one ci.yml job, parsed.
fn ci_steps(ci: &serde_yaml_ng::Value, job: &str) -> Vec<serde_yaml_ng::Value> {
    ci["jobs"][job]["steps"]
        .as_sequence()
        .unwrap_or_else(|| panic!("ci.yml: jobs.{job} has no `steps:`"))
        .clone()
}

/// The index of the one step of a job that runs exactly `run` in the folder `dir` (None: no `working-directory`).
fn step_running(steps: &[serde_yaml_ng::Value], job: &str, run: &str, dir: Option<&str>) -> usize {
    let found: Vec<usize> = steps
        .iter()
        .enumerate()
        .filter(|(_, s)| {
            s["run"].as_str().map(str::trim) == Some(run) && s["working-directory"].as_str() == dir
        })
        .map(|(i, _)| i)
        .collect();
    assert_eq!(
        found.len(),
        1,
        "ci.yml: jobs.{job} must have exactly one step that runs `{run}` (in {dir:?}); it has {}",
        found.len()
    );
    found[0]
}

/// What an app's steps are in the `floor` job (one package alone) and the `floor-app` job (all of them):
/// the same five steps, in this order, in the app's folder. `write` is the step that writes the app.
struct AppSteps<'a> {
    job: &'a str,
    dir: &'a str,
    /// The `if:` every one of the steps has, if any.
    condition: Option<&'a str>,
    /// The `env:` of the `--plugins` step.
    plugins_env: &'a [(&'a str, &'a str)],
    plugins: &'a str,
}

impl AppSteps<'_> {
    fn check(&self, steps: &[serde_yaml_ng::Value], after: usize) {
        let job = self.job;
        let order: Vec<(usize, &str)> = [
            ("flutter pub downgrade", "downgrades the app"),
            ("flutter pub get", "writes the plugin list"),
            (self.plugins, "writes the plugins' test"),
            ("flutter test", "tests the app"),
            (
                "python3 \"$GITHUB_WORKSPACE/scripts/floor_app.py\" --web .",
                "builds the app for the web",
            ),
        ]
        .into_iter()
        .map(|(run, what)| (step_running(steps, job, run, Some(self.dir)), what))
        .collect();
        let mut previous = after;
        for (index, what) in &order {
            let step = &steps[*index];
            assert!(
                *index > previous,
                "ci.yml: jobs.{job}: the step that {what} comes out of order"
            );
            previous = *index;
            assert_eq!(
                step.get("if").and_then(serde_yaml_ng::Value::as_str),
                self.condition,
                "ci.yml: jobs.{job}: the step that {what} has the job's condition"
            );
            assert!(
                step.get("continue-on-error").is_none(),
                "ci.yml: jobs.{job}: the step that {what} cannot fail without failing the job"
            );
        }
        let plugins = &steps[order[2].0];
        for (key, value) in self.plugins_env {
            assert_eq!(
                plugins["env"][*key].as_str(),
                Some(*value),
                "ci.yml: jobs.{job}: the plugins step's env {key}"
            );
        }
        // The web build must not skip: FSP_REQUIRE_WEB=1 turns the no-web-support skip into a failure.
        assert_eq!(
            steps[order[4].0]["env"]["FSP_REQUIRE_WEB"].as_str(),
            Some("1"),
            "ci.yml: jobs.{job}: the web build sets FSP_REQUIRE_WEB=1, or it skips instead of failing"
        );
    }
}

/// The Flutter the floor job installs, as `ci.yml` spells it (`FLUTTER_FLOOR_VERSION:`, a
/// `major.minor.patch`): the one place the floor is written for CI, and what the packages that claim
/// it are matched against.
fn floor_version(ci: &str) -> String {
    ci.lines()
        .find_map(|l| l.trim().strip_prefix("FLUTTER_FLOOR_VERSION:"))
        .map(|v| v.split('#').next().unwrap_or("").trim().to_string())
        .filter(|v| !v.is_empty())
        .expect("ci.yml has no `FLUTTER_FLOOR_VERSION:` line")
}

/// The `(major, minor)` of the floor in `ci.yml`.
fn floor_minor(ci: &str) -> (u64, u64) {
    let floor = floor_version(ci);
    assert!(
        looks_like_a_version(&floor),
        "FLUTTER_FLOOR_VERSION is `{floor}`, not major.minor.patch"
    );
    let (major, minor, _) = triple(&floor);
    (major, minor)
}

/// The `(major, minor)` of the lower bound of `environment.flutter` in `<dir>/pubspec.yaml`, or
/// `None` when it states none. See `flutter_claim_in`.
fn flutter_claim(dir: &str) -> Option<(u64, u64)> {
    flutter_claim_in(&format!("{dir}/pubspec.yaml"), &pubspec_of(dir))
}

/// The same for a parsed pubspec, named `file` in a failure. The claim is parsed, not matched as text,
/// so a quoting style (`'>=3.35.0'`) does not hide a package from the workspace and the floor. The one
/// spelling read is `">=X.Y.Z"` (what every package writes): any other (`^3.35.0`, `">=3.35.0 <4.0.0"`,
/// a number) fails here, naming the file, instead of being taken for a package that claims nothing.
fn flutter_claim_in(file: &str, pubspec: &serde_yaml_ng::Value) -> Option<(u64, u64)> {
    let claim = pubspec.get("environment")?.get("flutter")?;
    let Some(bound) = claim
        .as_str()
        .and_then(|spelled| spelled.strip_prefix(">="))
        .filter(|bound| looks_like_a_version(bound))
    else {
        panic!(
            "{file}: environment.flutter is `{claim:?}`; write it as `\">=X.Y.Z\"`, the only spelling \
             cli/tests/versions.rs reads"
        );
    };
    let (major, minor, _) = triple(bound);
    Some((major, minor))
}

#[test]
fn the_flutter_claim_is_read_as_yaml_and_only_one_spelling_is_accepted() {
    let claim = |flutter: &str| {
        let pubspec =
            serde_yaml_ng::from_str(&format!("environment:\n  flutter: {flutter}\n")).unwrap();
        std::panic::catch_unwind(|| flutter_claim_in("p/pubspec.yaml", &pubspec)).ok()
    };
    // However the string is quoted, it is the same claim.
    assert_eq!(claim("\">=3.35.0\""), Some(Some((3, 35))));
    assert_eq!(claim("'>=3.35.0'"), Some(Some((3, 35))));
    assert_eq!(claim("'>=3.44.2'  # a comment"), Some(Some((3, 44))));
    let no_claim = serde_yaml_ng::from_str("environment:\n  sdk: ^3.9.0\n").unwrap();
    assert_eq!(flutter_claim_in("p/pubspec.yaml", &no_claim), None);
    // Anything else is an error, not a package that claims nothing.
    for spelled in [
        "^3.35.0",
        "\">=3.35.0 <4.0.0\"",
        "\">3.35.0\"",
        "\">=3.35\"",
        "3.35",
        "\"3.35.0\"",
    ] {
        assert_eq!(claim(spelled), None, "`{spelled}` must fail, not parse");
    }
}

/// The `dir:` entries of the matrix of ci.yml's `floor` job, in order.
fn floor_matrix(ci: &str) -> Vec<String> {
    let dirs = job_matrix(ci, "floor");
    assert!(!dirs.is_empty(), "the floor job's `dir:` matrix is empty");
    dirs
}

#[test]
fn the_floor_job_runs_the_flutter_the_packages_claim() {
    // `ci.yml`'s `floor` job runs on FLUTTER_FLOOR_VERSION, the one place the floor is spelled
    // out for CI (`just floor` reads it from there). What the pubspecs and READMEs claim must be
    // that minor, or the job proves a floor nobody states.
    let ci = read(".github/workflows/ci.yml");
    let floor = floor_version(&ci);
    let floor_mm = floor_minor(&ci);
    let minor = format!("{}.{}", floor_mm.0, floor_mm.1);
    assert!(
        ci.contains("flutter-version: ${{ env.FLUTTER_FLOOR_VERSION }}"),
        "the floor job must install Flutter from FLUTTER_FLOOR_VERSION, not a second spelling"
    );
    // The job runs exactly the packages that claim the floor (and `examples/minimal`), so a new
    // companion that says `flutter: ">=3.35.0"` is run there from its first PR. fespalier_devtools
    // claims it too but is an app whose build and lockfile are committed (see the job's comment).
    let matrix = floor_matrix(&ci);
    let mut expected = workspace_members();
    expected.push("examples/minimal".to_string());
    assert_eq!(
        sorted(matrix.clone()),
        sorted(expected),
        "the floor job's matrix (left) is not the workspace plus examples/minimal (right)"
    );
    // Inside the workspace a pub downgrade moves every package together: the job and the recipe run each
    // package in a copy outside it.
    let job = job_text(&ci, "floor");
    assert!(
        job.contains("run: python3 scripts/floor_copy.py \"$RUNNER_TEMP/floor\""),
        "the floor job copies first"
    );
    assert_eq!(
        job.matches("working-directory: ${{ runner.temp }}/floor/${{ matrix.dir }}")
            .count(),
        3,
        "downgrade, analyze and test run in the copy"
    );
    let justfile = read("justfile");
    assert!(
        justfile.contains("python3 scripts/floor_copy.py \"$work/tree\""),
        "`just floor` copies first"
    );
    assert!(
        justfile.contains("(cd \"$work/tree/$d\" && flutter pub downgrade"),
        "`just floor` runs in the copy"
    );
    let mut claiming: Vec<String> = dart_folders()
        .into_iter()
        .filter(|dir| dir.starts_with("packages/") && dir != "packages/fespalier_devtools")
        .filter(|dir| flutter_claim(dir) == Some(floor_mm))
        .collect();
    claiming.sort();
    let mut run: Vec<String> = matrix
        .iter()
        .filter(|dir| dir.starts_with("packages/"))
        .cloned()
        .collect();
    run.sort();
    assert_eq!(
        run, claiming,
        "the floor job's packages (left) are not the packages that claim `flutter: \">={minor}.0\"` \
         (right): add a new one to the root pubspec.yaml's `workspace:` and to the floor matrix in ci.yml"
    );
    for readme in [
        "README.md",
        "packages/fespalier/README.md",
        "packages/fespalier_auth/README.md",
    ] {
        assert!(
            read(readme).contains(&format!("Flutter {minor} or newer")),
            "{readme} does not say `Flutter {minor} or newer`, the floor job's Flutter {floor}"
        );
    }
}

/// The root pubspec.yaml's `workspace:` list: the packages that share one resolution.
fn workspace_members() -> Vec<String> {
    let pubspec: serde_yaml_ng::Value = serde_yaml_ng::from_str(&read("pubspec.yaml")).unwrap();
    pubspec
        .get("workspace")
        .and_then(serde_yaml_ng::Value::as_sequence)
        .expect("the root pubspec.yaml has a `workspace:` list")
        .iter()
        .map(|v| v.as_str().expect("a workspace entry is a path").to_string())
        .collect()
}

/// Every folder under packages/ and examples/ with a pubspec.yaml, sorted.
fn dart_folders() -> Vec<String> {
    let mut out = Vec::new();
    for parent in ["packages", "examples"] {
        for entry in fs::read_dir(root().join(parent)).unwrap() {
            let dir = format!(
                "{parent}/{}",
                entry.unwrap().file_name().into_string().unwrap()
            );
            if root().join(&dir).join("pubspec.yaml").is_file() {
                out.push(dir);
            }
        }
    }
    out.sort();
    out
}

fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

fn pubspec_of(dir: &str) -> serde_yaml_ng::Value {
    serde_yaml_ng::from_str(&read(&format!("{dir}/pubspec.yaml"))).unwrap()
}

/// The names under some top-level sections of a pubspec.
fn dependency_names(pubspec: &serde_yaml_ng::Value, sections: &[&str]) -> Vec<String> {
    sections
        .iter()
        .filter_map(|s| pubspec.get(*s).and_then(serde_yaml_ng::Value::as_mapping))
        .flat_map(|m| m.keys().filter_map(|k| k.as_str().map(str::to_string)))
        .collect()
}

#[test]
fn the_workspace_is_the_packages_that_claim_the_floor() {
    let members = workspace_members();
    assert_eq!(
        members,
        sorted(members.clone()),
        "keep the root pubspec.yaml's `workspace:` sorted"
    );
    let floor = floor_minor(&read(".github/workflows/ci.yml"));
    // Every claim is parsed (a spelling that is not `">=X.Y.Z"` fails here, naming the file), and none
    // is below the floor, which would promise a Flutter that no job runs.
    for dir in dart_folders() {
        if let Some(claim) = flutter_claim(&dir) {
            assert!(
                claim >= floor,
                "{dir}/pubspec.yaml claims Flutter {}.{}, below the floor job's {}.{}",
                claim.0,
                claim.1,
                floor.0,
                floor.1
            );
        }
    }
    let claiming: Vec<String> = dart_folders()
        .into_iter()
        .filter(|d| d.starts_with("packages/") && d != "packages/fespalier_devtools")
        .filter(|d| flutter_claim(d) == Some(floor))
        .collect();
    assert_eq!(
        members, claiming,
        "the root pubspec.yaml's `workspace:` (left) is not the packages that claim the floor's Flutter, {}.{} (right)",
        floor.0, floor.1
    );
    let root = pubspec_of(".");
    let core = pubspec_of("packages/fespalier");
    assert_eq!(
        root["environment"]["sdk"], core["environment"]["sdk"],
        "the root claims fespalier's Dart"
    );
}

#[test]
fn the_root_pins_melos_exactly() {
    // `flutter pub upgrade --major-versions` rewrites an exact pin to `^<newest>`: scripts/deps.sh writes
    // it exact again, and this keeps a hand edit from leaving it a range.
    let melos = pubspec_of(".")["dev_dependencies"]["melos"]
        .as_str()
        .map(str::to_string);
    assert!(
        melos.as_deref().is_some_and(looks_like_a_version),
        "the root pubspec.yaml's dev dependency `melos:` is {melos:?}, not an exact version: write `melos: X.Y.Z` \
         (scripts/deps.sh writes the pin exact again after `deps:upgrade`)"
    );
}

#[test]
fn the_workspace_list_is_plain_entries() {
    // The justfile and scripts/deps.sh read `workspace:` with sed: an entry is `  - <path>` and nothing else
    // (a trailing comment, or a comment at the left margin, which ends the list for sed).
    let text = read("pubspec.yaml");
    let list: Vec<&str> = text
        .lines()
        .skip_while(|l| *l != "workspace:")
        .skip(1)
        .take_while(|l| !l.starts_with(|c: char| c.is_ascii_alphabetic()))
        .filter(|l| !l.trim().is_empty())
        .collect();
    assert!(
        !list.is_empty(),
        "the root pubspec.yaml has no `workspace:` entries"
    );
    for line in list {
        assert!(
            line.starts_with("  - ") && !line.contains('#'),
            "the root pubspec.yaml's `workspace:` entry `{line}` is not a plain `  - <path>` (no comment: the \
             justfile and scripts/deps.sh read the list with sed)"
        );
    }
}

#[test]
fn workspace_packages_resolve_together_and_the_others_alone() {
    let members = workspace_members();
    for dir in dart_folders() {
        let pubspec = pubspec_of(&dir);
        let resolution = pubspec
            .get("resolution")
            .and_then(serde_yaml_ng::Value::as_str);
        if members.contains(&dir) {
            assert_eq!(
                resolution,
                Some("workspace"),
                "{dir}/pubspec.yaml is in the workspace: `resolution: workspace`"
            );
            assert!(
                pubspec.get("dependency_overrides").is_none(),
                "{dir}/pubspec.yaml: a workspace package has no `dependency_overrides`: pub refuses an \
                 override of a workspace package (\"Cannot override workspace packages\"), and a third-party \
                 override in one member would apply to all of them, so this test refuses any; the workspace \
                 resolves its git dependencies on the others to the checkout"
            );
        } else {
            assert!(
                resolution.is_none(),
                "{dir}/pubspec.yaml is outside the workspace: no `resolution:`"
            );
        }
    }
}

#[test]
fn the_justfile_and_ci_run_every_package_and_example() {
    let justfile = read("justfile");
    assert!(
        justfile.contains(
            "members := `sed -n '/^workspace:/,/^[^ ]/s/^  - //p' pubspec.yaml | sed 's/ *#.*//' | tr '\\n' ' '`"
        ),
        "the justfile reads `members` from the root pubspec.yaml"
    );
    for line in [
        "dart_dirs := members + outside_dirs",
        "floor_dirs := members + \"examples/minimal\"",
    ] {
        assert!(
            justfile.lines().any(|l| l == line),
            "the justfile has no `{line}`"
        );
    }
    let outside: Vec<String> = justfile
        .lines()
        .find_map(|l| l.strip_prefix("outside_dirs := "))
        .expect("the justfile has no `outside_dirs := ` line")
        .trim_matches('"')
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let members = workspace_members();
    let expected: Vec<String> = dart_folders()
        .into_iter()
        .filter(|d| !members.contains(d))
        .collect();
    assert_eq!(
        sorted(outside.clone()),
        expected,
        "`outside_dirs` (left) is not every Dart folder outside the workspace (right)"
    );
    let mut all = members;
    all.extend(outside);
    assert_eq!(
        sorted(job_matrix(&read(".github/workflows/ci.yml"), "dart")),
        sorted(all),
        "the dart job's matrix (left) is not every package and example (right)"
    );
}

/// The pubspecs that may spell a third-party dependency their own way: (folder, dependency, reason). None
/// today: `fespalier_sentry` spelled `http` down to 0.13.0 so that its own floor avoided a win32 that does not
/// compile on Dart 3.9, until it depended on `win32` itself. Every other pubspec that names the dependency
/// spells it one way.
const SPELLING_EXCEPTIONS: [(&str, &str, &str); 0] = [];

#[test]
fn every_third_party_dependency_has_one_constraint() {
    use std::collections::BTreeMap;
    // dependency -> spelling -> where
    let mut seen: BTreeMap<String, BTreeMap<String, Vec<String>>> = BTreeMap::new();
    let mut excepted = Vec::new();
    let mut dirs = vec![".".to_string()];
    dirs.extend(dart_folders());
    for dir in dirs {
        let pubspec = pubspec_of(&dir);
        for section in ["dependencies", "dev_dependencies", "dependency_overrides"] {
            let Some(deps) = pubspec
                .get(section)
                .and_then(serde_yaml_ng::Value::as_mapping)
            else {
                continue;
            };
            for (name, spec) in deps {
                let name = name.as_str().unwrap();
                if name.starts_with("fespalier")
                    || spec.get("sdk").is_some()
                    || spec.get("path").is_some()
                {
                    continue;
                }
                let spelling = match spec {
                    serde_yaml_ng::Value::String(s) => s.clone(),
                    serde_yaml_ng::Value::Null => "any".to_string(),
                    other => serde_yaml_ng::to_string(other).unwrap(),
                };
                if SPELLING_EXCEPTIONS
                    .iter()
                    .any(|(d, n, _)| *d == dir && *n == name)
                {
                    excepted.push((dir.clone(), name.to_string(), spelling));
                    continue;
                }
                seen.entry(name.to_string())
                    .or_default()
                    .entry(spelling)
                    .or_default()
                    .push(format!("{dir}/pubspec.yaml ({section})"));
            }
        }
    }
    let bad: Vec<String> = seen
        .iter()
        .filter(|(_, spellings)| spellings.len() > 1)
        .map(|(name, spellings)| format!("{name}: {spellings:?}"))
        .collect();
    assert!(
        bad.is_empty(),
        "spell each third-party dependency one way in every pubspec, or add the pubspec to \
         SPELLING_EXCEPTIONS with the reason:\n{}",
        bad.join("\n")
    );
    for (dir, name, reason) in SPELLING_EXCEPTIONS {
        let own = excepted
            .iter()
            .find(|(d, n, _)| d == dir && n == name)
            .map(|(_, _, spelling)| spelling);
        let common = seen.get(name).and_then(|s| s.keys().next());
        assert!(
            own.is_some() && own != common,
            "SPELLING_EXCEPTIONS lets {dir} spell `{name}` its own way ({reason}), but it does not \
             any more: remove the entry"
        );
    }
}

/// What an app picks at the lowest versions of a plugin or of Dio does not always compile, and a constraint that
/// steers it away must sit in the pubspec of every package that brings the plugin (an app resolves its regular
/// dependencies only): (the dependencies that bring it, the ones that steer, why).
const STEERING: [(&[&str], &[&str], &str); 4] = [
    (
        &[
            "path_provider",
            "shared_preferences",
            "flutter_secure_storage",
            "background_downloader",
        ],
        &["platform", "file"],
        "path_provider's platform interface allows platform 3.0.0, which reads `Platform.packageRoot` (gone from \
         Dart 3), and its Linux and Windows plugins, like shared_preferences', allow file 6.0.0 to 6.1.2, which \
         fail on Dart 3.9 (`File.create` has no `exclusive:`); a Linux or Windows build compiles those plugins' \
         Dart code and `flutter test` does not",
    ),
    (
        &["sentry_flutter", "package_info_plus"],
        &["win32"],
        "sentry_flutter asks for package_info_plus 1.0.0 or newer, and package_info_plus 4.0.2 allows win32 4.0.0: \
         win32 before 5.5.3 uses `UnmodifiableUint8ListView`, gone from dart:typed_data, so a Windows build fails",
    ),
    (
        &["connectivity_plus"],
        &["web"],
        "connectivity_plus 6.0.1 allows web 0.3.0, whose JS interop does not compile for the web on Dart 3.9 \
         (`The type 'JSObject' can't be used as supertype`)",
    ),
    (
        &["dio"],
        &["dio_web_adapter"],
        "dio 5.7.0 with dio_web_adapter 1.0.0 (what the lowest versions pick) calls a `debugLog` that 5.7.0 lacks, \
         so a web build fails",
    ),
];

#[test]
fn a_package_that_brings_a_plugin_or_dio_steers_its_apps_away_from_versions_that_do_not_compile() {
    // `scripts/floor_app.py` finds these in the floor jobs; this keeps the next package that depends on one
    // of them (or an example, or `fsp create`'s pubspec, which is checked in create_tests.rs) from forgetting.
    use std::collections::BTreeSet;
    // The regular dependencies a package or example resolves: its own, and those of the fespalier packages it names.
    fn regular(dir: &str, seen: &mut BTreeSet<String>) {
        for dep in dependency_names(&pubspec_of(dir), &["dependencies"]) {
            if seen.insert(dep.clone()) && dep.starts_with("fespalier") {
                regular(&format!("packages/{dep}"), seen);
            }
        }
    }
    let mut checked = 0;
    for dir in dart_folders() {
        if dir == "packages/fespalier_devtools" {
            continue;
        }
        let own: BTreeSet<String> = dependency_names(&pubspec_of(&dir), &["dependencies"])
            .into_iter()
            .collect();
        for (brings, steers, why) in STEERING {
            if !brings.iter().any(|b| own.contains(*b)) {
                continue;
            }
            // A dependency on a fespalier package that steers already carries it.
            let mut inherited = BTreeSet::new();
            for dep in own.iter().filter(|d| d.starts_with("fespalier")) {
                regular(&format!("packages/{dep}"), &mut inherited);
            }
            for steer in steers {
                checked += 1;
                assert!(
                    own.contains(*steer) || inherited.contains(*steer),
                    "{dir}/pubspec.yaml depends on one of {brings:?} and so must list `{steer}` (not imported, \
                     with a comment): {why}"
                );
            }
        }
    }
    assert!(
        checked > 10,
        "only {checked} steering constraints were checked: did the walk break?"
    );
}

#[test]
fn a_sibling_package_by_git_is_this_repository_at_its_own_folder() {
    // A `fespalier*` git dependency must name this repository and `packages/<name>`: the workspace
    // resolves it to the checkout whatever it says, so a wrong url or path would only fail for an app.
    let mut checked = 0;
    for dir in dart_folders() {
        let pubspec = pubspec_of(&dir);
        for section in ["dependencies", "dev_dependencies", "dependency_overrides"] {
            let Some(deps) = pubspec
                .get(section)
                .and_then(serde_yaml_ng::Value::as_mapping)
            else {
                continue;
            };
            for (name, spec) in deps {
                let name = name.as_str().unwrap();
                let Some(git) = spec.get("git").filter(|_| name.starts_with("fespalier")) else {
                    continue;
                };
                checked += 1;
                let field = |key: &str| git.get(key).and_then(serde_yaml_ng::Value::as_str);
                assert_eq!(
                    field("url"),
                    Some("https://github.com/fespalier/fespalier"),
                    "{dir}/pubspec.yaml ({section}): the git url of `{name}`"
                );
                assert_eq!(
                    field("path"),
                    Some(format!("packages/{name}").as_str()),
                    "{dir}/pubspec.yaml ({section}): the git path of `{name}`"
                );
            }
        }
    }
    assert!(
        checked > 20,
        "only {checked} git dependencies on a fespalier package were found: did the walk break?"
    );
}

#[test]
fn the_floor_copies_override_what_each_package_reaches() {
    use std::collections::BTreeSet;
    let dest = tempfile::tempdir().unwrap();
    let out = match Command::new("python3")
        .arg(root().join("scripts/floor_copy.py"))
        .arg(dest.path().join("tree"))
        .output()
    {
        Ok(out) => out,
        Err(e) => {
            eprintln!(
                "skipping: no python3 to run scripts/floor_copy.py ({e}); CI runs it on Linux"
            );
            return;
        }
    };
    assert!(
        out.status.success(),
        "floor_copy.py failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let tree = dest.path().join("tree");
    assert!(
        !tree.join("pubspec.yaml").exists(),
        "no workspace root above the copies"
    );
    assert!(tree.join("examples/minimal/pubspec.yaml").is_file());
    let members = workspace_members();
    let names: BTreeSet<String> = members
        .iter()
        .map(|d| d.rsplit('/').next().unwrap().to_string())
        .collect();
    for dir in &members {
        let name = dir.rsplit('/').next().unwrap();
        let mut reached = BTreeSet::new();
        let mut todo = dependency_names(&pubspec_of(dir), &["dependencies", "dev_dependencies"]);
        while let Some(dep) = todo.pop() {
            if names.contains(&dep) && dep != name && reached.insert(dep.clone()) {
                todo.extend(dependency_names(
                    &pubspec_of(&format!("packages/{dep}")),
                    &["dependencies"],
                ));
            }
        }
        let file = tree.join(dir).join("pubspec_overrides.yaml");
        let overrides: serde_yaml_ng::Value =
            serde_yaml_ng::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
        assert!(
            overrides
                .get("resolution")
                .is_some_and(serde_yaml_ng::Value::is_null),
            "{dir}: the copy resets `resolution:`"
        );
        let mut got = BTreeSet::new();
        if let Some(map) = overrides
            .get("dependency_overrides")
            .and_then(serde_yaml_ng::Value::as_mapping)
        {
            for (dep, spec) in map {
                let dep = dep.as_str().unwrap().to_string();
                assert_eq!(
                    spec["path"].as_str(),
                    Some(format!("../{dep}").as_str()),
                    "{dir}: {dep}"
                );
                got.insert(dep);
            }
        }
        assert_eq!(
            got, reached,
            "{dir}: the copy overrides exactly the workspace packages it reaches"
        );
        for skipped in [".dart_tool", "build", "pubspec.lock"] {
            assert!(
                !tree.join(dir).join(skipped).exists(),
                "{dir}: {skipped} was copied"
            );
        }
    }
}

/// Runs `python3 scripts/<script>` with the arguments; None when there is no python3 (CI runs it on Linux).
fn python(script: &str, args: &[&Path]) -> Option<std::process::Output> {
    match Command::new("python3")
        .arg(root().join("scripts").join(script))
        .args(args)
        .output()
    {
        Ok(out) => Some(out),
        Err(e) => {
            eprintln!("skipping: no python3 to run scripts/{script} ({e}); CI runs it on Linux");
            None
        }
    }
}

/// The `lib/*.dart` files of a package, sorted.
fn public_libraries(dir: &str) -> Vec<String> {
    let mut libs: Vec<String> = fs::read_dir(root().join(dir).join("lib"))
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| {
            Path::new(n)
                .extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("dart"))
        })
        .collect();
    libs.sort();
    libs
}

#[test]
fn the_floor_apps_depend_on_what_they_are_for() {
    // scripts/floor_app.py writes the apps the floor runs: one with every workspace package, and one per package
    // with that package alone. Read back here, so a package the union leaves out, a library its test does not
    // import or an override a one-package app lacks fails this test, not a CI run an hour later.
    use std::collections::BTreeSet;
    let dest = tempfile::tempdir().unwrap();
    let tree = dest.path().join("tree");
    let Some(copied) = python("floor_copy.py", &[&tree]) else {
        return;
    };
    assert!(
        copied.status.success(),
        "floor_copy.py failed: {}",
        String::from_utf8_lossy(&copied.stderr)
    );
    let members = workspace_members();
    let names: BTreeSet<String> = members
        .iter()
        .map(|d| d.rsplit('/').next().unwrap().to_string())
        .collect();
    let keys = |pubspec: &serde_yaml_ng::Value, section: &str| -> BTreeSet<String> {
        pubspec[section]
            .as_mapping()
            .unwrap_or_else(|| panic!("the app's {section} is a map"))
            .keys()
            .filter_map(serde_yaml_ng::Value::as_str)
            .map(str::to_string)
            .collect()
    };
    // The test and the web entry point import every public library (each lib/*.dart, not lib/src) of `of`.
    let imports = |app: &Path, of: &[String]| {
        for file in ["test/imports_test.dart", "lib/main.dart"] {
            let text = fs::read_to_string(app.join(file)).unwrap();
            for dir in of {
                let name = dir.rsplit('/').next().unwrap();
                let libs = public_libraries(dir);
                assert!(!libs.is_empty(), "{dir} has no lib/*.dart");
                for lib in libs {
                    assert!(
                        text.contains(&format!("import 'package:{name}/{lib}' as p")),
                        "{file} does not import package:{name}/{lib}"
                    );
                }
            }
            let count = text.matches("import 'package:").count();
            let want: usize = of.iter().map(|d| public_libraries(d).len()).sum();
            // flutter_test or flutter, and one import per library.
            assert_eq!(count, want + 1, "{file}: one import per public library");
        }
        assert!(
            fs::read_to_string(app.join("web/index.html"))
                .unwrap()
                .contains("flutter_bootstrap.js"),
            "web/index.html loads the bootstrap script a web build needs"
        );
    };
    let pubspec_at = |app: &Path| -> serde_yaml_ng::Value {
        serde_yaml_ng::from_str(&fs::read_to_string(app.join("pubspec.yaml")).unwrap()).unwrap()
    };
    let in_tree = |app: &Path, pubspec: &serde_yaml_ng::Value, section: &str, name: &str| {
        let path = pubspec[section][name]["path"]
            .as_str()
            .unwrap_or_else(|| panic!("{section}: {name} is a path dependency"));
        assert_eq!(
            app.join(path).canonicalize().unwrap(),
            tree.join("packages").join(name).canonicalize().unwrap(),
            "{section}: {name} is not its copy in the tree"
        );
    };

    // The union: every package, depended on and overridden.
    let app = dest.path().join("app");
    let out = python("floor_app.py", &[&tree, &app]).unwrap();
    assert!(
        out.status.success(),
        "floor_app.py failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let pubspec = pubspec_at(&app);
    for section in ["dependencies", "dependency_overrides"] {
        let got: BTreeSet<String> = keys(&pubspec, section)
            .into_iter()
            .filter(|k| names.contains(k))
            .collect();
        assert_eq!(
            got, names,
            "the app's {section} is not every workspace package"
        );
        for name in &names {
            in_tree(&app, &pubspec, section, name);
        }
    }
    imports(&app, &members);

    // One package alone: a dependency on it, an override for it and for what it reaches, its own imports.
    for dir in &members {
        let name = dir.rsplit('/').next().unwrap();
        let app = dest.path().join(format!("only-{name}"));
        let out = Command::new("python3")
            .arg(root().join("scripts/floor_app.py"))
            .args(["--only", name])
            .arg(&tree)
            .arg(&app)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "floor_app.py --only {name} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let pubspec = pubspec_at(&app);
        let depends: BTreeSet<String> = keys(&pubspec, "dependencies")
            .into_iter()
            .filter(|k| k != "flutter")
            .collect();
        assert_eq!(
            depends,
            BTreeSet::from([name.to_string()]),
            "{name} alone: the app depends on that package and nothing else"
        );
        // What the package reaches in the workspace through its regular dependencies (an app resolves no dev
        // dependency of it), then theirs.
        let mut reached = BTreeSet::from([name.to_string()]);
        let mut todo = dependency_names(&pubspec_of(dir), &["dependencies"]);
        while let Some(dep) = todo.pop() {
            if names.contains(&dep) && reached.insert(dep.clone()) {
                todo.extend(dependency_names(
                    &pubspec_of(&format!("packages/{dep}")),
                    &["dependencies"],
                ));
            }
        }
        assert_eq!(
            keys(&pubspec, "dependency_overrides"),
            reached,
            "{name} alone: the app overrides the package and the workspace packages it reaches, no others"
        );
        for dep in &reached {
            in_tree(&app, &pubspec, "dependency_overrides", dep);
        }
        imports(&app, std::slice::from_ref(dir));
    }
    let bad = python(
        "floor_app.py",
        &[
            Path::new("--only"),
            Path::new("nope"),
            &tree,
            &dest.path().join("nope"),
        ],
    )
    .unwrap();
    assert!(
        !bad.status.success(),
        "--only names a workspace package, and refuses another"
    );
}

#[test]
fn the_plugins_check_imports_the_dart_implementations_the_app_resolved() {
    // `floor_app.py --plugins <app>` reads `.flutter-plugins-dependencies` (what `flutter pub get` writes) and
    // each plugin's pubspec, and imports the `dartPluginClass` libraries of the native platforms: what a
    // build's plugin registrant compiles and `flutter test` does not. Here with plugins made up for it.
    let dest = tempfile::tempdir().unwrap();
    let plugins = dest.path().join("plugins");
    let app = dest.path().join("app");
    fs::create_dir_all(app.join("test")).unwrap();
    let plugin = |name: &str, platforms: &str| {
        let dir = plugins.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("pubspec.yaml"),
            format!(
                "name: {name}\ndescription: >-\n  A plugin: with a colon\nflutter:\n  plugin:\n    platforms:\n{platforms}\ndependencies:\n  flutter:\n    sdk: flutter\n"
            ),
        )
        .unwrap();
        format!("{{\"name\":\"{name}\",\"path\":\"{}/\"}}", dir.display())
    };
    let linux_dart = plugin(
        "shared_preferences_linux",
        "      linux:\n        dartPluginClass: SharedPreferencesLinux\n",
    );
    let custom_file = plugin(
        "custom_windows",
        "      windows:\n        dartPluginClass: CustomWindows\n        dartFileName: src/custom.dart\n",
    );
    let native_only = plugin(
        "native_only",
        "      linux:\n        pluginClass: NativeOnlyPlugin\n",
    );
    let web_dart = plugin(
        "shared_preferences_web",
        "      web:\n        pluginClass: SharedPreferencesPlugin\n        fileName: shared_preferences_web.dart\n",
    );
    let endorsed = plugin(
        "shared_preferences",
        "      linux:\n        default_package: shared_preferences_linux\n",
    );
    fs::write(
        app.join(".flutter-plugins-dependencies"),
        format!(
            "{{\"plugins\":{{\"linux\":[{linux_dart},{native_only},{endorsed}],\"windows\":[{custom_file}],\"web\":[{web_dart}],\"ios\":[]}}}}"
        ),
    )
    .unwrap();
    let Some(out) = python("floor_app.py", &[Path::new("--plugins"), &app]) else {
        return;
    };
    assert!(
        out.status.success(),
        "floor_app.py --plugins failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let test = fs::read_to_string(app.join("test/plugins_test.dart")).unwrap();
    assert!(
        test.contains(
            "import 'package:shared_preferences_linux/shared_preferences_linux.dart' as p"
        ),
        "a dartPluginClass imports <package>.dart:\n{test}"
    );
    assert!(
        test.contains("import 'package:custom_windows/src/custom.dart' as p"),
        "dartFileName names the library:\n{test}"
    );
    assert_eq!(
        test.matches("import 'package:").count(),
        3,
        "flutter_test and the two Dart plugins, not a native-only, web or endorsing plugin:\n{test}"
    );
    // No plugin resolved: the app with every package refuses to prove nothing.
    let empty = dest.path().join("empty");
    fs::create_dir_all(&empty).unwrap();
    fs::write(
        empty.join(".flutter-plugins-dependencies"),
        "{\"plugins\":{\"linux\":[]}}",
    )
    .unwrap();
    let none = python("floor_app.py", &[Path::new("--plugins"), &empty]).unwrap();
    assert!(
        !none.status.success(),
        "no Dart plugin implementation in the app with every package means the check proves nothing"
    );
    // A package alone may have none.
    let alone = python(
        "floor_app.py",
        &[
            Path::new("--only"),
            Path::new("fespalier_flags"),
            Path::new("--plugins"),
            &empty,
        ],
    )
    .unwrap();
    assert!(
        alone.status.success(),
        "a package alone may resolve no plugin"
    );
    assert!(!empty.join("test/plugins_test.dart").exists());
}

#[test]
fn the_floor_jobs_run_every_app_check_and_cannot_skip_one() {
    // The `floor-app` job (every package) and the `floor` job (each package alone, in its matrix leg) run the same
    // checks on an app at its lowest versions: downgrade, pub get (the plugin list), the plugins' Dart code,
    // flutter test, the web build. Read as YAML, so a step with an `if: false`, one that echoes instead of running,
    // or one in another folder fails here. The `justfile`'s `floor` recipe runs them too, and is read line by line.
    let ci = ci_yaml();
    let floor_app = &ci["jobs"]["floor-app"];
    assert!(
        floor_app.is_mapping(),
        "ci.yml has a floor-app job: it is the only run of the app with every package"
    );
    assert!(
        floor_app.get("if").is_none(),
        "ci.yml: jobs.floor-app has an `if:`, so it can be skipped"
    );
    assert!(
        floor_app.get("continue-on-error").is_none(),
        "ci.yml: jobs.floor-app cannot fail the build"
    );
    assert_eq!(
        job_text(&read(".github/workflows/ci.yml"), "floor-app")
            .matches("flutter-version: ${{ env.FLUTTER_FLOOR_VERSION }}")
            .count(),
        1,
        "the floor-app job installs the floor's Flutter"
    );
    let steps = ci_steps(&ci, "floor-app");
    let write = step_running(
        &steps,
        "floor-app",
        "python3 scripts/floor_copy.py \"$RUNNER_TEMP/floor-app/tree\"\npython3 scripts/floor_app.py \"$RUNNER_TEMP/floor-app/tree\" \"$RUNNER_TEMP/floor-app/app\"",
        None,
    );
    AppSteps {
        job: "floor-app",
        dir: "${{ runner.temp }}/floor-app/app",
        condition: None,
        plugins_env: &[],
        plugins: "python3 \"$GITHUB_WORKSPACE/scripts/floor_app.py\" --plugins .",
    }
    .check(&steps, write);

    // The floor job: the packages (not examples/minimal) run once more, each alone as an app.
    let floor = &ci["jobs"]["floor"];
    assert!(
        floor.get("if").is_none(),
        "ci.yml: jobs.floor has an `if:`, so it can be skipped"
    );
    let steps = ci_steps(&ci, "floor");
    let copy = step_running(
        &steps,
        "floor",
        "python3 scripts/floor_copy.py \"$RUNNER_TEMP/floor\"",
        None,
    );
    let write = step_running(
        &steps,
        "floor",
        "python3 scripts/floor_app.py --only \"${DIR##*/}\" \"$RUNNER_TEMP/floor\" \"$RUNNER_TEMP/floor-only\"",
        None,
    );
    assert!(
        write > copy,
        "ci.yml: the package alone is written after the copies"
    );
    assert_eq!(
        steps[write]["env"]["DIR"].as_str(),
        Some("${{ matrix.dir }}"),
        "ci.yml: jobs.floor: the package alone is the matrix leg's"
    );
    assert_eq!(
        steps[write]
            .get("if")
            .and_then(serde_yaml_ng::Value::as_str),
        Some("startsWith(matrix.dir, 'packages/')"),
        "ci.yml: jobs.floor: the package alone runs for every package, and only for them"
    );
    AppSteps {
        job: "floor",
        dir: "${{ runner.temp }}/floor-only",
        condition: Some("startsWith(matrix.dir, 'packages/')"),
        plugins_env: &[("DIR", "${{ matrix.dir }}")],
        plugins: "python3 \"$GITHUB_WORKSPACE/scripts/floor_app.py\" --only \"${DIR##*/}\" --plugins .",
    }
    .check(&steps, write);

    // The recipe, line by line (a commented-out line is another line).
    let justfile = read("justfile");
    let recipe: Vec<&str> = justfile
        .lines()
        .skip_while(|l| !l.starts_with("floor sdk="))
        .take_while(|l| !l.is_empty() || l.starts_with(' '))
        .collect();
    let lines = [
        "    python3 scripts/floor_copy.py \"$work/tree\" > /dev/null",
        "    app_floor() {",
        "        (cd \"$1\" && flutter pub downgrade && flutter pub get \\",
        "            && python3 \"$root/scripts/floor_app.py\" $2 --plugins . \\",
        "            && flutter test \\",
        "            && python3 \"$root/scripts/floor_app.py\" --web .)",
        "    }",
        "        (cd \"$work/tree/$d\" && flutter pub downgrade && flutter analyze && flutter test)",
        "        case \"$d\" in",
        "            packages/*)",
        "                python3 scripts/floor_app.py --only \"${d##*/}\" \"$work/tree\" \"$work/only\" > /dev/null",
        "                app_floor \"$work/only\" \"--only ${d##*/}\"",
        "    python3 scripts/floor_app.py \"$work/tree\" \"$work/app\" > /dev/null",
        "    app_floor \"$work/app\" \"\"",
    ];
    let mut previous = 0;
    for line in lines {
        let at = recipe
            .iter()
            .position(|l| *l == line)
            .unwrap_or_else(|| panic!("the justfile's `floor` recipe has no line `{line}`"));
        assert!(
            at >= previous,
            "the justfile's `floor` recipe: `{line}` is out of order"
        );
        previous = at;
    }
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

/// The `channel = "..."` of a `rust-toolchain.toml`.
fn toolchain_channel(rel: &str) -> String {
    read(rel)
        .lines()
        .find_map(|l| {
            let value = l.trim().strip_prefix("channel")?.trim().strip_prefix('=')?;
            Some(value.trim().trim_matches('"').to_string())
        })
        .unwrap_or_else(|| panic!("{rel} has no `channel = ` line"))
}

#[test]
fn the_cose_example_server_builds_with_the_generators_rust() {
    // examples/cose/server is a crate of its own (its own Cargo.lock), so it has its own
    // rust-toolchain.toml, which the `cose` job reads: it must not drift from the one every other
    // job builds with, or the example is proven on a compiler nobody else uses.
    assert_eq!(
        toolchain_channel("examples/cose/server/rust-toolchain.toml"),
        toolchain_channel("cli/rust-toolchain.toml"),
        "examples/cose/server/rust-toolchain.toml (left) and cli/rust-toolchain.toml (right) differ"
    );
    let ci = read(".github/workflows/ci.yml");
    assert!(
        ci.contains("\n  cose:\n"),
        "ci.yml has no `cose` job (examples/cose)"
    );
    for needle in [
        "examples/cose/server/rust-toolchain.toml",
        "COSE_SERVER_BIN",
        "FSP_REQUIRE_COSE_SERVER",
    ] {
        assert!(
            ci.contains(needle),
            "the cose job must mention `{needle}`: it builds the server with the pinned toolchain \
             and requires the end-to-end test to run against it"
        );
    }
}

#[test]
fn the_wire_sizes_example_server_builds_with_the_generators_rust() {
    // Same as the cose server: a crate of its own with its own rust-toolchain.toml, which the
    // `wire-sizes` job reads, so it must not drift from cli/rust-toolchain.toml.
    assert_eq!(
        toolchain_channel("examples/wire-sizes/server/rust-toolchain.toml"),
        toolchain_channel("cli/rust-toolchain.toml"),
        "examples/wire-sizes/server/rust-toolchain.toml (left) and cli/rust-toolchain.toml (right) \
         differ"
    );
    let ci = read(".github/workflows/ci.yml");
    assert!(
        ci.contains("\n  wire-sizes:\n"),
        "ci.yml has no `wire-sizes` job (examples/wire-sizes)"
    );
    for needle in [
        "examples/wire-sizes/server/rust-toolchain.toml",
        // The report is generated, and the job has to prove the committed one is fresh rather
        // than trusting it: `wire-sizes-report` writes the very text REPORT.md holds.
        "wire-sizes-report",
    ] {
        assert!(
            ci.contains(needle),
            "the wire-sizes job must mention `{needle}`"
        );
    }
}

#[test]
fn the_cratestack_example_server_builds_with_the_generators_rust() {
    // Same as the cose server: a crate of its own with its own rust-toolchain.toml, which the
    // `cratestack` job reads, so it must not drift from cli/rust-toolchain.toml.
    assert_eq!(
        toolchain_channel("examples/cratestack/server/rust-toolchain.toml"),
        toolchain_channel("cli/rust-toolchain.toml"),
        "examples/cratestack/server/rust-toolchain.toml (left) and cli/rust-toolchain.toml (right) \
         differ"
    );
    let ci = read(".github/workflows/ci.yml");
    assert!(
        ci.contains("\n  cratestack:\n"),
        "ci.yml has no `cratestack` job (examples/cratestack)"
    );
    for needle in [
        "examples/cratestack/server/rust-toolchain.toml",
        "ORDERS_SERVER_BIN",
        "FSP_REQUIRE_ORDERS_SERVER",
        // The generated client is compared with a fresh one, made by the CLI at a commit.
        "scripts/cratestack-client.sh install",
        "scripts/cratestack-client.sh check",
    ] {
        assert!(
            ci.contains(needle),
            "the cratestack job must mention `{needle}`: it builds the server with the pinned \
             toolchain, requires the end-to-end test to run against it and checks the client"
        );
    }
}

#[test]
fn the_cratestack_example_pins_what_is_not_fespaliers_by_commit() {
    // The generated client's pubspec depends on fespalier_transport by git. `--fespalier-ref` is a
    // commit of fespalier/fespalier, never a `v...` tag: fespalier 0.21.0 is not released, and a
    // `ref: v...` in a pubspec is read as fespalier's own version (release-please does not bump it).
    // The example replaces that dependency with the checkout (a dependency override), so the pin is
    // never resolved here; the script that makes the client and the client must agree on it.
    let script = read("scripts/cratestack-client.sh");
    let pinned = |name: &str| {
        script
            .lines()
            .find_map(|l| l.strip_prefix(name)?.strip_prefix('='))
            .unwrap_or_else(|| panic!("scripts/cratestack-client.sh has no `{name}=`"))
            .to_string()
    };
    let is_commit = |s: &str| s.len() == 40 && s.chars().all(|c| c.is_ascii_hexdigit());
    let (cratestack_rev, fespalier_ref) = (pinned("CRATESTACK_REV"), pinned("FESPALIER_REF"));
    assert!(
        is_commit(&cratestack_rev),
        "CRATESTACK_REV is a commit: {cratestack_rev}"
    );
    assert!(
        is_commit(&fespalier_ref),
        "FESPALIER_REF is a commit: {fespalier_ref}"
    );
    let client = pubspec_of("examples/cratestack/client");
    let transport = &client["dependencies"]["fespalier_transport"]["git"];
    assert_eq!(transport["ref"].as_str(), Some(fespalier_ref.as_str()));
    assert_eq!(
        transport["path"].as_str(),
        Some("packages/fespalier_transport")
    );
    let app = pubspec_of("examples/cratestack");
    assert!(
        app["dependency_overrides"]["fespalier_transport"]["path"].is_string(),
        "examples/cratestack/pubspec.yaml must override fespalier_transport with the checkout"
    );
    assert!(
        client["dependencies"].get("dio").is_none(),
        "the fespalier preset's client links no Dio"
    );
}

/// `fsp create` writes the version it is, and spells it out nowhere: the pubspec it plans (for
/// every feature at once) pins fespalier and every companion to `ref: v<this version>` at one
/// url, and nothing in its sources or templates carries a version for release-please to miss.
#[test]
fn fsp_create_pins_every_package_to_this_version() {
    let cargo = env!("CARGO_PKG_VERSION");
    let fsp = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_fsp"))
            .args(args)
            .current_dir(root())
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "fsp {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    };
    let listed = fsp(&["create", "--list-features", "--json"]);
    let ids: Vec<String> = listed
        .lines()
        .map(|l| {
            let feature: serde_json::Value = serde_json::from_str(l).unwrap();
            feature["id"].as_str().unwrap().to_string()
        })
        .collect();
    let mut args = vec!["create", "app_under_test", "--dry-run", "--json"];
    let features = ids.join(",");
    if !ids.is_empty() {
        args.extend(["--features", &features]);
    }
    let events = fsp(&args);
    let pubspec = events
        .lines()
        .map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap())
        .find(|e| e["event"] == "file" && e["path"] == "pubspec.yaml")
        .expect("a pubspec.yaml file event")["content"]
        .as_str()
        .unwrap()
        .to_string();
    let refs = versions_after(&pubspec, "ref: v");
    assert!(!refs.is_empty(), "{pubspec}");
    for (line, v) in &refs {
        assert_eq!(v, cargo, "pubspec.yaml:{line}: `ref: v{v}`\n{pubspec}");
    }
    // Every package at the tag is at the one repository.
    let urls = pubspec
        .lines()
        .filter(|l| {
            l.trim()
                .starts_with("url: https://github.com/fespalier/fespalier")
        })
        .count();
    assert_eq!(urls, refs.len(), "{pubspec}");
    // The sources spell out no version of their own.
    for dir in ["cli/src/create", "cli/templates/create"] {
        for entry in fs::read_dir(root().join(dir)).unwrap() {
            let path = entry.unwrap().path();
            let text = fs::read_to_string(&path).unwrap();
            for marker in MARKERS {
                for (line, v) in versions_after(&text, marker) {
                    assert!(
                        !looks_like_a_version(&v),
                        "{}:{line}: spells out `{marker}{v}`",
                        path.display()
                    );
                }
            }
            assert!(!text.contains("x-release-please"), "{}", path.display());
        }
    }
    let create = read("cli/src/create.rs");
    assert!(
        versions_after(&create, "ref: v")
            .iter()
            .all(|(_, v)| !looks_like_a_version(v)),
        "cli/src/create.rs spells out a ref"
    );
}
