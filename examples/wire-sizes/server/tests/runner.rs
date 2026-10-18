//! The runner end to end: the same scenario through every variant, measured, and the two accounts
//! compared.
//!
//! These tests are the evidence that the runner *sends*. A runner that built requests and never
//! drove them would pass a unit test of its own helpers and produce a report of zero bytes; the
//! assertions here are on bytes that had to cross a router to exist.

use wire_sizes_demo_server::Variant;
use wire_sizes_demo_server::runner;
use wire_sizes_demo_server::scenario::{Run, Scenario};

/// A realistic-size token for the plain variants' baseline, so the run is authorized.
///
/// **Not a credential.** The server does not verify it; it is here because the plain variants have
/// no signature to identify their caller, so without a bearer they are refused before the payload
/// is ever reached. The comparison needs them to *succeed*, or it would measure a `403`.
const TOKEN: &str =
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

/// A small scenario, so the test is fast and its bytes are explainable.
fn scenario() -> Scenario {
    Scenario {
        reads: 2,
        writes: 2,
        note_text: "a note of a typical length".to_owned(),
    }
}

/// The credential a variant carries: the `cose` server signs instead of reading a header.
fn bearer_for(variant: Variant) -> Option<&'static str> {
    match variant {
        Variant::Json | Variant::Cbor => Some(TOKEN),
        Variant::Cose => None,
    }
}

async fn run_of(variant: Variant) -> Run {
    runner::run(variant, &scenario(), bearer_for(variant))
        .await
        .unwrap_or_else(|e| panic!("the {variant:?} run should work: {e}"))
}

#[tokio::test]
async fn every_variant_drives_the_whole_scenario() {
    for variant in Variant::all() {
        let run = run_of(variant).await;
        // Register, two writes, two reads.
        assert_eq!(
            run.exchanges.len(),
            1 + 2 + 2,
            "{variant:?} should have measured every call"
        );
        // Every call succeeded: this is a measurement of a working scenario, not of refusals.
        for exchange in &run.exchanges {
            assert_eq!(
                exchange.status, 200,
                "{variant:?}: {} {} -> {}",
                exchange.method, exchange.path, exchange.status
            );
        }
    }
}

#[tokio::test]
async fn a_run_measures_bytes_on_both_sides() {
    for variant in Variant::all() {
        let run = run_of(variant).await;
        assert!(
            run.server_request_total() > 0,
            "{variant:?} should have measured request bytes"
        );
        assert!(
            run.server_response_total() > 0,
            "{variant:?} should have measured response bytes"
        );
        // A body of zero bytes would mean the request never carried a payload.
        assert!(
            run.exchanges.iter().all(|e| e.request_body_bytes > 0),
            "{variant:?}: every call carries a payload"
        );
    }
}

#[tokio::test]
async fn the_cose_variant_carries_its_credential_in_the_body() {
    let run = run_of(Variant::Cose).await;
    for exchange in &run.exchanges {
        // The registration is plain by design; the rest are sealed.
        if exchange.path.ends_with("procedure.registerDevice") {
            continue;
        }
        assert!(
            !exchange.has_authorization(),
            "a sealed call carries no Authorization header: {}",
            exchange.path
        );
        assert_eq!(
            exchange.content_type(),
            Some(runner::SIGN1),
            "a sealed call is a COSE_Sign1 message"
        );
    }
    // And the run really is authorized: the credential is the signature, not a header, so an
    // all-succeeding run is the proof that the envelope layer accepted it.
    assert!(
        run.all_succeeded(),
        "every sealed call should have been accepted"
    );
}

#[tokio::test]
async fn the_plain_variants_carry_the_bearer_as_a_header() {
    for variant in [Variant::Json, Variant::Cbor] {
        let run = run_of(variant).await;
        for exchange in &run.exchanges {
            assert!(
                exchange.has_authorization(),
                "{variant:?}: the plain variants' credential is the header"
            );
            // `authorization: Bearer <token>\r\n`.
            assert_eq!(
                exchange.authorization_bytes(),
                "authorization".len() + 2 + "Bearer ".len() + TOKEN.len() + 2,
                "{variant:?}: the header counts its name, its value and its line ending"
            );
        }
    }
}

#[tokio::test]
async fn a_signed_body_weighs_more_than_the_payload_it_carries() {
    let json = run_of(Variant::Json).await;
    let cbor = run_of(Variant::Cbor).await;
    let cose = run_of(Variant::Cose).await;

    // The comparison the example exists for, asserted rather than merely printed: CBOR is smaller
    // than JSON, and signing that CBOR costs more again.
    assert!(
        cbor.server_request_total() < json.server_request_total(),
        "CBOR ({}) should be smaller than JSON ({})",
        cbor.server_request_total(),
        json.server_request_total()
    );
    assert!(
        cose.server_request_total() > cbor.server_request_total(),
        "a sealed call ({}) should weigh more than plain CBOR ({})",
        cose.server_request_total(),
        cbor.server_request_total()
    );
}

#[tokio::test]
async fn the_two_accounts_do_not_contradict_each_other() {
    for variant in Variant::all() {
        let run = run_of(variant).await;
        // The server's account is the only one there is, and it has to be internally consistent:
        // every total is the sum of its head and its body, and no part is ever larger than the
        // whole it belongs to. These hold by construction, which is exactly why they are worth
        // asserting — a refactor that double-counted a header would break one of them.
        for exchange in &run.exchanges {
            assert_eq!(
                exchange.request_total_bytes(),
                exchange.request_head_bytes() + exchange.request_body_bytes,
                "{variant:?}: a request total is its head plus its body"
            );
            assert_eq!(
                exchange.response_total_bytes(),
                exchange.response_head_bytes() + exchange.response_body_bytes,
                "{variant:?}: a response total is its head plus its body"
            );
            assert!(
                exchange.request_head_bytes() >= exchange.request_line_bytes(),
                "{variant:?}: the head contains the request line"
            );
        }
        assert_eq!(
            run.server_request_total(),
            run.exchanges
                .iter()
                .map(wire_sizes_demo_server::measure::Exchange::request_total_bytes)
                .sum::<usize>(),
            "{variant:?}: the run total is the sum of its exchanges"
        );
    }
}

#[tokio::test]
async fn a_run_can_be_read_back_by_op() {
    let run = run_of(Variant::Cbor).await;
    assert_eq!(run.of_op("procedure.listNotes").len(), 2);
    assert_eq!(run.of_op("procedure.addNote").len(), 2);
    assert_eq!(run.of_op("procedure.registerDevice").len(), 1);
}
