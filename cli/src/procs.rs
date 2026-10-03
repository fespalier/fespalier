//! The processes `fsp dev`, `fsp build` and `fsp run` start (since 0.9.0): how they are spawned,
//! watched, signalled and stopped.
//!
//! Every process that fsp supervises (flutter and each `with` command) runs in its own process
//! group on Unix and with `CREATE_NEW_PROCESS_GROUP` on Windows, so a stop reaches what it
//! started too, and only fsp decides when that happens. Unix stops a group with `killpg`
//! (SIGTERM, then SIGKILL); Windows has no signals to send, so it uses `taskkill /T /F`. Steps
//! (`before`, `after`, and `run` of `fsp build` and `fsp run`) stay in fsp's own group with the
//! terminal's stdio, so Ctrl-C reaches them as it reaches fsp.
//!
//! Signals reach fsp through one `ctrlc` handler: SIGINT, SIGTERM and SIGHUP on Unix, Ctrl-C and
//! closing the console on Windows.

use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

/// How a process ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Status {
    /// The exit code, or 128 plus the signal number when a signal ended it (the shell's rule).
    pub code: i32,
    /// The signal that ended it, on Unix.
    pub signal: Option<i32>,
}

impl Status {
    #[must_use]
    pub fn of(status: ExitStatus) -> Status {
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            if let Some(s) = status.signal() {
                return Status {
                    code: 128 + s,
                    signal: Some(s),
                };
            }
        }
        Status {
            code: status.code().unwrap_or(1),
            signal: None,
        }
    }

    #[must_use]
    pub fn success(self) -> bool {
        self.code == 0 && self.signal.is_none()
    }

    /// `exit 3`, or `killed by signal 9`: what the messages put in parentheses.
    #[must_use]
    pub fn describe(self) -> String {
        match self.signal {
            Some(s) => format!("killed by signal {s}"),
            None => format!("exit {}", self.code),
        }
    }
}

// --- signals ----------------------------------------------------------------------------------

static SIGNALLED: AtomicBool = AtomicBool::new(false);
static SINK: Mutex<Option<Sender<()>>> = Mutex::new(None);
static INSTALLED: OnceLock<Result<(), String>> = OnceLock::new();

/// Installs the handler for SIGINT, SIGTERM and SIGHUP (Ctrl-C and close on Windows), once. A
/// signal sets [`signalled`] and wakes whoever last called [`subscribe`].
pub fn install_signals() -> Result<(), String> {
    INSTALLED
        .get_or_init(|| {
            ctrlc::set_handler(|| {
                SIGNALLED.store(true, Ordering::SeqCst);
                if let Ok(sink) = SINK.lock()
                    && let Some(tx) = sink.as_ref()
                {
                    let _ = tx.send(());
                }
            })
            .map_err(|e| format!("could not install the signal handler: {e}"))
        })
        .clone()
}

/// A channel that gets a `()` for each signal from now on. Only the latest subscriber hears.
pub fn subscribe() -> Receiver<()> {
    let (tx, rx) = mpsc::channel();
    if let Ok(mut sink) = SINK.lock() {
        *sink = Some(tx);
    }
    rx
}

/// Whether a signal has arrived since the handler was installed.
pub fn signalled() -> bool {
    SIGNALLED.load(Ordering::SeqCst)
}

// --- stopping a group -------------------------------------------------------------------------

/// Asks the process group of `pid` to stop (SIGTERM; `taskkill /T /F` on Windows, which has no
/// grace).
pub fn term_group(pid: u32) {
    stop_group(pid, false);
}

/// Stops the process group of `pid` at once (SIGKILL; `taskkill /T /F`).
pub fn kill_group(pid: u32) {
    stop_group(pid, true);
}

#[cfg(unix)]
fn stop_group(pid: u32, force: bool) {
    use nix::sys::signal::{Signal, killpg};
    use nix::unistd::Pid;
    let Ok(pid) = i32::try_from(pid) else {
        return;
    };
    let signal = if force {
        Signal::SIGKILL
    } else {
        Signal::SIGTERM
    };
    // The group may be gone already.
    let _ = killpg(Pid::from_raw(pid), signal);
}

