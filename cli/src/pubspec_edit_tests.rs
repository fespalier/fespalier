//! Tests of the pubspec editor (`pubspec_edit.rs`): on small pubspecs for each edit and layout,
//! and on every pubspec of this repository, which must read back unchanged and take an edit of
//! each kind.

use std::fs;
use std::path::{Path, PathBuf};

use serde_yaml_ng::Value;

use crate::pubspec_edit::{Body, Doc, Edit, Place, Rewrite, apply, write_files};

fn ok(text: &str, edits: &[Edit]) -> String {
    apply(text, edits).unwrap_or_else(|e| panic!("{e}: {}\n{text}", e.edit.by_hand()))
}

fn err(text: &str, edits: &[Edit]) -> String {
    apply(text, edits).unwrap_err().why
}

fn inline(text: &str) -> Body {
    Body::Inline(text.to_string())
}

fn block(lines: &[&str]) -> Body {
    Body::Block(lines.iter().map(|l| (*l).to_string()).collect())
}

/// What `fsp create` writes, cut down.
const CREATED: &str = "name: app
description: A new fespalier app.
publish_to: none

environment:
  sdk: ^3.9.0
  flutter: \">=3.35.0\"

dependencies:
  flutter:
    sdk: flutter
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v9.8.7
  http: \"^1.5.0\"

dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter

flutter:
  uses-material-design: true

# fsp dev reads tasks: from here (docs/cli.md, \"Running your app: `fsp dev`\").
# fespalier:
#   tasks:
#     codegen: dart run build_runner build # fsp run codegen
";

// --- Reading -----------------------------------------------------------------------------------

#[test]
fn a_document_reads_back_byte_for_byte() {
    for text in [
        CREATED,
        "",
        "name: a",
        "name: a\r\ndependencies:\r\n  b: ^1.0.0\r\n",
        "name: a\n\n\n# end\n",
        "name: a\r\nmixed: true\n",
    ] {
        assert_eq!(Doc::parse(text).text(), text);
        assert_eq!(ok(text, &[]), text);
    }
}

// --- Set ---------------------------------------------------------------------------------------

#[test]
fn set_replaces_one_value_and_keeps_its_quotes_and_comment() {
    let text = "dependencies:\n  fespalier:\n    git:\n      url: https://x/y\n      ref: v1.0.0   # the release\n  fespalier_http:\n    git: {url: https://x/y, path: packages/fespalier_http, ref: 'v1.0.0'}\n";
    let out = ok(
        text,
        &[
            Edit::set(&["dependencies", "fespalier", "git", "ref"], "v1.2.0"),
            Edit::set(&["dependencies", "fespalier_http", "git", "ref"], "v1.2.0"),
        ],
    );
    assert_eq!(
        out,
        "dependencies:\n  fespalier:\n    git:\n      url: https://x/y\n      ref: v1.2.0   # the release\n  fespalier_http:\n    git: {url: https://x/y, path: packages/fespalier_http, ref: 'v1.2.0'}\n"
    );
    let quoted = ok(
        "fespalier:\n  telemetry: \"false\" # off\n",
        &[Edit::set(&["fespalier", "telemetry"], "on")],
    );
    assert_eq!(quoted, "fespalier:\n  telemetry: \"on\" # off\n");
}

#[test]
fn set_refuses_what_is_not_there_or_not_on_a_line() {
    assert!(err("a:\n  b: 1\n", &[Edit::set(&["a", "c"], "2")]).contains("`a: c:` is not there"),);
    assert!(
        err("a:\n  b:\n    c: 1\n", &[Edit::set(&["a", "b"], "2")])
            .contains("has no value on its line")
    );
}

/// The check after each edit: a value written over two lines (a plain scalar goes on below its
/// key) is not what replacing its first line makes, and the edit is refused.
#[test]
fn an_edit_that_would_read_differently_is_refused() {
    let text = "a:\n  b: one\n    two\n";
    let e = apply(text, &[Edit::set(&["a", "b"], "x")]).unwrap_err();
    assert_eq!(e.why, "`a: b:` is laid out in a way fsp does not edit");
    assert_eq!(e.edit.by_hand(), "set `a: b:` to `x`");
}

// --- Insert ------------------------------------------------------------------------------------

