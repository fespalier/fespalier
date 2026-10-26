//! What `fsp dev` decides, driven with `now` values and no I/O: the hot reload rules, the
//! shutdown, the device choice, the panes.

use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::app_config::{Choice, Snapshot};
use crate::daemon::{self, Line};
use crate::dev_state::{
    Build, DevState, Device, Effect, FLUTTER, FSP, Input, KEPT_CHANGED, Key, Kind, Opts, Phase,
    Pick, Proc, RING, names_a_device, pick_device, strip_ansi,
};
use crate::procs::Status;
use crate::reload::Stamp;
use crate::watch::{FirstError, GenReport};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn state_with(plain: bool, hot_reload: bool, with: &[&str]) -> DevState {
    let mut s = DevState::new(Opts {
        name: "shop".into(),
        with: with.iter().map(|w| (*w).to_string()).collect(),
        hot_reload,
        plain,
        output: "lib/app.g.dart".into(),
        config_output: "lib/app.config.g.dart".into(),
        build: Build::seen(Choice::default(), None),
        device: Some(Device {
            id: "fake-1".into(),
            name: "Fake".into(),
            platform: "android-arm64".into(),
        }),
        stamp: None,
        config: None,
    });
    s.started(FLUTTER);
    s
}

fn state() -> DevState {
    state_with(true, true, &[])
}

/// A daemon event or response, from the line flutter would print.
fn daemon(json: &str) -> Input {
    let Line::Messages(mut m) = daemon::parse_line(json) else {
        panic!("not a message: {json}");
    };
    Input::Daemon(m.remove(0))
}

