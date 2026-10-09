//! Tests of `fsp create`'s plan and its feature table (the I/O around them is run against a
//! stand-in `flutter` in `tests/cli.rs`).
//!
//! The goldens are in `tests/golden/create/`; `FSP_UPDATE_GOLDEN=1 cargo test create_tests::`
//! rewrites them. They show `v<version>` where the plan has this crate's own version, so a
//! release does not make them stale.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::create::compose;
use crate::create::plan::{self, Action, BASE_FLOOR, DirState, FlutterVersion, REF, Request};
use crate::create::recipes::{
    self, COMPANION_DEPS, NOT_A_CREATE_FEATURE, Phase, RECIPES, Recipe, Source, Startup, Step,
    StepKind, ThirdParty,
};

fn request(dir: &str) -> Request {
    Request {
        dir: PathBuf::from(dir),
        dir_state: DirState::Absent,
        name: None,
        org: None,
        platforms: vec![],
        description: None,
        features: vec![],
        local_packages: None,
        no_pub_get: false,
        offline: false,
        flutter: None,
    }
}

/// Three made-up features, so the composer is tested on shapes the real table does not have
/// (yet): a pubspec with a companion and a range, a feature that needs another and has a floor, a
/// git dependency, statements in every phase and a zone, and one that conflicts.
const SYNTHETIC: &[Recipe] = &[
    Recipe {
        id: "alpha",
        description: "First.",
        companions: &["fespalier_storage"],
        third_party: &[ThirdParty {
            name: "zeta",
            source: Source::Range(">=1.0.0 <2.0.0"),
        }],
        flutter_floor: "3.32",
        config: &["format: true"],
        files: &[("create/about.dart", "lib/app/alpha/page.dart")],
        startup: Startup {
            imports: &["package:fespalier/fespalier.dart", "package:zeta/zeta.dart"],
            steps: &[Step {
                kind: StepKind::Override,
                phase: Phase::Rest,
                comment: "alpha: its provider.",
                code: "alphaProvider.overrideWithValue(1),",
                awaits: false,
            }],
            app_imports: &["package:zeta/zeta.dart"],
            main_imports: &["dart:async"],
            ..Startup::NONE
        },
        requires: &[],
        conflicts: &["gamma"],
    },
    Recipe {
        id: "beta",
        description: "Second.",
        companions: &["fespalier_cratestack"],
        third_party: &[ThirdParty {
            name: "pinned",
            source: Source::Git {
                url: "https://example.com/pinned",
                commit: "0123456789abcdef0123456789abcdef01234567",
            },
        }],
        flutter_floor: "3.44",
        config: &["telemetry: true", "data_retry: none"],
        files: &[],
        startup: Startup {
            imports: &["dart:async", "package:fespalier/fespalier.dart"],
            steps: &[
                Step {
                    kind: StepKind::Override,
                    phase: Phase::Rest,
                    comment: "",
                    code: "betaProvider.overrideWithValue(await openBeta()),",
                    awaits: true,
                },
                Step {
                    kind: StepKind::Statement,
                    phase: Phase::Rest,
                    comment: "beta: last of the statements.",
                    code: "betaSetup();",
                    awaits: false,
                },
                Step {
                    kind: StepKind::Statement,
                    phase: Phase::Telemetry,
                    comment: "beta: the sink comes first.",
                    code: "installSink();",
                    awaits: false,
                },
                Step {
                    kind: StepKind::Statement,
                    phase: Phase::Session,
                    comment: "",
                    code: "await restoreSession();",
                    awaits: true,
                },
            ],
            zone: Some("Future<void> zone(Future<void> Function() body) => runZoned(body);"),
            ..Startup::NONE
        },
        requires: &["alpha"],
        conflicts: &[],
    },
    Recipe {
        id: "gamma",
        description: "Third.",
        companions: &[],
        third_party: &[],
        flutter_floor: "3.32",
        config: &[],
        files: &[],
        startup: Startup::NONE,
        requires: &[],
        conflicts: &["alpha"],
    },
];

fn ok(req: &Request, table: &[Recipe]) -> plan::Plan {
    plan::build(req, table).unwrap_or_else(|e| panic!("{e:#}"))
}

fn err(req: &Request, table: &[Recipe]) -> String {
    format!("{:#}", plan::build(req, table).unwrap_err())
}

fn golden(name: &str, text: &str) {
    let text = text.replace(REF, "v<version>");
    assert!(
        !text.contains(env!("CARGO_PKG_VERSION")),
        "the plan spells out the version somewhere other than REF"
    );
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/create")
        .join(format!("{name}.txt"));
    if std::env::var_os("FSP_UPDATE_GOLDEN").is_some() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &text).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        text,
        want,
        "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test create_tests::` in cli/",
        path.display()
    );
}

// --- goldens ------------------------------------------------------------------------------------

#[test]
fn golden_of_the_base_app() {
    let plan = ok(&request("my_app"), RECIPES);
    golden("base", &plan.describe("<staging>"));
}

#[test]
fn golden_of_the_base_app_with_every_flag() {
    let mut req = request("apps/Shop-App");
    req.org = Some("com.example".into());
    req.platforms = vec!["android".into(), "web".into()];
    req.description = Some("The shop: orders, and more".into());
    req.no_pub_get = true;
    let plan = ok(&req, RECIPES);
    assert_eq!(plan.name, "shop_app");
    assert!(plan.pub_get.is_none());
    golden("base-flags", &plan.describe("<staging>"));
}