#[test]
fn insert_puts_a_dependency_in_name_order_past_the_sdk_ones() {
    let out = ok(
        CREATED,
        &[
            Edit::insert(
                &["dependencies"],
                "fespalier_forms",
                block(&[
                    "git:",
                    "  url: https://github.com/fespalier/fespalier",
                    "  path: packages/fespalier_forms",
                    "  ref: v9.8.7",
                ]),
                Place::Sorted,
            ),
            Edit::insert(&["dependencies"], "zeta", inline("^2.0.0"), Place::Sorted),
            Edit::insert(&["dependencies"], "async", inline("^2.0.0"), Place::Sorted),
            Edit::insert(
                &["dev_dependencies"],
                "flutter_secure_storage",
                inline("\">=10.0.0 <12.0.0\""),
                Place::Sorted,
            ),
        ],
    );
    assert!(
        out.contains(
            "dependencies:
  flutter:
    sdk: flutter
  async: ^2.0.0
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v9.8.7
  fespalier_forms:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_forms
      ref: v9.8.7
  http: \"^1.5.0\"
  zeta: ^2.0.0

dev_dependencies:
  flutter_lints: ^6.0.0
  flutter_test:
    sdk: flutter
  flutter_secure_storage: \">=10.0.0 <12.0.0\"
"
        ),
        "{out}"
    );
}

#[test]
fn insert_goes_above_the_comments_of_the_next_key_and_last_when_unsorted() {
    let text = "dependencies:\n  flutter:\n    sdk: flutter\n  fespalier:\n    path: ../fespalier\n  # Taps.\n  fespalier_push:\n    path: ../fespalier_push\n";
    let out = ok(
        text,
        &[Edit::insert(
            &["dependencies"],
            "fespalier_http",
            block(&["path: ../fespalier_http"]),
            Place::Sorted,
        )],
    );
    assert_eq!(
        out,
        "dependencies:\n  flutter:\n    sdk: flutter\n  fespalier:\n    path: ../fespalier\n  fespalier_http:\n    path: ../fespalier_http\n  # Taps.\n  fespalier_push:\n    path: ../fespalier_push\n"
    );
    let unsorted = "dependencies:\n  zeta: ^1.0.0\n  alpha: ^1.0.0\n# after\n";
    let out = ok(
        unsorted,
        &[Edit::insert(
            &["dependencies"],
            "beta",
            inline("^1.0.0"),
            Place::Sorted,
        )],
    );
    assert_eq!(
        out,
        "dependencies:\n  zeta: ^1.0.0\n  alpha: ^1.0.0\n  beta: ^1.0.0\n# after\n"
    );
}

#[test]
fn insert_makes_the_missing_parents_and_a_new_section_last() {
    let out = ok(
        CREATED,
        &[
            Edit::insert(&[], "fespalier", Body::Block(vec![]), Place::End)
                .with_comments(vec!["# Read by the `fsp` generator.".to_string()]),
            Edit::insert(&["fespalier"], "telemetry", inline("true"), Place::End),
            Edit::insert(&["fespalier", "test"], "skip", inline("[/a]"), Place::End)
                .with_comments(vec!["# /a needs a server.".to_string()]),
        ],
    );
    assert!(
        out.ends_with(
            "#     codegen: dart run build_runner build # fsp run codegen

# Read by the `fsp` generator.
fespalier:
  telemetry: true
  test:
    # /a needs a server.
    skip: [/a]
"
        ),
        "{out}"
    );
    // A pubspec without that section, and without a newline at its end.
    let out = ok(
        "name: a",
        &[Edit::insert(
            &["dependency_overrides"],
            "fespalier",
            block(&["path: ../fespalier"]),
            Place::Sorted,
        )],
    );
    assert_eq!(
        out,
        "name: a\n\ndependency_overrides:\n  fespalier:\n    path: ../fespalier\n"
    );
}

#[test]
fn insert_follows_the_files_indent_and_line_endings() {
    let text = "dependencies:\r\n    flutter:\r\n        sdk: flutter\r\n    fespalier:\r\n        path: ../f\r\n";
    let out = ok(
        text,
        &[Edit::insert(
            &["dependencies"],
            "fespalier_http",
            block(&["git:", "  url: u", "  ref: r"]),
            Place::Sorted,
        )],
    );
    assert_eq!(
        out,
        "dependencies:\r\n    flutter:\r\n        sdk: flutter\r\n    fespalier:\r\n        path: ../f\r\n    fespalier_http:\r\n        git:\r\n            url: u\r\n            ref: r\r\n"
    );
}

