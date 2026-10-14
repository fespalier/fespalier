//! The warning that `build_runner` can delete a generated `X.g.dart` that has an `X.dart` beside
//! it (`build_runner.rs`, since 0.16.0): when it fires, what it says, and that it is a warning
//! `gen`, `check` and `watch` show without failing.

use std::fs;
use std::path::Path;

use crate::build_runner;
use crate::config::{Config, Pubspec};
use crate::session::Session;

/// The warning for the default output, exactly: `skills/fespalier-troubleshooting` quotes it.
const DEFAULT: &str = "`build_runner` can delete `lib/app.g.dart`: `lib/app.dart` exists, so the builders that write `.g.dart` files (json_serializable, riverpod_generator, ...) claim that path as an output of theirs, and `dart run build_runner build` removes the file `fsp` wrote; set `fespalier: output:` in pubspec.yaml to another file (for example `lib/routes.g.dart`), or rename `lib/app.dart`";

fn write(root: &Path, rel: &str, body: &str) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, body).unwrap();
}

/// A project with one page, `pubspec` as its pubspec.yaml and the given extra files.
fn project(pubspec: &str, files: &[&str]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), "pubspec.yaml", pubspec);
    write(
        dir.path(),
        "lib/app/page.dart",
        "class HomePage extends StatelessWidget { const HomePage({super.key}); }",
    );
    for f in files {
        write(dir.path(), f, "// yours\n");
    }
    dir
}

/// A pubspec with `build_runner` as a dev dependency, and `extra` after it.
fn with_runner(extra: &str) -> String {
    format!("name: demo\ndev_dependencies:\n  build_runner: ^2.4.0\n{extra}")
}

/// What `gen` shows for the project, one line per diagnostic, and whether it succeeded.
fn shown(dir: &Path, write: bool) -> (bool, Vec<String>) {
    let cfg = Config::load(dir).unwrap();
    let mut lines = vec![];
    let result = crate::gen_core(dir, &cfg, write, &mut Session::default(), |_, d| {
        lines = d.0.iter().map(ToString::to_string).collect();
    });
    (result.is_ok(), lines)
}

fn warnings(dir: &Path) -> Vec<String> {
    let cfg = Config::load(dir).unwrap();
    let outputs = vec![cfg.output.clone()];
    build_runner::check(dir, &cfg, &outputs)
        .0
        .into_iter()
        .map(|d| d.msg)
        .collect()
}

#[test]
fn build_runner_is_read_from_dependencies_and_dev_dependencies() {
    let read = |yaml: &str| Pubspec::parse(yaml).unwrap().config.build_runner;
    assert!(read("name: a\ndev_dependencies:\n  build_runner: ^2.4.0\n"));
    assert!(read("name: a\ndependencies:\n  build_runner: any\n"));
    assert!(read(
        "name: a\ndev_dependencies:\n  build_runner:\n    git: https://example.com/b\n"
    ));
    assert!(!read("name: a\n"));
    assert!(!read("name: a\ndev_dependencies:\n  freezed: ^3.0.0\n"));
    // The name of a package, not any text with it in.
    assert!(!read("name: a\ndev_dependencies:\n  build_runner_x: any\n"));
    assert!(!Pubspec::parse("").unwrap().config.build_runner);
}

#[test]
fn a_dart_file_beside_the_output_is_warned_about_with_build_runner() {
    let dir = project(&with_runner(""), &["lib/app.dart"]);
    assert_eq!(warnings(dir.path()), [DEFAULT]);
}

#[test]
fn nothing_is_said_without_build_runner() {
    let dir = project("name: demo\n", &["lib/app.dart"]);
    assert!(warnings(dir.path()).is_empty());
}

#[test]
fn nothing_is_said_without_the_dart_file() {
    let dir = project(&with_runner(""), &["lib/main.dart", "lib/application.dart"]);
    assert!(warnings(dir.path()).is_empty());
}

#[test]
fn the_dart_file_must_be_a_file() {
    let dir = project(&with_runner(""), &[]);
    fs::create_dir_all(dir.path().join("lib/app.dart")).unwrap();
    assert!(warnings(dir.path()).is_empty());
}

