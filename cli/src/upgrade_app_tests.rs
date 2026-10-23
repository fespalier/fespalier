//! Tests of `fsp upgrade --app`'s decisions (`upgrade_app.rs`): the refs it moves, what it refuses,
//! and the migration notes it prints. The run against a stand-in flutter is in `tests/cli.rs`.

use std::fs;
use std::path::Path;

use crate::upgrade::Version;
use crate::upgrade_app::{AppPlan, MIGRATION, Move, notes, notes_text, plan, sections};

fn v(a: u64, b: u64, c: u64) -> Version {
    Version(a, b, c)
}

fn refs(text: &str, target: Version) -> (Version, Vec<Move>, Vec<String>, String) {
    match plan(text, None, target).unwrap_or_else(|e| panic!("{e}")) {
        AppPlan::Refs {
            oldest,
            moves,
            kept,
            pubspec,
            ..
        } => (oldest, moves, kept, pubspec),
        AppPlan::Checkout { root } => panic!("a checkout at {root}"),
    }
}

const APP: &str = "name: shop
dependencies:
  flutter:
    sdk: flutter
  # The router.
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.21.0 # pinned with the companions
  fespalier_http:
    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_http, ref: \"v0.21.0\"}
  otel_zone:
    git:
      url: https://github.com/vaam-apps/flutter-otel-zone
      ref: 64c4661ac6cd09718141864d528892916677cc38
dev_dependencies:
  fespalier_forms:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_forms
      ref: v0.20.0
dependency_overrides:
  fespalier_transport:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_transport
      ref: v0.21.0
";

#[test]
fn it_moves_every_ref_together_and_changes_nothing_else() {
    let (oldest, moves, kept, pubspec) = refs(APP, v(0, 22, 1));
    assert_eq!(oldest, v(0, 20, 0));
    let shown: Vec<(&str, &str, &str, &str)> = moves
        .iter()
        .map(|m| (m.name.as_str(), m.section, m.from.as_str(), m.to.as_str()))
        .collect();
    assert_eq!(
        shown,
        [
            ("fespalier", "dependencies", "v0.21.0", "v0.22.1"),
            ("fespalier_http", "dependencies", "v0.21.0", "v0.22.1"),
            ("fespalier_forms", "dev_dependencies", "v0.20.0", "v0.22.1"),
            (
                "fespalier_transport",
                "dependency_overrides",
                "v0.21.0",
                "v0.22.1"
            ),
        ]
    );
    assert!(kept.is_empty(), "{kept:?}");
    // Each changed line is a ref of this repository, with its comment and quotes kept.
    let changed: Vec<(&str, &str)> = APP
        .lines()
        .zip(pubspec.lines())
        .filter(|(a, b)| a != b)
        .collect();
    assert_eq!(APP.lines().count(), pubspec.lines().count());
    assert_eq!(
        changed,
        [
            (
                "      ref: v0.21.0 # pinned with the companions",
                "      ref: v0.22.1 # pinned with the companions"
            ),
            (
                "    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_http, ref: \"v0.21.0\"}",
                "    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_http, ref: \"v0.22.1\"}"
            ),
            ("      ref: v0.20.0", "      ref: v0.22.1"),
            ("      ref: v0.21.0", "      ref: v0.22.1"),
        ]
    );
}

#[test]
fn nothing_moves_when_every_ref_is_at_the_target() {
    let (oldest, moves, _, pubspec) = refs(APP, v(0, 21, 0));
    // fespalier_forms is behind, so it moves (a downgrade is the person's call: --version).
    assert_eq!(oldest, v(0, 20, 0));
    assert_eq!(moves.len(), 1);
    let at = APP.replace("v0.20.0", "v0.21.0");
    let (oldest, moves, _, pubspec2) = refs(&at, v(0, 21, 0));
    assert_eq!(oldest, v(0, 21, 0));
    assert!(moves.is_empty());
    assert_eq!(pubspec2, at);
    assert_ne!(pubspec, APP);
}

#[test]
fn a_checkout_has_no_ref_to_move() {
    // Every example of this repository depends on its own packages by path.
    let examples = Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples");
    let mut seen = 0;
    for entry in fs::read_dir(examples).unwrap() {
        let path = entry.unwrap().path().join("pubspec.yaml");
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        if !text.contains("\n  fespalier:\n") {
            continue;
        }
        let plan = plan(&text, None, v(0, 22, 1)).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(
            plan,
            AppPlan::Checkout {
                root: "../../packages".to_string()
            },
            "{}",
            path.display()
        );
        seen += 1;
    }
    assert!(seen >= 10, "{seen}");
}

#[test]
fn it_refuses_pins_it_cannot_move_together() {
    let other = APP.replace(
        "url: https://github.com/fespalier/fespalier\n      path: packages/fespalier_forms",
        "url: https://github.com/someone/fork\n      path: packages/fespalier_forms",
    );
    let e = plan(&other, None, v(0, 22, 1)).unwrap_err();
    assert!(
        e.contains(
            "fespalier_forms (dev_dependencies) comes from https://github.com/someone/fork at v0.20.0, not from https://github.com/fespalier/fespalier"
        ),
        "{e}"
    );
    assert!(e.ends_with("then run `fsp upgrade --app` again"), "{e}");
    let branch = APP.replace("ref: v0.20.0", "ref: main");
    let e = plan(&branch, None, v(0, 22, 1)).unwrap_err();
    assert!(
        e.contains(
            "fespalier_forms (dev_dependencies) is at `main`, not a release tag like v0.22.1"
        ),
        "{e}"
    );
    let mixed = "dependencies:\n  fespalier:\n    path: ../fespalier/packages/fespalier\n  fespalier_http:\n    git:\n      url: https://x/y\n      path: packages/fespalier_http\n      ref: v0.21.0\n";
    let e = plan(mixed, None, v(0, 22, 1)).unwrap_err();
    assert!(
        e.contains("from a checkout (../fespalier/packages/fespalier) and fespalier_http (dependencies) from git"),
        "{e}"
    );
}