#[test]
fn insert_refuses_a_key_that_is_there_and_a_flow_mapping() {
    assert!(
        err(
            "dependencies:\n  a: ^1.0.0\n",
            &[Edit::insert(
                &["dependencies"],
                "a",
                inline("^2.0.0"),
                Place::End
            )]
        )
        .contains("`a` is already under `dependencies:`")
    );
    let flow = "dependencies: {a: ^1.0.0}\n";
    let e = apply(
        flow,
        &[Edit::insert(
            &["dependencies"],
            "b",
            inline("^1.0.0"),
            Place::End,
        )],
    )
    .unwrap_err();
    assert!(e.why.contains("written on one line"), "{}", e.why);
    assert_eq!(
        e.edit.by_hand(),
        "under `dependencies:` add:\n    b: ^1.0.0"
    );
}

// --- Append ------------------------------------------------------------------------------------

#[test]
fn append_adds_to_a_flow_list_a_block_list_or_makes_one() {
    let text =
        "fespalier:\n  test:\n    # /a why.\n    skip: [/a]\nflutter:\n  assets:\n    - a/\n";
    let out = ok(
        text,
        &[
            Edit::append(
                &["fespalier", "test", "skip"],
                "/b",
                Some("# /b why.".to_string()),
            ),
            Edit::append(&["flutter", "assets"], "assets/i18n/", None),
        ],
    );
    assert_eq!(
        out,
        "fespalier:\n  test:\n    # /a why.\n    # /b why.\n    skip: [/a, /b]\nflutter:\n  assets:\n    - a/\n    - assets/i18n/\n"
    );
    // The compact form, with the items at the key's own indent.
    let out = ok(
        "flutter:\n  assets:\n  - a/\nname: x\n",
        &[Edit::append(&["flutter", "assets"], "b/", None)],
    );
    assert_eq!(out, "flutter:\n  assets:\n  - a/\n  - b/\nname: x\n");
    let out = ok(
        "flutter:\n  uses-material-design: true\n",
        &[Edit::append(&["flutter", "assets"], "assets/i18n/", None)],
    );
    assert_eq!(
        out,
        "flutter:\n  uses-material-design: true\n  assets: [assets/i18n/]\n"
    );
    let out = ok("a:\n  b: []\n", &[Edit::append(&["a", "b"], "c", None)]);
    assert_eq!(out, "a:\n  b: [c]\n");
}

// --- Document markers and a byte order mark ----------------------------------------------------

const BODY: &str = "name: app
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.22.1
flutter:
  uses-material-design: true
";

/// A pubspec may start with `---` (yamllint asks for it), a `%YAML` directive or a byte order mark
/// before a comment: every kind of edit works on them, and the head stays. (A byte order mark
/// right before `---` or a key is not YAML to `serde_yaml_ng`, and `fsp` refuses the file at the
/// first read.)
#[test]
fn a_file_that_starts_with_a_marker_or_a_bom_takes_every_kind_of_edit() {
    let heads = [
        "---\n",
        "--- # the app\n",
        "%YAML 1.2\n---\n",
        "---\n# Comment.\n",
        "\u{feff}# Comment.\n",
    ];
    for head in heads {
        let text = format!("{head}{BODY}");
        assert_eq!(Doc::parse(&text).text(), text, "{head:?}");
        assert_eq!(
            Doc::parse(&text).keys(&[]).unwrap(),
            ["name", "dependencies", "flutter"],
            "{head:?}"
        );
        let out = apply(
            &text,
            &[
                Edit::set(&["dependencies", "fespalier", "git", "ref"], "v0.23.0"),
                Edit::insert(
                    &["dependencies"],
                    "fespalier_http",
                    block(&["git:", "  url: u", "  ref: v0.23.0"]),
                    Place::Sorted,
                ),
                Edit::insert(&[], "fespalier", block(&[]), Place::End)
                    .with_comments(vec!["# Read by fsp.".to_string()]),
                Edit::insert(&["fespalier"], "telemetry", inline("false"), Place::End),
                Edit::append(&["flutter", "assets"], "assets/", None),
            ],
        )
        .unwrap_or_else(|e| panic!("{head:?}: {e}"));
        assert!(out.starts_with(head), "{head:?}: {out}");
        assert_eq!(
            out[head.len()..],
            BODY.replace("v0.22.1", "v0.23.0")
                .replace(
                    "flutter:\n",
                    "  fespalier_http:\n    git:\n      url: u\n      ref: v0.23.0\nflutter:\n"
                )
                .replace(
                    "true\n",
                    "true\n  assets: [assets/]\n\n# Read by fsp.\nfespalier:\n  telemetry: false\n"
                ),
            "{head:?}"
        );
    }
}

