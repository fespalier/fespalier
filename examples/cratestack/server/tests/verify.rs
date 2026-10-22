//! `verify::verify` on its own: a request that is right passes, and each thing that can be wrong
//! with it is refused with the code Dart's `verifyDeviceSignature` and `webankRefusals` use.

#![allow(clippy::unused_self, reason = "a test rig")]
#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

mod support;

use cratestack::serde_json::{Value, json};
use orders_demo_server::jose::{Jwk, b64, sha256_hex, sign_compact};
use orders_demo_server::verify::{
    MAX_LIFETIME, Profile, Received, Refusal, Role, SKEW, SeenJtis, Verified, verify,
};
use orders_demo_server::{DEFAULT_AUDIENCE, ISSUER};
use p256::ecdsa::{SigningKey, VerifyingKey};

const NOW: i64 = 1_800_000_000;

struct Rig {
    issuer: SigningKey,
    device: SigningKey,
    profile: Profile,
}

/// A request to sign, and what to change in the claims.
#[derive(Clone)]
struct Req {
    method: &'static str,
    path: &'static str,
    query: Option<&'static str>,
    body: Vec<u8>,
}

fn req() -> Req {
    Req {
        method: "POST",
        path: "/rpc/procedure.placeOrder",
        query: None,
        body: b"{\"args\":{}}".to_vec(),
    }
}

impl Rig {
    fn new() -> Self {
        Self {
            issuer: support::key(1),
            device: support::key(2),
            profile: Profile::new(DEFAULT_AUDIENCE, ISSUER),
        }
    }

    fn issuer_keys(&self) -> Vec<VerifyingKey> {
        vec![*self.issuer.verifying_key()]
    }

    fn attestation(&self, exp: i64) -> String {
        sign_compact(
            &self.issuer,
            &json!({"alg": "ES256", "typ": "JWT"}),
            &json!({
                "iss": ISSUER, "sub": "user-1", "did": "device-1",
                "iat": NOW - 10, "exp": exp,
                "cnf": {"jkt": Jwk::of(self.device.verifying_key()).thumbprint()},
                "att": "ambient",
            }),
        )
    }

    /// Claims of a good signature for `r`; a test edits the object before it is signed.
    fn claims(r: &Req, jti: &str) -> Value {
        let mut claims = json!({
            "iat": NOW, "exp": NOW + 300, "jti": jti,
            "mth": r.method, "pth": r.path, "aud": DEFAULT_AUDIENCE,
        });
        if let Some(query) = r.query {
            claims["qsh"] = json!(sha256_hex(query.as_bytes()));
        }
        if !r.body.is_empty() {
            claims["bdh"] = json!(sha256_hex(&r.body));
        }
        claims
    }

    fn sign(&self, key: &SigningKey, claims: &Value) -> String {
        sign_compact(
            key,
            &json!({"alg": "ES256", "jwk": Jwk::of(key.verifying_key()).to_json()}),
            claims,
        )
    }

    fn check(
        &self,
        received: &Req,
        attestation: &str,
        signature: &str,
        seen: &mut SeenJtis,
    ) -> Result<Verified, Refusal> {
        verify(
            &self.profile,
            &self.issuer_keys(),
            &Received {
                method: received.method,
                path: received.path,
                query: received.query,
                attestation: Some(attestation),
                signature: Some(signature),
                body: &received.body,
            },
            NOW,
            seen,
        )
    }

    /// A signature for `signed`, checked against `received`.
    fn run(&self, signed: &Req, received: &Req) -> Result<Verified, Refusal> {
        let signature = self.sign(&self.device, &Rig::claims(signed, "jti-1"));
        self.check(
            received,
            &self.attestation(NOW + 3600),
            &signature,
            &mut SeenJtis::default(),
        )
    }
}

#[test]
fn a_good_request_passes() {
    let rig = Rig::new();
    let verified = rig.run(&req(), &req()).expect("accepted");
    assert_eq!(verified.subject, "user-1");
    assert_eq!(verified.device_id, "device-1");
    assert_eq!(verified.role, Role::Ambient);
    assert_eq!(verified.jti, "jti-1");
}

#[test]
fn a_good_request_with_a_query_and_no_body_passes() {
    let rig = Rig::new();
    let both = Req {
        method: "GET",
        path: "/rpc/x",
        query: Some("a=1&b=%20"),
        body: Vec::new(),
    };
    rig.run(&both, &both).expect("accepted");
}

