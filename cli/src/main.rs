mod adapters;
mod config;
mod create;
mod daemon;
mod dart;
mod dev;
mod dev_state;
mod dev_tui;
mod devtools;
mod diag;
mod emit;
mod entry;
mod enums;
mod extra;
mod format;
mod forms;
mod graph;
mod init;
mod links;
mod lint;
mod locale;
mod maestro;
mod manifest;
mod menu;
mod osc8;
mod parse_cache;
mod platform_files;
mod procs;
mod resolve;
mod routes;
mod samples;
mod scaffold;
mod scan;
mod segtype;
mod session;
mod size;
mod smoke;
mod tasks;
mod telemetry_stack;
mod templates;
mod upgrade;
mod upgrade_replace;
mod watch;

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::{env, fs, process};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand};
use config::Config;
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
    /// Write a widget smoke test per route into `test/routes/routes_test.dart` (`test:` in pubspec.yaml)
    Test {
        /// Write nothing; exit non-zero when the test file on disk is not what `fsp test` would write
        #[arg(long)]
        check: bool,
    },
    /// Regenerate on every change under the app folder
    Watch,
    /// Run the app: `fsp watch` and `flutter run` in one terminal, hot restarting when the routes change (`tasks: dev:` in pubspec.yaml)
    Dev(dev::DevCmd),
    /// `fsp gen`, then `flutter build <TARGET>`, with the hooks of `tasks: build:` in pubspec.yaml
    Build(tasks::BuildCmd),
    /// Run a task from `tasks:` in pubspec.yaml; with no name, list them
    Run(tasks::RunCmd),
    /// Make a new Flutter app with fespalier in it: `fsp create my_app` (optional features with --features)
    Create(create::CreateCmd),
    /// Set up an existing Flutter project: starter layout, page and not-found, then gen
    Init,
    /// Scaffold a route: `fsp new products/[id] --data --loading --error`
    New(scaffold::NewCmd),
    /// Start a local OpenTelemetry stack with fespalier's dashboards: a collector, OpenObserve, and Grafana with --grafana (needs Docker)
    Telemetry(telemetry_stack::TelemetryCmd),
    /// Upgrade fsp the way it was installed (Homebrew, Scoop, cargo, install script); `--check` says whether a newer release exists (exit 3)
    Upgrade(upgrade::UpgradeCmd),
}

fn main() {
    // A Windows upgrade leaves the running binary behind as `fsp.exe.old`; this run is a later
    // one, so that process is gone. Best effort, and silent (nothing may print here).
    #[cfg(windows)]
    if let Ok(exe) = std::env::current_exe() {
        upgrade_replace::remove_stale_old(&exe);
    }
    let cli = Cli::parse();
    let result = (|| {
        // The stack is per user, not per app: it needs no project.
        if let Cmd::Telemetry(cmd) = &cli.cmd {
            let project = find_project(cli.project.clone()).ok();
            return telemetry_stack::run(cmd, project.as_deref());
        }
        // A new app has no project yet: its folder is the argument, and `--project` is refused.
        if let Cmd::Create(cmd) = &cli.cmd {
            return create::run(cmd, cli.project.as_deref());
        }
        // So is the installed `fsp` itself.
        if let Cmd::Upgrade(cmd) = &cli.cmd {
            // Only the closing note reads the project, and it may be none.
            let project = find_project(cli.project.clone()).ok();
            return upgrade::run(cmd, project.as_deref());
        }
        let project = find_project(cli.project)?;
        match cli.cmd {
            Cmd::Telemetry(_) | Cmd::Create(_) | Cmd::Upgrade(_) => {
                unreachable!("handled before the project is looked up")
            }
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
            Cmd::Test { check } => smoke::run(&project, check),
            Cmd::Watch => watch(&project),
            Cmd::Dev(cmd) => dev::run(&project, &cmd),
            Cmd::Build(cmd) => tasks::build(&project, &cmd),
            Cmd::Run(cmd) => tasks::run_task(&project, &cmd),
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
        // `Exit` says its piece itself, if it has one, and only carries the code.
        if let Some(Exit(code)) = e.downcast_ref::<Exit>() {
            process::exit(*code);
        }
        eprintln!("{e:#}");
        process::exit(1);
    }
}

/// An error that ends `fsp` with this exit code and prints nothing: the command said what it had
/// to (a failed `before` step, flutter's own exit code, a signal).
#[derive(Debug)]
pub struct Exit(pub i32);

impl std::fmt::Display for Exit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "exit {}", self.0)
    }
}

impl std::error::Error for Exit {}

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
    let mut session = Session::default();
    let result = gen_core(project, cfg, write, &mut session, |app_dir, diags| {
        if json {
            diag::render_json(app_dir, &cfg.app_dir, diags);
        } else {
            diag::render(app_dir, &cfg.app_dir, diags);
        }
    });
    for warning in session.formats.take_warnings() {
        eprintln!("{warning}");
    }
    result
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
    let writes_main = entry::wanted(&tree, cfg);
    let libs = enums::Libs::for_app(&app_dir, cfg);
    let (run, reads) = if let Some(kept) = session.last.reuse(&tree, &scan_diags, &libs) {
        kept
    } else {
        let (code, main, app) = analyze_tree(&tree, cfg, &libs, &mut diags);
        let routes = app.routes.iter().filter(|r| r.is_route()).count();
        // The manifest is a second file when `output_manifest:` asks for one, and the generated
        // main() a third when there is one to write. `check` renders them too, but writes and
        // compares nothing.
        let mut files = vec![];
        let mut table = lint::Table::default();
        if !diags.has_errors() {
            files.push((cfg.output.clone(), code));
            files.extend(cfg.output_manifest.clone().zip(manifest::emit(&app, cfg)));
            files.extend(main.map(|code| (cfg.output_main(), code)));
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
        let mut outputs = outputs(cfg, writes_main);
        let last = outputs.pop().unwrap_or_default();
        let left = if outputs.is_empty() {
            last
        } else {
            format!("{} and {last}", outputs.join(", "))
        };
        bail!(
            "{} error(s); {left} left unchanged",
            run.diags.error_count()
        );
    }
    let mut wrote = false;
    session.wrote = false;
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
            session.wrote = true;
        }
    }
    let output = outputs(cfg, writes_main).join(", ");
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