#[test]
fn golden_of_the_base_app_against_a_checkout() {
    let mut req = request("my_app");
    req.local_packages = Some("/checkout".into());
    req.offline = true;
    let plan = ok(&req, RECIPES);
    assert_eq!(
        plan.pub_get.as_deref(),
        Some(
            &[
                "pub".to_string(),
                "get".to_string(),
                "--offline".to_string()
            ][..]
        )
    );
    golden("base-local", &plan.describe("<staging>"));
}

#[test]
fn golden_of_features_from_the_composer() {
    let mut req = request("my_app");
    req.features = vec!["beta".into()];
    let plan = ok(&req, SYNTHETIC);
    // `beta` needs `alpha`, which is added, and said.
    assert_eq!(plan.features, ["alpha", "beta"]);
    assert_eq!(plan.notes, ["`beta` needs `alpha`: added it"]);
    golden("features", &plan.describe("<staging>"));
}

#[test]
fn golden_of_features_against_a_checkout() {
    let mut req = request("my_app");
    req.features = vec!["beta".into()];
    req.local_packages = Some("/check out".into());
    let plan = ok(&req, SYNTHETIC);
    golden("features-local", &plan.describe("<staging>"));
}

// --- the pin ------------------------------------------------------------------------------------

#[test]
fn every_fespalier_dependency_is_pinned_to_this_version() {
    assert_eq!(REF, format!("v{}", env!("CARGO_PKG_VERSION")));
    let mut req = request("my_app");
    req.features = vec!["beta".into()];
    let plan = ok(&req, SYNTHETIC);
    let pubspec = &plan.files[0];
    assert_eq!(pubspec.path, "pubspec.yaml");
    let refs: Vec<&str> = pubspec
        .content
        .lines()
        .filter_map(|l| l.trim().strip_prefix("ref: "))
        .collect();
    // fespalier, fespalier_cratestack and fespalier_storage by the tag; the git dependency of
    // another repository by its commit, never by a `v…` tag.
    assert_eq!(refs.iter().filter(|r| **r == REF).count(), 3, "{refs:?}");
    assert!(refs.contains(&"0123456789abcdef0123456789abcdef01234567"));
    assert_eq!(refs.len(), 4, "{refs:?}");
}

#[test]
fn a_checkout_overrides_each_companion_and_what_it_needs() {
    let mut req = request("my_app");
    req.features = vec!["beta".into()];
    req.local_packages = Some("/checkout/".into());
    let plan = ok(&req, SYNTHETIC);
    let pubspec = &plan.files[0].content;
    assert!(
        pubspec.contains("  fespalier:\n    path: /checkout/packages/fespalier\n"),
        "{pubspec}"
    );
    assert!(!pubspec.contains("git:\n      url: https://github.com/fespalier"));
    let overrides = pubspec.split("dependency_overrides:\n").nth(1).unwrap();
    let names: Vec<&str> = overrides
        .lines()
        .filter_map(|l| l.strip_prefix("  ").and_then(|l| l.strip_suffix(':')))
        .collect();
    // cratestack depends on dio, and dio on http, which the app does not name.
    assert_eq!(
        names,
        [
            "fespalier",
            "fespalier_cratestack",
            "fespalier_dio",
            "fespalier_http",
            "fespalier_storage"
        ]
    );
    // No companion, no override: the app depends on fespalier at the path itself.
    let mut bare = request("my_app");
    bare.local_packages = Some("/checkout".into());
    let bare = ok(&bare, SYNTHETIC);
    assert!(!bare.files[0].content.contains("dependency_overrides"));
}

// --- refusals -----------------------------------------------------------------------------------

#[test]
fn it_refuses_a_folder_that_is_not_empty_or_not_a_folder() {
    let mut req = request("my_app");
    req.dir_state = DirState::NotEmpty;
    let message = err(&req, RECIPES);
    assert!(message.contains("my_app is not empty"), "{message}");
    assert!(message.contains("fsp init"), "{message}");
    req.dir_state = DirState::NotADirectory;
    assert!(err(&req, RECIPES).contains("exists and is a file"));
    // An empty one is fine: the app replaces it.
    req.dir_state = DirState::Empty;
    ok(&req, RECIPES);
}

#[test]
fn it_refuses_names_that_are_not_dart_packages() {
    for (dir, name, want) in [
        ("1app", None, "lower case letter"),
        ("class", None, "Dart keyword"),
        (
            "app",
            Some("my app"),
            "lower case letters, digits and underscores",
        ),
        (
            "app",
            Some("flutter"),
            "depends on a package called `flutter`",
        ),
        (
            "app",
            Some("fespalier"),
            "depends on a package called `fespalier`",
        ),
        ("app", Some(""), "empty"),
    ] {
        let mut req = request(dir);
        req.name = name.map(String::from);
        let message = err(&req, RECIPES);
        assert!(message.contains(want), "{dir} {name:?}: {message}");
    }
    // The folder's name is made into one when it can be.
    for (dir, name) in [("My-App", "my_app"), ("a/b/Cool App", "cool_app")] {
        assert_eq!(ok(&request(dir), RECIPES).name, name);
    }
    // ... and the message names the flag when it cannot.
    assert!(err(&request("Über"), RECIPES).contains("--project-name"));
    assert!(err(&request("/"), RECIPES).contains("--project-name"));
}

