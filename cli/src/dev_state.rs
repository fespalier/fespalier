//! What `fsp dev` knows, as a value: the panes and their lines, flutter's state, the last
//! generation, the hot reload requests in flight, and the shutdown. [`DevState::update`] takes one
//! [`Input`] (a daemon message, a line, a key, a signal, an exit, a tick) and says what to do
//! about it as [`Effect`]s; nothing in this file reads a clock, a file or a terminal, so a test
//! drives it with whatever `now` it likes (since 0.9.0).
//!
//! The rules that matter live here: a regeneration that wrote restarts the app and any other save
//! reloads it (see [`DevState::request`]); requests are coalesced; flutter is stopped first, then
//! the `with` processes, and a second quit kills everything.

use std::collections::VecDeque;
use std::time::Duration;

use serde_json::Value;

use crate::daemon::{self, Event, Msg, Response};
use crate::procs::Status;
use crate::watch::{FirstError, GenReport};

/// The pane of `flutter run`.
pub const FLUTTER: usize = 0;
/// The pane of fsp's own lines: generation, the app's address, hot reload results.
pub const FSP: usize = 1;
/// How many lines a pane keeps.
pub const RING: usize = 10_000;

/// How long flutter gets to stop after `app.stop` before it is sent SIGTERM.
const FLUTTER_GRACE: Duration = Duration::from_secs(10);
/// How long a group gets after SIGTERM before SIGKILL.
const TERM_GRACE: Duration = Duration::from_secs(5);

/// What a line is, for colour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Normal,
    Warn,
    Error,
}

/// One line of a pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneLine {
    pub text: String,
    pub kind: Kind,
}

/// Whether a pane's process is running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Proc {
    /// Not a process (the `fsp` pane), or not started.
    Idle,
    Running,
    Exited(Status),
}

/// A pane: a name and the last [`RING`] lines of one source.
#[derive(Debug, Clone)]
pub struct Pane {
    pub name: String,
    pub lines: VecDeque<PaneLine>,
    pub proc: Proc,
}

impl Pane {
    fn new(name: &str) -> Pane {
        Pane {
            name: name.to_string(),
            lines: VecDeque::new(),
            proc: Proc::Idle,
        }
    }
}

/// A line of a pane that plain mode prints.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlainLine {
    pub pane: usize,
    pub text: String,
    pub kind: Kind,
}

/// What a key is, whatever the terminal library calls it.
#[allow(dead_code, reason = "the full-screen view reads it (the next commit)")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Ctrl(char),
    Enter,
}

/// Everything that can happen to `fsp dev`.
#[allow(dead_code, reason = "the full-screen view reads it (the next commit)")]
#[derive(Debug, Clone)]
pub enum Input {
    /// A message from flutter's daemon protocol.
    Daemon(Msg),
    /// A line of a pane's process (flutter's stray text and stderr, a `with` command), or one of
    /// fsp's own (`pane` is [`FSP`]).
    Line {
        pane: usize,
        text: String,
        err: bool,
    },
    /// A regeneration finished.
    Gen(GenReport),
    Key(Key),
    /// A line typed in plain mode.
    Typed(String),
    /// SIGINT, SIGTERM, SIGHUP or the console's Ctrl-C.
    Signal,
    /// A process ended.
    Exited {
        pane: usize,
        status: Status,
    },
    /// Time passed.
    Tick,
}

/// What the caller has to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// A line for flutter's stdin.
    SendFlutter(String),
    /// SIGTERM to a pane's group.
    Term(usize),
    /// SIGKILL to a pane's group.
    Kill(usize),
    /// Everything is stopped: leave the loop.
    Finish,
    /// A second quit: kill every group at once and leave.
    KillAll,
}

/// A device `flutter devices --machine` lists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub platform: String,
}

