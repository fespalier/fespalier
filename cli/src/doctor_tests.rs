//! `fsp doctor` (since 0.23.0): the rows each fact makes. Projects are written to a temporary
//! folder and read with [`doctor::gather`]; `flutter --version --machine` is given as text.

use std::fs;
use std::path::Path;

use crate::doctor::{self, Facts, Row, Section, Status, Toolchain};
use crate::upgrade::Version;

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

/// What `flutter --version --machine` prints, for one Flutter and one Dart.
fn flutter(framework: &str, dart: &str) -> Result<String, String> {
    Ok(format!(
        "{{\n  \"frameworkVersion\": \"{framework}\",\n  \"channel\": \"stable\",\n  \"dartSdkVersion\": \"{dart}\"\n}}\n"
    ))
}

fn this_fsp() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// A git dependency on this repository at `git_ref`.
fn git(git_ref: &str) -> String {
    format!("\n    git:\n      url: https://github.com/fespalier/fespalier\n      ref: {git_ref}")
}

/// A project with this pubspec and these files (relative to the project), read by the doctor.
fn facts(pubspec: &str, files: &[(&str, &str)], toolchain: Result<String, String>) -> Facts {
    let dir = tempfile::tempdir().unwrap();
    write(dir.path(), pubspec, files);
    doctor::gather(dir.path(), toolchain)
}

/// A project with this pubspec and no `lib/` at all.
fn facts_without_app(pubspec: &str) -> Facts {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), pubspec).unwrap();
    doctor::gather(dir.path(), Err("no".into()))
}

fn write(root: &Path, pubspec: &str, files: &[(&str, &str)]) {
    fs::write(root.join("pubspec.yaml"), pubspec).unwrap();
    fs::create_dir_all(root.join("lib/app")).unwrap();
    fs::write(root.join("lib/app/page.dart"), HOME).unwrap();
    for (file, text) in files {
        let path = root.join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
}

/// The rows of `check` (and `subject`, when given), as `status: message`.
fn of(rows: &[Row], check: &str, subject: Option<&str>) -> Vec<String> {
    rows.iter()
        .filter(|r| r.check == check && (subject.is_none() || r.subject.as_deref() == subject))
        .map(|r| format!("{}: {}", r.status.name(), r.message))
        .collect()
}

fn one(rows: &[Row], check: &str, subject: Option<&str>) -> String {
    let found = of(rows, check, subject);
    assert_eq!(found.len(), 1, "{check} {subject:?}: {found:?}");
    found[0].clone()
}

fn statuses(rows: &[Row], status: Status) -> Vec<String> {
    rows.iter()
        .filter(|r| r.status == status)
        .map(|r| format!("{} {}", r.check, r.message))
        .collect()
}

#[test]
fn flutter_version_machine_reads_as_flutter_and_dart() {
    let t = Toolchain::parse(&flutter("3.47.7", "3.13.5").unwrap()).unwrap();
    assert_eq!(t.flutter, Version(3, 47, 7));
    assert_eq!(t.dart, Version(3, 13, 5));
    assert!(!t.flutter_pre);
    // A notice before the JSON, a pre-release and Dart's build suffix.
    let t = Toolchain::parse(
        "Waiting for another flutter command to release the startup lock...\n{\"frameworkVersion\": \"3.38.0-0.1.pre\", \"dartSdkVersion\": \"3.10.0 (build 3.10.0-290.4.beta)\"}",
    )
    .unwrap();
    assert_eq!(t.flutter, Version(3, 38, 0));
    assert_eq!(t.dart, Version(3, 10, 0));
    assert!(t.flutter_pre);
    assert_eq!(Toolchain::parse("Flutter 3.35.0"), None);
    assert_eq!(Toolchain::parse("{\"frameworkVersion\": \"x\"}"), None);
}

/// The floors and the `go_router` range are fespalier's own pubspec's, and the companions that claim
/// a newer Flutter are listed with what they claim.
#[test]
fn the_floors_are_the_packages_own() {
    let packages = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packages");
    let pubspec = |name: &str| -> serde_yaml_ng::Value {
        serde_yaml_ng::from_str(
            &fs::read_to_string(packages.join(name).join("pubspec.yaml")).unwrap(),
        )
        .unwrap()
    };
    let core = pubspec("fespalier");
    let text = |v: &serde_yaml_ng::Value| v.as_str().unwrap().to_string();
    assert_eq!(
        text(&core["environment"]["flutter"]),
        format!(">={}", doctor::versions::FLUTTER_FLOOR)
    );
    assert_eq!(
        text(&core["environment"]["sdk"]),
        format!("^{}", doctor::versions::DART_FLOOR)
    );
    let (low, high) = doctor::versions::GO_ROUTER;
    assert_eq!(
        text(&core["dependencies"]["go_router"]),
        format!(">={low} <{high}")
    );
    let mut newer = vec![];
    for entry in fs::read_dir(&packages).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !entry.path().join("pubspec.yaml").is_file() {
            continue;
        }
        let p = pubspec(&name);
        let Some(claim) = p["environment"]["flutter"].as_str() else {
            continue;
        };
        let floor = Version::parse(claim.trim_start_matches(">=")).unwrap();
        if floor > doctor::versions::FLUTTER_FLOOR && name != "fespalier_devtools" {
            newer.push((name, floor));
        }
    }
    newer.sort();
    let table: Vec<(String, Version)> = doctor::versions::NEWER_FLUTTER
        .iter()
        .map(|(n, v)| ((*n).to_string(), *v))
        .collect();
    assert_eq!(
        table, newer,
        "NEWER_FLUTTER in doctor/versions.rs, sorted by name"
    );
}