#[test]
fn it_refuses_an_app_named_like_its_dependency() {
    let mut req = request("app");
    req.name = Some("zeta".into());
    req.features = vec!["alpha".into()];
    let message = err(&req, SYNTHETIC);
    assert!(message.contains("cannot be named `zeta`"), "{message}");
}

#[test]
fn it_refuses_what_flutter_create_would() {
    let mut req = request("app");
    req.platforms = vec!["web".into(), "tizen".into()];
    assert!(
        err(&req, RECIPES).contains("unknown platform `tizen`; the platforms are android, ios")
    );
    let mut req = request("app");
    req.org = Some("com example".into());
    assert!(err(&req, RECIPES).contains("not an organization"));
    let mut req = request("app");
    req.description = Some("two\nlines".into());
    assert!(err(&req, RECIPES).contains("one line"));
}

#[test]
fn it_refuses_unknown_and_conflicting_features() {
    let mut req = request("app");
    req.features = vec!["nope".into()];
    assert_eq!(
        err(&req, &[]),
        "unknown feature `nope`: `fsp create` has no optional features yet"
    );
    let message = err(&req, SYNTHETIC);
    assert!(
        message.starts_with("unknown feature `nope`; the features are alpha, beta, gamma"),
        "{message}"
    );
    req.features = vec!["gamma".into(), "alpha".into()];
    assert_eq!(
        err(&req, SYNTHETIC),
        "`alpha` and `gamma` cannot be combined"
    );
    // A feature that is needed by another counts too.
    req.features = vec!["gamma".into(), "beta".into()];
    assert!(err(&req, SYNTHETIC).contains("cannot be combined"));
    // Asking twice is asking once.
    req.features = vec!["alpha".into(), "alpha".into()];
    assert_eq!(ok(&req, SYNTHETIC).features, ["alpha"]);
}

#[test]
fn it_refuses_a_flutter_below_the_floor() {
    let mut req = request("app");
    req.flutter = FlutterVersion::parse("3.31.5");
    let message = err(&req, RECIPES);
    assert!(
        message.contains(&format!(
            "Flutter 3.31.5 is too old: fespalier needs Flutter {BASE_FLOOR}"
        )),
        "{message}"
    );
    req.flutter = FlutterVersion::parse("3.32.0");
    ok(&req, RECIPES);
    req.features = vec!["beta".into()];
    assert_eq!(
        err(&req, SYNTHETIC),
        "`beta` needs Flutter 3.44 or newer, and this is Flutter 3.32.0; leave it out, or upgrade"
    );
    req.flutter = FlutterVersion::parse("3.44.0");
    assert!(
        ok(&req, SYNTHETIC).files[0]
            .content
            .contains("flutter: \">=3.44.0\"")
    );
    // Not asked (a dry run): nothing to refuse.
    req.flutter = None;
    ok(&req, SYNTHETIC);
}

#[test]
fn flutter_versions_read_as_flutter_prints_them() {
    let v = |s| FlutterVersion::parse(s);
    assert_eq!(
        v("3.47.5"),
        Some(FlutterVersion {
            major: 3,
            minor: 47,
            patch: 5
        })
    );
    assert_eq!(v("3.47.0-0.1.pre").map(|v| v.minor), Some(47));
    assert_eq!(v("3.47").map(|v| v.patch), Some(0));
    assert_eq!(v("three"), None);
    assert_eq!(v("3.x.1"), None);
    assert_eq!(v("3.1.2.3"), None);
    assert!(v("3.32.0").unwrap().at_least("3.32"));
    assert!(v("4.0.0").unwrap().at_least("3.99"));
    assert!(!v("3.31.9").unwrap().at_least("3.32"));
}

#[test]
fn a_description_with_a_colon_is_quoted() {
    let mut req = request("app");
    req.description = Some("Orders: it's all here".into());
    let plan = ok(&req, RECIPES);
    assert!(
        plan.files[0]
            .content
            .contains("description: 'Orders: it''s all here'\n"),
        "{}",
        plan.files[0].content
    );
}

#[test]
fn the_pubspec_and_main_replace_what_flutter_create_wrote() {
    let plan = ok(&request("app"), RECIPES);
    let overwritten: Vec<&str> = plan
        .files
        .iter()
        .filter(|f| f.action == Action::Overwrite)
        .map(|f| f.path.as_str())
        .collect();
    assert_eq!(overwritten, ["pubspec.yaml", "lib/main.dart"]);
    assert_eq!(
        plan.flutter_create,
        ["create", "--no-pub", "--empty", "--project-name=app"]
    );
}

// --- the starter app ----------------------------------------------------------------------------

/// What the base plan writes, as an app on disk.
fn write_plan(dir: &Path, plan: &plan::Plan) {
    for file in &plan.files {
        let path = dir.join(&file.path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &file.content).unwrap();
    }
}

