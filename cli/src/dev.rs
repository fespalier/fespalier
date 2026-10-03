//! `fsp dev`: `fsp watch` and `flutter run` in one terminal (since 0.9.0).
//!
//! It generates, runs the `before` steps of `tasks: dev:`, starts the `with` commands and
//! `flutter run --machine`, and keeps `lib/app.g.dart` current while it runs: a regeneration that
//! wrote hot restarts the app (the router is built once), any other save hot reloads it. All the
//! decisions are in [`crate::dev_state`]; this file is the I/O around it: threads that turn what
//! happens (flutter's output, a regeneration, a key, a signal, an exit) into [`Input`]s for one
//! loop, and the effects the state asks for.
//!
//! Every child runs in a process group of its own (see [`crate::procs`]), so quitting stops what
//! flutter and the `with` commands started too.

use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::Instant;

use anyhow::{Result, bail};
use clap::Args;

use crate::Exit;
use crate::config::Config;
use crate::daemon::{self, Line};
use crate::dev_state::{
    self, DevState, Device, Effect, FLUTTER, FSP, Input, Opts, Pick, PlainLine,
};
use crate::diag;
use crate::osc8;
use crate::procs::{self, Out, Supervised};
use crate::tasks::{self, Cmd, Env, Plan, Tasks};
use crate::watch::{self, Wake, Watched};

#[derive(Args)]
pub struct DevCmd {
    /// Plain prefixed lines instead of the full-screen view (the default when stdout is not a terminal, with TERM=dumb or in CI)
    #[arg(long)]
    pub no_tui: bool,
    /// Print what would run, and run nothing
    #[arg(long)]
    pub dry_run: bool,
    /// Passed on to `flutter run`, after `--`: `fsp dev -- -d chrome --flavor dev`
    #[arg(last = true, value_name = "FLUTTER_RUN_ARGS")]
    pub args: Vec<String>,
}

const DEVICE_MEMORY: &str = ".dart_tool/fespalier/dev.json";

/// `flutter run`'s own arguments: `--machine` (unless given), the device fsp chose, then the
/// arguments after `--`.
pub fn run_args(args: &[String], device: Option<&Device>) -> Vec<String> {
    let mut out = vec![];
    if !args.iter().any(|a| a == "--machine") {
        out.push("--machine".to_string());
    }
    if let Some(d) = device {
        out.push("-d".to_string());
        out.push(d.id.clone());
    }
    out.extend(args.iter().cloned());
    out
}

/// What `fsp dev --dry-run` prints.
pub fn dry_run(project: &Path, cfg: &Config, plan: &Plan, args: &[String]) -> String {
    let hot = if plan.hot_reload {
        format!(
            "hot reload after a save; hot restart when {} changes",
            cfg.output
        )
    } else {
        "hot reload off (r and R still work)".to_string()
    };
    tasks::dry_run(
        "fsp dev",
        project,
        plan,
        &run_args(args, None),
        Some(&format!(
            "gen     {}, kept current while it runs",
            cfg.output
        )),
        Some(&hot),
    )
}

/// The device chosen last time, from `.dart_tool/fespalier/dev.json`.
fn remembered(project: &Path) -> Option<String> {
    let text = std::fs::read_to_string(project.join(DEVICE_MEMORY)).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    v.get("device")?.as_str().map(str::to_string)
}

/// Keeps the choice for next time. A failure is nobody's problem: it only costs the preselection.
fn remember(project: &Path, id: &str) {
    let path = project.join(DEVICE_MEMORY);
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, serde_json::json!({ "device": id }).to_string());
}