#[test]
fn overrides_to_a_folder_are_left_and_said() {
    let local = APP.replace(
        "    git:\n      url: https://github.com/fespalier/fespalier\n      path: packages/fespalier_transport\n      ref: v0.21.0\n",
        "    path: ../fespalier/packages/fespalier_transport\n",
    );
    let overrides = "dependency_overrides:\n  fespalier:\n    path: ../fespalier/packages/fespalier\n  http: ^1.0.0\n";
    let AppPlan::Refs { moves, kept, .. } = plan(&local, Some(overrides), v(0, 22, 1)).unwrap()
    else {
        panic!()
    };
    assert_eq!(moves.len(), 3);
    assert_eq!(
        kept,
        [
            "dependency_overrides: fespalier_transport is path ../fespalier/packages/fespalier_transport; left as it is",
            "pubspec_overrides.yaml overrides fespalier; left as it is",
        ]
    );
}

// --- The migration notes -----------------------------------------------------------------------

#[test]
fn every_release_section_of_the_migration_notes_is_read() {
    let all = sections(MIGRATION);
    assert!(all.len() >= 15, "{}", all.len());
    for pair in all.windows(2) {
        assert!(
            pair[0].version > pair[1].version,
            "{} is above {} in docs/migration.md",
            pair[0].heading,
            pair[1].heading
        );
    }
    for section in &all {
        assert!(
            !section.summary.is_empty(),
            "{} says nothing",
            section.heading
        );
        for line in &section.summary {
            assert!(!line.contains("](") && !line.contains("**"), "{line}");
        }
    }
    let nine = all.iter().find(|s| s.heading == "0.9.x").unwrap();
    assert_eq!(nine.version, v(0, 9, 0));
    assert_eq!(
        all.iter()
            .find(|s| s.heading == "0.22.0")
            .unwrap()
            .url("v0.22.1"),
        "https://github.com/fespalier/fespalier/blob/v0.22.1/docs/migration.md#0220"
    );
}

#[test]
fn the_notes_between_two_releases_are_oldest_first() {
    let picked: Vec<String> = notes(MIGRATION, v(0, 19, 0), v(0, 22, 1))
        .into_iter()
        .map(|s| s.heading)
        .collect();
    assert_eq!(picked, ["0.20.0", "0.21.0", "0.22.0"]);
    assert!(notes(MIGRATION, v(0, 22, 0), v(0, 22, 0)).is_empty());
}

const NOTES: &str = "# Migration

## Adopting

### 9.9.9

Not a release section.

## Upgrading

Intro.

### 1.2.0

1.2.0 changes `x`: see [the page](a.md#b). Apps regenerate
`app.g.dart`.

- **A bold lead.** The rest, [linked](c.md).
- No bold here. Then a second sentence.

#### A group

- **Grouped.** More.

### 1.1.0

Only a paragraph.

Another one, not printed.

## After
";

#[test]
fn a_section_is_its_first_paragraph_its_groups_and_its_bullet_leads() {
    let all = sections(NOTES);
    let headings: Vec<&str> = all.iter().map(|s| s.heading.as_str()).collect();
    assert_eq!(headings, ["1.2.0", "1.1.0"]);
    assert_eq!(
        all[0].summary,
        [
            "1.2.0 changes `x`: see the page. Apps regenerate `app.g.dart`.",
            "- A bold lead.",
            "- No bold here.",
            "A group:",
            "- Grouped.",
        ]
    );
    assert_eq!(all[1].summary, ["Only a paragraph."]);
}

#[test]
fn the_notes_text_says_where_to_read_more() {
    let text = notes_text(NOTES, v(1, 0, 0), v(1, 2, 0), v(1, 2, 0));
    assert!(
        text.starts_with(
            "What changed from v1.0.0 to v1.2.0 (docs/migration.md, \"Upgrading\"; read each before you run the app):\n\n1.1.0: https://github.com/fespalier/fespalier/blob/v1.2.0/docs/migration.md#110\n  Only a paragraph.\n\n1.2.0: "
        ),
        "{text}"
    );
    // A target this fsp predates: what it has, then a link for the rest.
    let ahead = notes_text(NOTES, v(1, 0, 0), v(1, 3, 0), v(1, 1, 0));
    assert!(ahead.contains("\n1.1.0: "), "{ahead}");
    assert!(!ahead.contains("\n1.2.0: "), "{ahead}");
    assert!(
        ahead.ends_with(
            "fsp 1.1.0 was built before v1.3.0, so it does not carry the notes of the releases after v1.1.0: https://github.com/fespalier/fespalier/blob/v1.3.0/docs/migration.md#upgrading\n"
        ),
        "{ahead}"
    );
    let down = notes_text(NOTES, v(1, 2, 0), v(1, 1, 0), v(1, 2, 0));
    assert_eq!(
        down,
        "v1.2.0 -> v1.1.0 is a downgrade: https://github.com/fespalier/fespalier/blob/v1.1.0/docs/migration.md#upgrading says what each release in between changed.\n"
    );
    let none = notes_text(NOTES, v(1, 2, 0), v(1, 2, 1), v(1, 2, 1));
    assert_eq!(
        none,
        "No release from v1.2.0 to v1.2.1 has migration notes.\n"
    );
}