/// `fsp gen` reads the starter app without a complaint, and `fsp test` writes its smoke tests
/// with no `test:` key in the pubspec: that is why `fsp create` runs it and has no test of its own.
#[test]
fn the_starter_app_generates_and_gets_route_smoke_tests_without_config() {
    let dir = tempfile::tempdir().unwrap();
    write_plan(dir.path(), &ok(&request("my_app"), RECIPES));
    let cfg = crate::config::Config::load(dir.path())
        .unwrap()
        .for_scaffolding();
    let outcome = crate::gen_with(dir.path(), &cfg, true).unwrap();
    assert_eq!(outcome.routes, 2);
    let main = fs::read_to_string(dir.path().join("lib/app.main.g.dart")).unwrap();
    assert!(main.contains("class AppMain"), "{main}");
    crate::smoke::run(dir.path(), false).unwrap();
    let test = fs::read_to_string(dir.path().join("test/routes/routes_test.dart")).unwrap();
    assert_eq!(test.matches("testWidgets(").count(), 2, "{test}");
    assert!(
        test.contains("package:my_app/app/about/page.dart"),
        "{test}"
    );
    // The pages link to each other with typed routes, which exist once gen has run.
    let home = fs::read_to_string(dir.path().join("lib/app/page.dart")).unwrap();
    assert!(home.contains("const AboutRoute().go(context)"));
    let app = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(app.contains("class AboutRoute") && app.contains("class HomeRoute"));
}

/// What `fsp create` writes is what `dart format` writes, for short names and for names long
/// enough to make the formatter wrap (the same bar as the scaffolds of `fsp init` and `fsp new`).
/// Without `dart` on PATH there is nothing to compare it with: skip.
#[test]
fn created_files_are_dart_format_clean() {
    let mut checked = 0;
    let mut cases: Vec<(&str, &[Recipe], Vec<String>)> = vec![
        ("app", RECIPES, vec![]),
        ("a_much_longer_package_name_than_usual", RECIPES, vec![]),
        ("my_app", SYNTHETIC, vec!["beta".to_string()]),
        ("my_app", SYNTHETIC, vec!["gamma".to_string()]),
    ];
    // Each real feature alone, each pair, and all of them, under a short and a long name.
    for (i, a) in RECIPES.iter().enumerate() {
        cases.push(("my_app", RECIPES, vec![a.id.to_string()]));
        for b in &RECIPES[i + 1..] {
            cases.push(("my_app", RECIPES, vec![a.id.to_string(), b.id.to_string()]));
        }
    }
    cases.push(("my_app", RECIPES, vec!["all".to_string()]));
    cases.push((
        "a_much_longer_package_name_than_usual",
        RECIPES,
        vec!["all".to_string()],
    ));
    for (name, table, features) in cases {
        let dir = tempfile::tempdir().unwrap();
        let mut req = request(name);
        req.features = features;
        let plan = ok(&req, table);
        write_plan(dir.path(), &plan);
        for file in plan.files.iter().filter(|f| f.path.ends_with(".dart")) {
            let path = dir.path().join(&file.path);
            let (formatted, warning) = crate::format::format_dart(&file.content, &path);
            if warning.is_some() {
                return;
            }
            assert_eq!(
                file.content, formatted,
                "{} of `{name}` is not dart-format clean",
                file.path
            );
            checked += 1;
        }
    }
    assert!(checked >= 20, "{checked}");
}

// --- the table ----------------------------------------------------------------------------------

fn packages_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../packages")
}

/// `packages/fespalier_*`, except the DevTools extension's source (an app of its own).
fn packages() -> Vec<String> {
    let mut all: Vec<String> = fs::read_dir(packages_dir())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| n.starts_with("fespalier_") && n != "fespalier_devtools")
        .collect();
    all.sort();
    assert!(all.len() >= 15, "{all:?}");
    all
}

/// The files only the composer writes: a feature cannot have its own template for them.
const SHARED: [&str; 4] = [
    "pubspec.yaml",
    "lib/main.dart",
    "lib/app/app.dart",
    "lib/app/startup.dart",
];