#[test]
fn a_changed_body_is_refused() {
    let mut other = req();
    other.body = b"{\"args\":{\"x\":1}}".to_vec();
    assert_eq!(
        Rig::new().run(&req(), &other),
        Err(Refusal::Mismatch("bdh"))
    );
}

#[test]
fn a_body_the_signature_does_not_name_is_refused() {
    let signed = Req {
        body: Vec::new(),
        ..req()
    };
    assert_eq!(
        Rig::new().run(&signed, &req()),
        Err(Refusal::Mismatch("bdh"))
    );
    // And the other way: a hash for a body that never arrived.
    assert_eq!(
        Rig::new().run(&req(), &signed),
        Err(Refusal::Mismatch("bdh"))
    );
}

#[test]
fn a_changed_query_is_refused() {
    let signed = Req {
        query: Some("a=1"),
        ..req()
    };
    let other = Req {
        query: Some("a=2"),
        ..req()
    };
    assert_eq!(
        Rig::new().run(&signed, &other),
        Err(Refusal::Mismatch("qsh"))
    );
    // A query added after signing, or dropped.
    assert_eq!(
        Rig::new().run(&req(), &other),
        Err(Refusal::Mismatch("qsh"))
    );
    assert_eq!(
        Rig::new().run(&signed, &req()),
        Err(Refusal::Mismatch("qsh"))
    );
}

#[test]
fn a_changed_path_is_refused() {
    let other = Req {
        path: "/rpc/procedure.payOrder",
        ..req()
    };
    assert_eq!(
        Rig::new().run(&req(), &other),
        Err(Refusal::Mismatch("pth"))
    );
}

#[test]
fn a_changed_method_is_refused() {
    let other = Req {
        method: "PUT",
        ..req()
    };
    assert_eq!(
        Rig::new().run(&req(), &other),
        Err(Refusal::Mismatch("mth"))
    );
}

#[test]
fn another_audience_is_refused() {
    let rig = Rig::new();
    let mut claims = Rig::claims(&req(), "jti-1");
    claims["aud"] = json!("another-api");
    let signature = rig.sign(&rig.device, &claims);
    assert_eq!(
        rig.check(
            &req(),
            &rig.attestation(NOW + 60),
            &signature,
            &mut SeenJtis::default()
        ),
        Err(Refusal::Mismatch("aud"))
    );
}

#[test]
fn a_reused_jti_is_refused_but_a_refusal_burns_none() {
    let rig = Rig::new();
    let attestation = rig.attestation(NOW + 3600);
    let good = rig.sign(&rig.device, &Rig::claims(&req(), "same"));
    let mut seen = SeenJtis::default();
    // Refused for its body: the jti is not spent.
    let mut other = req();
    other.body = b"x".to_vec();
    assert_eq!(
        rig.check(&other, &attestation, &good, &mut seen),
        Err(Refusal::Mismatch("bdh"))
    );
    assert!(seen.is_empty());
    rig.check(&req(), &attestation, &good, &mut seen)
        .expect("first use");
    assert_eq!(seen.len(), 1);
    assert_eq!(
        rig.check(&req(), &attestation, &good, &mut seen),
        Err(Refusal::Replay)
    );
}

#[test]
fn an_old_signature_is_refused_but_skew_is_allowed() {
    let rig = Rig::new();
    let attestation = rig.attestation(NOW + 3600);
    let at = |iat: i64, exp: i64| {
        let mut claims = Rig::claims(&req(), "j");
        claims["iat"] = json!(iat);
        claims["exp"] = json!(exp);
        rig.sign(&rig.device, &claims)
    };
    let mut seen = SeenJtis::default();
    // Expired more than the skew ago.
    assert_eq!(
        rig.check(&req(), &attestation, &at(NOW - 400, NOW - SKEW), &mut seen),
        Err(Refusal::SignatureExpired)
    );
    // Dated further ahead than the skew.
    assert_eq!(
        rig.check(
            &req(),
            &attestation,
            &at(NOW + SKEW + 1, NOW + 100),
            &mut seen
        ),
        Err(Refusal::SignatureExpired)
    );
    // Within the skew on both sides.
    rig.check(
        &req(),
        &attestation,
        &at(NOW - 280, NOW - SKEW + 1),
        &mut seen,
    )
    .expect("a clock a little behind");
}

