//! The full-screen view of `fsp dev` (since 0.9.0): ratatui on crossterm, drawn from a
//! [`DevState`] and nothing else, so a test draws it into a `TestBackend` and compares the buffer.
//!
//! ```text
//!  fespalier dev · shop                                          ● running · debug
//!  Pixel 8 (emulator-5554) · android-arm64     VM service ws://127.0.0.1:52341/aBcD=/ws
//!  DevTools http://127.0.0.1:9100/?uri=ws://127.0.0.1:52341/aBcD=/ws
//!  1 flutter │ 2 fsp │ 3 build_runner •
//!  ──────────────────────────────────────────────────────────────────────────────────
//!  (the selected pane's log)
//!  ──────────────────────────────────────────────────────────────────────────────────
//!  ✓ 14 routes · generated 4 s ago in 3.1 ms · no errors · hot restart ✓ 412 ms
//!  r reload  R restart  d DevTools  o open  t telemetry  1-9/Tab pane  / filter  ? help  q quit
//! ```
//!
//! The terminal is entered by [`TerminalGuard`], whose `Drop` restores it, and ratatui installs a
//! panic hook that restores it too. Mouse capture stays off, so the terminal's own text
//! selection works.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use ratatui::DefaultTerminal;
use ratatui::Frame;
use ratatui::buffer::{Buffer, CellDiffOption};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::dev_state::{DevState, Device, Input, Key, Kind, Overlay, Pane, Phase, Proc};
use crate::plural;

/// Whether `fsp dev` takes the whole screen: not with `--no-tui`, not when stdout or stdin is
/// not a terminal, not with `TERM=dumb`, not in CI.
#[must_use]
pub fn want_tui(
    no_tui: bool,
    env: impl Fn(&str) -> Option<String>,
    stdout_tty: bool,
    stdin_tty: bool,
) -> bool {
    !no_tui
        && stdout_tty
        && stdin_tty
        && env("TERM").as_deref() != Some("dumb")
        && env("CI").is_none_or(|v| v.is_empty())
}

// --- the terminal -------------------------------------------------------------------------------

/// The terminal in raw mode on the alternate screen; dropping it puts it back.
pub struct TerminalGuard {
    terminal: DefaultTerminal,
}

impl TerminalGuard {
    pub fn enter() -> io::Result<TerminalGuard> {
        Ok(TerminalGuard {
            terminal: ratatui::try_init()?,
        })
    }

    pub fn draw(&mut self, state: &DevState, now: Duration, links: bool) -> io::Result<()> {
        self.terminal.draw(|frame| draw(state, now, links, frame))?;
        Ok(())
    }

    /// Columns and rows.
    pub fn size(&self) -> io::Result<(u16, u16)> {
        let s = self.terminal.size()?;
        Ok((s.width, s.height))
    }

    /// Asks which of `devices` to run on; `default` is preselected. `None`: quit.
    pub fn pick(&mut self, devices: &[Device], default: usize) -> io::Result<Option<usize>> {
        let mut picker = Picker::new(devices.len(), default);
        loop {
            self.terminal
                .draw(|frame| draw_picker(devices, &picker, frame))?;
            let Event::Key(key) = event::read()? else {
                continue;
            };
            let Some(key) = key_of(key) else {
                continue;
            };
            match picker.key(key) {
                PickerAction::Choose(i) => return Ok(Some(i)),
                PickerAction::Quit => return Ok(None),
                PickerAction::None => {}
            }
        }
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        ratatui::restore();
    }
}

/// A key press, in the state's own words. Releases (Windows sends them) are not keys.
#[must_use]
pub fn key_of(k: KeyEvent) -> Option<Key> {
    if k.kind == KeyEventKind::Release {
        return None;
    }
    Some(match k.code {
        KeyCode::Char(c) if k.modifiers.contains(KeyModifiers::CONTROL) => Key::Ctrl(c),
        KeyCode::Char(c) => Key::Char(c),
        KeyCode::Enter => Key::Enter,
        KeyCode::Esc => Key::Esc,
        KeyCode::Tab => Key::Tab,
        KeyCode::BackTab => Key::BackTab,
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        KeyCode::Home => Key::Home,
        KeyCode::End => Key::End,
        KeyCode::Backspace => Key::Backspace,
        _ => return None,
    })
}