/// What is wrong with a feature table, as sentences; empty when it is fine.
fn table_problems(table: &[Recipe], packages: &[String]) -> Vec<String> {
    let mut bad = vec![];
    let ids: Vec<&str> = table.iter().map(|r| r.id).collect();
    let base_paths: BTreeSet<String> = ok(&request("app"), &[])
        .files
        .iter()
        .map(|f| f.path.clone())
        .collect();
    let mut written: Vec<(String, &str)> = vec![];
    for r in table {
        let id = r.id;
        let well_formed = id.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && id
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
        if !well_formed || id == "base" || id == "all" {
            bad.push(format!("{id}: not an id a person can type"));
        }
        if ids.iter().filter(|i| **i == id).count() > 1 {
            bad.push(format!("{id}: listed twice"));
        }
        if r.description.is_empty() || r.description.contains('\n') {
            bad.push(format!("{id}: the description is one line"));
        }
        if plan::floor_of(r.flutter_floor).is_none() {
            bad.push(format!(
                "{id}: floor `{}` is not major.minor",
                r.flutter_floor
            ));
        }
        for c in r.companions {
            if !packages.iter().any(|p| p == c) {
                bad.push(format!("{id}: companion `{c}` is not under packages/"));
            }
        }
        for other in r.requires.iter().chain(r.conflicts) {
            if !ids.contains(other) {
                bad.push(format!("{id}: `{other}` is not a feature"));
            }
            if *other == id {
                bad.push(format!("{id}: names itself"));
            }
        }
        for tp in r.third_party {
            match tp.source {
                Source::Git { commit, .. } => {
                    if commit.len() != 40 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
                        bad.push(format!(
                            "{id}: {} must be pinned by a 40-digit commit, not `{commit}`",
                            tp.name
                        ));
                    }
                }
                Source::Range(range) => {
                    if range.contains("ref:") || tp.name.starts_with("fespalier") {
                        bad.push(format!("{id}: {} is not a third-party range", tp.name));
                    }
                }
            }
        }
        for (_, path) in r.files {
            if path.starts_with('/')
                || path.contains("..")
                || base_paths.contains(*path)
                || SHARED.contains(path)
            {
                bad.push(format!("{id}: `{path}` is not a new path inside the app"));
            }
            if let Some((_, other)) = written.iter().find(|(p, _)| p == path) {
                bad.push(format!("{id}: `{path}` is also written by `{other}`"));
            }
            written.push(((*path).to_string(), id));
        }
    }
    for r in table {
        let id = r.id;
        let packages_ok = |uri: &str| -> bool {
            let Some(rest) = uri.strip_prefix("package:") else {
                return uri.starts_with("dart:");
            };
            let name = rest.split('/').next().unwrap_or_default();
            name == "fespalier"
                || name == "flutter"
                || r.companions.contains(&name)
                || r.third_party.iter().any(|t| t.name == name)
        };
        for uri in r
            .startup
            .imports
            .iter()
            .chain(r.startup.app_imports)
            .chain(r.startup.main_imports)
        {
            if !packages_ok(uri) {
                bad.push(format!(
                    "{id}: imports `{uri}`, which is not fespalier, a companion or a dependency of it"
                ));
            }
        }
        for step in r.startup.steps {
            let code = step.code;
            if code.contains('\n') || step.comment.contains('\n') || code.is_empty() {
                bad.push(format!("{id}: `{code}` is not one line"));
            }
            if code.contains("await ") != step.awaits {
                bad.push(format!("{id}: `{code}`: `awaits` disagrees with the code"));
            }
            let end = match step.kind {
                StepKind::Override => ',',
                StepKind::Statement => ';',
            };
            if !code.ends_with(end) {
                bad.push(format!("{id}: `{code}` should end with `{end}`"));
            }
        }
        if let Some(zone) = r.startup.zone
            && !zone.contains("zone(Future<void> Function() body)")
        {
            bad.push(format!("{id}: the zone is not a `zone(...)` function"));
        }
    }
    if table.iter().filter(|r| r.startup.zone.is_some()).count() > 1 {
        bad.push("two features wrap main() in a zone()".to_string());
    }
    // `requires` has no cycle: following it from any feature ends.
    for r in table {
        let mut seen = vec![r.id];
        let mut stack: Vec<&str> = r.requires.to_vec();
        while let Some(next) = stack.pop() {
            if seen.contains(&next) {
                if next == r.id {
                    bad.push(format!("{}: requires itself, through {seen:?}", r.id));
                }
                continue;
            }
            seen.push(next);
            if let Some(n) = table.iter().find(|t| t.id == next) {
                stack.extend(n.requires.iter().copied());
            }
        }
    }
    // A feature and what it requires do not conflict.
    for r in table {
        for need in r.requires {
            if r.conflicts.contains(need) {
                bad.push(format!("{}: requires and conflicts with `{need}`", r.id));
            }
        }
    }
    bad
}

#[test]
fn the_feature_table_is_sound() {
    let problems = table_problems(RECIPES, &packages());
    assert!(problems.is_empty(), "{problems:#?}");
    // The synthetic table passes the same checks, so they are not vacuous on a full table.
    assert_eq!(table_problems(SYNTHETIC, &packages()), Vec::<String>::new());
}

