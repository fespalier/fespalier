//! `fsp doctor` (since 0.23.0): what the generated `main()` wires and why, and what is out of line
//! around it. A report, like Spring Boot's conditions report, with a status per row:
//!
//! - **wiring** (`doctor/wiring.rs`): whether `lib/app.main.g.dart` is written and why, what the root
//!   files give it, each adapter (listed, found by `adapters: auto`, or a first-party adapter package
//!   that is a dependency and is not wired), telemetry, `otel`, forms, deferred pages, tasks;
//! - **versions** (`doctor/versions.rs`): fespalier's `ref:` against this `fsp`, every companion's
//!   `url` and `ref` against fespalier's, `pubspec.lock` against both, `go_router` against the range
//!   fespalier supports, and Flutter and Dart against fespalier's floor and the companions' own;
//! - **checks** (`doctor/checks.rs`): what `fsp gen` never checks (the `links:`, `maestro:`, `size:`,
//!   `test:` and `tasks:` sections, which only their commands read), the `build_runner` trap,
//!   `lib/main.dart` and `AppMain.run()`, and a one-line summary of `fsp check`, whose diagnostics it
//!   does not repeat.
//!
//! It is advisory, so it reads more than `fsp gen` may: `pubspec.lock` (a workspace member's is the
//! workspace root's), every Dart file under `lib/` (for `AppMain.run(` and the adapters' `configure(`
//! calls, by their text), what `fsp check` reads (the `path:` dependencies' files, through
//! `enums::Libs`), and `flutter --version --machine` when `flutter` is on PATH. `fsp` itself never
//! reads the pub cache or `.dart_tool/`, never reaches the network and writes nothing; the `flutter`
//! it runs is another program and may do any of that (its own cache, its analytics, the download of
//! its Dart SDK on a fresh clone). [`gather`] does all the reading; [`rows`] is a function of what it
//! read, so the tests give it any [`Facts`].
//!
//! A group of rows is a module with a `rows(&Facts) -> Vec<Row>` and one entry in [`GROUPS`]: a later
//! group (a Rust core's toolchain, say) is a file of its own beside these.

mod checks;
pub(crate) mod versions;
mod wiring;

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Result;
use clap::Args;
use serde_yaml_ng::Value;

use crate::Exit;
use crate::config::{Config, Pubspec};
use crate::upgrade::Version;

#[derive(Args, Debug)]
pub struct DoctorCmd {
    /// Print the report to stdout as JSON lines (section, check, subject, status, message)
    #[arg(long)]
    pub json: bool,
}

/// Where a row is printed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    Wiring,
    Versions,
    Checks,
}

impl Section {
    /// How `--json` names it.
    pub fn name(self) -> &'static str {
        match self {
            Section::Wiring => "wiring",
            Section::Versions => "versions",
            Section::Checks => "checks",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Section::Wiring => "What the generated main() wires, and why",
            Section::Versions => "Versions",
            Section::Checks => "Checks",
        }
    }
}

/// How a row reads. Only [`Status::Error`] makes `fsp doctor` exit 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// As it should be.
    Ok,
    /// What is, neither right nor wrong (`telemetry: false`).
    Info,
    /// Works, and may not be what you meant.
    Warning,
    /// Will not work as it is.
    Error,
    /// Not checked, and why (no `pubspec.lock`, no `flutter` on PATH).
    Skipped,
}

impl Status {
    /// How `--json` names it.
    pub fn name(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Info => "info",
            Status::Warning => "warning",
            Status::Error => "error",
            Status::Skipped => "skipped",
        }
    }

    fn mark(self) -> &'static str {
        match self {
            Status::Ok => "✓",
            Status::Info => "·",
            Status::Warning => "!",
            Status::Error => "✗",
            Status::Skipped => "-",
        }
    }
}

/// One line of the report.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub section: Section,
    /// What was looked at, a stable name (`main`, `adapter`, `companion`, `go_router`...).
    pub check: &'static str,
    /// The package or file the row is about, when there are several of its `check`.
    pub subject: Option<String>,
    pub status: Status,
    /// A sentence that stands alone.
    pub message: String,
}

impl Row {
    pub(crate) fn new(
        section: Section,
        check: &'static str,
        status: Status,
        message: impl Into<String>,
    ) -> Row {
        Row {
            section,
            check,
            subject: None,
            status,
            message: message.into(),
        }
    }

    #[must_use]
    pub(crate) fn about(mut self, subject: impl Into<String>) -> Row {
        self.subject = Some(subject.into());
        self
    }
}