/// Reads keys and resizes on a thread, as inputs, until `stop` is set. It looks at `stop` every
/// 100 ms, so ending it does not wait for a key.
pub fn spawn_input(tx: Sender<Input>, stop: Arc<AtomicBool>) -> JoinHandle<()> {
    thread::spawn(move || {
        while !stop.load(Ordering::SeqCst) {
            match event::poll(Duration::from_millis(100)) {
                Ok(true) => {}
                Ok(false) => continue,
                Err(_) => break,
            }
            let input = match event::read() {
                Ok(Event::Key(k)) => key_of(k).map(Input::Key),
                Ok(Event::Resize(w, h)) => Some(Input::Resize(w, h)),
                Ok(_) => None,
                Err(_) => break,
            };
            if let Some(input) = input
                && tx.send(input).is_err()
            {
                break;
            }
        }
    })
}

// --- the device picker --------------------------------------------------------------------------

/// What a key did to the picker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PickerAction {
    None,
    Choose(usize),
    Quit,
}

/// A list of devices with a cursor.
#[derive(Debug, Clone)]
pub struct Picker {
    len: usize,
    pub cursor: usize,
}

impl Picker {
    #[must_use]
    pub fn new(len: usize, cursor: usize) -> Picker {
        Picker {
            len,
            cursor: cursor.min(len.saturating_sub(1)),
        }
    }

    pub fn key(&mut self, key: Key) -> PickerAction {
        match key {
            Key::Up | Key::Char('k') => self.cursor = self.cursor.saturating_sub(1),
            Key::Down | Key::Char('j') => self.cursor = (self.cursor + 1).min(self.len - 1),
            Key::Home => self.cursor = 0,
            Key::End => self.cursor = self.len - 1,
            Key::Enter => return PickerAction::Choose(self.cursor),
            Key::Char('q') | Key::Esc | Key::Ctrl('c') => return PickerAction::Quit,
            _ => {}
        }
        PickerAction::None
    }
}

fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let w = width.min(area.width);
    let h = height.min(area.height);
    Rect {
        x: area.x + (area.width - w) / 2,
        y: area.y + (area.height - h) / 2,
        width: w,
        height: h,
    }
}

/// The picker, over a cleared screen.
pub fn draw_picker(devices: &[Device], picker: &Picker, frame: &mut Frame) {
    let area = frame.area();
    frame.render_widget(Clear, area);
    let mut lines = vec![Line::from(Span::styled(
        "more than one device: pick one to run on",
        bold(),
    ))];
    lines.push(Line::default());
    for (i, d) in devices.iter().enumerate() {
        let platform = if d.platform.is_empty() {
            String::new()
        } else {
            format!(" · {}", d.platform)
        };
        let text = format!(" {} ({}){platform} ", d.name, d.id);
        lines.push(Line::from(if i == picker.cursor {
            Span::styled(
                format!("›{text}"),
                Style::new().add_modifier(Modifier::REVERSED),
            )
        } else {
            Span::raw(format!(" {text}"))
        }));
    }
    lines.push(Line::default());
    lines.push(Line::from(Span::styled(
        "↑/↓ choose · Enter run · q quit",
        dim(),
    )));
    let width = lines.iter().map(Line::width).max().unwrap_or(0) as u16 + 4;
    let height = lines.len() as u16 + 2;
    let at = centered(area, width, height);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" fespalier dev ");
    frame.render_widget(Paragraph::new(lines).block(block), at);
}

// --- styles -------------------------------------------------------------------------------------

fn bold() -> Style {
    Style::new().add_modifier(Modifier::BOLD)
}

fn dim() -> Style {
    Style::new().fg(Color::DarkGray)
}

fn red() -> Style {
    Style::new().fg(Color::Red)
}

fn green() -> Style {
    Style::new().fg(Color::Green)
}