#[test]
fn the_checks_of_the_table_bite() {
    let base = SYNTHETIC[0];
    let with = |r: Recipe| table_problems(&[r], &packages());
    let has = |problems: Vec<String>, needle: &str| {
        assert!(
            problems.iter().any(|p| p.contains(needle)),
            "{needle}: {problems:?}"
        );
    };
    has(
        with(Recipe {
            id: "Bad-Id",
            ..base
        }),
        "not an id",
    );
    has(with(Recipe { id: "all", ..base }), "not an id");
    has(
        with(Recipe {
            companions: &["fespalier_nope"],
            ..base
        }),
        "not under packages/",
    );
    has(
        with(Recipe {
            companions: &["fespalier_devtools"],
            ..base
        }),
        "not under packages/",
    );
    has(
        with(Recipe {
            flutter_floor: "3",
            ..base
        }),
        "major.minor",
    );
    has(
        with(Recipe {
            requires: &["ghost"],
            ..base
        }),
        "not a feature",
    );
    has(
        with(Recipe {
            conflicts: &["alpha"],
            ..base
        }),
        "names itself",
    );
    has(
        with(Recipe {
            third_party: &[ThirdParty {
                name: "x",
                source: Source::Git {
                    url: "https://example.com/x",
                    commit: "v1.2.3",
                },
            }],
            ..base
        }),
        "40-digit commit",
    );
    has(
        with(Recipe {
            files: &[("create/about.dart", "lib/main.dart")],
            ..base
        }),
        "not a new path",
    );
    has(
        with(Recipe {
            files: &[("create/about.dart", "lib/app/startup.dart")],
            ..base
        }),
        "not a new path",
    );
    has(
        with(Recipe {
            startup: Startup {
                steps: &[Step {
                    kind: StepKind::Override,
                    phase: Phase::Rest,
                    comment: "",
                    code: "x.overrideWithValue(await y())",
                    awaits: false,
                }],
                ..Startup::NONE
            },
            ..base
        }),
        "`awaits` disagrees",
    );
    has(
        with(Recipe {
            startup: Startup {
                imports: &["package:somebody_else/x.dart"],
                ..Startup::NONE
            },
            ..base
        }),
        "which is not fespalier, a companion",
    );
    // Two features writing one path.
    let a = Recipe {
        id: "one",
        companions: &[],
        requires: &[],
        conflicts: &[],
        ..base
    };
    let b = Recipe { id: "two", ..a };
    has(table_problems(&[a, b], &packages()), "also written by");
    has(table_problems(&[a, a], &packages()), "listed twice");
    // A cycle.
    let x = Recipe {
        id: "x",
        files: &[],
        companions: &[],
        requires: &["y"],
        conflicts: &[],
        ..base
    };
    let y = Recipe {
        id: "y",
        requires: &["x"],
        ..x
    };
    has(table_problems(&[x, y], &packages()), "requires itself");
}

/// Every package under `packages/` is a create feature's companion or says why it is not.
#[test]
fn every_package_is_a_feature_or_has_a_reason() {
    let packages = packages();
    let companions: BTreeSet<&str> = RECIPES
        .iter()
        .flat_map(|r| r.companions.iter().copied())
        .collect();
    let excused: BTreeSet<&str> = NOT_A_CREATE_FEATURE.iter().map(|(p, _)| *p).collect();
    assert_eq!(
        excused.len(),
        NOT_A_CREATE_FEATURE.len(),
        "a package is listed twice"
    );
    for package in &packages {
        let (is_companion, is_excused) = (
            companions.contains(package.as_str()),
            excused.contains(package.as_str()),
        );
        assert!(
            is_companion || is_excused,
            "{package} is neither a companion of a `fsp create` feature nor in NOT_A_CREATE_FEATURE (cli/src/create/recipes.rs)"
        );
        assert!(
            !(is_companion && is_excused),
            "{package} is a feature's companion and also listed as not a feature"
        );
    }
    for (package, reason) in NOT_A_CREATE_FEATURE {
        assert!(
            packages.iter().any(|p| p == package),
            "NOT_A_CREATE_FEATURE names {package}, which is not under packages/"
        );
        assert!(
            reason.len() > 20 && !reason.ends_with('.'),
            "{package}: `{reason}`"
        );
    }
}

/// `COMPANION_DEPS` is what the companions' pubspecs say: the `fespalier_*` packages in
/// `dependencies:` (the app's own fespalier aside).
#[test]
fn companion_deps_are_what_the_pubspecs_depend_on() {
    let mut from_pubspecs: Vec<(String, Vec<String>)> = vec![];
    for package in packages() {
        let text = fs::read_to_string(packages_dir().join(&package).join("pubspec.yaml")).unwrap();
        let yaml: serde_yaml_ng::Value = serde_yaml_ng::from_str(&text).unwrap();
        let mut deps: Vec<String> = yaml["dependencies"]
            .as_mapping()
            .into_iter()
            .flatten()
            .filter_map(|(k, _)| k.as_str())
            .filter(|k| k.starts_with("fespalier_"))
            .map(String::from)
            .collect();
        deps.sort();
        if !deps.is_empty() {
            from_pubspecs.push((package, deps));
        }
    }
    let table: Vec<(String, Vec<String>)> = COMPANION_DEPS
        .iter()
        .map(|(p, deps)| {
            let mut deps: Vec<String> = deps.iter().map(|d| (*d).to_string()).collect();
            deps.sort();
            ((*p).to_string(), deps)
        })
        .collect();
    assert_eq!(
        table, from_pubspecs,
        "COMPANION_DEPS (left) differs from the companions' pubspecs (right)"
    );
}

#[test]
fn the_closure_of_a_companion_names_what_it_needs() {
    assert_eq!(
        recipes::companion_closure(&["fespalier_cratestack", "fespalier_otel"]),
        [
            "fespalier_cratestack",
            "fespalier_dio",
            "fespalier_http",
            "fespalier_otel"
        ]
    );
    assert_eq!(
        recipes::companion_closure(&["fespalier_sign_keypair"]),
        ["fespalier_auth", "fespalier_http", "fespalier_sign_keypair"]
    );
}

#[test]
fn the_features_list_says_what_the_table_says() {
    let listed = plan::list_features(SYNTHETIC);
    assert_eq!(listed.len(), 3);
    assert_eq!(listed[1].id, "beta");
    assert_eq!(listed[1].requires, ["alpha"]);
    assert_eq!(listed[1].flutter, "3.44");
    let json = serde_json::to_string(&listed[0]).unwrap();
    assert_eq!(
        json,
        r#"{"id":"alpha","description":"First.","flutter":"3.32","requires":[],"conflicts":["gamma"],"companions":["fespalier_storage"]}"#
    );
}

