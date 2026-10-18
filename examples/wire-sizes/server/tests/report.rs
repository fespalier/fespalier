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
        "plain CBOR should be smaller than JSON on the wire"
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

    // This is the honest headline, and the one the totals hide: signing *replaces* a token rather
    // than adding to it. Pinned with a bound rather than an equality, because the exact figure moves
    // with the token's length and the protected header, and a test that broke on a 1-byte shift
    // would be noise — but a change of *direction* (a signature that started costing twice a token)
    // is exactly what a reader would need to know about.
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