/// What [`pick_device`] decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pick {
    /// The arguments name a device: pass nothing.
    Skip,
    /// This one.
    Device(Device),
    /// Several, and someone to ask.
    Choose(Vec<Device>),
    /// Several, and no one to ask: the ids to say.
    NeedFlag(Vec<String>),
    /// `flutter devices` lists none this project supports.
    NoDevice,
    /// The listing did not parse.
    Unlisted,
}

/// Whether `args` (the ones after `--`) name a device: `-d x`, `-dx`, `--device-id x`,
/// `--device-id=x`.
#[must_use]
pub fn names_a_device(args: &[String]) -> bool {
    args.iter().any(|a| {
        a == "-d"
            || a == "--device-id"
            || a.starts_with("--device-id=")
            || (a.starts_with("-d") && !a.starts_with("--"))
    })
}

/// The device to run on, from `flutter devices --machine`'s output, the way `flutter run` would
/// choose and where it would ask. Only supported devices count. One device, or exactly one phone
/// or emulator (flutter's own "single ephemeral device" rule), is picked; with several, `interactive`
/// says whether someone can be asked.
#[must_use]
pub fn pick_device(listing: &str, args: &[String], interactive: bool) -> Pick {
    if names_a_device(args) {
        return Pick::Skip;
    }
    let (Some(start), Some(end)) = (listing.find('['), listing.rfind(']')) else {
        return Pick::Unlisted;
    };
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(&listing[start..=end]) else {
        return Pick::Unlisted;
    };
    let devices: Vec<Device> = items
        .iter()
        .filter(|d| {
            d.get("isSupported")
                .and_then(Value::as_bool)
                .unwrap_or(true)
        })
        .filter_map(|d| {
            let id = d.get("id")?.as_str()?.to_string();
            Some(Device {
                name: d
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or(&id)
                    .to_string(),
                platform: d
                    .get("targetPlatform")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                id,
            })
        })
        .collect();
    let mobile: Vec<&Device> = devices
        .iter()
        .filter(|d| d.platform.starts_with("android") || d.platform.starts_with("ios"))
        .collect();
    match (devices.as_slice(), mobile.as_slice()) {
        ([], _) => Pick::NoDevice,
        ([one], _) => Pick::Device(one.clone()),
        (_, [one]) => Pick::Device((*one).clone()),
        _ if interactive => Pick::Choose(devices),
        _ => Pick::NeedFlag(devices.into_iter().map(|d| d.id).collect()),
    }
}

