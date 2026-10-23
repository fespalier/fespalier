//! Tests of `fsp add`'s plan (`add/plan.rs`); the run against a stand-in flutter is in
//! `tests/cli.rs`, and `scripts/check-create.sh add` runs the real one.
//!
//! The goldens are in `tests/golden/add/`; `FSP_UPDATE_GOLDEN=1 cargo test add_tests::` rewrites
//! them. They show `v<version>` where the plan has this crate's own version.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use serde_yaml_ng::Value;

use crate::add::plan::{self, Request, Write, diff};
use crate::create::plan::{self as create_plan, DirState, REF};
use crate::create::recipes::RECIPES;

/// An app on disk, in memory: path to text.
type Tree = BTreeMap<String, String>;

/// What `fsp create` writes for `features`, as a tree (the files `flutter create` makes besides are
/// none of the plan's business). `local` is a checkout for `--local-packages`.
fn created(features: &[&str], local: Option<&str>) -> Tree {
    let req = create_plan::Request {
        dir: PathBuf::from("my_app"),
        dir_state: DirState::Absent,
        name: None,
        org: None,
        platforms: vec![],
        description: None,
        features: features.iter().map(|f| (*f).to_string()).collect(),
        template: None,
        local_packages: local.map(str::to_string),
        no_pub_get: false,
        offline: false,
        flutter: None,
    };
    let plan = create_plan::build(&req, RECIPES).unwrap_or_else(|e| panic!("{e:#}"));
    plan.files
        .into_iter()
        .map(|f| (f.path, f.content))
        .collect()
}

fn plan_for(tree: &Tree, features: &[&str]) -> anyhow::Result<plan::Plan> {
    let features: Vec<String> = features.iter().map(|f| (*f).to_string()).collect();
    let files: Tree = plan::paths(RECIPES)
        .into_iter()
        .filter_map(|p| tree.get(&p).map(|c| (p, c.clone())))
        .collect();
    plan::build(
        &Request {
            features: &features,
            pubspec: &tree["pubspec.yaml"],
            files: &files,
        },
        RECIPES,
    )
}

fn ok(tree: &Tree, features: &[&str]) -> plan::Plan {
    plan_for(tree, features).unwrap_or_else(|e| panic!("{e:#}"))
}

fn err(tree: &Tree, features: &[&str]) -> String {
    format!("{:#}", plan_for(tree, features).unwrap_err())
}

/// `tree` with the plan written into it, as `fsp add` writes it.
fn write(tree: &mut Tree, plan: &plan::Plan) {
    if let Some(pubspec) = &plan.pubspec {
        tree.insert("pubspec.yaml".to_string(), pubspec.clone());
    }
    for file in &plan.files {
        let there = tree.contains_key(&file.path);
        assert_eq!(
            there,
            file.write == Write::Update,
            "{} ({})",
            file.path,
            file.write.word()
        );
        tree.insert(file.path.clone(), file.content.clone());
    }
}

fn yaml(text: &str) -> Value {
    serde_yaml_ng::from_str(text).unwrap()
}

/// The pubspec as a value, with the `test: skip:` list sorted: `fsp add` appends the routes in the
/// order the features come, `fsp create` in the table's.
fn pubspec_value(tree: &Tree) -> Value {
    let mut value = yaml(&tree["pubspec.yaml"]);
    if let Some(Value::Sequence(skip)) = value
        .get_mut("fespalier")
        .and_then(|f| f.get_mut("test"))
        .and_then(|t| t.get_mut("skip"))
    {
        skip.sort_by_key(|v| v.as_str().map(str::to_string));
    }
    value
}

fn golden(name: &str, text: &str) {
    let text = text.replace(REF, "v<version>");
    assert!(!text.contains(env!("CARGO_PKG_VERSION")));
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden/add")
        .join(format!("{name}.txt"));
    if std::env::var_os("FSP_UPDATE_GOLDEN").is_some() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &text).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        text,
        want,
        "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test add_tests::` in cli/",
        path.display()
    );
}

