//! The engine's events: what changed, for a listener (the app's `/core` page invalidates on them).
//!
//! The log keeps the last [`BACKLOG`] events and the live ones. Both change under one lock, so a listener that
//! subscribes at any time sees every event exactly once: the backlog first, then the rest.

use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};

use tokio::sync::broadcast;

/// How many events a listener that starts late is given, and how far a live listener may fall behind.
pub const BACKLOG: usize = 64;

/// What the engine reports.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// The device's key was registered with the server.
    Registered,
    /// The server stopped knowing the device's key (it refused a sealed call as unsigned), so the registration is
    /// gone. The next call registers again.
    Forgotten,
    /// A call the engine accepted ended, whatever its outcome (its journal row is written first). `op` is its op.
    Called { op: &'static str },
}

/// The events so far and the live ones.
pub struct EventLog {
    inner: Mutex<Log>,
}

struct Log {
    backlog: VecDeque<Event>,
    live: broadcast::Sender<Event>,
}

impl Default for EventLog {
    fn default() -> Self {
        let (live, _) = broadcast::channel(BACKLOG);
        Self {
            inner: Mutex::new(Log {
                backlog: VecDeque::with_capacity(BACKLOG),
                live,
            }),
        }
    }
}

impl EventLog {
    /// Records an event and tells the live listeners. With no listener it still stays in the backlog.
    pub fn emit(&self, event: Event) {
        let mut log = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if log.backlog.len() == BACKLOG {
            log.backlog.pop_front();
        }
        log.backlog.push_back(event.clone());
        // No listener is not an error: the backlog keeps the event.
        let _ = log.live.send(event);
    }

    /// The backlog, oldest first, and a receiver of the events after it.
    #[must_use]
    pub fn subscribe(&self) -> (Vec<Event>, broadcast::Receiver<Event>) {
        let log = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
        (log.backlog.iter().cloned().collect(), log.live.subscribe())
    }
}

#[cfg(test)]
#[path = "events_tests.rs"]
mod tests;