/// An app on this fsp's release, its companions at the same url and ref, a lock that resolved them
/// and a `go_router` fespalier supports, and a Flutter above the floor: nothing out of line.
#[test]
fn an_app_in_line_has_no_error_and_no_warning() {
    let v = this_fsp();
    let pubspec = format!(
        "name: shop\ndependencies:\n  flutter:\n    sdk: flutter\n  fespalier:{}\n  fespalier_push:{}\nfespalier:\n  adapters: [fespalier_push]\n",
        git(&format!("v{v}")),
        git(&format!("v{v}"))
    );
    let lock = format!(
        "packages:\n  fespalier:\n    source: git\n    version: \"{v}\"\n  fespalier_push:\n    source: git\n    version: \"{v}\"\n  go_router:\n    source: hosted\n    version: \"17.3.0\"\n"
    );
    let main = "import 'package:fespalier_push/fespalier_push.dart';\nFuture<void> main() {\n  FespalierPush.configure(source: s, route: r);\n  return AppMain.run();\n}\n";
    let f = facts(
        &pubspec,
        &[("pubspec.lock", &lock), ("lib/main.dart", main)],
        flutter("3.38.1", "3.10.2"),
    );
    let rows = doctor::rows(&f);
    assert_eq!(statuses(&rows, Status::Error), Vec::<String>::new());
    assert_eq!(statuses(&rows, Status::Warning), Vec::<String>::new());
    assert_eq!(
        one(&rows, "fespalier", None),
        format!("ok: fespalier: git, ref v{v}, the version of this fsp")
    );
    assert_eq!(
        one(&rows, "companion", Some("fespalier_push")),
        format!("ok: fespalier_push: git, ref v{v}, as fespalier")
    );
    assert!(one(&rows, "go_router", None).starts_with("ok: go_router 17.3.0 (pubspec.lock)"));
    assert_eq!(
        one(&rows, "adapter", Some("fespalier_push")),
        "ok: fespalier_push: on, listed in `adapters:`; lib/main.dart calls `FespalierPush.configure(...)`"
    );
    assert_eq!(
        one(&rows, "main", None),
        "ok: lib/app.main.g.dart is written: `adapters:` lists fespalier_push"
    );
    assert_eq!(
        one(&rows, "main_dart", None),
        "ok: lib/main.dart calls AppMain.run()"
    );
    assert_eq!(
        one(&rows, "fsp_check", None),
        "ok: `fsp check`: 1 route, no errors"
    );
    // Every section, in order.
    let order: Vec<Section> = rows.iter().map(|r| r.section).collect();
    let first = |s: Section| order.iter().position(|x| *x == s).unwrap();
    assert!(first(Section::Wiring) < first(Section::Versions));
    assert!(first(Section::Versions) < first(Section::Checks));
}