fn connect(s: &mut DevState) {
    s.update(
        ms(0),
        daemon(r#"[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]"#),
    );
}

fn app_start(s: &mut DevState, now: u64, supports_restart: bool) -> Vec<Effect> {
    s.update(
        ms(now),
        daemon(&format!(
            r#"[{{"event":"app.start","params":{{"appId":"a1","deviceId":"fake-1","supportsRestart":{supports_restart},"mode":"debug"}}}}]"#
        )),
    )
}

fn app_started(s: &mut DevState, now: u64) {
    s.update(
        ms(now),
        daemon(r#"[{"event":"app.started","params":{"appId":"a1"}}]"#),
    );
}

/// A state whose app is up: connected, started, running.
fn running() -> DevState {
    let mut s = state();
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    s
}

fn report(wrote: bool, ok: bool, first: bool) -> GenReport {
    GenReport {
        first,
        ok,
        wrote,
        // No stamp: a write restarts, as before 0.19.0.
        main_changed: false,
        stamp: None,
        swaps: false,
        config_written: false,
        routes_wrote: wrote,
        config: None,
        routes: ok.then_some(3),
        errors: usize::from(!ok),
        first_error: (!ok).then(|| FirstError {
            message: "a route clashes".into(),
            loc: None,
        }),
        elapsed: ms(3),
        quiet: false,
        line: Some(if ok {
            "✓ 3 routes → lib/app.g.dart (3.0ms)".into()
        } else {
            "1 error(s); lib/app.g.dart left unchanged".into()
        }),
    }
}

fn pass(s: &mut DevState, now: u64, r: GenReport) -> Vec<Effect> {
    s.update(ms(now), Input::Gen(r))
}

/// The requests among the effects, as `(id, fullRestart)`.
fn requests(fx: &[Effect]) -> Vec<(u64, bool)> {
    fx.iter()
        .filter_map(|e| match e {
            Effect::SendFlutter(line) if line.contains("app.restart") => {
                let v: serde_json::Value = serde_json::from_str(line).unwrap();
                Some((
                    v[0]["id"].as_u64().unwrap(),
                    v[0]["params"]["fullRestart"].as_bool().unwrap(),
                ))
            }
            _ => None,
        })
        .collect()
}

fn respond(s: &mut DevState, now: u64, id: u64, message: &str) -> Vec<Effect> {
    s.update(
        ms(now),
        daemon(&format!(
            r#"[{{"id":{id},"result":{{"code":0,"message":"{message}"}}}}]"#
        )),
    )
}

fn lines(s: &mut DevState) -> Vec<String> {
    s.drain_plain().into_iter().map(|l| l.text).collect()
}

// --- the app ---------------------------------------------------------------------------------

#[test]
fn app_start_sets_the_app_id_and_flushes_what_was_waiting() {
    let mut s = state();
    connect(&mut s);
    // A regeneration before `app.start`: nothing to send it to yet.
    let fx = pass(&mut s, 1, report(true, true, false));
    assert!(requests(&fx).is_empty());
    // A reload after it adds nothing: a restart is already waiting.
    let fx = pass(&mut s, 2, report(false, true, false));
    assert!(requests(&fx).is_empty());
    let fx = app_start(&mut s, 3, true);
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(s.phase(), Phase::Restarting);
}

#[test]
fn a_waiting_reload_is_sent_as_a_reload() {
    let mut s = state();
    connect(&mut s);
    pass(&mut s, 1, report(false, true, false));
    let fx = app_start(&mut s, 2, true);
    assert_eq!(requests(&fx), [(1, false)]);
}

#[test]
fn the_started_app_is_announced_with_its_device_once() {
    let mut s = state();
    connect(&mut s);
    app_start(&mut s, 1, true);
    s.update(
        ms(2),
        daemon(
            r#"[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:9100/"}}]"#,
        ),
    );
    s.update(
        ms(3),
        daemon(r#"[{"event":"app.webLaunchUrl","params":{"url":"http://localhost:54321","launched":false}}]"#),
    );
    app_started(&mut s, 4);
    assert_eq!(
        lines(&mut s),
        [
            "DevTools: http://127.0.0.1:9100/",
            "web: http://localhost:54321",
            "app running on Fake (fake-1)",
            "keys: r reload · R restart · q quit (type the letter, then Enter)",
        ]
    );
    assert_eq!(s.phase(), Phase::Running);
    // A second start (a hot restart does not send one, a new flutter does) says it again but
    // does not repeat the hint.
    app_started(&mut s, 5);
    assert_eq!(lines(&mut s), ["app running on Fake (fake-1)"]);
}

#[test]
fn flutter_lines_land_in_its_pane_with_the_right_kind() {
    let mut s = state();
    s.update(
        ms(1),
        daemon(r#"[{"event":"app.log","params":{"appId":"a1","log":"one\ntwo\n"}}]"#),
    );
    s.update(
        ms(2),
        daemon(r#"[{"event":"app.log","params":{"appId":"a1","log":"bad","error":true}}]"#),
    );
    s.update(
        ms(3),
        daemon(r#"[{"event":"daemon.logMessage","params":{"level":"error","message":"boom"}}]"#),
    );
    s.update(
        ms(4),
        daemon(
            r#"[{"event":"daemon.logMessage","params":{"level":"warning","message":"careful"}}]"#,
        ),
    );
    s.update(
        ms(5),
        daemon(r#"[{"event":"app.progress","params":{"appId":"a1","id":"1","message":"Running Gradle task...","finished":false}}]"#),
    );
    s.update(
        ms(6),
        daemon(r#"[{"event":"app.progress","params":{"appId":"a1","id":"1","finished":true}}]"#),
    );
    s.update(
        ms(7),
        Input::Line {
            pane: FLUTTER,
            text: "stray".into(),
            err: true,
        },
    );
    let got: Vec<(String, Kind)> = s.panes()[FLUTTER]
        .lines
        .iter()
        .map(|l| (l.text.clone(), l.kind))
        .collect();
    assert_eq!(
        got,
        [
            ("one".to_string(), Kind::Normal),
            ("two".to_string(), Kind::Normal),
            ("bad".to_string(), Kind::Error),
            ("error: boom".to_string(), Kind::Error),
            ("careful".to_string(), Kind::Warn),
            ("Running Gradle task...".to_string(), Kind::Normal),
            ("stray".to_string(), Kind::Error),
        ]
    );
}

// --- hot reload and restart ------------------------------------------------------------------------

#[test]
fn a_regeneration_that_wrote_restarts_and_any_other_save_reloads() {
    let mut s = running();
    let fx = pass(&mut s, 100, report(true, true, false));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(
        lines(&mut s)[..2],
        [
            "✓ 3 routes → lib/app.g.dart (3.0ms)",
            "hot restart: lib/app.g.dart changed"
        ]
    );
    respond(&mut s, 512, 1, "Restarted application in 412ms.");
    let fx = pass(&mut s, 600, report(false, true, false));
    assert_eq!(requests(&fx), [(2, false)]);
}

#[test]
fn the_first_pass_never_reloads_but_a_write_restarts() {
    let mut s = running();
    assert!(requests(&pass(&mut s, 5, report(false, true, true))).is_empty());
    assert_eq!(
        requests(&pass(&mut s, 6, report(true, true, true))),
        [(1, true)]
    );
}

#[test]
fn a_restart_in_flight_covers_a_reload_but_not_another_restart() {
    let mut s = running();
    assert_eq!(
        requests(&pass(&mut s, 100, report(true, true, false))),
        [(1, true)]
    );
    // The reload is dropped: the restart covers it.
    assert!(requests(&pass(&mut s, 110, report(false, true, false))).is_empty());
    // A restart is sent again: the file changed after the first compile began.
    assert_eq!(
        requests(&pass(&mut s, 120, report(true, true, false))),
        [(2, true)]
    );
    respond(&mut s, 400, 1, "");
    assert_eq!(s.phase(), Phase::Restarting);
    respond(&mut s, 500, 2, "");
    assert_eq!(s.phase(), Phase::Running);
}

#[test]
fn a_reload_in_flight_lets_a_restart_and_a_reload_through() {
    let mut s = running();
    assert_eq!(
        requests(&pass(&mut s, 100, report(false, true, false))),
        [(1, false)]
    );
    let fx = pass(&mut s, 105, report(false, true, false));
    assert_eq!(requests(&fx), [(2, false)]);
    // Reloads are sent debounced, so flutter merges neighbours.
    let Effect::SendFlutter(line) = &fx[0] else {
        panic!("not a request");
    };
    assert!(line.contains(r#""debounce":true"#), "{line}");
    assert_eq!(
        requests(&pass(&mut s, 110, report(true, true, false))),
        [(3, true)]
    );
}

#[test]
fn results_set_the_status_and_the_duration_is_measured_from_the_send() {
    let mut s = running();
    pass(&mut s, 1000, report(true, true, false));
    s.drain_plain();
    respond(&mut s, 1412, 1, "Restarted application in 412ms.");
    assert_eq!(lines(&mut s), ["✓ hot restart in 412 ms"]);
    let hot = s.last_hot().unwrap();
    assert!(hot.ok && hot.full);
    assert_eq!(hot.ms, 412);

    pass(&mut s, 2000, report(false, true, false));
    s.drain_plain();
    respond(&mut s, 2120, 2, "Reloaded 3 of 512 libraries");
    assert_eq!(
        lines(&mut s),
        ["✓ hot reload in 120 ms (Reloaded 3 of 512 libraries)"]
    );
    assert_eq!(s.last_hot().unwrap().message, "Reloaded 3 of 512 libraries");
}

#[test]
fn a_failed_reload_says_why_in_the_status_and_the_flutter_pane() {
    let mut s = state_with(false, true, &[]);
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    pass(&mut s, 1000, report(false, true, false));
    s.update(
        ms(1100),
        daemon(r#"[{"id":1,"result":{"code":1,"message":"Hot reload was rejected"}}]"#),
    );
    let fsp = s.panes()[FSP].lines.back().unwrap();
    assert_eq!(fsp.text, "✗ hot reload failed: Hot reload was rejected");
    assert_eq!(fsp.kind, Kind::Error);
    assert_eq!(
        s.panes()[FLUTTER].lines.back().unwrap().text,
        "Hot reload was rejected"
    );
    assert!(!s.last_hot().unwrap().ok);
    // A request that threw.
    pass(&mut s, 1200, report(true, true, false));
    s.update(ms(1300), daemon(r#"[{"id":2,"error":"app not found"}]"#));
    assert_eq!(
        s.panes()[FSP].lines.back().unwrap().text,
        "✗ hot restart failed: app not found"
    );
}

#[test]
fn plain_mode_says_a_failure_once_on_fsps_line() {
    let mut s = running();
    pass(&mut s, 1000, report(false, true, false));
    s.drain_plain();
    s.update(
        ms(1100),
        daemon(r#"[{"id":1,"result":{"code":1,"message":"Hot reload was rejected"}}]"#),
    );
    assert_eq!(
        lines(&mut s),
        ["✗ hot reload failed: Hot reload was rejected"]
    );
}

#[test]
fn a_response_nobody_asked_for_is_ignored() {
    let mut s = running();
    s.update(ms(5), daemon(r#"[{"id":99,"result":true}]"#));
    assert!(s.drain_plain().is_empty());
    assert!(s.last_hot().is_none());
}

#[test]
fn without_hot_restart_nothing_is_sent_and_a_key_says_why() {
    let mut s = state();
    connect(&mut s);
    app_start(&mut s, 1, false);
    app_started(&mut s, 2);
    s.drain_plain();
    assert!(requests(&pass(&mut s, 10, report(true, true, false))).is_empty());
    assert!(s.update(ms(11), Input::Key(Key::Char('r'))).is_empty());
    assert_eq!(
        lines(&mut s).last().unwrap(),
        "hot reload is off: flutter run started without it (--no-hot, --profile or --release)"
    );
}

#[test]
fn hot_reload_false_sends_nothing_by_itself_but_the_keys_work() {
    let mut s = state_with(true, false, &[]);
    connect(&mut s);
    app_start(&mut s, 1, true);
    app_started(&mut s, 2);
    assert!(requests(&pass(&mut s, 10, report(true, true, false))).is_empty());
    assert!(requests(&pass(&mut s, 11, report(false, true, false))).is_empty());
    assert_eq!(
        requests(&s.update(ms(12), Input::Key(Key::Char('r')))),
        [(1, false)]
    );
    assert_eq!(
        requests(&s.update(ms(13), Input::Key(Key::Char('R')))),
        [(2, true)]
    );
}

#[test]
fn a_generation_with_errors_shows_the_first_error_and_sends_nothing() {
    let mut s = running();
    let fx = pass(&mut s, 50, report(false, false, false));
    assert!(requests(&fx).is_empty());
    assert_eq!(s.generation.errors, 1);
    assert_eq!(
        s.generation.first_error.as_ref().unwrap().message,
        "a route clashes"
    );
    // The route count is what the last good pass had.
    pass(&mut s, 40, report(false, true, false));
    pass(&mut s, 60, report(false, false, false));
    assert_eq!(s.generation.routes, Some(3));
    assert_eq!(
        lines(&mut s).last().unwrap(),
        "1 error(s); lib/app.g.dart left unchanged"
    );
}

#[test]
fn a_key_before_flutter_has_connected_says_so() {
    let mut s = state();
    s.update(ms(1), Input::Key(Key::Char('r')));
    assert_eq!(
        lines(&mut s),
        [
            "the `run` command has not connected over flutter's --machine protocol yet; hot reload needs `flutter run`"
        ]
    );
    // Once it has, a key before `app.start` waits for it.
    connect(&mut s);
    assert!(s.update(ms(2), Input::Key(Key::Char('r'))).is_empty());
    assert_eq!(requests(&app_start(&mut s, 3, true)), [(1, false)]);
}

#[test]
fn typed_lines_are_keys() {
    let mut s = running();
    assert_eq!(
        requests(&s.update(ms(1), Input::Typed("r\n".into()))),
        [(1, false)]
    );
    assert_eq!(
        requests(&s.update(ms(2), Input::Typed(" R ".into()))),
        [(2, true)]
    );
    // More than a letter, or nothing, is not a key.
    assert!(s.update(ms(3), Input::Typed("reload".into())).is_empty());
    assert!(s.update(ms(4), Input::Typed(String::new())).is_empty());
    assert_eq!(s.phase(), Phase::Restarting);
}

#[test]
fn d_and_o_print_the_addresses_in_plain_mode() {
    let mut s = running();
    s.update(ms(30), Input::Key(Key::Char('d')));
    s.update(ms(31), Input::Key(Key::Char('o')));
    assert_eq!(
        lines(&mut s),
        ["no DevTools URL yet", "no web URL: the app runs on Fake"]
    );
    s.update(
        ms(32),
        daemon(
            r#"[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:9100/"}}]"#,
        ),
    );
    s.update(
        ms(33),
        daemon(r#"[{"event":"app.webLaunchUrl","params":{"url":"http://localhost:1","launched":true}}]"#),
    );
    s.drain_plain();
    s.update(ms(34), Input::Key(Key::Char('d')));
    s.update(ms(35), Input::Key(Key::Char('o')));
    assert_eq!(
        lines(&mut s),
        [
            "DevTools: http://127.0.0.1:9100/",
            "web: http://localhost:1"
        ]
    );
}

// --- quitting ---------------------------------------------------------------------------------------

fn exit0() -> Status {
    Status {
        code: 0,
        signal: None,
    }
}

fn exit(code: i32) -> Status {
    Status { code, signal: None }
}

#[test]
fn q_asks_flutter_to_stop_and_a_second_q_kills_everything() {
    let mut s = running();
    let fx = s.update(ms(100), Input::Key(Key::Char('q')));
    assert_eq!(fx.len(), 1);
    let Effect::SendFlutter(line) = &fx[0] else {
        panic!("{fx:?}");
    };
    assert!(
        line.contains(r#""method":"app.stop""#) && line.contains(r#""appId":"a1""#),
        "{line}"
    );
    assert_eq!(s.phase(), Phase::Quitting);
    assert_eq!(
        lines(&mut s),
        ["stopping flutter… (press q or Ctrl-C again to kill it)"]
    );
    // Reloads and restarts are over.
    assert!(requests(&pass(&mut s, 110, report(true, true, false))).is_empty());
    assert!(!s.finished());
    let fx = s.update(ms(120), Input::Key(Key::Char('q')));
    assert_eq!(fx, [Effect::KillAll]);
    assert!(s.finished());
    assert_eq!(s.exit_code(), 130);
    assert!(!s.after_ok());
}

#[test]
fn flutter_stopping_ends_the_loop_with_exit_0() {
    let mut s = running();
    s.update(ms(100), Input::Key(Key::Char('q')));
    let fx = s.update(
        ms(200),
        Input::Exited {
            pane: FLUTTER,
            status: exit0(),
        },
    );
    assert_eq!(fx, [Effect::Finish]);
    assert!(s.finished());
    assert_eq!(s.exit_code(), 0);
    assert!(s.after_ok());
}

#[test]
fn a_signal_exits_130_and_still_stops_flutter_first() {
    let mut s = running();
    let fx = s.update(ms(100), Input::Signal);
    assert!(matches!(&fx[0], Effect::SendFlutter(l) if l.contains("app.stop")));
    s.update(
        ms(150),
        Input::Exited {
            pane: FLUTTER,
            status: exit0(),
        },
    );
    assert!(s.finished());
    assert_eq!(s.exit_code(), 130);
    // fsp stopped it, so `after` runs.
    assert!(s.after_ok());
}

#[test]
fn flutter_before_app_start_is_terminated_at_once() {
    let mut s = state();
    let fx = s.update(ms(5), Input::Key(Key::Char('q')));
    assert_eq!(fx, [Effect::Term(FLUTTER)]);
}

#[test]
fn a_flutter_that_ignores_app_stop_is_terminated_then_killed() {
    let mut s = running();
    s.update(ms(1000), Input::Key(Key::Char('q')));
    assert_eq!(s.next_deadline(), Some(ms(11_000)));
    assert!(s.update(ms(10_999), Input::Tick).is_empty());
    assert_eq!(s.update(ms(11_000), Input::Tick), [Effect::Term(FLUTTER)]);
    assert_eq!(s.next_deadline(), Some(ms(16_000)));
    assert!(s.update(ms(15_999), Input::Tick).is_empty());
    assert_eq!(s.update(ms(16_000), Input::Tick), [Effect::Kill(FLUTTER)]);
    assert_eq!(s.next_deadline(), None);
}

#[test]
fn with_processes_are_stopped_after_flutter_and_killed_after_a_grace() {
    let mut s = state_with(true, true, &["builder", "ticker"]);
    s.started(2);
    s.started(3);
    connect(&mut s);
    app_start(&mut s, 1, true);
    s.update(ms(1000), Input::Key(Key::Char('q')));
    // Flutter first; the others are left alone until it is gone.
    let fx = s.update(
        ms(1500),
        Input::Exited {
            pane: FLUTTER,
            status: exit0(),
        },
    );
    assert_eq!(fx, [Effect::Term(2), Effect::Term(3)]);
    assert!(!s.finished());
    assert_eq!(s.next_deadline(), Some(ms(6500)));
    // One ends, the other does not.
    s.update(
        ms(1600),
        Input::Exited {
            pane: 2,
            status: exit(143),
        },
    );
    assert!(!s.finished());
    assert_eq!(s.update(ms(6500), Input::Tick), [Effect::Kill(3)]);
    let fx = s.update(
        ms(6600),
        Input::Exited {
            pane: 3,
            status: exit(137),
        },
    );
    assert_eq!(fx, [Effect::Finish]);
    assert_eq!(s.exit_code(), 0);
}

#[test]
fn a_with_process_that_exits_marks_its_pane_and_says_so() {
    let mut s = state_with(true, true, &["builder"]);
    s.started(2);
    s.update(
        ms(10),
        Input::Line {
            pane: 2,
            text: "compiling".into(),
            err: false,
        },
    );
    s.update(
        ms(20),
        Input::Exited {
            pane: 2,
            status: exit(1),
        },
    );
    assert_eq!(s.panes()[2].proc, Proc::Exited(exit(1)));
    assert_eq!(
        lines(&mut s),
        [
            "compiling",
            "[builder] exited (exit 1); fsp dev keeps running"
        ]
    );
    assert!(!s.finished());
}

#[test]
fn flutter_exiting_by_itself_ends_plain_mode_with_its_code() {
    let mut s = running();
    s.update(
        ms(100),
        Input::Exited {
            pane: FLUTTER,
            status: exit(1),
        },
    );
    assert_eq!(lines(&mut s), ["flutter run exited (exit 1)"]);
    assert!(s.finished());
    assert_eq!(s.exit_code(), 1);
    assert!(!s.after_ok());
}

#[test]
fn flutter_exiting_by_itself_with_0_is_a_clean_end() {
    let mut s = running();
    s.update(
        ms(100),
        Input::Exited {
            pane: FLUTTER,
            status: exit0(),
        },
    );
    assert!(s.finished());
    assert_eq!(s.exit_code(), 0);
    assert!(s.after_ok());
}

#[test]
fn flutter_exiting_by_itself_leaves_the_view_open_when_it_is_not_plain() {
    let mut s = state_with(false, true, &[]);
    s.update(
        ms(100),
        Input::Exited {
            pane: FLUTTER,
            status: exit(1),
        },
    );
    assert!(!s.finished());
    assert_eq!(s.phase(), Phase::Stopped(1));
    assert!(
        s.drain_plain().is_empty(),
        "the view shows panes, plain mode prints them"
    );
    // q ends it, with flutter's own code.
    s.update(ms(200), Input::Key(Key::Char('q')));
    assert!(s.finished());
    assert_eq!(s.exit_code(), 1);
}

// --- the panes -------------------------------------------------------------------------------------

#[test]
fn ansi_escapes_are_stripped() {
    assert_eq!(strip_ansi("\x1b[31mred\x1b[0m plain"), "red plain");
    assert_eq!(strip_ansi("\x1b[1;32m✓\x1b[m ok"), "✓ ok");
    assert_eq!(
        strip_ansi("a\x1b]8;;file:///x\x1b\\link\x1b]8;;\x1b\\b"),
        "alinkb"
    );
    assert_eq!(strip_ansi("a\x1b]0;title\x07b"), "ab");
    assert_eq!(strip_ansi("\x1b[2K\x1b[1Gdone"), "done");
    assert_eq!(strip_ansi("no escapes"), "no escapes");
    assert_eq!(strip_ansi("trailing \x1b"), "trailing ");
}

#[test]
fn a_pane_keeps_only_the_last_lines() {
    let mut s = state_with(false, true, &[]);
    for i in 0..RING + 25 {
        s.update(
            ms(1),
            Input::Line {
                pane: FSP,
                text: format!("line {i}"),
                err: false,
            },
        );
    }
    let p = &s.panes()[FSP];
    assert_eq!(p.lines.len(), RING);
    assert_eq!(p.lines.front().unwrap().text, "line 25");
    assert_eq!(p.lines.back().unwrap().text, format!("line {}", RING + 24));
}

#[test]
fn lines_are_cleaned_when_they_arrive() {
    let mut s = state();
    s.update(
        ms(1),
        Input::Line {
            pane: 0,
            text: "\x1b[32mgreen\x1b[0m\r".into(),
            err: false,
        },
    );
    assert_eq!(lines(&mut s), ["green"]);
}

// --- the device ------------------------------------------------------------------------------------

fn listing(items: &[(&str, &str, &str, bool)]) -> String {
    let all: Vec<String> = items
        .iter()
        .map(|(id, name, platform, supported)| {
            format!(
                r#"{{"name":"{name}","id":"{id}","isSupported":{supported},"targetPlatform":"{platform}","emulator":false}}"#
            )
        })
        .collect();
    format!("[{}]", all.join(","))
}

fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| (*s).to_string()).collect()
}

fn device(id: &str, name: &str, platform: &str) -> Device {
    Device {
        id: id.into(),
        name: name.into(),
        platform: platform.into(),
    }
}

#[test]
fn a_device_in_the_arguments_means_fsp_passes_nothing() {
    let l = listing(&[("a", "A", "android-arm64", true), ("b", "B", "ios", true)]);
    for a in [
        &["-d", "chrome"][..],
        &["--device-id", "chrome"],
        &["--device-id=chrome"],
        &["-dchrome"],
        &["--flavor", "dev", "-d", "x"],
    ] {
        assert!(names_a_device(&args(a)), "{a:?}");
        assert_eq!(pick_device(&l, &args(a), true), Pick::Skip, "{a:?}");
    }
    for a in [
        &[][..],
        &["--flavor", "dev"],
        &["--dart-define=A=1"],
        &["--debug"],
    ] {
        assert!(!names_a_device(&args(a)), "{a:?}");
    }
}

#[test]
fn one_supported_device_is_the_device() {
    let l = listing(&[("chrome", "Chrome", "web-javascript", true)]);
    assert_eq!(
        pick_device(&l, &[], false),
        Pick::Device(device("chrome", "Chrome", "web-javascript"))
    );
    // An unsupported one does not count.
    let l = listing(&[
        ("chrome", "Chrome", "web-javascript", true),
        ("linux", "Linux", "linux-x64", false),
    ]);
    assert!(matches!(pick_device(&l, &[], false), Pick::Device(d) if d.id == "chrome"));
}

#[test]
fn one_phone_among_desktop_and_web_is_the_device() {
    // Flutter's own rule: a single ephemeral device is chosen without asking.
    let l = listing(&[
        ("macos", "macOS", "darwin", true),
        ("chrome", "Chrome", "web-javascript", true),
        ("emulator-5554", "Pixel 8", "android-arm64", true),
    ]);
    assert_eq!(
        pick_device(&l, &[], false),
        Pick::Device(device("emulator-5554", "Pixel 8", "android-arm64"))
    );
}

#[test]
fn several_devices_ask_when_someone_can_be_asked_and_say_so_when_not() {
    let l = listing(&[
        ("macos", "macOS", "darwin", true),
        ("chrome", "Chrome", "web-javascript", true),
    ]);
    assert_eq!(
        pick_device(&l, &[], true),
        Pick::Choose(vec![
            device("macos", "macOS", "darwin"),
            device("chrome", "Chrome", "web-javascript"),
        ])
    );
    assert_eq!(
        pick_device(&l, &[], false),
        Pick::NeedFlag(vec!["macos".into(), "chrome".into()])
    );
    // Two phones are two devices too.
    let l = listing(&[("a", "A", "android-arm64", true), ("b", "B", "ios", true)]);
    assert!(matches!(pick_device(&l, &[], true), Pick::Choose(d) if d.len() == 2));
}

#[test]
fn no_supported_device_and_an_unreadable_listing() {
    assert_eq!(pick_device("[]", &[], true), Pick::NoDevice);
    let l = listing(&[("linux", "Linux", "linux-x64", false)]);
    assert_eq!(pick_device(&l, &[], true), Pick::NoDevice);
    assert_eq!(pick_device("", &[], true), Pick::Unlisted);
    assert_eq!(pick_device("no json here", &[], true), Pick::Unlisted);
    assert_eq!(pick_device("[{broken", &[], true), Pick::Unlisted);
}

#[test]
fn a_banner_before_the_json_is_ignored() {
    let l = format!(
        "Downloading things...\n{}\n",
        listing(&[("chrome", "Chrome", "web-javascript", true)])
    );
    assert!(matches!(pick_device(&l, &[], false), Pick::Device(_)));
}

// --- a reload after a regeneration (since 0.19.0) ---------------------------------------------

/// A stamp with this `_version` and these `_kept` names and hashes.
fn stamp(version: &str, kept: &[(&str, &str)]) -> Stamp {
    Stamp {
        version: version.into(),
        kept: kept
            .iter()
            .map(|(name, hash)| ((*name).to_string(), (*hash).to_string()))
            .collect(),
    }
}

/// A state that flutter started on a file holding `stamp`, not yet connected.
fn started_from(stamp: Option<Stamp>, plain: bool) -> DevState {
    started_with(stamp, plain, Build::seen(Choice::default(), None))
}

/// [`started_from`], with what `fsp dev` can tell of the configuration's profile.
fn started_with(stamp: Option<Stamp>, plain: bool, build: Build) -> DevState {
    started_hot(stamp, plain, true, build)
}

/// [`started_with`], with `hot_reload:` of the task as `hot_reload`.
fn started_hot(stamp: Option<Stamp>, plain: bool, hot_reload: bool, build: Build) -> DevState {
    started_config(stamp, plain, hot_reload, build, None)
}

/// [`started_hot`], over a file of the app's configuration that holds `config` (since 0.24.1).
fn started_config(
    stamp: Option<Stamp>,
    plain: bool,
    hot_reload: bool,
    build: Build,
    config: Option<Snapshot>,
) -> DevState {
    let mut s = DevState::new(Opts {
        name: "shop".into(),
        with: vec![],
        hot_reload,
        plain,
        output: "lib/app.g.dart".into(),
        config_output: "lib/app.config.g.dart".into(),
        build,
        device: Some(Device {
            id: "fake-1".into(),
            name: "Fake".into(),
            platform: "android-arm64".into(),
        }),
        stamp,
        config,
    });
    s.started(FLUTTER);
    s
}

/// A running app, plain, whose routes are `stamp`.
fn running_from(stamp: Option<Stamp>) -> DevState {
    let mut s = started_from(stamp, true);
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    s
}

/// The report of a pass that wrote a file holding `stamp`, whose routes can be swapped in.
fn wrote(stamp: Stamp) -> GenReport {
    GenReport {
        stamp: Some(stamp),
        swaps: true,
        ..report(true, true, false)
    }
}

/// The report of a pass that wrote nothing (a save) over a file holding `stamp`, whose routes can
/// be swapped in: it makes a hot reload.
fn saved(stamp: Stamp) -> GenReport {
    GenReport {
        stamp: Some(stamp),
        swaps: true,
        ..report(false, true, false)
    }
}

/// The app's log with `line` in it, as flutter sends it (a refusal of a swap is one of these).
fn refusal(line: &str) -> Input {
    daemon(&format!(
        r#"[{{"event":"app.log","params":{{"appId":"a1","log":"{line}"}}}}]"#
    ))
}

#[test]
fn a_regeneration_the_app_can_swap_is_a_hot_reload() {
    let v0 = stamp(
        "0123456789abcdef",
        &[("(router)", "aaaaaaaa"), ("AppRoutes._data3", "dddddddd")],
    );
    // A new route adds a name and changes none that is kept.
    let v1 = stamp(
        "fedcba9876543210",
        &[
            ("(router)", "aaaaaaaa"),
            ("AppRoutes._data3", "dddddddd"),
            ("ZzRoute.x", "eeeeeeee"),
        ],
    );
    let mut s = running_from(Some(v0));
    let fx = pass(&mut s, 100, wrote(v1));
    assert_eq!(requests(&fx), [(1, false)]);
    assert_eq!(
        lines(&mut s),
        [
            "✓ 3 routes → lib/app.g.dart (3.0ms)",
            "hot reload: lib/app.g.dart changed"
        ]
    );
    respond(&mut s, 220, 1, "Reloaded 2 of 9 libraries");
    assert_eq!(
        lines(&mut s),
        ["✓ hot reload in 120 ms (Reloaded 2 of 9 libraries)"]
    );
}

#[test]
fn a_kept_name_with_another_hash_restarts() {
    let v0 = stamp(
        "0123456789abcdef",
        &[("(router)", "aaaaaaaa"), ("AppRoutes._data3", "dddddddd")],
    );
    // The same route, with another hash for `_data3`: the app would keep its old value.
    let v1 = stamp(
        "fedcba9876543210",
        &[("(router)", "aaaaaaaa"), ("AppRoutes._data3", "eeeeeeee")],
    );
    let mut s = running_from(Some(v0));
    let fx = pass(&mut s, 100, wrote(v1));
    assert_eq!(requests(&fx), [(1, true)]);
    let shown = lines(&mut s);
    assert_eq!(shown[1], "hot restart: lib/app.g.dart changed");
}

#[test]
fn added_and_removed_names_still_reload() {
    let v0 = stamp("0123456789abcdef", &[("a", "11111111"), ("b", "22222222")]);
    let v1 = stamp("fedcba9876543210", &[("b", "22222222"), ("c", "33333333")]);
    let mut s = running_from(Some(v0));
    let fx = pass(&mut s, 100, wrote(v1));
    assert_eq!(requests(&fx), [(1, false)]);
}

#[test]
fn each_reason_to_restart() {
    let v0 = stamp("0123456789abcdef", &[("a", "11111111")]);
    let v1 = stamp("fedcba9876543210", &[("a", "11111111")]);
    let restarts = |reason: &str, r: GenReport, mut s: DevState| {
        assert_eq!(requests(&pass(&mut s, 100, r)), [(1, true)], "{reason}");
    };
    // The generated main was written: a reload never runs `main()` again.
    restarts(
        "main_changed",
        GenReport {
            main_changed: true,
            ..wrote(v1.clone())
        },
        running_from(Some(v0.clone())),
    );
    // app.dart builds its own router, so the generated routes are not the ones in use.
    restarts(
        "swaps: false",
        GenReport {
            swaps: false,
            ..wrote(v1.clone())
        },
        running_from(Some(v0.clone())),
    );
    // The file has no stamp (it was edited by hand, or is not generated by this version).
    restarts(
        "stamp: None",
        GenReport {
            stamp: None,
            ..wrote(v1.clone())
        },
        running_from(Some(v0.clone())),
    );
    // The app holds no baseline: flutter started on a file with no stamp.
    restarts("running: None", wrote(v1), running_from(None));
}

#[test]
fn a_restart_runs_the_file_it_compiled() {
    let v1 = stamp("fedcba9876543210", &[("a", "11111111")]);
    let mut s = running_from(None);
    assert_eq!(requests(&pass(&mut s, 100, wrote(v1))), [(1, true)]);
    respond(&mut s, 200, 1, "");
    // The restart compiled v1, so v1 is the baseline now: a compatible v2 reloads.
    let v2 = stamp("0f0f0f0f0f0f0f0f", &[("a", "11111111"), ("b", "22222222")]);
    assert_eq!(requests(&pass(&mut s, 300, wrote(v2))), [(2, false)]);
}

#[test]
fn the_baseline_follows_a_reload_that_swapped() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let v2 = stamp("2222222222222222", &[("b", "33333333")]);
    // v0 swaps to v2 (a is removed, b is added), but the app holds v1 once v1's reload was
    // answered, and v1 does not swap to v2 (b changed): so v2 restarts.
    assert!(v0.swaps_to(&v2));
    let mut s = running_from(Some(v0));
    assert_eq!(requests(&pass(&mut s, 100, wrote(v1))), [(1, false)]);
    respond(&mut s, 120, 1, "Reloaded 1 of 9 libraries");
    assert_eq!(requests(&pass(&mut s, 200, wrote(v2))), [(2, true)]);
}

#[test]
fn a_reload_in_flight_counts() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let v2 = stamp("2222222222222222", &[("a", "11111111"), ("b", "33333333")]);
    let mut s = running_from(Some(v0));
    assert_eq!(requests(&pass(&mut s, 100, wrote(v1))), [(1, false)]);
    // Reload 1 is unanswered and its routes do not swap to v2: the reload would go past it.
    assert_eq!(requests(&pass(&mut s, 110, wrote(v2))), [(2, true)]);
}

#[test]
fn a_failed_request_makes_the_next_regeneration_restart() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0));
    // A save reload is refused by flutter: nothing follows it, and the app keeps what it had.
    assert_eq!(
        requests(&pass(&mut s, 100, report(false, true, false))),
        [(1, false)]
    );
    let fx = s.update(
        ms(110),
        daemon(r#"[{"id":1,"result":{"code":1,"message":"Hot reload was rejected"}}]"#),
    );
    assert!(requests(&fx).is_empty());
    // A compatible regeneration restarts, since the last hot result is a failure.
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    assert_eq!(requests(&pass(&mut s, 200, wrote(v1))), [(2, true)]);
}

#[test]
fn a_restart_under_way_makes_a_regeneration_restart() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0));
    assert_eq!(
        requests(&s.update(ms(100), Input::Key(Key::Char('R')))),
        [(1, true)]
    );
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    assert_eq!(requests(&pass(&mut s, 110, wrote(v1))), [(2, true)]);
}

#[test]
fn a_failed_reload_of_a_regeneration_is_followed_by_a_restart() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let mut s = running_from(Some(v0));
    assert_eq!(requests(&pass(&mut s, 100, wrote(v1))), [(1, false)]);
    s.drain_plain();
    let fx = s.update(
        ms(110),
        daemon(r#"[{"id":1,"result":{"code":1,"message":"Hot reload was rejected"}}]"#),
    );
    assert_eq!(requests(&fx), [(2, true)]);
    assert_eq!(
        lines(&mut s),
        [
            "✗ hot reload failed: Hot reload was rejected",
            "hot restart: lib/app.g.dart changed and the hot reload failed"
        ]
    );
    respond(&mut s, 200, 2, "");
    // The restart compiled v1: a compatible v2 reloads again.
    let v2 = stamp(
        "2222222222222222",
        &[("a", "11111111"), ("b", "22222222"), ("c", "33333333")],
    );
    assert_eq!(requests(&pass(&mut s, 300, wrote(v2))), [(3, false)]);
}

#[test]
fn the_app_keeping_its_old_routes_is_restarted() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0.clone()));
    // Only a reload can be refused: one goes out first (a save), and the app refuses it.
    assert_eq!(requests(&pass(&mut s, 50, saved(v0))), [(1, false)]);
    s.drain_plain();
    let line = format!("I/flutter ( 4242): {KEPT_CHANGED}");
    let fx = s.update(ms(100), refusal(&line));
    assert_eq!(requests(&fx), [(2, true)]);
    assert_eq!(
        lines(&mut s).last().unwrap(),
        "hot restart: the app kept its old routes"
    );
    // The app says it once per version; the same line while the restart is under way sends nothing.
    let fx = s.update(ms(110), refusal(&line));
    assert!(requests(&fx).is_empty());
}

/// A reload that went out and was answered, and then a restart for a refusal that was answered
/// too: a state in which the app's refusal has been dealt with.
fn refused_and_restarted() -> DevState {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0.clone()));
    assert_eq!(requests(&pass(&mut s, 50, saved(v0))), [(1, false)]);
    assert_eq!(
        requests(&s.update(ms(100), refusal(KEPT_CHANGED))),
        [(2, true)]
    );
    respond(&mut s, 120, 1, "Reloaded 1 of 9 libraries");
    respond(&mut s, 400, 2, "");
    s.drain_plain();
    s
}

#[test]
fn a_web_app_prints_the_refusal_as_a_plain_line() {
    // Flutter on the web sends the app's prints as plain lines on stdout, not as `app.log` events.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    for (text, err) in [
        (KEPT_CHANGED.to_string(), false),
        (KEPT_CHANGED.to_string(), true),
        (format!("I/flutter ( 4242): {KEPT_CHANGED}"), false),
    ] {
        let mut s = running_from(Some(v0.clone()));
        assert_eq!(requests(&pass(&mut s, 50, saved(v0.clone()))), [(1, false)]);
        s.drain_plain();
        let fx = s.update(
            ms(100),
            Input::Line {
                pane: FLUTTER,
                text: text.clone(),
                err,
            },
        );
        assert_eq!(requests(&fx), [(2, true)], "{text}");
        let said = lines(&mut s);
        assert_eq!(
            said.last().unwrap(),
            "hot restart: the app kept its old routes"
        );
        // The line itself is in the pane, once, and only the restart line is added to it.
        assert_eq!(
            said,
            [text.as_str(), "hot restart: the app kept its old routes"]
        );
    }
}

#[test]
fn only_flutters_lines_are_a_refusal() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = state_with(true, true, &["web"]);
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    assert_eq!(requests(&pass(&mut s, 50, saved(v0))), [(1, false)]);
    // A line of fsp's own pane, or of a `with` process, is not the app speaking.
    for pane in [FSP, FSP + 1] {
        let fx = s.update(
            ms(100),
            Input::Line {
                pane,
                text: KEPT_CHANGED.into(),
                err: false,
            },
        );
        assert!(requests(&fx).is_empty());
    }
}

#[test]
fn the_tools_log_can_carry_the_refusal_too() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0.clone()));
    assert_eq!(requests(&pass(&mut s, 50, saved(v0))), [(1, false)]);
    let fx = s.update(
        ms(100),
        daemon(&format!(
            r#"[{{"event":"daemon.logMessage","params":{{"level":"status","message":"{KEPT_CHANGED}"}}}}]"#
        )),
    );
    assert_eq!(requests(&fx), [(2, true)]);
}

