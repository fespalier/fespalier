//! The server end to end, in process: enrolment, signed calls, the user-present rule, renewal,
//! revocation and idempotency, with a Rust device that signs the way Dart's `DeviceSigner` does.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

mod support;

use cratestack::axum::http::StatusCode;
use cratestack::serde_json::json;
use orders_demo_server::jose::{Jwk, split, verify_es256};
use orders_demo_server::verify::Role;
use orders_demo_server::{DEFAULT_ATTESTATION_TTL_SECS, ISSUER};
use support::{Device, Parts, call, claims_of, send, world};

const PHONE: &str = "+237 6 55 00 00 00";

async fn enrolled(world: &support::World, user_present: bool) -> Device {
    let mut device = Device::new(1, user_present);
    let confirm = device.enrol(world, PHONE).await;
    assert_eq!(confirm.status, StatusCode::OK, "{:?}", confirm.json());
    device
}

#[tokio::test]
async fn enrolling_issues_an_attestation_per_key_bound_to_it() {
    let world = world();
    let device = enrolled(&world, true).await;
    assert_eq!(world.built.shared.device_count(), 1);
    for role in [Role::Ambient, Role::UserPresent] {
        let jws = &device.attestations[&role];
        let compact = split(jws).expect("a compact JWS");
        assert!(
            verify_es256(
                &world.issuer(),
                compact.signing_input.as_bytes(),
                &compact.signature
            ),
            "signed by the issuer"
        );
        let claims = claims_of(jws);
        assert_eq!(claims["iss"], ISSUER);
        assert_eq!(
            claims["sub"], "user-237655000000",
            "derived from the phone, not sent"
        );
        assert_eq!(claims["did"], device.device_id.as_str());
        assert_eq!(claims["att"], role.name());
        assert_eq!(claims["iat"], world.now());
        assert_eq!(claims["exp"], world.now() + DEFAULT_ATTESTATION_TTL_SECS);
        assert_eq!(
            claims["cnf"]["jkt"],
            Jwk::of(device.key(role).verifying_key())
                .thumbprint()
                .as_str()
        );
    }
}

#[tokio::test]
async fn a_wrong_code_is_a_field_error_and_a_wrong_phone_too() {
    let world = world();
    let mut device = Device::new(1, false);
    let bad_phone = call(
        &world,
        "beginEnrolment",
        &json!({"args": {"phone": "hello", "ambient": Jwk::of(device.ambient.verifying_key()).to_json()}}),
    )
    .await;
    assert_eq!(bad_phone.status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        bad_phone.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("field 'phone'")
    );

    let begin = call(
        &world,
        "beginEnrolment",
        &json!({"args": {"phone": PHONE, "ambient": Jwk::of(device.ambient.verifying_key()).to_json()}}),
    )
    .await
    .json();
    let wrong = call(
        &world,
        "confirmEnrolment",
        &json!({"args": {
            "enrolmentId": begin["enrolmentId"],
            "otp": "000000",
            "ambient": support::sign_challenge(&device.ambient, begin["ambient"].as_str().unwrap()),
        }}),
    )
    .await;
    assert_eq!(wrong.status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        wrong.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("field 'otp'")
    );
    assert_eq!(world.built.shared.device_count(), 0);
    // The enrolment is still open for the right code.
    let confirm = device.enrol(&world, PHONE).await;
    assert_eq!(confirm.status, StatusCode::OK);
}

#[tokio::test]
async fn a_challenge_signed_by_another_key_does_not_enrol() {
    let world = world();
    let device = Device::new(1, false);
    let begin = call(
        &world,
        "beginEnrolment",
        &json!({"args": {"phone": PHONE, "ambient": Jwk::of(device.ambient.verifying_key()).to_json()}}),
    )
    .await
    .json();
    let confirm = call(
        &world,
        "confirmEnrolment",
        &json!({"args": {
            "enrolmentId": begin["enrolmentId"],
            "otp": orders_demo_server::DEMO_OTP,
            "ambient": support::sign_challenge(&support::key(50), begin["ambient"].as_str().unwrap()),
        }}),
    )
    .await;
    assert_eq!(confirm.status, StatusCode::FORBIDDEN);
    assert_eq!(world.built.shared.device_count(), 0);
}