#[test]
fn refs_out_of_line_are_errors_and_other_sources_are_warnings() {
    let pubspec = format!(
        "name: shop\ndependencies:\n  fespalier:{}\n  fespalier_push:{}\n  fespalier_http:\n    git:\n      url: https://github.com/someone/fork.git\n      ref: v0.1.0\n  fespalier_flags: ^1.0.0\n  fespalier_mine:\n    path: ../mine\n",
        git("v0.1.0"),
        git("v0.0.9")
    );
    let rows = doctor::rows(&facts(
        &pubspec,
        &[],
        Err("`flutter` is not on PATH".into()),
    ));
    assert_eq!(
        one(&rows, "fespalier", None),
        format!(
            "error: {}",
            crate::upgrade::ref_note(Some("v0.1.0"), Version::parse(&this_fsp()).unwrap()).unwrap()
        )
    );
    assert_eq!(
        one(&rows, "companion", Some("fespalier_push")),
        "error: fespalier_push: ref v0.0.9, and fespalier's is v0.1.0: give every companion fespalier's url and ref, or move them together with `fsp upgrade --app`"
    );
    assert_eq!(
        one(&rows, "companion", Some("fespalier_http")),
        "warning: fespalier_http: url https://github.com/someone/fork.git, and fespalier's is https://github.com/fespalier/fespalier: give every companion fespalier's url and ref"
    );
    assert_eq!(
        one(&rows, "companion", Some("fespalier_flags")),
        "warning: fespalier_flags: `^1.0.0`, not a git dependency: the companions are not published; give it fespalier's url and ref"
    );
    assert_eq!(
        one(&rows, "companion", Some("fespalier_mine")),
        "info: fespalier_mine: path ../mine, not compared"
    );
    // A `.git` and a trailing slash name the same repository.
    let same = format!(
        "name: shop\ndependencies:\n  fespalier:{}\n  fespalier_push:\n    git:\n      url: https://github.com/fespalier/fespalier.git/\n      ref: v0.1.0\n",
        git("v0.1.0")
    );
    let rows = doctor::rows(&facts(&same, &[], Err("no".into())));
    assert!(one(&rows, "companion", Some("fespalier_push")).starts_with("ok: "));
    // A branch or a commit is not compared; no ref at all is the default branch.
    let rows = doctor::rows(&facts(
        &format!("name: shop\ndependencies:\n  fespalier:{}\n", git("main")),
        &[],
        Err("no".into()),
    ));
    assert!(
        one(&rows, "fespalier", None)
            .starts_with("info: fespalier: git, ref main, which is not a release tag")
    );
    let rows = doctor::rows(&facts(
        "name: shop\ndependencies:\n  fespalier:\n    git: https://github.com/fespalier/fespalier\n",
        &[],
        Err("no".into()),
    ));
    assert!(one(&rows, "fespalier", None).starts_with("warning: fespalier: git with no `ref:`"));
    let rows = doctor::rows(&facts("name: shop\n", &[], Err("no".into())));
    assert_eq!(
        one(&rows, "fespalier", None),
        "error: fespalier is not under `dependencies:`: the generated files import package:fespalier"
    );
}

/// fespalier under `dev_dependencies:` only builds, but the generated files under lib/ import it:
/// a warning beside the row of its ref (since 0.23.1). Under `dependencies:` it is not.
#[test]
fn fespalier_under_dev_dependencies_only_is_a_warning() {
    let pin = git(&format!("v{}", this_fsp()));
    let rows = doctor::rows(&facts(
        &format!("name: shop\ndev_dependencies:\n  fespalier:{pin}\n"),
        &[],
        Err("no".into()),
    ));
    assert_eq!(
        of(&rows, "fespalier", None),
        [
            format!(
                "ok: fespalier: git, ref v{}, the version of this fsp",
                this_fsp()
            ),
            "warning: fespalier is under `dev_dependencies:` only: the generated files under lib/ import package:fespalier, so move it to `dependencies:`".to_string(),
        ]
    );
    for pubspec in [
        format!("name: shop\ndependencies:\n  fespalier:{pin}\n"),
        format!(
            "name: shop\ndependencies:\n  fespalier:{pin}\ndev_dependencies:\n  fespalier:{pin}\n"
        ),
    ] {
        let rows = doctor::rows(&facts(&pubspec, &[], Err("no".into())));
        assert!(
            one(&rows, "fespalier", None).starts_with("ok: "),
            "{pubspec}"
        );
    }
}

