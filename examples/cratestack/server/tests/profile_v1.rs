//! Authkestra's device-signature profile v1 (RFC-014): its conformance vectors run through this
//! server's hand-written `verify::verify`, so the example and `fespalier_sign_keypair` agree on
//! one table. The vectors are the copy `fespalier_sign_keypair` vendors, pinned by commit and
//! SHA-256 (`packages/fespalier_sign_keypair/test/fixtures/devsig-profile-v1/`, whose Dart test
//! checks the pin).
//!
//! This server is its own issuer and holds ES256 issuer keys only, and takes ES256 device keys
//! only, so three vectors get another verdict, each listed in [`DIFFERENT`] with what it is
//! instead: every other vector must give exactly the profile's verdict.

#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::collections::HashMap;

use cratestack::serde_json::{self, Value};
use orders_demo_server::jose::Jwk;
use orders_demo_server::verify::{IssuerKey, Profile, Received, Refusal, Role, SeenJtis, verify};

const VECTORS: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../packages/fespalier_sign_keypair/test/fixtures/devsig-profile-v1/vectors.json"
);

/// The vectors this server answers differently, and its answer.
const DIFFERENT: [(&str, &str); 3] = [
    // An EdDSA issuer key: this server's key set is ES256 only, so its kid is not one of them.
    ("accept-eddsa-issuer", "unknown_kid"),
    // An RS256 issuer key: the same.
    ("accept-rs256-issuer", "unknown_kid"),
    // An EdDSA device key, which a verifier MAY accept (optional): this server takes ES256 only.
    ("accept-eddsa-device", "bad_alg"),
];

fn text<'a>(value: &'a Value, name: &str) -> &'a str {
    value[name]
        .as_str()
        .unwrap_or_else(|| panic!("{name} is not a string"))
}

#[test]
fn every_vector_gets_the_profile_verdict() {
    let raw = std::fs::read_to_string(VECTORS).expect("the vendored vectors");
    let vectors: Value = serde_json::from_str(&raw).expect("JSON");
    let verifier = &vectors["verifier"];
    let trusted = verifier["trusted_issuers"].as_array().unwrap();
    assert_eq!(trusted.len(), 1);
    assert_eq!(verifier["clock_skew_secs"], 30);
    assert_eq!(verifier["max_signature_lifetime_secs"], 300);
    let mut profile = Profile::new(text(verifier, "audience"), trusted[0].as_str().unwrap());
    assert_eq!(text(verifier, "signature_header"), "X-Signature");
    assert_eq!(text(verifier, "attestation_header"), "X-Attestation");
    profile.signature_header = "x-signature";
    profile.attestation_header = "x-attestation";

    let issuer_keys: Vec<IssuerKey> = vectors["issuer_keys"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|key| {
            let jwk = Jwk::parse(&key["jwk"])?;
            Some(IssuerKey {
                kid: text(key, "kid").to_owned(),
                key: jwk.verifying_key()?,
            })
        })
        .collect();
    assert_eq!(issuer_keys.len(), 1, "one ES256 issuer key");

    let different: HashMap<&str, &str> = DIFFERENT.into_iter().collect();
    let cases = vectors["vectors"].as_array().unwrap();
    assert_eq!(cases.len(), 44);
    let mut seen_different = 0;
    for vector in cases {
        let id = text(vector, "id");
        let request = &vector["request"];
        let headers = request["headers"].as_object().unwrap();
        let header = |name: &str| headers.get(name).and_then(Value::as_str);
        let body = request["body"].as_str().unwrap_or_default();
        let now = vector["now"].as_i64().unwrap();
        // A store that cannot be reached: this server's memory with no room for a jti.
        let mut seen = if vector["replay"]["store"] == "unavailable" {
            SeenJtis::with_capacity(0)
        } else {
            SeenJtis::default()
        };
        for jti in vector["replay"]["seen_jtis"].as_array().unwrap() {
            seen.remember(jti.as_str().unwrap(), now + 3600);
        }
        let outcome = verify(
            &profile,
            &issuer_keys,
            &Received {
                method: text(request, "method"),
                path: text(request, "path"),
                query: request["query"].as_str(),
                attestation: header("X-Attestation"),
                signature: header("X-Signature"),
                body: body.as_bytes(),
            },
            now,
            &mut seen,
        );
        let expect = &vector["expect"];
        let got = outcome.as_ref().map_err(|refusal| refusal.code());
        if let Some(instead) = different.get(id) {
            seen_different += 1;
            assert_eq!(got.err(), Some(*instead), "{id}");
            continue;
        }
        if expect["outcome"] == "accept" {
            let accepted = outcome.unwrap_or_else(|r| panic!("{id}: refused {}", r.code()));
            assert_eq!(accepted.subject, text(expect, "sub"), "{id}");
            assert_eq!(accepted.device_id, text(expect, "did"), "{id}");
            assert_eq!(accepted.jkt, text(expect, "jkt"), "{id}");
            let role = match text(expect, "role") {
                "user_present" => Role::UserPresent,
                _ => Role::Ambient,
            };
            assert_eq!(accepted.role, role, "{id}");
        } else {
            assert_eq!(got.err(), Some(text(expect, "error")), "{id}");
            assert_eq!(
                expect["status"], 401,
                "{id}: every verifier refusal is a 401"
            );
        }
    }
    assert_eq!(seen_different, DIFFERENT.len());
}

#[test]
fn the_refusal_codes_are_the_profiles() {
    let raw = std::fs::read_to_string(VECTORS).expect("the vendored vectors");
    let vectors: Value = serde_json::from_str(&raw).expect("JSON");
    let verifier_codes: Vec<&str> = vectors["refusals"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| row["produced_by"] == "verifier")
        .map(|row| text(row, "error"))
        .collect();
    let ours = [
        Refusal::MissingCredential,
        Refusal::Malformed,
        Refusal::BadAlg,
        Refusal::UntrustedIssuer,
        Refusal::UnknownKid,
        Refusal::BadAttestation,
        Refusal::AttestationExpired,
        Refusal::DeviceNotActive,
        Refusal::BadJwk,
        Refusal::KeyNotBound,
        Refusal::BadSignature,
        Refusal::SignatureExpired,
        Refusal::LifetimeTooLong,
        Refusal::Mismatch("mth"),
        Refusal::Mismatch("pth"),
        Refusal::Mismatch("aud"),
        Refusal::Mismatch("qsh"),
        Refusal::Mismatch("bdh"),
        Refusal::Replay,
    ]
    .map(Refusal::code);
    assert_eq!(ours.to_vec(), verifier_codes);
}