#[tokio::test]
async fn a_signed_read_works_and_an_unsigned_one_is_refused() {
    let world = world();
    let device = enrolled(&world, false).await;
    let signed = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(signed.status, StatusCode::OK, "{:?}", signed.json());
    assert_eq!(signed.json()["orders"].as_array().unwrap().len(), 2);
    assert_eq!(world.built.shared.seen_jti_count(), 1);

    let unsigned = call(&world, "listOrders", &json!({"args": {}})).await;
    assert_eq!(unsigned.status, StatusCode::UNAUTHORIZED);
    assert_eq!(unsigned.error().as_deref(), Some("missing_credential"));
}

#[tokio::test]
async fn an_authorization_header_is_not_a_credential() {
    let world = world();
    let parts = Parts::rpc("listOrders", &json!({"args": {}}));
    let answer = send(
        &world.router,
        parts.request(&[("authorization".to_owned(), "Bearer anything".to_owned())]),
    )
    .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert_eq!(answer.error().as_deref(), Some("missing_credential"));
}

#[tokio::test]
async fn a_replayed_request_is_refused() {
    let world = world();
    let device = enrolled(&world, false).await;
    let parts = Parts::rpc("listOrders", &json!({"args": {}}));
    let headers = device.headers(&world, Role::Ambient, &parts, 0, 300);
    assert_eq!(
        send(&world.router, parts.request(&headers)).await.status,
        StatusCode::OK
    );
    let again = send(&world.router, parts.request(&headers)).await;
    assert_eq!(again.status, StatusCode::UNAUTHORIZED);
    assert_eq!(again.error().as_deref(), Some("replay"));
}

#[tokio::test]
async fn a_request_changed_after_signing_is_refused() {
    let world = world();
    let device = enrolled(&world, false).await;
    let signed = Parts::rpc(
        "placeOrder",
        &json!({"args": {"item": "Tea", "quantity": 1}}),
    );
    let headers = device.headers(&world, Role::Ambient, &signed, 0, 300);
    let mut tampered = signed.clone();
    tampered.body = support::cbor(&json!({"args": {"item": "Tea", "quantity": 99}}));
    let refused = send(&world.router, tampered.request(&headers)).await;
    assert_eq!(refused.status, StatusCode::UNAUTHORIZED);
    assert_eq!(refused.error().as_deref(), Some("mismatch"));
    let mut elsewhere = signed.clone();
    elsewhere.path = "/rpc/procedure.payOrder".to_owned();
    let refused = send(&world.router, elsewhere.request(&headers)).await;
    assert_eq!(refused.error().as_deref(), Some("mismatch"));
}

