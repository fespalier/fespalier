//! Checking a device-signed request: Authkestra's device-signature profile v1 (RFC-014), the
//! profile `fespalier_sign_keypair` follows (`packages/fespalier_sign_keypair`, its README and
//! `lib/verify.dart`), in Rust. Hand-written, not Authkestra's crate: replacing it is fespalier#310.
//!
//! A request carries two headers and no `Authorization`:
//!
//! - `X-Attestation`, a compact JWS this server's issuer signed earlier: the header has `alg` and the
//!   issuer key's `kid`, the claims are `iss`, `sub`, `did`, `iat`, `exp`, `cnf.jkt` and `att`, an
//!   object with `status` (`"active"`) and, for the user-present key, `role: "user_present"`. On
//!   its own it is useless;
//! - `X-Signature`, a compact JWS made by the device's key: the header is `{"alg":"ES256","jwk":{..}}`
//!   and the claims are `iat`, `exp`, `jti`, `mth`, `pth`, `qsh`, `bdh` and `aud`.
//!
//! [`verify`] runs the checks in the profile's order (Dart's `verifyDeviceSignature` runs the same),
//! so a refusal carries the same code, and the client's `webankRefusals` classifier reads it the
//! same way. It is pure: the clock and the single-use memory of `jti`s are arguments.
//!
//! What this server does not do of what the profile allows: its issuer key set holds `ES256` keys
//! only (it is its own issuer), so an `EdDSA` or `RS256` attestation names a `kid` it does not have
//! (`unknown_kid`); and devices sign `ES256` only (an `EdDSA` device key, which a verifier MAY accept,
//! is `bad_alg`). `tests/profile_v1.rs` runs the profile's vectors and lists those three.

use std::collections::HashMap;

use cratestack::serde_json::{Map, Value};
use p256::ecdsa::VerifyingKey;

use crate::jose::{Compact, Jwk, sha256_hex, split, verify_es256};

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
    /// The name in this server's procedures (`beginRenewal`'s `role`, `signedWith`): Dart's
    /// `KeyRole.name`. Never the `att.role` of an attestation, which is [`Role::att`].
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Ambient => "ambient",
            Self::UserPresent => "userPresent",
        }
    }

    /// The role a procedure's name stands for.
    #[must_use]
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "ambient" => Some(Self::Ambient),
            "userPresent" => Some(Self::UserPresent),
            _ => None,
        }
    }

    /// The `att.role` of an attestation for this key (profile v1 §3.3): `"user_present"`, or none
    /// for the ambient key.
    #[must_use]
    pub const fn att(self) -> Option<&'static str> {
        match self {
            Self::Ambient => None,
            Self::UserPresent => Some(USER_PRESENT),
        }
    }

    /// The role an attestation's `att` object names: the user-present key only for the exact
    /// string `"user_present"`, the ambient key for anything else or nothing, so an application's
    /// own `role` is never read as a presence proof.
    #[must_use]
    pub fn of_att(att: &Map<String, Value>) -> Self {
        if att.get("role").and_then(Value::as_str) == Some(USER_PRESENT) {
            Self::UserPresent
        } else {
            Self::Ambient
        }
    }
}

/// `att.role` of the user-present key, on the wire: snake case.
pub const USER_PRESENT: &str = "user_present";

/// One of the issuer's public keys, by its `kid`.
#[derive(Clone, Debug)]
pub struct IssuerKey {
    /// The `kid` an attestation's header names it by.
    pub kid: String,
    /// The ES256 key.
    pub key: VerifyingKey,
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
    /// How far a clock may differ from this server's, in seconds, for both credentials: [`SKEW`]
    /// unless told otherwise.
    pub skew: i64,
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
            skew: SKEW,
        }
    }
}

