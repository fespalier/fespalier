//! Authkestra's device-signature profile v1 (RFC-014): its conformance vectors, the copy
//! `fespalier_sign_keypair` vendors (pinned by commit and SHA-256 in
//! `packages/fespalier_sign_keypair/test/fixtures/devsig-profile-v1/`), run through the verifier
//! this server calls, `authkestra_devsig::verify_at`, and then through the server's own rendering
//! of a refusal (`orders_demo_server::auth::refusal`). The verdicts are Authkestra's, which runs the
//! same vectors in its own tests; what this file pins is that the Dart client's copy and the
//! Authkestra commit the server is built on agree, and that every refusal leaves the server with
//! the status, the `error` member and the `DeviceSignature` challenge the client's table reads.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::time::{Duration, UNIX_EPOCH};

use authkestra_devsig::{
    InMemoryReplayStore, IssuerJwks, ReplayStore, SignedRequest, UnavailableReplayStore,
    VerifierConfig, verify_at,
};
use cratestack::serde_json::{self, Value};
use cratestack::{CratestackError, Value as CsValue};
use orders_demo_server::auth::refusal;

const VECTORS: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../packages/fespalier_sign_keypair/test/fixtures/devsig-profile-v1/vectors.json"
);

fn text<'a>(value: &'a Value, name: &str) -> &'a str {
    value[name]
        .as_str()
        .unwrap_or_else(|| panic!("{name} is not a string"))
}

#[tokio::test]
async fn every_vector_gets_the_profile_verdict_and_the_refusal_its_wire_form() {
    let raw = std::fs::read_to_string(VECTORS).expect("the vendored vectors");
    let vectors: Value = serde_json::from_str(&raw).expect("JSON");
    let verifier = &vectors["verifier"];
    let issuers: Vec<&str> = verifier["trusted_issuers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    let config = VerifierConfig::profile_v1(issuers.clone(), text(verifier, "audience"));
    assert_eq!(config.max_clock_skew.as_secs(), 30);
    assert_eq!(config.max_signature_lifetime.as_secs(), 300);
    let jwks = IssuerJwks::new();
    for key in vectors["issuer_keys"].as_array().unwrap() {
        let jwk = serde_json::from_value(key["jwk"].clone()).expect("a JWK");
        jwks.insert(issuers[0], text(key, "kid"), jwk).await;
    }

    let cases = vectors["vectors"].as_array().unwrap();
    assert_eq!(cases.len(), 44);
    for vector in cases {
        let id = text(vector, "id");
        let request = &vector["request"];
        let headers = request["headers"].as_object().unwrap();
        let header = |name: &str| headers.get(name).and_then(Value::as_str);
        let body = request["body"].as_str().unwrap_or_default();
        let now = UNIX_EPOCH + Duration::from_secs(vector["now"].as_u64().unwrap());
        let store: Box<dyn ReplayStore> = if vector["replay"]["store"] == "unavailable" {
            Box::new(UnavailableReplayStore)
        } else {
            Box::new(InMemoryReplayStore::new())
        };
        for jti in vector["replay"]["seen_jtis"].as_array().unwrap() {
            store
                .put_if_absent(jti.as_str().unwrap(), Duration::from_hours(1))
                .await
                .unwrap();
        }
        let outcome = verify_at(
            &SignedRequest {
                signature: header("X-Signature"),
                attestation: header("X-Attestation"),
                method: text(request, "method"),
                path: text(request, "path"),
                query: request["query"].as_str(),
                body: (!body.is_empty()).then_some(body.as_bytes()),
            },
            &config,
            &jwks,
            &*store,
            now,
        )
        .await;
        let expect = &vector["expect"];
        if expect["outcome"] == "accept" {
            let device = outcome.unwrap_or_else(|e| panic!("{id}: refused {}", e.code()));
            assert_eq!(device.subject, text(expect, "sub"), "{id}");
            assert_eq!(device.device, text(expect, "did"), "{id}");
            assert_eq!(device.key_thumbprint, text(expect, "jkt"), "{id}");
            assert_eq!(device.key_role().as_str(), text(expect, "role"), "{id}");
            continue;
        }
        let error = outcome.err().unwrap_or_else(|| panic!("{id}: accepted"));
        let code = text(expect, "error");
        assert_eq!(error.code(), code, "{id}");
        let wire = error.refusal();
        assert_eq!(
            i64::from(wire.status),
            expect["status"].as_i64().unwrap(),
            "{id}"
        );
        // The server's rendering: status, `error` member and challenge.
        let CratestackError::AuthRefused(rendered) = refusal(wire) else {
            panic!("{id}: not an AuthRefusal");
        };
        assert_eq!(
            rendered.members().get("error"),
            Some(&CsValue::String(code.to_owned())),
            "{id}"
        );
        assert_eq!(
            rendered.challenges(),
            [format!(r#"DeviceSignature error="{code}""#)],
            "{id}"
        );
    }
}
