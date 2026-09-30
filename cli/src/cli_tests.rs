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
        loading: false,
        error: false,
        layout,
        guard: false,
        transition: false,
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
        loading: true,
        error: true,
        layout: true,
        guard: true,
        transition: true,
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