/// Why a request was refused: the verifier's codes of profile v1 (RFC-014 §5), the ones Dart's
/// `DeviceSignatureError` and `webankRefusals` use. Every one is a 401 with `{"error": code}` and
/// `WWW-Authenticate: DeviceSignature error="<code>"`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A header is missing or empty.
    MissingCredential,
    /// A credential is not a compact JWS of JSON, a header has no `alg`, or a claim is missing or
    /// of the wrong type (`att` that is not an object included).
    Malformed,
    /// `none`, an HMAC, or an algorithm this server does not take.
    BadAlg,
    /// The attestation's `iss` is not this server's.
    UntrustedIssuer,
    /// The attestation's header has no `kid`, or one this server has no key for.
    UnknownKid,
    /// The attestation's signature does not verify with the key its `kid` names.
    BadAttestation,
    /// The attestation is not valid now. The client renews it and sends again.
    AttestationExpired,
    /// The attestation's `att.status` is not `"active"`, or the device is not one this server
    /// knows. The client renews once.
    DeviceNotActive,
    /// The signature's `jwk` is missing, private, or not a public P-256 key.
    BadJwk,
    /// The signature's `jwk` is not the key the attestation is bound to.
    KeyNotBound,
    /// The signature does not verify.
    BadSignature,
    /// The signature is too old, or dated in the future.
    SignatureExpired,
    /// The signature lives longer than five minutes, or its `exp` is before its `iat`.
    LifetimeTooLong,
    /// A claim disagrees with the request; the field names which (`mth`, `pth`, `aud`, `qsh`,
    /// `bdh`), and the code says it: `method_mismatch`, ...
    Mismatch(&'static str),
    /// The `jti` was used before, or the memory of `jti`s is full (fail closed: the profile makes
    /// the two indistinguishable on the wire).
    Replay,
}

impl Refusal {
    /// The wire name: `{"error": code}`.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::MissingCredential => "missing_credential",
            Self::Malformed => "malformed",
            Self::BadAlg => "bad_alg",
            Self::UntrustedIssuer => "untrusted_issuer",
            Self::UnknownKid => "unknown_kid",
            Self::BadAttestation => "bad_attestation",
            Self::AttestationExpired => "attestation_expired",
            Self::DeviceNotActive => "device_not_active",
            Self::BadJwk => "bad_jwk",
            Self::KeyNotBound => "key_not_bound",
            Self::BadSignature => "bad_signature",
            Self::SignatureExpired => "signature_expired",
            Self::LifetimeTooLong => "lifetime_too_long",
            Self::Mismatch(claim) => match claim.as_bytes() {
                b"mth" => "method_mismatch",
                b"pth" => "path_mismatch",
                b"aud" => "audience_mismatch",
                b"qsh" => "query_mismatch",
                _ => "body_mismatch",
            },
            Self::Replay => "replay_detected",
        }
    }
}

/// The single-use memory of `jti`s: each is kept until its signature can no longer pass the
/// freshness check anyway, then swept.
#[derive(Debug)]
pub struct SeenJtis {
    until: HashMap<String, i64>,
    capacity: usize,
}

impl Default for SeenJtis {
    fn default() -> Self {
        Self::with_capacity(JTI_CAPACITY)
    }
}