// --- the composer -------------------------------------------------------------------------------

fn plan_of(table: &[Recipe], features: &[&str]) -> plan::Plan {
    let mut req = request("my_app");
    req.features = features.iter().map(|f| (*f).to_string()).collect();
    ok(&req, table)
}

fn file<'p>(plan: &'p plan::Plan, path: &str) -> &'p str {
    &plan
        .files
        .iter()
        .find(|f| f.path == path)
        .unwrap_or_else(|| panic!("no {path} in the plan"))
        .content
}

#[test]
fn the_base_app_has_no_startup_file() {
    let plan = ok(&request("my_app"), RECIPES);
    assert!(plan.files.iter().all(|f| f.path != "lib/app/startup.dart"));
    // A feature without a step adds none either.
    let plan = plan_of(SYNTHETIC, &["gamma"]);
    assert!(plan.files.iter().all(|f| f.path != "lib/app/startup.dart"));
}

#[test]
fn startup_runs_telemetry_first_then_the_session_then_the_rest() {
    let plan = plan_of(SYNTHETIC, &["beta"]);
    let startup = file(&plan, "lib/app/startup.dart");
    let at = |needle: &str| {
        startup
            .find(needle)
            .unwrap_or_else(|| panic!("no `{needle}` in\n{startup}"))
    };
    assert!(at("installSink();") < at("await restoreSession();"));
    assert!(at("await restoreSession();") < at("betaSetup();"));
    // The statements come before the list, and the list keeps the table's order (alpha, beta).
    assert!(at("betaSetup();") < at("return ["));
    assert!(at("alphaProvider") < at("betaProvider"));
    // One step awaits, so startup() is async, and the zone is there once.
    assert!(startup.contains("Future<List<Override>> startup() async {"));
    assert_eq!(startup.matches("Future<void> zone(").count(), 1);
}

#[test]
fn startup_is_async_only_when_a_step_awaits() {
    let plan = plan_of(SYNTHETIC, &["alpha"]);
    let startup = file(&plan, "lib/app/startup.dart");
    assert!(
        startup.contains("List<Override> startup() => [\n  // alpha: its provider.\n"),
        "{startup}"
    );
    assert!(!startup.contains("async"), "{startup}");
    let plan = plan_of(RECIPES, &["connectivity"]);
    assert!(!file(&plan, "lib/app/startup.dart").contains("async"));
    let plan = plan_of(RECIPES, &["storage"]);
    assert!(file(&plan, "lib/app/startup.dart").contains("Future<List<Override>> startup() async"));
}

/// The shapes `startup()` takes besides the list of overrides.
#[test]
fn a_startup_of_statements_only_returns_nothing() {
    let sink = Recipe {
        id: "sink",
        startup: Startup {
            steps: &[Step {
                kind: StepKind::Statement,
                phase: Phase::Telemetry,
                comment: "",
                code: "installSink();",
                awaits: false,
            }],
            ..Startup::NONE
        },
        ..SYNTHETIC[2]
    };
    let startup = compose::startup_dart(&[&sink]).unwrap().unwrap();
    assert!(
        startup.contains("void startup() {\n  installSink();\n}\n"),
        "{startup}"
    );
    let waits = Recipe {
        startup: Startup {
            steps: &[Step {
                kind: StepKind::Statement,
                phase: Phase::Rest,
                comment: "",
                code: "await warmUp();",
                awaits: true,
            }],
            ..Startup::NONE
        },
        ..sink
    };
    let startup = compose::startup_dart(&[&waits]).unwrap().unwrap();
    assert!(
        startup.contains("Future<void> startup() async {"),
        "{startup}"
    );
}

#[test]
fn two_zones_are_refused_naming_both() {
    let zoned = |id| Recipe {
        id,
        startup: Startup {
            zone: Some("Future<void> zone(Future<void> Function() body) => body();"),
            ..Startup::NONE
        },
        ..SYNTHETIC[2]
    };
    let (a, b) = (zoned("one"), zoned("two"));
    let message = format!("{:#}", compose::startup_dart(&[&a, &b]).unwrap_err());
    assert_eq!(
        message,
        "`one` and `two` both wrap main() in a zone(); an app has one"
    );
    // A zone alone is a startup file (and `startup()` returns nothing).
    let startup = compose::startup_dart(&[&a]).unwrap().unwrap();
    assert!(startup.contains("void startup() {\n}\n") || startup.contains("void startup()"));
}