#[cfg(windows)]
fn stop_group(pid: u32, _force: bool) {
    let _ = Command::new("taskkill")
        .args(["/T", "/F", "/PID", &pid.to_string()])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

/// Stops one process (not its group), for a step that shares fsp's group.
#[cfg(unix)]
fn stop_pid(pid: u32, force: bool) {
    use nix::sys::signal::{Signal, kill};
    use nix::unistd::Pid;
    let Ok(pid) = i32::try_from(pid) else {
        return;
    };
    let signal = if force {
        Signal::SIGKILL
    } else {
        Signal::SIGTERM
    };
    let _ = kill(Pid::from_raw(pid), signal);
}

#[cfg(windows)]
fn stop_pid(pid: u32, force: bool) {
    stop_group(pid, force);
}

// --- supervised processes ---------------------------------------------------------------------

/// What a supervised process tells its owner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Out {
    /// One line of its output (`err`: from stderr).
    Line { text: String, err: bool },
    /// It ended, after every line it wrote that the pipes still held.
    Exited(Status),
}

struct Done {
    status: Mutex<Option<Status>>,
    cv: Condvar,
}

/// A process in a group of its own, with its output on pipes, pumped by threads into a sink.
pub struct Supervised {
    pub pid: u32,
    stdin: Mutex<Option<ChildStdin>>,
    done: Arc<Done>,
}

impl Supervised {
    /// Writes `line` and a newline to its stdin, when it has one.
    pub fn write_line(&self, line: &str) -> io::Result<()> {
        let mut guard = self
            .stdin
            .lock()
            .map_err(|_| io::Error::other("stdin lock poisoned"))?;
        match guard.as_mut() {
            Some(stdin) => {
                stdin.write_all(line.as_bytes())?;
                stdin.write_all(b"\n")?;
                stdin.flush()
            }
            None => Err(io::Error::new(io::ErrorKind::BrokenPipe, "no stdin")),
        }
    }

    /// How it ended, if it has.
    pub fn exited(&self) -> Option<Status> {
        self.done.status.lock().ok().and_then(|s| *s)
    }

    /// Waits up to `timeout` for it to end; `None` when it did not.
    pub fn wait(&self, timeout: Duration) -> Option<Status> {
        let deadline = Instant::now() + timeout;
        let mut status = self.done.status.lock().ok()?;
        loop {
            if let Some(s) = *status {
                return Some(s);
            }
            let left = deadline.checked_duration_since(Instant::now())?;
            let (next, result) = self.done.cv.wait_timeout(status, left).ok()?;
            status = next;
            if result.timed_out() {
                return *status;
            }
        }
    }

    /// SIGTERM to its group, SIGKILL after `grace`; returns once it has ended (or after a further
    /// 2 s, if it will not).
    pub fn terminate(&self, grace: Duration) -> Option<Status> {
        if let Some(s) = self.exited() {
            return Some(s);
        }
        term_group(self.pid);
        if let Some(s) = self.wait(grace) {
            return Some(s);
        }
        kill_group(self.pid);
        self.wait(Duration::from_secs(2))
    }
}

/// Starts `command` in a group of its own with its output on pipes (and stdin, when `pipe_stdin`,
/// else null). The sink gets every line, and `Out::Exited` last.
pub fn spawn(
    mut command: Command,
    pipe_stdin: bool,
    sink: Arc<dyn Fn(Out) + Send + Sync>,
) -> io::Result<Supervised> {
    command
        .stdin(if pipe_stdin {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    own_group(&mut command);
    let mut child = command.spawn()?;
    let pid = child.id();
    let stdin = child.stdin.take();
    let (pumped, finished) = mpsc::channel::<()>();
    if let Some(out) = child.stdout.take() {
        pump(out, false, &sink, pumped.clone());
    }
    if let Some(err) = child.stderr.take() {
        pump(err, true, &sink, pumped.clone());
    }
    drop(pumped);
    let done = Arc::new(Done {
        status: Mutex::new(None),
        cv: Condvar::new(),
    });
    let waiter_done = Arc::clone(&done);
    thread::spawn(move || {
        let status = child.wait().map_or(
            Status {
                code: 1,
                signal: None,
            },
            Status::of,
        );
        // Let the pumps hand over what the pipes still hold, but not for ever: a grandchild may
        // keep a pipe open.
        for _ in 0..2 {
            if finished.recv_timeout(Duration::from_millis(500)).is_err() {
                break;
            }
        }
        if let Ok(mut s) = waiter_done.status.lock() {
            *s = Some(status);
        }
        waiter_done.cv.notify_all();
        sink(Out::Exited(status));
    });
    Ok(Supervised {
        pid,
        stdin: Mutex::new(stdin),
        done,
    })
}

#[cfg(unix)]
fn own_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(windows)]
fn own_group(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    // CREATE_NEW_PROCESS_GROUP
    command.creation_flags(0x0000_0200);
}

fn pump(
    source: impl Read + Send + 'static,
    err: bool,
    sink: &Arc<dyn Fn(Out) + Send + Sync>,
    finished: Sender<()>,
) {
    let sink = Arc::clone(sink);
    thread::spawn(move || {
        let mut reader = BufReader::new(source);
        let mut buf = vec![];
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    while matches!(buf.last(), Some(b'\n' | b'\r')) {
                        buf.pop();
                    }
                    sink(Out::Line {
                        text: String::from_utf8_lossy(&buf).into_owned(),
                        err,
                    });
                }
            }
        }
        let _ = finished.send(());
    });
}