#[test]
fn the_refusal_said_again_after_its_restart_is_not_another_restart() {
    let mut s = refused_and_restarted();
    // A late or repeated line, as an event or as a plain line: no reload has gone out since the
    // restart, so it is the same refusal.
    let fx = s.update(ms(500), refusal(KEPT_CHANGED));
    assert!(requests(&fx).is_empty());
    let fx = s.update(
        ms(510),
        Input::Line {
            pane: FLUTTER,
            text: KEPT_CHANGED.into(),
            err: false,
        },
    );
    assert!(requests(&fx).is_empty());
    assert!(
        !lines(&mut s)
            .iter()
            .any(|l| l == "hot restart: the app kept its old routes")
    );
    // A reload that goes out afterwards can be refused again, and is restarted once more.
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    assert_eq!(requests(&pass(&mut s, 600, wrote(v1))), [(3, false)]);
    assert_eq!(
        requests(&s.update(ms(650), refusal(KEPT_CHANGED))),
        [(4, true)]
    );
}

#[test]
fn a_refusal_before_any_reload_is_not_acted_on() {
    // The app has not been reloaded since it started: the line cannot be a refusal of ours.
    let mut s = running_from(Some(stamp("0000000000000000", &[("a", "11111111")])));
    let fx = s.update(ms(100), refusal(KEPT_CHANGED));
    assert!(requests(&fx).is_empty());
    assert!(
        !lines(&mut s)
            .iter()
            .any(|l| l == "hot restart: the app kept its old routes")
    );
}

