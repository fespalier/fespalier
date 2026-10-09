//! `fsp create <dir>`: a new Flutter app with fespalier in it (since 0.15.0).
//!
//! The decisions are in `create/plan.rs` (pure: a request in, a plan out, pinned by goldens) and
//! the table of optional features in `create/recipes.rs`. This file is the I/O around them: it
//! reads the machine into a [`plan::Request`], and then does what the plan says, in this order:
//!
//! 1. `flutter create --no-pub --empty` into a sibling folder, `.<dir>.fsp-create-<pid>`;
//! 2. writes the plan's files over the result (the pubspec whole, `lib/main.dart`, `lib/app/**`);
//! 3. renames that folder to `<dir>` (before `pub get`: the generated platform files and the
//!    package config hold absolute paths, which must be the final ones);
//! 4. `flutter pub get`, `fsp gen` and `fsp test`, in this process.
//!
//! A failure before step 3 deletes the sibling folder and leaves nothing behind. After it the app
//! stays, and the message names the step that failed and the commands that finish the job.

use std::io;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::{env, fs, process};

use anyhow::{Context, Result, anyhow, bail};
use clap::Args;
use serde_json::json;

use crate::Exit;
use crate::config::Config;
use crate::procs;
use crate::tasks::{self, Cmd};

pub mod plan;
pub mod recipes;

use plan::{DirState, FlutterVersion, Plan, Request};

#[derive(Args)]
pub struct CreateCmd {
    /// The folder to make; its name is the app's package name unless --project-name says otherwise
    #[arg(value_name = "DIR", required_unless_present = "list_features")]
    pub dir: Option<PathBuf>,
    /// The Dart package name (default: the folder's name, lower case)
    #[arg(long, value_name = "NAME", conflicts_with = "list_features")]
    pub project_name: Option<String>,
    /// The organization for the Android and iOS identifiers, like `com.example` (flutter create's --org)
    #[arg(long, value_name = "ORG", conflicts_with = "list_features")]
    pub org: Option<String>,
    /// The platforms to make folders for, comma separated (flutter create's --platforms; default: all)
    #[arg(
        long,
        value_delimiter = ',',
        value_name = "PLATFORMS",
        conflicts_with = "list_features"
    )]
    pub platforms: Vec<String>,
    /// The `description:` of the pubspec
    #[arg(long, value_name = "TEXT", conflicts_with = "list_features")]
    pub description: Option<String>,
    /// Optional features to add, comma separated (`--list-features` lists them)
    #[arg(
        long,
        value_delimiter = ',',
        value_name = "FEATURES",
        conflicts_with = "list_features"
    )]
    pub features: Vec<String>,
    /// Print the optional features and exit
    #[arg(long, conflicts_with_all = ["dry_run", "no_pub_get", "offline"])]
    pub list_features: bool,
    /// Write the app but do not run `flutter pub get`
    #[arg(long)]
    pub no_pub_get: bool,
    /// Pass --offline to `flutter pub get`
    #[arg(long)]
    pub offline: bool,
    /// Print what would be made, run nothing and write nothing
    #[arg(long)]
    pub dry_run: bool,
    /// Print JSON lines to stdout (file, run, done, error); the text for people stays on stderr
    #[arg(long)]
    pub json: bool,
    /// Depend on the packages of a checkout of fespalier instead of its git tag (CI, contributors)
    #[arg(
        long,
        hide = true,
        value_name = "CHECKOUT",
        conflicts_with = "list_features"
    )]
    pub local_packages: Option<PathBuf>,
}

/// What `fsp create` says on stderr for people, and on stdout, with `--json`, for programs.
struct Report {
    json: bool,
}

impl Report {
    fn event(&self, value: &serde_json::Value) {
        if self.json {
            println!("{value}");
        }
    }
}

