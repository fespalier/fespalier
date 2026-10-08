//! Broken trees and what `fsp check --json` says about them.
//!
//! Each directory under `tests/fixtures/diagnostics/` is the smallest app folder that triggers one
//! diagnostic. Its `expected.txt` is the golden: the exit status, the diagnostics on stdout (one
//! JSON object per line, sorted) and stderr, with the project path replaced by `<project>`.
//! `FSP_UPDATE_GOLDEN=1 cargo test --test diagnostics` rewrites the goldens.
//!
//! The cases are also the example of `skills/fespalier-troubleshooting/`: each one names the
//! reference page that quotes its message, and the test fails when the message no longer has the
//! text the page quotes, or when the page no longer does.

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    reason = "integration-test helpers: a failed unwrap is a failed test"
)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One broken tree: its folder, the page of the troubleshooting skill that quotes what `fsp`
/// says about it, and the pieces of that message the page has to quote.
struct Case {
    name: &'static str,
    page: &'static str,
    quotes: &'static [&'static str],
}

const CASES: &[Case] = &[
    Case {
        name: "folder-name-invalid",
        page: "diagnostics-tree.md",
        quotes: &[
            "`Hello World` is not a valid URL segment (use a-z, A-Z, 0-9, - _ . ~; `$name` for params, `(name)` for groups, `_name` for private folders)",
        ],
    },
    Case {
        name: "two-public-widgets",
        page: "diagnostics-tree.md",
        quotes: &[
            "expected one public widget class, found ",
            "; make the others private (`_Name`)",
        ],
    },
    Case {
        name: "page-and-redirect",
        page: "diagnostics-tree.md",
        quotes: &["a folder has a page.dart or a redirect.dart, not both"],
    },
    Case {
        name: "unreachable-in-group",
        page: "diagnostics-tree.md",
        quotes: &[
            "/settings is unreachable: $a/page.dart (/:a) comes first and matches it; move one of them into or out of its (group)",
        ],
    },
    Case {
        name: "cant-fill-param",
        page: "diagnostics-binding.md",
        quotes: &["can't fill `label`: it isn't a segment of this path"],
    },
    Case {
        name: "segment-type-mismatch",
        page: "diagnostics-binding.md",
        quotes: &["`$id` is String in ", " but int here"],
    },
    Case {
        name: "unknown-segment-type",
        page: "diagnostics-binding.md",
        quotes: &["`Uri id`: segments are String, int, double or bool, or an enum"],
    },
    Case {
        name: "extra-not-nullable",
        page: "diagnostics-binding.md",
        quotes: &[
            "`extra` gets the object passed on navigation, but it isn't in the URL: a deep link or a reload leaves it null, so declare it nullable, e.g. `",
        ],
    },
    Case {
        name: "data-without-page",
        page: "diagnostics-data-and-hooks.md",
        quotes: &[
            "data.dart has no page.dart to feed; with a layout.dart beside it, it would be the data of the section below that layout",
        ],
    },
    Case {
        name: "data-without-ref",
        page: "diagnostics-data-and-hooks.md",
        quotes: &["data() must take `Ref ref` first"],
    },
    Case {
        name: "guard-wrong-return",
        page: "diagnostics-data-and-hooks.md",
        quotes: &["guard() must return GuardResult (a location to redirect to, or null)"],
    },
    Case {
        name: "form-without-forms-package",
        page: "diagnostics-data-and-hooks.md",
        quotes: &[
            "and since 0.11.0 forms are in the fespalier_forms package: add `fespalier_forms` under `dependencies:` in pubspec.yaml, with the same git `url` and `ref` as fespalier",
        ],
    },
    Case {
        name: "config-unknown-field",
        page: "diagnostics-config-and-meta.md",
        quotes: &[
            "invalid pubspec.yaml: fespalier: unknown field `nope`, expected one of `app_dir`, `output`, `format`, `output_manifest`, `meta`",
        ],
    },
    Case {
        name: "app-without-router",
        page: "diagnostics-app-main.md",
        quotes: &[
            "the app's widget gets the router: add `required this.router` (a `GoRouter`) and pass it to `MaterialApp.router(routerConfig: router)`. If this file is not the app around the router, move it out of the app folder's root or set `main: manual`",
        ],
    },
    Case {
        name: "tabs-missing-branch",
        page: "diagnostics-layouts-and-navigators.md",
        quotes: &["`tabs` is missing the branch `b`; list every branch once (`a`, `b`)"],
    },
];

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixtures() -> PathBuf {
    manifest_dir().join("tests/fixtures/diagnostics")
}

fn pages() -> PathBuf {
    manifest_dir().join("../skills/fespalier-troubleshooting/references")
}

/// What `fsp check --json` prints for the tree at `project`, as the text of its golden.
fn run(project: &Path) -> String {
    let out = Command::new(env!("CARGO_BIN_EXE_fsp"))
        .args(["check", "--json", "--project"])
        .arg(project)
        .output()
        .unwrap();
    let here = project.display().to_string();
    let normalise = |bytes: &[u8]| {
        String::from_utf8_lossy(bytes)
            .replace(&here, "<project>")
            .replace(&here.replace('\\', "/"), "<project>")
            .replace("<project>\\", "<project>/")
    };
    let mut lines: Vec<String> = normalise(&out.stdout).lines().map(str::to_owned).collect();
    lines.sort();
    format!(
        "exit: {}\nstdout:\n{}{}\nstderr:\n{}",
        out.status.code().unwrap_or(-1),
        lines.join("\n"),
        if lines.is_empty() { "" } else { "\n" },
        normalise(&out.stderr),
    )
}

#[test]
fn every_fixture_has_a_case_and_every_case_a_fixture() {
    let mut on_disk: Vec<String> = fs::read_dir(fixtures())
        .unwrap()
        .map(|e| e.unwrap())
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    on_disk.sort();
    let mut listed: Vec<String> = CASES.iter().map(|c| c.name.to_owned()).collect();
    listed.sort();
    assert_eq!(on_disk, listed, "a fixture folder and CASES disagree");
}

#[test]
fn goldens_match_fsp_check() {
    let update = std::env::var_os("FSP_UPDATE_GOLDEN").is_some();
    for case in CASES {
        let dir = fixtures().join(case.name);
        let got = run(&dir);
        let golden = dir.join("expected.txt");
        if update {
            fs::write(&golden, &got).unwrap();
        }
        let want = fs::read_to_string(&golden).unwrap_or_default();
        assert_eq!(
            got,
            want,
            "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test --test diagnostics` in cli/",
            golden.display()
        );
    }
}

#[test]
fn every_case_fails_with_a_message_its_skill_page_quotes() {
    for case in CASES {
        let golden = run(&fixtures().join(case.name));
        assert!(
            golden.starts_with("exit: 1\n"),
            "{}: a broken tree must make `fsp check` exit 1",
            case.name
        );
        let page_path = pages().join(case.page);
        let page = fs::read_to_string(&page_path)
            .unwrap_or_else(|e| panic!("{}: {}: {e}", case.name, page_path.display()));
        for quote in case.quotes {
            assert!(
                golden.contains(quote),
                "{}: `fsp` no longer says {quote:?}; update the page ({}) and CASES together",
                case.name,
                case.page
            );
            assert!(
                page.contains(quote),
                "{}: {} no longer quotes {quote:?}, which `fsp` still says",
                case.name,
                case.page
            );
        }
    }
}