/// A closing `...` is not part of the mapping: a section made last goes before it.
#[test]
fn a_section_made_last_goes_before_a_document_end_marker() {
    let text = format!("---\n{BODY}...\n");
    let out = ok(
        &text,
        &[Edit::insert(
            &[],
            "fespalier",
            block(&["telemetry: false"]),
            Place::End,
        )],
    );
    assert_eq!(
        out,
        format!("---\n{BODY}\nfespalier:\n  telemetry: false\n...\n")
    );
    // A line that only looks like a marker is a value, and the file is refused.
    let value = "--- text\nname: app\n";
    let e = err(value, &[Edit::insert(&[], "a", inline("1"), Place::End)]);
    assert!(e.contains("not valid YAML") || e.contains("not a"), "{e}");
}

/// The indent of a new section is the file's, not that of the continuation of a folded scalar, and
/// a file that is not a mapping is named by what it is.
#[test]
fn the_indent_comes_from_a_key_and_a_top_level_that_is_no_mapping_is_named() {
    let text = "name: app\ndescription: >-\n    A long text\n    folded.\ndependencies:\n  flutter:\n    sdk: flutter\n";
    let out = ok(
        text,
        &[Edit::insert(
            &[],
            "fespalier",
            block(&["telemetry: false"]),
            Place::End,
        )],
    );
    assert_eq!(out, format!("{text}\nfespalier:\n  telemetry: false\n"));
    assert_eq!(
        err(
            "- a\n- b\n",
            &[Edit::insert(&[], "k", inline("1"), Place::End)]
        ),
        "the top level of the file is not a mapping"
    );
}

// --- Every pubspec of the repository -----------------------------------------------------------

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// The pubspecs of the examples, the packages and the root workspace.
fn pubspecs() -> Vec<(String, String)> {
    let mut out: Vec<(String, PathBuf)> = vec![];
    let root = root();
    out.push(("pubspec.yaml".to_string(), root.join("pubspec.yaml")));
    for parent in ["examples", "packages"] {
        for entry in fs::read_dir(root.join(parent)).unwrap() {
            let dir = entry.unwrap().path();
            for path in [dir.join("pubspec.yaml"), dir.join("server/pubspec.yaml")] {
                if path.is_file() {
                    let rel = path.strip_prefix(&root).unwrap().display().to_string();
                    out.push((rel, path));
                }
            }
        }
    }
    let out: Vec<(String, String)> = out
        .into_iter()
        .filter(|(_, p)| p.is_file())
        .map(|(rel, p)| (rel, fs::read_to_string(p).unwrap()))
        .collect();
    assert!(out.len() >= 30, "{}", out.len());
    out
}

#[test]
fn every_pubspec_of_the_repository_reads_back_unchanged() {
    for (rel, text) in pubspecs() {
        assert_eq!(Doc::parse(&text).text(), text, "{rel}");
        assert_eq!(ok(&text, &[]), text, "{rel}");
    }
}

