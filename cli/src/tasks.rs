//! `tasks:` in the `fespalier:` section of pubspec.yaml, and the commands that run them: `fsp dev`
//! (see `dev.rs`), `fsp build <target>` and `fsp run <task>` (since 0.9.0).
//!
//! ```yaml
//! fespalier:
//!   tasks:
//!     dev:
//!       before: dart run build_runner build -d
//!       with:
//!         build_runner: dart run build_runner watch -d
//!       run: flutter run
//!       env: { API_URL: "http://localhost:8080" }
//!     codegen: dart run build_runner build -d
//! ```
//!
//! A command is a string, which the shell runs (`sh -c` on Unix, `cmd /d /s /c` on Windows), or a
//! list of words, which runs with no shell and is the same on every OS. A leading `fsp` means the
//! very `fsp` that runs the task, so `before: fsp check` works under `dart run fespalier dev`,
//! where no `fsp` is on PATH.
//!
//! The section is checked by the commands that read it, never by `fsp gen`: [`Config::tasks`] is
//! the raw value, and [`Tasks::from_config`] reports a mistake with the key it is in.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command as Process;
use std::sync::Arc;

use anyhow::{Result, bail};
use clap::Args;
use serde_yaml_ng::Value;

use crate::Exit;
use crate::config::{Config, shown_value};
use crate::procs::{self, Out, Status, Supervised};

/// A command: what runs, and how.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cmd {
    /// A string, run by the shell.
    Shell(String),
    /// A list of words: the program and its arguments, run with no shell.
    Argv(Vec<String>),
}

impl Cmd {
    /// The command as it is written, for `› {command}` and `--dry-run`: a shell string as it is,
    /// words of a list joined by spaces (a word with a space or a quote in single quotes).
    #[must_use]
    pub fn shown(&self) -> String {
        match self {
            Cmd::Shell(s) => s.clone(),
            Cmd::Argv(words) => words
                .iter()
                .map(|w| show_word(w))
                .collect::<Vec<_>>()
                .join(" "),
        }
    }

    fn argv(words: &[&str]) -> Cmd {
        Cmd::Argv(words.iter().map(|w| (*w).to_string()).collect())
    }
}

/// One task of `tasks:`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Task {
    pub run: Option<Cmd>,
    pub before: Vec<Cmd>,
    /// Long-running commands next to `run`, by name, in the order written.
    pub with: Vec<(String, Cmd)>,
    pub after: Vec<Cmd>,
    pub env: Vec<(String, String)>,
    pub hot_reload: Option<bool>,
}

/// The `tasks:` section, checked: the tasks in the order the pubspec has them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Tasks(pub(crate) Vec<(String, Task)>);

/// A task with its defaults filled in, ready to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub name: String,
    pub before: Vec<Cmd>,
    pub with: Vec<(String, Cmd)>,
    pub run: Cmd,
    /// `run` is the default (`flutter run`, `flutter build`), not something the pubspec says.
    pub run_is_default: bool,
    pub after: Vec<Cmd>,
    pub env: Vec<(String, String)>,
    pub hot_reload: bool,
}

