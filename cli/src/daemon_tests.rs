//! The `flutter run --machine` protocol: each event `fsp dev` reads, parsed from a line built with
//! the field names flutter's own source uses (`flutter_tools` `daemon.dart`, `doc/daemon.md`).

use crate::daemon::{Event, Line, Msg, Reply, Response, parse_line, restart, stop};

fn events(line: &str) -> Vec<Event> {
    let Line::Messages(msgs) = parse_line(line) else {
        panic!("not messages: {line}");
    };
    msgs.into_iter()
        .map(|m| match m {
            Msg::Event(e) => e,
            Msg::Response(r) => panic!("a response: {r:?}"),
        })
        .collect()
}

fn one(line: &str) -> Event {
    let mut all = events(line);
    assert_eq!(all.len(), 1);
    all.remove(0)
}

#[test]
fn connected_carries_the_protocol_version() {
    assert_eq!(
        one(r#"[{"event":"daemon.connected","params":{"version":"0.6.1","pid":4242}}]"#),
        Event::Connected {
            version: Some("0.6.1".into())
        }
    );
}

#[test]
fn log_messages_keep_their_level() {
    assert_eq!(
        one(
            r##"[{"event":"daemon.logMessage","params":{"level":"error","message":"boom","stackTrace":"#1"}}]"##
        ),
        Event::LogMessage {
            level: "error".into(),
            message: "boom".into()
        }
    );
}

#[test]
fn app_start_says_whether_the_app_restarts() {
    assert_eq!(
        one(
            r#"[{"event":"app.start","params":{"appId":"a1","deviceId":"chrome","directory":"/p","supportsRestart":true,"launchMode":"run","mode":"debug"}}]"#
        ),
        Event::AppStart {
            app_id: "a1".into(),
            device_id: Some("chrome".into()),
            supports_restart: true,
            mode: Some("debug".into())
        }
    );
    let Event::AppStart {
        supports_restart, ..
    } = one(
        r#"[{"event":"app.start","params":{"appId":"a1","supportsRestart":false,"mode":"release"}}]"#,
    )
    else {
        panic!("not app.start");
    };
    assert!(!supports_restart);
}

#[test]
fn the_vm_service_devtools_and_started_events() {
    assert_eq!(
        one(
            r#"[{"event":"app.debugPort","params":{"appId":"a1","port":52341,"wsUri":"ws://127.0.0.1:52341/aBcD=/ws","baseUri":"x"}}]"#
        ),
        Event::DebugPort {
            app_id: "a1".into(),
            ws_uri: Some("ws://127.0.0.1:52341/aBcD=/ws".into())
        }
    );
    assert_eq!(
        one(r#"[{"event":"app.devTools","params":{"appId":"a1","uri":"http://127.0.0.1:9100/"}}]"#),
        Event::DevTools {
            uri: "http://127.0.0.1:9100/".into()
        }
    );
    assert_eq!(
        one(r#"[{"event":"app.started","params":{"appId":"a1"}}]"#),
        Event::Started {
            app_id: "a1".into()
        }
    );
}

#[test]
fn app_log_and_progress() {
    assert_eq!(
        one(r#"[{"event":"app.log","params":{"appId":"a1","log":"hi\n","error":true}}]"#),
        Event::Log {
            app_id: "a1".into(),
            log: "hi\n".into(),
            error: true
        }
    );
    assert_eq!(
        one(
            r#"[{"event":"app.progress","params":{"appId":"a1","id":"0","progressId":"hot.reload","message":"Performing hot reload...","finished":false}}]"#
        ),
        Event::Progress {
            message: Some("Performing hot reload...".into()),
            finished: false
        }
    );
    assert_eq!(
        one(r#"[{"event":"app.progress","params":{"appId":"a1","id":"0","finished":true}}]"#),
        Event::Progress {
            message: None,
            finished: true
        }
    );
}

#[test]
fn app_stop_may_carry_an_error() {
    assert_eq!(
        one(r#"[{"event":"app.stop","params":{"appId":"a1","error":"it broke","trace":"t"}}]"#),
        Event::Stop {
            app_id: "a1".into(),
            error: Some("it broke".into())
        }
    );
    assert_eq!(
        one(r#"[{"event":"app.stop","params":{"appId":"a1"}}]"#),
        Event::Stop {
            app_id: "a1".into(),
            error: None
        }
    );
}

#[test]
fn the_web_launch_url_has_no_app_id() {
    assert_eq!(
        one(
            r#"[{"event":"app.webLaunchUrl","params":{"url":"http://localhost:54321","launched":false}}]"#
        ),
        Event::WebLaunchUrl {
            url: "http://localhost:54321".into()
        }
    );
}

#[test]
fn an_unknown_event_is_other_and_a_missing_field_is_none() {
    assert_eq!(
        one(r#"[{"event":"app.dtd","params":{"appId":"a1","uri":"ws://x"}}]"#),
        Event::Other("app.dtd".into())
    );
    assert_eq!(
        one(r#"[{"event":"app.debugPort","params":{"appId":"a1"}}]"#),
        Event::DebugPort {
            app_id: "a1".into(),
            ws_uri: None
        }
    );
    // An event with no params at all.
    assert_eq!(
        one(r#"[{"event":"app.started"}]"#),
        Event::Started {
            app_id: String::new()
        }
    );
}

#[test]
fn two_messages_in_one_array() {
    let all = events(
        r#"[{"event":"app.started","params":{"appId":"a1"}},{"event":"app.log","params":{"appId":"a1","log":"x"}}]"#,
    );
    assert_eq!(all.len(), 2);
    assert!(matches!(all[0], Event::Started { .. }));
    assert!(matches!(all[1], Event::Log { .. }));
}

#[test]
fn a_response_with_a_result_and_one_with_an_error() {
    let Line::Messages(m) =
        parse_line(r#"[{"id":7,"result":{"code":0,"message":"Reloaded 3 of 512 libraries"}}]"#)
    else {
        panic!("not messages");
    };
    assert_eq!(
        m,
        vec![Msg::Response(Response {
            id: 7,
            outcome: Ok(Reply {
                code: 0,
                message: "Reloaded 3 of 512 libraries".into()
            })
        })]
    );
    let Line::Messages(m) = parse_line(r#"[{"id":8,"error":"app not found"}]"#) else {
        panic!("not messages");
    };
    let [Msg::Response(r)] = m.as_slice() else {
        panic!("one response");
    };
    assert_eq!(r.id, 8);
    assert!(r.failure().is_some());
    assert_eq!(r.failure().as_deref(), Some("app not found"));
}

#[test]
fn a_reply_with_a_non_zero_code_failed_and_a_true_result_worked() {
    let Line::Messages(m) =
        parse_line(r#"[{"id":1,"result":{"code":1,"message":"Hot reload was rejected"}}]"#)
    else {
        panic!("not messages");
    };
    let [Msg::Response(r)] = m.as_slice() else {
        panic!("one response");
    };
    assert!(r.failure().is_some());
    assert_eq!(r.failure().as_deref(), Some("Hot reload was rejected"));
    let Line::Messages(m) = parse_line(r#"[{"id":2,"result":true}]"#) else {
        panic!("not messages");
    };
    let [Msg::Response(r)] = m.as_slice() else {
        panic!("one response");
    };
    assert!(r.failure().is_none());
    assert_eq!(r.failure(), None);
}

#[test]
fn stray_text_and_malformed_json_are_text() {
    for line in [
        "Launching lib/main.dart on Pixel 8 in debug mode...",
        "[{\"event\":\"app.start\"",
        "[1, 2]",
        "[]",
        "{\"event\":\"app.start\"}",
        "[not json]",
        "",
    ] {
        assert_eq!(parse_line(line), Line::Text(line.to_string()), "{line:?}");
    }
}

#[test]
fn objects_that_are_neither_events_nor_responses_are_skipped() {
    assert_eq!(parse_line(r#"[{"hello":1}]"#), Line::Messages(vec![]));
}

#[test]
fn requests_are_encoded_byte_for_byte() {
    assert_eq!(
        restart(3, "a1", true, "save", true),
        r#"[{"id":3,"method":"app.restart","params":{"appId":"a1","fullRestart":true,"reason":"save","debounce":true}}]"#
    );
    assert_eq!(
        restart(4, "a1", false, "manual", false),
        r#"[{"id":4,"method":"app.restart","params":{"appId":"a1","fullRestart":false,"reason":"manual"}}]"#
    );
    assert_eq!(
        stop(5, "a1"),
        r#"[{"id":5,"method":"app.stop","params":{"appId":"a1"}}]"#
    );
}

#[test]
fn an_encoded_request_is_not_taken_for_a_response() {
    // It has "method", not "event" or a result: a request echoed back is skipped, not a response.
    assert_eq!(
        parse_line(&stop(5, "a1")),
        Line::Messages(vec![]),
        "a request has no event and no result"
    );
}