fn commands() -> Vec<String> {
    vec!["flutter pub get".to_string(), "fsp gen".to_string()]
}

/// Every feature `fsp add` takes: all but the one that is the tabs template.
fn addable() -> Vec<&'static str> {
    RECIPES
        .iter()
        .filter(|r| r.replaces.is_empty())
        .map(|r| r.id)
        .collect()
}

// --- What create makes --------------------------------------------------------------------------

/// Adding the features one at a time to the base app makes the app `fsp create` makes with all of
/// them, file for file (the pubspec as a value), in the table's order and backwards, and nothing is
/// left to do by hand: `fsp add` composes the files the way `fsp create` does.
fn adding_one_at_a_time_makes_what_create_makes(local: Option<&str>) {
    let features = addable();
    let want = created(&features, local);
    for order in [features.clone(), features.iter().rev().copied().collect()] {
        let mut tree = created(&[], local);
        for feature in &order {
            let plan = ok(&tree, &[feature]);
            assert_eq!(plan.features, [*feature]);
            assert!(
                plan.by_hand.is_empty(),
                "{feature} after {:?}: {:?}",
                plan.present,
                plan.by_hand
            );
            write(&mut tree, &plan);
        }
        let paths = |t: &Tree| t.keys().cloned().collect::<Vec<_>>();
        assert_eq!(paths(&tree), paths(&want), "{order:?}");
        for (path, content) in &want {
            if path == "pubspec.yaml" {
                assert_eq!(pubspec_value(&tree), pubspec_value(&want), "{order:?}");
            } else {
                assert_eq!(&tree[path], content, "{path} after {order:?}");
            }
        }
        // And every feature is now in the app.
        let again = ok(&tree, &features);
        assert!(again.is_empty(), "{:?}", again.features);
    }
}

#[test]
fn adding_the_features_one_at_a_time_makes_what_create_makes() {
    adding_one_at_a_time_makes_what_create_makes(None);
}

#[test]
fn against_a_checkout_too() {
    adding_one_at_a_time_makes_what_create_makes(Some("/work/fespalier"));
}

// --- Goldens ------------------------------------------------------------------------------------

#[test]
fn golden_of_storage_on_the_base_app() {
    let tree = created(&[], None);
    golden(
        "storage",
        &ok(&tree, &["storage"]).describe(&tree["pubspec.yaml"], &commands()),
    );
}

#[test]
fn golden_of_sentry_on_an_app_with_otel_and_http() {
    let tree = created(&["otel", "http"], None);
    golden(
        "sentry-on-otel-http",
        &ok(&tree, &["sentry"]).describe(&tree["pubspec.yaml"], &commands()),
    );
}

#[test]
fn golden_of_auth_on_a_checkout() {
    let tree = created(&[], Some("/work/fespalier"));
    golden(
        "auth-local",
        &ok(&tree, &["auth"]).describe(&tree["pubspec.yaml"], &commands()),
    );
}

// --- An app that is not fsp create's ------------------------------------------------------------

/// An app made by `flutter create` and `fsp init`, with the pubspec a person writes.
fn by_hand() -> Tree {
    let mut tree = Tree::new();
    tree.insert(
        "pubspec.yaml".to_string(),
        "name: shop
description: \"A shop.\"
version: 1.0.0+1

environment:
  sdk: ^3.9.0
  flutter: \">=3.35.0\"

dependencies:
  flutter:
    sdk: flutter
  # The router (docs/getting-started.md).
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier.git
      path: packages/fespalier
      ref: v0.21.0   # with every companion
  intl: any

dev_dependencies:
  flutter_test:
    sdk: flutter

flutter:
  uses-material-design: true
"
        .to_string(),
    );
    tree.insert(
        "lib/main.dart".to_string(),
        "import 'package:shop/app.main.g.dart';\n\nFuture<void> main() => AppMain.run();\n"
            .to_string(),
    );
    tree.insert(
        "lib/app/app.dart".to_string(),
        crate::init::starter("app", "shop"),
    );
    tree
}

