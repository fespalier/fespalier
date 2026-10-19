//! The committed report is the generated one.
//!
//! `REPORT.md` is generated, not written: the numbers in it come from the same run the other tests
//! drive. This test is what keeps that true — a change to the encoder, the measurement or the
//! scenario moves the numbers, and a report that was not regenerated then fails here instead of
//! being believed.
//!
//! Regenerate with:
//!
//! ```text
//! cargo run --release --bin wire-sizes-report > REPORT.md
//! ```

#![allow(clippy::expect_used, reason = "tests may expect")]

use wire_sizes_demo_server::Variant;
use wire_sizes_demo_server::measure::Exchange;
use wire_sizes_demo_server::report;
use wire_sizes_demo_server::scenario::Scenario;

/// The report as it is committed.
const COMMITTED: &str = include_str!("../REPORT.md");

#[tokio::test]
async fn the_committed_report_matches_a_fresh_measurement() {
    let fresh = report::generate().await.expect("a measurement");
    assert_eq!(
        fresh.trim_end(),
        COMMITTED.trim_end(),
        "REPORT.md is stale: regenerate it with \
         `cargo run --release --bin wire-sizes-report > REPORT.md`"
    );
}

#[tokio::test]
async fn the_report_holds_the_numbers_it_claims() {
    let runs = report::measure_all(&Scenario::default())
        .await
        .expect("a measurement");

    let find = |variant| {
        runs.iter()
            .find(|r| r.variant == variant)
            .unwrap_or_else(|| panic!("the {} run", variant.name()))
    };
    let json = find(Variant::Json);
    let cbor = find(Variant::Cbor);
    let cose = find(Variant::Cose);

    // The claims the report makes, checked here so a table cannot say one thing while the code
    // does another.
    assert!(
        cbor.server_request_total() < json.server_request_total(),
        "plain CBOR should be smaller than JSON"
    );
    assert!(
        cose.added_total() > 0,
        "a signature costs bytes, or the example has nothing to report"
    );
    // The credential is in the body for `cose` and in a header for the plain variants: the point
    // of the whole comparison, and the easiest thing for a refactor to quietly reverse.
    assert!(
        cose.exchanges.iter().all(|e| !e.has_authorization()),
        "a sealed call must carry no Authorization header"
    );
    assert!(
        json.exchanges.iter().all(Exchange::has_authorization),
        "the plain baseline's credential is the header"
    );
}

/// The finding a reader is most likely to get wrong without being told twice: the two halves move
/// in **opposite** directions, so a whole-request total says "cose is bigger" while an eye looking
/// at headers says "cose is thinner". Both are true, of different halves.
#[tokio::test]
async fn a_sealed_call_has_a_thinner_head_and_a_fatter_body() {
    let runs = report::measure_all(&Scenario::default())
        .await
        .expect("a measurement");

    let run_of = |variant| {
        runs.iter()
            .find(|r| r.variant == variant)
            .unwrap_or_else(|| panic!("the {} run", variant.name()))
    };
    let cbor = run_of(Variant::Cbor);
    let cose = run_of(Variant::Cose);

    // The same op, so the comparison is between credentials and not between payloads.
    let cbor_call = cbor.of_op("procedure.addNote");
    let cose_call = cose.of_op("procedure.addNote");
    let (cbor_call, cose_call) = (
        cbor_call.first().expect("a cbor addNote"),
        cose_call.first().expect("a cose addNote"),
    );

    assert!(
        cose_call.request_head_bytes() < cbor_call.request_head_bytes(),
        "a sealed call sends no Authorization header, so its head must be smaller: {} vs {}",
        cose_call.request_head_bytes(),
        cbor_call.request_head_bytes()
    );
    assert!(
        cose_call.request_body_bytes > cbor_call.request_body_bytes,
        "a sealed call carries its signature in the body, so its body must be larger: {} vs {}",
        cose_call.request_body_bytes,
        cbor_call.request_body_bytes
    );
    assert_eq!(
        cose_call.authorization_bytes(),
        0,
        "a sealed call has no Authorization header at all"
    );
    assert!(
        cbor_call.authorization_bytes() > 0,
        "the plain variant's credential is the header"
    );
}