impl SeenJtis {
    /// A memory that holds at most `capacity` live `jti`s; when it is full of live ones, a new
    /// request is refused as a replay (profile v1 fails closed).
    #[must_use]
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            until: HashMap::new(),
            capacity,
        }
    }

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

    /// Remembers `jti` as used until `until` (seconds since the epoch), whatever the capacity.
    pub fn remember(&mut self, jti: &str, until: i64) {
        self.until.insert(jti.to_owned(), until);
    }

    fn contains(&self, jti: &str, now: i64) -> bool {
        self.until.get(jti).is_some_and(|until| *until > now)
    }

    fn insert(&mut self, jti: &str, until: i64, now: i64) -> Result<(), Refusal> {
        if self.until.len() >= self.capacity {
            self.until.retain(|_, until| *until > now);
        }
        // Full of live ones: refuse as a replay (profile v1 fails closed).
        if self.until.len() >= self.capacity {
            return Err(Refusal::Replay);
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
    /// The attestation's `att.role`: which of the device's keys signed.
    pub role: Role,
    /// The thumbprint of the key that signed (the attestation's `cnf.jkt`).
    pub jkt: String,
    /// The signature's `jti`.
    pub jti: String,
    /// When the request was signed: the signature's `iat`, never later than now (a clock a little
    /// ahead is within the skew this check allows). For the user-present key it is when the user
    /// passed the platform's presence test, the principal's `auth_time`.
    pub signed_at: i64,
}

fn int(claims: &Map<String, Value>, name: &str) -> Option<i64> {
    claims.get(name)?.as_i64()
}

/// Checks a request the way a server does; the first check that fails is the refusal.
///
/// In profile v1's order: both headers are there and not empty; both are compact JWSs of JSON
/// with an allowed `alg` (`ES256`, `EdDSA` or `RS256` for the issuer, `ES256` for the device) and the
/// signature's header has a `jwk`; the attestation has its claims and an `att` object, is this
/// server's (`iss`), names a `kid` of `issuer_keys`, is signed by it, is valid now (30 s of skew)
/// and its `att.status` is `"active"`; the `jwk` is a public P-256 key whose thumbprint is
/// `cnf.jkt`; the signature verifies and has its claims; it is fresh (30 s of skew, a lifetime of
/// at most 300 s); `mth`, `pth`, `aud`, `qsh` and `bdh` match the request (a hash on one side only
/// is a mismatch; a bare `?` is no query, an empty body no body); the `jti` was not used before. A
/// `jti` is remembered only when everything passed, so a refused request burns none.
///
/// # Errors
/// The [`Refusal`] of the first failed check.
pub fn verify(
    profile: &Profile,
    issuer_keys: &[IssuerKey],
    request: &Received<'_>,
    now: i64,
    seen: &mut SeenJtis,
) -> Result<Verified, Refusal> {
    // 1. Presence: an empty header is an absent one.
    let (Some(attestation_jws), Some(signature_jws)) = (
        request.attestation.filter(|value| !value.is_empty()),
        request.signature.filter(|value| !value.is_empty()),
    ) else {
        return Err(Refusal::MissingCredential);
    };

    // 2. Parse both, and their algorithms, before any cryptography.
    let attestation = split(attestation_jws).ok_or(Refusal::Malformed)?;
    let attestation_alg = alg(&attestation.header, &["ES256", "EdDSA", "RS256"])?;
    let signature = split(signature_jws).ok_or(Refusal::Malformed)?;
    alg(&signature.header, &["ES256"])?;
    let embedded = signature.header.get("jwk").ok_or(Refusal::BadJwk)?;

    // 3. Attestation trust.
    let trusted = trust(profile, issuer_keys, &attestation, attestation_alg, now)?;
    let (subject, device_id, jkt, role) = (
        trusted.subject,
        trusted.device_id,
        trusted.jkt,
        trusted.role,
    );

    // 4. The binding.
    let jwk = Jwk::parse(embedded).ok_or(Refusal::BadJwk)?;
    if !constant_time_eq(&jwk.thumbprint(), jkt) {
        return Err(Refusal::KeyNotBound);
    }

    // 5. The request signature.
    let key = jwk.verifying_key().ok_or(Refusal::BadJwk)?;
    if !verify_es256(
        &key,
        signature.signing_input.as_bytes(),
        &signature.signature,
    ) {
        return Err(Refusal::BadSignature);
    }
    let signed = &signature.claims;
    let claim = |name: &str| signed.get(name).and_then(Value::as_str);
    let optional = |name: &str| match signed.get(name) {
        None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.as_str())),
        Some(_) => Err(Refusal::Malformed),
    };
    let (Some(signed_iat), Some(signed_exp), Some(jti), Some(mth), Some(pth), Some(aud)) = (
        int(signed, "iat"),
        int(signed, "exp"),
        claim("jti").filter(|jti| !jti.is_empty()),
        claim("mth"),
        claim("pth"),
        claim("aud"),
    ) else {
        return Err(Refusal::Malformed);
    };
    let (qsh, bdh) = (optional("qsh")?, optional("bdh")?);

    // 6. Freshness.
    if signed_exp + profile.skew <= now || signed_iat - profile.skew > now {
        return Err(Refusal::SignatureExpired);
    }
    let lifetime = signed_exp - signed_iat;
    if !(0..=MAX_LIFETIME).contains(&lifetime) {
        return Err(Refusal::LifetimeTooLong);
    }

    // 7. The request.
    if mth != request.method.to_ascii_uppercase() {
        return Err(Refusal::Mismatch("mth"));
    }
    let sent_path = Some(request.path).filter(|p| !p.is_empty()).unwrap_or("/");
    if pth != sent_path {
        return Err(Refusal::Mismatch("pth"));
    }
    if aud != profile.audience {
        return Err(Refusal::Mismatch("aud"));
    }
    // Present on both sides or on neither: a hash the request does not call for is a mismatch too.
    let query = request.query.unwrap_or_default().as_bytes();
    if !hash_matches(query, qsh) {
        return Err(Refusal::Mismatch("qsh"));
    }
    if !hash_matches(request.body, bdh) {
        return Err(Refusal::Mismatch("bdh"));
    }

    // 8. Single use, last.
    if seen.contains(jti, now) {
        return Err(Refusal::Replay);
    }
    seen.insert(jti, signed_exp + profile.skew, now)?;
    Ok(Verified {
        subject: subject.to_owned(),
        device_id: device_id.to_owned(),
        role,
        jkt: jkt.to_owned(),
        jti: jti.to_owned(),
        signed_at: signed_iat.min(now),
    })
}