#[test]
fn a_refusal_while_quitting_says_nothing() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0.clone()));
    assert_eq!(requests(&pass(&mut s, 50, saved(v0))), [(1, false)]);
    s.update(ms(60), Input::Key(Key::Char('q')));
    s.drain_plain();
    // The restart cannot be sent while flutter is stopping, so the line must not claim one.
    let fx = s.update(ms(100), refusal(KEPT_CHANGED));
    assert!(requests(&fx).is_empty());
    assert!(
        !lines(&mut s)
            .iter()
            .any(|l| l == "hot restart: the app kept its old routes")
    );
}

#[test]
fn a_router_that_stops_following_the_table_leaves_no_baseline() {
    // The app started with a router of its own: the table is not what it routes with.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0.clone()));
    let own_router = GenReport {
        stamp: Some(v0.clone()),
        swaps: false,
        ..report(false, true, false)
    };
    assert_eq!(requests(&pass(&mut s, 50, own_router)), [(1, false)]);
    respond(&mut s, 60, 1, "Reloaded 1 of 9 libraries");
    // A regeneration that wrote, with the router of its own: a restart, which compiles v1.
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let own_router_wrote = GenReport {
        swaps: false,
        ..wrote(v1.clone())
    };
    assert_eq!(requests(&pass(&mut s, 100, own_router_wrote)), [(2, true)]);
    respond(&mut s, 200, 2, "");
    // The user then lets `AppRoutes.router()` build it: this pass writes nothing, so it only
    // reloads, and the running app keeps its hand-built router.
    assert_eq!(
        requests(&pass(&mut s, 300, saved(v1.clone()))),
        [(3, false)]
    );
    respond(&mut s, 320, 3, "Reloaded 1 of 9 libraries");
    // The next regeneration restarts once, because nothing says the app follows the table ...
    let v2 = stamp(
        "2222222222222222",
        &[("a", "11111111"), ("b", "22222222"), ("c", "33333333")],
    );
    assert_eq!(requests(&pass(&mut s, 400, wrote(v2.clone()))), [(4, true)]);
    respond(&mut s, 500, 4, "");
    // ... and that restart sets the baseline: the one after it reloads.
    let v3 = stamp(
        "3333333333333333",
        &[
            ("a", "11111111"),
            ("b", "22222222"),
            ("c", "33333333"),
            ("d", "44444444"),
        ],
    );
    assert_eq!(requests(&pass(&mut s, 600, wrote(v3))), [(5, false)]);
}