#[tokio::test]
async fn the_signature_and_the_bearer_are_comparable_in_size() {
    let runs = report::measure_all(&Scenario::default())
        .await
        .expect("a measurement");

    let run_of = |variant| {
        runs.iter()
            .find(|r| r.variant == variant)
            .unwrap_or_else(|| panic!("the {} run", variant.name()))
    };
    let cbor = run_of(Variant::Cbor);
    let cose = run_of(Variant::Cose);

    // Signing replaces a token rather than adding to it, and the totals hide that. Pinned with a
    // bound rather than an equality, because the exact figure moves with the token's length and
    // the protected header, and a 1-byte shift should not fail the test; a change of direction
    // (a signature that started costing twice a token) should.
    let bearer = report::credential_bytes(cbor) / cbor.exchanges.len();
    let sealed_calls = cose.sealed().len();
    let signature = cose.added_total() / sealed_calls;

    assert!(
        signature < bearer * 2,
        "a signature ({signature} B) should stay comparable to the bearer it replaces \
         ({bearer} B), not several times it"
    );
    assert!(
        signature > bearer / 2,
        "a signature ({signature} B) should not be a rounding error beside the bearer \
         ({bearer} B)"
    );
}

/// The signature is fixed for every payload kind; JSON's penalty is not.
///
/// The **first version of this test was wrong**, and its error is worth keeping visible: it compared
/// the sweep's first and last rows, which were two sizes of one kind (`"x".repeat(n)`) and reported
/// that JSON's penalty never grows. Once the sweep measured payload *kinds*, that claim turned out
/// to hold for three of them and to be badly false for the fourth — `escapable` text costs JSON
/// roughly an extra byte per escaped character, so its penalty grows with the payload. The test now
/// says which of the two it expects, per kind, instead of generalising from the one payload that
/// happened to have nothing to escape.
#[tokio::test]
async fn the_signature_is_fixed_and_json_grows_only_on_escaped_text() {
    let sweep = report::measure_sweep().await.expect("a sweep");

    let body_of = |row: &report::SweepRow, variant| {
        row.runs
            .iter()
            .find(|r| r.variant == variant)
            .map_or(0, |r| {
                r.exchanges
                    .iter()
                    .map(|e| e.request_body_bytes)
                    .sum::<usize>()
            })
    };

    for kind in report::PayloadKind::all() {
        // Compare one kind's smallest and largest size. Comparing the sweep's first and last row
        // would compare two *kinds*, and so measure the payload rather than the size.
        let rows: Vec<&report::SweepRow> = sweep.iter().filter(|r| r.kind == kind).collect();
        let first = rows.iter().min_by_key(|r| r.note_bytes).expect("a first");
        let last = rows.iter().max_by_key(|r| r.note_bytes).expect("a last");
        assert!(
            last.note_bytes > first.note_bytes * 10,
            "the sweep should span an order of magnitude for {}",
            kind.name()
        );
        assert!(
            body_of(last, Variant::Cbor) > body_of(first, Variant::Cbor) * 10,
            "the CBOR body should grow with the note, for {}",
            kind.name()
        );

        // The signature: fixed, for every kind. That is what a 64-byte ESP256 signature looks like.
        let cose_first = body_of(first, Variant::Cose) - body_of(first, Variant::Cbor);
        let cose_last = body_of(last, Variant::Cose) - body_of(last, Variant::Cbor);
        assert!(
            cose_last.abs_diff(cose_first) <= 4,
            "the signature should stay fixed for {}: {cose_first} at {} bytes, {cose_last} at {}",
            kind.name(),
            first.note_bytes,
            last.note_bytes
        );

        let json_first = body_of(first, Variant::Json) - body_of(first, Variant::Cbor);
        let json_last = body_of(last, Variant::Json) - body_of(last, Variant::Cbor);
        if kind == report::PayloadKind::Escapable {
            assert!(
                json_last > json_first,
                "JSON's penalty should GROW on escapable text: {json_first} at {} bytes, \
                 {json_last} at {} bytes",
                first.note_bytes,
                last.note_bytes
            );
        } else {
            assert!(
                json_last <= json_first,
                "JSON's penalty should not grow on {} text: {json_first} at {} bytes, \
                 {json_last} at {} bytes",
                kind.name(),
                first.note_bytes,
                last.note_bytes
            );
        }
    }
}