#[test]
fn the_lock_go_router_and_the_toolchain() {
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../fespalier\n  fespalier_download_background:\n    path: ../bg\n";
    // No lock: skipped. No flutter: one skipped row for both.
    let rows = doctor::rows(&facts(pubspec, &[], Err("`flutter` is not on PATH".into())));
    assert_eq!(
        of(&rows, "lock", None),
        [
            "skipped: no pubspec.lock: run `flutter pub get`; the versions it resolves (fespalier's, go_router's) are not checked"
        ]
    );
    assert_eq!(
        of(&rows, "flutter", None),
        ["skipped: `flutter` is not on PATH: Flutter and Dart are not checked"]
    );
    assert!(of(&rows, "dart", None).is_empty());
    // A lock of another fespalier, a companion out of step, `go_router` outside the range.
    let lock = "packages:\n  fespalier:\n    version: \"0.1.0\"\n  fespalier_download_background:\n    version: \"0.0.9\"\n  go_router:\n    version: \"16.2.0\"\n";
    let rows = doctor::rows(&facts(
        pubspec,
        &[("pubspec.lock", lock)],
        flutter("3.44.2", "3.11.0"),
    ));
    let v = Version::parse(&this_fsp()).unwrap();
    assert_eq!(
        of(&rows, "lock", None),
        [
            format!(
                "warning: pubspec.lock resolves fespalier 0.1.0, and this fsp writes code for {v}: move the refs to {} with `fsp upgrade --app`, or run `dart run fespalier` to use the fsp of the pin",
                v.tag()
            ),
            "warning: pubspec.lock resolves fespalier_download_background 0.0.9, and fespalier 0.1.0: give every companion fespalier's ref, then run `flutter pub get`".to_string(),
        ]
    );
    assert_eq!(
        one(&rows, "go_router", None),
        "error: go_router 16.2.0 (pubspec.lock) is outside what fespalier supports, >=17.2.3 <19.0.0: a `dependency_overrides:` entry or a stale lock; remove the override and run `flutter pub get`"
    );
    // fespalier's floor is met, the background package's is not.
    assert_eq!(
        of(&rows, "flutter", None),
        [
            "ok: Flutter 3.44.2, at or above fespalier's floor, 3.35.0",
            "error: fespalier_download_background needs Flutter 3.47.0, and this is 3.44.2",
        ]
    );
    assert_eq!(
        one(&rows, "dart", None),
        "ok: Dart 3.11.0, at or above fespalier's floor, 3.9.0"
    );
    let rows = doctor::rows(&facts(pubspec, &[], flutter("3.32.8", "3.8.1")));
    assert!(
        one(&rows, "dart", None).starts_with("error: Dart 3.8.1 is below fespalier's floor, 3.9.0")
    );
    assert!(
        of(&rows, "flutter", None)[0]
            .starts_with("error: Flutter 3.32.8 is below fespalier's floor, 3.35.0")
    );
}

/// A lock that is ahead of this `fsp` is fixed by a newer `fsp`, not by moving the refs back.
#[test]
fn a_lock_ahead_of_this_fsp_says_to_upgrade_fsp() {
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../fespalier\n";
    let lock = "packages:\n  fespalier:\n    version: \"99.0.0\"\n";
    let rows = doctor::rows(&facts(pubspec, &[("pubspec.lock", lock)], Err("no".into())));
    let v = Version::parse(&this_fsp()).unwrap();
    assert_eq!(
        of(&rows, "lock", None)[0],
        format!(
            "warning: pubspec.lock resolves fespalier 99.0.0, and this fsp writes code for {v}: upgrade fsp (`fsp upgrade`), or run `dart run fespalier` to use the fsp of the pin"
        )
    );
}

/// A Flutter that does not know its version, and a pre-release of the floor, which pub orders below it.
#[test]
fn a_flutter_without_tags_and_a_pre_release_of_the_floor() {
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../fespalier\n  fespalier_keypair:\n    path: ../kp\n";
    // A shallow clone with no tags says `0.0.0-unknown`.
    let rows = doctor::rows(&facts(pubspec, &[], flutter("0.0.0-unknown", "3.11.0")));
    assert_eq!(
        of(&rows, "flutter", None),
        [
            "error: Flutter does not know its own version (it reports 0.0.0): the checkout has no release tags, so pub cannot compare it with fespalier's floor, 3.35.0; run `git fetch --tags` in the Flutter folder, or install a release"
        ]
    );
    // The floor's own pre-release is below the floor, and says it is one.
    let rows = doctor::rows(&facts(pubspec, &[], flutter("3.35.0-0.1.pre", "3.9.0")));
    assert_eq!(
        of(&rows, "flutter", None),
        [
            "error: Flutter 3.35.0 (a pre-release) is below fespalier's floor, 3.35.0: upgrade Flutter",
            "error: fespalier_keypair needs Flutter 3.44.0, and this is 3.35.0 (a pre-release)",
        ]
    );
    // A pre-release of a later version is above it.
    let rows = doctor::rows(&facts(pubspec, &[], flutter("3.44.0-0.2.pre", "3.12.0")));
    assert_eq!(
        of(&rows, "flutter", None),
        [
            "ok: Flutter 3.44.0 (a pre-release), at or above fespalier's floor, 3.35.0",
            "error: fespalier_keypair needs Flutter 3.44.0, and this is 3.44.0 (a pre-release)",
        ]
    );
}