fn yellow() -> Style {
    Style::new().fg(Color::Yellow)
}

fn kind_style(kind: Kind) -> Style {
    match kind {
        Kind::Normal => Style::new(),
        Kind::Warn => yellow(),
        Kind::Error => red(),
    }
}

// --- the screen ---------------------------------------------------------------------------------

/// A line with `left` at the left edge and `right` at the right, at least one space between.
fn left_right(left: Vec<Span<'static>>, right: Vec<Span<'static>>, width: usize) -> Line<'static> {
    let lw: usize = left.iter().map(Span::width).sum();
    let rw: usize = right.iter().map(Span::width).sum();
    let mut spans = left;
    if lw + rw < width {
        spans.push(Span::raw(" ".repeat(width - lw - rw)));
        spans.extend(right);
    } else if lw < width {
        spans.push(Span::raw(" "));
    }
    Line::from(spans)
}

/// The state of the app, as the header's right-hand side says it.
fn phase_spans(state: &DevState, with_mode: bool) -> Vec<Span<'static>> {
    let app = &state.app;
    let (text, style) = match state.phase() {
        Phase::Starting => ("◌ starting".to_string(), yellow()),
        Phase::Building => (
            match &app.progress {
                Some(m) => format!("◐ building · {m}"),
                None => "◐ building".to_string(),
            },
            yellow(),
        ),
        Phase::Running => ("● running".to_string(), green()),
        Phase::Reloading => ("↻ reloading".to_string(), Style::new().fg(Color::Cyan)),
        Phase::Restarting => ("↻ restarting".to_string(), Style::new().fg(Color::Cyan)),
        Phase::Stopped(code) => (format!("✗ stopped (exit {code})"), red()),
        Phase::Quitting => ("■ stopped".to_string(), dim()),
    };
    let mut spans = vec![Span::styled(text, style)];
    if with_mode
        && matches!(
            state.phase(),
            Phase::Running | Phase::Reloading | Phase::Restarting
        )
        && let Some(mode) = &app.mode
    {
        spans.push(Span::styled(format!(" · {mode}"), dim()));
    }
    spans
}

/// `Pixel 8 (emulator-5554) · android-arm64`
fn device_text(d: &Device) -> String {
    let who = if d.name == d.id {
        d.id.clone()
    } else {
        format!("{} ({})", d.name, d.id)
    };
    if d.platform.is_empty() {
        who
    } else {
        format!("{who} · {}", d.platform)
    }
}

/// The header: three lines, or one on a small terminal.
fn header(state: &DevState, width: usize, small: bool) -> Vec<Line<'static>> {
    let app = &state.app;
    let title = vec![
        Span::styled("fespalier dev", bold()),
        Span::styled(format!(" · {}", state.name()), bold()),
    ];
    if small {
        let mut spans = vec![
            Span::styled(state.name().to_string(), bold()),
            Span::raw(" · "),
        ];
        spans.extend(phase_spans(state, false));
        if let Some(d) = &app.device {
            spans.push(Span::styled(format!(" · {}", d.name), dim()));
        }
        return vec![Line::from(spans)];
    }
    let device = app
        .device
        .as_ref()
        .map_or_else(|| "waiting for the device".to_string(), device_text);
    let address = match (&app.web_url, &app.ws_uri) {
        (Some(url), _) => format!("web {url}"),
        (None, Some(ws)) => format!("VM service {ws}"),
        (None, None) => String::new(),
    };
    let devtools = match &app.devtools {
        Some(uri) => Line::from(vec![
            Span::styled("DevTools ", dim()),
            Span::raw(uri.clone()),
        ]),
        None => Line::from(Span::styled("DevTools: waiting for the VM service", dim())),
    };
    vec![
        left_right(title, phase_spans(state, true), width),
        left_right(
            vec![Span::raw(device)],
            vec![Span::styled(address, dim())],
            width,
        ),
        devtools,
    ]
}

