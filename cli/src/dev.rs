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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::thread;
use std::time::Instant;

use anyhow::{Result, bail};
use clap::Args;

use crate::Exit;
use crate::config::Config;
use crate::daemon::{self, Line};
use crate::dev_state::{
    self, DevState, Device, Effect, FLUTTER, FSP, Input, Kind, Opts, Pick, PlainLine,
};
use crate::dev_tui::{self, TerminalGuard};
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

/// What the device question came to.
enum Chosen {
    /// Run on this device, or on flutter's own choice (`None`), with a warning to show.
    Device(Option<Device>, Option<String>),
    /// `q` in the picker.
    Quit,
}

/// What to do with the device listing: the device to pass, or nothing. With a view (`ui`) the
/// picker is a screen of its own; with a terminal on stdin it is a prompt; with neither,
/// several devices are an error that says which flag to use.
fn choose_device(
    project: &Path,
    args: &[String],
    listing: Result<String, String>,
    ui: Option<&mut TerminalGuard>,
    stdin_tty: bool,
) -> Result<Chosen> {
    let unlisted = |why: &str| {
        Chosen::Device(
            None,
            Some(format!(
                "warning: could not list the devices (`flutter devices --machine`: {why}); flutter run picks one"
            )),
        )
    };
    let text = match listing {
        Ok(t) => t,
        Err(why) => return Ok(unlisted(&why)),
    };
    match dev_state::pick_device(&text, args, ui.is_some() || stdin_tty) {
        Pick::Skip => Ok(Chosen::Device(None, None)),
        Pick::Device(d) => Ok(Chosen::Device(Some(d), None)),
        Pick::Choose(devices) => match ui {
            Some(g) => {
                let last = remembered(project);
                let default = last
                    .and_then(|id| devices.iter().position(|d| d.id == id))
                    .unwrap_or(0);
                match g.pick(&devices, default)? {
                    Some(i) => {
                        remember(project, &devices[i].id);
                        Ok(Chosen::Device(Some(devices[i].clone()), None))
                    }
                    None => Ok(Chosen::Quit),
                }
            }
            None => ask_device(project, &devices).map(|d| Chosen::Device(Some(d), None)),
        },
        Pick::NeedFlag(ids) => bail!(
            "more than one device: pick one with `fsp dev -- -d <id>` (ids: {})",
            ids.join(", ")
        ),
        Pick::NoDevice => bail!(
            "no device to run on: `flutter devices` lists none that this project supports. Start an emulator or a simulator, connect a phone, or enable a platform with `flutter create --platforms=web .`"
        ),
        Pick::Unlisted => Ok(unlisted("it printed no JSON")),
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

    // 4. The view: the whole screen on a terminal, plain lines elsewhere.
    let stdin_tty = std::io::stdin().is_terminal();
    let mut guard = None;
    if dev_tui::want_tui(
        cmd.no_tui,
        |k| std::env::var(k).ok(),
        std::io::stdout().is_terminal(),
        stdin_tty,
    ) {
        match TerminalGuard::enter() {
            Ok(g) => guard = Some(g),
            Err(e) => eprintln!("warning: could not take over the terminal ({e}); plain output"),
        }
    }
    let mut warning_text = None;
    let device = match listing {
        Some(handle) => {
            let listing = handle
                .join()
                .unwrap_or_else(|_| Err("the device thread panicked".into()));
            let asked = choose_device(project, &cmd.args, listing, guard.as_mut(), stdin_tty)?;
            match asked {
                Chosen::Device(d, warning) => {
                    warning_text = warning;
                    d
                }
                // `q` in the picker: nothing was started, nothing to say.
                Chosen::Quit => return Err(Exit(0).into()),
            }
        }
        None => None,
    };

    // 5. The loop.
    if guard.is_none()
        && let Some(w) = warning_text.take()
    {
        eprintln!("{w}");
    }
    let outcome = run_loop(
        project,
        &cfg,
        &plan,
        &env,
        &cmd.args,
        device,
        warning_text,
        guard,
    )?;
    // The terminal is back; what flutter said last stays on screen.
    for line in &outcome.tail {
        procs::write_stderr_line(line);
    }
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
    /// The last lines of the panes worth showing once the view is closed (TUI only).
    tail: Vec<String>,
}

/// Starts flutter (`run`, with `--machine` and the device) and tells the state.
fn start_flutter(
    plan: &Plan,
    env: &Env<'_>,
    args: &[String],
    device: Option<&Device>,
    tx: &Sender<Input>,
) -> Result<Supervised> {
    let place = format!("`run` of `{}`", plan.name);
    let extra = run_args(args, device);
    let prepared = tasks::prepare(&plan.run, &extra, env)
        .map_err(|w| tasks::start_error(&plan.run, &place, &w))?;
    let program = prepared.program;
    procs::spawn(prepared.process, true, sink_for(FLUTTER, tx))
        .map_err(|e| tasks::start_error(&plan.run, &place, &tasks::why(&e, &program)))
}

/// Starts `fsp telemetry` for this project, for the pane `pane`.
fn start_telemetry(project: &Path, pane: usize, tx: &Sender<Input>) -> Result<Supervised> {
    let exe = std::env::current_exe()?;
    let mut command = std::process::Command::new(exe);
    command
        .arg("--project")
        .arg(project)
        .arg("telemetry")
        .current_dir(project);
    Ok(procs::spawn(command, false, sink_for(pane, tx))?)
}

#[allow(
    clippy::too_many_arguments,
    reason = "the loop's inputs, each used once"
)]
fn run_loop(
    project: &Path,
    cfg: &Config,
    plan: &Plan,
    env: &Env<'_>,
    args: &[String],
    device: Option<Device>,
    warning: Option<String>,
    mut guard: Option<TerminalGuard>,
) -> Result<Outcome> {
    let (tx, rx) = mpsc::channel::<Input>();
    let start = Instant::now();
    let color = procs::color_enabled();
    let tui = guard.is_some();
    let links = tui && osc8::enabled_here();
    let mut state = DevState::new(Opts {
        name: cfg.package.clone().unwrap_or_else(|| {
            project
                .file_name()
                .map_or_else(|| "app".to_string(), |n| n.to_string_lossy().into_owned())
        }),
        with: plan.with.iter().map(|(n, _)| n.clone()).collect(),
        hot_reload: plan.hot_reload,
        plain: !tui,
        output: cfg.output.clone(),
        device: device.clone(),
    });
    if let Some(w) = warning {
        state.say(&w, Kind::Warn);
    }
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
    match start_flutter(plan, env, args, device.as_ref(), &tx) {
        Ok(s) => {
            state.started(FLUTTER);
            running.flutter = Some(s);
        }
        Err(e) => {
            abort(&running);
            return Err(e);
        }
    }

    // The watcher: it regenerates on every save, on this one thread (the parse cache is
    // thread-local), and says so through the loop's channel.
    let (wtx, wrx) = mpsc::channel::<Wake>();
    let stop_watcher = wtx.clone();
    let watcher = {
        let (project, cfg, tx) = (project.to_path_buf(), cfg.clone(), tx.clone());
        let links = !tui && osc8::enabled_here() && std::io::stderr().is_terminal();
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

    // Keys: the terminal's in the full-screen view, lines typed on stdin in plain mode (an end of
    // input does not quit).
    let stop_keys = Arc::new(AtomicBool::new(false));
    let keys = if let Some(g) = &guard {
        if let Ok((w, h)) = g.size() {
            let _ = tx.send(Input::Resize(w, h));
        }
        Some(dev_tui::spawn_input(tx.clone(), Arc::clone(&stop_keys)))
    } else {
        let tx = tx.clone();
        thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { break };
                if tx.send(Input::Typed(line)).is_err() {
                    break;
                }
            }
        });
        None
    };
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

    let tick = std::time::Duration::from_millis(250);
    while !state.finished() {
        let wait = state
            .next_deadline()
            .map(|at| at.saturating_sub(start.elapsed()));
        let wait = match (wait, tui) {
            (Some(w), true) => Some(w.min(tick)),
            (None, true) => Some(tick),
            (w, false) => w,
        };
        let first = match wait {
            Some(w) => match rx.recv_timeout(w) {
                Ok(i) => i,
                Err(mpsc::RecvTimeoutError::Timeout) => Input::Tick,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match rx.recv() {
                Ok(i) => i,
                Err(_) => break,
            },
        };
        // Everything that is waiting, then one draw: a burst of log lines is one frame.
        let mut batch = vec![first];
        while batch.len() < 500
            && let Ok(more) = rx.try_recv()
        {
            batch.push(more);
        }
        for input in batch {
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
                    Effect::Open(url) => {
                        if let Err(e) = procs::open_url(&url) {
                            let _ = tx.send(Input::Notice(format!("could not open {url}: {e}")));
                        }
                    }
                    Effect::StartTelemetry(pane) => match start_telemetry(project, pane, &tx) {
                        Ok(s) => {
                            state.started(pane);
                            running.with.push((pane, s));
                        }
                        Err(e) => {
                            let _ = tx.send(Input::Line {
                                pane,
                                text: format!("{e:#}"),
                                err: true,
                            });
                        }
                    },
                    Effect::Respawn => match start_flutter(plan, env, args, device.as_ref(), &tx) {
                        Ok(s) => {
                            state.started(FLUTTER);
                            running.flutter = Some(s);
                        }
                        Err(e) => {
                            // It did not start: the view stays stopped, with the reason.
                            let _ = tx.send(Input::Line {
                                pane: FLUTTER,
                                text: format!("{e:#}"),
                                err: true,
                            });
                            let _ = tx.send(Input::Exited {
                                pane: FLUTTER,
                                status: procs::Status {
                                    code: 1,
                                    signal: None,
                                },
                            });
                        }
                    },
                }
            }
        }
        if let Some(g) = guard.as_mut() {
            let _ = g.draw(&state, start.elapsed(), links);
        } else {
            let names: Vec<String> = state.panes().iter().map(|p| p.name.clone()).collect();
            plain_print(&state.drain_plain(), &names, color);
        }
    }

    stop_keys.store(true, Ordering::SeqCst);
    let _ = stop_watcher.send(Wake::Stop);
    let _ = watcher.join();
    if let Some(k) = keys {
        let _ = k.join();
    }
    let tail = if tui {
        dev_tui::tail(&state, 20)
    } else {
        vec![]
    };
    // The terminal goes back before anything else is printed.
    drop(guard.take());
    Ok(Outcome {
        code: state.exit_code(),
        after_ok: state.after_ok(),
        tail,
    })
}

/// Stops what is already running when a later command could not start.
fn abort(running: &Procs) {
    for (_, s) in &running.with {
        s.terminate(std::time::Duration::from_secs(5));
    }
}
