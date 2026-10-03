//! What `fsp dev` decides, driven with `now` values and no I/O: the hot reload rules, the
//! shutdown, the device choice, the panes.

use std::time::Duration;

use crate::daemon::{self, Line};
use crate::dev_state::{
    DevState, Device, Effect, FLUTTER, FSP, Input, Key, Kind, Opts, Phase, Pick, Proc, RING,
    names_a_device, pick_device, strip_ansi,
};
use crate::procs::Status;
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
        device: Some(Device {
            id: "fake-1".into(),
            name: "Fake".into(),
            platform: "android-arm64".into(),
        }),
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

fn respond(s: &mut DevState, now: u64, id: u64, message: &str) {
    s.update(
        ms(now),
        daemon(&format!(
            r#"[{{"id":{id},"result":{{"code":0,"message":"{message}"}}}}]"#
        )),
    );
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
