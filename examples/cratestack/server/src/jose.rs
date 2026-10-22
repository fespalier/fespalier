//! The little JOSE this server needs and nothing more: unpadded base64url, a compact JWS signed
//! with ES256 (P-256, SHA-256, the raw 64-byte `r||s`), a P-256 public key as a JWK, and its
//! RFC 7638 thumbprint.
//!
//! Every check is strict where Dart's `fespalier_keypair` is loose, because a server is the side
//! that must not accept a second spelling of the same key: a coordinate is exactly 32 bytes of
//! unpadded base64url, and it must re-encode to the very string it came from.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cratestack::serde_json::{self, Map, Value};
use p256::ecdsa::signature::{Signer, Verifier};
use p256::ecdsa::{Signature, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};

/// Unpadded base64url, as every part of a compact JWS is written.
#[must_use]
pub fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// The bytes of unpadded base64url text, or `None` for anything else (padding included).
#[must_use]
pub fn unb64(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text).ok()
}

/// Lowercase hex of the SHA-256 of `bytes`: the form of the `qsh` and `bdh` claims.
#[must_use]
pub fn sha256_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    Sha256::digest(bytes)
        .iter()
        .fold(String::with_capacity(64), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        })
}

/// A public P-256 key as a JWK: `kty` EC, `crv` P-256 and the two coordinates.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Jwk {
    /// The x coordinate, 32 bytes as unpadded base64url.
    pub x: String,
    /// The y coordinate, 32 bytes as unpadded base64url.
    pub y: String,
}

impl Jwk {
    /// The key a verifying key is, spelled as a JWK.
    #[must_use]
    pub fn of(key: &VerifyingKey) -> Self {
        let point = key.to_encoded_point(false);
        Self {
            x: point.x().map(|x| b64(x)).unwrap_or_default(),
            y: point.y().map(|y| b64(y)).unwrap_or_default(),
        }
    }

    /// A JWK object (`{kty, crv, x, y}`), or `None` when it is not a public P-256 key on the curve,
    /// when it carries a private part (`d`), or when a coordinate is not spelled canonically.
    #[must_use]
    pub fn parse(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        if object.get("kty")?.as_str()? != "EC"
            || object.get("crv")?.as_str()? != "P-256"
            || object.contains_key("d")
        {
            return None;
        }
        let jwk = Self {
            x: object.get("x")?.as_str()?.to_owned(),
            y: object.get("y")?.as_str()?.to_owned(),
        };
        jwk.verifying_key().map(|_| jwk)
    }

    /// The key, when both coordinates are canonical and the point is on the curve.
    #[must_use]
    pub fn verifying_key(&self) -> Option<VerifyingKey> {
        let x = unb64(&self.x).filter(|x| x.len() == 32 && b64(x) == self.x)?;
        let y = unb64(&self.y).filter(|y| y.len() == 32 && b64(y) == self.y)?;
        let mut sec1 = Vec::with_capacity(65);
        sec1.push(0x04);
        sec1.extend_from_slice(&x);
        sec1.extend_from_slice(&y);
        VerifyingKey::from_sec1_bytes(&sec1).ok()
    }

    /// The RFC 7638 thumbprint: SHA-256 of the members `crv`, `kty`, `x`, `y` in that order,
    /// unpadded base64url. It is the attestation's `cnf.jkt`.
    #[must_use]
    pub fn thumbprint(&self) -> String {
        let canonical = format!(
            r#"{{"crv":"P-256","kty":"EC","x":"{}","y":"{}"}}"#,
            self.x, self.y
        );
        b64(&Sha256::digest(canonical.as_bytes()))
    }

    /// The JWK as the JSON object a JWS header carries.
    #[must_use]
    pub fn to_json(&self) -> Value {
        serde_json::json!({ "kty": "EC", "crv": "P-256", "x": self.x, "y": self.y })
    }
}

/// The three parts of a compact JWS, each still encoded, and the bytes the signature covers.
pub struct Compact<'a> {
    /// The decoded header object.
    pub header: Map<String, Value>,
    /// The decoded payload object.
    pub claims: Map<String, Value>,
    /// The decoded signature.
    pub signature: Vec<u8>,
    /// `header.payload` as sent: what was signed.
    pub signing_input: &'a str,
}

/// Splits and decodes a compact JWS whose header and payload are JSON objects. The signature is
/// not checked.
#[must_use]
pub fn split(jws: &str) -> Option<Compact<'_>> {
    let mut parts = jws.split('.');
    let (header, claims, signature) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || header.is_empty() || claims.is_empty() || signature.is_empty() {
        return None;
    }
    let object = |part: &str| match serde_json::from_slice(&unb64(part)?).ok()? {
        Value::Object(object) => Some(object),
        _ => None,
    };
    Some(Compact {
        header: object(header)?,
        claims: object(claims)?,
        signature: unb64(signature)?,
        signing_input: &jws[..header.len() + 1 + claims.len()],
    })
}

/// Whether `signature` (raw `r||s`) is the ES256 signature of `message` by `key`. A signature with
/// a high `s` is normalised first: Dart's signers (and a secure element's) do not promise the low
/// half, and the malleability does not matter here, since a `jti` is single use.
#[must_use]
pub fn verify_es256(key: &VerifyingKey, message: &[u8], signature: &[u8]) -> bool {
    let Ok(signature) = Signature::from_slice(signature) else {
        return false;
    };
    let signature = signature.normalize_s().unwrap_or(signature);
    key.verify(message, &signature).is_ok()
}

/// A compact JWS over `header` and `claims`, signed with ES256 by `key`.
#[must_use]
pub fn sign_compact(key: &SigningKey, header: &Value, claims: &Value) -> String {
    let input = format!(
        "{}.{}",
        b64(header.to_string().as_bytes()),
        b64(claims.to_string().as_bytes())
    );
    let signature: Signature = key.sign(input.as_bytes());
    format!("{input}.{}", b64(&signature.to_bytes()))
}

/// A signing key from its 32-byte scalar, or `None` when it is zero or not below the group order.
#[must_use]
pub fn signing_key(scalar: &[u8; 32]) -> Option<SigningKey> {
    SigningKey::from_slice(scalar).ok()
}

/// A fresh private scalar.
///
/// # Errors
/// When the operating system has no randomness.
pub fn random_scalar() -> Result<[u8; 32], getrandom::Error> {
    loop {
        let mut scalar = [0_u8; 32];
        getrandom::fill(&mut scalar)?;
        // Zero, or not below the group order: draw again (about 2^-32 of draws).
        if signing_key(&scalar).is_some() {
            return Ok(scalar);
        }
    }
}

/// `count` random bytes as unpadded base64url: an id or a challenge nobody can guess.
///
/// # Errors
/// When the operating system has no randomness.
pub fn random_token(count: usize) -> Result<String, getrandom::Error> {
    let mut bytes = vec![0_u8; count];
    getrandom::fill(&mut bytes)?;
    Ok(b64(&bytes))
}