/// The files `gen` writes, as the user spells them: the output, the manifest library when
/// `output_manifest:` asks for one, and the generated `main()` when `with_main`.
fn outputs(cfg: &Config, with_main: bool) -> Vec<String> {
    let mut all = vec![cfg.output.clone()];
    all.extend(cfg.output_manifest.clone());
    if with_main {
        all.push(cfg.output_main());
    }
    all
}

pub fn build(app_dir: &Path, cfg: &Config) -> Result<(String, diag::Diags, usize)> {
    let (code, diags, app) = analyze(app_dir, cfg)?;
    let routes = app.routes.iter().filter(|r| r.is_route()).count();
    Ok((code, diags, routes))
}

/// Like [`build`], but keeps the resolved app (for `fsp routes`).
pub fn analyze(app_dir: &Path, cfg: &Config) -> Result<(String, diag::Diags, resolve::App)> {
    let (code, _, diags, app) = analyze_with_main(app_dir, cfg)?;
    Ok((code, diags, app))
}

/// [`analyze`] that also returns the generated `main()` (`lib/app.main.g.dart`), when there is one.
pub fn analyze_with_main(
    app_dir: &Path,
    cfg: &Config,
) -> Result<(String, Option<String>, diag::Diags, resolve::App)> {
    let mut diags = diag::Diags::default();
    let tree = scan::scan(app_dir, &mut diags)?;
    let libs = enums::Libs::for_app(app_dir, cfg);
    let (code, main, app) = analyze_tree(&tree, cfg, &libs, &mut diags);
    Ok((code, main, diags, app))
}

/// Everything after the scan: resolve, check the manifest, emit. A function of the tree, the
/// configuration and the files `libs` reads (see [`enums::Libs::reads`]), which is what lets
/// `watch` skip it for a tree it has seen.
fn analyze_tree(
    tree: &scan::Node,
    cfg: &Config,
    libs: &enums::Libs,
    diags: &mut diag::Diags,
) -> (String, Option<String>, resolve::App) {
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
    forms::check_dependency(&app, cfg, diags);
    let code = emit::emit(&app, cfg, diags);
    let main = entry::emit(tree, &app, cfg, &adapters::hooks(&cfg.adapters), diags);
    (code, main, app)
}

/// `fsp watch`: [`watch::watch_loop`] with a sink that prints to stderr.
fn watch(project: &Path) -> Result<()> {
    let cfg = Config::load(project)?;
    let (tx, rx) = mpsc::channel();
    watch::watch_loop(project, &cfg, tx, &rx, |msg| match msg {
        watch::Watched::Diags(dir, d) => diag::render(dir, &cfg.app_dir, d),
        watch::Watched::Warning(text) | watch::Watched::Watching(text) => eprintln!("{text}"),
        watch::Watched::Pass(report) => {
            if let Some(line) = report.line {
                eprintln!("{line}");
            }
        }
    })
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
mod create_tests;
#[cfg(test)]
mod daemon_tests;
#[cfg(test)]
mod deferred_tests;
#[cfg(test)]
mod dev_state_tests;
#[cfg(test)]
mod dev_tui_tests;
#[cfg(test)]
mod devtools_tests;
#[cfg(test)]
mod entry_tests;
#[cfg(test)]
mod enum_tests;
#[cfg(test)]
mod extra_tests;
#[cfg(test)]
mod flow_tests;
#[cfg(test)]
mod form_tests;
#[cfg(test)]
mod freshness_tests;
#[cfg(test)]
mod graph_tests;
#[cfg(test)]
mod incremental_tests;
#[cfg(test)]
mod leave_tests;
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
mod menu_tests;
#[cfg(test)]
mod nav_tests;
#[cfg(test)]
mod navigator_tests;
#[cfg(test)]
mod nest_tests;
#[cfg(test)]
mod observe_tests;
#[cfg(test)]
mod page_name_tests;
#[cfg(test)]
mod paths_tests;
#[cfg(test)]
mod platform_files_tests;
#[cfg(test)]
mod procs_tests;
#[cfg(test)]
mod refresh_tests;
#[cfg(test)]
mod remount_tests;
#[cfg(test)]
mod rest_types_tests;
#[cfg(test)]
mod route_api_tests;
#[cfg(test)]
mod scroll_tests;
#[cfg(test)]
mod segtype_tests;
#[cfg(test)]
mod selector_tests;
#[cfg(test)]
mod semantics_tests;
#[cfg(test)]
mod size_tests;
#[cfg(test)]
mod smoke_tests;
#[cfg(test)]
mod synth;
#[cfg(test)]
mod tasks_tests;
#[cfg(test)]
mod telemetry_tests;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod upgrade_tests;
#[cfg(test)]
mod url_state_tests;
#[cfg(test)]
mod views_tests;