#[test]
fn an_output_in_another_place_is_safe() {
    // The way out the warning names.
    let dir = project(
        &with_runner("fespalier:\n  output: lib/routes.g.dart\n"),
        &["lib/app.dart"],
    );
    assert!(warnings(dir.path()).is_empty());
    // Not a `.g.dart`: build_runner has no output there.
    let dir = project(
        &with_runner("fespalier:\n  output: lib/app.routes.dart\n"),
        &["lib/app.dart", "lib/app.routes.dart"],
    );
    assert!(warnings(dir.path()).is_empty());
}

#[test]
fn a_custom_output_is_warned_about_by_its_own_name() {
    let dir = project(
        &with_runner("fespalier:\n  output: lib/router/app_router.g.dart\n"),
        &["lib/router/app_router.dart"],
    );
    let w = warnings(dir.path());
    assert_eq!(w.len(), 1, "{w:?}");
    assert!(
        w[0].starts_with(
            "`build_runner` can delete `lib/router/app_router.g.dart`: `lib/router/app_router.dart` exists"
        ),
        "{}",
        w[0]
    );
    // The suggestion is in the folder of the output.
    assert!(
        w[0].contains(
            "(for example `lib/router/routes.g.dart`), or rename `lib/router/app_router.dart`"
        ),
        "{}",
        w[0]
    );
}

#[test]
fn the_suggested_name_is_one_with_no_dart_file_beside_it() {
    let dir = project(&with_runner(""), &["lib/app.dart", "lib/routes.dart"]);
    let w = warnings(dir.path());
    assert!(
        w[0].contains("(for example `lib/app_routes.g.dart`)"),
        "{}",
        w[0]
    );
}

#[test]
fn the_manifest_and_the_generated_main_are_checked_too() {
    let dir = project(
        &with_runner("fespalier:\n  output_manifest: lib/app.routes.g.dart\n"),
        &["lib/app.routes.dart", "lib/app.main.dart"],
    );
    let cfg = Config::load(dir.path()).unwrap();
    let outputs = vec![
        cfg.output.clone(),
        "lib/app.routes.g.dart".to_string(),
        cfg.output_main(),
    ];
    let w: Vec<String> = build_runner::check(dir.path(), &cfg, &outputs)
        .0
        .into_iter()
        .map(|d| d.msg)
        .collect();
    assert_eq!(w.len(), 2, "{w:?}");
    // The manifest has a key of its own.
    assert!(
        w[0].starts_with(
            "`build_runner` can delete `lib/app.routes.g.dart`: `lib/app.routes.dart` exists"
        ) && w[0].contains("set `fespalier: output_manifest:` in pubspec.yaml")
            && w[0].contains("(for example `lib/app.manifest.g.dart`)"),
        "{}",
        w[0]
    );
    // The main() follows `output`.
    assert!(
        w[1].starts_with(
            "`build_runner` can delete `lib/app.main.g.dart`: `lib/app.main.dart` exists"
        ) && w[1].contains("set `fespalier: output:` in pubspec.yaml"),
        "{}",
        w[1]
    );
}

#[test]
fn it_is_a_warning_on_the_dart_file_and_gen_and_check_still_succeed() {
    let dir = project(&with_runner(""), &["lib/app.dart"]);
    for write in [true, false] {
        let (ok, lines) = shown(dir.path(), write);
        assert!(ok);
        assert_eq!(lines, [format!("! lib/app.dart  {DEFAULT}")]);
    }
    // `gen` wrote the file the warning is about.
    assert!(dir.path().join("lib/app.g.dart").is_file());
}

#[test]
fn it_is_shown_when_the_tree_has_errors_too() {
    let dir = project(&with_runner(""), &["lib/app.dart"]);
    write(dir.path(), "lib/app/broken/page.dart", "// no widget here");
    let (ok, lines) = shown(dir.path(), true);
    assert!(!ok);
    assert!(
        lines.iter().any(|l| l.starts_with("✗ broken/page.dart")),
        "{lines:?}"
    );
    assert!(
        lines.contains(&format!("! lib/app.dart  {DEFAULT}")),
        "{lines:?}"
    );
}