#[test]
fn an_app_of_its_own_gets_the_pins_it_has_and_keeps_its_lines() {
    let tree = by_hand();
    let plan = ok(&tree, &["storage", "http"]);
    assert_eq!(plan.features, ["storage", "http"]);
    let pubspec = plan.pubspec.clone().unwrap();
    // Every line it had is still there, in its order.
    let mut lines = pubspec.lines();
    for line in tree["pubspec.yaml"].lines() {
        assert!(lines.any(|l| l == line), "`{line}` is gone:\n{pubspec}");
    }
    assert!(
        pubspec.contains(
            "  fespalier_http:\n    git:\n      url: https://github.com/fespalier/fespalier.git\n      path: packages/fespalier_http\n      ref: v0.21.0\n"
        ),
        "{pubspec}"
    );
    assert!(
        pubspec.contains("  http: \"^1.5.0\"\n  intl: any\n"),
        "{pubspec}"
    );
    assert!(
        pubspec.ends_with(
            "\n# Read by the `fsp` generator; docs/configuration.md lists every key.\nfespalier:\n  test:\n    # /headlines needs a transport: test/http_test.dart serves it from a FakeTransport.\n    skip: [/headlines]\n"
        ),
        "{pubspec}"
    );
    let written: Vec<(&str, Write)> = plan
        .files
        .iter()
        .map(|f| (f.path.as_str(), f.write))
        .collect();
    assert_eq!(
        written,
        [
            ("test/storage_test.dart", Write::New),
            ("lib/api.dart", Write::New),
            ("lib/app/headlines/data.dart", Write::New),
            ("lib/app/headlines/page.dart", Write::New),
            ("test/http_test.dart", Write::New),
            ("lib/app/startup.dart", Write::New),
        ]
    );
    assert!(plan.by_hand.is_empty(), "{:?}", plan.by_hand);
}

#[test]
fn a_shared_file_the_app_changed_gets_the_change_to_make_by_hand() {
    let mut tree = by_hand();
    let app = tree["lib/app/app.dart"].replace(
        "MaterialApp.router(",
        "MaterialApp.router(\n      title: 'Shop',",
    );
    tree.insert("lib/app/app.dart".to_string(), app);
    let plan = ok(&tree, &["i18n"]);
    assert!(plan.files.iter().all(|f| f.path != "lib/app/app.dart"));
    assert_eq!(plan.by_hand.len(), 1, "{:?}", plan.by_hand);
    let hand = &plan.by_hand[0];
    assert_eq!(hand.path, "lib/app/app.dart");
    assert!(hand.why.contains("so it is yours"), "{}", hand.why);
    assert!(
        hand.change
            .contains("+ import 'package:fespalier_tolgee/fespalier_tolgee.dart';"),
        "{}",
        hand.change
    );
    // The same app with the starter as `fsp init` wrote it gets the file rewritten.
    let plan = ok(&by_hand(), &["i18n"]);
    assert!(plan.by_hand.is_empty());
    assert!(
        plan.files
            .iter()
            .any(|f| f.path == "lib/app/app.dart" && f.write == Write::Update)
    );
}

#[test]
fn a_test_that_starts_the_app_follows_the_features_it_starts() {
    let tree = created(&["storage"], None);
    let plan = ok(&tree, &["auth"]);
    let storage = plan
        .files
        .iter()
        .find(|f| f.path == "test/storage_test.dart")
        .unwrap();
    assert_eq!(storage.write, Write::Update);
    assert!(
        storage
            .content
            .contains("FlutterSecureStorage.setMockInitialValues")
    );
    // Changed by the app, it is the app's: the change is printed instead.
    let mut edited = tree.clone();
    edited
        .get_mut("test/storage_test.dart")
        .unwrap()
        .push_str("// mine\n");
    let plan = ok(&edited, &["auth"]);
    assert!(
        plan.files
            .iter()
            .all(|f| f.path != "test/storage_test.dart")
    );
    assert_eq!(plan.by_hand[0].path, "test/storage_test.dart");
}