#[test]
fn with_hot_reload_off_the_refusal_is_only_shown() {
    let mut s = state_with(true, false, &[]);
    connect(&mut s);
    app_start(&mut s, 1, true);
    app_started(&mut s, 2);
    s.drain_plain();
    let fx = s.update(ms(10), refusal(KEPT_CHANGED));
    assert!(requests(&fx).is_empty());
    assert_eq!(lines(&mut s).last().unwrap(), KEPT_CHANGED);
}

#[test]
fn kept_changed_is_the_runtime_message() {
    let dart = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../packages/fespalier/lib/src/routes_reload.dart"),
    )
    .unwrap();
    assert!(
        dart.contains(&format!("'{KEPT_CHANGED}'")),
        "routes_reload.dart prints another message"
    );
}

#[test]
fn a_flutter_run_again_starts_from_the_file_on_disk() {
    // Not plain: a flutter that stops by itself leaves the view open for `R`.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = started_from(Some(v0), false);
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    // v1 changes a kept name: the restart compiles it.
    let v1 = stamp("1111111111111111", &[("a", "22222222")]);
    assert_eq!(requests(&pass(&mut s, 100, wrote(v1.clone()))), [(1, true)]);
    s.update(
        ms(110),
        Input::Exited {
            pane: FLUTTER,
            status: exit(1),
        },
    );
    let fx = s.update(ms(120), Input::Key(Key::Char('R')));
    assert!(fx.contains(&Effect::Respawn), "{fx:?}");
    // The new flutter compiles the file on disk, which is v1.
    s.started(FLUTTER);
    app_start(&mut s, 130, true);
    app_started(&mut s, 140);
    let v2 = stamp("2222222222222222", &[("a", "22222222"), ("b", "33333333")]);
    assert_eq!(requests(&pass(&mut s, 200, wrote(v2))), [(2, false)]);
}