/// What a task name may be.
fn is_task_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// What a `with` command's name may be.
fn is_with_name(name: &str) -> bool {
    !name.is_empty()
        && name.chars().count() <= 20
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn is_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// A command from its YAML: a non-empty string, or a non-empty list of strings whose first word
/// is not empty.
fn command(v: &Value) -> Option<Cmd> {
    match v {
        Value::String(s) if !s.trim().is_empty() => Some(Cmd::Shell(s.clone())),
        Value::Sequence(items) if !items.is_empty() => {
            let words: Option<Vec<String>> = items
                .iter()
                .map(|w| w.as_str().map(str::to_string))
                .collect();
            words.filter(|w| !w[0].trim().is_empty()).map(Cmd::Argv)
        }
        _ => None,
    }
}

const COMMAND_SHAPE: &str = "a string the shell runs, or a list of words run without a shell";

/// `before` or `after`: a command, or a list of commands.
fn steps(task: &str, key: &str, v: &Value) -> Result<Vec<Cmd>> {
    let shown = shown_value(v);
    match v {
        Value::Sequence(items) => {
            let mut out = vec![];
            for (i, item) in items.iter().enumerate() {
                let Some(c) = command(item) else {
                    bail!(
                        "`fespalier.tasks.{task}.{key}[{}]` must be a command: {COMMAND_SHAPE}, got `{}`",
                        i + 1,
                        shown_value(item)
                    );
                };
                out.push(c);
            }
            Ok(out)
        }
        other => match command(other) {
            Some(c) => Ok(vec![c]),
            None => bail!(
                "`fespalier.tasks.{task}.{key}` must be a command or a list of commands, got `{shown}`"
            ),
        },
    }
}

fn with_map(task: &str, v: &Value) -> Result<Vec<(String, Cmd)>> {
    let Value::Mapping(map) = v else {
        bail!(
            "`fespalier.tasks.{task}.with` must be a map of names to commands, e.g. `build_runner: dart run build_runner watch -d`, got `{}`",
            shown_value(v)
        );
    };
    let mut out = vec![];
    for (k, value) in map {
        let name = k.as_str().map_or_else(|| shown_value(k), str::to_string);
        if !is_with_name(&name) {
            bail!(
                "`fespalier.tasks.{task}.with`: `{name}` is not a name; use letters, digits, `_` and `-`, at most 20"
            );
        }
        if name == "flutter" || name == "fsp" {
            bail!(
                "`fespalier.tasks.{task}.with`: `{name}` is the name of a pane of fsp dev's own; pick another"
            );
        }
        let Some(c) = command(value) else {
            bail!(
                "`fespalier.tasks.{task}.with.{name}` must be a command: {COMMAND_SHAPE}, got `{}`",
                shown_value(value)
            );
        };
        out.push((name, c));
    }
    Ok(out)
}

fn env_map(task: &str, v: &Value) -> Result<Vec<(String, String)>> {
    let Value::Mapping(map) = v else {
        bail!(
            "`fespalier.tasks.{task}.env` must be a map of variable names to values, got `{}`",
            shown_value(v)
        );
    };
    let mut out = vec![];
    for (k, value) in map {
        let name = k.as_str().map_or_else(|| shown_value(k), str::to_string);
        if !is_env_name(&name) {
            bail!(
                "`fespalier.tasks.{task}.env`: `{name}` is not a variable name (letters, digits and `_`, not starting with a digit)"
            );
        }
        let text = match value {
            Value::String(s) => s.clone(),
            Value::Number(n) => n.to_string(),
            Value::Bool(b) => b.to_string(),
            other => bail!(
                "`fespalier.tasks.{task}.env.{name}` must be a string, a number or a boolean, got `{}`",
                shown_value(other)
            ),
        };
        out.push((name, text));
    }
    Ok(out)
}

fn run_command(task: &str, v: &Value) -> Result<Cmd> {
    command(v).ok_or_else(|| {
        anyhow::anyhow!(
            "`fespalier.tasks.{task}.run` must be a command: a string the shell runs, or a list of words run without a shell (`[flutter, run]`), got `{}`",
            shown_value(v)
        )
    })
}

fn parse_task(name: &str, v: &Value) -> Result<Task> {
    let map = match v {
        Value::String(_) | Value::Sequence(_) => {
            return Ok(Task {
                run: Some(run_command(name, v)?),
                ..Task::default()
            });
        }
        Value::Mapping(m) => m,
        other => bail!(
            "`fespalier.tasks.{name}` must be a command (a string, or a list of words) or a map with `run`, `before`, `with`, `after`, `env` and `hot_reload`, got `{}`",
            shown_value(other)
        ),
    };
    for k in map.keys() {
        let key = k.as_str().map_or_else(|| shown_value(k), str::to_string);
        if !matches!(
            key.as_str(),
            "run" | "before" | "with" | "after" | "env" | "hot_reload"
        ) {
            bail!(
                "`fespalier.tasks.{name}` has an unknown key `{key}`; a task takes `run`, `before`, `with`, `after`, `env` and `hot_reload`"
            );
        }
    }
    let get = |key: &str| map.get(key);
    let mut task = Task::default();
    if get("hot_reload").is_some() && name != "dev" {
        bail!(
            "`fespalier.tasks.{name}.hot_reload` is only read by `fsp dev`; move it under `tasks: dev:`"
        );
    }
    if let Some(v) = get("run") {
        task.run = Some(run_command(name, v)?);
    }
    if let Some(v) = get("before") {
        task.before = steps(name, "before", v)?;
    }
    if let Some(v) = get("with") {
        task.with = with_map(name, v)?;
    }
    if let Some(v) = get("after") {
        task.after = steps(name, "after", v)?;
    }
    if let Some(v) = get("env") {
        task.env = env_map(name, v)?;
    }
    if let Some(v) = get("hot_reload") {
        let Value::Bool(b) = v else {
            bail!(
                "`fespalier.tasks.{name}.hot_reload` must be `true` or `false`, got `{}`",
                shown_value(v)
            );
        };
        task.hot_reload = Some(*b);
    }
    if task.run.is_none() && name != "dev" && name != "build" {
        bail!(
            "`fespalier.tasks.{name}` has no `run`; only `dev` and `build` have a default command"
        );
    }
    Ok(task)
}

impl Tasks {
    /// The section of `cfg`, checked. No section is no tasks.
    pub fn from_config(cfg: &Config) -> Result<Tasks> {
        Tasks::from_value(cfg.tasks.as_ref())
    }

    pub fn from_value(v: Option<&Value>) -> Result<Tasks> {
        let Some(v) = v else {
            return Ok(Tasks::default());
        };
        let Value::Mapping(map) = v else {
            bail!(
                "`fespalier.tasks` must be a map of task names to tasks, e.g. `codegen: dart run build_runner build -d`"
            );
        };
        let mut tasks = vec![];
        for (k, value) in map {
            let name = k.as_str().map_or_else(|| shown_value(k), str::to_string);
            if !is_task_name(&name) {
                bail!(
                    "`fespalier.tasks`: `{name}` is not a task name; use lower-case letters, digits, `_` and `-`, starting with a letter"
                );
            }
            tasks.push((name.clone(), parse_task(&name, value)?));
        }
        Ok(Tasks(tasks))
    }

    fn get(&self, name: &str) -> Option<&Task> {
        self.0.iter().find(|(n, _)| n == name).map(|(_, t)| t)
    }

    fn plan(&self, name: &str, default_run: &[&str]) -> Plan {
        let task = self.get(name).cloned().unwrap_or_default();
        Plan {
            name: name.to_string(),
            before: task.before,
            with: task.with,
            run_is_default: task.run.is_none(),
            run: task.run.unwrap_or_else(|| Cmd::argv(default_run)),
            after: task.after,
            env: task.env,
            hot_reload: task.hot_reload.unwrap_or(true),
        }
    }

    /// `fsp dev`'s task: `flutter run` unless the pubspec says otherwise.
    #[must_use]
    pub fn dev(&self) -> Plan {
        self.plan("dev", &["flutter", "run"])
    }

    /// `fsp build`'s task: `flutter build` unless the pubspec says otherwise.
    #[must_use]
    pub fn build(&self) -> Plan {
        self.plan("build", &["flutter", "build"])
    }

    /// A task of the pubspec by name, for `fsp run`.
    fn named(&self, name: &str) -> Option<Plan> {
        self.get(name).map(|t| Plan {
            name: name.to_string(),
            before: t.before.clone(),
            with: t.with.clone(),
            run: t.run.clone().unwrap_or_else(|| Cmd::argv(&["true"])),
            run_is_default: false,
            after: t.after.clone(),
            env: t.env.clone(),
            hot_reload: false,
        })
    }

    /// The names `fsp run` knows: `dev` and `build` first, then the others in pubspec order.
    #[must_use]
    pub fn names(&self) -> Vec<String> {
        let mut names = vec!["dev".to_string(), "build".to_string()];
        names.extend(
            self.0
                .iter()
                .map(|(n, _)| n.clone())
                .filter(|n| n != "dev" && n != "build"),
        );
        names
    }

    /// `fsp run` with no name: one task per line.
    #[must_use]
    pub fn listing(&self) -> String {
        let names = self.names();
        let width = names.iter().map(String::len).max().unwrap_or(0) + 2;
        let row = |name: &str| -> (String, Option<&'static str>) {
            let (default, note) = match name {
                "dev" => (Some("flutter run"), Some("(fsp dev)")),
                "build" => (Some("flutter build"), Some("(fsp build <target>)")),
                _ => (None, None),
            };
            let run = self
                .get(name)
                .and_then(|t| t.run.as_ref())
                .map(Cmd::shown)
                .or_else(|| default.map(str::to_string))
                .unwrap_or_default();
            (run, note)
        };
        let rows: Vec<(String, (String, Option<&str>))> =
            names.iter().map(|n| (n.clone(), row(n))).collect();
        let run_width = rows
            .iter()
            .filter(|(_, (_, note))| note.is_some())
            .map(|(_, (run, _))| run.chars().count())
            .max()
            .unwrap_or(0);
        let mut out = String::new();
        for (name, (run, note)) in rows {
            let line = match note {
                Some(note) => format!("{name:<width$}{run:<run_width$} {note}"),
                None => format!("{name:<width$}{run}"),
            };
            let _ = writeln!(out, "{line}");
        }
        out
    }
}

// --- quoting and building a command -------------------------------------------------------------

/// A word as `sh` reads it back: as it is when it is made of safe characters, else in single
/// quotes (a quote in it written `'\''`).
#[must_use]
pub fn quote_sh(word: &str) -> String {
    let safe = !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_@%+=:,./-".contains(c));
    if safe {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', "'\\''"))
    }
}

/// A word as `cmd` reads it: as it is when it is made of safe characters, else in double quotes
/// (a quote in it doubled). A word with a quote and a `%` or a `!` cannot be quoted for `cmd`
/// safely, and is an error.
pub fn quote_cmd(word: &str) -> Result<String, String> {
    if word.contains('"') && word.contains(['%', '!']) {
        return Err(format!(
            "the word `{word}` has a quote and a `%` or `!`, which cmd cannot quote safely; write the command as a list of words"
        ));
    }
    let safe = !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_@+=:,./\\-".contains(c));
    Ok(if safe {
        word.to_string()
    } else {
        format!("\"{}\"", word.replace('"', "\"\""))
    })
}

/// A word of an argv list for `--dry-run` and `› {command}`: in single quotes when it has a space
/// or a quote.
fn show_word(word: &str) -> String {
    if word.is_empty() || word.contains(|c: char| c.is_whitespace() || c == '\'' || c == '"') {
        format!("'{}'", word.replace('\'', "'\\''"))
    } else {
        word.to_string()
    }
}

/// The quoter of the shell this OS runs strings with.
fn quote_word(word: &str) -> Result<String, String> {
    if cfg!(windows) {
        quote_cmd(word)
    } else {
        Ok(quote_sh(word))
    }
}

/// `name` as Windows would find it: in each folder of `path` (separated by `;`), `name` with each
/// extension of `pathext` (`.COM;.EXE;.BAT;.CMD`), or `name` itself when it already ends in one of
/// them. std only appends `.exe`, and `flutter` is `flutter.bat`. A name with a folder in it is
/// looked up as it is.
#[must_use]
pub fn resolve_windows(name: &str, path: &str, pathext: &str) -> Option<PathBuf> {
    let exts: Vec<&str> = pathext.split(';').filter(|e| !e.is_empty()).collect();
    let has_ext = exts
        .iter()
        .any(|e| name.len() > e.len() && name[name.len() - e.len()..].eq_ignore_ascii_case(e));
    let candidates = |dir: &Path| -> Option<PathBuf> {
        if has_ext {
            let p = dir.join(name);
            if p.is_file() {
                return Some(p);
            }
        }
        exts.iter()
            .map(|e| dir.join(format!("{name}{e}")))
            .find(|p| p.is_file())
    };
    if name.contains(['/', '\\']) {
        return candidates(Path::new(""));
    }
    path.split(';')
        .filter(|d| !d.is_empty())
        .find_map(|d| candidates(Path::new(d)))
}

/// What a command needs to run: where, with which variables, and which `fsp` a leading `fsp`
/// means.
pub struct Env<'a> {
    pub cwd: &'a Path,
    pub vars: Vec<(String, String)>,
    pub fsp: &'a Path,
}

