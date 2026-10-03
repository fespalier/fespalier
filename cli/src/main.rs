mod config;
mod dart;
mod devtools;
mod diag;
mod emit;
mod enums;
mod extra;
mod format;
mod graph;
mod init;
mod links;
mod lint;
mod locale;
mod maestro;
mod manifest;
mod parse_cache;
mod resolve;
mod routes;
mod scaffold;
mod scan;
mod segtype;
mod session;
mod size;
mod templates;

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};
use std::{env, fs, process};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand};
use config::Config;
use notify::event::ModifyKind;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use session::{Run, Session};

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
        #[arg(long, conflicts_with = "graph")]
        json: bool,
        /// The route tree as a graph: `mermaid` (the default) or `dot`; or `json`, the tree the DevTools extension reads
        #[arg(long, value_enum, num_args = 0..=1, default_missing_value = "mermaid", value_name = "FORMAT")]
        graph: Option<graph::Format>,
    },
    /// Write App Links, Universal Links and a sitemap from the routes (`links:` in pubspec.yaml)
    Links {
        /// Write nothing; exit non-zero when the files on disk are not what `fsp links` would write
        #[arg(long)]
        check: bool,
    },
    /// Write Maestro smoke flows, one per route, from the routes (`maestro:` in pubspec.yaml)
    Maestro {
        /// Write nothing; exit non-zero when the flows on disk are not what `fsp maestro` would write
        #[arg(long)]
        check: bool,
    },
    /// Report the web build's JavaScript per deferred route, and check the budgets (`size:` in pubspec.yaml)
    Size {
        /// The `flutter build web` output folder (default: `size.build` in pubspec.yaml, else build/web)
        #[arg(long, value_name = "DIR")]
        build: Option<PathBuf>,
        /// Print the report to stdout as JSON lines (main.dart.js, each deferred route, each part)
        #[arg(long)]
        json: bool,
        /// Exit non-zero when a budget in `size:` is exceeded
        #[arg(long)]
        check: bool,
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
            Cmd::Routes { json, graph } => routes::run(&project, json, graph),
            Cmd::Links { check } => links::run(&project, check),
            Cmd::Maestro { check } => maestro::run(&project, check),
            Cmd::Size { build, json, check } => size::run(&project, build.as_deref(), json, check),
            Cmd::Watch => watch(&project),
            Cmd::Init => init::run(&project),
            Cmd::New(cmd) => {
                let created = scaffold::new_route_opts(&project, &cmd.args, cmd.no_page)?;
                match gen_with(&project, &Config::load(&project)?.for_scaffolding(), true) {
                    Ok(o) => {
                        eprintln!("{}", o.line());
                        Ok(())
                    }
                    Err(e) => {
                        let files: String = created.iter().map(|f| format!("\n  {f}")).collect();
                        Err(anyhow!(
                            "{e:#}\n\n`fsp new` created:{files}\nFix or delete them, then run `fsp gen`."
                        ))
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
    #[must_use]
    pub fn line(&self) -> String {
        let routes = plural(self.routes, "route");
        if self.wrote {
            format!("✓ {routes} → {}", self.output)
        } else {
            format!("✓ {routes}, {} unchanged", self.output)
        }
    }
}

#[must_use]
pub fn plural(n: usize, noun: &str) -> String {
    if n == 1 {
        format!("1 {noun}")
    } else {
        format!("{n} {noun}s")
    }
}

/// Scan, check, and (if `write`) emit. Errors are printed per file.
pub fn generate(project: &Path, write: bool) -> Result<Outcome> {
    gen_with(project, &Config::load(project)?, write)
}

pub fn gen_with(project: &Path, cfg: &Config, write: bool) -> Result<Outcome> {
    gen_opts(project, cfg, write, false)
}

/// `json`: diagnostics go to stdout as JSON lines instead of the codespan rendering.
pub fn gen_opts(project: &Path, cfg: &Config, write: bool, json: bool) -> Result<Outcome> {
    gen_core(
        project,
        cfg,
        write,
        &mut Session::default(),
        |app_dir, diags| {
            if json {
                diag::render_json(app_dir, &cfg.app_dir, diags);
            } else {
                diag::render(app_dir, &cfg.app_dir, diags);
            }
        },
    )
}

/// `show` prints the diagnostics (watch mode skips ones it already showed). `session` is what
/// `watch` keeps from run to run; every other command passes a new one.
fn gen_core(
    project: &Path,
    cfg: &Config,
    write: bool,
    session: &mut Session,
    show: impl FnOnce(&Path, &diag::Diags),
) -> Result<Outcome> {
    let app_dir = project.join(&cfg.app_dir);
    if !app_dir.is_dir() {
        bail!(
            "{} not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)",
            app_dir.display()
        );
    }
    let mut diags = diag::Diags::default();
    let tree = scan::scan(&app_dir, &mut diags)?;
    let scan_diags = format!("{diags:?}");
    let libs = enums::Libs::for_app(&app_dir, cfg);
    let (run, reads) = if let Some(kept) = session.last.reuse(&tree, &scan_diags, &libs) {
        kept
    } else {
        let (code, app) = analyze_tree(&tree, cfg, &libs, &mut diags);
        let routes = app.routes.iter().filter(|r| r.is_route()).count();
        // The manifest is a second file when `output_manifest:` asks for one. `check`
        // renders it too, but writes and compares nothing.
        let mut files = vec![];
        let mut table = lint::Table::default();
        if !diags.has_errors() {
            files.push((cfg.output.clone(), code));
            files.extend(cfg.output_manifest.clone().zip(manifest::emit(&app, cfg)));
            table = lint::Table::new(&app);
        }
        (
            Run {
                diags,
                routes,
                files,
                table,
            },
            libs.reads(),
        )
    };
    let run = session.last.keep(tree, scan_diags, reads, run);
    // The lint reads files outside the tree, so it runs on every run, reused or not. A tree
    // with errors is half resolved and would make every path look unknown.
    let lints = if run.diags.has_errors() {
        diag::Diags::default()
    } else {
        lint::check(project, cfg, &run.table, &mut session.sites)
    };
    let mut everything = run.diags.clone();
    everything.0.extend(lints.0.iter().cloned());
    show(&app_dir, &everything);
    if run.diags.has_errors() {
        let left = match &cfg.output_manifest {
            Some(m) => format!("{} and {m}", cfg.output),
            None => cfg.output.clone(),
        };
        bail!(
            "{} error(s); {left} left unchanged",
            run.diags.error_count()
        );
    }
    let mut wrote = false;
    for (path, code) in &run.files {
        let out = project.join(path);
        // `check` writes and compares nothing, so it never needs `dart`. `gen` formats
        // before comparing, so a formatted file that is up to date reads "unchanged".
        // `watch` doesn't run `dart` again on code it has formatted before.
        let code = if write && cfg.format {
            session
                .formats
                .get(path, code, |code| format::format_dart(code, &out))
        } else {
            code.clone()
        };
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
    // A lint error fails the command but not the output: the generated file does not depend on
    // it, and `watch` must not stop regenerating for a typo in some other file.
    if lints.has_errors() {
        let n = lints.error_count();
        if write {
            bail!(
                "{n} error(s) in string paths (`lints: unknown_path: error`); {output} is up to date"
            );
        }
        bail!("{n} error(s) in string paths (`lints: unknown_path: error`)");
    }
    Ok(Outcome {
        wrote,
        routes: run.routes,
        output,
    })
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
    let libs = enums::Libs::for_app(app_dir, cfg);
    let (code, app) = analyze_tree(&tree, cfg, &libs, &mut diags);
    Ok((code, diags, app))
}

/// Everything after the scan: resolve, check the manifest, emit. A function of the tree, the
/// configuration and the files `libs` reads (see [`enums::Libs::reads`]), which is what lets
/// `watch` skip it for a tree it has seen.
fn analyze_tree(
    tree: &scan::Node,
    cfg: &Config,
    libs: &enums::Libs,
    diags: &mut diag::Diags,
) -> (String, resolve::App) {
    let _warm = parse_cache::prewarm(tree);
    let app = resolve::resolve(
        tree,
        cfg.case_sensitive,
        cfg.remount,
        cfg.deferred,
        libs,
        diags,
    );
    manifest::check(&app, cfg, diags);
    let code = emit::emit(&app, cfg, diags);
    (code, app)
}

/// Whether a filesystem event can change what the app folder generates.
/// Reads (`Access`, which the generator itself causes) and metadata-only changes
/// don't, and neither does the generated file when it lives in the app folder.
/// `watch` also sees `lib/` outside the app folder, because an enum a segment names is
/// declared there (`lib/models/category.dart`): of those paths only Dart files and folders
/// (a path with no extension) count, not the `.png` or `.json` beside them.
fn relevant(ev: &Event, outputs: &[PathBuf], app_dir: &Path) -> bool {
    let kind_matters = match ev.kind {
        EventKind::Access(_) | EventKind::Modify(ModifyKind::Metadata(_)) => false,
        EventKind::Create(_)
        | EventKind::Remove(_)
        | EventKind::Modify(_)
        | EventKind::Any
        | EventKind::Other => true,
    };
    let matters = |p: &PathBuf| {
        !outputs.contains(p)
            && (p.starts_with(app_dir) || p.extension().is_none_or(|e| e == "dart"))
    };
    kind_matters && (ev.paths.is_empty() || ev.paths.iter().any(matters))
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
    let outputs: Vec<PathBuf> = [Some(&cfg.output), cfg.output_manifest.as_ref()]
        .into_iter()
        .flatten()
        .map(|o| project.join(o))
        .collect();
    let mut shown = Shown::default();
    // A save changes one file: keep the parse results of the others between runs, and the
    // last run's result and formatted text (see session.rs).
    parse_cache::enable();
    let mut session = Session::default();
    let mut run = |first: bool| {
        let t = Instant::now();
        let mut diags = String::new();
        let result = gen_core(project, &cfg, true, &mut session, |dir, d| {
            diags =
                d.0.iter()
                    .map(std::string::ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("\n");
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
    let changes_under = app_dir.clone();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| match res {
            Ok(ev) if relevant(&ev, &outputs, &changes_under) => {
                let _ = tx.send(());
            }
            Ok(_) => {}
            Err(e) => eprintln!("watch error: {e}"),
        },
        notify::Config::default(),
    )?;
    // The app folder, and the rest of `lib/` too when it is there: that is where the enums are
    // that segments and query parameters name, and editing one must regenerate.
    let lib = project.join("lib");
    let watched = if app_dir.starts_with(&lib) && lib.is_dir() {
        lib
    } else {
        app_dir.clone()
    };
    watcher.watch(&watched, RecursiveMode::Recursive)?;
    eprintln!("watching {}/ …", cfg.app_dir);
    while rx.recv().is_ok() {
        // Editors save in bursts; one regeneration per burst.
        while rx.recv_timeout(Duration::from_millis(80)).is_ok() {}
        run(false);
    }
    Ok(())
}

#[cfg(test)]
mod action_tests;
#[cfg(test)]
mod bench;
#[cfg(test)]
mod case_tests;
#[cfg(test)]
mod cli_tests;
#[cfg(test)]
mod deferred_tests;
#[cfg(test)]
mod devtools_tests;
#[cfg(test)]
mod enum_tests;
#[cfg(test)]
mod extra_tests;
#[cfg(test)]
mod graph_tests;
#[cfg(test)]
mod incremental_tests;
#[cfg(test)]
mod links_tests;
#[cfg(test)]
mod lint_tests;
#[cfg(test)]
mod locale_tests;
#[cfg(test)]
mod maestro_tests;
#[cfg(test)]
mod manifest_tests;
#[cfg(test)]
mod match_tests;
#[cfg(test)]
mod nav_tests;
#[cfg(test)]
mod navigator_tests;
#[cfg(test)]
mod nest_tests;
#[cfg(test)]
mod paths_tests;
#[cfg(test)]
mod refresh_tests;
#[cfg(test)]
mod remount_tests;
#[cfg(test)]
mod rest_types_tests;
#[cfg(test)]
mod route_api_tests;
#[cfg(test)]
mod segtype_tests;
#[cfg(test)]
mod selector_tests;
#[cfg(test)]
mod semantics_tests;
#[cfg(test)]
mod size_tests;
#[cfg(test)]
mod synth;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod url_state_tests;
#[cfg(test)]
mod views_tests;