/// What `flutter --version --machine` says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toolchain {
    pub flutter: Version,
    pub dart: Version,
    /// Flutter's version is a pre-release (`3.35.0-0.1.pre`), which pub orders below `3.35.0`.
    pub flutter_pre: bool,
}

impl Toolchain {
    /// From the JSON `flutter --version --machine` prints (`frameworkVersion`, `dartSdkVersion`); a
    /// pre-release (`3.38.0-0.1.pre`) or a Dart `3.13.5 (build ...)` reads as its `x.y.z`.
    #[must_use]
    pub fn parse(stdout: &str) -> Option<Toolchain> {
        let start = stdout.find('{')?;
        let end = stdout.rfind('}')?;
        let v: serde_json::Value = serde_json::from_str(stdout.get(start..=end)?).ok()?;
        let flutter = v.get("frameworkVersion")?.as_str()?;
        Some(Toolchain {
            flutter: leading_version(flutter)?,
            dart: leading_version(v.get("dartSdkVersion")?.as_str()?)?,
            flutter_pre: flutter.contains('-'),
        })
    }
}

/// The `x.y.z` a version string starts with: `3.38.0-0.1.pre` is 3.38.0.
pub(crate) fn leading_version(text: &str) -> Option<Version> {
    let end = text
        .find(|c: char| !c.is_ascii_digit() && c != '.')
        .unwrap_or(text.len());
    Version::parse(text.get(..end)?.trim_end_matches('.'))
}

/// What the app is, read once for every group.
#[derive(Debug)]
pub struct AppFacts {
    /// Whether the app folder could be read as a tree: when not, `main`, `swaps` and `root` are
    /// empty, not found to be so.
    pub readable: bool,
    /// Whether the generated `main()` is written, and why (`entry::main_reasons`).
    pub main: (bool, Vec<String>),
    pub root: crate::entry::RootReport,
    /// A hot reload swaps the route table (`entry::swaps`).
    pub swaps: bool,
    /// The `form()` companions of the actions.
    pub forms: usize,
    /// The routes whose page loads on demand.
    pub deferred: usize,
    /// What `fsp check` said: the routes, the errors and warnings it printed, or why it stopped.
    pub check: CheckFacts,
    /// The `build_runner` warnings `fsp check` also prints (`build_runner::check`).
    pub build_runner: Vec<(String, String)>,
}

/// The outcome of `fsp check`, counted.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct CheckFacts {
    pub routes: usize,
    /// The errors and warnings `fsp check` prints, but those with a row of their own in the
    /// report (`listed`): a problem is counted once.
    pub errors: usize,
    pub warnings: usize,
    /// The diagnostics another row already is: the `form()` without `fespalier_forms` (`forms`) and
    /// the `build_runner` trap (`build_runner`), which `fsp check` prints too.
    pub listed: usize,
    /// Why it stopped before it could check the tree (no app folder).
    pub failure: Option<String>,
}

/// Everything the report is about. [`gather`] reads it; the tests make it.
#[derive(Debug)]
pub struct Facts {
    pub project: PathBuf,
    /// This `fsp`'s version.
    pub fsp: Version,
    /// pubspec.yaml as YAML: what the versions are read from, even when `config.rs` refuses it.
    pub raw: Option<Value>,
    /// What `config.rs` makes of pubspec.yaml, or why it refuses it.
    pub pubspec: Result<Pubspec, String>,
    /// pubspec.lock as YAML, when there is one that reads: the project's, or, for a pub workspace
    /// member, the workspace root's (pub writes the one lock there).
    pub lock: Option<Value>,
    /// The pubspec says `resolution: workspace`: it has no `pubspec.lock` beside it.
    pub workspace_member: bool,
    /// `flutter --version --machine`, when `flutter` is on PATH and answered; else why not.
    pub toolchain: Result<Toolchain, String>,
    /// The app, when the config reads.
    pub app: Option<AppFacts>,
    /// The Dart files under `lib/` but the ones `fsp` writes (`*.g.dart`, `output:` and
    /// `output_manifest:`), each relative to the project and with its comments taken out: where
    /// `AppMain.run(` and the adapters' `configure(` calls are looked for.
    pub sources: Vec<(String, String)>,
}

impl Facts {
    /// The config, when pubspec.yaml reads.
    pub fn config(&self) -> Option<&Config> {
        self.pubspec.as_ref().ok().map(|p| &p.config)
    }

    /// The files of [`Facts::sources`] that hold `needle`, by their path.
    pub fn files_with(&self, needle: &str) -> Vec<&str> {
        self.sources
            .iter()
            .filter(|(_, code)| code.contains(needle))
            .map(|(file, _)| file.as_str())
            .collect()
    }
}