/// `fsp add` formats what it writes the way the app formats its code, so a shared file that only
/// `dart format` changed is still `fsp create`'s; a word changed is not.
#[test]
fn a_file_formatted_for_another_dart_is_still_fsp_creates() {
    let mut tree = created(&["storage"], None);
    let startup = tree["lib/app/startup.dart"].clone();
    let reformatted = startup
        .replace(
            "Future<List<Override>> startup() async => [",
            "Future<List<Override>> startup() async =>\n    [",
        )
        .replace("open()),\n];", "open())\n    ];");
    assert_ne!(reformatted, startup);
    assert!(plan::same_file(
        "lib/app/startup.dart",
        &reformatted,
        &startup
    ));
    assert!(!plan::same_file("pubspec.yaml", "a: 1\n", "a:  1\n"));
    tree.insert("lib/app/startup.dart".to_string(), reformatted);
    let plan = ok(&tree, &["connectivity"]);
    assert!(plan.by_hand.is_empty(), "{:?}", plan.by_hand);
    assert!(
        plan.files
            .iter()
            .any(|f| f.path == "lib/app/startup.dart" && f.write == Write::Update)
    );
    let mut edited = tree.clone();
    let mine = edited["lib/app/startup.dart"].replace("is saved here", "lives here");
    edited.insert("lib/app/startup.dart".to_string(), mine);
    assert_eq!(ok(&edited, &["connectivity"]).by_hand.len(), 1);
}

// --- Refusals -----------------------------------------------------------------------------------

#[test]
fn it_refuses_what_it_cannot_add() {
    let tree = created(&[], None);
    assert!(err(&tree, &[]).starts_with("fsp add needs a feature: devtools, adaptive, forms"));
    assert!(err(&tree, &["all"]).starts_with("`all` is for `fsp create`"));
    assert!(
        err(&tree, &["nope"]).starts_with("unknown feature `nope`; the features are devtools,"),
        "{}",
        err(&tree, &["nope"])
    );
    assert_eq!(
        err(&tree, &["adaptive"]),
        "`adaptive` takes the place of lib/app/layout.dart, lib/app/page.dart, lib/app/about/page.dart, which are the app's own: only `fsp create` makes it (`fsp create --template tabs`)"
    );
    let mut manual = tree.clone();
    manual
        .get_mut("pubspec.yaml")
        .unwrap()
        .push_str("fespalier:\n  main: manual\n");
    assert!(err(&manual, &["storage"]).contains("this app has `main: manual`"));
    let mut elsewhere = tree.clone();
    elsewhere
        .get_mut("pubspec.yaml")
        .unwrap()
        .push_str("fespalier:\n  app_dir: lib/pages\n");
    assert!(err(&elsewhere, &["storage"]).contains("sets `app_dir:` or `output:`"));
}

#[test]
fn it_refuses_companions_pinned_out_of_line() {
    let tree = created(&["http"], None);
    let mut odd = tree.clone();
    let pubspec = odd["pubspec.yaml"].replacen(
        &format!("path: packages/fespalier_http\n      ref: {REF}"),
        "path: packages/fespalier_http\n      ref: main",
        1,
    );
    assert_ne!(pubspec, odd["pubspec.yaml"]);
    odd.insert("pubspec.yaml".to_string(), pubspec);
    let e = err(&odd, &["storage"]);
    assert!(
        e.contains("fespalier_http (dependencies): https://github.com/fespalier/fespalier at main"),
        "{e}"
    );
    assert!(e.contains("`fsp upgrade --app` moves refs together"), "{e}");
    let mut none = tree;
    none.insert("pubspec.yaml".to_string(), "name: x\n".to_string());
    assert!(err(&none, &["storage"]).contains("does not list fespalier"));
}