/// `fsp create`. `project` is the global `--project`, which this command refuses.
pub fn run(cmd: &CreateCmd, project: Option<&Path>) -> Result<()> {
    if project.is_some() {
        bail!(
            "fsp create takes the new app's folder as its argument; --project selects an existing app (`fsp init` sets one up)"
        );
    }
    let report = Report { json: cmd.json };
    let result = create(cmd, &report);
    if let Err(e) = &result {
        let message = match e.downcast_ref::<Exit>() {
            Some(_) => "interrupted or a command failed".to_string(),
            None => format!("{e:#}"),
        };
        report.event(&json!({ "event": "error", "message": message }));
    }
    result
}

fn create(cmd: &CreateCmd, report: &Report) -> Result<()> {
    if cmd.list_features {
        list_features(cmd.json);
        return Ok(());
    }
    let Some(given) = &cmd.dir else {
        bail!("fsp create needs the folder to make: `fsp create my_app`");
    };
    let abs =
        std::path::absolute(given).with_context(|| format!("resolving {}", given.display()))?;
    let local = cmd
        .local_packages
        .as_deref()
        .map(local_checkout)
        .transpose()?;
    let flutter = if cmd.dry_run {
        None
    } else {
        flutter_version(&abs)?
    };
    let request = Request {
        // `.` and `..` have no name of their own: the absolute path does.
        dir: if given.file_name().is_some() {
            given.clone()
        } else {
            abs.clone()
        },
        dir_state: dir_state(&abs)?,
        name: cmd.project_name.clone(),
        org: cmd.org.clone(),
        platforms: cmd.platforms.clone(),
        description: cmd.description.clone(),
        features: cmd.features.clone(),
        local_packages: local,
        no_pub_get: cmd.no_pub_get,
        offline: cmd.offline,
        flutter,
    };
    let plan = plan::build(&request, recipes::RECIPES)?;
    for note in &plan.notes {
        eprintln!("note: {note}");
    }
    if cmd.dry_run {
        dry_run(&plan, report);
        return Ok(());
    }
    execute(&plan, &abs, report)?;
    report.event(&done_event(&plan, false));
    eprintln!("\n✓ created {}", plan.dir.display());
    next_steps(&plan);
    Ok(())
}

fn done_event(plan: &Plan, dry_run: bool) -> serde_json::Value {
    json!({
        "event": "done",
        "dir": plan.dir.display().to_string(),
        "name": plan.name,
        "features": plan.features,
        "dry_run": dry_run,
    })
}

/// `--list-features`: one line per feature on stdout (JSON objects with `--json`).
fn list_features(json: bool) {
    let features = plan::list_features(recipes::RECIPES);
    if json {
        for f in &features {
            println!("{}", serde_json::to_string(f).unwrap_or_default());
        }
    } else if features.is_empty() {
        println!("no optional features yet: `fsp create <dir>` makes the base app");
    } else {
        let width = features.iter().map(|f| f.id.len()).max().unwrap_or(0);
        for f in &features {
            println!("{:<width$}  {}", f.id, f.description);
        }
    }
}

/// `--dry-run`: the plan, and nothing else.
fn dry_run(plan: &Plan, report: &Report) {
    eprint!("{}", plan.describe("<staging>"));
    let flutter_create = Cmd::Argv(
        ["flutter".to_string()]
            .into_iter()
            .chain(plan.flutter_create.iter().cloned())
            .chain(["<staging>".to_string()])
            .collect(),
    );
    report.event(&json!({ "event": "run", "command": flutter_create.shown() }));
    for file in &plan.files {
        report.event(&json!({
            "event": "file",
            "path": file.path,
            "action": file.action.word(),
            "content": file.content,
        }));
    }
    if let Some(args) = &plan.pub_get {
        let pub_get = Cmd::Argv(
            ["flutter".to_string()]
                .into_iter()
                .chain(args.clone())
                .collect(),
        );
        report.event(&json!({ "event": "run", "command": pub_get.shown() }));
    }
    report.event(&json!({ "event": "run", "command": "fsp gen" }));
    report.event(&json!({ "event": "run", "command": "fsp test" }));
    report.event(&done_event(plan, true));
}

