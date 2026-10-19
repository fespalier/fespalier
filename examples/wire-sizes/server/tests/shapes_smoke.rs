//! The new `measurePayload` op carries every shape through every variant.
//!
//! This shows that arbitrary payloads reach the server: without it the sweeps would measure only
//! the one shape `addNote` can express.

#![allow(clippy::expect_used, reason = "tests may expect")]

use wire_sizes_demo_server::Variant;
use wire_sizes_demo_server::payload::{Kind, Shape};
use wire_sizes_demo_server::report::BEARER_BASELINE;
use wire_sizes_demo_server::runner;

/// The bearer the plain variants need; the `cose` one signs instead.
fn bearer_for(variant: Variant) -> Option<&'static str> {
    match variant {
        Variant::Json | Variant::Cbor => Some(BEARER_BASELINE),
        Variant::Cose => None,
    }
}

#[tokio::test]
async fn every_shape_reaches_the_server() {
    for shape in Shape::all() {
        let payload = shape.build(Kind::Prose, 4096, 42);
        for variant in Variant::all() {
            let run = runner::run_payload(variant, &payload, bearer_for(variant))
                .await
                .expect("a run");
            let calls = run.of_op(runner::PAYLOAD_OP);
            let first = calls.first().expect("the payload call");
            assert_eq!(
                first.status,
                200,
                "{} as {} should be accepted",
                shape.name(),
                variant.name()
            );
            assert!(
                first.request_body_bytes > 0,
                "{} as {} should carry a body",
                shape.name(),
                variant.name()
            );
            // The registration is forgotten, so the run is the payload call alone.
            assert_eq!(
                calls.len(),
                1,
                "the run should hold only the payload call, got {}",
                calls.len()
            );
        }
    }
}

#[tokio::test]
async fn the_payload_shapes_differ_in_size() {
    // A guard against the shapes collapsing into the same thing: if `records` and `nested` produced
    // identical bytes, the shape dimension would be measuring nothing.
    let mut sizes = Vec::new();
    for shape in Shape::all() {
        let payload = shape.build(Kind::Prose, 8192, 7);
        let run = runner::run_payload(Variant::Cbor, &payload, Some(BEARER_BASELINE))
            .await
            .expect("a run");
        let calls = run.of_op(runner::PAYLOAD_OP);
        let bytes = calls.first().expect("the call").request_body_bytes;
        sizes.push((shape, bytes));
    }
    for (shape, bytes) in &sizes {
        assert!(*bytes > 0, "{} should weigh something", shape.name());
    }
    let distinct: std::collections::HashSet<usize> = sizes.iter().map(|(_, b)| *b).collect();
    assert!(
        distinct.len() >= 3,
        "the shapes should produce visibly different bodies, got {sizes:?}"
    );
}

#[tokio::test]
async fn a_large_payload_survives_the_round_trip() {
    // The megabyte sizes are where a body limit could quietly truncate, so the biggest size the
    // sweep uses is checked here rather than trusted.
    let payload = Shape::Records.build(Kind::Base64, 1024 * 1024, 11);
    // With a bearer: `measurePayload` requires auth, and without one the server answers `403`
    // before the body is considered — which is a test bug, not a payload finding.
    let run = runner::run_payload(Variant::Cbor, &payload, Some(BEARER_BASELINE))
        .await
        .expect("a run");
    let calls = run.of_op(runner::PAYLOAD_OP);
    let call = calls.first().expect("the call");
    assert_eq!(call.status, 200, "a 1 MB payload should be accepted");
    assert!(
        call.request_body_bytes > 1_000_000,
        "a 1 MB payload should arrive at about that size, got {}",
        call.request_body_bytes
    );
}