#[test]
fn imports_are_sorted_and_deduplicated() {
    let plan = plan_of(SYNTHETIC, &["beta"]);
    let startup = file(&plan, "lib/app/startup.dart");
    // One block, `dart:` apart from `package:` by a blank line, as `dart format` leaves it.
    assert!(
        startup.starts_with(
            "import 'dart:async';\n\nimport 'package:fespalier/fespalier.dart';\nimport 'package:fespalier/startup.dart';\nimport 'package:zeta/zeta.dart';\n\n"
        ),
        "{startup}"
    );
    // app.dart and main.dart get their features' libraries in the same block.
    let app = file(&plan, "lib/app/app.dart");
    assert!(
        app.starts_with(
            "import 'package:fespalier/fespalier.dart';\nimport 'package:flutter/material.dart';\nimport 'package:zeta/zeta.dart';\n\n"
        ),
        "{app}"
    );
    let main = file(&plan, "lib/main.dart");
    assert!(
        main.starts_with("import 'dart:async';\n\nimport 'package:my_app/app.main.g.dart';\n"),
        "{main}"
    );
    // Without anything to add a file is left as it is, show clauses and all.
    let source = "import 'package:b/b.dart' show b;\nimport 'package:a/a.dart';\n\nvoid f() {}\n";
    assert_eq!(compose::merge_imports(source, &[]), source);
    assert_eq!(
        compose::merge_imports(source, &["package:a/a.dart", "dart:io", "package:c/c.dart"]),
        "import 'dart:io';\n\nimport 'package:a/a.dart';\nimport 'package:b/b.dart' show b;\nimport 'package:c/c.dart';\n\nvoid f() {}\n"
    );
}

#[test]
fn the_order_features_were_asked_in_changes_nothing() {
    let one = plan_of(RECIPES, &["storage", "connectivity"]).describe("<staging>");
    let two = plan_of(RECIPES, &["connectivity", "storage"]).describe("<staging>");
    let three = plan_of(RECIPES, &["all"]).describe("<staging>");
    assert_eq!(one, two);
    assert_eq!(one, three);
}

// --- the features -------------------------------------------------------------------------------

/// Every id of the real table, and `all`.
fn real_cases() -> Vec<Vec<&'static str>> {
    let mut cases: Vec<Vec<&str>> = RECIPES.iter().map(|r| vec![r.id]).collect();
    cases.push(vec!["all"]);
    cases
}

#[test]
fn golden_of_each_real_feature_alone_and_of_all() {
    for features in real_cases() {
        let plan = plan_of(RECIPES, &features);
        golden(
            &format!("feature-{}", features[0]),
            &plan.describe("<staging>"),
        );
    }
    let mut req = request("my_app");
    req.features = vec!["all".into()];
    req.local_packages = Some("/checkout".into());
    golden(
        "feature-all-local",
        &ok(&req, RECIPES).describe("<staging>"),
    );
}

#[test]
fn all_is_every_feature_of_the_table() {
    let ids: Vec<&str> = RECIPES.iter().map(|r| r.id).collect();
    assert_eq!(plan_of(RECIPES, &["all"]).features, ids);
    // It is asking for each one, so a conflict between two of them is still a conflict.
    let mut req = request("my_app");
    req.features = vec!["all".into()];
    assert_eq!(
        err(&req, SYNTHETIC),
        "`alpha` and `gamma` cannot be combined"
    );
}

#[test]
fn every_real_feature_is_pinned_and_overridden_at_the_checkout() {
    let plan = plan_of(RECIPES, &["all"]);
    let pubspec = file(&plan, "pubspec.yaml");
    let companions: BTreeSet<&str> = RECIPES
        .iter()
        .flat_map(|r| r.companions.iter().copied())
        .collect();
    let refs = pubspec
        .lines()
        .filter_map(|l| l.trim().strip_prefix("ref: "))
        .count();
    let tagged = pubspec
        .lines()
        .filter(|l| l.trim() == format!("ref: {REF}"))
        .count();
    // fespalier and each companion, all at this version's tag.
    assert_eq!(tagged, 1 + companions.len(), "{pubspec}");
    assert_eq!(refs, tagged, "{pubspec}");
    for companion in &companions {
        assert!(
            pubspec.contains(&format!("  {companion}:\n    git:")),
            "{pubspec}"
        );
    }
    // At a checkout the overrides are the app's packages and what they depend on, nothing else.
    let mut req = request("my_app");
    req.features = vec!["all".into()];
    req.local_packages = Some("/checkout".into());
    let local = ok(&req, RECIPES);
    let pubspec = file(&local, "pubspec.yaml");
    let overrides = pubspec.split("dependency_overrides:\n").nth(1).unwrap();
    let names: Vec<&str> = overrides
        .lines()
        .filter_map(|l| l.strip_prefix("  ").and_then(|l| l.strip_suffix(':')))
        .collect();
    let mut want: Vec<String> =
        recipes::companion_closure(&companions.iter().copied().collect::<Vec<_>>());
    want.push("fespalier".to_string());
    want.sort();
    assert_eq!(names, want);
    assert!(!pubspec.contains("git:"), "{pubspec}");
}

#[test]
fn storage_and_connectivity_start_up_as_the_docs_say() {
    let plan = plan_of(RECIPES, &["all"]);
    let startup = file(&plan, "lib/app/startup.dart");
    // docs/data.md, "A cache on disk" and "Reconnects": one override each, the disk one awaited.
    assert!(
        startup.contains("dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),"),
        "{startup}"
    );
    assert!(
        startup.contains("reconnectSignal.overrideWith(ConnectivitySignal.new),"),
        "{startup}"
    );
    assert!(startup.contains("Future<List<Override>> startup() async => ["));
    let tests: Vec<&str> = plan
        .files
        .iter()
        .map(|f| f.path.as_str())
        .filter(|p| p.starts_with("test/"))
        .collect();
    assert_eq!(
        tests,
        ["test/storage_test.dart", "test/connectivity_test.dart"]
    );
}
