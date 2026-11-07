//! The server end to end, in process: enrolment and renewal through Authkestra's handlers, signed
//! calls through `authkestra-devsig` inside the `AuthProvider`, the step-up rule (`@authn`),
//! revocation and idempotency, with a Rust device that signs the way Dart's `DeviceSigner` does.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

mod support;

use std::time::Duration;

use authkestra_devsig::DeviceIdentity;
use cratestack::axum::body::Body;
use cratestack::axum::http::{Request, StatusCode};
use cratestack::serde_json::{Value, json};
use jsonwebtoken::{Algorithm, DecodingKey, Validation};
use orders_demo_server::auth::{amr_of, principal_of};
use orders_demo_server::issuer::ISSUER;
use orders_demo_server::{Config, DEFAULT_ATTESTATION_TTL_SECS};
use support::{Device, Parts, Role, call, claims_of, header_of, now, send, world, world_with};

const PHONE: &str = "+237 6 55 00 00 00";

async fn enrolled(world: &support::World, user_present: bool) -> Device {
    let mut device = Device::new(1, user_present);
    let confirm = device.enrol(world, PHONE).await;
    assert_eq!(confirm.status, StatusCode::OK, "{:?}", confirm.json());
    device
}

#[tokio::test]
async fn enrolling_issues_an_attestation_per_key_in_the_profile_shape() {
    let world = world().await;
    let device = enrolled(&world, true).await;
    assert_eq!(world.built.shared.device_count(), 1);
    let issuer: jsonwebtoken::jwk::Jwk =
        cratestack::serde_json::from_value(world.built.hello.issuer_jwk.clone()).unwrap();
    let mut validation = Validation::new(Algorithm::EdDSA);
    validation.set_issuer(&[ISSUER]);
    for role in [Role::Ambient, Role::UserPresent] {
        let jws = &device.attestations[&role];
        jsonwebtoken::decode::<Value>(jws, &DecodingKey::from_jwk(&issuer).unwrap(), &validation)
            .expect("signed by the issuer the hello names");
        let head = header_of(jws);
        assert_eq!(head["typ"], "webank-attest+jws");
        assert_eq!(head["kid"], world.built.hello.issuer_jwk["kid"]);
        let claims = claims_of(jws);
        assert_eq!(
            claims["sub"], "user-237655000000",
            "derived from the phone, not sent"
        );
        assert_eq!(claims["did"], device.device_id.as_str());
        assert_eq!(claims["principal_type"], "device");
        assert_eq!(claims["att"]["status"], "active");
        let expected = if role == Role::Ambient {
            "ambient"
        } else {
            "user_present"
        };
        assert_eq!(claims["att"]["role"], expected);
        let ttl = i64::try_from(DEFAULT_ATTESTATION_TTL_SECS).unwrap();
        assert_eq!(
            claims["exp"].as_i64().unwrap() - claims["iat"].as_i64().unwrap(),
            ttl
        );
        // Authkestra computes `cnf.jkt` from the key that signed the challenge.
        let key = support::jwk(device.key(role));
        let key: jsonwebtoken::jwk::Jwk = cratestack::serde_json::from_value(key).unwrap();
        assert_eq!(
            claims["cnf"]["jkt"],
            key.thumbprint(jsonwebtoken::jwk::ThumbprintHash::SHA256)
                .unwrap()
        );
    }
}

#[tokio::test]
async fn a_wrong_code_or_phone_is_a_field_error_and_a_code_is_single_use() {
    let world = world().await;
    let device = Device::new(1, true);
    let phone = device.begin(&world, "hello", "123456").await;
    assert_eq!(phone.status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        phone.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("field 'phone'")
    );
    let wrong = device.begin(&world, PHONE, "000000").await;
    assert_eq!(wrong.status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        wrong.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("field 'otp'")
    );
    // No code was sent for this number: the right digits are refused too.
    let unsent = call(
        &world,
        "beginEnrolment",
        &json!({"args": {"phone": "+33 6 12 34 56 78", "otp": "123456",
            "ambient": support::jwk(&device.ambient)}}),
    )
    .await;
    assert_eq!(unsent.status, StatusCode::UNPROCESSABLE_ENTITY);
    let good = device.begin(&world, PHONE, "123456").await;
    assert_eq!(good.status, StatusCode::OK);
    let replay = call(
        &world,
        "beginEnrolment",
        &json!({"args": {"phone": PHONE, "otp": "123456", "ambient": support::jwk(&device.ambient)}}),
    )
    .await;
    assert_eq!(
        replay.status,
        StatusCode::UNPROCESSABLE_ENTITY,
        "the code was used"
    );
}

