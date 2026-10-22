//! Checking a device-signed request: the profile of `fespalier_sign_keypair`
//! (`packages/fespalier_sign_keypair`, its README and `lib/verify.dart`), in Rust.
//!
//! A request carries two headers and no `Authorization`:
//!
//! - `X-Attestation`, a compact JWS this server's issuer signed earlier, with the claims `iss`,
//!   `sub`, `did`, `iat`, `exp`, `cnf.jkt` and `att` (the key role). On its own it is useless;
//! - `X-Signature`, a compact JWS made by the device's key: the header is `{"alg":"ES256","jwk":{..}}`
//!   and the claims are `iat`, `exp`, `jti`, `mth`, `pth`, `qsh`, `bdh` and `aud`.
//!
//! [`verify`] runs the checks in the order Dart's `verifyDeviceSignature` runs them, so a refusal
//! carries the same code, and the client's `webankRefusals` classifier reads it the same way.
//! It is pure: the clock and the single-use memory of `jti`s are arguments.

use std::collections::HashMap;

use cratestack::serde_json::{Map, Value};
use p256::ecdsa::VerifyingKey;

use crate::jose::{Jwk, sha256_hex, split, verify_es256};

/// How far a signature's clock may differ from this server's, in seconds.
pub const SKEW: i64 = 30;

/// The longest a signature may live (`exp - iat`), in seconds.
pub const MAX_LIFETIME: i64 = 300;

/// The two keys of a device, by what they are for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// Never prompts; signs every ordinary request.
    Ambient,
    /// Prompts the user (a biometric or the device credential) on every signature.
    UserPresent,
}

impl Role {
    /// The name on the wire and in the `att` claim: Dart's `KeyRole.name`.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Ambient => "ambient",
            Self::UserPresent => "userPresent",
        }
    }

    /// The role a wire name stands for.
    #[must_use]
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "ambient" => Some(Self::Ambient),
            "userPresent" => Some(Self::UserPresent),
            _ => None,
        }
    }
}

/// What this server expects of a request.
#[derive(Clone, Debug)]
pub struct Profile {
    /// The `aud` claim of a signature: the API it is for.
    pub audience: String,
    /// The `iss` claim of an attestation.
    pub issuer: String,
    /// The header that carries the attestation.
    pub attestation_header: &'static str,
    /// The header that carries the signature.
    pub signature_header: &'static str,
}

impl Profile {
    /// The defaults of `DeviceSignatureProfile`: `X-Attestation` and `X-Signature`.
    #[must_use]
    pub fn new(audience: &str, issuer: &str) -> Self {
        Self {
            audience: audience.to_owned(),
            issuer: issuer.to_owned(),
            attestation_header: "x-attestation",
            signature_header: "x-signature",
        }
    }
}

/// Why a request was refused. The codes are the ones Dart's `DeviceSignatureError` and
/// `webankRefusals` use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A header is missing or empty.
    MissingCredential,
    /// The attestation is not a JWS this server's issuer signed, or its claims are unreadable.
    BadAttestation,
    /// The attestation's `exp` has passed. The client renews it and sends again.
    AttestationExpired,
    /// The signature's `jwk` is not a public P-256 key, or `alg` is not ES256.
    BadJwk,
    /// The signature's `jwk` is not the key the attestation is bound to.
    KeyNotBound,
    /// The signature does not verify, or its claims are unreadable.
    BadSignature,
    /// The signature is too old, or dated in the future.
    SignatureExpired,
    /// The signature lives longer than five minutes.
    LifetimeTooLong,
    /// A claim disagrees with the request; the field names which.
    Mismatch(&'static str),
    /// The `jti` was used before.
    Replay,
    /// The memory of `jti`s is full of live ones. Not the caller's fault: a 503.
    Overloaded,
}