/// The sizes a real app sends: 55 KB, 120 KB and 300 KB, measured because the answer is not
/// obvious. Both penalties stay in single- to triple-digit bytes, and JSON's *shrinks* slightly as
/// the CBOR length prefix grows — so "CBOR halves your payload" is wrong by two orders of magnitude
/// at these sizes.
#[tokio::test]
async fn large_payloads_still_show_a_fixed_cost() {
    let sweep = report::measure_sweep().await.expect("a sweep");

    let body_of = |row: &report::SweepRow, variant| {
        row.runs
            .iter()
            .find(|r| r.variant == variant)
            .map_or(0, |r| {
                r.exchanges
                    .iter()
                    .map(|e| e.request_body_bytes)
                    .sum::<usize>()
            })
    };

    for row in sweep
        .iter()
        .filter(|r| r.note_bytes >= 55 * 1024 && r.kind != report::PayloadKind::Escapable)
    {
        let json = body_of(row, Variant::Json) - body_of(row, Variant::Cbor);
        let cose = body_of(row, Variant::Cose) - body_of(row, Variant::Cbor);
        assert!(
            json < 32,
            "JSON's penalty on {} text should stay tens of bytes at {} note bytes, got {json}",
            row.kind.name(),
            row.note_bytes
        );
        assert!(
            cose < 160,
            "the signature should stay ~115 bytes at {} note bytes, got {cose}",
            row.note_bytes
        );
        assert!(
            row.runs
                .iter()
                .all(wire_sizes_demo_server::scenario::Run::all_succeeded),
            "every variant should answer 200 at {} note bytes",
            row.note_bytes
        );
    }
}

/// **The finding a degenerate payload hid, and the reason payload kind is a column.**
///
/// JSON must escape `"`, `\\`, `\n`, `\t` and every control byte; CBOR passes all of them through
/// raw. On text that is mostly escapable — a CRLF log, JSON inside JSON, a code sample — JSON's
/// penalty is not the fixed ~14 bytes the other kinds show but a large, *growing* one. The first
/// version of the sweep built payloads with `"x".repeat(n)` and reported the flat figure as if it
/// were general; it was a property of the one payload kind with nothing to escape.
#[tokio::test]
async fn an_escapable_payload_costs_json_far_more_and_it_scales() {
    let sweep = report::measure_sweep().await.expect("a sweep");

    let body_of = |row: &report::SweepRow, variant| {
        row.runs
            .iter()
            .find(|r| r.variant == variant)
            .map_or(0, |r| {
                r.exchanges
                    .iter()
                    .map(|e| e.request_body_bytes)
                    .sum::<usize>()
            })
    };
    let escapable = |note_bytes| {
        sweep
            .iter()
            .find(|r| r.kind == report::PayloadKind::Escapable && r.note_bytes == note_bytes)
            .unwrap_or_else(|| panic!("the {note_bytes}-byte escapable row"))
    };

    let small = escapable(1024);
    let large = escapable(300 * 1024);
    let small_penalty = body_of(small, Variant::Json) - body_of(small, Variant::Cbor);
    let large_penalty = body_of(large, Variant::Json) - body_of(large, Variant::Cbor);

    // It scales — the property the flat-14-bytes claim denied.
    assert!(
        large_penalty > small_penalty * 10,
        "JSON's penalty on escapable text should grow with the payload: {small_penalty} at 1 KB, \
         {large_penalty} at 300 KB"
    );
    // And it is a large fraction, not a rounding error: more than a tenth of the whole body. An
    // integer comparison, so no lossy `as f64` and no float rounding to argue with.
    let body = body_of(large, Variant::Cbor);
    assert!(
        large_penalty * 10 > body,
        "JSON should be >10% larger than CBOR on escapable text: {large_penalty} of {body} bytes"
    );
}

/// The three other kinds agree with each other, which is what makes the escapable one a finding
/// rather than noise — and what makes "JSON costs a fixed ~14 bytes" a true statement about them.
#[tokio::test]
async fn payloads_with_nothing_to_escape_cost_json_the_same() {
    let sweep = report::measure_sweep().await.expect("a sweep");

    let body_of = |row: &report::SweepRow, variant| {
        row.runs
            .iter()
            .find(|r| r.variant == variant)
            .map_or(0, |r| {
                r.exchanges
                    .iter()
                    .map(|e| e.request_body_bytes)
                    .sum::<usize>()
            })
    };

    for note_bytes in [1024_usize, 300 * 1024] {
        let penalties = |kind| {
            let row = sweep
                .iter()
                .find(|r| r.kind == kind && r.note_bytes == note_bytes)
                .unwrap_or_else(|| panic!("the {note_bytes}-byte {} row", kind.name()));
            body_of(row, Variant::Json) - body_of(row, Variant::Cbor)
        };
        let repeated = penalties(report::PayloadKind::Repeated);
        assert_eq!(
            repeated,
            penalties(report::PayloadKind::Prose),
            "prose should cost JSON what repeated text does at {note_bytes} bytes"
        );
        assert_eq!(
            repeated,
            penalties(report::PayloadKind::Base64),
            "base64 should cost JSON what repeated text does at {note_bytes} bytes"
        );
        let escapable = penalties(report::PayloadKind::Escapable);
        assert!(
            escapable > repeated * 10,
            "escapable text should be an order of magnitude worse at {note_bytes} bytes: \
             {escapable} vs {repeated}"
        );
    }
}