/// A checkout of fespalier for `--local-packages`: absolute, with the core package in it.
fn local_checkout(path: &Path) -> Result<String> {
    let abs = fs::canonicalize(path)
        .with_context(|| format!("--local-packages {}: no such folder", path.display()))?;
    if !abs.join("packages/fespalier/pubspec.yaml").is_file() {
        bail!(
            "--local-packages {}: not a checkout of fespalier (no packages/fespalier/pubspec.yaml)",
            path.display()
        );
    }
    Ok(abs.to_string_lossy().replace('\\', "/"))
}

fn dir_state(dir: &Path) -> Result<DirState> {
    match fs::metadata(dir) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(DirState::Absent),
        Err(e) => Err(e).with_context(|| format!("reading {}", dir.display())),
        Ok(m) if !m.is_dir() => Ok(DirState::NotADirectory),
        Ok(_) => {
            let mut entries =
                fs::read_dir(dir).with_context(|| format!("reading {}", dir.display()))?;
            Ok(if entries.next().is_none() {
                DirState::Empty
            } else {
                DirState::NotEmpty
            })
        }
    }
}

/// The installed Flutter, from `flutter --version --machine`. `None` when it answers but not in
/// a way that can be read (the checks that need it are then skipped, with a warning); an error
/// when there is no `flutter` to run.
fn flutter_version(cwd: &Path) -> Result<Option<FlutterVersion>> {
    let probe = Cmd::Argv(vec![
        "flutter".to_string(),
        "--version".to_string(),
        "--machine".to_string(),
    ]);
    let fsp = env::current_exe().unwrap_or_else(|_| PathBuf::from("fsp"));
    let cwd = cwd
        .ancestors()
        .find(|d| d.is_dir())
        .unwrap_or(Path::new("."));
    let env = tasks::Env {
        cwd,
        vars: vec![],
        fsp: &fsp,
    };
    let mut prepared = tasks::prepare(&probe, &[], &env)
        .map_err(|w| tasks::start_error(&probe, "fsp create", &w))?;
    let out = prepared.process.stdin(Stdio::null()).output().map_err(|e| {
        if e.kind() == io::ErrorKind::NotFound {
            anyhow!(
                "`flutter` is not on PATH: install Flutter (https://docs.flutter.dev/get-started/install) and try again"
            )
        } else {
            anyhow!("could not run `flutter --version --machine`: {e}")
        }
    })?;
    let text = String::from_utf8_lossy(&out.stdout);
    // Flutter may print notices before the JSON object.
    let version = text
        .find('{')
        .and_then(|from| text.rfind('}').map(|to| &text[from..=to]))
        .and_then(|j| serde_json::from_str::<serde_json::Value>(j).ok())
        .and_then(|v| {
            v.get("frameworkVersion")
                .and_then(|f| f.as_str())
                .and_then(FlutterVersion::parse)
        });
    if version.is_none() {
        eprintln!("warning: could not read Flutter's version; not checking it");
    }
    Ok(version)
}

/// Deletes the folder `flutter create` works in, unless the app has been moved out of it.
struct Staging {
    path: PathBuf,
    armed: bool,
}