#[tokio::test]
async fn paying_needs_the_user_present_key() {
    let world = world();
    let device = enrolled(&world, true).await;
    let input = json!({"args": {"id": 1}});
    let refused = device.call(&world, Role::Ambient, "payOrder", &input).await;
    assert_eq!(refused.status, StatusCode::FORBIDDEN);
    assert!(
        refused.json()["message"]
            .as_str()
            .unwrap()
            .contains("user_presence_required")
    );
    let paid = device
        .call(&world, Role::UserPresent, "payOrder", &input)
        .await;
    assert_eq!(paid.status, StatusCode::OK, "{:?}", paid.json());
    assert_eq!(paid.json()["status"], "paid");
    let again = device
        .call(&world, Role::UserPresent, "payOrder", &input)
        .await;
    assert_eq!(again.status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn the_account_names_the_key_that_signed() {
    let world = world();
    let device = enrolled(&world, true).await;
    let ambient = device
        .ambient(&world, "account", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(ambient["signedWith"], "ambient");
    assert_eq!(ambient["phone"], "+237655000000");
    let presence = device
        .call(&world, Role::UserPresent, "account", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(presence["signedWith"], "userPresent");
}

#[tokio::test]
async fn orders_belong_to_the_user_not_the_device() {
    let world = world();
    let first = enrolled(&world, false).await;
    first
        .ambient(
            &world,
            "placeOrder",
            &json!({"args": {"item": "Tea", "quantity": 3}}),
        )
        .await;
    // Another device of the same phone sees it; another phone does not.
    let mut second = Device::new(2, false);
    assert_eq!(second.enrol(&world, PHONE).await.status, StatusCode::OK);
    let mine = second
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(mine["orders"].as_array().unwrap().len(), 3);
    let mut stranger = Device::new(3, false);
    assert_eq!(
        stranger.enrol(&world, "+33 6 12 34 56 78").await.status,
        StatusCode::OK
    );
    let theirs = stranger
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(theirs["orders"].as_array().unwrap().len(), 2);
}

#[tokio::test]
async fn a_bad_order_is_a_field_error() {
    let world = world();
    let device = enrolled(&world, false).await;
    let blank = device
        .ambient(
            &world,
            "placeOrder",
            &json!({"args": {"item": "  ", "quantity": 1}}),
        )
        .await;
    assert_eq!(blank.status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        blank.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("field 'item'")
    );
    let many = device
        .ambient(
            &world,
            "placeOrder",
            &json!({"args": {"item": "Tea", "quantity": 100}}),
        )
        .await;
    assert!(
        many.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("field 'quantity'")
    );
    let missing = device
        .ambient(&world, "getOrder", &json!({"args": {"id": 404}}))
        .await;
    assert_eq!(missing.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn an_idempotency_key_runs_a_write_once() {
    let world = world();
    let device = enrolled(&world, false).await;
    let place = |key: &str, quantity: i64| {
        let mut parts = Parts::rpc(
            "placeOrder",
            &json!({"args": {"item": "Tea", "quantity": quantity}}),
        );
        parts.idempotency_key = Some(key.to_owned());
        parts
    };
    let first = place("k-1", 1);
    let headers = device.headers(&world, Role::Ambient, &first, 0, 300);
    let one = send(&world.router, first.request(&headers)).await;
    assert_eq!(one.status, StatusCode::OK);
    // The retry is a new signature over the same bytes and the same key: replayed, not run again.
    let headers = device.headers(&world, Role::Ambient, &first, 0, 300);
    let two = send(&world.router, first.request(&headers)).await;
    assert_eq!(two.status, StatusCode::OK);
    assert_eq!(one.json(), two.json());
    let listed = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(
        listed["orders"].as_array().unwrap().len(),
        3,
        "two seeded, one placed"
    );
    // The same key with another body is the caller's bug.
    let other = place("k-1", 2);
    let headers = device.headers(&world, Role::Ambient, &other, 0, 300);
    let conflict = send(&world.router, other.request(&headers)).await;
    assert_eq!(conflict.status, StatusCode::UNPROCESSABLE_ENTITY);
    // A key an unsigned caller sends is dropped, never stored.
    let mut unsigned = place("k-2", 1);
    unsigned.idempotency_key = Some("k-2".to_owned());
    let refused = send(&world.router, unsigned.request(&[])).await;
    assert_eq!(refused.status, StatusCode::UNAUTHORIZED);
    assert_eq!(world.built.idempotency.len(), 1);
}

#[tokio::test]
async fn an_expired_attestation_is_renewed_by_a_proof_of_possession() {
    let world = world();
    let mut device = enrolled(&world, false).await;
    world.advance(DEFAULT_ATTESTATION_TTL_SECS + 1);
    let expired = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(expired.status, StatusCode::UNAUTHORIZED);
    assert_eq!(expired.error().as_deref(), Some("attestation_expired"));

    let old = device.attestations[&Role::Ambient].clone();
    let renewed = device.renew(&world, Role::Ambient).await;
    assert_eq!(renewed.status, StatusCode::OK, "{:?}", renewed.json());
    assert_ne!(device.attestations[&Role::Ambient], old);
    let claims = claims_of(&device.attestations[&Role::Ambient]);
    assert_eq!(claims["exp"], world.now() + DEFAULT_ATTESTATION_TTL_SECS);
    let ok = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(ok.status, StatusCode::OK);
}

#[tokio::test]
async fn a_renewal_needs_the_key_to_sign_the_challenge() {
    let world = world();
    let device = enrolled(&world, false).await;
    let begin = call(
        &world,
        "beginRenewal",
        &json!({"args": {"deviceId": device.device_id, "role": "ambient"}}),
    )
    .await
    .json();
    let confirm = call(
        &world,
        "confirmRenewal",
        &json!({"args": {
            "challengeId": begin["challengeId"],
            "signature": support::sign_challenge(&support::key(60), begin["challenge"].as_str().unwrap()),
        }}),
    )
    .await;
    assert_eq!(confirm.status, StatusCode::FORBIDDEN);
    // A challenge is single use: the right signature on the same one finds nothing.
    let again = call(
        &world,
        "confirmRenewal",
        &json!({"args": {
            "challengeId": begin["challengeId"],
            "signature": support::sign_challenge(&device.ambient, begin["challenge"].as_str().unwrap()),
        }}),
    )
    .await;
    assert_eq!(again.status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn revoking_ends_the_device_and_a_device_with_a_user_present_key_needs_it() {
    let world = world();
    let mut device = enrolled(&world, true).await;
    let input = json!({"args": {"deviceId": device.device_id}});
    let with_ambient = device
        .call(&world, Role::Ambient, "revokeDevice", &input)
        .await;
    assert_eq!(with_ambient.status, StatusCode::FORBIDDEN);
    assert!(!world.built.shared.is_revoked(&device.device_id));

    let elsewhere = device
        .call(
            &world,
            Role::UserPresent,
            "revokeDevice",
            &json!({"args": {"deviceId": "device-other"}}),
        )
        .await;
    assert_eq!(
        elsewhere.status,
        StatusCode::FORBIDDEN,
        "a device revokes itself only"
    );

    let revoked = device
        .call(&world, Role::UserPresent, "revokeDevice", &input)
        .await;
    assert_eq!(revoked.status, StatusCode::OK, "{:?}", revoked.json());
    assert!(world.built.shared.is_revoked(&device.device_id));

    // Every later request, of either key, is the 403 the client reads as "revoked", and so is a renewal.
    for role in [Role::Ambient, Role::UserPresent] {
        let after = device
            .call(&world, role, "listOrders", &json!({"args": {}}))
            .await;
        assert_eq!(after.status, StatusCode::FORBIDDEN);
        assert_eq!(after.error().as_deref(), Some("DEVICE_REVOKED"));
    }
    assert_eq!(
        device.renew(&world, Role::Ambient).await.status,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn a_device_the_server_never_saw_is_not_active_and_cannot_renew() {
    // An attestation the issuer signed, for a device this process has no record of (a restart).
    let one = world();
    let device = enrolled(&one, false).await;
    let two = world();
    let answer = device
        .ambient(&two, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert_eq!(answer.error().as_deref(), Some("device_not_active"));
    let mut device = device;
    assert_eq!(
        device.renew(&two, Role::Ambient).await.status,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn a_refusal_carries_both_the_device_code_and_crates_envelope() {
    let world = world();
    let answer = call(&world, "listOrders", &json!({"args": {}})).await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    let body = answer.json();
    assert_eq!(body["error"], "missing_credential");
    assert_eq!(body["code"], "unauthenticated");
    assert!(body["message"].is_string());
}