/// The edits `fsp add` makes, on every pubspec of the repository: each one is made, and the
/// result reads as the document with that change (which `apply` checks itself).
#[test]
fn every_pubspec_of_the_repository_takes_each_kind_of_edit() {
    for (rel, text) in pubspecs() {
        let value: Value = serde_yaml_ng::from_str(&text).unwrap();
        let has = |key: &str| value.get(key).is_some();
        let mut edits = vec![
            Edit::insert(
                &["dependencies"],
                "zzz_added",
                inline("^1.0.0"),
                Place::Sorted,
            ),
            Edit::insert(
                &["dependencies"],
                "aaa_added",
                block(&["git:", "  url: https://example.com/a", "  ref: main"]),
                Place::Sorted,
            ),
            Edit::insert(
                &["dev_dependencies"],
                "mmm_added",
                inline("^1.0.0"),
                Place::Sorted,
            ),
            Edit::append(
                &["fespalier", "test", "skip"],
                "/added",
                Some("# /added why.".to_string()),
            ),
            Edit::append(&["flutter", "assets"], "added/", None),
        ];
        if !has("dependencies") {
            edits.drain(..2);
        }
        let out = apply(&text, &edits).unwrap_or_else(|e| panic!("{rel}: {e}"));
        // What was there is still there, line for line: only lines were added.
        let mut lines = out.lines();
        for line in text.lines() {
            assert!(
                lines.any(|l| l == line),
                "{rel}: the line `{line}` is gone\n{out}"
            );
        }
    }
}

/// The keys the editor finds are the ones serde reads, at the top and one level down, in every
/// pubspec here: the line reader agrees with a YAML parser on real files.
#[test]
fn the_keys_the_editor_finds_are_the_ones_yaml_reads() {
    let names = |map: &serde_yaml_ng::Mapping| -> Vec<String> {
        map.keys()
            .map(|k| k.as_str().unwrap().to_string())
            .collect()
    };
    for (rel, text) in pubspecs() {
        let doc = Doc::parse(&text);
        let value: Value = serde_yaml_ng::from_str(&text).unwrap();
        let Value::Mapping(top) = &value else {
            panic!("{rel}")
        };
        assert_eq!(doc.keys(&[]), Some(names(top)), "{rel}");
        for (key, sub) in top {
            let key = key.as_str().unwrap();
            if let Value::Mapping(map) = sub {
                assert_eq!(doc.keys(&[key]), Some(names(map)), "{rel}: {key}");
            }
        }
    }
}

/// `fsp add` and `fsp upgrade --app` write both pubspec files or neither: when the second write
/// fails, the first file gets its text back (since 0.24.1). The writer here is a map of texts that
/// refuses the writes it is told to, so it fails whoever runs the test.
#[test]
fn a_failed_second_write_puts_the_first_back() {
    use std::cell::RefCell;
    use std::collections::BTreeMap;
    let (first, second) = (
        Path::new("app/pubspec_overrides.yaml"),
        Path::new("app/pubspec.yaml"),
    );
    let files = [
        Rewrite {
            path: first,
            before: "old overrides",
            after: "new overrides",
        },
        Rewrite {
            path: second,
            before: "old pubspec",
            after: "new pubspec",
        },
    ];
    let run = |refused: &[(&Path, &str)]| {
        let disk = RefCell::new(BTreeMap::from([
            (first.to_path_buf(), "old overrides".to_string()),
            (second.to_path_buf(), "old pubspec".to_string()),
        ]));
        let mut write = |path: &Path, text: &str| {
            if refused.contains(&(path, text)) {
                return Err(std::io::Error::other("refused"));
            }
            disk.borrow_mut()
                .insert(path.to_path_buf(), text.to_string());
            Ok(())
        };
        let result = write_files(&files, &mut write);
        let disk = disk.into_inner();
        (result, disk[first].clone(), disk[second].clone())
    };
    assert_eq!(
        run(&[]),
        (
            Ok(()),
            "new overrides".to_string(),
            "new pubspec".to_string()
        )
    );
    assert_eq!(
        run(&[(second, "new pubspec")]),
        (
            Err("writing app/pubspec.yaml: refused; app/pubspec_overrides.yaml was put back as it was read, so nothing was written".to_string()),
            "old overrides".to_string(),
            "old pubspec".to_string()
        )
    );
    assert_eq!(
        run(&[(first, "new overrides")]),
        (
            Err("writing app/pubspec_overrides.yaml: refused; nothing was written".to_string()),
            "old overrides".to_string(),
            "old pubspec".to_string()
        )
    );
    let (result, overrides, _) = run(&[(second, "new pubspec"), (first, "old overrides")]);
    assert_eq!(overrides, "new overrides");
    assert!(
        result.as_ref().unwrap_err().starts_with("writing app/pubspec.yaml: refused; and app/pubspec_overrides.yaml (refused) could not be put back as read, so it has the new text"),
        "{result:?}"
    );
}
