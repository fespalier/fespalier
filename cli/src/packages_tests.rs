//! `packages.rs`: the path packages, from the pubspecs alone (since 0.22.0).

use std::fs;
use std::path::Path;

use crate::packages::Packages;

/// Writes `files` (paths relative to a new folder) and returns the folder.
fn tree(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    for (rel, body) in files {
        let p = dir.path().join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// The names followed from `app/`, with each folder relative to the tree, `/` separated.
fn followed(dir: &Path) -> Vec<(String, String)> {
    let app = dir.join("app");
    let packages = Packages::read(&app, Some("app"));
    packages
        .names()
        .map(|name| {
            let root = packages.root(name).unwrap();
            let rel = root
                .strip_prefix(&app)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/");
            (name.to_string(), rel)
        })
        .collect()
}

fn named(name: &str) -> String {
    format!("name: {name}\n")
}

#[test]
fn a_path_under_dependencies_dev_dependencies_or_overrides_is_followed() {
    let dir = tree(&[
        (
            "app/pubspec.yaml",
            "name: app\ndependencies:\n  a:\n    path: ../a\n  h: ^1.0.0\n  g:\n    git:\n      url: https://example.com/g.git\n      path: packages/g\n  flutter:\n    sdk: flutter\n  o:\n    path: ../o\ndev_dependencies:\n  d:\n    path: ../d\ndependency_overrides:\n  h:\n    path: ../h\n  o: ^2.0.0\n",
        ),
        ("a/pubspec.yaml", &named("a")),
        ("d/pubspec.yaml", &named("d")),
        ("h/pubspec.yaml", &named("h")),
        ("o/pubspec.yaml", &named("o")),
    ]);
    // `h` is overridden with a path, `o` with a version: the override wins either way. A git
    // dependency's `path:` is in the repository, not on disk here.
    assert_eq!(
        followed(dir.path()),
        [
            ("a".into(), "../a".into()),
            ("d".into(), "../d".into()),
            ("h".into(), "../h".into())
        ]
    );
}

#[test]
fn the_overrides_of_pubspec_overrides_replace_those_of_the_pubspec() {
    let pubspec = "name: app\ndependencies:\n  a:\n    path: ../a1\n  b:\n    path: ../b1\ndependency_overrides:\n  b:\n    path: ../b2\n";
    let files = |overrides: &'static str| {
        let mut f = vec![
            ("app/pubspec.yaml", pubspec.to_string()),
            ("a1/pubspec.yaml", named("a")),
            ("a2/pubspec.yaml", named("a")),
            ("b1/pubspec.yaml", named("b")),
            ("b2/pubspec.yaml", named("b")),
        ];
        if !overrides.is_empty() {
            f.push(("app/pubspec_overrides.yaml", overrides.to_string()));
        }
        f
    };
    let run = |overrides: &'static str| {
        let f = files(overrides);
        let f: Vec<(&str, &str)> = f.iter().map(|(p, s)| (*p, s.as_str())).collect();
        followed(tree(&f).path())
    };
    let pair = |a: &str, b: &str| {
        vec![
            ("a".to_string(), a.to_string()),
            ("b".to_string(), b.to_string()),
        ]
    };
    // As pub 3.13.5 reads them: the file's `dependency_overrides`, when it has the key, replace the
    // pubspec's whole section; a file without the key leaves the pubspec's.
    assert_eq!(run(""), pair("../a1", "../b2"));
    assert_eq!(
        run("dependency_overrides:\n  a:\n    path: ../a2\n"),
        pair("../a2", "../b1")
    );
    assert_eq!(run("dependency_overrides:\n"), pair("../a1", "../b1"));
    assert_eq!(run("# nothing\n"), pair("../a1", "../b2"));
}

#[test]
fn a_path_dependency_of_a_path_dependency_is_followed_from_its_folder() {
    let dir = tree(&[
        (
            "app/pubspec.yaml",
            "name: app\ndependencies:\n  shared:\n    path: ../pk/shared\n",
        ),
        (
            "pk/shared/pubspec.yaml",
            "name: shared\ndependencies:\n  deep:\n    path: ../deep\ndev_dependencies:\n  tool:\n    path: ../tool\ndependency_overrides:\n  other:\n    path: ../other\n",
        ),
        (
            "pk/deep/pubspec.yaml",
            "name: deep\ndependencies:\n  app:\n    path: ../../app\n  shared:\n    path: ../shared\n",
        ),
        ("pk/tool/pubspec.yaml", &named("tool")),
        ("pk/other/pubspec.yaml", &named("other")),
    ]);
    // Its dev_dependencies and overrides are not the app's (pub ignores them), and the cycle back to
    // the app and to `shared` ends.
    assert_eq!(
        followed(dir.path()),
        [
            ("deep".into(), "../pk/shared/../deep".into()),
            ("shared".into(), "../pk/shared".into())
        ]
    );
}

#[test]
fn a_name_the_app_lists_is_decided_by_the_app() {
    let dir = tree(&[
        (
            "app/pubspec.yaml",
            "name: app\ndependencies:\n  shared:\n    path: ../shared\n  deep: ^1.0.0\n",
        ),
        (
            "shared/pubspec.yaml",
            "name: shared\ndependencies:\n  deep:\n    path: ../deep\n  twice:\n    path: ../t1\n  more:\n    path: ../more\n",
        ),
        (
            "more/pubspec.yaml",
            "name: more\ndependencies:\n  twice:\n    path: ../t2\n",
        ),
        ("deep/pubspec.yaml", &named("deep")),
        ("t1/pubspec.yaml", &named("twice")),
        ("t2/pubspec.yaml", &named("twice")),
    ]);
    // `deep` is a hosted dependency of the app; `twice` takes the first path, breadth first.
    let got = followed(dir.path());
    assert_eq!(
        got,
        [
            ("more".into(), "../shared/../more".into()),
            ("shared".into(), "../shared".into()),
            ("twice".into(), "../shared/../t1".into())
        ]
    );
}

#[test]
fn a_folder_without_its_pubspec_or_of_another_name_is_not_followed() {
    let dir = tree(&[
        (
            "app/pubspec.yaml",
            "name: app\ndependencies:\n  gone:\n    path: ../gone\n  bare:\n    path: ../bare\n  renamed:\n    path: ../renamed\n  broken:\n    path: ../broken\n",
        ),
        ("bare/lib/x.dart", "class X {}\n"),
        (
            "renamed/pubspec.yaml",
            "name: common\ndependencies:\n  inner:\n    path: ../inner\n",
        ),
        ("broken/pubspec.yaml", "name: [broken\n"),
        ("inner/pubspec.yaml", &named("inner")),
    ]);
    // Pub refuses each of them; fsp follows none, nor what they list.
    assert_eq!(followed(dir.path()), Vec::<(String, String)>::new());
}

#[test]
fn no_pubspec_or_a_broken_one_has_no_path_package() {
    let dir = tree(&[("app/lib/x.dart", "class X {}\n")]);
    assert_eq!(followed(dir.path()), Vec::<(String, String)>::new());
    let dir = tree(&[("app/pubspec.yaml", "name: app\ndependencies: [\n")]);
    assert_eq!(followed(dir.path()), Vec::<(String, String)>::new());
}