#[test]
fn a_regeneration_before_app_start_restarts() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = started_from(Some(v0), true);
    connect(&mut s);
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    // No app id yet: the request is held, not sent.
    assert!(requests(&pass(&mut s, 10, wrote(v1))).is_empty());
    // app.start sends it, as the restart it was.
    assert_eq!(requests(&app_start(&mut s, 20, true)), [(1, true)]);
}

#[test]
fn a_pass_that_fails_in_the_configuration_still_reloads_the_routes_and_keeps_the_error() {
    // The routes were written and a file of config/ was not (since 0.24.0): the app reloads the
    // new routes (not a restart for values that did not change), and the error stays on screen.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0));
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let line =
        "1 error(s) in config/; lib/app.config.g.dart left unchanged; lib/app.g.dart is up to date";
    let failed = GenReport {
        ok: false,
        routes: None,
        errors: 1,
        first_error: Some(FirstError {
            message: "`api.base_ur` is not in config/app.yaml".into(),
            loc: None,
        }),
        line: Some(line.into()),
        ..wrote(v1)
    };
    assert_eq!(requests(&pass(&mut s, 100, failed)), [(1, false)]);
    assert_eq!(s.generation.errors, 1);
    let said = s.drain_plain();
    assert!(said.iter().any(|l| l.text == line), "{said:?}");
    assert!(
        said.iter()
            .any(|l| l.text == "hot reload: lib/app.g.dart changed")
    );
    assert!(
        !said
            .iter()
            .any(|l| l.text.contains("app.config.g.dart changed"))
    );
}

/// A configuration whose one constant, `a`, is the value of each of `values`: `default`'s, then
/// the profiles' (since 0.24.1).
fn config(values: &[(&str, &str)]) -> Snapshot {
    let mut profiles: Vec<String> = values
        .iter()
        .map(|(profile, _)| (*profile).to_string())
        .filter(|profile| profile != "default")
        .collect();
    profiles.sort();
    Snapshot {
        profiles,
        constants: values
            .iter()
            .map(|(profile, value)| {
                let a = ("int".to_string(), (*value).to_string());
                ((*profile).to_string(), [("a".to_string(), a)].into())
            })
            .collect(),
    }
}

/// The configuration of the apps below: `dev` and `staging`.
fn three() -> Snapshot {
    config(&[("default", "1"), ("dev", "2"), ("staging", "3")])
}

/// The report of a pass that wrote the configuration alone, which now holds `config`, over routes
/// that hold `stamp`.
fn config_alone(stamp: Stamp, config: Snapshot) -> GenReport {
    GenReport {
        config_written: true,
        routes_wrote: false,
        config: Some(config),
        ..wrote(stamp)
    }
}

/// The report of a pass that wrote nothing, over a file of the configuration that holds `config`:
/// a save, or the pass after a `git checkout` that changed `config/` and the file together.
fn config_found(stamp: Stamp, config: Snapshot) -> GenReport {
    GenReport {
        config: Some(config),
        ..saved(stamp)
    }
}

/// A running app, plain, whose routes are `stamp`, that flutter started on a configuration that
/// holds `config`, and whose profile is `profile`, chosen by `choice`.
fn running_profile(stamp: Stamp, choice: Choice, profile: &str, config: Snapshot) -> DevState {
    let mut s = started_config(
        Some(stamp),
        true,
        true,
        Build::seen(choice, Some(profile)),
        Some(config),
    );
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    s
}

/// [`running_profile`] for `--profile staging` over [`three`].
fn running_staging(stamp: Stamp) -> DevState {
    let staging = Choice::new(Some("staging"), &[], None, true);
    running_profile(stamp, staging, "staging", three())
}

/// A restart or reload of `id` that flutter refused (a compile error).
fn refuse(s: &mut DevState, now: u64, id: u64) {
    s.update(
        ms(now),
        daemon(&format!(
            r#"[{{"id":{id},"result":{{"code":1,"message":"Compilation failed"}}}}]"#
        )),
    );
}

const RESTART: [&str; 2] = [
    "✓ 3 routes → lib/app.g.dart (3.0ms)",
    "hot restart: lib/app.config.g.dart changed",
];

const RELOAD: [&str; 2] = [
    "✓ 3 routes → lib/app.g.dart (3.0ms)",
    "hot reload: lib/app.config.g.dart changed",
];

#[test]
fn a_pass_that_writes_the_values_of_the_running_profile_restarts_the_app() {
    // Even when the routes would swap: a value of config/ read once (into a provider, a `static
    // final`) keeps its old value through a hot reload (since 0.24.0).
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_staging(v0.clone());
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    let fx = pass(&mut s, 100, config_alone(v0, edited));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(lines(&mut s), RESTART);
}

#[test]
fn a_pass_that_writes_only_another_profile_reloads_the_app() {
    // The app runs `staging`; `dev`'s values changed (since 0.24.1). `_profile` is a constant of
    // the running build's define, so no value the app has changed: a reload brings in the file.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_staging(v0.clone());
    let dev = |value: &str| config(&[("default", "1"), ("dev", value), ("staging", "3")]);
    let fx = pass(&mut s, 100, config_alone(v0.clone(), dev("5")));
    assert_eq!(requests(&fx), [(1, false)]);
    assert_eq!(lines(&mut s), RELOAD);
    respond(&mut s, 220, 1, "Reloaded 1 of 9 libraries");
    // With routes written too, the routes decide: these swap in, so a reload.
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let both = GenReport {
        config_written: true,
        config: Some(dev("6")),
        ..wrote(v1)
    };
    assert_eq!(requests(&pass(&mut s, 300, both)), [(2, false)]);
    assert!(
        s.drain_plain()
            .iter()
            .any(|l| l.text == "hot reload: lib/app.g.dart changed")
    );
    respond(&mut s, 400, 2, "Reloaded 2 of 9 libraries");
    // And routes that do not swap restart, for the routes.
    let v2 = stamp("2222222222222222", &[("a", "33333333"), ("b", "22222222")]);
    let both = GenReport {
        config_written: true,
        config: Some(dev("7")),
        ..wrote(v2)
    };
    assert_eq!(requests(&pass(&mut s, 500, both)), [(3, true)]);
    assert!(
        s.drain_plain()
            .iter()
            .any(|l| l.text == "hot restart: lib/app.g.dart changed")
    );
}

#[test]
fn a_profile_added_or_removed_restarts_the_app_and_chooses_its_profile_again() {
    // A debug build with no `dev` profile runs `default`; a `config/app.dev.yaml` made while it
    // runs makes it run `dev` after the restart (since 0.24.1), and the line says so.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let debug = Choice::new(None, &[], None, true);
    let alone = config(&[("default", "1")]);
    let mut s = running_profile(v0.clone(), debug, "default", alone);
    let added = config(&[("default", "1"), ("dev", "2")]);
    let fx = pass(&mut s, 100, config_alone(v0.clone(), added));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(
        lines(&mut s),
        [
            "✓ 3 routes → lib/app.g.dart (3.0ms)",
            "profile dev (a debug build): config/app.dev.yaml over config/app.yaml",
            "hot restart: lib/app.config.g.dart changed"
        ]
    );
    respond(&mut s, 200, 1, "Restarted");
    // `dev` is the profile it runs now: an edit of `config/app.yaml` that `dev` overrides reloads,
    let base = config(&[("default", "7"), ("dev", "2")]);
    assert_eq!(
        requests(&pass(&mut s, 300, config_alone(v0.clone(), base))),
        [(2, false)]
    );
    respond(&mut s, 400, 2, "Reloaded 1 of 9 libraries");
    // and an edit of `dev`'s file restarts.
    let dev = config(&[("default", "7"), ("dev", "8")]);
    assert_eq!(
        requests(&pass(&mut s, 500, config_alone(v0.clone(), dev.clone()))),
        [(3, true)]
    );
    respond(&mut s, 600, 3, "Restarted");
    s.drain_plain();
    // A profile added or removed restarts too, and the same profile is not said again.
    let prod = config(&[("default", "7"), ("dev", "8"), ("prod", "9")]);
    let fx = pass(&mut s, 700, config_alone(v0.clone(), prod));
    assert_eq!(requests(&fx), [(4, true)]);
    assert_eq!(lines(&mut s), RESTART);
    respond(&mut s, 800, 4, "Restarted");
    s.drain_plain();
    let fx = pass(&mut s, 900, config_alone(v0, dev));
    assert_eq!(requests(&fx), [(5, true)]);
    assert_eq!(lines(&mut s), RESTART);
}