/// A pub workspace member has no `pubspec.lock`: the root's is the one pub wrote.
#[test]
fn a_workspace_member_is_checked_against_the_roots_lock() {
    let dir = tempfile::tempdir().unwrap();
    let app = dir.path().join("app");
    fs::create_dir_all(app.join("lib")).unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: root\nenvironment:\n  sdk: ^3.9.0\nworkspace:\n  - app\n",
    )
    .unwrap();
    fs::write(
        app.join("pubspec.yaml"),
        "name: shop\nresolution: workspace\ndependencies:\n  fespalier:\n    path: ../../f\n",
    )
    .unwrap();
    // The root has no lock yet: the row says where pub writes it.
    let rows = doctor::rows(&doctor::gather(&app, Err("no".into())));
    assert_eq!(
        one(&rows, "lock", None),
        "skipped: no pubspec.lock at the root of the pub workspace (`resolution: workspace`: pub keeps the one lock there, none beside this pubspec): run `flutter pub get` in the workspace; the versions it resolves (fespalier's, go_router's) are not checked"
    );
    // With the root's lock, its versions are checked.
    fs::write(
        dir.path().join("pubspec.lock"),
        "packages:\n  fespalier:\n    version: \"0.1.0\"\n  go_router:\n    version: \"16.2.0\"\n",
    )
    .unwrap();
    let rows = doctor::rows(&doctor::gather(&app, Err("no".into())));
    assert!(one(&rows, "lock", None).starts_with("warning: pubspec.lock resolves fespalier 0.1.0"));
    assert!(one(&rows, "go_router", None).starts_with("error: go_router 16.2.0"));
}

/// Each adapter that is on, whether its `configure` is called (by text, comments out), and each
/// first-party adapter package that is a dependency and is off.
#[test]
fn adapters_on_off_and_configured() {
    let deps = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\n  fespalier_push: any\n  fespalier_analytics: any\n  fespalier_download: any\n  my_tools: any\n";
    let main = "Future<void> main() {\n  // FespalierAnalytics.configure(backend) once there is one\n  FespalierPush.configure(source: s, route: r);\n  return AppMain.run();\n}\n";
    let listed =
        format!("{deps}fespalier:\n  adapters: [fespalier_push, fespalier_analytics, my_tools]\n");
    let rows = doctor::rows(&facts(
        &listed,
        &[("lib/main.dart", main)],
        Err("no".into()),
    ));
    assert_eq!(
        of(&rows, "adapter", None),
        [
            "ok: fespalier_push: on, listed in `adapters:`; lib/main.dart calls `FespalierPush.configure(...)`",
            "warning: fespalier_analytics: on, listed in `adapters:`, and no Dart file under lib/ calls `FespalierAnalytics.configure(...)`: unconfigured, the adapter reports an error once and does nothing; call it in main() before AppMain.run() (docs/adapters.md, \"Adapters that need your code\")",
            "info: my_tools: on, listed in `adapters:`; fsp does not read package:my_tools/fespalier_adapter.dart",
            "info: fespalier_download: off: a dependency, and `adapters:` does not list it; no Dart file under lib/ calls `FespalierDownload.configure(...)`, so nothing asks for its adapter",
        ]
    );
    // The off row never steers towards `adapters: auto`: a package of the family is often a
    // dependency for something else (the engine through an override, `fespalier_maps`' file packs).
    assert!(
        !of(&rows, "adapter", Some("fespalier_download"))[0].contains("auto"),
        "{rows:?}"
    );
    // A `configure(` that `adapters:` leaves out never runs: that one is worth a warning.
    let forgotten = format!("{deps}fespalier:\n  adapters: [fespalier_push]\n");
    let rows = doctor::rows(&facts(
        &forgotten,
        &[
            ("lib/main.dart", main),
            (
                "lib/setup.dart",
                "void setup() => FespalierDownload.configure(backend: b);\n",
            ),
        ],
        Err("no".into()),
    ));
    assert_eq!(
        of(&rows, "adapter", Some("fespalier_download")),
        [
            "warning: fespalier_download: off: lib/setup.dart calls `FespalierDownload.configure(...)`, and `adapters:` does not list fespalier_download, so the adapter does not run: list it in `adapters:`"
        ]
    );
    let auto = format!("{deps}fespalier:\n  adapters: auto\n");
    let rows = doctor::rows(&facts(&auto, &[("lib/main.dart", main)], Err("no".into())));
    let adapters = of(&rows, "adapter", None);
    assert_eq!(adapters.len(), 3, "{adapters:?}");
    assert!(
        adapters[0].starts_with(
            "ok: fespalier_push: on, found by `adapters: auto` under `dependencies:`;"
        )
    );
    assert!(adapters.iter().all(|a| !a.contains(": off:")));
    assert!(one(&rows, "main", None).ends_with(
        "`adapters: auto` finds fespalier_push, fespalier_analytics, fespalier_download"
    ));
}

