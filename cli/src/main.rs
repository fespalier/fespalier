mod dart;
mod diag;
mod emit;
mod resolve;
mod scaffold;
mod scan;
mod templates;

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use std::{env, fs, process};

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use notify_debouncer_mini::{new_debouncer, notify::RecursiveMode};

#[derive(Parser)]
#[command(name = "fsp", version, about = "File-tree routing for Flutter")]
struct Cli {
    /// Flutter project root (defaults to the nearest folder with a pubspec.yaml)
    #[arg(long, global = true)]
    project: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Check lib/app/ and write lib/app.g.dart
    Gen,
    /// Check lib/app/ only; non-zero exit on errors (for CI)
    Check,
    /// Regenerate on every change under lib/app/
    Watch,
    /// Scaffold a route: `fsp new products/[id] --data --loading --error`
    New(scaffold::NewArgs),
}

fn main() {
    let cli = Cli::parse();
    let result = (|| {
        let project = find_project(cli.project)?;
        match cli.cmd {
            Cmd::Gen => gen(&project, true).map(|_| ()),
            Cmd::Check => gen(&project, false).map(|_| ()),
            Cmd::Watch => watch(&project),
            Cmd::New(args) => {
                scaffold::new_route(&project, &args)?;
                gen(&project, true).map(|_| ())
            }
        }
    })();
    if let Err(e) = result {
        eprintln!("{e:#}");
        process::exit(1);
    }
}

fn find_project(explicit: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(p) = explicit {
        return Ok(p);
    }
    let mut dir = env::current_dir()?;
    loop {
        if dir.join("pubspec.yaml").exists() {
            return Ok(dir);
        }
        if !dir.pop() {
            bail!("no pubspec.yaml here or above; pass --project");
        }
    }
}

pub struct Outcome {
    pub wrote: bool,
    pub routes: usize,
}

/// Scan, check, and (if `write`) emit. Errors are printed per file.
pub fn gen(project: &Path, write: bool) -> Result<Outcome> {
    let app_dir = project.join("lib/app");
    if !app_dir.is_dir() {
        bail!("{} not found", app_dir.display());
    }
    let (code, diags, routes) = build(&app_dir)?;
    diag::render(&app_dir, &diags);
    if diags.has_errors() {
        bail!("{} error(s); lib/app.g.dart left unchanged", diags.error_count());
    }
    let out = project.join("lib/app.g.dart");
    let mut wrote = false;
    if write && fs::read_to_string(&out).ok().as_deref() != Some(code.as_str()) {
        fs::write(&out, &code).with_context(|| format!("writing {}", out.display()))?;
        wrote = true;
    }
    Ok(Outcome { wrote, routes })
}

pub fn build(app_dir: &Path) -> Result<(String, diag::Diags, usize)> {
    let mut diags = diag::Diags::default();
    let tree = scan::scan(app_dir, &mut diags)?;
    let app = resolve::resolve(&tree, &mut diags);
    let routes = app.routes.iter().filter(|r| r.page.is_some()).count();
    let code = emit::emit(&app, &mut diags);
    Ok((code, diags, routes))
}

fn watch(project: &Path) -> Result<()> {
    let run = || {
        let t = Instant::now();
        match gen(project, true) {
            Ok(o) => eprintln!(
                "✓ {} routes {} in {:?}",
                o.routes,
                if o.wrote { "→ lib/app.g.dart" } else { "(unchanged)" },
                t.elapsed()
            ),
            Err(e) => eprintln!("{e:#}"),
        }
    };
    run();
    let (tx, rx) = mpsc::channel();
    // Editors save in bursts; one regeneration per burst.
    let mut debouncer = new_debouncer(Duration::from_millis(80), tx)?;
    debouncer.watcher().watch(&project.join("lib/app"), RecursiveMode::Recursive)?;
    eprintln!("watching lib/app/ …");
    for events in rx {
        if events.is_ok() {
            run();
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