#[test]
fn a_signature_that_lives_too_long_is_refused() {
    let rig = Rig::new();
    let mut claims = Rig::claims(&req(), "j");
    claims["exp"] = json!(NOW + MAX_LIFETIME + 1);
    let signature = rig.sign(&rig.device, &claims);
    assert_eq!(
        rig.check(
            &req(),
            &rig.attestation(NOW + 60),
            &signature,
            &mut SeenJtis::default()
        ),
        Err(Refusal::LifetimeTooLong)
    );
}

#[test]
fn an_expired_attestation_is_the_renewable_refusal() {
    let rig = Rig::new();
    let signature = rig.sign(&rig.device, &Rig::claims(&req(), "j"));
    assert_eq!(
        rig.check(
            &req(),
            &rig.attestation(NOW),
            &signature,
            &mut SeenJtis::default()
        ),
        Err(Refusal::AttestationExpired)
    );
    assert_eq!(Refusal::AttestationExpired.code(), "attestation_expired");
}

#[test]
fn a_jwk_that_is_not_the_attested_key_is_refused() {
    let rig = Rig::new();
    let attestation = rig.attestation(NOW + 60);
    // Signed, validly, by another key than the one the attestation is bound to.
    let other = support::key(9);
    let signature = rig.sign(&other, &Rig::claims(&req(), "j"));
    assert_eq!(
        rig.check(&req(), &attestation, &signature, &mut SeenJtis::default()),
        Err(Refusal::KeyNotBound)
    );
}

#[test]
fn a_signature_that_does_not_verify_is_refused() {
    let rig = Rig::new();
    let attestation = rig.attestation(NOW + 60);
    // The right key in the header, a signature made over other claims.
    let genuine = rig.sign(&rig.device, &Rig::claims(&req(), "j"));
    let forged = rig.sign(&rig.device, &Rig::claims(&req(), "k"));
    let mut parts: Vec<&str> = genuine.split('.').collect();
    let tail = forged.rsplit('.').next().expect("signature");
    parts[2] = tail;
    assert_eq!(
        rig.check(
            &req(),
            &attestation,
            &parts.join("."),
            &mut SeenJtis::default()
        ),
        Err(Refusal::BadSignature)
    );
}

#[test]
fn an_attestation_from_another_issuer_is_refused() {
    let rig = Rig::new();
    let forged = sign_compact(
        &support::key(77),
        &json!({"alg": "ES256"}),
        &json!({
            "iss": ISSUER, "sub": "user-1", "did": "device-1", "exp": NOW + 60,
            "cnf": {"jkt": Jwk::of(rig.device.verifying_key()).thumbprint()},
            "att": "ambient",
        }),
    );
    let signature = rig.sign(&rig.device, &Rig::claims(&req(), "j"));
    assert_eq!(
        rig.check(&req(), &forged, &signature, &mut SeenJtis::default()),
        Err(Refusal::BadAttestation)
    );
}

#[test]
fn a_header_that_is_missing_is_refused() {
    let rig = Rig::new();
    let none = verify(
        &rig.profile,
        &rig.issuer_keys(),
        &Received {
            method: "POST",
            path: "/x",
            query: None,
            attestation: None,
            signature: None,
            body: b"",
        },
        NOW,
        &mut SeenJtis::default(),
    );
    assert_eq!(none, Err(Refusal::MissingCredential));
    assert_eq!(Refusal::MissingCredential.code(), "missing_credential");
}

#[test]
fn a_jwk_that_is_not_on_the_curve_is_bad() {
    let rig = Rig::new();
    let attestation = rig.attestation(NOW + 60);
    let signature = sign_compact(
        &rig.device,
        &json!({"alg": "ES256", "jwk": {
            "kty": "EC", "crv": "P-256", "x": b64(&[1; 32]), "y": b64(&[2; 32])
        }}),
        &Rig::claims(&req(), "j"),
    );
    assert_eq!(
        rig.check(&req(), &attestation, &signature, &mut SeenJtis::default()),
        Err(Refusal::BadJwk)
    );
}

#[test]
fn a_jwk_with_a_private_part_or_another_curve_is_bad() {
    let rig = Rig::new();
    let attestation = rig.attestation(NOW + 60);
    let mut jwk = Jwk::of(rig.device.verifying_key()).to_json();
    jwk["d"] = json!(b64(&[3; 32]));
    let signature = sign_compact(
        &rig.device,
        &json!({"alg": "ES256", "jwk": jwk}),
        &Rig::claims(&req(), "j"),
    );
    assert_eq!(
        rig.check(&req(), &attestation, &signature, &mut SeenJtis::default()),
        Err(Refusal::BadJwk)
    );
}