#[tokio::test]
async fn a_challenge_signed_by_another_key_does_not_enrol() {
    let world = world().await;
    let device = Device::new(1, false);
    let begin = device.begin(&world, PHONE, "123456").await.json();
    let confirm = call(
        &world,
        "confirmEnrolment",
        &json!({"args": {
            "enrolmentId": begin["enrolmentId"],
            "ambient": support::sign_challenge(&support::key(60), begin["ambient"].as_str().unwrap()),
        }}),
    )
    .await;
    assert_eq!(confirm.status, StatusCode::FORBIDDEN);
    assert_eq!(world.built.shared.device_count(), 0);
}

#[tokio::test]
async fn a_signed_read_works_and_an_unsigned_one_is_refused_by_the_policy() {
    let world = world().await;
    let device = enrolled(&world, false).await;
    let listed = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(listed.status, StatusCode::OK, "{:?}", listed.json());
    assert_eq!(listed.json()["orders"].as_array().unwrap().len(), 2);
    // No credential: anonymous, which `@allow(auth() != null)` refuses (CrateStack answers a
    // policy refusal 403). No profile code, so a client reads nothing into it.
    let unsigned = call(&world, "listOrders", &json!({"args": {}})).await;
    assert_eq!(unsigned.status, StatusCode::FORBIDDEN);
    assert_eq!(unsigned.error(), None);
    // Half a credential is the profile's `missing_credential`.
    let parts = Parts::rpc("listOrders", &json!({"args": {}}));
    let only = vec![(
        "x-attestation".to_owned(),
        device.attestations[&Role::Ambient].clone(),
    )];
    let half = send(&world.router, parts.request(&only)).await;
    assert_eq!(half.status, StatusCode::UNAUTHORIZED);
    assert_eq!(half.error().as_deref(), Some("missing_credential"));
    assert_eq!(
        half.challenges(),
        [r#"DeviceSignature error="missing_credential""#]
    );
}

#[tokio::test]
async fn a_replayed_or_changed_request_is_refused_with_the_profiles_code() {
    let world = world().await;
    let device = enrolled(&world, false).await;
    let parts = Parts::rpc("listOrders", &json!({"args": {}}));
    let headers = device.headers(Role::Ambient, &parts);
    assert_eq!(
        send(&world.router, parts.request(&headers)).await.status,
        StatusCode::OK
    );
    let replay = send(&world.router, parts.request(&headers)).await;
    assert_eq!(replay.error().as_deref(), Some("replay_detected"));

    let signed = Parts::rpc(
        "placeOrder",
        &json!({"args": {"item": "Tea", "quantity": 1}}),
    );
    let headers = device.headers(Role::Ambient, &signed);
    let mut tampered = signed.clone();
    tampered.body = support::cbor(&json!({"args": {"item": "Tea", "quantity": 99}}));
    let refused = send(&world.router, tampered.request(&headers)).await;
    assert_eq!(refused.status, StatusCode::UNAUTHORIZED);
    assert_eq!(refused.error().as_deref(), Some("body_mismatch"));
    let mut elsewhere = signed.clone();
    elsewhere.path = "/rpc/procedure.payOrder".to_owned();
    let refused = send(&world.router, elsewhere.request(&headers)).await;
    assert_eq!(refused.error().as_deref(), Some("path_mismatch"));
}

#[tokio::test]
async fn a_key_presented_with_another_keys_attestation_is_not_bound() {
    let world = world().await;
    let device = enrolled(&world, true).await;
    let parts = Parts::rpc("listOrders", &json!({"args": {}}));
    let headers = device.headers_with(
        device.key(Role::UserPresent),
        &device.attestations[&Role::Ambient],
        &parts,
    );
    let refused = send(&world.router, parts.request(&headers)).await;
    assert_eq!(refused.status, StatusCode::UNAUTHORIZED);
    assert_eq!(refused.error().as_deref(), Some("key_not_bound"));
}

#[tokio::test]
async fn paying_with_the_ambient_key_is_a_step_up_refusal_never_kept_under_its_key() {
    let world = world().await;
    let device = enrolled(&world, true).await;
    let mut parts = Parts::rpc("payOrder", &json!({"args": {"id": 1}}));
    parts.idempotency_key = Some("pay-1".to_owned());
    let refused = send(
        &world.router,
        parts.request(&device.headers(Role::Ambient, &parts)),
    )
    .await;
    assert_eq!(refused.status, StatusCode::UNAUTHORIZED);
    assert_eq!(
        refused.challenges(),
        [
            r#"Bearer error="insufficient_user_authentication", error_description="step-up authentication required""#
        ]
    );
    let body = refused.json();
    assert_eq!(body["error"], "insufficient_user_authentication");
    assert_eq!(body["details"]["amr"], json!(["user"]));
    assert_eq!(world.built.shared.recorded_count(), 0);

    let paid = send(
        &world.router,
        parts.request(&device.headers(Role::UserPresent, &parts)),
    )
    .await;
    assert_eq!(paid.status, StatusCode::OK, "{:?}", paid.json());
    assert_eq!(paid.json()["status"], "paid");
    // The retry is replayed, not run again (which would be a 409).
    let again = send(
        &world.router,
        parts.request(&device.headers(Role::UserPresent, &parts)),
    )
    .await;
    assert_eq!(again.status, StatusCode::OK);
    assert_eq!(again.json()["status"], "paid");
    assert_eq!(world.built.shared.recorded_count(), 1);
}

#[test]
fn the_principal_says_how_the_request_was_signed() {
    let identity = |role: &str| {
        DeviceIdentity::new(
            "user-1".to_owned(),
            "device-1".to_owned(),
            "thumb".to_owned(),
            json!({ "status": "active", "role": role }),
        )
    };
    let present = principal_of(&identity("user_present"), 1_700_000_000, 30, Some("k"));
    assert_eq!(present.subject().as_deref(), Some("user-1"));
    assert_eq!(present.amr(), Some(vec!["user", "pop"]));
    assert_eq!(
        present.auth_time(),
        Some(1_700_000_000 - 30 - 300),
        "the earliest the signature could be from"
    );
    assert_eq!(present.key_role(), Some(cratestack::KeyRole::UserPresent));
    assert_eq!(present.cnf_jkt(), Some("thumb"));
    let ambient = principal_of(&identity("ambient"), 1_700_000_000, 30, None);
    assert_eq!(ambient.amr(), Some(vec!["pop"]));
    assert_eq!(
        ambient.auth_time(),
        None,
        "the ambient key never tests the user"
    );
    assert_eq!(ambient.key_role(), Some(cratestack::KeyRole::Ambient));
    // A role Authkestra does not know reads as the ambient key: never a presence proof.
    let odd = principal_of(&identity("admin"), 1_700_000_000, 30, None);
    assert_eq!(odd.amr(), Some(vec!["pop"]));
    for role in [
        authkestra_devsig::KeyRole::Ambient,
        authkestra_devsig::KeyRole::UserPresent,
    ] {
        assert!(!amr_of(role).contains(&"hwk"), "not checked by this server");
    }
}

#[tokio::test]
async fn the_account_names_the_key_and_orders_belong_to_the_user() {
    let world = world().await;
    let first = enrolled(&world, true).await;
    let account = first
        .ambient(&world, "account", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(account["signedWith"], "ambient");
    assert_eq!(account["phone"], "+237655000000");
    let presence = first
        .call(&world, Role::UserPresent, "account", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(presence["signedWith"], "userPresent");
    first
        .ambient(
            &world,
            "placeOrder",
            &json!({"args": {"item": "Tea", "quantity": 3}}),
        )
        .await;
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
async fn an_idempotency_key_runs_a_write_once_per_user() {
    let world = world().await;
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
    let one = send(
        &world.router,
        first.request(&device.headers(Role::Ambient, &first)),
    )
    .await;
    assert_eq!(one.status, StatusCode::OK);
    let two = send(
        &world.router,
        first.request(&device.headers(Role::Ambient, &first)),
    )
    .await;
    assert_eq!(one.json(), two.json(), "a new signature, the kept answer");
    let listed = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await
        .json();
    assert_eq!(listed["orders"].as_array().unwrap().len(), 3);
    let other = place("k-1", 2);
    let conflict = send(
        &world.router,
        other.request(&device.headers(Role::Ambient, &other)),
    )
    .await;
    assert_eq!(conflict.status, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(
        conflict.json()["message"]
            .as_str()
            .unwrap()
            .starts_with("idempotency_key_conflict")
    );
    // An unsigned caller never reaches the store.
    let unsigned = place("k-2", 1);
    assert_eq!(
        send(&world.router, unsigned.request(&[])).await.status,
        StatusCode::FORBIDDEN
    );
    assert_eq!(world.built.shared.recorded_count(), 1);
}

#[tokio::test]
async fn an_expired_attestation_is_refused_and_renewed_by_a_proof_of_possession() {
    let world = world_with(Config {
        attestation_ttl_secs: 1,
        clock_skew_secs: 0,
        ..Config::default()
    })
    .await;
    let mut device = enrolled(&world, false).await;
    tokio::time::sleep(Duration::from_millis(2_100)).await;
    let expired = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(expired.status, StatusCode::UNAUTHORIZED);
    assert_eq!(expired.error().as_deref(), Some("attestation_expired"));
    assert_eq!(
        expired.challenges(),
        [r#"DeviceSignature error="attestation_expired""#]
    );
    let old = device.attestations[&Role::Ambient].clone();
    let renewed = device.renew(&world, Role::Ambient).await;
    assert_eq!(renewed.status, StatusCode::OK, "{:?}", renewed.json());
    assert_ne!(device.attestations[&Role::Ambient], old);
    assert!(
        claims_of(&device.attestations[&Role::Ambient])["exp"]
            .as_i64()
            .unwrap()
            >= now()
    );
}

#[tokio::test]
async fn a_renewal_needs_the_key_to_sign_the_challenge() {
    let world = world().await;
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
    let again = call(
        &world,
        "confirmRenewal",
        &json!({"args": {
            "challengeId": begin["challengeId"],
            "signature": support::sign_challenge(&device.ambient, begin["challenge"].as_str().unwrap()),
        }}),
    )
    .await;
    assert_eq!(
        again.status,
        StatusCode::NOT_FOUND,
        "a challenge is single use"
    );
}

#[tokio::test]
async fn revoking_ends_the_device_and_a_device_with_a_user_present_key_needs_it() {
    let world = world().await;
    let mut device = enrolled(&world, true).await;
    let input = json!({"args": {"deviceId": device.device_id}});
    let with_ambient = device
        .call(&world, Role::Ambient, "revokeDevice", &input)
        .await;
    assert_eq!(with_ambient.status, StatusCode::FORBIDDEN);
    assert!(!world.built.shared.is_revoked(&device.device_id));
    let revoked = device
        .call(&world, Role::UserPresent, "revokeDevice", &input)
        .await;
    assert_eq!(revoked.status, StatusCode::OK, "{:?}", revoked.json());
    for role in [Role::Ambient, Role::UserPresent] {
        let after = device
            .call(&world, role, "listOrders", &json!({"args": {}}))
            .await;
        assert_eq!(after.status, StatusCode::FORBIDDEN);
        assert_eq!(after.error().as_deref(), Some("device_revoked"));
        assert_eq!(
            after.challenges(),
            [r#"DeviceSignature error="device_revoked""#],
            "readable when the body is CBOR"
        );
    }
    assert_eq!(
        device.renew(&world, Role::Ambient).await.status,
        StatusCode::FORBIDDEN
    );
}

#[tokio::test]
async fn the_test_route_revokes_and_exists_only_when_asked_for() {
    let world = world().await;
    let device = enrolled(&world, false).await;
    let revoke = |id: &str| {
        Request::post("/test/revoke")
            .header("content-type", "application/json")
            .body(Body::from(json!({ "deviceId": id }).to_string()))
            .unwrap()
    };
    assert_eq!(
        send(&world.router, revoke("device-nope")).await.status,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        send(&world.router, revoke(&device.device_id)).await.status,
        StatusCode::NO_CONTENT
    );
    let after = device
        .ambient(&world, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(after.error().as_deref(), Some("device_revoked"));

    let plain = orders_demo_server::build(&Config::default()).await.unwrap();
    let missing = send(&plain.router, revoke(&device.device_id)).await;
    assert_ne!(missing.status, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn a_device_the_server_never_saw_is_not_active_and_cannot_renew() {
    // The same issuer seed, a new process: the attestation verifies, the device is unknown.
    let one = world().await;
    let mut device = enrolled(&one, false).await;
    let two = world().await;
    let answer = device
        .ambient(&two, "listOrders", &json!({"args": {}}))
        .await;
    assert_eq!(answer.status, StatusCode::UNAUTHORIZED);
    assert_eq!(answer.error().as_deref(), Some("device_not_active"));
    assert_eq!(
        device.renew(&two, Role::Ambient).await.status,
        StatusCode::FORBIDDEN
    );
}