/// The mark after a tab's name: new lines (`•`), new errors (`!`), a process that ended (`✗` with
/// an error, `■` without).
fn mark(pane: &Pane, is_process: bool) -> Option<Span<'static>> {
    match pane.proc {
        Proc::Exited(s) if !s.success() => Some(Span::styled("✗", red())),
        Proc::Exited(_) if is_process => Some(Span::styled("■", dim())),
        _ if pane.unread_err => Some(Span::styled("!", red())),
        _ if pane.unread => Some(Span::styled("•", yellow())),
        _ => None,
    }
}

fn tabs(state: &DevState, small: bool) -> Line<'static> {
    let panes = state.panes();
    let sel = state.selected();
    if small {
        let mut spans = vec![Span::raw(format!(
            "{}/{} {}",
            sel + 1,
            panes.len(),
            panes[sel].name
        ))];
        if let Some(m) = mark(&panes[sel], sel != 1) {
            spans.push(Span::raw(" "));
            spans.push(m);
        }
        return Line::from(spans);
    }
    let mut spans = vec![];
    for (i, p) in panes.iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(" │ ", dim()));
        }
        let label = format!("{} {}", i + 1, p.name);
        spans.push(if i == sel {
            Span::styled(
                label,
                Style::new().add_modifier(Modifier::REVERSED | Modifier::BOLD),
            )
        } else {
            Span::raw(label)
        });
        if let Some(m) = mark(p, i != 1) {
            spans.push(Span::raw(" "));
            spans.push(m);
        }
    }
    Line::from(spans)
}

/// Display width of a character.
fn char_width(c: char) -> usize {
    if c.is_ascii() {
        usize::from(!c.is_ascii_control())
    } else {
        Span::raw(c.to_string()).width()
    }
}

/// `text` cut into rows of at most `width` columns.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let text = text.replace('\t', "    ");
    let mut rows = vec![];
    let mut row = String::new();
    let mut used = 0;
    for c in text.chars() {
        let w = char_width(c);
        if used + w > width && !row.is_empty() {
            rows.push(std::mem::take(&mut row));
            used = 0;
        }
        row.push(c);
        used += w;
    }
    rows.push(row);
    rows
}

/// The rows of the pane that fit `height`, ending `pane.scroll` lines before its last, and how
/// many lines are below them.
fn body(pane: &Pane, width: usize, height: usize) -> (Vec<Line<'static>>, usize) {
    let lines = pane.visible();
    let below = pane.scroll.min(lines.len().saturating_sub(1));
    let end = lines.len() - below;
    let mut rows: Vec<Line<'static>> = vec![];
    for line in lines[..end].iter().rev() {
        for row in wrap(&line.text, width).into_iter().rev() {
            rows.push(Line::from(Span::styled(row, kind_style(line.kind))));
            if rows.len() == height {
                break;
            }
        }
        if rows.len() == height {
            break;
        }
    }
    rows.reverse();
    (rows, below)
}

/// `4 s ago`, `3 min ago`, `2 h ago`.
fn ago(d: Duration) -> String {
    let s = d.as_secs();
    if s < 60 {
        format!("{s} s ago")
    } else if s < 3600 {
        format!("{} min ago", s / 60)
    } else {
        format!("{} h ago", s / 3600)
    }
}

