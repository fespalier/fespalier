//! The attestation issuer and the verifier's trust, on Authkestra.
//!
//! - **Issuing** is `authkestra-op`'s: [`handle_enrol_start`] (the second factor, then a single-use
//!   challenge for one key), [`handle_reissue_start`] (a renewal: the key's last attestation and
//!   its JWK, checked against each other, and the device's current status) and
//!   [`handle_complete_challenge`] (the challenge signature, then the attestation, with `cnf.jkt`
//!   computed by Authkestra from the key it just verified). The attestations are signed by
//!   `authkestra-engine`'s [`TokenManager`] with this server's Ed25519 key.
//! - **Verifying** is `authkestra-devsig`'s: the [`VerifierConfig`] of profile v1, the issuer key
//!   in an [`IssuerJwks`], and an [`InMemoryReplayStore`] for the single-use `jti`s
//!   (`src/auth.rs` calls [`authkestra_devsig::verify`]).
//!
//! What stays here is the glue the handlers leave to the application: the one-time code the demo
//! "texts" ([`OneCode`], a [`SecondFactorVerifier`]), the device's status at a renewal
//! ([`KeyStatus`], an [`AttestationStatusProvider`]), and the issuer key's generation.

use std::time::Duration;

use async_trait::async_trait;
use authkestra_devsig::{InMemoryReplayStore, IssuerJwks, KeyRole, VerifierConfig};
use authkestra_engine::store::memory::MemoryStore;
use authkestra_engine::token::TokenManager;
use authkestra_op::OpError;
use authkestra_op::attestation::{
    AttestationConfig, AttestationStatusProvider, EnrolmentChallenge, PrincipalType,
    SecondFactorProof, SecondFactorVerifier,
};
use authkestra_op::handlers::enrolment::{
    AttestationResponse, ChallengeResponse, CompleteChallengeRequest, EnrolStartRequest,
    ReissueStartRequest, handle_complete_challenge, handle_enrol_start, handle_reissue_start,
};
use cratestack::CratestackError;
use cratestack::serde_json::{self, Value as Json, json};
use ed25519_dalek::SigningKey;
use ed25519_dalek::pkcs8::EncodePrivateKey as _;
use jsonwebtoken::jwk::{Jwk, ThumbprintHash};

/// The `iss` of every attestation, and the one issuer the verifier trusts.
pub const ISSUER: &str = "https://issuer.cratestack.example";

/// The second factor's `kind`: the demo's one-time code, "texted" to the phone.
pub const OTP_KIND: &str = "sms_otp";

/// How long an enrolment or a renewal challenge waits for its signature, in seconds.
const CHALLENGE_TTL_SECS: u64 = 5 * 60;

/// How an issuer is configured.
#[derive(Clone, Debug)]
pub struct IssuerConfig {
    /// The `aud` every request signature must name.
    pub audience: String,
    /// How long an attestation lives, in seconds.
    pub attestation_ttl_secs: u64,
    /// How far a device's clock may be from this server's, in seconds (profile v1: 30). A test
    /// that wants an attestation refused as soon as it expires sets 0.
    pub clock_skew_secs: u64,
    /// The issuer's Ed25519 seed; `None` draws a fresh one, so a restart makes every attestation
    /// `unknown_kid`.
    pub seed: Option<[u8; 32]>,
}

/// The issuer and the verifier's trust, built once.
pub struct Issuer {
    /// Signs the attestations, and checks a key's last one at a renewal.
    pub tokens: TokenManager,
    /// The single-use challenges of enrolments and renewals.
    pub challenges: MemoryStore<EnrolmentChallenge>,
    /// The attestation and challenge lifetimes.
    pub attestation: AttestationConfig,
    /// Profile v1's verifier configuration, with this server's audience and skew.
    pub verifier: VerifierConfig,
    /// The issuer key, as the verifier looks it up.
    pub jwks: IssuerJwks,
    /// The `jti`s already seen.
    pub replay: InMemoryReplayStore,
    /// The issuer key's public JWK.
    pub public_jwk: Json,
    /// Its `kid`: its RFC 7638 thumbprint, so a new key is a new `kid`.
    pub kid: String,
}

fn internal(what: &str) -> impl FnOnce(String) -> CratestackError + '_ {
    move |error| CratestackError::Internal(format!("{what}: {error}"))
}

impl Issuer {
    /// An issuer with a key from `config.seed` (or a fresh one).
    ///
    /// # Errors
    /// When there is no randomness, or the key cannot be handed to Authkestra.
    pub async fn new(config: &IssuerConfig) -> Result<Self, CratestackError> {
        let seed = match config.seed {
            Some(seed) => seed,
            None => random_bytes::<32>()?,
        };
        let key = SigningKey::from_bytes(&seed);
        let x = base64url(key.verifying_key().as_bytes());
        let public: Jwk = serde_json::from_value(json!({ "kty": "OKP", "crv": "Ed25519", "x": x }))
            .map_err(|e| internal("the issuer JWK")(e.to_string()))?;
        let kid = public
            .thumbprint(ThumbprintHash::SHA256)
            .map_err(|e| internal("the issuer kid")(e.to_string()))?;
        let pem = key
            .to_pkcs8_pem(ed25519_dalek::pkcs8::spki::der::pem::LineEnding::LF)
            .map_err(|e| internal("the issuer key")(e.to_string()))?;
        let tokens =
            TokenManager::new_ed25519(pem.as_bytes(), Some(ISSUER.to_owned()), Some(kid.clone()))
                .map_err(|e| internal("the token manager")(e.to_string()))?;
        let mut public_jwk =
            serde_json::to_value(&public).map_err(|e| internal("the issuer JWK")(e.to_string()))?;
        public_jwk["kid"] = Json::String(kid.clone());
        let jwks = IssuerJwks::new();
        jwks.insert(ISSUER, kid.clone(), public).await;
        let mut verifier = VerifierConfig::profile_v1([ISSUER], config.audience.clone());
        verifier.max_clock_skew = Duration::from_secs(config.clock_skew_secs);
        let mut attestation = AttestationConfig::new();
        attestation.attestation_ttl_secs = config.attestation_ttl_secs;
        attestation.attestation_reissue_after_secs = config.attestation_ttl_secs / 2;
        attestation.challenge_ttl_secs = CHALLENGE_TTL_SECS;
        Ok(Self {
            tokens,
            challenges: MemoryStore::new(),
            attestation,
            verifier,
            jwks,
            replay: InMemoryReplayStore::new(),
            public_jwk,
            kid,
        })
    }

