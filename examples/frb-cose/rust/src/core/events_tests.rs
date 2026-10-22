//! The event log: the backlog is bounded, and a listener that subscribes late sees the backlog and then the rest.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use super::*;

#[test]
fn the_backlog_keeps_the_newest_events_and_is_bounded() {
    let log = EventLog::default();
    for _ in 0..BACKLOG + 3 {
        log.emit(Event::Registered);
    }
    log.emit(Event::Forgotten);
    let (backlog, _) = log.subscribe();
    assert_eq!(backlog.len(), BACKLOG);
    assert_eq!(backlog.last(), Some(&Event::Forgotten));
}

#[tokio::test]
async fn a_late_listener_sees_the_backlog_then_each_new_event_once() {
    let log = EventLog::default();
    log.emit(Event::Registered);
    let (backlog, mut live) = log.subscribe();
    assert_eq!(backlog, vec![Event::Registered]);

    log.emit(Event::Called { op: "addNote" });
    log.emit(Event::Forgotten);
    assert_eq!(
        live.recv().await.expect("an event"),
        Event::Called { op: "addNote" }
    );
    assert_eq!(live.recv().await.expect("an event"), Event::Forgotten);
}
