//! `fsp init`: starter files for an existing Flutter project, then `gen`.

use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

use crate::config::Pubspec;
use crate::scan::FileStyle;
use crate::templates;

const STARTERS: [&str; 4] = ["layout", "page", "not_found", "transition"];

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
        fs::write(&path, templates::render(&format!("init/{kind}.dart"), ()))?;
        eprintln!("  new   {shown}");
    }

    let o = crate::gen_with(project, cfg, true)?;
    eprintln!("{}", o.line());

    let mut step = 0;
    let mut next = |title: &str| {
        step += 1;
        eprintln!("\n{step}. {title}");
    };
    eprintln!("\nNext steps");
    if !pubspec.has_dependency {
        next("Add the dependency to pubspec.yaml, then run `flutter pub get`:");
        eprintln!(
            "\n   dependencies:\n     fespalier:\n       git:\n         url: https://github.com/vaam-apps/fespalier\n         path: packages/fespalier\n         ref: v0.6.0" // x-release-please-version
        );
    }
    next("Run the router from lib/main.dart:");
    eprintln!(
        "\n   import 'package:fespalier/fespalier.dart';\n   import 'package:flutter/material.dart';\n   import 'package:{package}/{}';\n\n   void main() => runApp(\n         ProviderScope(\n           child: MaterialApp.router(routerConfig: AppRoutes.router()),\n         ),\n       );",
        cfg.output_in_lib()
    );
    eprintln!(
        "\n   Already have a GoRouter? Mount the tree inside it instead:\n\n   GoRouter(routes: [...yourRoutes, ...AppRoutes.mount(at: '/x')])"
    );
    next("Run `fsp watch` next to `flutter run` to regenerate on every save.");
    Ok(())
}
