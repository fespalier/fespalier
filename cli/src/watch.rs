//! The loop behind `fsp watch` and `fsp dev`: regenerate on every relevant change under the app
//! folder (and the rest of `lib/`), once per burst of saves.
//!
//! [`watch_loop`] reports through a sink instead of printing, so `fsp watch` prints byte for byte
//! what it always has and `fsp dev` can put the same lines in a pane of its own. The loop runs on
//! the thread that calls it: the parse cache is thread-local, so every pass must be on one thread.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};

use anyhow::Result;
use notify::event::ModifyKind;
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};

use crate::config::Config;
use crate::diag::{self, Diags, Level, Loc};
use crate::parse_cache;
use crate::session::Session;

/// What wakes the loop: a relevant change on disk, a failure of the file watcher, or a request
/// to end.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wake {
    Changed,
    Failed(String),
    Stop,
}

/// What the loop has to say, in the order it says it.
pub enum Watched<'a> {
    /// Diagnostics that were not shown by the pass before. `fsp watch` renders them to stderr.
    Diags(&'a Path, &'a Diags),
    /// A warning from `dart format`.
    Warning(String),
    /// A pass is done.
    Pass(GenReport),
    /// `watching lib/app/ …`, once the watcher is up.
    Watching(String),
}

/// The first error of a pass, for a status line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FirstError {
    /// The first line of the message.
    pub message: String,
    pub loc: Option<Loc>,
}

/// What one regeneration did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GenReport {
    /// The pass that runs once the watcher starts, before any change.
    pub first: bool,
    /// Whether `gen` succeeded.
    pub ok: bool,
    /// Whether it wrote an output file. A pass can write and still fail: a string path that
    /// `lints: unknown_path: error` rejects fails the command, not the output.
    pub wrote: bool,
    /// The route count of a pass that succeeded.
    pub routes: Option<usize>,
    /// How many errors the pass reported (0 when `ok`).
    pub errors: usize,
    pub first_error: Option<FirstError>,
    pub elapsed: Duration,
    /// An unchanged rerun: `fsp watch` prints nothing for it.
    pub quiet: bool,
    /// The line `fsp watch` prints for the pass, if it prints one.
    pub line: Option<String>,
}

/// Whether a filesystem event can change what the app folder generates.
/// Reads (`Access`, which the generator itself causes) and metadata-only changes
/// don't, and neither does the generated file when it lives in the app folder.
/// `watch` also sees `lib/` outside the app folder, because an enum a segment names is
/// declared there (`lib/models/category.dart`): of those paths only Dart files and folders
/// (a path with no extension) count, not the `.png` or `.json` beside them.
pub fn relevant(ev: &Event, outputs: &[PathBuf], app_dir: &Path) -> bool {
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

/// Runs `gen` once, then again after every burst of changes, until a [`Wake::Stop`] arrives.
/// `tx` is the sending end of `rx`, which the file watcher's callback clones.
pub fn watch_loop(
    project: &Path,
    cfg: &Config,
    tx: Sender<Wake>,
    rx: &Receiver<Wake>,
    mut sink: impl FnMut(Watched<'_>),
) -> Result<()> {
    let app_dir = project.join(&cfg.app_dir);
    let main_output = cfg.output_main();
    let outputs: Vec<PathBuf> = [
        Some(&cfg.output),
        cfg.output_manifest.as_ref(),
        Some(&main_output),
    ]
    .into_iter()
    .flatten()
    .map(|o| project.join(o))
    .collect();
    // A save changes one file: keep the parse results of the others between runs, and the
    // last run's result and formatted text (see session.rs).
    parse_cache::enable();
    let mut pass = Pass {
        project,
        cfg,
        shown: Shown::default(),
        session: Session::default(),
    };
    pass.run(true, &mut sink);

    let changes_under = app_dir.clone();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| match res {
            Ok(ev) if relevant(&ev, &outputs, &changes_under) => {
                let _ = tx.send(Wake::Changed);
            }
            Ok(_) => {}
            Err(e) => {
                let _ = tx.send(Wake::Failed(e.to_string()));
            }
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
    sink(Watched::Watching(format!("watching {}/ …", cfg.app_dir)));
    loop {
        match rx.recv() {
            Ok(Wake::Changed) => {}
            Ok(Wake::Failed(why)) => {
                sink(Watched::Warning(format!("watch error: {why}")));
                continue;
            }
            Ok(Wake::Stop) | Err(_) => break,
        }
        // Editors save in bursts; one regeneration per burst.
        loop {
            match rx.recv_timeout(Duration::from_millis(80)) {
                Ok(Wake::Changed) => {}
                Ok(Wake::Failed(why)) => {
                    sink(Watched::Warning(format!("watch error: {why}")));
                }
                Ok(Wake::Stop) => return Ok(()),
                Err(_) => break,
            }
        }
        pass.run(false, &mut sink);
    }
    Ok(())
}

struct Pass<'a> {
    project: &'a Path,
    cfg: &'a Config,
    shown: Shown,
    session: Session,
}

impl Pass<'_> {
    fn run(&mut self, first: bool, sink: &mut impl FnMut(Watched<'_>)) {
        let t = Instant::now();
        let mut diags = String::new();
        let mut first_error: Option<FirstError> = None;
        let mut errors = 0;
        let cfg = self.cfg;
        let shown = &self.shown;
        let result = crate::gen_core(self.project, cfg, true, &mut self.session, |dir, d| {
            diags =
                d.0.iter()
                    .map(std::string::ToString::to_string)
                    .collect::<Vec<_>>()
                    .join("\n");
            errors = d.error_count();
            first_error =
                d.0.iter()
                    .find(|x| x.level == Level::Error)
                    .map(|x| FirstError {
                        message: x.msg.lines().next().unwrap_or_default().to_string(),
                        loc: diag::location(dir, &cfg.app_dir, x),
                    });
            if diags != shown.diags {
                sink(Watched::Diags(dir, d));
            }
        });
        for w in self.session.formats.take_warnings() {
            sink(Watched::Warning(w));
        }
        let outcome = match &result {
            Ok(_) => diags.clone(),
            Err(e) => format!("{diags}\n{e:#}"),
        };
        let quiet = !first && outcome == self.shown.outcome;
        let elapsed = t.elapsed();
        let report = match result {
            Ok(o) => GenReport {
                first,
                ok: true,
                wrote: o.wrote,
                routes: Some(o.routes),
                errors: 0,
                first_error: None,
                elapsed,
                quiet,
                line: (o.wrote || !quiet).then(|| format!("{} ({elapsed:.1?})", o.line())),
            },
            Err(e) => {
                let text = format!("{e:#}");
                GenReport {
                    first,
                    ok: false,
                    // A string path that `lints: unknown_path: error` rejects fails the command
                    // after the output is written.
                    wrote: self.session.wrote,
                    routes: None,
                    errors: errors.max(1),
                    first_error: first_error.or_else(|| {
                        Some(FirstError {
                            message: text.lines().next().unwrap_or_default().to_string(),
                            loc: None,
                        })
                    }),
                    elapsed,
                    quiet,
                    line: (!quiet).then_some(text),
                }
            }
        };
        self.shown = Shown { diags, outcome };
        parse_cache::finish_run();
        sink(Watched::Pass(report));
    }
}