impl Refusal {
    /// The wire name: `{"error": code}`.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::MissingCredential => "missing_credential",
            Self::BadAttestation => "bad_attestation",
            Self::AttestationExpired => "attestation_expired",
            Self::BadJwk => "bad_jwk",
            Self::KeyNotBound => "key_not_bound",
            Self::BadSignature => "bad_signature",
            Self::SignatureExpired => "signature_expired",
            Self::LifetimeTooLong => "lifetime_too_long",
            Self::Mismatch(_) => "mismatch",
            Self::Replay => "replay",
            Self::Overloaded => "overloaded",
        }
    }
}

/// The single-use memory of `jti`s: each is kept until its signature can no longer pass the
/// freshness check anyway, then swept.
#[derive(Debug, Default)]
pub struct SeenJtis {
    until: HashMap<String, i64>,
}

impl SeenJtis {
    /// How many are held.
    #[must_use]
    pub fn len(&self) -> usize {
        self.until.len()
    }

    /// Whether none is held.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.until.is_empty()
    }

    fn contains(&self, jti: &str, now: i64) -> bool {
        self.until.get(jti).is_some_and(|until| *until > now)
    }

    fn insert(&mut self, jti: &str, until: i64, now: i64, capacity: usize) -> Result<(), Refusal> {
        if self.until.len() >= capacity {
            self.until.retain(|_, until| *until > now);
        }
        if self.until.len() >= capacity {
            return Err(Refusal::Overloaded);
        }
        self.until.insert(jti.to_owned(), until);
        Ok(())
    }
}

/// How many live `jti`s are held at most.
pub const JTI_CAPACITY: usize = 100_000;

/// The request as the server received it: the exact bytes, not a parsed form.
#[derive(Clone, Copy, Debug)]
pub struct Received<'a> {
    /// The HTTP method.
    pub method: &'a str,
    /// The path as sent.
    pub path: &'a str,
    /// The raw query, without the `?`.
    pub query: Option<&'a str>,
    /// The attestation header's value.
    pub attestation: Option<&'a str>,
    /// The signature header's value.
    pub signature: Option<&'a str>,
    /// The body bytes exactly as received.
    pub body: &'a [u8],
}

/// A request that passed every check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    /// The attestation's `sub`: who the device belongs to.
    pub subject: String,
    /// The attestation's `did`: which device.
    pub device_id: String,
    /// The attestation's `att`: which of the device's keys signed.
    pub role: Role,
    /// The thumbprint of the key that signed (the attestation's `cnf.jkt`).
    pub jkt: String,
    /// The signature's `jti`.
    pub jti: String,
}

fn int(claims: &Map<String, Value>, name: &str) -> Option<i64> {
    claims.get(name)?.as_i64()
}

fn text<'a>(claims: &'a Map<String, Value>, name: &str) -> Option<&'a str> {
    claims.get(name)?.as_str().filter(|text| !text.is_empty())
}

