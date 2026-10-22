//! The device signer: a signature passes, a `None` and a timeout both fail the signing.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::future::pending;

use cratestack::cose::{CoseSigner, P256Signer};

use super::*;

fn public_point() -> Vec<u8> {
    let signer = P256Signer::from_scalar(&[3; 32]).expect("a scalar");
    signer
        .verify_key()
        .p256_sec1_uncompressed()
        .expect("P-256")
        .to_vec()
}

#[tokio::test]
async fn a_signature_in_time_is_the_signature() {
    let sign: SignFn =
        Arc::new(|_: Vec<u8>| -> SignFuture { Box::pin(async { Some(vec![1; 64]) }) });
    let signer =
        device_signer_within(&public_point(), sign, Duration::from_secs(5)).expect("point");
    assert_eq!(signer.sign(b"tbs").await.expect("signed").len(), 64);
}

#[tokio::test]
async fn a_callback_that_answers_none_fails_the_signing() {
    let sign: SignFn = Arc::new(|_: Vec<u8>| -> SignFuture { Box::pin(async { None }) });
    let signer =
        device_signer_within(&public_point(), sign, Duration::from_secs(5)).expect("point");
    assert!(signer.sign(b"tbs").await.is_err());
}

#[tokio::test]
async fn a_callback_that_does_not_answer_in_time_fails_the_signing() {
    // Never answers: only the timeout can end the wait, so the outcome does not depend on the machine's speed.
    let sign: SignFn = Arc::new(|_: Vec<u8>| -> SignFuture { Box::pin(pending()) });
    let signer =
        device_signer_within(&public_point(), sign, Duration::from_millis(20)).expect("point");
    let error = signer.sign(b"tbs").await.expect_err("the timeout");
    assert!(error.to_string().contains(SIGN_REFUSED));
}

#[test]
fn the_production_timeout_is_ten_seconds() {
    assert_eq!(SIGN_TIMEOUT, Duration::from_secs(10));
}
