mod config;
mod dart;
mod diag;
mod emit;
mod extra;
mod format;
mod init;
mod manifest;
mod parse_cache;
mod resolve;
mod routes;
mod scaffold;
mod scan;
mod templates;

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use std::{env, fs, process};

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use config::Config;
use notify::event::ModifyKind;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

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
    /// Check the app folder (lib/app/) and write the generated file (lib/app.g.dart)
    Gen {
        /// Run `dart format` on the generated file (needs `dart` on PATH; or set `format: true` in pubspec.yaml)
        #[arg(long)]
        format: bool,
        /// Print diagnostics to stdout as JSON lines (file, line, column, severity, message)
        #[arg(long)]
        json: bool,
    },
    /// Check the app folder only; non-zero exit on errors (for CI)
    Check {
        /// Print diagnostics to stdout as JSON lines (file, line, column, severity, message)
        #[arg(long)]
        json: bool,
    },
    /// Print the route table: pattern, route class, file, tags
    Routes {
        /// One JSON object per route, one per line
        #[arg(long)]
        json: bool,
    },
    /// Regenerate on every change under the app folder
    Watch,
    /// Set up an existing Flutter project: starter layout, page and not-found, then gen
    Init,
    /// Scaffold a route: `fsp new products/[id] --data --loading --error`
    New(scaffold::NewCmd),
}

