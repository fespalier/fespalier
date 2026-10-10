//! `fsp init`: starter files for an existing Flutter project, then `gen`.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

use crate::config::{MainMode, Pubspec};
use crate::scan::FileStyle;
use crate::templates;

pub const STARTERS: [&str; 5] = ["layout", "page", "not_found", "transition", "app"];

/// What the starter templates are rendered with.
#[derive(serde::Serialize)]
struct Starter<'a> {
    package: &'a str,
}

/// The text of the starter file `kind` (one of [`STARTERS`]) for the package `package`: what
/// `fsp init` writes, and `fsp create` writes the same.
#[must_use]
pub fn starter(kind: &str, package: &str) -> String {
    templates::render(&format!("init/{kind}.dart"), Starter { package })
}

pub fn run(project: &Path) -> Result<()> {
    if !project.join("pubspec.yaml").is_file() {
        bail!(
            "no pubspec.yaml in {}; run `fsp init` inside a Flutter project or pass --project",
            project.display()
        );
    }
    let pubspec = Pubspec::load(project)?;
    let Some(package) = pubspec.name.clone() else {
        bail!("pubspec.yaml has no `name:`");
    };
    let cfg = &pubspec.config;
    let dir = project.join(&cfg.app_dir);
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    for kind in STARTERS {
        // `main: manual` keeps the app's own main(): no app.dart for the generated one to run.
        if kind == "app" && cfg.main == MainMode::Manual {
            continue;
        }
        // `file_style` picks the spelling; a file in the other one counts as existing.
        let (snake, kebab) = (
            format!("{kind}.dart"),
            format!("{}.dart", kind.replace('_', "-")),
        );
        let file = if cfg.file_style == FileStyle::Kebab {
            kebab.clone()
        } else {
            snake.clone()
        };
        let shown = format!("{}/{file}", cfg.app_dir);
        let path = dir.join(&file);
        if let Some(present) = [&snake, &kebab].into_iter().find(|f| dir.join(f).exists()) {
            let shown = format!("{}/{present}", cfg.app_dir);
            eprintln!("  skip  {shown} (exists)");
            continue;
        }
        fs::write(&path, starter(kind, &package))?;
        eprintln!("  new   {shown}");
    }

    let o = crate::gen_with(project, &cfg.for_scaffolding(), true)?;
    eprintln!("{}", o.line());
    tasks_example(project)?;

    let mut step = 0;
    let mut next = |title: &str| {
        step += 1;
        eprintln!("\n{step}. {title}");
    };
    eprintln!("\nNext steps");
    if !pubspec.has_dependency {
        next("Add the dependency to pubspec.yaml, then run `flutter pub get`:");
        eprintln!(
            "\n   dependencies:\n     fespalier:\n       git:\n         url: https://github.com/fespalier/fespalier\n         path: packages/fespalier\n         ref: v0.15.0" // x-release-please-version
        );
    }
    if cfg.main == MainMode::Manual {
        next("Run the router from lib/main.dart:");
        eprintln!(
            "\n   import 'package:fespalier/fespalier.dart';\n   import 'package:flutter/material.dart';\n   import 'package:{package}/{}';\n\n   void main() => runApp(\n         ProviderScope(\n           child: MaterialApp.router(routerConfig: AppRoutes.router()),\n         ),\n       );",
            cfg.output_in_lib()
        );
        eprintln!(
            "\n   Already have a GoRouter? Mount the tree inside it instead:\n\n   GoRouter(routes: [...yourRoutes, ...AppRoutes.mount(at: '/x')])"
        );
    } else {
        let main_file = cfg.output_main();
        let main_in_lib = main_file.strip_prefix("lib/").unwrap_or(&main_file);
        next(&format!(
            "Make lib/main.dart run the generated main() ({main_file}):"
        ));
        eprintln!(
            "\n   import 'package:{package}/{main_in_lib}';\n\n   Future<void> main() => AppMain.run();"
        );
        eprintln!(
            "\n   The app around the router (theme, title) is {dir}/app.dart; work to do before it starts goes\n   in {dir}/startup.dart (see docs/app-startup.md).\n   Already have a GoRouter? Mount the tree inside it instead, and set `main: manual`:\n\n   GoRouter(routes: [...yourRoutes, ...AppRoutes.mount(at: '/x')])",
            dir = cfg.app_dir
        );
    }
    next(
        "Run `fsp dev` to start the app: it regenerates on every save and hot restarts (or `fsp watch` next to `flutter run`).",
    );
    Ok(())
}

/// The line that says a pubspec already has the commented `tasks:` example.
pub const TASKS_MARKER: &str = "# fsp dev reads tasks:";

/// Appends the commented `tasks:` example to pubspec.yaml (since 0.9.0), when it has no
/// `fespalier:` key yet: uncommenting the block then gives valid YAML. With the key there (a
/// second one would be a duplicate) it says where to read about it instead. The block is only
/// comments, so what the pubspec means does not change.
fn tasks_example(project: &Path) -> Result<()> {
    let path = project.join("pubspec.yaml");
    let mut text =
        fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    if text.lines().any(|l| l.starts_with(TASKS_MARKER)) {
        eprintln!("  skip  pubspec.yaml tasks example (exists)");
    } else if text.lines().any(|l| l.starts_with("fespalier:")) {
        eprintln!(
            "  skip  pubspec.yaml tasks example (fespalier: is already there; docs/cli.md, \"Tasks: commands around `flutter run`\")"
        );
    } else {
        if !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(&templates::render("init/pubspec_tasks.yaml", ()));
        fs::write(&path, text).with_context(|| format!("writing {}", path.display()))?;
        eprintln!("  edit  pubspec.yaml (a commented tasks: example for fsp dev)");
    }
    Ok(())
}
