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
