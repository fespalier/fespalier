//! The journal: bounded, the newest rows kept, and each failure reads as its outcome. A row holds no payload.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use super::*;

fn row(op: &'static str, key: &str) -> Entry {
    Entry::of(
        op,
        key,
        &Ok(Answer {
            status: 200,
            retry_after: None,
            body_json: "{}".to_owned(),
        }),
    )
}

#[test]
fn the_journal_keeps_the_newest_rows_and_is_bounded() {
    let journal = Journal::default();
    for index in 0..CAPACITY + 3 {
        journal.record(row("listNotes", &index.to_string()));
    }
    let rows = journal.entries();
    assert_eq!(rows.len(), CAPACITY);
    assert_eq!(rows.first().map(|r| r.idempotency_key.as_str()), Some("3"));
    assert_eq!(
        rows.last().map(|r| r.idempotency_key.as_str()),
        Some((CAPACITY + 2).to_string().as_str())
    );
}

#[test]
fn each_ending_has_its_outcome_and_whether_a_sealed_request_went_out() {
    // (the result, the outcome it reads as, its status, whether a sealed request went out)
    type Case = (Result<Answer, Error>, Outcome, Option<u16>, bool);
    let cases: [Case; 8] = [
        (
            Ok(Answer {
                status: 400,
                retry_after: None,
                body_json: String::new(),
            }),
            Outcome::Answered,
            Some(400),
            true,
        ),
        (
            Err(Error::Unsigned { status: 401 }),
            Outcome::Unsigned,
            Some(401),
            true,
        ),
        (Err(Error::Unverified), Outcome::Unverified, None, true),
        (Err(Error::Seal("text")), Outcome::NotSigned, None, false),
        (
            Err(Error::Registration("text")),
            Outcome::NotRegistered,
            None,
            false,
        ),
        // A timeout, a dead connection or a failed read: the server may have run the request.
        (
            Err(Error::Transport("text")),
            Outcome::Unreachable,
            None,
            true,
        ),
        // The connection was never made: nothing went out.
        (
            Err(Error::Transport(error::UNREACHABLE)),
            Outcome::Unreachable,
            None,
            false,
        ),
        (Err(Error::BadInput("text")), Outcome::Rejected, None, false),
    ];
    for (result, outcome, status, sent) in cases {
        let entry = Entry::of("addNote", "k#0", &result);
        assert_eq!(entry.outcome, outcome, "{result:?}");
        assert_eq!(entry.status, status, "{result:?}");
        assert_eq!(entry.sent, sent, "{result:?}");
    }
}

#[test]
fn a_row_holds_no_payload() {
    let entry = Entry::of(
        "addNote",
        "k#0",
        &Ok(Answer {
            status: 200,
            retry_after: Some(5),
            body_json: "{\"text\":\"SECRET\"}".to_owned(),
        }),
    );
    assert!(!format!("{entry:?}").contains("SECRET"));
}