/// A command ready to spawn, and the program it starts (for a message).
pub struct Prepared {
    pub process: Process,
    pub program: String,
}

/// `cmd` with `extra` words appended (each quoted for the shell of a string), run in `env`.
pub fn prepare(cmd: &Cmd, extra: &[String], env: &Env<'_>) -> Result<Prepared, String> {
    let exe = env.fsp.to_string_lossy().into_owned();
    let (mut process, program) = match cmd {
        Cmd::Shell(line) => {
            let mut line = match line.as_str() {
                "fsp" => quote_word(&exe)?,
                l if l.starts_with("fsp ") || l.starts_with("fsp\t") => {
                    format!("{}{}", quote_word(&exe)?, &l[3..])
                }
                l => l.to_string(),
            };
            for word in extra {
                line.push(' ');
                line.push_str(&quote_word(word)?);
            }
            shell(&line)
        }
        Cmd::Argv(words) => {
            let first = if words[0] == "fsp" {
                exe
            } else if cfg!(windows) {
                resolve_windows(
                    &words[0],
                    &std::env::var("PATH").unwrap_or_default(),
                    &std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into()),
                )
                .map_or_else(|| words[0].clone(), |p| p.to_string_lossy().into_owned())
            } else {
                words[0].clone()
            };
            let mut p = Process::new(&first);
            p.args(&words[1..]).args(extra);
            (p, words[0].clone())
        }
    };
    process.current_dir(env.cwd);
    process.envs(env.vars.iter().map(|(k, v)| (k, v)));
    process.env("FSP", env.fsp);
    Ok(Prepared { process, program })
}