/// `flutter devices --machine`, on a thread: what it printed, or why it did not work.
fn list_devices(project: PathBuf, env_vars: Vec<(String, String)>) -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let env = Env {
        cwd: &project,
        vars: env_vars,
        fsp: &exe,
    };
    let cmd = Cmd::Argv(vec!["flutter".into(), "devices".into(), "--machine".into()]);
    let mut prepared = tasks::prepare(&cmd, &[], &env)?;
    let program = prepared.program.clone();
    let out = prepared
        .process
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| tasks::why(&e, &program))?;
    if !out.status.success() {
        return Err(procs::Status::of(out.status).describe());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Asks which device, on a terminal in plain mode.
fn ask_device(project: &Path, devices: &[Device]) -> Result<Device> {
    let last = remembered(project);
    let default = last
        .as_ref()
        .and_then(|id| devices.iter().position(|d| &d.id == id));
    eprintln!("more than one device:");
    for (i, d) in devices.iter().enumerate() {
        let mark = if default == Some(i) {
            " (last used)"
        } else {
            ""
        };
        eprintln!("  {}) {} ({}){mark}", i + 1, d.name, d.id);
    }
    eprint!("pick a device [1-{}]: ", devices.len());
    let _ = std::io::stderr().flush();
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    let line = line.trim();
    let index = if line.is_empty() {
        default
    } else {
        line.parse::<usize>()
            .ok()
            .and_then(|n| n.checked_sub(1))
            .filter(|n| *n < devices.len())
    };
    let Some(index) = index else {
        bail!(
            "`{line}` is not one of the devices: run `fsp dev` again, or pick one with `fsp dev -- -d <id>`"
        );
    };
    remember(project, &devices[index].id);
    Ok(devices[index].clone())
}

/// What to do with the device listing: the device to pass, or nothing.
fn choose_device(
    project: &Path,
    args: &[String],
    listing: Result<String, String>,
    interactive: bool,
) -> Result<Option<Device>> {
    let text = match listing {
        Ok(t) => t,
        Err(why) => {
            eprintln!(
                "warning: could not list the devices (`flutter devices --machine`: {why}); flutter run picks one"
            );
            return Ok(None);
        }
    };
    match dev_state::pick_device(&text, args, interactive) {
        Pick::Skip => Ok(None),
        Pick::Device(d) => Ok(Some(d)),
        Pick::Choose(devices) => ask_device(project, &devices).map(Some),
        Pick::NeedFlag(ids) => bail!(
            "more than one device: pick one with `fsp dev -- -d <id>` (ids: {})",
            ids.join(", ")
        ),
        Pick::NoDevice => bail!(
            "no device to run on: `flutter devices` lists none that this project supports. Start an emulator or a simulator, connect a phone, or enable a platform with `flutter create --platforms=web .`"
        ),
        Pick::Unlisted => {
            eprintln!(
                "warning: could not list the devices (`flutter devices --machine`: it printed no JSON); flutter run picks one"
            );
            Ok(None)
        }
    }
}

/// Everything the loop owns that is not state: the processes, by pane.
struct Procs {
    flutter: Option<Supervised>,
    with: Vec<(usize, Supervised)>,
}

impl Procs {
    fn pid(&self, pane: usize) -> Option<u32> {
        if pane == FLUTTER {
            self.flutter.as_ref().map(|s| s.pid)
        } else {
            self.with
                .iter()
                .find(|(p, _)| *p == pane)
                .map(|(_, s)| s.pid)
        }
    }

    fn kill_all(&self) {
        for pane in std::iter::once(FLUTTER).chain(self.with.iter().map(|(p, _)| *p)) {
            if let Some(pid) = self.pid(pane) {
                procs::kill_group(pid);
            }
        }
    }
}

/// A sink that turns a process's output into inputs of the loop.
fn sink_for(pane: usize, tx: &Sender<Input>) -> Arc<dyn Fn(Out) + Send + Sync> {
    let tx = tx.clone();
    Arc::new(move |out| {
        let _ = match out {
            Out::Line { text, err } if pane == FLUTTER && !err => match daemon::parse_line(&text) {
                Line::Messages(msgs) => {
                    for m in msgs {
                        let _ = tx.send(Input::Daemon(m));
                    }
                    return;
                }
                Line::Text(t) => tx.send(Input::Line {
                    pane,
                    text: t,
                    err: false,
                }),
            },
            Out::Line { text, err } => tx.send(Input::Line { pane, text, err }),
            Out::Exited(status) => tx.send(Input::Exited { pane, status }),
        };
    })
}

fn plain_print(lines: &[PlainLine], names: &[String], color: bool) {
    for l in lines {
        procs::write_stderr_line(&procs::prefixed(&names[l.pane], l.pane, &l.text, color));
    }
}

/// `fsp dev`.
pub fn run(project: &Path, cmd: &DevCmd) -> Result<()> {
    let cfg = Config::load(project)?;
    let plan = Tasks::from_config(&cfg)?.dev();
    if cmd.dry_run {
        eprint!("{}", dry_run(project, &cfg, &plan, &cmd.args));
        return Ok(());
    }
    procs::install_signals().map_err(anyhow::Error::msg)?;

    // 1. The first generation, as `fsp gen` prints it.
    match crate::gen_opts(project, &cfg, true, false) {
        Ok(o) => eprintln!("{}", o.line()),
        Err(e) => {
            eprintln!("{e:#}");
            if project.join(&cfg.output).is_file() {
                eprintln!(
                    "warning: {} is out of date until the errors above are fixed; fsp dev keeps watching",
                    cfg.output
                );
            } else {
                eprintln!(
                    "fsp dev needs {}: fix the errors above, then run `fsp dev` again",
                    cfg.output
                );
                return Err(Exit(1).into());
            }
        }
    }

    // 2. The device, asked of flutter while the `before` steps run.
    let exe = std::env::current_exe()?;
    let vars = plan.env.clone();
    let env = Env {
        cwd: project,
        vars: vars.clone(),
        fsp: &exe,
    };
    let discover = plan.run_is_default && !dev_state::names_a_device(&cmd.args);
    let listing = discover.then(|| {
        let project = project.to_path_buf();
        let vars = vars.clone();
        thread::spawn(move || list_devices(project, vars))
    });

    // 3. The `before` steps, in the terminal's own stdio.
    tasks::run_steps("before", &plan.name, &plan.before, &env)?;
    if procs::signalled() {
        return Err(Exit(130).into());
    }
    let device = match listing {
        Some(handle) => {
            let listing = handle
                .join()
                .unwrap_or_else(|_| Err("the device thread panicked".into()));
            choose_device(project, &cmd.args, listing, std::io::stdin().is_terminal())?
        }
        None => None,
    };

    // 4. The loop.
    let outcome = run_loop(project, &cfg, &plan, &env, &cmd.args, device);
    let outcome = outcome?;
    if outcome.after_ok {
        tasks::run_steps("after", &plan.name, &plan.after, &env)?;
    }
    if outcome.code == 0 {
        Ok(())
    } else {
        Err(Exit(outcome.code).into())
    }
}

struct Outcome {
    code: i32,
    after_ok: bool,
}

fn run_loop(
    project: &Path,
    cfg: &Config,
    plan: &Plan,
    env: &Env<'_>,
    args: &[String],
    device: Option<Device>,
) -> Result<Outcome> {
    let (tx, rx) = mpsc::channel::<Input>();
    let start = Instant::now();
    let color = procs::color_enabled();
    let mut state = DevState::new(Opts {
        with: plan.with.iter().map(|(n, _)| n.clone()).collect(),
        hot_reload: plan.hot_reload,
        plain: true,
        output: cfg.output.clone(),
        device: device.clone(),
    });
    let names: Vec<String> = state.panes().iter().map(|p| p.name.clone()).collect();
    let mut running = Procs {
        flutter: None,
        with: vec![],
    };

    // The `with` commands, then flutter.
    for (i, (name, cmd)) in plan.with.iter().enumerate() {
        let pane = FSP + 1 + i;
        let place = format!("`with` {name}");
        let prepared =
            tasks::prepare(cmd, &[], env).map_err(|w| tasks::start_error(cmd, &place, &w))?;
        let program = prepared.program;
        match procs::spawn(prepared.process, false, sink_for(pane, &tx)) {
            Ok(s) => {
                state.started(pane);
                running.with.push((pane, s));
            }
            Err(e) => {
                abort(&running);
                return Err(tasks::start_error(cmd, &place, &tasks::why(&e, &program)));
            }
        }
    }
    let place = format!("`run` of `{}`", plan.name);
    let extra = run_args(args, device.as_ref());
    let prepared = tasks::prepare(&plan.run, &extra, env)
        .map_err(|w| tasks::start_error(&plan.run, &place, &w))?;
    let program = prepared.program;
    match procs::spawn(prepared.process, true, sink_for(FLUTTER, &tx)) {
        Ok(s) => {
            state.started(FLUTTER);
            running.flutter = Some(s);
        }
        Err(e) => {
            abort(&running);
            return Err(tasks::start_error(
                &plan.run,
                &place,
                &tasks::why(&e, &program),
            ));
        }
    }

    // The watcher: it regenerates on every save, on this one thread (the parse cache is
    // thread-local), and says so through the loop's channel.
    let (wtx, wrx) = mpsc::channel::<Wake>();
    let stop_watcher = wtx.clone();
    let watcher = {
        let (project, cfg, tx) = (project.to_path_buf(), cfg.clone(), tx.clone());
        let links = osc8::enabled_here() && std::io::stderr().is_terminal();
        thread::spawn(move || {
            let sent = tx.clone();
            let result = watch::watch_loop(&project, &cfg, wtx, &wrx, |msg| {
                let say = |text: String| {
                    let _ = sent.send(Input::Line {
                        pane: FSP,
                        text,
                        err: false,
                    });
                };
                match msg {
                    Watched::Diags(dir, diags) => {
                        let mut lines = diag::render_plain(dir, &cfg.app_dir, diags);
                        if links {
                            let places: Vec<(String, String)> = diags
                                .0
                                .iter()
                                .filter_map(|d| diag::location(dir, &cfg.app_dir, d))
                                .map(|l| (l.text(), osc8::file_url(&l.path)))
                                .collect();
                            lines = osc8::link_locations(lines, &places);
                        }
                        lines.into_iter().for_each(say);
                    }
                    Watched::Warning(w) => say(w),
                    Watched::Pass(report) => {
                        let _ = sent.send(Input::Gen(report));
                    }
                    Watched::Watching(text) => say(text),
                }
            });
            if let Err(e) = result {
                let _ = tx.send(Input::Line {
                    pane: FSP,
                    text: format!("watch error: {e:#}"),
                    err: true,
                });
            }
        })
    };

    // Keys are typed as lines in plain mode; an end of input does not quit.
    {
        let tx = tx.clone();
        thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                if tx.send(Input::Typed(line)).is_err() {
                    break;
                }
            }
        });
    }
    // Signals.
    {
        let tx = tx.clone();
        let signals = procs::subscribe();
        thread::spawn(move || {
            for () in signals {
                if tx.send(Input::Signal).is_err() {
                    break;
                }
            }
        });
    }
    if procs::signalled() {
        // One arrived while the children started; the thread above did not hear it.
        let _ = tx.send(Input::Signal);
    }

    while !state.finished() {
        let input = match state
            .next_deadline()
            .map(|at| at.saturating_sub(start.elapsed()))
        {
            Some(wait) => match rx.recv_timeout(wait) {
                Ok(i) => i,
                Err(mpsc::RecvTimeoutError::Timeout) => Input::Tick,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match rx.recv() {
                Ok(i) => i,
                Err(_) => break,
            },
        };
        for effect in state.update(start.elapsed(), input) {
            match effect {
                Effect::SendFlutter(line) => {
                    if let Some(f) = &running.flutter {
                        let _ = f.write_line(&line);
                    }
                }
                Effect::Term(pane) => {
                    if let Some(pid) = running.pid(pane) {
                        procs::term_group(pid);
                    }
                }
                Effect::Kill(pane) => {
                    if let Some(pid) = running.pid(pane) {
                        procs::kill_group(pid);
                    }
                }
                Effect::KillAll => running.kill_all(),
                Effect::Finish => {}
            }
        }
        plain_print(&state.drain_plain(), &names, color);
    }

    let _ = stop_watcher.send(Wake::Stop);
    let _ = watcher.join();
    Ok(Outcome {
        code: state.exit_code(),
        after_ok: state.after_ok(),
    })
}

/// Stops what is already running when a later command could not start.
fn abort(running: &Procs) {
    for (_, s) in &running.with {
        s.terminate(std::time::Duration::from_secs(5));
    }
}