/// The status line, and where the clickable location is in it: `(column, text, path)`.
fn status(
    state: &DevState,
    now: Duration,
) -> (Line<'static>, Option<(usize, String, std::path::PathBuf)>) {
    if let Some(n) = state.notice(now) {
        return (Line::from(Span::styled(n.to_string(), yellow())), None);
    }
    let g = &state.generation;
    let mut spans: Vec<Span<'static>> = vec![];
    let sep = || Span::styled(" · ", dim());
    if g.errors > 0 {
        spans.push(Span::styled(
            format!("✗ {}", plural(g.errors, "error")),
            red(),
        ));
    } else if let Some(n) = g.routes {
        spans.push(Span::styled(format!("✓ {}", plural(n, "route")), green()));
    } else {
        spans.push(Span::styled("· generating", dim()));
    }
    if let Some(at) = g.at {
        spans.push(sep());
        spans.push(Span::raw(format!(
            "generated {} in {:.1} ms",
            ago(now.saturating_sub(at)),
            g.elapsed.as_secs_f64() * 1000.0
        )));
    }
    let mut link = None;
    match &g.first_error {
        Some(e) if g.errors > 0 => {
            spans.push(sep());
            spans.push(Span::styled(e.message.clone(), red()));
            if let Some(loc) = &e.loc {
                spans.push(sep());
                let column: usize = spans.iter().map(Span::width).sum();
                link = Some((column, loc.text(), loc.path.clone()));
                spans.push(Span::styled(loc.text(), red()));
            }
        }
        _ if g.at.is_some() => {
            spans.push(sep());
            spans.push(Span::raw("no errors"));
        }
        _ => {}
    }
    if let Some(h) = state.last_hot() {
        let what = if h.full { "restart" } else { "reload" };
        spans.push(sep());
        if h.ok {
            spans.push(Span::raw(format!("hot {what} ")));
            spans.push(Span::styled(format!("✓ {} ms", h.ms), green()));
            if !h.message.is_empty() {
                spans.push(Span::raw(format!(" · {}", h.message)));
            }
        } else {
            spans.push(Span::styled(
                format!("hot {what} ✗ {}", h.message.lines().next().unwrap_or("")),
                red(),
            ));
        }
    }
    (Line::from(spans), link)
}

const LEGEND: [(&str, &str); 9] = [
    ("r", "reload"),
    ("R", "restart"),
    ("d", "DevTools"),
    ("o", "open"),
    ("t", "telemetry"),
    ("1-9/Tab", "pane"),
    ("/", "filter"),
    ("?", "help"),
    ("q", "quit"),
];

fn legend(state: &DevState, width: usize) -> Line<'static> {
    let key = |k: &str| Span::styled(k.to_string(), Style::new().fg(Color::Cyan));
    let item = |k: &str, what: &str| vec![key(k), Span::styled(format!(" {what}"), dim())];
    let mut spans: Vec<Span<'static>> = vec![];
    let panes = state.panes();
    if let Some(text) = state.editing() {
        spans.push(key("/"));
        spans.push(Span::raw(format!(" {text}")));
        spans.push(Span::styled(
            " ",
            Style::new().add_modifier(Modifier::REVERSED),
        ));
        spans.push(Span::styled("   Enter keeps it · Esc clears", dim()));
        return Line::from(spans);
    }
    if let Some(f) = &panes[state.selected()].filter {
        spans.push(key("/"));
        spans.push(Span::raw(format!(" {f}")));
        spans.push(Span::styled("  Esc clears  ", dim()));
    }
    let all = width >= 70;
    let shown: &[(&str, &str)] = if all { &LEGEND } else { &LEGEND[7..] };
    for (i, (k, what)) in shown.iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw("  "));
        }
        spans.extend(item(k, what));
    }
    Line::from(spans)
}

const HELP: [(&str, &str); 13] = [
    ("r", "hot reload"),
    ("R", "hot restart (runs flutter again when it stopped)"),
    ("d", "open DevTools"),
    ("o", "open the app in the browser (web)"),
    ("t", "start fsp telemetry in a pane"),
    ("Tab, 1-9", "switch panes"),
    ("↑ ↓ PgUp PgDn Home", "scroll the pane"),
    ("End, G", "follow the end of the log"),
    ("/", "filter the pane (Enter keeps it)"),
    ("Esc", "clear the filter"),
    ("c", "clear the pane"),
    ("?", "this help; any key closes it"),
    ("q, Ctrl-C", "quit; again to kill everything"),
];

fn rule(width: usize) -> Line<'static> {
    Line::from(Span::styled("─".repeat(width), dim()))
}

/// The bottom rule, with `↑ N lines below` at its right end while the pane is scrolled up.
fn bottom_rule(width: usize, below: usize) -> Line<'static> {
    if below == 0 {
        return rule(width);
    }
    let label = format!(" ↑ {} below ", plural(below, "line"));
    let w = label.chars().count();
    if w + 2 > width {
        return rule(width);
    }
    Line::from(vec![
        Span::styled("─".repeat(width - w - 2), dim()),
        Span::styled(label, yellow().add_modifier(Modifier::REVERSED)),
        Span::styled("──", dim()),
    ])
}