#[test]
fn a_watch_pass_with_the_same_files_says_it_again_only_as_the_same_text() {
    // `watch` prints diagnostics when their text changes, so the warning is shown once and
    // an unchanged pass stays quiet: the text of two passes is equal.
    let dir = project(&with_runner(""), &["lib/app.dart"]);
    let cfg = Config::load(dir.path()).unwrap();
    let mut session = Session::default();
    let mut texts = vec![];
    for _ in 0..2 {
        crate::gen_core(dir.path(), &cfg, true, &mut session, |_, d| {
            texts.push(
                d.0.iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("\n"),
            );
        })
        .unwrap();
    }
    assert_eq!(texts.len(), 2);
    assert_eq!(texts[0], texts[1]);
    assert!(texts[0].contains("build_runner"), "{}", texts[0]);
    // And when the file is renamed the warning goes.
    fs::rename(
        dir.path().join("lib/app.dart"),
        dir.path().join("lib/root.dart"),
    )
    .unwrap();
    crate::gen_core(dir.path(), &cfg, true, &mut session, |_, d| {
        assert!(d.0.is_empty(), "{:?}", d.0);
    })
    .unwrap();
}

#[test]
fn the_json_diagnostic_names_the_dart_file_and_has_no_line() {
    let dir = project(&with_runner(""), &["lib/app.dart"]);
    let cfg = Config::load(dir.path()).unwrap();
    let diags = build_runner::check(dir.path(), &cfg, std::slice::from_ref(&cfg.output));
    let v: serde_json::Value = serde_json::from_str(&crate::diag::json_line(
        &dir.path().join("lib/app"),
        "lib/app",
        &diags.0[0],
    ))
    .unwrap();
    assert_eq!(v["file"], "lib/app.dart");
    assert_eq!(v["severity"], "warning");
    assert!(v["line"].is_null() && v["column"].is_null());
    assert_eq!(v["message"], DEFAULT);
}

/// What the way out that is not in the warning looks like.
const EXCLUDED: &str = "targets:
  $default:
    builders:
      source_gen:combining_builder:
        generate_for:
          exclude:
            - lib/app.dart
";

#[test]
fn a_build_yaml_that_keeps_the_file_out_of_the_combining_builder_is_respected() {
    let dir = project(&with_runner(""), &["lib/app.dart"]);
    write(dir.path(), "build.yaml", EXCLUDED);
    assert!(warnings(dir.path()).is_empty());
    // Only that file, only that builder: the rest still warns.
    for build_yaml in [
        // another file
        EXCLUDED.replace("lib/app.dart", "lib/other.dart"),
        // another builder
        EXCLUDED.replace("source_gen:combining_builder", "json_serializable"),
        // `include:` says what runs, not what is left out
        EXCLUDED.replace("exclude", "include"),
        // a glob: not read
        EXCLUDED.replace("lib/app.dart", "lib/app*.dart"),
        // not YAML, or not the shape
        "targets: [".to_string(),
        "targets: nothing".to_string(),
        String::new(),
    ] {
        write(dir.path(), "build.yaml", &build_yaml);
        assert_eq!(warnings(dir.path()), [DEFAULT], "{build_yaml}");
    }
}

/// The warning is quoted word for word where a reader looks it up: the troubleshooting skill's
/// page for the `fespalier:` section and the CLI reference. A changed message has to change both.
#[test]
fn the_skill_and_the_docs_quote_the_warning_exactly() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    for page in [
        "skills/fespalier-troubleshooting/references/diagnostics-config-and-meta.md",
        "docs/cli.md",
    ] {
        let text = fs::read_to_string(repo.join(page)).unwrap();
        assert!(
            text.contains(DEFAULT),
            "{page} no longer quotes the build_runner warning exactly; update it with build_runner.rs"
        );
    }
}