#[cfg(unix)]
fn shell(line: &str) -> (Process, String) {
    let mut p = Process::new("sh");
    p.arg("-c").arg(line);
    (p, "sh".to_string())
}

#[cfg(windows)]
fn shell(line: &str) -> (Process, String) {
    use std::os::windows::process::CommandExt;
    let mut p = Process::new("cmd");
    p.args(["/d", "/s", "/c"]).raw_arg(format!("\"{line}\""));
    (p, "cmd".to_string())
}

/// The words a spawn error says: `` `flutter` is not on PATH `` or the io error.
#[must_use]
pub fn why(e: &std::io::Error, program: &str) -> String {
    if e.kind() == std::io::ErrorKind::NotFound {
        format!("`{program}` is not on PATH")
    } else {
        e.to_string()
    }
}

/// R7: `could not start `{command}` ({where}): {why}`.
#[must_use]
pub fn start_error(cmd: &Cmd, place: &str, why: &str) -> anyhow::Error {
    anyhow::anyhow!("could not start `{}` ({place}): {why}", cmd.shown())
}

// --- before and after steps ---------------------------------------------------------------------

/// Runs `steps` in order with fsp's own stdio, each printed first as `› {command}`. The first
/// that fails stops, with its exit code. `kind` is `before` or `after`.
pub fn run_steps(kind: &str, task: &str, steps: &[Cmd], env: &Env<'_>) -> Result<()> {
    for (i, cmd) in steps.iter().enumerate() {
        let n = i + 1;
        if procs::signalled() {
            return Err(Exit(130).into());
        }
        eprintln!("› {}", cmd.shown());
        let place = format!("{kind} step {n} of `{task}`");
        let prepared = prepare(cmd, &[], env).map_err(|w| start_error(cmd, &place, &w))?;
        let program = prepared.program;
        let (status, interrupted) = procs::run_foreground(prepared.process)
            .map_err(|e| start_error(cmd, &place, &why(&e, &program)))?;
        if interrupted {
            return Err(Exit(130).into());
        }
        if !status.success() {
            eprintln!(
                "`{kind}` step {n} of `{task}` failed ({}): {}",
                status.describe(),
                cmd.shown()
            );
            return Err(Exit(status.code).into());
        }
    }
    Ok(())
}