#[test]
fn a_configuration_that_flutter_did_not_start_with_restarts_the_app() {
    // No `config/app.yaml` when flutter started: what the app was built from is not known, so a
    // write restarts.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_from(Some(v0.clone()));
    let made = config(&[("default", "1"), ("staging", "2")]);
    let fx = pass(&mut s, 100, config_alone(v0, made));
    assert_eq!(requests(&fx), [(1, true)]);
}

#[test]
fn a_configuration_the_app_did_not_start_with_restarts_it_though_the_pass_wrote_nothing() {
    // A `git checkout` that changes `config/app.staging.yaml` and the committed
    // `lib/app.config.g.dart` together (since 0.24.1): the pass finds the file current and writes
    // nothing, but the app was not built from it.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_staging(v0.clone());
    let checked_out = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    let fx = pass(&mut s, 100, config_found(v0.clone(), checked_out.clone()));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(lines(&mut s), RESTART);
    respond(&mut s, 200, 1, "Restarted");
    s.drain_plain();
    // Once the app has it, a save reloads, as any save does.
    let fx = pass(&mut s, 300, config_found(v0.clone(), checked_out));
    assert_eq!(requests(&fx), [(2, false)]);
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
    respond(&mut s, 400, 2, "Reloaded 1 of 9 libraries");
    // A checkout that changes only another profile's values reloads too: the app reads none of
    // them.
    let dev = config(&[("default", "1"), ("dev", "5"), ("staging", "4")]);
    let fx = pass(&mut s, 500, config_found(v0.clone(), dev));
    assert_eq!(requests(&fx), [(3, false)]);
    respond(&mut s, 600, 3, "Reloaded 1 of 9 libraries");
    // A first pass of the watcher that finds the configuration the app started with asks for
    // nothing, as before.
    let mut s = running_staging(v0.clone());
    let first = GenReport {
        first: true,
        ..config_found(v0.clone(), three())
    };
    assert!(requests(&pass(&mut s, 700, first)).is_empty());
    // And a build `fsp` cannot read restarts for any value it was not built from.
    let mut s = running_unseen(v0.clone(), three());
    let dev = config(&[("default", "1"), ("dev", "5"), ("staging", "3")]);
    let fx = pass(&mut s, 800, config_found(v0, dev));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(lines(&mut s), RESTART);
}

#[test]
fn a_restart_that_failed_leaves_the_values_the_app_has() {
    // The restart for an edit of the running profile fails (a compile error elsewhere, since
    // 0.24.1): the app keeps the values it read once, so the next save restarts again,
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_staging(v0.clone());
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    let fx = pass(&mut s, 100, config_alone(v0.clone(), edited.clone()));
    assert_eq!(requests(&fx), [(1, true)]);
    refuse(&mut s, 200, 1);
    s.drain_plain();
    let fx = pass(&mut s, 300, config_found(v0.clone(), edited));
    assert_eq!(requests(&fx), [(2, true)]);
    assert_eq!(lines(&mut s), RESTART);
    refuse(&mut s, 400, 2);
    s.drain_plain();
    // and so does a write of another profile's values,
    let dev = config(&[("default", "1"), ("dev", "5"), ("staging", "4")]);
    let fx = pass(&mut s, 500, config_alone(v0.clone(), dev.clone()));
    assert_eq!(requests(&fx), [(3, true)]);
    assert_eq!(lines(&mut s), RESTART);
    // until a restart brings them in: then a save reloads.
    respond(&mut s, 600, 3, "Restarted");
    let fx = pass(&mut s, 700, config_found(v0.clone(), dev));
    assert_eq!(requests(&fx), [(4, false)]);
    // An edit that puts back the values the app has after a restart that failed reloads: the
    // app has them.
    let mut s = running_staging(v0.clone());
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    assert_eq!(
        requests(&pass(&mut s, 100, config_alone(v0.clone(), edited))),
        [(1, true)]
    );
    refuse(&mut s, 200, 1);
    s.drain_plain();
    let fx = pass(&mut s, 300, config_alone(v0, three()));
    assert_eq!(requests(&fx), [(2, false)]);
    assert_eq!(lines(&mut s), RELOAD);
}

#[test]
fn a_restart_on_its_way_is_not_asked_again_for_the_configuration_it_brings() {
    // Sent and not answered: a save is covered by it, and only another value restarts again.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_staging(v0.clone());
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    let fx = pass(&mut s, 100, config_alone(v0.clone(), edited.clone()));
    assert_eq!(requests(&fx), [(1, true)]);
    s.drain_plain();
    assert!(requests(&pass(&mut s, 150, config_found(v0.clone(), edited))).is_empty());
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
    let again = config(&[("default", "1"), ("dev", "2"), ("staging", "5")]);
    let fx = pass(&mut s, 200, config_alone(v0.clone(), again.clone()));
    assert_eq!(requests(&fx), [(2, true)]);
    // The first answers and the second fails: the app has the first's values, so a save restarts
    // for the second's.
    respond(&mut s, 300, 1, "Restarted");
    refuse(&mut s, 350, 2);
    s.drain_plain();
    let fx = pass(&mut s, 400, config_found(v0.clone(), again.clone()));
    assert_eq!(requests(&fx), [(3, true)]);
    // Held for `app.start`: one restart, sent with the file as it is then.
    let mut s = started_config(
        Some(v0.clone()),
        true,
        true,
        Build::seen(
            Choice::new(Some("staging"), &[], None, true),
            Some("staging"),
        ),
        Some(three()),
    );
    connect(&mut s);
    assert!(requests(&pass(&mut s, 10, config_alone(v0.clone(), again.clone()))).is_empty());
    assert_eq!(lines(&mut s), RESTART);
    assert!(requests(&pass(&mut s, 20, config_found(v0, again))).is_empty());
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
    assert_eq!(requests(&app_start(&mut s, 30, true)), [(1, true)]);
}

/// A running app, plain, whose routes are `stamp`, that flutter started on a configuration that
/// holds `config`, and whose profile `fsp` cannot tell.
fn running_unseen(stamp: Stamp, config: Snapshot) -> DevState {
    let mut s = started_config(Some(stamp), true, true, Build::Unseen, Some(config));
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    s
}

#[test]
fn a_build_fsp_cannot_read_restarts_for_every_write_of_the_configuration() {
    // A `run:` of the pubspec's (`flutter run --flavor staging`) or a `--dart-define-from-file`
    // can choose a profile where `fsp` does not look (since 0.24.1): whatever profile `fsp` would
    // guess, a write restarts the app, as 0.24.0 did.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_unseen(v0.clone(), three());
    // Another profile's values, as far as `fsp` can tell.
    let other = config(&[("default", "1"), ("dev", "5"), ("staging", "3")]);
    assert_eq!(
        requests(&pass(&mut s, 100, config_alone(v0.clone(), other.clone()))),
        [(1, true)]
    );
    assert_eq!(lines(&mut s), RESTART);
    respond(&mut s, 200, 1, "Restarted");
    s.drain_plain();
    // A comment of config/app.yaml: no constant changed for any profile, and the file is written.
    assert_eq!(
        requests(&pass(&mut s, 300, config_alone(v0.clone(), other))),
        [(2, true)]
    );
    assert_eq!(lines(&mut s), RESTART);
    respond(&mut s, 400, 2, "Restarted");
    s.drain_plain();
    // The profiles changed: a restart, and no profile is chosen or said.
    let added = config(&[
        ("default", "1"),
        ("dev", "5"),
        ("prod", "6"),
        ("staging", "3"),
    ]);
    assert_eq!(
        requests(&pass(&mut s, 500, config_alone(v0.clone(), added))),
        [(3, true)]
    );
    assert_eq!(lines(&mut s), RESTART);
    respond(&mut s, 600, 3, "Restarted");
    s.drain_plain();
    // And the set of profiles does not bring the selective reload back: there is still no profile
    // to compare with.
    let later = config(&[
        ("default", "1"),
        ("dev", "5"),
        ("prod", "7"),
        ("staging", "3"),
    ]);
    assert_eq!(
        requests(&pass(&mut s, 700, config_alone(v0, later))),
        [(4, true)]
    );
    assert_eq!(lines(&mut s), RESTART);
}

#[test]
fn a_build_fsp_cannot_read_restarts_before_the_routes_decide() {
    // The configuration and the routes written together: the restart is the configuration's.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_unseen(v0, three());
    let v1 = stamp("1111111111111111", &[("a", "11111111"), ("b", "22222222")]);
    let both = GenReport {
        config_written: true,
        config: Some(config(&[("default", "1"), ("dev", "5"), ("staging", "3")])),
        ..wrote(v1)
    };
    assert_eq!(requests(&pass(&mut s, 100, both)), [(1, true)]);
    assert!(
        s.drain_plain()
            .iter()
            .any(|l| l.text == "hot restart: lib/app.config.g.dart changed")
    );
}