#[test]
fn the_main_and_what_the_root_files_give_it() {
    let startup = "Future<List<Override>> startup() async => [];\nFuture<void> zone(Future<void> Function() body) => body();\nList<NavigatorObserver> get routerObservers => [];\n";
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\n";
    let rows = doctor::rows(&facts(
        pubspec,
        &[
            ("lib/app/startup.dart", startup),
            ("lib/main.dart", "void main() => runApp(const MyApp());\n"),
        ],
        Err("no".into()),
    ));
    assert_eq!(
        one(&rows, "main", None),
        "ok: lib/app.main.g.dart is written: lib/app/startup.dart exists"
    );
    assert_eq!(
        one(&rows, "root_file", Some("lib/app/startup.dart")),
        "info: lib/app/startup.dart gives the generated main() startup() (which returns overrides), zone(), routerObservers"
    );
    assert!(one(&rows, "main_dart", None).starts_with(
        "warning: no Dart file under lib/ calls AppMain.run(), so the generated main() (lib/app.main.g.dart) does not run"
    ));
    // `lib/main.dart` may hand over to another file (a `bootstrap()`, a flavour's main): not a warning.
    let rows = doctor::rows(&facts(
        pubspec,
        &[
            ("lib/app/startup.dart", startup),
            ("lib/main.dart", "void main() => bootstrap();\n"),
            (
                "lib/bootstrap.dart",
                "Future<void> bootstrap() => AppMain.run();\n",
            ),
        ],
        Err("no".into()),
    ));
    assert_eq!(
        one(&rows, "main_dart", None),
        "ok: lib/bootstrap.dart calls AppMain.run(); the entry point you run must reach it"
    );
    // A comment is no call, and no `lib/main.dart` is a note, not a warning.
    let rows = doctor::rows(&facts(
        pubspec,
        &[
            ("lib/app/startup.dart", startup),
            ("lib/other.dart", "// AppMain.run()\n"),
        ],
        Err("no".into()),
    ));
    assert_eq!(
        one(&rows, "main_dart", None),
        "info: no lib/main.dart, and no Dart file under lib/ calls AppMain.run(): the entry point you run must call AppMain.run()"
    );
    // Nothing to write a main for.
    let rows = doctor::rows(&facts(pubspec, &[], Err("no".into())));
    assert!(
        one(&rows, "main", None)
            .starts_with("info: no lib/app.main.g.dart: `main: auto` finds no app.dart")
    );
    assert!(of(&rows, "main_dart", None).is_empty());
    assert!(of(&rows, "hot_reload", None).is_empty());
    // `main: manual` with adapters needs AppAdapters in the app's own code.
    let manual = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\n  my_tools: any\nfespalier:\n  main: manual\n  adapters: [my_tools]\n";
    let rows = doctor::rows(&facts(
        manual,
        &[("lib/main.dart", "void main() {}\n")],
        Err("no".into()),
    ));
    assert!(one(&rows, "main", None).starts_with("info: no lib/app.main.g.dart: `main: manual`"));
    assert_eq!(
        one(&rows, "main_dart", None),
        "warning: `main: manual` with adapters, and no Dart file under lib/ calls AppAdapters: the adapters do not run (docs/adapters.md, \"With main: manual: AppAdapters\")"
    );
    // The file `output:` names is fsp's, whatever its name: its `AppAdapters.` is not the app's call.
    let renamed = format!("{manual}  output: lib/routes.dart\n");
    let rows = doctor::rows(&facts(
        &renamed,
        &[
            ("lib/main.dart", "void main() {}\n"),
            (
                "lib/routes.dart",
                "class AppRoutes { static void r() => AppAdapters.launch(); }\n",
            ),
        ],
        Err("no".into()),
    ));
    assert!(
        one(&rows, "main_dart", None).starts_with("warning: `main: manual` with adapters, and no")
    );
}

#[test]
fn what_fsp_gen_never_checks_is_checked_here() {
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\nfespalier:\n  tasks:\n    codegen: 5\n  maestro: {}\n  size:\n    main: 3 MB\n";
    let rows = doctor::rows(&facts(pubspec, &[], Err("no".into())));
    assert!(
        one(&rows, "tasks", None).starts_with("error: `fespalier.tasks.codegen` must be a command")
    );
    assert!(
        one(&rows, "section", Some("maestro"))
            .starts_with("error: `fespalier.maestro` needs `app_id`")
    );
    assert_eq!(
        one(&rows, "section", Some("size")),
        "ok: `size:` is what `fsp size` needs (only that command reads it)"
    );
    // A tasks section that reads lists the tasks.
    let ok = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\nfespalier:\n  tasks:\n    codegen: dart run build_runner build\n";
    let rows = doctor::rows(&facts(ok, &[], Err("no".into())));
    assert_eq!(
        one(&rows, "tasks", None),
        "ok: dev, build, codegen: `fsp run` lists them (dev and build have a default)"
    );
}