/// The environment of a task: its `env`, and any `extra` (`FSP_BUILD_TARGET`).
fn task_vars(plan: &Plan, extra: &[(String, String)]) -> Vec<(String, String)> {
    let mut vars = plan.env.clone();
    vars.extend(extra.iter().cloned());
    vars
}

/// Starts the `with` commands of a plan, their output on stderr prefixed with their name.
pub fn start_withs(
    plan: &Plan,
    env: &Env<'_>,
    first_index: usize,
) -> Result<Vec<(String, Supervised)>> {
    let color = procs::color_enabled();
    let mut running: Vec<(String, Supervised)> = vec![];
    for (i, (name, cmd)) in plan.with.iter().enumerate() {
        let place = format!("`with` {name}");
        let started = prepare(cmd, &[], env)
            .map_err(|w| start_error(cmd, &place, &w))
            .and_then(|prepared| {
                let program = prepared.program;
                let label = name.clone();
                let index = first_index + i;
                let sink: Arc<dyn Fn(Out) + Send + Sync> = Arc::new(move |out| match out {
                    Out::Line { text, .. } => {
                        procs::write_stderr_line(&procs::prefixed(&label, index, &text, color));
                    }
                    Out::Exited(status) => procs::write_stderr_line(&procs::prefixed(
                        &label,
                        index,
                        &format!("exited ({})", status.describe()),
                        color,
                    )),
                });
                procs::spawn(prepared.process, false, sink)
                    .map_err(|e| start_error(cmd, &place, &why(&e, &program)))
            });
        match started {
            Ok(s) => running.push((name.clone(), s)),
            Err(e) => {
                stop_withs(&running);
                return Err(e);
            }
        }
    }
    Ok(running)
}