#[test]
fn a_new_profile_is_said_with_hot_reload_off_for_a_build_fsp_reads() {
    // `hot_reload: false` restarts nothing by itself, but the next `R` runs the profile the new
    // file makes (since 0.24.1), so the line is said and the profile is remembered.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let debug = Choice::new(None, &[], None, true);
    let mut s = started_config(
        Some(v0.clone()),
        true,
        false,
        Build::seen(debug, Some("default")),
        Some(config(&[("default", "1")])),
    );
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    let added = config(&[("default", "1"), ("dev", "2")]);
    let fx = pass(&mut s, 100, config_alone(v0.clone(), added.clone()));
    assert!(requests(&fx).is_empty());
    assert_eq!(
        lines(&mut s),
        [
            "✓ 3 routes → lib/app.g.dart (3.0ms)",
            "profile dev (a debug build): config/app.dev.yaml over config/app.yaml"
        ]
    );
    // The same profile is not said again.
    pass(&mut s, 200, config_alone(v0, added));
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
}

#[test]
fn a_build_fsp_cannot_read_says_no_profile_with_hot_reload_off() {
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = started_config(
        Some(v0.clone()),
        true,
        false,
        Build::Unseen,
        Some(config(&[("default", "1")])),
    );
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    let fx = pass(
        &mut s,
        100,
        config_alone(v0, config(&[("default", "1"), ("dev", "2")])),
    );
    assert!(requests(&fx).is_empty());
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
}

/// A running app, plain, whose routes are `stamp`, that flutter started when `config` was not
/// known (an error in `config/` or in the routes, or no `config/app.yaml` then), and whose profile
/// is `profile`, chosen by `choice` (since 0.24.1).
fn running_unknown(stamp: Stamp, choice: Choice, profile: &str) -> DevState {
    let mut s = started_config(
        Some(stamp),
        true,
        true,
        Build::seen(choice, Some(profile)),
        None,
    );
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.drain_plain();
    s
}

#[test]
fn a_restart_that_failed_over_an_unknown_baseline_is_asked_again() {
    // Flutter started while `config/app.staging.yaml` had a YAML error: the file it compiled is
    // the older one, and what the app was built from is not known (since 0.24.1). The first pass
    // that reads a clean configuration restarts the app,
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let staging = Choice::new(Some("staging"), &[], None, true);
    let mut s = running_unknown(v0.clone(), staging, "staging");
    let fx = pass(&mut s, 100, config_alone(v0.clone(), three()));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(lines(&mut s), RESTART);
    // and when that restart fails (a key was renamed and a reference no longer compiles), the
    // baseline is still unknown: the save that fixes the Dart writes nothing, and restarts again,
    refuse(&mut s, 200, 1);
    s.drain_plain();
    let fx = pass(&mut s, 300, config_found(v0.clone(), three()));
    assert_eq!(requests(&fx), [(2, true)]);
    assert_eq!(lines(&mut s), RESTART);
    // until a restart succeeds: then the app has the values, and a save reloads.
    respond(&mut s, 400, 2, "Restarted");
    s.drain_plain();
    let fx = pass(&mut s, 500, config_found(v0, three()));
    assert_eq!(requests(&fx), [(3, false)]);
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
}

#[test]
fn another_profile_reloads_once_a_restart_set_an_unknown_baseline() {
    // Flutter started on routes with an error, so the first generation never read `config/`
    // (since 0.24.1). The first pass that reads it restarts, though it wrote nothing,
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let staging = Choice::new(Some("staging"), &[], None, true);
    let mut s = running_unknown(v0.clone(), staging, "staging");
    let fx = pass(&mut s, 100, config_found(v0.clone(), three()));
    assert_eq!(requests(&fx), [(1, true)]);
    // and a save in flight with it does not restart it again,
    assert!(requests(&pass(&mut s, 150, config_found(v0.clone(), three()))).is_empty());
    respond(&mut s, 200, 1, "Restarted");
    s.drain_plain();
    // but once the restart succeeded, the rule of the baseline applies: an edit of another
    // profile (`dev`, while the app runs `staging`) reloads,
    let dev = config(&[("default", "1"), ("dev", "5"), ("staging", "3")]);
    let fx = pass(&mut s, 300, config_alone(v0.clone(), dev));
    assert_eq!(requests(&fx), [(2, false)]);
    assert_eq!(lines(&mut s), RELOAD);
    // and one of the profile it runs restarts.
    respond(&mut s, 400, 2, "Reloaded 1 of 9 libraries");
    let edited = config(&[("default", "1"), ("dev", "5"), ("staging", "4")]);
    let fx = pass(&mut s, 500, config_alone(v0, edited));
    assert_eq!(requests(&fx), [(3, true)]);
}

#[test]
fn an_unknown_baseline_held_for_app_start_restarts_once() {
    // Before `app.start` the restart is held, and a second pass for the same configuration does
    // not ask for another (since 0.24.1); a build `fsp` cannot read waits for it the same way.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    for build in [
        Build::seen(
            Choice::new(Some("staging"), &[], None, true),
            Some("staging"),
        ),
        Build::Unseen,
    ] {
        let mut s = started_config(Some(v0.clone()), true, true, build, None);
        connect(&mut s);
        assert!(requests(&pass(&mut s, 10, config_found(v0.clone(), three()))).is_empty());
        assert_eq!(lines(&mut s), RESTART);
        assert!(requests(&pass(&mut s, 20, config_found(v0.clone(), three()))).is_empty());
        assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
        assert_eq!(requests(&app_start(&mut s, 30, true)), [(1, true)]);
    }
}

#[test]
fn a_pass_that_read_no_configuration_over_an_unknown_baseline_restarts_for_a_write_only() {
    // No `config/app.yaml`, or an error in `config/`: the pass read nothing (since 0.24.1), so it
    // has no configuration to compare, and a write of the file restarts as before.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let staging = Choice::new(Some("staging"), &[], None, true);
    let mut s = running_unknown(v0.clone(), staging, "staging");
    assert_eq!(
        requests(&pass(&mut s, 100, saved(v0.clone()))),
        [(1, false)]
    );
    respond(&mut s, 200, 1, "Reloaded 1 of 9 libraries");
    s.drain_plain();
    let written = GenReport {
        config_written: true,
        routes_wrote: false,
        ..wrote(v0)
    };
    assert_eq!(requests(&pass(&mut s, 300, written)), [(2, true)]);
}

/// A running app, plain, that flutter started without hot restart (`--profile`, `--release` or
/// `--no-hot`), over a configuration that holds [`three`], run as `staging`.
fn running_without_restart(stamp: Stamp) -> DevState {
    let staging = Choice::new(Some("staging"), &[], None, true);
    let mut s = started_config(
        Some(stamp),
        true,
        true,
        Build::seen(staging, Some("staging")),
        Some(three()),
    );
    connect(&mut s);
    app_start(&mut s, 10, false);
    app_started(&mut s, 20);
    s.drain_plain();
    s
}

#[test]
fn a_run_without_restart_does_not_say_hot_restart_for_a_configuration() {
    // `flutter run --profile` says `supportsRestart: false`: a restart cannot be sent (since
    // 0.24.1), so no line says one is. Before this, every later save said it again, because the
    // app never took the values and the file always differed.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_without_restart(v0.clone());
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    let fx = pass(&mut s, 100, config_alone(v0.clone(), edited.clone()));
    assert!(requests(&fx).is_empty());
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
    for at in [200, 300, 400] {
        let fx = pass(&mut s, at, config_found(v0.clone(), edited.clone()));
        assert!(requests(&fx).is_empty());
        assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
    }
}

#[test]
fn a_stopped_flutter_does_not_say_hot_restart_for_a_configuration() {
    // The full-screen view after flutter exited (before `R`): nothing can be sent (since 0.24.1),
    // so no save says a restart is on its way.
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let staging = Choice::new(Some("staging"), &[], None, true);
    let mut s = started_config(
        Some(v0.clone()),
        false,
        true,
        Build::seen(staging, Some("staging")),
        Some(three()),
    );
    connect(&mut s);
    app_start(&mut s, 10, true);
    app_started(&mut s, 20);
    s.update(
        ms(30),
        Input::Exited {
            pane: FLUTTER,
            status: exit(1),
        },
    );
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    for at in [100, 200] {
        let fx = pass(&mut s, at, config_found(v0.clone(), edited.clone()));
        assert!(requests(&fx).is_empty());
    }
    let said: Vec<String> = s.panes()[FSP]
        .lines
        .iter()
        .map(|l| l.text.clone())
        .collect();
    assert!(said.iter().all(|l| !l.contains("hot restart")), "{said:?}");
}

#[test]
fn a_restart_that_is_sent_is_still_said() {
    // The line goes with the request: a run that can restart says it once, and a save the restart
    // covers does not say it again (since 0.24.1).
    let v0 = stamp("0000000000000000", &[("a", "11111111")]);
    let mut s = running_staging(v0.clone());
    let edited = config(&[("default", "1"), ("dev", "2"), ("staging", "4")]);
    let fx = pass(&mut s, 100, config_found(v0.clone(), edited.clone()));
    assert_eq!(requests(&fx), [(1, true)]);
    assert_eq!(lines(&mut s), RESTART);
    let fx = pass(&mut s, 200, config_found(v0, edited));
    assert!(requests(&fx).is_empty());
    assert_eq!(lines(&mut s), ["✓ 3 routes → lib/app.g.dart (3.0ms)"]);
}