// --- a step in the foreground -----------------------------------------------------------------

enum Fg {
    Exit(io::Result<ExitStatus>),
    Signal,
}

/// Runs `command` with fsp's own stdio and in fsp's own group, and waits for it. A signal to fsp
/// reaches a child on the terminal by itself (Ctrl-C), so fsp keeps waiting; it asks the child to
/// stop (SIGTERM) when it has not ended 5 s later, and kills it 5 s after that or at a second
/// signal. The returned flag says a signal arrived.
pub fn run_foreground(mut command: Command) -> io::Result<(Status, bool)> {
    let signals = subscribe();
    let mut child: Child = command.spawn()?;
    let pid = child.id();
    let (tx, rx) = mpsc::channel::<Fg>();
    let waiter = tx.clone();
    thread::spawn(move || {
        let _ = waiter.send(Fg::Exit(child.wait()));
    });
    thread::spawn(move || {
        for () in signals {
            if tx.send(Fg::Signal).is_err() {
                break;
            }
        }
    });
    let mut asked: Option<Instant> = None;
    let mut termed = false;
    let mut interrupted = false;
    loop {
        let wait = match asked {
            Some(at) if !termed => Duration::from_secs(5).saturating_sub(at.elapsed()),
            Some(at) => Duration::from_secs(10).saturating_sub(at.elapsed()),
            None => Duration::from_secs(3600),
        };
        match rx.recv_timeout(wait) {
            Ok(Fg::Exit(status)) => return status.map(|s| (Status::of(s), interrupted)),
            Ok(Fg::Signal) => {
                interrupted = true;
                if asked.is_some() {
                    stop_pid(pid, true);
                } else {
                    asked = Some(Instant::now());
                }
            }
            Err(_) => {
                if asked.is_some() {
                    if termed {
                        stop_pid(pid, true);
                    } else {
                        termed = true;
                        stop_pid(pid, false);
                    }
                }
            }
        }
    }
}

// --- plain output -----------------------------------------------------------------------------

/// The colours of the prefixes, by pane number.
const PREFIX_COLORS: [u8; 5] = [36, 35, 33, 34, 32];

/// Whether prefixes are coloured: stderr is a terminal and `NO_COLOR` is not set.
#[must_use]
pub fn color_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none_or(|v| v.is_empty()) && io::stderr().is_terminal()
}

/// `[name] text`, the prefix coloured by `index` when `color`.
#[must_use]
pub fn prefixed(name: &str, index: usize, text: &str, color: bool) -> String {
    if color {
        let c = PREFIX_COLORS[index % PREFIX_COLORS.len()];
        format!("\x1b[{c}m[{name}]\x1b[0m {text}")
    } else {
        format!("[{name}] {text}")
    }
}

/// Writes one line to stderr with one `write_all`, so lines from threads never interleave in the
/// middle of a line.
pub fn write_stderr_line(line: &str) {
    let mut bytes = Vec::with_capacity(line.len() + 1);
    bytes.extend_from_slice(line.as_bytes());
    bytes.push(b'\n');
    let _ = io::stderr().lock().write_all(&bytes);
}

// --- opening a URL ----------------------------------------------------------------------------

#[allow(
    dead_code,
    reason = "the full-screen view opens URLs (the next commit)"
)]
/// Opens `url` in the browser: `open` on macOS, `xdg-open` on Linux, `start` on Windows.
pub fn open_url(url: &str) -> io::Result<()> {
    let mut command = if cfg!(target_os = "macos") {
        let mut c = Command::new("open");
        c.arg(url);
        c
    } else if cfg!(windows) {
        windows_start(url)
    } else {
        let mut c = Command::new("xdg-open");
        c.arg(url);
        c
    };
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(windows)]
#[allow(
    dead_code,
    reason = "the full-screen view opens URLs (the next commit)"
)]
fn windows_start(url: &str) -> Command {
    use std::os::windows::process::CommandExt;
    let mut c = Command::new("cmd");
    c.args(["/d", "/s", "/c"])
        .raw_arg(format!("\"start \"\" \"{}\"\"", url.replace('"', "")));
    c
}

#[cfg(not(windows))]
#[allow(
    dead_code,
    reason = "the full-screen view opens URLs (the next commit)"
)]
fn windows_start(_url: &str) -> Command {
    Command::new("cmd")
}