#[test]
fn forms_need_their_package_and_fsp_check_is_counted() {
    let action = "import 'package:fespalier/fespalier.dart';\n\ntypedef NameFields = ({String name});\n\nNameFields form() => (name: '');\n\nFuture<void> action(Ref ref, {required NameFields input}) async {}\n";
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\n";
    let rows = doctor::rows(&facts(
        pubspec,
        &[("lib/app/action.dart", action)],
        Err("no".into()),
    ));
    assert_eq!(
        one(&rows, "forms", None),
        "error: 1 action with a form(), and fespalier_forms is not under `dependencies:`: the generated file imports it (`fsp check` reports each form())"
    );
    // One problem, one error: `fsp check` prints the form() error, and the `forms` row is it.
    assert_eq!(
        one(&rows, "fsp_check", None),
        "info: `fsp check` finds nothing besides what the rows above report: run `fsp check` to see it"
    );
    assert_eq!(statuses(&rows, Status::Error).len(), 1, "{rows:?}");
    let f = facts(
        pubspec,
        &[("lib/app/action.dart", action)],
        Err("no".into()),
    );
    assert!(doctor::text(&f, &doctor::rows(&f)).ends_with("\n1 error.\n"));
    let with = format!("{pubspec}  fespalier_forms:\n    path: ../forms\n");
    let rows = doctor::rows(&facts(
        &with,
        &[("lib/app/action.dart", action)],
        Err("no".into()),
    ));
    assert_eq!(
        one(&rows, "forms", None),
        "ok: 1 action with a form(), and fespalier_forms is a dependency"
    );
    // No app folder: `fsp check` stops before the tree, and says why; `main` does not guess.
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), pubspec).unwrap();
    let rows = doctor::rows(&doctor::gather(dir.path(), Err("no".into())));
    assert!(one(&rows, "fsp_check", None).contains("not found (set `fespalier: app_dir:`"));
    assert_eq!(
        one(&rows, "main", None),
        "skipped: lib/app cannot be read as a tree, so whether lib/app.main.g.dart is written is not known: `fsp_check` says why"
    );
    let adapters =
        format!("{pubspec}  fespalier_push: any\nfespalier:\n  adapters: [fespalier_push]\n");
    let rows = doctor::rows(&facts_without_app(&adapters));
    assert!(one(&rows, "main", None).starts_with("skipped: lib/app cannot be read"));
}

#[test]
fn the_build_runner_trap_is_fsp_checks_own_warning() {
    let pubspec = "name: shop\ndependencies:\n  fespalier:\n    path: ../f\ndev_dependencies:\n  build_runner: any\n";
    let rows = doctor::rows(&facts(
        pubspec,
        &[("lib/app.dart", "class A {}\n")],
        Err("no".into()),
    ));
    let row = one(&rows, "build_runner", Some("lib/app.dart"));
    assert!(
        row.starts_with("warning: `build_runner` can delete `lib/app.g.dart`"),
        "{row}"
    );
    // One warning, counted once: `fsp check` prints it too, and `fsp_check` leaves it to its row.
    assert_eq!(
        one(&rows, "fsp_check", None),
        "info: `fsp check` finds nothing besides what the rows above report: run `fsp check` to see it"
    );
    assert_eq!(statuses(&rows, Status::Warning).len(), 1, "{rows:?}");
    let rows = doctor::rows(&facts(pubspec, &[], Err("no".into())));
    assert!(one(&rows, "build_runner", None).starts_with("ok: build_runner is a dependency"));
}

#[test]
fn a_pubspec_config_rs_refuses_is_one_error_and_the_versions_still_show() {
    let pubspec = format!(
        "name: shop\ndependencies:\n  fespalier:{}\nfespalier:\n  remount: sometimes\n",
        git(&format!("v{}", this_fsp()))
    );
    let rows = doctor::rows(&facts(&pubspec, &[], Err("no".into())));
    assert!(rows.iter().all(|r| r.section != Section::Wiring));
    let config = one(&rows, "config", None);
    assert!(
        config.starts_with("error: invalid pubspec.yaml: "),
        "{config}"
    );
    assert!(config.contains("unknown variant `sometimes`"), "{config}");
    assert!(one(&rows, "fespalier", None).starts_with("ok: "));
}