fn main() {
    let cli = Cli::parse();
    let result = (|| {
        let project = find_project(cli.project)?;
        match cli.cmd {
            Cmd::Gen { format, json } => {
                let mut cfg = Config::load(&project)?;
                cfg.format |= format;
                eprintln!("{}", gen_opts(&project, &cfg, true, json)?.line());
                Ok(())
            }
            Cmd::Check { json } => {
                let o = gen_opts(&project, &Config::load(&project)?, false, json)?;
                eprintln!("✓ {}, no errors", plural(o.routes, "route"));
                Ok(())
            }
            Cmd::Routes { json } => routes::run(&project, json),
            Cmd::Watch => watch(&project),
            Cmd::Init => init::run(&project),
            Cmd::New(cmd) => {
                let created = scaffold::new_route_opts(&project, &cmd.args, cmd.no_page)?;
                match gen(&project, true) {
                    Ok(o) => {
                        eprintln!("{}", o.line());
                        Ok(())
                    }
                    Err(e) => {
                        let files: String = created.iter().map(|f| format!("\n  {f}")).collect();
                        Err(anyhow!("{e:#}\n\n`fsp new` created:{files}\nFix or delete them, then run `fsp gen`."))
                    }
                }
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

#[derive(Debug)]
pub struct Outcome {
    pub wrote: bool,
    pub routes: usize,
    /// The output file as the user spells it (`lib/app.g.dart`); with a separate
    /// manifest library, both, comma-separated.
    pub output: String,
}

impl Outcome {
    /// The success line shared by `gen`, `new`, `init` and `watch`.
    pub fn line(&self) -> String {
        let routes = plural(self.routes, "route");
        if self.wrote {
            format!("✓ {routes} → {}", self.output)
        } else {
            format!("✓ {routes}, {} unchanged", self.output)
        }
    }
}

pub fn plural(n: usize, noun: &str) -> String {
    if n == 1 { format!("1 {noun}") } else { format!("{n} {noun}s") }
}

/// Scan, check, and (if `write`) emit. Errors are printed per file.
pub fn gen(project: &Path, write: bool) -> Result<Outcome> {
    gen_with(project, &Config::load(project)?, write)
}

pub fn gen_with(project: &Path, cfg: &Config, write: bool) -> Result<Outcome> {
    gen_opts(project, cfg, write, false)
}

/// `json`: diagnostics go to stdout as JSON lines instead of the codespan rendering.
pub fn gen_opts(project: &Path, cfg: &Config, write: bool, json: bool) -> Result<Outcome> {
    gen_core(project, cfg, write, |app_dir, diags| {
        if json {
            diag::render_json(app_dir, &cfg.app_dir, diags)
        } else {
            diag::render(app_dir, &cfg.app_dir, diags)
        }
    })
}

/// `show` prints the diagnostics (watch mode skips ones it already showed).
fn gen_core(project: &Path, cfg: &Config, write: bool, show: impl FnOnce(&Path, &diag::Diags)) -> Result<Outcome> {
    let app_dir = project.join(&cfg.app_dir);
    if !app_dir.is_dir() {
        bail!("{} not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)", app_dir.display());
    }
    let (code, diags, app) = analyze(&app_dir, cfg)?;
    let routes = app.routes.iter().filter(|r| r.is_route()).count();
    show(&app_dir, &diags);
    if diags.has_errors() {
        let left = match &cfg.output_manifest {
            Some(m) => format!("{} and {m}", cfg.output),
            None => cfg.output.clone(),
        };
        bail!("{} error(s); {left} left unchanged", diags.error_count());
    }
    // The manifest is a second file when `output_manifest:` asks for one. `check`
    // renders it too, but writes and compares nothing.
    let mut files = vec![(cfg.output.clone(), code)];
    files.extend(cfg.output_manifest.clone().zip(manifest::emit(&app, cfg)));
    let mut wrote = false;
    for (path, mut code) in files {
        let out = project.join(&path);
        // `check` writes and compares nothing, so it never needs `dart`. `gen` formats
        // before comparing, so a formatted file that is up to date reads "unchanged".
        if write && cfg.format {
            let (formatted, warning) = format::format_dart(&code, &out);
            if let Some(w) = warning {
                eprintln!("{w}");
            }
            code = formatted;
        }
        if write && fs::read_to_string(&out).ok().as_deref() != Some(code.as_str()) {
            if let Some(dir) = out.parent() {
                fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
            }
            fs::write(&out, &code).with_context(|| format!("writing {}", out.display()))?;
            wrote = true;
        }
    }
    let output = match &cfg.output_manifest {
        Some(m) => format!("{}, {m}", cfg.output),
        None => cfg.output.clone(),
    };
    Ok(Outcome { wrote, routes, output })
}

pub fn build(app_dir: &Path, cfg: &Config) -> Result<(String, diag::Diags, usize)> {
    let (code, diags, app) = analyze(app_dir, cfg)?;
    let routes = app.routes.iter().filter(|r| r.is_route()).count();
    Ok((code, diags, routes))
}

/// Like [`build`], but keeps the resolved app (for `fsp routes`).
pub fn analyze(app_dir: &Path, cfg: &Config) -> Result<(String, diag::Diags, resolve::App)> {
    let mut diags = diag::Diags::default();
    let tree = scan::scan(app_dir, &mut diags)?;
    let app = resolve::resolve(&tree, cfg.case_sensitive, &mut diags);
    manifest::check(&app, cfg, &mut diags);
    let code = emit::emit(&app, cfg, &mut diags);
    Ok((code, diags, app))
}

/// Whether a filesystem event can change what the app folder generates.
/// Reads (`Access`, which the generator itself causes) and metadata-only changes
/// don't, and neither does the generated file when it lives in the app folder.
fn relevant(ev: &Event, outputs: &[PathBuf]) -> bool {
    let kind_matters = match ev.kind {
        EventKind::Access(_) | EventKind::Modify(ModifyKind::Metadata(_)) => false,
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(_) | EventKind::Any | EventKind::Other => true,
    };
    kind_matters && (ev.paths.is_empty() || ev.paths.iter().any(|p| !outputs.contains(p)))
}

/// What `watch` last showed, so an unchanged rerun stays quiet.
#[derive(Default)]
struct Shown {
    /// The diagnostics last printed.
    diags: String,
    /// Diagnostics plus the error line (empty after a clean run).
    outcome: String,
}

fn watch(project: &Path) -> Result<()> {
    let cfg = Config::load(project)?;
    let app_dir = project.join(&cfg.app_dir);
    let outputs: Vec<PathBuf> = [Some(&cfg.output), cfg.output_manifest.as_ref()].into_iter().flatten().map(|o| project.join(o)).collect();
    let mut shown = Shown::default();
    // A save changes one file: keep the parse results of the others between runs.
    parse_cache::enable();
    let mut run = |first: bool| {
        let t = Instant::now();
        let mut diags = String::new();
        let result = gen_core(project, &cfg, true, |dir, d| {
            diags = d.0.iter().map(|d| d.to_string()).collect::<Vec<_>>().join("\n");
            if diags != shown.diags {
                diag::render(dir, &cfg.app_dir, d);
            }
        });
        let outcome = match &result {
            Ok(_) => diags.clone(),
            Err(e) => format!("{diags}\n{e:#}"),
        };
        let quiet = !first && outcome == shown.outcome;
        match result {
            Ok(o) if o.wrote || !quiet => eprintln!("{} ({:.1?})", o.line(), t.elapsed()),
            Err(e) if !quiet => eprintln!("{e:#}"),
            _ => {}
        }
        shown = Shown { diags, outcome };
        parse_cache::finish_run();
    };
    run(true);

    let (tx, rx) = mpsc::channel();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| match res {
            Ok(ev) if relevant(&ev, &outputs) => {
                let _ = tx.send(());
            }
            Ok(_) => {}
            Err(e) => eprintln!("watch error: {e}"),
        },
        notify::Config::default(),
    )?;
    watcher.watch(&app_dir, RecursiveMode::Recursive)?;
    eprintln!("watching {}/ …", cfg.app_dir);
    while rx.recv().is_ok() {
        // Editors save in bursts; one regeneration per burst.
        while rx.recv_timeout(Duration::from_millis(80)).is_ok() {}
        run(false);
    }
    Ok(())
}

#[cfg(test)]
mod case_tests;
#[cfg(test)]
mod cli_tests;
#[cfg(test)]
mod extra_tests;
#[cfg(test)]
mod manifest_tests;
#[cfg(test)]
mod match_tests;
#[cfg(test)]
mod nav_tests;
#[cfg(test)]
mod navigator_tests;
#[cfg(test)]
mod paths_tests;
#[cfg(test)]
mod refresh_tests;
#[cfg(test)]
mod rest_types_tests;
#[cfg(test)]
mod route_api_tests;
#[cfg(test)]
mod selector_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod views_tests;