#[test]
fn it_refuses_a_feature_some_of_whose_files_are_there() {
    let mut tree = created(&[], None);
    tree.insert(
        "lib/app/contact/page.dart".to_string(),
        "// mine\n".to_string(),
    );
    assert_eq!(
        err(&tree, &["forms"]),
        "`forms` writes lib/app/contact/action.dart, lib/app/contact/page.dart, test/forms_test.dart, and lib/app/contact/page.dart is there already; fsp add never writes over a file. Move it, or add the feature by hand: docs/cli.md, \"fsp create\", says what it adds"
    );
}

#[test]
fn it_refuses_a_flutter_below_the_features() {
    let mut tree = created(&[], None);
    let pubspec = tree["pubspec.yaml"].replace("flutter: \">=3.35.0\"", "flutter: \">=3.32.0\"");
    tree.insert("pubspec.yaml".to_string(), pubspec);
    assert_eq!(
        err(&tree, &["storage"]),
        "`storage` needs Flutter 3.35 or newer, and pubspec.yaml allows Flutter 3.32.0 (`environment: flutter:`); raise that first"
    );
}

#[test]
fn it_refuses_a_dart_older_than_the_files_it_writes() {
    let mut tree = created(&[], None);
    // fsp create writes the Dart its files are written in.
    assert!(
        tree["pubspec.yaml"].contains(&format!("  sdk: ^{}.0\n", crate::create::plan::BASE_DART))
    );
    let pubspec = tree["pubspec.yaml"].replace("sdk: ^3.9.0", "sdk: \">=3.5.0 <4.0.0\"");
    tree.insert("pubspec.yaml".to_string(), pubspec);
    assert_eq!(
        err(&tree, &["storage"]),
        "fsp add writes the files of `fsp create`, which are Dart 3.9 (`sdk: ^3.9.0`), and pubspec.yaml allows Dart 3.5.0 (`environment: sdk:`); raise that to ^3.9.0 first (Flutter 3.35 comes with Dart 3.9)"
    );
}

#[test]
fn a_feature_the_app_has_is_not_added_again() {
    let tree = created(&["forms"], None);
    let plan = ok(&tree, &["forms"]);
    assert!(plan.is_empty());
    assert_eq!(plan.notes, ["`forms` is in the app already"]);
    // Its package alone (added by hand) is not the feature: its files are written.
    let mut by_hand = created(&[], None);
    let pubspec = created(&["forms"], None)["pubspec.yaml"].clone();
    by_hand.insert("pubspec.yaml".to_string(), pubspec);
    let plan = ok(&by_hand, &["forms"]);
    assert!(plan.pubspec.is_none());
    assert_eq!(plan.files.len(), 3);
}

#[test]
fn a_flow_mapping_it_cannot_edit_is_refused_with_the_lines_to_write() {
    let mut tree = created(&[], None);
    let pubspec = tree["pubspec.yaml"].replace(
        "dev_dependencies:\n  flutter_lints: ^6.0.0\n  flutter_test:\n    sdk: flutter\n",
        "dev_dependencies: {flutter_lints: ^6.0.0, flutter_test: {sdk: flutter}}\n",
    );
    tree.insert("pubspec.yaml".to_string(), pubspec);
    let e = err(&tree, &["auth"]);
    assert!(
        e.starts_with("could not edit pubspec.yaml safely (`dev_dependencies:` is written on one line; fsp adds keys to a block mapping), so nothing was written. Make this change by hand, then run fsp add again:\n  under `dev_dependencies:` add:\n      flutter_secure_storage: \">=10.0.0 <12.0.0\""),
        "{e}"
    );
}

// --- The diff -----------------------------------------------------------------------------------

#[test]
fn the_diff_shows_two_lines_around_each_change() {
    let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\n";
    let new = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\n";
    assert_eq!(
        diff(old, new),
        "  a\n- b\n+ B\n  c\n  d\n  ...\n  h\n  i\n+ j\n"
    );
    assert_eq!(diff(old, old), "");
    assert_eq!(diff("", "x\n"), "+ x\n");
}