#[test]
fn every_example_reads_with_no_error_and_no_warning() {
    let examples = Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples");
    let mut seen = 0;
    for entry in fs::read_dir(&examples).unwrap().flatten() {
        let dir = entry.path();
        if !dir.join("pubspec.yaml").is_file() {
            continue;
        }
        seen += 1;
        let mut f = doctor::gather(&dir, Err("not asked".into()));
        // What `flutter pub get` left there depends on what ran before: not this test's business.
        f.lock = None;
        let rows = doctor::rows(&f);
        let name = dir.display();
        assert_eq!(
            statuses(&rows, Status::Error),
            Vec::<String>::new(),
            "{name}"
        );
        assert_eq!(
            statuses(&rows, Status::Warning),
            Vec::<String>::new(),
            "{name}"
        );
    }
    assert!(seen >= 10, "{seen}");
}

#[test]
fn json_lines_have_every_key_and_the_text_counts() {
    let row = Row::new(
        Section::Versions,
        "lock",
        Status::Skipped,
        "no pubspec.lock",
    );
    assert_eq!(
        doctor::json_line(&row),
        r#"{"section":"versions","check":"lock","subject":null,"status":"skipped","message":"no pubspec.lock"}"#
    );
    let row = row.about("fespalier_push");
    assert!(doctor::json_line(&row).contains(r#""subject":"fespalier_push""#));
    let f = facts(
        "name: shop\ndependencies:\n  fespalier:\n    path: ../f\n",
        &[],
        Err("no".into()),
    );
    let mut rows = doctor::rows(&f);
    let text = doctor::text(&f, &rows);
    assert!(
        text.starts_with(&format!("fsp doctor {} (", this_fsp())),
        "{text}"
    );
    assert!(
        text.contains(
            "\nWhat the generated main() wires, and why\n  · main         no lib/app.main.g.dart"
        ),
        "{text}"
    );
    assert!(text.ends_with("\nNothing out of line.\n"), "{text}");
    rows.push(Row::new(Section::Checks, "x", Status::Error, "e"));
    rows.push(Row::new(Section::Checks, "x", Status::Warning, "w"));
    rows.push(Row::new(Section::Checks, "x", Status::Warning, "w"));
    assert!(doctor::text(&f, &rows).ends_with("\n1 error, 2 warnings.\n"));
}

/// A `flutter` that does not answer (it waits while another flutter command holds its startup
/// lock) is stopped after the timeout with everything it started, and the `flutter` row is skipped
/// and says why (since 0.23.1). The stand-in sleeps under a shell, as `flutter` runs `dart` under
/// one.
#[cfg(unix)]
#[test]
fn a_flutter_that_does_not_answer_is_stopped_and_its_row_skipped() {
    use std::process::Command;
    use std::time::{Duration, Instant};
    let dir = tempfile::tempdir().unwrap();
    let pidfile = dir.path().join("dart.pid");
    let mut stand_in = Command::new("sh");
    stand_in.arg("-c").arg(format!(
        "sleep 300 & echo $! > '{}'; wait",
        pidfile.display()
    ));
    let started = Instant::now();
    let why = doctor::version_output(stand_in, "flutter", Duration::from_secs(1)).unwrap_err();
    assert!(started.elapsed() < Duration::from_secs(30), "{why}");
    assert_eq!(
        why,
        "`flutter --version --machine` did not answer in 1 s and was stopped (another flutter command may hold its startup lock)"
    );
    // What it started is stopped too (`kill -0` fails for a process that does not exist). A shell
    // stopped before it started the sleep left nothing behind.
    if let Ok(pid) = fs::read_to_string(&pidfile) {
        let end = Instant::now() + Duration::from_secs(20);
        while Command::new("kill")
            .args(["-0", pid.trim()])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
        {
            assert!(
                Instant::now() < end,
                "the stand-in's sleep is still running"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    let rows = doctor::rows(&facts("name: demo\n", &[], Err(why)));
    let row = rows.iter().find(|r| r.check == "flutter").unwrap();
    assert_eq!(row.status, Status::Skipped);
    assert_eq!(
        row.message,
        "`flutter --version --machine` did not answer in 1 s and was stopped (another flutter command may hold its startup lock): Flutter and Dart are not checked"
    );
    // One that answers in time is read as before.
    let mut answers = Command::new("sh");
    answers.arg("-c").arg(
        "printf '{\"frameworkVersion\":\"3.38.4\",\"dartSdkVersion\":\"3.10.4\"}\\n'; echo noise >&2",
    );
    let out = doctor::version_output(answers, "flutter", Duration::from_secs(30)).unwrap();
    assert_eq!(Toolchain::parse(&out).unwrap().flutter, Version(3, 38, 4));
}
