//! The full-screen view of `fsp dev`, drawn into a `TestBackend`: golden screens (the text, and a
//! sidecar of the styled runs, so colours are pinned too), the pieces (marks, wrapping, scrolling,
//! links, the picker), and the README screenshot, an SVG made from the same buffer.
//!
//! The goldens are in `tests/golden/dev-tui/`; `FSP_UPDATE_GOLDEN=1 cargo test dev_tui_tests::`
//! rewrites them and `docs/images/fsp-dev.svg`.

use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::{Buffer, CellDiffOption};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};
use ratatui::style::{Color, Modifier};

use crate::daemon::{self, Line};
use crate::dev_state::{
    DevState, Device, Effect, FLUTTER, FSP, Input, Key, Kind, Opts, Pick, pick_device,
};
use crate::dev_tui::{Picker, PickerAction, draw, draw_picker, key_of, link_cells, tail, want_tui};
use crate::diag::Loc;
use crate::procs::Status;
use crate::watch::{FirstError, GenReport};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

// --- scenes ------------------------------------------------------------------------------------

fn daemon_input(json: &str) -> Input {
    let Line::Messages(mut m) = daemon::parse_line(json) else {
        panic!("not a message: {json}");
    };
    Input::Daemon(m.remove(0))
}

fn pixel() -> Device {
    Device {
        id: "emulator-5554".into(),
        name: "Pixel 8".into(),
        platform: "android-arm64".into(),
    }
}

fn chrome() -> Device {
    Device {
        id: "chrome".into(),
        name: "Chrome".into(),
        platform: "web-javascript".into(),
    }
}

/// A new state for the app `shop`, with a `build_runner` pane, flutter and that pane started.
fn fresh(device: Device, width: u16, height: u16) -> DevState {
    let mut s = DevState::new(Opts {
        name: "shop".into(),
        with: vec!["build_runner".into()],
        hot_reload: true,
        plain: false,
        output: "lib/app.g.dart".into(),
        device: Some(device),
    });
    s.started(FLUTTER);
    s.started(2);
    s.update(ms(0), Input::Resize(width, height));
    s
}

fn say(s: &mut DevState, now: u64, pane: usize, text: &str) {
    s.update(
        ms(now),
        Input::Line {
            pane,
            text: text.into(),
            err: false,
        },
    );
}

