//! The journal: one row per call the engine accepted, the newest [`CAPACITY`] of them.
//!
//! A row says what a person needs to read what happened: the op, the idempotency key the call used, the outcome,
//! the sealed status and whether a sealed request went to the network. It never holds a payload: no arguments, no
//! body, no text from the server or the client. A call refused before anything was attempted (`BadInput`) has no row.

use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};

use super::{Answer, Error};

/// How many rows the journal keeps.
pub const CAPACITY: usize = 32;

/// How an accepted call ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The server sealed its answer, and it opened. The status is the sealed one.
    Answered,
    /// The server answered without a COSE envelope, with the row's status.
    Unsigned,
    /// The answer did not verify, so it is not the server's word.
    Unverified,
    /// The device key did not sign. Nothing sealed was sent.
    NotSigned,
    /// The device was not registered. Nothing sealed was sent.
    NotRegistered,
    /// The sealed request got no usable answer.
    Unreachable,
    /// The engine refused the call while it was sending it. Nothing sealed was sent.
    Rejected,
}

/// One row of the journal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// The op, one of the engine's own names.
    pub op: &'static str,
    /// The idempotency key the call used; empty for a read, which sends none.
    pub idempotency_key: String,
    /// How the call ended.
    pub outcome: Outcome,
    /// The HTTP status the server sealed or sent, when it answered.
    pub status: Option<u16>,
    /// Whether a sealed request went to the network (false when the device key or the registration refused first).
    pub sent: bool,
}

impl Entry {
    /// The row of a call that ended with `result`.
    pub(super) fn of(op: &'static str, key: &str, result: &Result<Answer, Error>) -> Self {
        let (outcome, status, sent) = match result {
            Ok(answer) => (Outcome::Answered, Some(answer.status), true),
            Err(Error::Unsigned { status }) => (Outcome::Unsigned, Some(*status), true),
            Err(Error::Unverified) => (Outcome::Unverified, None, true),
            Err(Error::Seal(_)) => (Outcome::NotSigned, None, false),
            Err(Error::Registration(_)) => (Outcome::NotRegistered, None, false),
            Err(Error::Transport(_)) => (Outcome::Unreachable, None, true),
            Err(Error::BadInput(_)) => (Outcome::Rejected, None, false),
        };
        Self {
            op,
            idempotency_key: key.to_owned(),
            outcome,
            status,
            sent,
        }
    }
}

/// The rows, under a lock that is never held across an await.
pub struct Journal {
    rows: Mutex<VecDeque<Entry>>,
}

impl Default for Journal {
    fn default() -> Self {
        Self {
            rows: Mutex::new(VecDeque::with_capacity(CAPACITY)),
        }
    }
}

impl Journal {
    /// Appends a row; past [`CAPACITY`] the oldest one goes.
    pub fn record(&self, entry: Entry) {
        let mut rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
        if rows.len() == CAPACITY {
            rows.pop_front();
        }
        rows.push_back(entry);
    }

    /// The rows, oldest first.
    #[must_use]
    pub fn entries(&self) -> Vec<Entry> {
        self.rows
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .cloned()
            .collect()
    }
}

#[cfg(test)]
#[path = "journal_tests.rs"]
mod tests;