/// What a trusted attestation says.
struct Trusted<'a> {
    subject: &'a str,
    device_id: &'a str,
    jkt: &'a str,
    role: Role,
}

/// Attestation trust (profile v1 §4): its claims and `att` object, a trusted `iss`, a `kid` of
/// `issuer_keys`, a signature by that key, valid now, and `att.status` `"active"`.
fn trust<'a>(
    profile: &Profile,
    issuer_keys: &[IssuerKey],
    attestation: &'a Compact<'_>,
    attestation_alg: &str,
    now: i64,
) -> Result<Trusted<'a>, Refusal> {
    let claims = &attestation.claims;
    let (Some(iss), Some(subject), Some(device_id), Some(iat), Some(exp), Some(jkt)) = (
        claims.get("iss").and_then(Value::as_str),
        claims.get("sub").and_then(Value::as_str),
        claims.get("did").and_then(Value::as_str),
        int(claims, "iat"),
        int(claims, "exp"),
        claims
            .get("cnf")
            .and_then(Value::as_object)
            .and_then(|cnf| cnf.get("jkt"))
            .and_then(Value::as_str),
    ) else {
        return Err(Refusal::Malformed);
    };
    let att = claims
        .get("att")
        .and_then(Value::as_object)
        .ok_or(Refusal::Malformed)?;
    if iss != profile.issuer {
        return Err(Refusal::UntrustedIssuer);
    }
    let kid = attestation
        .header
        .get("kid")
        .and_then(Value::as_str)
        .ok_or(Refusal::UnknownKid)?;
    let issuer = issuer_keys
        .iter()
        .find(|key| key.kid == kid)
        .ok_or(Refusal::UnknownKid)?;
    if attestation_alg != "ES256"
        || !verify_es256(
            &issuer.key,
            attestation.signing_input.as_bytes(),
            &attestation.signature,
        )
    {
        return Err(Refusal::BadAttestation);
    }
    if now < iat - profile.skew || now >= exp + profile.skew {
        return Err(Refusal::AttestationExpired);
    }
    if att.get("status").and_then(Value::as_str) != Some("active") {
        return Err(Refusal::DeviceNotActive);
    }
    let role = Role::of_att(att);

    Ok(Trusted {
        subject,
        device_id,
        jkt,
        role,
    })
}

/// The header's `alg` when it is in `allowed`: `malformed` without one, `bad_alg` otherwise.
fn alg<'a>(header: &'a Map<String, Value>, allowed: &[&str]) -> Result<&'a str, Refusal> {
    let alg = header
        .get("alg")
        .and_then(Value::as_str)
        .ok_or(Refusal::Malformed)?;
    if allowed.contains(&alg) {
        Ok(alg)
    } else {
        Err(Refusal::BadAlg)
    }
}

/// A hash on both sides that matches, or on neither (an empty value counts as none).
fn hash_matches(bytes: &[u8], claim: Option<&str>) -> bool {
    match (bytes.is_empty(), claim) {
        (true, None) => true,
        (false, Some(claim)) => constant_time_eq(claim, &sha256_hex(bytes)),
        _ => false,
    }
}

/// Equal, in a time that depends on the length only.
fn constant_time_eq(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0_u8, |diff, (x, y)| diff | (x ^ y))
            == 0
}