/// `text` without ANSI escape sequences: colours and cursor moves (`ESC [ … final`), operating
/// system commands such as hyperlinks (`ESC ] … BEL` or `ESC \`), and two-character escapes.
#[must_use]
pub fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('[') => {
                for n in chars.by_ref() {
                    if ('\x40'..='\x7e').contains(&n) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(n) = chars.next() {
                    if n == '\x07' {
                        break;
                    }
                    if n == '\x1b' {
                        if chars.peek() == Some(&'\\') {
                            chars.next();
                        }
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// Where the app is in its life, for the header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// flutter was started; `app.start` has not come.
    Starting,
    /// `app.start` came; `app.started` has not.
    Building,
    Running,
    Reloading,
    Restarting,
    /// flutter exited by itself, with this code.
    Stopped(i32),
    /// fsp is shutting down.
    Quitting,
}

/// What is known of the app flutter runs.
#[derive(Debug, Clone, Default)]
pub struct App {
    /// The id flutter gave the app in `app.start`.
    pub id: Option<String>,
    pub mode: Option<String>,
    pub device: Option<Device>,
    pub ws_uri: Option<String>,
    pub devtools: Option<String>,
    pub web_url: Option<String>,
    pub progress: Option<String>,
    pub supports_restart: bool,
    /// `daemon.connected` came: flutter speaks `--machine`.
    pub connected: bool,
}

/// What the last generation did.
#[allow(dead_code, reason = "the full-screen view reads it (the next commit)")]
#[derive(Debug, Clone, Default)]
pub struct Generation {
    pub routes: Option<usize>,
    pub errors: usize,
    pub first_error: Option<FirstError>,
    /// When it finished, on the state's clock; `None` before the first.
    pub at: Option<Duration>,
    pub elapsed: Duration,
}

/// The last hot reload or restart.
#[allow(dead_code, reason = "the full-screen view reads it (the next commit)")]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HotResult {
    pub full: bool,
    pub ok: bool,
    pub ms: u128,
    /// The message flutter gave: how many libraries a reload reloaded, or why it failed.
    pub message: String,
}

struct Inflight {
    id: u64,
    full: bool,
    sent: Duration,
}

struct Quit {
    by_signal: bool,
    stage: Stage,
    since: Duration,
    termed_at: Option<Duration>,
    killed: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    Flutter,
    With,
}

/// What the state is made from.
pub struct Opts {
    /// The names of the `with` panes, in order.
    pub with: Vec<String>,
    /// `hot_reload:` of the task: whether a save reloads by itself.
    pub hot_reload: bool,
    /// Plain output: keys are typed lines, and `d` and `o` print instead of opening.
    pub plain: bool,
    /// The generated file as the user spells it, for the `hot restart: … changed` line.
    pub output: String,
    /// The device fsp chose, when it did.
    pub device: Option<Device>,
}

/// Everything `fsp dev` knows. See the module docs.
pub struct DevState {
    panes: Vec<Pane>,
    plain: bool,
    plain_out: VecDeque<PlainLine>,
    hot_reload: bool,
    output: String,
    pub app: App,
    pub generation: Generation,
    phase: Phase,
    last_hot: Option<HotResult>,
    next_id: u64,
    inflight: Vec<Inflight>,
    pending: Option<bool>,
    keys_hint_shown: bool,
    flutter_failed: Option<i32>,
    quit: Option<Quit>,
    killed_all: bool,
    finished: bool,
}

impl DevState {
    #[must_use]
    pub fn new(opts: Opts) -> DevState {
        let mut panes = vec![Pane::new("flutter"), Pane::new("fsp")];
        panes.extend(opts.with.iter().map(|n| Pane::new(n)));
        DevState {
            panes,
            plain: opts.plain,
            plain_out: VecDeque::new(),
            hot_reload: opts.hot_reload,
            output: opts.output,
            app: App {
                device: opts.device,
                supports_restart: true,
                ..App::default()
            },
            generation: Generation::default(),
            phase: Phase::Starting,
            last_hot: None,
            next_id: 1,
            inflight: vec![],
            pending: None,
            keys_hint_shown: false,
            flutter_failed: None,
            quit: None,
            killed_all: false,
            finished: false,
        }
    }

    #[must_use]
    pub fn panes(&self) -> &[Pane] {
        &self.panes
    }

    #[must_use]
    #[allow(dead_code, reason = "the full-screen view reads it (the next commit)")]
    pub fn phase(&self) -> Phase {
        self.phase
    }

    #[must_use]
    #[allow(dead_code, reason = "the full-screen view reads it (the next commit)")]
    pub fn last_hot(&self) -> Option<&HotResult> {
        self.last_hot.as_ref()
    }

    /// Whether the loop can end: everything is stopped, or was killed.
    #[must_use]
    pub fn finished(&self) -> bool {
        self.finished
    }

    /// What `fsp dev` exits with: 130 for a signal or a second quit, flutter's own code when it
    /// stopped by itself with a failure, else 0.
    #[must_use]
    pub fn exit_code(&self) -> i32 {
        if self.killed_all || self.quit.as_ref().is_some_and(|q| q.by_signal) {
            130
        } else {
            self.flutter_failed.unwrap_or(0)
        }
    }

    /// Whether the `after` steps run: flutter did not fail by itself, and nothing was killed.
    #[must_use]
    pub fn after_ok(&self) -> bool {
        !self.killed_all && self.flutter_failed.is_none()
    }

    /// Marks a pane's process as started.
    pub fn started(&mut self, pane: usize) {
        self.panes[pane].proc = Proc::Running;
        if pane == FLUTTER {
            self.phase = Phase::Starting;
        }
    }

    /// The lines plain mode has not printed yet.
    pub fn drain_plain(&mut self) -> Vec<PlainLine> {
        self.plain_out.drain(..).collect()
    }

    /// A line of fsp's own, from outside (the device, a warning).
    pub fn say(&mut self, text: &str, kind: Kind) {
        self.push(FSP, text, kind);
    }

    /// The next time [`Input::Tick`] has something to do: the shutdown's deadlines.
    #[must_use]
    pub fn next_deadline(&self) -> Option<Duration> {
        let q = self.quit.as_ref()?;
        match (q.stage, q.termed_at, q.killed) {
            (_, _, true) => None,
            (Stage::Flutter, None, false) => Some(q.since + FLUTTER_GRACE),
            (_, Some(at), false) => Some(at + TERM_GRACE),
            (Stage::With, None, false) => None,
        }
    }

    fn flutter_running(&self) -> bool {
        self.panes[FLUTTER].proc == Proc::Running
    }

    fn push(&mut self, pane: usize, text: &str, kind: Kind) {
        let clean = strip_ansi(text);
        let mut lines: Vec<&str> = clean.split('\n').collect();
        if lines.len() > 1 && lines.last() == Some(&"") {
            lines.pop();
        }
        for line in lines {
            let line = line.trim_end_matches('\r');
            let p = &mut self.panes[pane];
            if p.lines.len() == RING {
                p.lines.pop_front();
            }
            p.lines.push_back(PaneLine {
                text: line.to_string(),
                kind,
            });
            if self.plain {
                self.plain_out.push_back(PlainLine {
                    pane,
                    text: line.to_string(),
                    kind,
                });
            }
        }
    }

    /// Takes one input; returns what to do about it.
    pub fn update(&mut self, now: Duration, input: Input) -> Vec<Effect> {
        let mut fx = vec![];
        match input {
            Input::Daemon(msg) => self.on_msg(now, msg, &mut fx),
            Input::Line { pane, text, err } => {
                let kind = if err { Kind::Error } else { Kind::Normal };
                self.push(pane, &text, kind);
            }
            Input::Gen(report) => self.on_gen(now, &report, &mut fx),
            Input::Key(key) => self.on_key(now, key, &mut fx),
            Input::Typed(line) => {
                let mut chars = line.trim().chars();
                if let (Some(c), None) = (chars.next(), chars.next()) {
                    self.on_key(now, Key::Char(c), &mut fx);
                }
            }
            Input::Signal => self.shut_down(now, true, &mut fx),
            Input::Exited { pane, status } => self.on_exit(now, pane, status, &mut fx),
            Input::Tick => self.on_tick(now, &mut fx),
        }
        fx
    }

    // --- flutter's messages -------------------------------------------------------------------

    fn on_msg(&mut self, now: Duration, msg: Msg, fx: &mut Vec<Effect>) {
        match msg {
            Msg::Response(r) => self.on_response(now, &r),
            Msg::Event(e) => self.on_event(now, e, fx),
        }
    }

    fn on_event(&mut self, now: Duration, event: Event, fx: &mut Vec<Effect>) {
        match event {
            Event::Connected { .. } => self.app.connected = true,
            Event::LogMessage { level, message } => {
                if level == "error" {
                    self.push(FLUTTER, &format!("error: {message}"), Kind::Error);
                } else {
                    let kind = if level == "warning" {
                        Kind::Warn
                    } else {
                        Kind::Normal
                    };
                    self.push(FLUTTER, &message, kind);
                }
            }
            Event::AppStart {
                app_id,
                device_id,
                supports_restart,
                mode,
            } => {
                self.app.id = Some(app_id);
                self.app.supports_restart = supports_restart;
                self.app.mode = mode;
                if let Some(id) = device_id
                    && self.app.device.as_ref().is_none_or(|d| d.id != id)
                {
                    self.app.device = Some(Device {
                        name: id.clone(),
                        id,
                        platform: String::new(),
                    });
                }
                if self.phase == Phase::Starting {
                    self.phase = Phase::Building;
                }
                if let Some(full) = self.pending.take() {
                    self.send_request(now, full, false, fx);
                }
            }
            Event::DebugPort { ws_uri, .. } => self.app.ws_uri = ws_uri,
            Event::DevTools { uri } => {
                self.say(&format!("DevTools: {uri}"), Kind::Normal);
                self.app.devtools = Some(uri);
            }
            Event::Started { .. } => {
                if matches!(self.phase, Phase::Starting | Phase::Building) {
                    self.phase = Phase::Running;
                }
                self.app.progress = None;
                let running = match &self.app.device {
                    Some(d) if d.name != d.id => format!("app running on {} ({})", d.name, d.id),
                    Some(d) => format!("app running on {}", d.id),
                    None => "app running".to_string(),
                };
                self.say(&running, Kind::Normal);
                if self.plain && !self.keys_hint_shown {
                    self.keys_hint_shown = true;
                    self.say(
                        "keys: r reload · R restart · q quit (type the letter, then Enter)",
                        Kind::Normal,
                    );
                }
            }
            Event::Log { log, error, .. } => {
                let kind = if error { Kind::Error } else { Kind::Normal };
                self.push(FLUTTER, &log, kind);
            }
            Event::Progress { message, finished } => {
                if !finished && let Some(m) = message {
                    self.push(FLUTTER, &m, Kind::Normal);
                    self.app.progress = Some(m);
                }
            }
            Event::Stop { error, .. } => {
                if let Some(e) = error {
                    self.push(FLUTTER, &e, Kind::Error);
                }
            }
            Event::WebLaunchUrl { url } => {
                self.say(&format!("web: {url}"), Kind::Normal);
                self.app.web_url = Some(url);
            }
            Event::Other(_) => {}
        }
    }

    // --- hot reload and restart ---------------------------------------------------------------

    /// A request for a reload, or for a restart when `full`. `manual` is a key.
    ///
    /// - Before `app.start` there is no app id: the strongest request is kept (a restart beats a
    ///   reload) and sent on `app.start`.
    /// - A restart in flight covers a new reload, which is dropped; a new restart is sent, because
    ///   the file changed after the first compile began (flutter queues it).
    /// - Otherwise it is sent; a reload is sent debounced, so flutter merges neighbours.
    fn request(&mut self, now: Duration, full: bool, manual: bool, fx: &mut Vec<Effect>) {
        if self.quit.is_some() || !self.flutter_running() {
            return;
        }
        if self.app.id.is_none() {
            if manual && !self.app.connected {
                self.say(
                    "the `run` command has not connected over flutter's --machine protocol yet; hot reload needs `flutter run`",
                    Kind::Warn,
                );
                return;
            }
            self.pending = Some(self.pending.unwrap_or(false) || full);
            return;
        }
        if !self.app.supports_restart {
            if manual {
                self.say(
                    "hot reload is off: flutter run started without it (--no-hot, --profile or --release)",
                    Kind::Warn,
                );
            }
            return;
        }
        if !full && self.inflight.iter().any(|i| i.full) {
            return;
        }
        self.send_request(now, full, manual, fx);
    }

    fn send_request(&mut self, now: Duration, full: bool, manual: bool, fx: &mut Vec<Effect>) {
        let Some(app_id) = self.app.id.clone() else {
            return;
        };
        let id = self.next_id;
        self.next_id += 1;
        self.inflight.push(Inflight {
            id,
            full,
            sent: now,
        });
        // A reload does not end a restart that is still going.
        self.phase = if full || self.phase == Phase::Restarting {
            Phase::Restarting
        } else {
            Phase::Reloading
        };
        let reason = if manual { "manual" } else { "save" };
        fx.push(Effect::SendFlutter(daemon::restart(
            id, &app_id, full, reason, !manual,
        )));
    }

    fn on_response(&mut self, now: Duration, r: &Response) {
        let Some(at) = self.inflight.iter().position(|i| i.id == r.id) else {
            return;
        };
        let sent = self.inflight.remove(at);
        let ms = now.saturating_sub(sent.sent).as_millis();
        let what = if sent.full { "restart" } else { "reload" };
        let result = match r.failure() {
            None => {
                let message = r
                    .outcome
                    .as_ref()
                    .map(|o| o.message.clone())
                    .unwrap_or_default();
                let line = if sent.full || message.is_empty() {
                    format!("✓ hot {what} in {ms} ms")
                } else {
                    format!("✓ hot {what} in {ms} ms ({message})")
                };
                self.say(&line, Kind::Normal);
                HotResult {
                    full: sent.full,
                    ok: true,
                    ms,
                    message: if sent.full { String::new() } else { message },
                }
            }
            Some(why) => {
                self.say(&format!("✗ hot {what} failed: {why}"), Kind::Error);
                // Plain mode has said it; the view keeps the full message in flutter's pane.
                if !self.plain {
                    self.push(FLUTTER, &why, Kind::Error);
                }
                HotResult {
                    full: sent.full,
                    ok: false,
                    ms,
                    message: why,
                }
            }
        };
        self.last_hot = Some(result);
        if self.inflight.is_empty() && matches!(self.phase, Phase::Reloading | Phase::Restarting) {
            self.phase = Phase::Running;
        } else if let Some(last) = self.inflight.last() {
            self.phase = if self.inflight.iter().any(|i| i.full) || last.full {
                Phase::Restarting
            } else {
                Phase::Reloading
            };
        }
    }

    // --- a regeneration -----------------------------------------------------------------------

    fn on_gen(&mut self, now: Duration, r: &GenReport, fx: &mut Vec<Effect>) {
        self.generation = Generation {
            routes: r.routes.or(self.generation.routes),
            errors: r.errors,
            first_error: r.first_error.clone(),
            at: Some(now),
            elapsed: r.elapsed,
        };
        if let Some(line) = &r.line {
            let kind = if r.ok { Kind::Normal } else { Kind::Error };
            self.push(FSP, line, kind);
        }
        if !self.hot_reload {
            return;
        }
        if r.wrote {
            let line = format!("hot restart: {} changed", self.output);
            self.say(&line, Kind::Normal);
            self.request(now, true, false, fx);
        } else if r.ok && !r.first {
            self.request(now, false, false, fx);
        }
    }

    // --- keys ---------------------------------------------------------------------------------

    fn on_key(&mut self, now: Duration, key: Key, fx: &mut Vec<Effect>) {
        match key {
            Key::Char('q') | Key::Ctrl('c') => self.shut_down(now, false, fx),
            _ if self.quit.is_some() => {}
            Key::Char('r') => self.request(now, false, true, fx),
            Key::Char('R') => self.request(now, true, true, fx),
            Key::Char('d') => {
                let line = match &self.app.devtools {
                    Some(uri) => format!("DevTools: {uri}"),
                    None => "no DevTools URL yet".to_string(),
                };
                self.say(&line, Kind::Normal);
            }
            Key::Char('o') => {
                let line = match (&self.app.web_url, &self.app.device) {
                    (Some(url), _) => format!("web: {url}"),
                    (None, Some(d)) => format!("no web URL: the app runs on {}", d.name),
                    (None, None) => "no web URL yet".to_string(),
                };
                self.say(&line, Kind::Normal);
            }
            Key::Char(_) | Key::Ctrl(_) | Key::Enter => {}
        }
    }

    // --- shutdown -----------------------------------------------------------------------------

    /// The first call stops flutter (`app.stop`, then SIGTERM after 10 s, SIGKILL 5 s later),
    /// then the `with` processes (SIGTERM, SIGKILL after 5 s). A second kills everything.
    fn shut_down(&mut self, now: Duration, by_signal: bool, fx: &mut Vec<Effect>) {
        if self.quit.is_some() {
            if !self.finished {
                fx.push(Effect::KillAll);
            }
            self.killed_all = true;
            self.finished = true;
            return;
        }
        self.quit = Some(Quit {
            by_signal,
            stage: Stage::Flutter,
            since: now,
            termed_at: None,
            killed: false,
        });
        self.phase = Phase::Quitting;
        if self.flutter_running() {
            self.say(
                "stopping flutter… (press q or Ctrl-C again to kill it)",
                Kind::Normal,
            );
            if let Some(app_id) = self.app.id.clone() {
                let id = self.next_id;
                self.next_id += 1;
                fx.push(Effect::SendFlutter(daemon::stop(id, &app_id)));
            } else {
                // Nothing to ask: flutter has not said which app it runs.
                fx.push(Effect::Term(FLUTTER));
                if let Some(q) = self.quit.as_mut() {
                    q.termed_at = Some(now);
                }
            }
        }
        self.advance(now, fx);
    }

    /// Moves the shutdown on: when flutter is gone, the `with` groups are asked to stop; when
    /// nothing runs, it is done.
    fn advance(&mut self, now: Duration, fx: &mut Vec<Effect>) {
        let flutter_up = self.flutter_running();
        let with_up: Vec<usize> = (2..self.panes.len())
            .filter(|i| self.panes[*i].proc == Proc::Running)
            .collect();
        let Some(q) = self.quit.as_mut() else {
            return;
        };
        if q.stage == Stage::Flutter && !flutter_up {
            q.stage = Stage::With;
            q.since = now;
            q.termed_at = None;
            q.killed = false;
            if !with_up.is_empty() {
                q.termed_at = Some(now);
                fx.extend(with_up.iter().map(|p| Effect::Term(*p)));
            }
        }
        if q.stage == Stage::With && with_up.is_empty() && !flutter_up && !self.finished {
            self.finished = true;
            fx.push(Effect::Finish);
        }
    }

    fn on_tick(&mut self, now: Duration, fx: &mut Vec<Effect>) {
        let flutter_up = self.flutter_running();
        let with_up: Vec<usize> = (2..self.panes.len())
            .filter(|i| self.panes[*i].proc == Proc::Running)
            .collect();
        let Some(q) = self.quit.as_mut() else {
            return;
        };
        if q.killed {
            return;
        }
        match (q.stage, q.termed_at) {
            (Stage::Flutter, None) if now >= q.since + FLUTTER_GRACE && flutter_up => {
                fx.push(Effect::Term(FLUTTER));
                q.termed_at = Some(now);
            }
            (Stage::Flutter, Some(at)) if now >= at + TERM_GRACE && flutter_up => {
                fx.push(Effect::Kill(FLUTTER));
                q.killed = true;
            }
            (Stage::With, Some(at)) if now >= at + TERM_GRACE => {
                fx.extend(with_up.iter().map(|p| Effect::Kill(*p)));
                q.killed = true;
            }
            _ => {}
        }
    }

    fn on_exit(&mut self, now: Duration, pane: usize, status: Status, fx: &mut Vec<Effect>) {
        self.panes[pane].proc = Proc::Exited(status);
        if pane == FLUTTER {
            self.app.id = None;
            self.inflight.clear();
            self.pending = None;
            if self.quit.is_none() {
                let kind = if status.success() {
                    Kind::Normal
                } else {
                    Kind::Error
                };
                self.push(
                    FLUTTER,
                    &format!("flutter run exited (exit {})", status.code),
                    kind,
                );
                self.flutter_failed = (!status.success()).then_some(status.code);
                self.phase = Phase::Stopped(status.code);
                // Plain mode has nothing to keep open: it ends with flutter.
                if self.plain {
                    self.shut_down(now, false, fx);
                    return;
                }
            }
        } else if self.quit.is_none() {
            let name = self.panes[pane].name.clone();
            self.say(
                &format!(
                    "[{name}] exited (exit {}); fsp dev keeps running",
                    status.code
                ),
                Kind::Warn,
            );
        }
        self.advance(now, fx);
    }
}
