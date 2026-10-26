//! The loop behind `fsp watch` and `fsp dev`: regenerate on every relevant change under the app
//! folder (and the rest of `lib/`), once per burst of saves.
//!
//! [`watch_loop`] reports through a sink instead of printing, so `fsp watch` prints byte for byte
//! what it always has and `fsp dev` can put the same lines in a pane of its own. The loop runs on
//! the thread that calls it: the parse cache is thread-local, so every pass must be on one thread.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};

use anyhow::Result;
use notify::event::ModifyKind;
use notify::{Event, EventKind, PathsMut, RecommendedWatcher, RecursiveMode, Watcher};

use crate::config::Config;
use crate::diag::{self, Diags, Level, Loc};
use crate::parse_cache;
use crate::reload::Stamp;
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
    /// Whether it wrote the generated `main()` (since 0.19.0). A hot reload never runs `main()`
    /// again, so `fsp dev` restarts the app for it.
    pub main_changed: bool,
    /// The output's stamp as the pass left it, when it got to writing (since 0.19.0). `None` makes
    /// `fsp dev` restart rather than reload.
    pub stamp: Option<Stamp>,
    /// Whether a hot reload can swap the routes the pass generated (since 0.19.0; `entry::swaps`).
    pub swaps: bool,
    /// Whether the pass wrote the app's configuration (`lib/app.config.g.dart`, since 0.23.0):
    /// `fsp dev` restarts the app for it, since a value read once (into a provider, a
    /// `static final`) keeps its old value through a hot reload.
    pub config_written: bool,
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
/// (a path with no extension) count, not the `.png` or `.json` beside them. The same goes for the
/// folders of a `path:` dependency that `watch` adds after a pass (since 0.22.0). In `config_dir`
/// (since 0.23.0) only its `.yaml` and `.yml` files count, and the folder itself.
pub fn relevant(ev: &Event, outputs: &[PathBuf], app_dir: &Path, config_dir: &Path) -> bool {
    let kind_matters = match ev.kind {
        EventKind::Access(_) | EventKind::Modify(ModifyKind::Metadata(_)) => false,
        EventKind::Create(_)
        | EventKind::Remove(_)
        | EventKind::Modify(_)
        | EventKind::Any
        | EventKind::Other => true,
    };
    let matters = |p: &PathBuf| {
        if p.starts_with(config_dir) {
            return p == config_dir
                || (p.parent() == Some(config_dir)
                    && p.extension().is_some_and(|e| e == "yaml" || e == "yml"));
        }
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
    let config_output = cfg.output_config();
    let outputs: Vec<PathBuf> = [
        Some(&cfg.output),
        cfg.output_manifest.as_ref(),
        Some(&main_output),
        Some(&config_output),
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
    let config_dir = project.join(crate::app_config::DIR);
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| match res {
            Ok(ev) if relevant(&ev, &outputs, &changes_under, &config_dir) => {
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
    // The folders of a path dependency that hold a file the last pass read (since 0.22.0), each on
    // its own and not recursively: only those can change what the next pass generates.
    let mut beside = Beside::default();
    for warning in pass.watch_beside(&mut watcher, &watched, &mut beside) {
        sink(Watched::Warning(warning));
    }
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
        for warning in pass.watch_beside(&mut watcher, &watched, &mut beside) {
            sink(Watched::Warning(warning));
        }
    }
    Ok(())
}

/// The folders outside the recursively watched one that are watched (since 0.22.0): those of a
/// `path:` dependency that hold a file the last pass read, each on its own.
#[derive(Debug, Default)]
pub(crate) struct Beside {
    /// The folders watched.
    watched: BTreeSet<PathBuf>,
    /// The folders the watcher refused, so that each is said once.
    refused: BTreeSet<PathBuf>,
}

/// What to change to watch the folders that are there.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Plan {
    /// Folders to stop watching: no longer wanted, or gone.
    pub(crate) stop: Vec<PathBuf>,
    /// Folders to watch.
    pub(crate) start: Vec<PathBuf>,
}

/// Whether asking a [`RecommendedWatcher`] to watch a folder it already watches changes nothing.
/// inotify drops the watch of a folder that is deleted (or moved away) and a folder made again at
/// its path is not watched, so each pass asks again, which adds to the watch that is there; the
/// other backends are asked once, as `FSEvents` restarts its stream for every call and keeps the
/// path twice. UNCHECKED there: a dependency folder deleted and made again within one pass.
fn asking_again_is_free() -> bool {
    matches!(RecommendedWatcher::kind(), notify::WatcherKind::Inotify)
}

impl Beside {
    /// What to do for the wanted folders `there` (those that exist now). With `again`, a folder that
    /// is watched is asked for again, in case the watch is of a folder that is gone.
    pub(crate) fn plan(&self, there: &BTreeSet<PathBuf>, again: bool) -> Plan {
        Plan {
            stop: self.watched.difference(there).cloned().collect(),
            start: there
                .iter()
                .filter(|dir| again || !self.watched.contains(*dir))
                .cloned()
                .collect(),
        }
    }

    /// Carries out `plan` in one batch (`FSEvents` restarts its stream for each call of `watch`), and
    /// returns what to tell the user: each folder the watcher refuses, once. A refused folder is in the
    /// next plan, so it is tried again after the next pass. Nothing is told for a folder that is not
    /// there yet: it is asked for when it is.
    pub(crate) fn apply(&mut self, plan: &Plan, paths: &mut dyn PathsMut) -> Vec<String> {
        let mut told = vec![];
        for dir in &plan.stop {
            // Its watch may be gone already, which is why it is stopped.
            let _ = paths.remove(dir);
            self.watched.remove(dir);
        }
        for dir in &plan.start {
            match paths.add(dir, RecursiveMode::NonRecursive) {
                Ok(()) => {
                    self.watched.insert(dir.clone());
                    self.refused.remove(dir);
                }
                Err(e) => {
                    self.watched.remove(dir);
                    if self.refused.insert(dir.clone()) {
                        told.push(format!(
                            "watch error: cannot watch {}: {e}; changes there are not seen",
                            dir.display()
                        ));
                    }
                }
            }
        }
        told
    }

    /// Forgets the refusals of folders that are gone or not wanted, so a later one is told again.
    pub(crate) fn forget(&mut self, there: &BTreeSet<PathBuf>) {
        self.refused.retain(|dir| there.contains(dir));
    }
}

struct Pass<'a> {
    project: &'a Path,
    cfg: &'a Config,
    shown: Shown,
    session: Session,
}

impl Pass<'_> {
    /// Brings the watches outside `watched` in line with the folders the last pass read from, and
    /// returns what to tell the user (since 0.22.0). Every folder that is there is watched, one that
    /// was deleted and made again included, which the watcher dropped (see
    /// [`asking_again_is_free`]); the others are watched when they come.
    fn watch_beside(
        &self,
        watcher: &mut RecommendedWatcher,
        watched: &Path,
        beside: &mut Beside,
    ) -> Vec<String> {
        let there: BTreeSet<PathBuf> = self
            .session
            .last
            .reads()
            .map(|r| r.folders(self.project))
            .unwrap_or_default()
            .into_iter()
            // The app's configuration (since 0.23.0), whenever the folder is there: one made while
            // `fsp watch` runs is watched from the pass after it appears.
            .chain(std::iter::once(self.project.join(crate::app_config::DIR)))
            .filter(|d| !d.starts_with(watched) && d.is_dir())
            .collect();
        beside.forget(&there);
        let plan = beside.plan(&there, asking_again_is_free());
        if plan == Plan::default() {
            return vec![];
        }
        let mut paths = watcher.paths_mut();
        let mut told = beside.apply(&plan, &mut *paths);
        if let Err(e) = paths.commit() {
            told.push(format!("watch error: {e}"));
        }
        told
    }

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
                main_changed: self.session.main_changed,
                stamp: self.session.stamp.clone(),
                swaps: self.session.swaps,
                config_written: self.session.config_written.is_some(),
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
                    main_changed: self.session.main_changed,
                    stamp: self.session.stamp.clone(),
                    swaps: self.session.swaps,
                    config_written: self.session.config_written.is_some(),
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