/// Draws the screen for `state` at time `now` (the state's clock). `links`: write the location of
/// the first error as an OSC 8 hyperlink.
pub fn draw(state: &DevState, now: Duration, links: bool, frame: &mut Frame) {
    let area = frame.area();
    // One column of margin on each side, when there is room for it.
    let margin = u16::from(area.width > 2);
    let inner = Rect {
        x: area.x + margin,
        y: area.y,
        width: area.width - 2 * margin,
        height: area.height,
    };
    let width = usize::from(inner.width);
    let small = area.width < 60 || area.height < 12;
    let head = header(state, width, small);
    let [h, t, r1, b, r2, s, l] = Layout::vertical([
        Constraint::Length(head.len() as u16),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(inner);
    let pane = &state.panes()[state.selected()];
    let (rows, below) = body(pane, width, usize::from(b.height));
    let (status_line, link) = status(state, now);
    frame.render_widget(Paragraph::new(head), h);
    frame.render_widget(Paragraph::new(tabs(state, small)), t);
    frame.render_widget(Paragraph::new(rule(width)), r1);
    frame.render_widget(Paragraph::new(rows), b);
    frame.render_widget(Paragraph::new(bottom_rule(width, below)), r2);
    frame.render_widget(Paragraph::new(status_line), s);
    frame.render_widget(Paragraph::new(legend(state, area.width.into())), l);
    if links
        && state.notice(now).is_none()
        && let Some((column, text, path)) = link
        && column + text.chars().count() <= width
    {
        let x = s.x + column as u16;
        link_cells(
            frame.buffer_mut(),
            x,
            s.y,
            &text,
            &crate::osc8::file_url(&path),
        );
    }
    if state.overlay() == Overlay::Help {
        let at = centered(area, 72, HELP.len() as u16 + 2);
        frame.render_widget(Clear, at);
        let lines: Vec<Line<'static>> = HELP
            .iter()
            .map(|(k, what)| {
                Line::from(vec![
                    Span::styled(format!(" {k:<20}"), Style::new().fg(Color::Cyan)),
                    Span::raw((*what).to_string()),
                ])
            })
            .collect();
        frame.render_widget(
            Paragraph::new(lines).block(Block::default().borders(Borders::ALL).title(" keys ")),
            at,
        );
    }
}

/// Turns the cells under `text` into an OSC 8 hyperlink to `url`. Ratatui's buffer has no
/// hyperlink cell, so (as in its own `hyperlink` example) each pair of characters becomes one
/// cell's symbol, wrapped in the escape sequences, and the cell after it is skipped.
pub fn link_cells(buf: &mut Buffer, x: u16, y: u16, text: &str, url: &str) {
    let chars: Vec<char> = text.chars().collect();
    for (i, pair) in chars.chunks(2).enumerate() {
        let at = x + (i * 2) as u16;
        let chunk: String = pair.iter().collect();
        buf[(at, y)].set_symbol(&crate::osc8::link(url, &chunk));
        if pair.len() == 2 {
            buf[(at + 1, y)].set_diff_option(CellDiffOption::Skip);
        }
    }
}

/// The last `n` lines of the panes worth showing after the view closes: flutter's, and any pane
/// whose last lines hold an error. `[name] text`, so a crash stays on screen.
#[must_use]
pub fn tail(state: &DevState, n: usize) -> Vec<String> {
    let mut out = vec![];
    for (i, p) in state.panes().iter().enumerate() {
        let last: Vec<_> = p.lines.iter().rev().take(n).collect();
        let worth = i == 0 || last.iter().any(|l| l.kind == Kind::Error);
        if !worth || last.is_empty() {
            continue;
        }
        out.extend(
            last.iter()
                .rev()
                .map(|l| crate::procs::prefixed(&p.name, i, &l.text, false)),
        );
    }
    out
}
