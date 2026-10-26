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

/// The names followed from `app/`, with each folder relative to the tree, `/` separated. A folder is
/// read as pub reads it, its `..` resolved in the text, so it is under the tree.
fn followed(dir: &Path) -> Vec<(String, String)> {
    let packages = Packages::read(&dir.join("app"), Some("app"));
    packages
        .names()
        .map(|name| {
            let root = packages.root(name).unwrap();
            let rel = root
                .strip_prefix(dir)
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
            ("a".into(), "a".into()),
            ("d".into(), "d".into()),
            ("h".into(), "h".into())
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
    assert_eq!(run(""), pair("a1", "b2"));
    assert_eq!(
        run("dependency_overrides:\n  a:\n    path: ../a2\n"),
        pair("a2", "b1")
    );
    assert_eq!(run("dependency_overrides:\n"), pair("a1", "b1"));
    assert_eq!(run("# nothing\n"), pair("a1", "b2"));
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
            ("deep".into(), "pk/deep".into()),
            ("shared".into(), "pk/shared".into())
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
            ("more".into(), "more".into()),
            ("shared".into(), "shared".into()),
            ("twice".into(), "t1".into())
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

#[test]
fn dot_segments_are_resolved_in_the_text() {
    let dir = tree(&[
        (
            "app/pubspec.yaml",
            "name: app\ndependencies:\n  a:\n    path: ./x/../../a\n  b:\n    path: ../sub/./b/\n  c:\n    path: sub/../../c\n",
        ),
        ("a/pubspec.yaml", &named("a")),
        ("sub/b/pubspec.yaml", &named("b")),
        ("c/pubspec.yaml", &named("c")),
    ]);
    assert_eq!(
        followed(dir.path()),
        [
            ("a".into(), "a".into()),
            ("b".into(), "sub/b".into()),
            ("c".into(), "c".into())
        ]
    );
}

/// Pub joins a `path:` to the folder of the pubspec that lists it and normalizes the text, so
/// `../deep` from `links/shared`, a symlink to `real/shared`, is `links/deep`. The file system would
/// say `real/deep` (a `..` follows the link it climbs out of). Fails when the path is not normalized
/// first: `deep` is then the one in `real/` and `leaf` is not followed.
#[cfg(unix)]
#[test]
fn a_dot_dot_after_a_symlinked_dependency_is_not_resolved_through_the_link() {
    let dir = tree(&[
        (
            "app/pubspec.yaml",
            "name: app\ndependencies:\n  shared:\n    path: ../links/shared\n",
        ),
        (
            "real/shared/pubspec.yaml",
            "name: shared\ndependencies:\n  deep:\n    path: ../deep\n",
        ),
        (
            "links/deep/pubspec.yaml",
            "name: deep\ndependencies:\n  leaf:\n    path: ../leaf\n",
        ),
        ("links/leaf/pubspec.yaml", &named("leaf")),
        ("real/deep/pubspec.yaml", &named("deep")),
    ]);
    std::os::unix::fs::symlink("../real/shared", dir.path().join("links/shared")).unwrap();
    assert_eq!(
        followed(dir.path()),
        [
            ("deep".into(), "links/deep".into()),
            ("leaf".into(), "links/leaf".into()),
            ("shared".into(), "links/shared".into())
        ]
    );
}

/// The folders of `shared`, `deep` and the like in a workspace: the root is the tree itself.
fn workspace(root: &str, app: &str, extra: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut files = vec![
        ("pubspec.yaml", root),
        ("app/pubspec.yaml", app),
        ("s1/pubspec.yaml", "name: shared\n"),
        ("s2/pubspec.yaml", "name: shared\n"),
        ("s3/pubspec.yaml", "name: shared\n"),
    ];
    files.extend_from_slice(extra);
    followed(tree(&files).path())
}

fn shared(rel: &str) -> Vec<(String, String)> {
    vec![("shared".into(), rel.into())]
}

const MEMBER: &str =
    "name: app\nresolution: workspace\ndependencies:\n  shared:\n    path: ../s1\n";
const ROOT: &str = "name: root\nworkspace:\n  - app\n";

/// Pub applies the `dependency_overrides` of the workspace root to every member, its folder being the
/// root's (each rule checked with `dart pub get --offline`, Dart 3.13.5).
#[test]
fn the_overrides_of_the_workspace_root_apply_to_a_member() {
    let root = |overrides: &str| format!("{ROOT}dependency_overrides:\n{overrides}");
    // The root's override replaces the member's source for the name, relative to the root.
    assert_eq!(
        workspace(&root("  shared:\n    path: s2\n"), MEMBER, &[]),
        shared("s2")
    );
    // A version replaces it too: then nothing is followed.
    assert_eq!(
        workspace(&root("  shared: ^1.0.0\n"), MEMBER, &[]),
        Vec::<(String, String)>::new()
    );
    // A name the member lists with a version becomes a path.
    let hosted = "name: app\nresolution: workspace\ndependencies:\n  shared: any\n";
    assert_eq!(
        workspace(&root("  shared:\n    path: s3\n"), hosted, &[]),
        shared("s3")
    );
    // It reaches a package only a path dependency lists.
    let deep = "name: app\nresolution: workspace\ndependencies:\n  shared:\n    path: ../s1\n";
    let files = [
        (
            "s1/pubspec.yaml",
            "name: shared\ndependencies:\n  deep:\n    path: ../d1\n",
        ),
        ("d1/pubspec.yaml", "name: deep\n"),
        ("d2/pubspec.yaml", "name: deep\n"),
    ];
    assert_eq!(
        workspace(&root("  deep:\n    path: d2\n"), deep, &files),
        [("deep".into(), "d2".into()), ("shared".into(), "s1".into())]
    );
}

#[test]
fn the_workspace_roots_pubspec_overrides_file_replaces_its_section() {
    let root = format!("{ROOT}dependency_overrides:\n  shared:\n    path: s2\n");
    let run = |file: &str| workspace(&root, MEMBER, &[("pubspec_overrides.yaml", file)]);
    // As for the app's own: the key replaces the pubspec's whole section (an empty key: none), a file
    // without the key leaves it.
    assert_eq!(
        run("dependency_overrides:\n  shared:\n    path: s3\n"),
        shared("s3")
    );
    assert_eq!(run("dependency_overrides:\n"), shared("s1"));
    assert_eq!(run("# nothing\n"), shared("s2"));
}

#[test]
fn the_overrides_of_a_workspace_root_need_resolution_workspace_and_a_root() {
    let root = format!("{ROOT}dependency_overrides:\n  shared:\n    path: s2\n");
    // Not a member: pub resolves the app on its own, and so does fsp.
    let alone = "name: app\ndependencies:\n  shared:\n    path: ../s1\n";
    assert_eq!(workspace(&root, alone, &[]), shared("s1"));
    // A member with no root above it (pub refuses it): nothing to apply.
    assert_eq!(workspace("name: root\n", MEMBER, &[]), shared("s1"));
}

/// pub reads `resolution` and `workspace` from `pubspec_overrides.yaml` too, in place of the
/// pubspec's when the file has the key, even with no value (since 0.24.1; each rule checked with
/// `dart pub get --offline` on Dart 3.13.5 and on the floor's 3.9.2).
#[test]
fn resolution_and_workspace_are_read_from_pubspec_overrides_too() {
    let root = format!("{ROOT}dependency_overrides:\n  shared:\n    path: s2\n");
    let alone = "name: app\ndependencies:\n  shared:\n    path: ../s1\n";
    let file = |body| [("app/pubspec_overrides.yaml", body)];
    // A member by its file alone: pub resolves it at the root, with the root's overrides.
    assert_eq!(
        workspace(&root, alone, &file("resolution: workspace\n")),
        shared("s2")
    );
    // `resolution:` with no value there makes a member by its pubspec resolve on its own.
    assert_eq!(
        workspace(&root, MEMBER, &file("resolution:\n")),
        shared("s1")
    );
    // A file without the key leaves the pubspec's in force, either way.
    let other = "dependency_overrides:\n  other:\n    path: ../o\n";
    assert_eq!(workspace(&root, MEMBER, &file(other)), shared("s2"));
    assert_eq!(workspace(&root, alone, &file(other)), shared("s1"));
    // A root whose `workspace:` is in its file alone is the root.
    let bare = "name: root\ndependency_overrides:\n  shared:\n    path: s2\n";
    let listed = [("pubspec_overrides.yaml", "workspace:\n  - app\n")];
    assert_eq!(workspace(bare, MEMBER, &listed), shared("s2"));
}

/// A `workspace:` with no value, or `[]`, lists no member: pub finds no root in that folder, in its
/// pubspec or in its `pubspec_overrides.yaml` (which takes the place of the pubspec's key even
/// then), so the app has none and the overrides of that folder are not applied (since 0.24.1; each
/// case checked with `dart pub get --offline` on Dart 3.13.5 and on the floor's 3.9.2: "found no
/// workspace root including it").
#[test]
fn a_workspace_key_with_no_member_is_no_root() {
    let root = format!("{ROOT}dependency_overrides:\n  shared:\n    path: s2\n");
    let bare = "name: root\ndependency_overrides:\n  shared:\n    path: s2\n";
    let in_file = |body| [("pubspec_overrides.yaml", body)];
    // The root's file lists nobody, over a pubspec that lists the app or has no `workspace:` at all.
    for body in ["workspace:\n", "workspace: []\n"] {
        assert_eq!(
            workspace(&root, MEMBER, &in_file(body)),
            shared("s1"),
            "{body:?}"
        );
        assert_eq!(
            workspace(bare, MEMBER, &in_file(body)),
            shared("s1"),
            "{body:?}"
        );
    }
    // As does the pubspec's own key.
    for key in ["workspace:\n", "workspace: []\n"] {
        let root = format!("name: root\n{key}dependency_overrides:\n  shared:\n    path: s2\n");
        assert_eq!(workspace(&root, MEMBER, &[]), shared("s1"), "{key:?}");
    }
    // A file that lists the app makes the root again, whatever the pubspec says.
    let listed = in_file("workspace:\n  - app\n");
    assert_eq!(workspace(bare, MEMBER, &listed), shared("s2"));
    let empty = "name: root\nworkspace: []\ndependency_overrides:\n  shared:\n    path: s2\n";
    assert_eq!(workspace(empty, MEMBER, &listed), shared("s2"));
}

/// The root of a nested workspace is the outermost: the pubspec in between is a member itself, and
/// so is one whose `pubspec_overrides.yaml` says `resolution: workspace` (since 0.24.1).
#[test]
fn a_member_by_its_pubspec_overrides_is_not_the_root_of_a_nested_workspace() {
    let dir = tree(&[
        (
            "pubspec.yaml",
            "name: root\nworkspace:\n  - mid\ndependency_overrides:\n  shared:\n    path: s2\n",
        ),
        ("mid/pubspec.yaml", "name: mid\nworkspace:\n  - app\n"),
        ("mid/pubspec_overrides.yaml", "resolution: workspace\n"),
        (
            "mid/app/pubspec.yaml",
            "name: app\nresolution: workspace\ndependencies:\n  shared:\n    path: ../../s1\n",
        ),
        ("s1/pubspec.yaml", "name: shared\n"),
        ("s2/pubspec.yaml", "name: shared\n"),
    ]);
    let packages = Packages::read(&dir.path().join("mid/app"), Some("app"));
    let at = packages.root("shared").unwrap();
    assert_eq!(at.strip_prefix(dir.path()).unwrap(), Path::new("s2"));
}

/// The root of a nested workspace is the outermost: the pubspec in between is a member itself.
#[test]
fn the_root_of_a_nested_workspace_is_the_outermost() {
    let dir = tree(&[
        (
            "pubspec.yaml",
            "name: root\nworkspace:\n  - mid\ndependency_overrides:\n  shared:\n    path: s2\n",
        ),
        (
            "mid/pubspec.yaml",
            "name: mid\nresolution: workspace\nworkspace:\n  - app\n",
        ),
        (
            "mid/app/pubspec.yaml",
            "name: app\nresolution: workspace\ndependencies:\n  shared:\n    path: ../../s1\n",
        ),
        ("s1/pubspec.yaml", "name: shared\n"),
        ("s2/pubspec.yaml", "name: shared\n"),
    ]);
    let packages = Packages::read(&dir.path().join("mid/app"), Some("app"));
    let at = packages.root("shared").unwrap();
    assert_eq!(at.strip_prefix(dir.path()).unwrap(), Path::new("s2"));
}

/// What is not read: the overrides written in another member's pubspec (pub applies them to the
/// whole workspace, `Known limitations` says to write them in the root).
#[test]
fn the_overrides_of_another_member_are_not_read() {
    let root = "name: root\nworkspace:\n  - app\n  - other\n";
    let other = (
        "other/pubspec.yaml",
        "name: other\nresolution: workspace\ndependency_overrides:\n  shared:\n    path: ../s2\n",
    );
    assert_eq!(workspace(root, MEMBER, &[other]), shared("s1"));
}