    /// Leg one of an enrolment, for one key: the code is checked first ([`OneCode`]), and only
    /// then is a challenge issued for `jwk`, bound to `subject`, the device `did` and `role`.
    ///
    /// # Errors
    /// Authkestra's refusal: `SecondFactorFailed`, `BadJwk`, `Storage`.
    pub async fn enrol(
        &self,
        subject: &str,
        did: &str,
        role: KeyRole,
        jwk: Json,
        code: &OneCode,
        otp: &str,
    ) -> Result<ChallengeResponse, OpError> {
        let request: EnrolStartRequest = serde_json::from_value(json!({
            "subject": subject,
            "principal_id": did,
            "principal_type": "device",
            "public_jwk": jwk,
            "attributes": attributes(role),
            "second_factor": { "kind": OTP_KIND, "value": otp },
        }))
        .map_err(|_| OpError::BadJwk("not an enrolment request".to_owned()))?;
        handle_enrol_start(request, code, &self.challenges, &self.attestation).await
    }

    /// Leg one of a renewal: the key's last attestation and its JWK, which Authkestra checks
    /// against each other, and the device's status ([`KeyStatus`]).
    ///
    /// # Errors
    /// Authkestra's refusal: `AttestationInvalid`, `KeyNotBound`, `PrincipalRevoked`.
    pub async fn reissue(
        &self,
        attestation: &str,
        jwk: Json,
        status: &KeyStatus,
    ) -> Result<ChallengeResponse, OpError> {
        let request: ReissueStartRequest = serde_json::from_value(json!({
            "attestation": attestation,
            "public_jwk": jwk,
        }))
        .map_err(|_| OpError::BadJwk("not a re-issuance request".to_owned()))?;
        handle_reissue_start(
            request,
            &self.tokens,
            Some(status),
            &self.challenges,
            &self.attestation,
        )
        .await
    }

    /// Leg two of both: the challenge's signature, then the attestation.
    ///
    /// # Errors
    /// Authkestra's refusal: `InvalidChallenge`, `ChallengeSignatureInvalid`, `TokenIssuance`.
    pub async fn complete(
        &self,
        challenge: &str,
        signature: &str,
    ) -> Result<AttestationResponse, OpError> {
        let request: CompleteChallengeRequest = serde_json::from_value(json!({
            "challenge": challenge,
            "challenge_signature": signature,
        }))
        .map_err(|_| OpError::InvalidChallenge)?;
        handle_complete_challenge(request, &self.challenges, &self.tokens, &self.attestation).await
    }
}

/// The `att` claim of a key's attestation (profile v1): active, and which key it is.
#[must_use]
pub fn attributes(role: KeyRole) -> Json {
    json!({ "status": "active", "role": role.as_str() })
}

/// The second factor of one enrolment: the code this server sent to the phone, read under the
/// state's lock before the handler runs, so the verifier holds no lock across an `await`.
pub struct OneCode {
    /// The code sent, or `None` when none was (or it expired).
    pub sent: Option<String>,
}

#[async_trait]
impl SecondFactorVerifier for OneCode {
    async fn verify(
        &self,
        _subject: &str,
        principal_type: PrincipalType,
        proof: &SecondFactorProof,
    ) -> Result<(), OpError> {
        let matches = principal_type == PrincipalType::Device
            && proof.kind == OTP_KIND
            && self
                .sent
                .as_deref()
                .is_some_and(|sent| constant_time_eq(sent.as_bytes(), proof.value.as_bytes()));
        if matches {
            Ok(())
        } else {
            Err(OpError::SecondFactorFailed)
        }
    }
}

/// A device's status at a renewal, read under the state's lock: the `att` claim to issue for the
/// key being renewed, or `None` when the device is revoked (or unknown), which Authkestra refuses
/// as [`OpError::PrincipalRevoked`].
pub struct KeyStatus {
    /// The attributes, or `None`.
    pub attributes: Option<Json>,
}

#[async_trait]
impl AttestationStatusProvider for KeyStatus {
    async fn current_attributes(
        &self,
        _subject: &str,
        _principal_id: &str,
        _principal_type: PrincipalType,
    ) -> Result<Option<Json>, OpError> {
        Ok(self.attributes.clone())
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0_u8, |diff, (x, y)| diff | (x ^ y)) == 0
}

/// `N` random bytes.
///
/// # Errors
/// When the system has no randomness.
pub fn random_bytes<const N: usize>() -> Result<[u8; N], CratestackError> {
    let mut bytes = [0_u8; N];
    getrandom::fill(&mut bytes)
        .map_err(|error| CratestackError::Internal(format!("no randomness: {error}")))?;
    Ok(bytes)
}

/// Lower-case hex.
#[must_use]
pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

fn base64url(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}