/// The groups of rows, in the order they print. A new group is a module and one entry here.
const GROUPS: [fn(&Facts) -> Vec<Row>; 3] = [wiring::rows, versions::rows, checks::rows];

/// The report: every group's rows, in order.
#[must_use]
pub fn rows(facts: &Facts) -> Vec<Row> {
    GROUPS.iter().flat_map(|group| group(facts)).collect()
}

/// Reads what the report is about. `toolchain` is what `flutter --version --machine` printed, or
/// why there is nothing (`flutter` is not on PATH).
#[must_use]
pub fn gather(project: &Path, toolchain: Result<String, String>) -> Facts {
    let text = fs::read_to_string(project.join("pubspec.yaml"));
    let raw = text
        .as_ref()
        .ok()
        .and_then(|t| serde_yaml_ng::from_str::<Value>(t).ok());
    let pubspec = match &text {
        Ok(t) => Pubspec::parse(t).map_err(|e| refused(format!("{e:#}"))),
        Err(e) => Err(format!("pubspec.yaml: {e}")),
    };
    let lock = read_lock(project, raw.as_ref());
    let workspace_member = is_workspace_member(raw.as_ref());
    let toolchain = toolchain.and_then(|out| {
        Toolchain::parse(&out)
            .ok_or_else(|| "`flutter --version --machine` printed no version".to_string())
    });
    let app = pubspec.as_ref().ok().map(|p| app_facts(project, &p.config));
    let mut sources = vec![];
    dart_sources(project, &project.join("lib"), &mut sources);
    if let Ok(p) = &pubspec {
        // An `output:` that is not a `.g.dart` is still generated code, which says `AppAdapters.`.
        let written = crate::outputs(&p.config, false);
        sources.retain(|(file, _)| !written.contains(file));
    }
    sources.sort();
    Facts {
        project: project.to_path_buf(),
        fsp: Version::parse(env!("CARGO_PKG_VERSION")).unwrap_or(Version(0, 0, 0)),
        raw,
        pubspec,
        lock,
        workspace_member,
        toolchain,
        app,
        sources,
    }
}

/// Whether the pubspec says `resolution: workspace`.
fn is_workspace_member(raw: Option<&Value>) -> bool {
    raw.and_then(|r| r.get("resolution"))
        .and_then(Value::as_str)
        == Some("workspace")
}

/// `pubspec.lock` as pub wrote it: beside the pubspec, or, for a pub workspace member, beside the
/// root's (a member has none of its own).
fn read_lock(project: &Path, raw: Option<&Value>) -> Option<Value> {
    let root = raw.and_then(|r| crate::packages::workspace_root(project, r));
    let dir = root.as_ref().map_or(project, |(dir, _)| dir.as_path());
    let text = fs::read_to_string(dir.join("pubspec.lock")).ok()?;
    serde_yaml_ng::from_str::<Value>(&text).ok()
}

/// What `config.rs` refused, as the report says it: its own message when it already names the file
/// (`invalid pubspec.yaml: ...`, from serde), else the file's name in front of it.
fn refused(message: String) -> String {
    if message.starts_with("invalid pubspec.yaml") {
        message
    } else {
        format!("pubspec.yaml: {message}")
    }
}

/// The Dart files under `dir` but generated ones (`*.g.dart`), relative to `project`, without
/// their comments.
fn dart_sources(project: &Path, dir: &Path, out: &mut Vec<(String, String)>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            dart_sources(project, &path, out);
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.ends_with(".dart") || name.ends_with(".g.dart") {
            continue;
        }
        if let Ok(src) = fs::read_to_string(&path) {
            let rel = path
                .strip_prefix(project)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            out.push((rel, crate::entry::without_comments(&src)));
        }
    }
}

