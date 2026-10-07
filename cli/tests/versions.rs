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
const COMPANIONS: [&str; 13] = [
    "packages/fespalier_otel/pubspec.yaml",
    "packages/fespalier_auth/pubspec.yaml",
    "packages/fespalier_sign_keypair/pubspec.yaml",
    "packages/fespalier_adaptive/pubspec.yaml",
    "packages/fespalier_flags/pubspec.yaml",
    "packages/fespalier_storage/pubspec.yaml",
    "packages/fespalier_connectivity/pubspec.yaml",
    "packages/fespalier_image/pubspec.yaml",
    "packages/fespalier_dio/pubspec.yaml",
    "packages/fespalier_cratestack/pubspec.yaml",
    "packages/fespalier_sentry/pubspec.yaml",
    "packages/fespalier_tolgee/pubspec.yaml",
    "packages/fespalier_forms/pubspec.yaml",
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
        assert!(
            !refs.is_empty(),
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
        "packages/fespalier_auth/README.md",
        "packages/fespalier_sign_keypair/README.md",
        "packages/fespalier_adaptive/README.md",
        "packages/fespalier_flags/README.md",
        "packages/fespalier_storage/README.md",
        "packages/fespalier_connectivity/README.md",
        "packages/fespalier_image/README.md",
        "packages/fespalier_dio/README.md",
        "packages/fespalier_cratestack/README.md",
        "packages/fespalier_sentry/README.md",
        "packages/fespalier_tolgee/README.md",
        "packages/fespalier_forms/README.md",
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
        "packages/fespalier_auth/pubspec.yaml",
        "packages/fespalier_auth/README.md",
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

/// The `dir:` entries of the matrix of ci.yml's `floor` job, in order.
fn floor_matrix(ci: &str) -> Vec<String> {
    let job = ci
        .split_once("\n  floor:\n")
        .expect("ci.yml has no `floor` job")
        .1;
    let dirs = job
        .split_once("\n        dir:\n")
        .expect("the floor job has no `dir:` matrix")
        .1;
    let dirs: Vec<String> = dirs
        .lines()
        .map_while(|l| l.trim().strip_prefix("- "))
        .map(str::to_string)
        .collect();
    assert!(!dirs.is_empty(), "the floor job's `dir:` matrix is empty");
    dirs
}

#[test]
fn the_floor_job_runs_the_flutter_the_packages_claim() {
    // `ci.yml`'s `floor` job runs on FLUTTER_FLOOR_VERSION, the one place the floor is spelled
    // out for CI (`just floor` reads it from there). What the pubspecs and READMEs claim must be
    // that minor, or the job proves a floor nobody states.
    let ci = read(".github/workflows/ci.yml");
    let floor = ci
        .lines()
        .find_map(|l| l.trim().strip_prefix("FLUTTER_FLOOR_VERSION:"))
        .map(|v| v.split('#').next().unwrap_or("").trim().to_string())
        .filter(|v| !v.is_empty())
        .expect("ci.yml has no `FLUTTER_FLOOR_VERSION:` line");
    let minor = floor.rsplit_once('.').map(|(minor, _)| minor).unwrap();
    assert_eq!(
        minor.matches('.').count(),
        1,
        "FLUTTER_FLOOR_VERSION is `{floor}`, not major.minor.patch"
    );
    assert!(
        ci.contains("flutter-version: ${{ env.FLUTTER_FLOOR_VERSION }}"),
        "the floor job must install Flutter from FLUTTER_FLOOR_VERSION, not a second spelling"
    );
    // The job runs exactly the packages that claim the floor (and `examples/minimal`), so a new
    // companion that says `flutter: ">=3.32.0"` is run there from its first PR. fespalier_devtools
    // claims it too but is an app whose build and lockfile are committed (see the job's comment).
    let matrix = floor_matrix(&ci);
    let recipe: Vec<String> = read("justfile")
        .lines()
        .find_map(|l| l.strip_prefix("floor_dirs := "))
        .expect("the justfile has no `floor_dirs := ` line")
        .trim_matches('"')
        .split_whitespace()
        .map(str::to_string)
        .collect();
    assert_eq!(
        recipe, matrix,
        "`floor_dirs` in the justfile (left) and the floor job's matrix in ci.yml (right) differ"
    );
    let claim = format!("flutter: \">={minor}.0\"");
    let mut claiming: Vec<String> = fs::read_dir(root().join("packages"))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .filter(|name| name != "fespalier_devtools")
        .map(|name| format!("packages/{name}"))
        .filter(|dir| {
            fs::read_to_string(root().join(dir).join("pubspec.yaml"))
                .is_ok_and(|pubspec| pubspec.contains(&claim))
        })
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
        "the floor job's packages (left) are not the packages that claim `{claim}` (right): add a \
         new one to the matrix in ci.yml and to `floor_dirs` in the justfile"
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