fn start_app(s: &mut DevState, device_id: &str) {
    s.update(
        ms(1),
        daemon_input(r#"[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]"#),
    );
    s.update(
        ms(2),
        daemon_input(&format!(
            r#"[{{"event":"app.start","params":{{"appId":"a1","deviceId":"{device_id}","supportsRestart":true,"mode":"debug"}}}}]"#
        )),
    );
}

fn report(wrote: bool, errors: usize, first_error: Option<FirstError>) -> GenReport {
    GenReport {
        first: false,
        ok: errors == 0,
        wrote,
        routes: (errors == 0).then_some(14),
        errors,
        first_error,
        elapsed: Duration::from_micros(3100),
        quiet: false,
        line: Some("✓ 14 routes → lib/app.g.dart (3.1ms)".into()),
    }
}

/// The screen of README: the Android app is up, a regeneration restarted it 4 s ago.
fn running() -> DevState {
    let mut s = fresh(pixel(), 100, 30);
    start_app(&mut s, "emulator-5554");
    say(
        &mut s,
        3,
        FLUTTER,
        "Launching lib/main.dart on Pixel 8 in debug mode...",
    );
    say(&mut s, 4, FLUTTER, "Running Gradle task 'assembleDebug'...");
    say(
        &mut s,
        5,
        FLUTTER,
        "✓ Built build/app/outputs/flutter-apk/app-debug.apk",
    );
    say(
        &mut s,
        5,
        FLUTTER,
        "Installing build/app/outputs/flutter-apk/app-debug.apk...",
    );
    say(&mut s, 5, FLUTTER, "Syncing files to device Pixel 8...");
    s.update(
        ms(6),
        daemon_input(
            r#"[{"event":"app.debugPort","params":{"appId":"a1","port":52341,"wsUri":"ws://127.0.0.1:52341/aBcD=/ws"}}]"#,
        ),
    );
    s.update(
        ms(7),
        daemon_input(
            r#"[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:9100/?uri=ws://127.0.0.1:52341/aBcD=/ws"}}]"#,
        ),
    );
    s.update(
        ms(8),
        daemon_input(r#"[{"event":"app.started","params":{"appId":"a1"}}]"#),
    );
    s.update(
        ms(9),
        daemon_input(
            r#"[{"event":"app.log","params":{"appId":"a1","log":"I/flutter ( 4242): signed in as ada"}}]"#,
        ),
    );
    for log in [
        "I/flutter ( 4242): GET /api/products 200 (84 ms)",
        "I/flutter ( 4242): GET /api/cart 200 (31 ms)",
    ] {
        say(&mut s, 9, FLUTTER, log);
    }
    // A build_runner line the view is not showing: the tab gets a mark.
    say(&mut s, 10, 2, "[INFO] Succeeded after 3.2s with 12 outputs");
    // A regeneration that wrote restarts the app, and flutter says it took 412 ms.
    s.update(ms(10_000), Input::Gen(report(true, 0, None)));
    say(&mut s, 10_001, FLUTTER, "Performing hot restart...");
    s.update(
        ms(10_412),
        daemon_input(
            r#"[{"id":1,"result":{"code":0,"message":"Restarted application in 412ms."}}]"#,
        ),
    );
    say(&mut s, 10_413, FLUTTER, "Restarted application in 412ms.");
    say(
        &mut s,
        10_414,
        FLUTTER,
        "I/flutter ( 4242): signed in as ada",
    );
    s
}

fn running_web() -> DevState {
    let mut s = fresh(chrome(), 100, 30);
    start_app(&mut s, "chrome");
    say(
        &mut s,
        3,
        FLUTTER,
        "Launching lib/main.dart on Chrome in debug mode...",
    );
    s.update(
        ms(4),
        daemon_input(
            r#"[{"event":"app.webLaunchUrl","params":{"url":"http://localhost:54321","launched":true}}]"#,
        ),
    );
    s.update(
        ms(5),
        daemon_input(
            r#"[{"event":"app.debugPort","params":{"appId":"a1","port":1,"wsUri":"ws://127.0.0.1:1/x=/ws"}}]"#,
        ),
    );
    s.update(
        ms(6),
        daemon_input(
            r#"[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:9100/?uri=ws://127.0.0.1:1/x=/ws"}}]"#,
        ),
    );
    s.update(
        ms(7),
        daemon_input(r#"[{"event":"app.started","params":{"appId":"a1"}}]"#),
    );
    s.update(ms(2_000), Input::Gen(report(false, 0, None)));
    s.update(
        ms(2_100),
        daemon_input(r#"[{"id":1,"result":{"code":0,"message":"Reloaded 3 of 512 libraries"}}]"#),
    );
    s
}

fn failing(loc: bool) -> DevState {
    let mut s = running();
    s.update(
        ms(13_000),
        Input::Gen(report(
            false,
            1,
            Some(FirstError {
                message: "`x` is not a segment of this path".into(),
                loc: loc.then(|| Loc {
                    file: "lib/app/products/$id/page.dart".into(),
                    path: PathBuf::from("/work/shop/lib/app/products/$id/page.dart"),
                    line: 6,
                    column: 18,
                }),
            }),
        )),
    );
    s
}

// --- the buffer as text ------------------------------------------------------------------------

fn render(state: &DevState, now: u64, width: u16, height: u16, links: bool) -> Buffer {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
    terminal
        .draw(|frame| draw(state, ms(now), links, frame))
        .unwrap();
    terminal.backend().buffer().clone()
}

fn text_of(buf: &Buffer) -> String {
    let mut out = String::new();
    for y in 0..buf.area.height {
        let mut line = String::new();
        for x in 0..buf.area.width {
            line.push_str(buf[(x, y)].symbol());
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

/// The cells with a style of their own, in runs: row, columns, colours, modifiers, text.
fn styles_of(buf: &Buffer) -> String {
    let mut out = String::new();
    for y in 0..buf.area.height {
        let mut x = 0;
        while x < buf.area.width {
            let c = &buf[(x, y)];
            let style = (c.fg, c.bg, c.modifier);
            if style == (Color::Reset, Color::Reset, Modifier::empty()) {
                x += 1;
                continue;
            }
            let start = x;
            let mut text = String::new();
            while x < buf.area.width && {
                let n = &buf[(x, y)];
                (n.fg, n.bg, n.modifier) == style
            } {
                text.push_str(buf[(x, y)].symbol());
                x += 1;
            }
            let _ = writeln!(
                out,
                "{y:02} {start:03}..{x:03} fg={:?} bg={:?} mods={:?} {text:?}",
                style.0, style.1, style.2
            );
        }
    }
    out
}

fn golden_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/dev-tui")
}

fn updating() -> bool {
    std::env::var_os("FSP_UPDATE_GOLDEN").is_some()
}

/// Compares `got` with the golden file `name`; with `FSP_UPDATE_GOLDEN` it writes it instead.
fn golden_file(name: &str, got: &str) {
    let path = golden_dir().join(name);
    if updating() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, got).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        got,
        want,
        "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test dev_tui_tests::` in cli/",
        path.display()
    );
}

fn golden(name: &str, buf: &Buffer) {
    golden_file(&format!("{name}.txt"), &text_of(buf));
    golden_file(&format!("{name}.styles.txt"), &styles_of(buf));
}

#[test]
fn golden_starting() {
    let s = fresh(pixel(), 100, 30);
    golden("starting", &render(&s, 500, 100, 30, false));
}

#[test]
fn golden_building_with_a_progress_message() {
    let mut s = fresh(pixel(), 100, 30);
    start_app(&mut s, "emulator-5554");
    s.update(
        ms(3),
        daemon_input(
            r#"[{"event":"app.progress","params":{"appId":"a1","id":"1","message":"Running Gradle task 'assembleDebug'...","finished":false}}]"#,
        ),
    );
    golden("building", &render(&s, 900, 100, 30, false));
}

#[test]
fn golden_running() {
    golden("running", &render(&running(), 14_000, 100, 30, false));
}

#[test]
fn golden_running_on_the_web() {
    golden(
        "running-web",
        &render(&running_web(), 6_000, 100, 30, false),
    );
}

#[test]
fn golden_errors() {
    golden("errors", &render(&failing(true), 14_000, 100, 30, false));
}

#[test]
fn golden_help() {
    let mut s = running();
    s.update(ms(14_000), Input::Key(Key::Char('?')));
    golden("help", &render(&s, 14_000, 100, 30, false));
}

#[test]
fn golden_picker() {
    let devices = vec![
        Device {
            id: "macos".into(),
            name: "macOS".into(),
            platform: "darwin".into(),
        },
        chrome(),
        Device {
            id: "ios-1".into(),
            name: "iPhone 15".into(),
            platform: "ios".into(),
        },
    ];
    let mut picker = Picker::new(devices.len(), 0);
    picker.key(Key::Down);
    let mut terminal = Terminal::new(TestBackend::new(100, 30)).unwrap();
    terminal
        .draw(|frame| draw_picker(&devices, &picker, frame))
        .unwrap();
    golden("picker", terminal.backend().buffer());
}

#[test]
fn golden_filter() {
    let mut s = running();
    for line in [
        "Resolving dependencies...",
        "gradle: configuring project :app",
        "Running Gradle task 'assembleDebug'...",
        "E/flutter: unrelated",
    ] {
        say(&mut s, 11, FLUTTER, line);
    }
    for k in [
        Key::Char('/'),
        Key::Char('G'),
        Key::Char('r'),
        Key::Char('a'),
        Key::Char('d'),
        Key::Char('l'),
        Key::Char('e'),
        Key::Enter,
    ] {
        s.update(ms(12), Input::Key(k));
    }
    golden("filter", &render(&s, 14_000, 100, 30, false));
}

#[test]
fn golden_a_small_terminal() {
    let mut s = fresh(pixel(), 60, 16);
    start_app(&mut s, "emulator-5554");
    for i in 1..=14 {
        say(&mut s, 3, FLUTTER, &format!("log line {i}"));
    }
    s.update(
        ms(8),
        daemon_input(r#"[{"event":"app.started","params":{"appId":"a1"}}]"#),
    );
    s.update(ms(1_000), Input::Gen(report(false, 0, None)));
    golden("small", &render(&s, 3_000, 60, 16, false));
}

// --- the pieces --------------------------------------------------------------------------------

#[test]
fn the_view_is_the_full_screen_only_on_a_terminal() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |k: &str| {
            pairs
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| (*v).to_string())
        }
    };
    assert!(want_tui(
        false,
        env(&[("TERM", "xterm-256color")]),
        true,
        true
    ));
    assert!(want_tui(false, env(&[]), true, true));
    assert!(!want_tui(true, env(&[]), true, true), "--no-tui");
    assert!(
        !want_tui(false, env(&[]), false, true),
        "stdout is not a terminal"
    );
    assert!(
        !want_tui(false, env(&[]), true, false),
        "stdin is not a terminal"
    );
    assert!(!want_tui(false, env(&[("TERM", "dumb")]), true, true));
    assert!(!want_tui(false, env(&[("CI", "true")]), true, true));
    // An empty CI is not CI.
    assert!(want_tui(false, env(&[("CI", "")]), true, true));
}

fn press(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent {
        code,
        modifiers,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    }
}

#[test]
fn terminal_keys_become_the_states_keys() {
    let none = KeyModifiers::NONE;
    assert_eq!(
        key_of(press(KeyCode::Char('r'), none)),
        Some(Key::Char('r'))
    );
    assert_eq!(
        key_of(press(KeyCode::Char('R'), KeyModifiers::SHIFT)),
        Some(Key::Char('R'))
    );
    assert_eq!(
        key_of(press(KeyCode::Char('c'), KeyModifiers::CONTROL)),
        Some(Key::Ctrl('c'))
    );
    assert_eq!(key_of(press(KeyCode::Tab, none)), Some(Key::Tab));
    assert_eq!(
        key_of(press(KeyCode::BackTab, KeyModifiers::SHIFT)),
        Some(Key::BackTab)
    );
    assert_eq!(key_of(press(KeyCode::PageUp, none)), Some(Key::PageUp));
    assert_eq!(key_of(press(KeyCode::F(5), none)), None);
    // A release (Windows sends them) is not a key.
    let mut release = press(KeyCode::Char('q'), none);
    release.kind = KeyEventKind::Release;
    assert_eq!(key_of(release), None);
}

#[test]
fn the_picker_moves_chooses_and_quits() {
    let mut p = Picker::new(3, 1);
    assert_eq!(p.key(Key::Up), PickerAction::None);
    assert_eq!(p.cursor, 0);
    assert_eq!(p.key(Key::Up), PickerAction::None);
    assert_eq!(p.cursor, 0, "it stops at the top");
    p.key(Key::Char('j'));
    p.key(Key::Down);
    p.key(Key::Down);
    assert_eq!(p.cursor, 2, "and at the bottom");
    assert_eq!(p.key(Key::Enter), PickerAction::Choose(2));
    assert_eq!(p.key(Key::Char('q')), PickerAction::Quit);
    assert_eq!(p.key(Key::Esc), PickerAction::Quit);
    assert_eq!(p.key(Key::Ctrl('c')), PickerAction::Quit);
    // A remembered choice that is no longer listed does not point past the end.
    assert_eq!(Picker::new(2, 9).cursor, 1);
}

#[test]
fn the_phase_is_in_the_header() {
    let header = |s: &DevState| {
        text_of(&render(s, 500, 100, 30, false))
            .lines()
            .next()
            .unwrap()
            .to_string()
    };
    let mut s = fresh(pixel(), 100, 30);
    assert!(header(&s).ends_with("◌ starting"), "{}", header(&s));
    start_app(&mut s, "emulator-5554");
    assert!(header(&s).ends_with("◐ building"));
    s.update(
        ms(3),
        daemon_input(r#"[{"event":"app.started","params":{"appId":"a1"}}]"#),
    );
    assert!(header(&s).ends_with("● running · debug"));
    s.update(ms(4), Input::Key(Key::Char('r')));
    assert!(header(&s).ends_with("↻ reloading · debug"));
    s.update(ms(5), Input::Key(Key::Char('R')));
    assert!(header(&s).ends_with("↻ restarting · debug"));
    s.update(ms(6), Input::Key(Key::Char('q')));
    assert!(header(&s).ends_with("■ stopped"));
    let mut s = fresh(pixel(), 100, 30);
    s.update(
        ms(3),
        Input::Exited {
            pane: FLUTTER,
            status: Status {
                code: 1,
                signal: None,
            },
        },
    );
    assert!(header(&s).ends_with("✗ stopped (exit 1)"), "{}", header(&s));
}

#[test]
fn tabs_get_marks_for_new_lines_new_errors_and_exits() {
    let tabs = |s: &DevState| {
        text_of(&render(s, 500, 100, 30, false))
            .lines()
            .nth(3)
            .unwrap()
            .to_string()
    };
    let mut s = fresh(pixel(), 100, 30);
    assert_eq!(tabs(&s), " 1 flutter │ 2 fsp │ 3 build_runner");
    say(&mut s, 1, 2, "something");
    assert_eq!(tabs(&s), " 1 flutter │ 2 fsp │ 3 build_runner •");
    s.update(
        ms(2),
        Input::Line {
            pane: 2,
            text: "boom".into(),
            err: true,
        },
    );
    assert_eq!(tabs(&s), " 1 flutter │ 2 fsp │ 3 build_runner !");
    // Showing the pane reads it.
    s.update(ms(3), Input::Key(Key::Char('3')));
    assert_eq!(tabs(&s), " 1 flutter │ 2 fsp │ 3 build_runner");
    // A process that ended: with an error, or cleanly.
    s.update(
        ms(4),
        Input::Exited {
            pane: 2,
            status: Status {
                code: 2,
                signal: None,
            },
        },
    );
    assert!(tabs(&s).ends_with("3 build_runner ✗"), "{}", tabs(&s));
    s.update(
        ms(5),
        Input::Exited {
            pane: FLUTTER,
            status: Status {
                code: 0,
                signal: None,
            },
        },
    );
    assert!(tabs(&s).starts_with(" 1 flutter ■ │"), "{}", tabs(&s));
}

#[test]
fn a_small_terminal_has_a_one_line_header_and_one_tab() {
    let buf = render(&running(), 14_000, 59, 20, false);
    let text = text_of(&buf);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], " shop · ● running · Pixel 8");
    assert_eq!(lines[1], " 1/3 flutter");
}

#[test]
fn long_lines_wrap_to_the_width_and_the_end_of_the_log_shows() {
    let mut s = fresh(pixel(), 40, 14);
    start_app(&mut s, "emulator-5554");
    say(&mut s, 3, FLUTTER, &"abcdefghij".repeat(7));
    say(&mut s, 4, FLUTTER, "last line");
    let text = text_of(&render(&s, 100, 40, 14, false));
    let lines: Vec<&str> = text.lines().collect();
    let at = lines.iter().position(|l| l.contains("last line")).unwrap();
    assert_eq!(
        lines[at - 1],
        format!(" {}", "abcdefghij".repeat(7).split_at(38).1)
    );
    assert_eq!(
        lines[at - 2],
        format!(" {}", "abcdefghij".repeat(7).split_at(38).0)
    );
}

#[test]
fn scrolling_up_leaves_the_end_and_says_how_many_lines_are_below() {
    let mut s = fresh(pixel(), 100, 20);
    for i in 1..=60 {
        say(&mut s, 3, FLUTTER, &format!("line {i}"));
    }
    let text = text_of(&render(&s, 100, 100, 20, false));
    assert!(
        text.contains("line 60") && !text.contains("below"),
        "{text}"
    );
    for _ in 0..5 {
        s.update(ms(5), Input::Key(Key::Up));
    }
    let text = text_of(&render(&s, 100, 100, 20, false));
    assert!(!text.contains("line 60"), "{text}");
    assert!(text.contains("line 55"), "{text}");
    assert!(text.contains("↑ 5 lines below"), "{text}");
    // New lines arrive below without moving what is shown.
    say(&mut s, 6, FLUTTER, "line 61");
    let text = text_of(&render(&s, 100, 100, 20, false));
    assert!(
        text.contains("line 55") && text.contains("↑ 6 lines below"),
        "{text}"
    );
    // End follows the log again.
    s.update(ms(7), Input::Key(Key::End));
    let text = text_of(&render(&s, 100, 100, 20, false));
    assert!(
        text.contains("line 61") && !text.contains("below"),
        "{text}"
    );
    // Home goes to the first line, and no further.
    s.update(ms(8), Input::Key(Key::Home));
    s.update(ms(9), Input::Key(Key::Up));
    let text = text_of(&render(&s, 100, 100, 20, false));
    assert!(
        text.contains("line 1\n") || text.contains("line 1 "),
        "{text}"
    );
    assert!(text.contains("↑ 60 lines below"), "{text}");
}

#[test]
fn the_filter_keeps_the_lines_with_the_text_in_any_case() {
    let mut s = fresh(pixel(), 100, 30);
    for line in ["Alpha one", "beta two", "ALPHA three"] {
        say(&mut s, 1, FLUTTER, line);
    }
    for k in [
        Key::Char('/'),
        Key::Char('a'),
        Key::Char('l'),
        Key::Char('p'),
        Key::Enter,
    ] {
        s.update(ms(2), Input::Key(k));
    }
    let text = text_of(&render(&s, 100, 100, 30, false));
    assert!(
        text.contains("Alpha one") && text.contains("ALPHA three"),
        "{text}"
    );
    assert!(!text.contains("beta two"), "{text}");
    assert!(text.contains("/ alp  Esc clears"), "{text}");
    // Esc clears it.
    s.update(ms(3), Input::Key(Key::Esc));
    let text = text_of(&render(&s, 100, 100, 30, false));
    assert!(
        text.contains("beta two") && !text.contains("Esc clears"),
        "{text}"
    );
    // While typing, the legend row is the prompt, with a cursor.
    s.update(ms(4), Input::Key(Key::Char('/')));
    s.update(ms(5), Input::Key(Key::Char('x')));
    let text = text_of(&render(&s, 100, 100, 30, false));
    assert!(text.contains("/ x"), "{text}");
    assert!(text.contains("Enter keeps it · Esc clears"), "{text}");
    // Esc while typing drops what was typed.
    s.update(ms(6), Input::Key(Key::Esc));
    assert!(s.editing().is_none());
    assert!(s.panes()[FLUTTER].filter.is_none());
}

#[test]
fn the_status_line_shows_the_error_and_the_location() {
    let text = text_of(&render(&failing(true), 14_000, 140, 30, false));
    let status = text.lines().nth(28).unwrap();
    assert_eq!(
        status,
        " ✗ 1 error · generated 1 s ago in 3.1 ms · `x` is not a segment of this path · lib/app/products/$id/page.dart:6:18 · hot restart ✓ 412 ms"
    );
    // A diagnostic with no place has no location.
    let text = text_of(&render(&failing(false), 14_000, 120, 30, false));
    assert!(!text.contains("page.dart:6:18"));
}

#[test]
fn the_location_is_a_link_when_links_are_on() {
    let buf = render(&failing(true), 14_000, 140, 30, true);
    let y = 28;
    let all: String = (0..buf.area.width)
        .map(|x| buf[(x, y)].symbol().to_string())
        .collect();
    let url = "file:///work/shop/lib/app/products/%24id/page.dart";
    assert!(
        all.contains(&format!("\x1b]8;;{url}\x1b\\li\x1b]8;;\x1b\\")),
        "{all:?}"
    );
    // Without links there is no escape in the buffer.
    let buf = render(&failing(true), 14_000, 140, 30, false);
    let all: String = (0..buf.area.width)
        .map(|x| buf[(x, y)].symbol().to_string())
        .collect();
    assert!(!all.contains('\x1b'));
}

#[test]
fn a_link_is_pairs_of_characters_wrapped_in_the_escape_with_the_second_cell_skipped() {
    let mut buf = Buffer::empty(ratatui::layout::Rect::new(0, 0, 10, 1));
    link_cells(&mut buf, 2, 0, "abc", "file:///x");
    assert_eq!(
        buf[(2, 0)].symbol(),
        "\x1b]8;;file:///x\x1b\\ab\x1b]8;;\x1b\\"
    );
    assert_eq!(buf[(3, 0)].diff_option, CellDiffOption::Skip);
    assert_eq!(
        buf[(4, 0)].symbol(),
        "\x1b]8;;file:///x\x1b\\c\x1b]8;;\x1b\\"
    );
    assert_eq!(
        buf[(5, 0)].diff_option,
        CellDiffOption::None,
        "an odd tail has no partner"
    );
    assert_eq!(buf[(1, 0)].symbol(), " ", "cells before it are untouched");
}

#[test]
fn a_notice_replaces_the_status_for_a_while() {
    let mut s = running();
    s.update(
        ms(14_000),
        Input::Notice("could not open http://x: no browser".into()),
    );
    let status = |now: u64| {
        text_of(&render(&s, now, 100, 30, false))
            .lines()
            .nth(28)
            .unwrap()
            .to_string()
    };
    assert_eq!(status(14_001), " could not open http://x: no browser");
    assert!(
        status(22_001).starts_with(" ✓ 14 routes"),
        "{}",
        status(22_001)
    );
}

#[test]
fn the_legend_shortens_on_a_narrow_terminal() {
    let text = text_of(&render(&running(), 14_000, 66, 30, false));
    assert_eq!(text.lines().nth(29).unwrap(), " ? help  q quit");
}

#[test]
fn keys_that_open_things_ask_for_them() {
    let mut s = running_web();
    assert_eq!(
        s.update(ms(3_000), Input::Key(Key::Char('d'))),
        [Effect::Open(
            "http://127.0.0.1:9100/?uri=ws://127.0.0.1:1/x=/ws".into()
        )]
    );
    assert_eq!(
        s.update(ms(3_000), Input::Key(Key::Char('o'))),
        [Effect::Open("http://localhost:54321".into())]
    );
    // Not on the web: a notice says where the app runs.
    let mut s = running();
    assert!(s.update(ms(14_000), Input::Key(Key::Char('o'))).is_empty());
    assert_eq!(
        s.notice(ms(14_001)),
        Some("no web URL: the app runs on Pixel 8")
    );
    let mut s = fresh(pixel(), 100, 30);
    assert!(s.update(ms(1), Input::Key(Key::Char('d'))).is_empty());
    assert_eq!(s.notice(ms(2)), Some("no DevTools URL yet"));
}

#[test]
fn t_starts_telemetry_once_and_then_switches_to_its_pane() {
    let mut s = running();
    let fx = s.update(ms(14_000), Input::Key(Key::Char('t')));
    assert_eq!(fx, [Effect::StartTelemetry(3)]);
    assert_eq!(s.panes()[3].name, "telemetry");
    assert_eq!(s.selected(), 3);
    s.update(ms(14_001), Input::Key(Key::Char('1')));
    assert_eq!(s.selected(), 0);
    assert!(s.update(ms(14_002), Input::Key(Key::Char('t'))).is_empty());
    assert_eq!(s.selected(), 3);
}

#[test]
fn tab_and_the_digits_switch_panes() {
    let mut s = running();
    s.update(ms(1), Input::Key(Key::Tab));
    assert_eq!(s.selected(), 1);
    s.update(ms(2), Input::Key(Key::Tab));
    s.update(ms(3), Input::Key(Key::Tab));
    assert_eq!(s.selected(), 0, "it wraps");
    s.update(ms(4), Input::Key(Key::BackTab));
    assert_eq!(s.selected(), 2);
    s.update(ms(5), Input::Key(Key::Char('9')));
    assert_eq!(s.selected(), 2, "there is no ninth pane");
    s.update(ms(6), Input::Key(Key::Char('2')));
    assert_eq!(s.selected(), 1);
}

#[test]
fn c_clears_the_pane_and_the_help_closes_on_any_key() {
    let mut s = running();
    assert!(!s.panes()[FLUTTER].lines.is_empty());
    s.update(ms(1), Input::Key(Key::Char('c')));
    assert!(s.panes()[FLUTTER].lines.is_empty());
    s.update(ms(2), Input::Key(Key::Char('?')));
    assert_eq!(s.overlay(), crate::dev_state::Overlay::Help);
    // The key that closes it is not also a command: `q` does not quit from the help.
    s.update(ms(3), Input::Key(Key::Char('q')));
    assert_eq!(s.overlay(), crate::dev_state::Overlay::None);
    assert!(!s.finished());
    assert_eq!(s.phase(), crate::dev_state::Phase::Running);
}

#[test]
fn ctrl_c_quits_from_anywhere_even_while_typing_a_filter() {
    let mut s = running();
    s.update(ms(1), Input::Key(Key::Char('/')));
    let fx = s.update(ms(2), Input::Key(Key::Ctrl('c')));
    assert!(
        matches!(&fx[0], Effect::SendFlutter(l) if l.contains("app.stop")),
        "{fx:?}"
    );
}

#[test]
fn r_runs_flutter_again_after_it_stopped_by_itself() {
    let mut s = running();
    s.update(
        ms(20_000),
        Input::Exited {
            pane: FLUTTER,
            status: Status {
                code: 1,
                signal: None,
            },
        },
    );
    // r and the log keys keep working, and nothing is sent to a flutter that is gone.
    assert!(s.update(ms(20_001), Input::Key(Key::Char('r'))).is_empty());
    assert_eq!(
        s.update(ms(20_002), Input::Key(Key::Char('R'))),
        [Effect::Respawn]
    );
    s.started(FLUTTER);
    assert_eq!(s.phase(), crate::dev_state::Phase::Starting);
    assert_eq!(s.exit_code(), 0, "the new run has not failed");
    // Enter does it too.
    s.update(
        ms(21_000),
        Input::Exited {
            pane: FLUTTER,
            status: Status {
                code: 1,
                signal: None,
            },
        },
    );
    assert_eq!(
        s.update(ms(21_001), Input::Key(Key::Enter)),
        [Effect::Respawn]
    );
}

#[test]
fn the_last_lines_of_flutter_and_of_failing_panes_stay_on_screen() {
    let mut s = running();
    for i in 1..=30 {
        say(&mut s, 11, FLUTTER, &format!("flutter {i}"));
    }
    say(&mut s, 12, 2, "quiet build_runner");
    let lines = tail(&s, 20);
    assert_eq!(lines.len(), 20, "{lines:?}");
    assert_eq!(lines[0], "[flutter] flutter 11");
    assert_eq!(lines[19], "[flutter] flutter 30");
    // A pane with an error in its last lines is there too.
    s.update(
        ms(13),
        Input::Line {
            pane: 2,
            text: "[SEVERE] build failed".into(),
            err: true,
        },
    );
    let lines = tail(&s, 20);
    assert_eq!(
        lines.last().unwrap(),
        "[build_runner] [SEVERE] build failed"
    );
    assert!(lines.contains(&"[build_runner] quiet build_runner".to_string()));
    // fsp's own pane is not there without an error.
    assert!(!lines.iter().any(|l| l.starts_with("[fsp]")));
    s.update(
        ms(14),
        Input::Line {
            pane: FSP,
            text: "✗ hot reload failed".into(),
            err: true,
        },
    );
    assert!(tail(&s, 20).iter().any(|l| l.starts_with("[fsp]")));
    let _ = Kind::Normal;
}

#[test]
fn several_devices_ask_in_the_view_and_the_remembered_one_is_preselected() {
    let json = r#"[{"name":"macOS","id":"macos","isSupported":true,"targetPlatform":"darwin"},{"name":"Chrome","id":"chrome","isSupported":true,"targetPlatform":"web-javascript"}]"#;
    let Pick::Choose(devices) = pick_device(json, &[], true) else {
        panic!("not a choice");
    };
    let default = devices.iter().position(|d| d.id == "chrome").unwrap();
    assert_eq!(Picker::new(devices.len(), default).cursor, 1);
}

// --- the README screenshot ----------------------------------------------------------------------

const CELL_W: f64 = 8.4;
const CELL_H: f64 = 18.0;
const PAD: f64 = 16.0;
const TITLE_H: f64 = 30.0;
const BACKGROUND: &str = "#0d1117";
const FOREGROUND: &str = "#c9d1d9";

/// A fixed dark palette for the named colours the view uses.
fn hex(color: Color, default: &'static str) -> &'static str {
    match color {
        Color::Black => "#484f58",
        Color::Red | Color::LightRed => "#ff7b72",
        Color::Green | Color::LightGreen => "#7ee787",
        Color::Yellow | Color::LightYellow => "#e3b341",
        Color::Blue | Color::LightBlue => "#79c0ff",
        Color::Magenta | Color::LightMagenta => "#d2a8ff",
        Color::Cyan | Color::LightCyan => "#a5d6ff",
        Color::Gray => "#b1bac4",
        Color::DarkGray => "#6e7681",
        Color::White => "#f0f6fc",
        _ => default,
    }
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The buffer as a monospace SVG: a window on a dark background, one `<text>` per styled run per
/// row (`xml:space="preserve"`, `textLength` so a font with other metrics still lines up), a
/// rectangle behind a reversed or coloured-background run.
fn svg_of(buf: &Buffer) -> String {
    let cols = f64::from(buf.area.width);
    let rows = f64::from(buf.area.height);
    let width = cols * CELL_W + 2.0 * PAD;
    let height = rows * CELL_H + 2.0 * PAD + TITLE_H;
    let mut out = String::new();
    let _ = writeln!(
        out,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0}" height="{height:.0}" viewBox="0 0 {width:.0} {height:.0}" role="img" aria-label="fsp dev, the full-screen view: a header with the app, the device and the DevTools link; a tab per process; the flutter log; a status line; the keys">"#
    );
    let _ = writeln!(
        out,
        r#"<rect width="{width:.0}" height="{height:.0}" rx="10" fill="{BACKGROUND}"/>"#
    );
    for (i, color) in ["#ff5f56", "#ffbd2e", "#27c93f"].iter().enumerate() {
        let _ = writeln!(
            out,
            r#"<circle cx="{}" cy="{}" r="6" fill="{color}"/>"#,
            PAD + 6.0 + 20.0 * f64::from(u8::try_from(i).unwrap()),
            TITLE_H / 2.0 + 4.0
        );
    }
    let _ = writeln!(
        out,
        r#"<g font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace" font-size="14" xml:space="preserve">"#
    );
    for y in 0..buf.area.height {
        let top = TITLE_H + PAD + f64::from(y) * CELL_H;
        let mut x = 0;
        while x < buf.area.width {
            let c = &buf[(x, y)];
            let style = (c.fg, c.bg, c.modifier);
            let start = x;
            let mut cells: Vec<&str> = vec![];
            while x < buf.area.width && {
                let n = &buf[(x, y)];
                (n.fg, n.bg, n.modifier) == style
            } {
                cells.push(buf[(x, y)].symbol());
                x += 1;
            }
            let reversed = style.2.contains(Modifier::REVERSED);
            let (fg, bg) = if reversed {
                (hex(style.1, BACKGROUND), hex(style.0, FOREGROUND))
            } else {
                (hex(style.0, FOREGROUND), hex(style.1, ""))
            };
            let left = PAD + f64::from(start) * CELL_W;
            let columns = |cells: &[&str]| f64::from(u16::try_from(cells.len()).unwrap());
            if !bg.is_empty() {
                let _ = writeln!(
                    out,
                    r#"<rect x="{left:.1}" y="{top:.1}" width="{:.1}" height="{CELL_H:.0}" fill="{bg}"/>"#,
                    columns(&cells) * CELL_W
                );
            }
            while cells.last() == Some(&" ") {
                cells.pop();
            }
            if cells.iter().all(|c| *c == " ") {
                continue;
            }
            let weight = if style.2.contains(Modifier::BOLD) {
                r#" font-weight="bold""#
            } else {
                ""
            };
            let _ = writeln!(
                out,
                r#"<text xml:space="preserve" x="{left:.1}" y="{:.1}" fill="{fg}" textLength="{:.1}" lengthAdjust="spacing"{weight}>{}</text>"#,
                top + CELL_H - 5.0,
                columns(&cells) * CELL_W,
                escape(&cells.concat())
            );
        }
    }
    out.push_str("</g>\n</svg>\n");
    out
}

/// `docs/images/fsp-dev.svg` is the `running` screen as an SVG; `FSP_UPDATE_GOLDEN=1` writes it,
/// and the test fails when the file is stale.
#[test]
fn screenshot() {
    let svg = svg_of(&render(&running(), 14_000, 100, 30, false));
    assert!(svg.len() < 40_000, "{} bytes", svg.len());
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../docs/images/fsp-dev.svg");
    if updating() {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, &svg).unwrap();
    }
    let want = fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        svg, want,
        "docs/images/fsp-dev.svg is stale; run `FSP_UPDATE_GOLDEN=1 cargo test dev_tui_tests::` in cli/"
    );
}