/// Stops `with` processes and what they started: SIGTERM to each group, SIGKILL after 5 s.
pub fn stop_withs(running: &[(String, Supervised)]) {
    for (_, s) in running {
        if s.exited().is_none() {
            procs::term_group(s.pid);
        }
    }
    for (_, s) in running {
        s.terminate(std::time::Duration::from_secs(5));
    }
}

/// `before`, `with` next to `run`, then `after` when `run` exits 0: the shape of `fsp build` and
/// `fsp run`. `run` gets fsp's own stdio.
fn execute(
    project: &Path,
    plan: &Plan,
    extra_args: &[String],
    extra_vars: &[(String, String)],
) -> Result<()> {
    let exe = std::env::current_exe()?;
    let env = Env {
        cwd: project,
        vars: task_vars(plan, extra_vars),
        fsp: &exe,
    };
    run_steps("before", &plan.name, &plan.before, &env)?;
    let withs = start_withs(plan, &env, 0)?;
    let outcome = run_main(plan, extra_args, &env);
    stop_withs(&withs);
    let status = outcome?;
    if !status.success() {
        return Err(Exit(status.code).into());
    }
    run_steps("after", &plan.name, &plan.after, &env)
}

fn run_main(plan: &Plan, extra_args: &[String], env: &Env<'_>) -> Result<Status> {
    let place = format!("`run` of `{}`", plan.name);
    let prepared =
        prepare(&plan.run, extra_args, env).map_err(|w| start_error(&plan.run, &place, &w))?;
    let program = prepared.program;
    let (status, interrupted) = procs::run_foreground(prepared.process)
        .map_err(|e| start_error(&plan.run, &place, &why(&e, &program)))?;
    if interrupted {
        return Err(Exit(130).into());
    }
    Ok(status)
}

// --- `fsp build` and `fsp run` -------------------------------------------------------------------

#[derive(Args)]
pub struct BuildCmd {
    /// What `flutter build` builds: apk, appbundle, ios, ipa, web, macos, linux, windows, ...
    pub target: String,
    /// Print what would run, and run nothing
    #[arg(long)]
    pub dry_run: bool,
    /// Passed on to `flutter build <TARGET>`, after `--`: `fsp build web -- --release`
    #[arg(last = true, value_name = "FLUTTER_BUILD_ARGS")]
    pub args: Vec<String>,
}

#[derive(Args)]
pub struct RunCmd {
    /// The task's name, as in `tasks:` in pubspec.yaml; leave it out to list the tasks
    pub task: Option<String>,
    /// Print what would run, and run nothing
    #[arg(long)]
    pub dry_run: bool,
    /// Passed on to the task's `run` command, after `--`
    #[arg(last = true, value_name = "ARGS")]
    pub args: Vec<String>,
}