/// Checks a request the way a server does; the first check that fails is the refusal.
///
/// In order: both headers are there; the attestation is signed by one of `issuer_keys`, is this
/// server's (`iss`) and has not expired; the signature's `jwk` is a P-256 key whose thumbprint is
/// the attestation's `cnf.jkt`; the signature verifies; it is fresh (30 s of skew, a lifetime of
/// at most 300 s); `mth`, `pth`, `aud`, `qsh` and `bdh` match the request (a hash on one side
/// only is a mismatch); the `jti` was not used before. A `jti` is remembered only when everything
/// passed, so a refused request burns none.
///
/// # Errors
/// The [`Refusal`] of the first failed check.
pub fn verify(
    profile: &Profile,
    issuer_keys: &[VerifyingKey],
    request: &Received<'_>,
    now: i64,
    seen: &mut SeenJtis,
) -> Result<Verified, Refusal> {
    let (Some(attestation_jws), Some(signature_jws)) = (
        request.attestation.filter(|value| !value.is_empty()),
        request.signature.filter(|value| !value.is_empty()),
    ) else {
        return Err(Refusal::MissingCredential);
    };

    // 1. The attestation.
    let attestation = split(attestation_jws).ok_or(Refusal::BadAttestation)?;
    if attestation.header.get("alg").and_then(Value::as_str) != Some("ES256")
        || !issuer_keys.iter().any(|key| {
            verify_es256(
                key,
                attestation.signing_input.as_bytes(),
                &attestation.signature,
            )
        })
        || text(&attestation.claims, "iss") != Some(profile.issuer.as_str())
    {
        return Err(Refusal::BadAttestation);
    }
    let claims = &attestation.claims;
    let (Some(exp), Some(jkt), Some(subject), Some(device_id)) = (
        int(claims, "exp"),
        claims
            .get("cnf")
            .and_then(Value::as_object)
            .and_then(|cnf| text(cnf, "jkt")),
        text(claims, "sub"),
        text(claims, "did"),
    ) else {
        return Err(Refusal::BadAttestation);
    };
    let role = text(claims, "att")
        .and_then(Role::parse)
        .ok_or(Refusal::BadAttestation)?;
    if exp <= now {
        return Err(Refusal::AttestationExpired);
    }

    // 2. The key.
    let signature = split(signature_jws).ok_or(Refusal::BadSignature)?;
    let jwk = signature
        .header
        .get("jwk")
        .and_then(Jwk::parse)
        .filter(|_| signature.header.get("alg").and_then(Value::as_str) == Some("ES256"))
        .ok_or(Refusal::BadJwk)?;
    if jwk.thumbprint() != jkt {
        return Err(Refusal::KeyNotBound);
    }

    // 3. The signature.
    let key = jwk.verifying_key().ok_or(Refusal::BadJwk)?;
    if !verify_es256(
        &key,
        signature.signing_input.as_bytes(),
        &signature.signature,
    ) {
        return Err(Refusal::BadSignature);
    }

    // 4. Freshness.
    let (Some(iat), Some(exp)) = (int(&signature.claims, "iat"), int(&signature.claims, "exp"))
    else {
        return Err(Refusal::BadSignature);
    };
    if exp + SKEW <= now || iat - SKEW > now {
        return Err(Refusal::SignatureExpired);
    }
    if exp - iat > MAX_LIFETIME {
        return Err(Refusal::LifetimeTooLong);
    }

    // 5. The request.
    let signed = &signature.claims;
    let claim = |name: &str| signed.get(name).and_then(Value::as_str);
    if claim("mth") != Some(request.method.to_ascii_uppercase().as_str()) {
        return Err(Refusal::Mismatch("mth"));
    }
    let path = if request.path.is_empty() {
        "/"
    } else {
        request.path
    };
    if claim("pth") != Some(path) {
        return Err(Refusal::Mismatch("pth"));
    }
    if claim("aud") != Some(profile.audience.as_str()) {
        return Err(Refusal::Mismatch("aud"));
    }
    // Present on both sides or on neither: a hash the request does not call for is a mismatch too.
    let hash = |bytes: &[u8]| (!bytes.is_empty()).then(|| Value::String(sha256_hex(bytes)));
    if signed.get("qsh") != hash(request.query.unwrap_or_default().as_bytes()).as_ref() {
        return Err(Refusal::Mismatch("qsh"));
    }
    if signed.get("bdh") != hash(request.body).as_ref() {
        return Err(Refusal::Mismatch("bdh"));
    }

    // 6. Single use.
    let jti = text(signed, "jti").ok_or(Refusal::BadSignature)?;
    if seen.contains(jti, now) {
        return Err(Refusal::Replay);
    }
    seen.insert(jti, exp + SKEW, now, JTI_CAPACITY)?;
    Ok(Verified {
        subject: subject.to_owned(),
        device_id: device_id.to_owned(),
        role,
        jkt: jkt.to_owned(),
        jti: jti.to_owned(),
    })
}
