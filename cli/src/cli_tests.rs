//! `fsp new` and the success lines. (The spawned-binary tests, including
//! `fsp watch`, are in `tests/cli.rs`.)

use std::fs;

use crate::scaffold::{self, NewArgs};
use crate::{generate, plural};

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

fn project() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    fs::write(dir.path().join("lib/app/page.dart"), HOME).unwrap();
    dir
}

fn args(route: &str, layout: bool) -> NewArgs {
    NewArgs {
        route: route.into(),
        name: None,
        function: false,
        not_found: false,
        data: false,
        action: false,
        loading: false,
        error: false,
        layout,
        guard: false,
        transition: false,
        nav: false,
        observe: false,
    }
}

#[test]
fn success_lines() {
    let dir = project();
    let o = generate(dir.path(), true).unwrap();
    assert_eq!(o.line(), "✓ 1 route → lib/app.g.dart");
    let o = generate(dir.path(), true).unwrap();
    assert_eq!(o.line(), "✓ 1 route, lib/app.g.dart unchanged");
    assert_eq!(plural(0, "route"), "0 routes");
    assert_eq!(plural(10, "route"), "10 routes");
}

#[test]
fn group_scaffold_writes_no_page() {
    let dir = project();
    let created = scaffold::new_route_opts(dir.path(), &args("(account)", true), false).unwrap();
    assert_eq!(created, vec!["lib/app/(account)/layout.dart".to_string()]);
    assert!(!dir.path().join("lib/app/(account)/page.dart").exists());
    // It must not collide with the root page.
    generate(dir.path(), true).expect("a group layout should check cleanly");
}

#[test]
fn group_with_nothing_to_write_is_an_error() {
    let dir = project();
    let e = scaffold::new_route_opts(dir.path(), &args("(account)", false), false)
        .unwrap_err()
        .to_string();
    assert!(
        e.contains("nothing to create") && e.contains("group"),
        "{e}"
    );
    assert!(!dir.path().join("lib/app/(account)/page.dart").exists());
}

#[test]
fn no_page_flag() {
    let dir = project();
    let created = scaffold::new_route_opts(dir.path(), &args("shop", true), true).unwrap();
    assert_eq!(created, vec!["lib/app/shop/layout.dart".to_string()]);
    assert!(!dir.path().join("lib/app/shop/page.dart").exists());
    let e = scaffold::new_route_opts(dir.path(), &args("other", false), true)
        .unwrap_err()
        .to_string();
    assert!(e.contains("--no-page"), "{e}");
    // A plain route still gets its page.
    let created = scaffold::new_route_opts(dir.path(), &args("plain", false), false).unwrap();
    assert_eq!(created, vec!["lib/app/plain/page.dart".to_string()]);
}

fn everything(route: &str, function: bool) -> NewArgs {
    NewArgs {
        function,
        not_found: true,
        data: true,
        action: true,
        loading: true,
        error: true,
        layout: true,
        guard: true,
        transition: true,
        nav: true,
        observe: true,
        ..args(route, true)
    }
}

/// What `fsp init` and `fsp new` write is already what `dart format` would write (what a new
/// app's `dart format --set-exit-if-changed .` needs), for short names and for names long
/// enough to make the formatter wrap. Without `dart` on PATH there is nothing to compare it
/// with: skip.
#[test]
fn scaffolded_files_are_dart_format_clean() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    crate::init::run(dir.path()).unwrap();
    for (route, function) in [
        ("orders/[orderId]", false),
        ("shops/:shop/items/:id/reviews", false),
        ("plain", false),
        ("fnplain", true),
        ("fn/[id]", true),
        ("fn2/[a]/[b]", true),
        ("x/[...rest]", false),
        (
            "a/very/long/folder/structure/[someLongSegmentName]/[anotherLongSegmentName]",
            false,
        ),
        (
            "fnlong/[someLongSegmentName]/[anotherLongSegmentName]",
            true,
        ),
    ] {
        let mut all = everything(route, function);
        // A catch-all matches every URL below it, so none of them is unknown.
        all.not_found = !route.contains("...");
        scaffold::new_route(dir.path(), &all).unwrap();
    }
    let mut checked = 0;
    let mut stack = vec![dir.path().join("lib/app")];
    while let Some(d) = stack.pop() {
        for entry in fs::read_dir(d).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|e| e == "dart") {
                let written = fs::read_to_string(&path).unwrap();
                let (formatted, warning) = crate::format::format_dart(&written, &path);
                if warning.is_some() {
                    return;
                }
                assert_eq!(
                    written,
                    formatted,
                    "{} is not dart-format clean",
                    path.display()
                );
                checked += 1;
            }
        }
    }
    assert!(checked > 40, "{checked}");
}