/// `fsp build <target>`: `fsp gen`, then the `build` task.
pub fn build(project: &Path, cmd: &BuildCmd) -> Result<()> {
    let cfg = Config::load(project)?;
    let plan = Tasks::from_config(&cfg)?.build();
    let mut args = vec![cmd.target.clone()];
    args.extend(cmd.args.iter().cloned());
    if cmd.dry_run {
        eprint!(
            "{}",
            dry_run(
                &format!("fsp build {}", cmd.target),
                project,
                &plan,
                &args,
                Some(&format!("gen     {}", cfg.output)),
                None,
            )
        );
        return Ok(());
    }
    procs::install_signals().map_err(anyhow::Error::msg)?;
    eprintln!("{}", crate::gen_opts(project, &cfg, true, false)?.line());
    let vars = [("FSP_BUILD_TARGET".to_string(), cmd.target.clone())];
    execute(project, &plan, &args, &vars)
}

/// `fsp run [task]`.
pub fn run_task(project: &Path, cmd: &RunCmd) -> Result<()> {
    let cfg = Config::load(project)?;
    let tasks = Tasks::from_config(&cfg)?;
    let Some(name) = &cmd.task else {
        print!("{}", tasks.listing());
        return Ok(());
    };
    if name == "dev" {
        bail!(
            "`dev` is the task `fsp dev` runs, with the watcher, the device and hot reload: run `fsp dev`"
        );
    }
    if name == "build" {
        bail!(
            "`build` is the task `fsp build <target>` runs, after `fsp gen`: run `fsp build web` (or apk, ipa, macos, ...)"
        );
    }
    let Some(plan) = tasks.named(name) else {
        let known = tasks.names().join(", ");
        if cfg
            .tasks
            .as_ref()
            .is_none_or(|v| matches!(v, Value::Mapping(m) if m.is_empty()))
        {
            bail!(
                "no task `{name}` in `fespalier: tasks:` of pubspec.yaml; there are none yet (README, \"Tasks: commands around `flutter run`\")"
            );
        }
        bail!("no task `{name}` in `fespalier: tasks:` of pubspec.yaml; the tasks are: {known}");
    };
    if cmd.dry_run {
        eprint!(
            "{}",
            dry_run(
                &format!("fsp run {name}"),
                project,
                &plan,
                &cmd.args,
                None,
                None
            )
        );
        return Ok(());
    }
    procs::install_signals().map_err(anyhow::Error::msg)?;
    execute(project, &plan, &cmd.args, &[])
}

/// What `--dry-run` prints: the plan, one line per step. `gen` is its own line (`fsp dev` and
/// `fsp build`), `hot` the last line (`fsp dev`).
#[must_use]
pub fn dry_run(
    header: &str,
    project: &Path,
    plan: &Plan,
    run_args: &[String],
    gen_line: Option<&str>,
    hot: Option<&str>,
) -> String {
    let mut out = format!("{header} in {}\n", project.display());
    if let Some(g) = gen_line {
        let _ = writeln!(out, "  {g}");
    }
    let lines = |label: &str, items: Vec<String>| -> String {
        if items.is_empty() {
            return format!("  {label:<7} (nothing)\n");
        }
        items
            .iter()
            .map(|i| format!("  {label:<7} {i}\n"))
            .collect()
    };
    out.push_str(&lines(
        "before",
        plan.before.iter().map(Cmd::shown).collect(),
    ));
    out.push_str(&lines(
        "with",
        plan.with
            .iter()
            .map(|(n, c)| format!("{n}: {}", c.shown()))
            .collect(),
    ));
    let mut run = plan.run.shown();
    for a in run_args {
        run.push(' ');
        run.push_str(&show_word(a));
    }
    let _ = writeln!(out, "  {:<7} {run}", "run");
    out.push_str(&lines("after", plan.after.iter().map(Cmd::shown).collect()));
    out.push_str(&lines(
        "env",
        plan.env.iter().map(|(k, v)| format!("{k}={v}")).collect(),
    ));
    if let Some(h) = hot {
        let _ = writeln!(out, "  {h}");
    }
    out
}