/// The app's facts: the tree read as `fsp check` reads it, and `fsp check` itself, counted.
fn app_facts(project: &Path, cfg: &Config) -> AppFacts {
    let app_dir = project.join(&cfg.app_dir);
    let mut scratch = crate::diag::Diags::default();
    let tree = crate::scan::scan(&app_dir, &mut scratch).ok();
    let readable = tree.is_some();
    let (main, root, swaps) = match &tree {
        Some(t) => (
            crate::entry::main_reasons(t, cfg),
            crate::entry::root_report(t),
            crate::entry::swaps(t, cfg),
        ),
        None => ((false, vec![]), crate::entry::RootReport::default(), false),
    };
    let (forms, deferred, routes) = match crate::analyze(&app_dir, cfg) {
        Ok((_, _, app)) => (
            app.routes
                .iter()
                .flat_map(|r| &r.actions)
                .filter(|a| a.form.is_some())
                .count(),
            app.routes.iter().filter(|r| r.defers_page()).count(),
            app.routes.iter().filter(|r| r.is_route()).count(),
        ),
        Err(_) => (0, 0, 0),
    };
    let outputs = crate::outputs(cfg, main.0);
    let build_runner: Vec<(String, String)> = crate::build_runner::check(project, cfg, &outputs)
        .0
        .into_iter()
        .map(|d| (d.file, d.msg))
        .collect();
    let mut check = CheckFacts::default();
    let mut session = crate::session::Session::default();
    // What `fsp check` printed, as (errors, warnings).
    let mut printed = (0, 0);
    let outcome = crate::gen_core(project, cfg, false, &mut session, |_, diags| {
        printed = (diags.error_count(), diags.0.len() - diags.error_count());
    });
    // A `form()` without its package is an error for each form, and the `build_runner` trap one
    // warning per file: each has a row of its own, so `fsp_check` counts the rest.
    let own = (
        if cfg.forms_dependency { 0 } else { forms },
        build_runner.len(),
    );
    check.errors = printed.0.saturating_sub(own.0);
    check.warnings = printed.1.saturating_sub(own.1);
    check.listed = (printed.0 - check.errors) + (printed.1 - check.warnings);
    check.routes = routes;
    match outcome {
        Ok(o) => check.routes = o.routes,
        // A tree with errors says how many; anything else stopped before the tree.
        Err(e) if printed.0 == 0 => check.failure = Some(format!("{e:#}")),
        Err(_) => {}
    }
    AppFacts {
        readable,
        main,
        root,
        swaps,
        forms,
        deferred,
        check,
        build_runner,
    }
}

/// `flutter --version --machine`, run in the project, or why it did not answer.
fn flutter_version(project: &Path) -> Result<String, String> {
    // A folder that is not there would fail the spawn with the same error as a missing `flutter`.
    if !project.is_dir() {
        return Err(format!("{} is not a folder", project.display()));
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let env = crate::tasks::Env {
        cwd: project,
        vars: vec![],
        fsp: &exe,
    };
    let cmd = crate::tasks::Cmd::Argv(vec![
        "flutter".into(),
        "--version".into(),
        "--machine".into(),
    ]);
    let mut prepared = crate::tasks::prepare(&cmd, &[], &env)?;
    let program = prepared.program.clone();
    let out = prepared
        .process
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .map_err(|e| crate::tasks::why(&e, &program))?;
    if !out.status.success() {
        return Err(format!(
            "`flutter --version --machine` {}",
            crate::procs::Status::of(out.status).describe()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// One row as a JSON object: `{"section","check","subject","status","message"}`, every key there
/// (`subject` is `null` when the row is about no one package or file).
#[must_use]
pub fn json_line(row: &Row) -> String {
    serde_json::json!({
        "section": row.section.name(),
        "check": row.check,
        "subject": row.subject,
        "status": row.status.name(),
        "message": row.message,
    })
    .to_string()
}

/// The report as text: a header, the rows under their section's title, and a closing count.
#[must_use]
pub fn text(facts: &Facts, rows: &[Row]) -> String {
    let mut out = format!("fsp doctor {} ({})\n", facts.fsp, facts.project.display());
    let mut last: Option<Section> = None;
    for row in rows {
        if last != Some(row.section) {
            out.push_str(&format!("\n{}\n", row.section.title()));
            last = Some(row.section);
        }
        out.push_str(&format!(
            "  {} {:<12} {}\n",
            row.status.mark(),
            row.check,
            row.message
        ));
    }
    out.push('\n');
    out.push_str(&summary(rows));
    out.push('\n');
    out
}

/// `2 errors, 1 warning.`, or `Nothing out of line.`
fn summary(rows: &[Row]) -> String {
    let count = |s: Status| rows.iter().filter(|r| r.status == s).count();
    let (errors, warnings) = (count(Status::Error), count(Status::Warning));
    match (errors, warnings) {
        (0, 0) => "Nothing out of line.".into(),
        (0, w) => format!("{}.", crate::plural(w, "warning")),
        (e, 0) => format!("{}.", crate::plural(e, "error")),
        (e, w) => format!(
            "{}, {}.",
            crate::plural(e, "error"),
            crate::plural(w, "warning")
        ),
    }
}

pub fn run(project: &Path, cmd: &DoctorCmd) -> Result<()> {
    let facts = gather(project, flutter_version(project));
    let rows = rows(&facts);
    if cmd.json {
        for row in &rows {
            outln!("{}", json_line(row));
        }
    } else {
        out!("{}", text(&facts, &rows));
    }
    if rows.iter().any(|r| r.status == Status::Error) {
        return Err(Exit(1).into());
    }
    Ok(())
}