/// `fsp new --action` writes an action.dart that the generator reads without a complaint: the
/// segments of the path, then `input`, and a helper on the typed route.
#[test]
fn new_action_scaffolds_a_working_action_dart() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    crate::init::run(dir.path()).unwrap();
    let mut a = args("orders/[orderId]/refund", false);
    a.action = true;
    let created = scaffold::new_route(dir.path(), &a).unwrap();
    assert!(
        created.contains(&"lib/app/orders/$orderId/refund/action.dart".to_string()),
        "{created:?}"
    );
    let action = fs::read_to_string(
        dir.path()
            .join("lib/app/orders/$orderId/refund/action.dart"),
    )
    .unwrap();
    assert!(
        action.contains("Future<Object?> action(Ref ref, {required String orderId, required Object? input}) async =>\n    input;")
            || action.contains("Future<Object?> action(\n"),
        "{action}"
    );
    let (code, diags, _) = crate::build(
        &dir.path().join("lib/app"),
        &crate::config::Config::default(),
    )
    .unwrap();
    assert!(
        diags.0.iter().all(|d| !d.to_string().starts_with('✗')),
        "{:?}",
        diags.0
    );
    assert!(code.contains("static final submit = (WidgetRef ref, {required String orderId, required Object? input})"), "{code}");
    // It is not written over: the file is yours once it exists.
    assert!(scaffold::new_route(dir.path(), &a).is_err());
}

/// `fsp new --observe` writes an observe.dart that the generator reads without a complaint: the
/// three hooks, each with the segments of the path.
#[test]
fn new_observe_scaffolds_a_working_observe_dart() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    crate::init::run(dir.path()).unwrap();
    let mut a = args("orders/[orderId]", false);
    a.observe = true;
    let created = scaffold::new_route(dir.path(), &a).unwrap();
    assert!(
        created.contains(&"lib/app/orders/$orderId/observe.dart".to_string()),
        "{created:?}"
    );
    let observe =
        fs::read_to_string(dir.path().join("lib/app/orders/$orderId/observe.dart")).unwrap();
    for hook in [
        "void onEnter(Ref ref, {required String orderId}) {}",
        "void onFocus(Ref ref, {required String orderId}) {}",
        "void onLeave(Ref ref, {required String orderId}) {}",
    ] {
        assert!(observe.contains(hook), "{observe}");
    }
    let (code, diags, _) = crate::build(
        &dir.path().join("lib/app"),
        &crate::config::Config::default(),
    )
    .unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    assert!(
        code.contains("observeAttach(router, _observeAt, container: container);"),
        "{code}"
    );
    // It is not written over: the file is yours once it exists.
    assert!(scaffold::new_route(dir.path(), &a).is_err());
}

// --- `fsp init` and the commented `tasks:` example (since 0.9.0) -------------------------------

fn pubspec_of(dir: &std::path::Path) -> String {
    fs::read_to_string(dir.join("pubspec.yaml")).unwrap()
}

/// `fsp init` appends a block that is only comments, once, and what the pubspec means does not
/// change.
#[test]
fn init_appends_a_commented_tasks_example_once() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nversion: 1.0.0",
    )
    .unwrap();
    let before = crate::config::Pubspec::load(dir.path()).unwrap();
    crate::init::run(dir.path()).unwrap();
    let after_first = pubspec_of(dir.path());
    assert!(
        after_first.starts_with(
            "name: demo\nversion: 1.0.0\n\n# fsp dev reads tasks: from here (since 0.9.0;"
        ),
        "{after_first}"
    );
    assert!(
        after_first.ends_with("#     codegen: dart run build_runner build -d # fsp run codegen\n")
    );
    let after = crate::config::Pubspec::load(dir.path()).unwrap();
    assert_eq!(before.name, after.name);
    assert_eq!(before.config, after.config);
    // The next run finds the marker and leaves the file alone.
    crate::init::run(dir.path()).unwrap();
    assert_eq!(pubspec_of(dir.path()), after_first);
}

/// A second `fespalier:` key would be a duplicate, so with one there the example is not added.
#[test]
fn init_leaves_a_pubspec_with_a_fespalier_section_alone() {
    let dir = tempfile::tempdir().unwrap();
    let yaml = "name: demo\nfespalier:\n  format: false\n";
    fs::write(dir.path().join("pubspec.yaml"), yaml).unwrap();
    crate::init::run(dir.path()).unwrap();
    assert_eq!(pubspec_of(dir.path()), yaml);
}

/// Uncommenting the block gives a pubspec that parses and whose tasks are valid.
#[test]
fn the_tasks_example_is_valid_once_uncommented() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    crate::init::run(dir.path()).unwrap();
    let text = pubspec_of(dir.path());
    let (head, block) = text
        .split_once(crate::init::TASKS_MARKER)
        .expect("the marker");
    let block = block.split_once('\n').unwrap().1;
    let uncommented: String = block
        .lines()
        .map(|l| {
            format!(
                "{}\n",
                l.strip_prefix("# ")
                    .or_else(|| l.strip_prefix('#'))
                    .unwrap_or(l)
            )
        })
        .collect();
    let yaml = format!("{}\n{uncommented}", head.trim_end());
    let pubspec = crate::config::Pubspec::parse(&yaml).unwrap();
    let tasks = crate::tasks::Tasks::from_config(&pubspec.config).unwrap();
    let dev = tasks.dev();
    assert_eq!(dev.before.len(), 1);
    assert_eq!(dev.with.len(), 1);
    assert_eq!(dev.with[0].0, "build_runner");
    assert_eq!(tasks.names(), ["dev", "build", "codegen"]);
}

/// The template is comments only, after one blank line.
#[test]
fn the_init_template_is_comments_only() {
    let block = crate::templates::render("init/pubspec_tasks.yaml", ());
    assert!(block.starts_with('\n') && block.ends_with('\n'));
    assert!(block.lines().skip(1).all(|l| l.starts_with('#')), "{block}");
}