impl Drop for Staging {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

/// Runs one command in `cwd` with fsp's own stdio (stdout goes to stderr with `--json`).
fn run_command(cmd: &Cmd, cwd: &Path, report: &Report) -> Result<()> {
    report.event(&json!({ "event": "run", "command": cmd.shown() }));
    eprintln!("› {}", cmd.shown());
    let fsp = env::current_exe().unwrap_or_else(|_| PathBuf::from("fsp"));
    let env = tasks::Env {
        cwd,
        vars: vec![],
        fsp: &fsp,
    };
    let mut prepared =
        tasks::prepare(cmd, &[], &env).map_err(|w| tasks::start_error(cmd, "fsp create", &w))?;
    if report.json {
        prepared.process.stdout(Stdio::from(io::stderr()));
    }
    let program = prepared.program;
    let (status, interrupted) = procs::run_foreground(prepared.process)
        .map_err(|e| tasks::start_error(cmd, "fsp create", &tasks::why(&e, &program)))?;
    if interrupted {
        return Err(Exit(130).into());
    }
    if !status.success() {
        bail!("`{}` failed ({})", cmd.shown(), status.describe());
    }
    Ok(())
}

/// The error of a step after the app was moved into place: the app stays, and the message says
/// what is left to do.
fn left_over(plan: &Plan, abs: &Path, step: &str, rest: &str, e: &anyhow::Error) -> anyhow::Error {
    anyhow!(
        "{step} failed: {e:#}\n\nThe app is in {dir}; fix that and finish with:\n  cd {dir}\n  {rest}",
        dir = if plan.dir.file_name().is_some() {
            plan.dir.display().to_string()
        } else {
            abs.display().to_string()
        }
    )
}

/// Renames `staging` to `dir`. An empty folder that is already there (`fsp create .` in a new
/// folder) is kept, not replaced, so a shell that is in it stays in the app: the entries move
/// into it one by one, and `staging` goes.
fn move_into_place(staging: &Path, dir: &Path) -> io::Result<()> {
    if !dir.is_dir() {
        return fs::rename(staging, dir);
    }
    for entry in fs::read_dir(staging)? {
        let entry = entry?;
        fs::rename(entry.path(), dir.join(entry.file_name()))?;
    }
    fs::remove_dir(staging)
}

fn execute(plan: &Plan, abs: &Path, report: &Report) -> Result<()> {
    procs::install_signals().map_err(anyhow::Error::msg)?;
    let parent = abs.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let base = abs.file_name().and_then(|n| n.to_str()).unwrap_or("app");
    let mut staging = Staging {
        path: parent.join(format!(".{base}.fsp-create-{}", process::id())),
        armed: true,
    };
    let _ = fs::remove_dir_all(&staging.path);

    let mut words = vec!["flutter".to_string()];
    words.extend(plan.flutter_create.iter().cloned());
    words.push(staging.path.to_string_lossy().into_owned());
    run_command(&Cmd::Argv(words), parent, report)?;

    for file in &plan.files {
        let path = staging.path.join(&file.path);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        fs::write(&path, &file.content).with_context(|| format!("writing {}", path.display()))?;
        report.event(&json!({ "event": "file", "path": file.path, "action": file.action.word() }));
        eprintln!("  {:<5} {}", file.action.word(), file.path);
    }

    move_into_place(&staging.path, abs)
        .with_context(|| format!("moving the app to {}", abs.display()))?;
    staging.armed = false;

    let mut remaining = vec![];
    if plan.pub_get.is_some() {
        remaining.push("flutter pub get");
    }
    remaining.extend(["fsp gen", "fsp test"]);
    if let Some(args) = &plan.pub_get {
        let mut words = vec!["flutter".to_string()];
        words.extend(args.iter().cloned());
        run_command(&Cmd::Argv(words), abs, report)
            .map_err(|e| left_over(plan, abs, "flutter pub get", &remaining.join(" && "), &e))?;
        remaining.remove(0);
    }
    let gen_and_test = || -> Result<()> {
        let cfg = Config::load(abs)?.for_scaffolding();
        report.event(&json!({ "event": "run", "command": "fsp gen" }));
        let o = crate::gen_with(abs, &cfg, true)?;
        eprintln!("{}", o.line());
        report.event(&json!({ "event": "run", "command": "fsp test" }));
        crate::smoke::run(abs, false)
    };
    gen_and_test().map_err(|e| left_over(plan, abs, "fsp gen", &remaining.join(" && "), &e))
}

fn next_steps(plan: &Plan) {
    eprintln!("\nNext steps");
    eprintln!("  cd {}", plan.dir.display());
    if plan.pub_get.is_none() {
        eprintln!("  flutter pub get");
    }
    eprintln!("  fsp dev      # runs the app, regenerating on every save");
    if plan.features.is_empty() && !recipes::RECIPES.is_empty() {
        eprintln!("\nOptional features: `fsp create --list-features`");
    }
}
