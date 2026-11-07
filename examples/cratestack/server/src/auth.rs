//! Who signed a request: `authkestra-devsig` inside a `CrateStack` [`AuthProvider`], with no layer
//! in front of the generated router.
//!
//! A request with neither `X-Signature` nor `X-Attestation` is anonymous ([`Credential::Absent`]),
//! and the schema's policies decide: the enrolment and renewal procedures are `@allow(true)`,
//! every other one is `@allow(auth() != null)`. A request that carries either header is verified
//! by [`authkestra_devsig::verify`] (profile v1: the attestation, the binding, the signature over
//! the method, the path, the query and the exact body bytes, and the single-use `jti`), and then
//! checked against this server's devices ([`crate::Shared::admit`]): a device it does not know is
//! `device_not_active`, a revoked one `device_revoked`, a key that is not the one it enrolled for
//! that role `key_not_bound`.
//!
//! Every refusal goes out through `CrateStack`'s [`AuthRefusal`]: the status the profile gives
//! (401, or 403 for `device_revoked`), the code as the envelope's `error` member, and a
//! `WWW-Authenticate: DeviceSignature error="<code>"` challenge, on REST and RPC alike. The
//! challenge is there on the 403 too: the generated client asks for CBOR, so the body is not the
//! profile's JSON, and the challenge is what `fespalier_sign_keypair`'s classifier reads then.

use std::sync::Arc;

use authkestra_devsig::{
    DeviceIdentity, KeyRole, MAX_SIGNATURE_LIFETIME, Refusal, SignedRequest,
    WWW_AUTHENTICATE_SCHEME,
};
use cratestack::{
    AuthProvider, AuthRefusal, CratestackContext, CratestackError, Credential, RequestContext,
    Value,
};

use crate::Shared;

/// The claim the request's `Idempotency-Key` travels in, from the provider to the procedures
/// (`src/procedures.rs` replays a write under it, after the caller is known).
pub const IDEMPOTENCY_CLAIM: &str = "idempotency_key";

/// The claim of the device id (the attestation's `did`).
pub const DEVICE_CLAIM: &str = "did";

/// The provider.
#[derive(Clone)]
pub struct DeviceAuth {
    pub(crate) shared: Arc<Shared>,
}

fn header<'r>(request: &RequestContext<'r>, name: &str) -> Option<&'r str> {
    request.headers.get(name)?.to_str().ok()
}

impl AuthProvider for DeviceAuth {
    type Error = CratestackError;

    async fn authenticate(
        &self,
        request: &RequestContext<'_>,
    ) -> Result<CratestackContext, CratestackError> {
        if self.credential(request).is_absent() {
            return Ok(CratestackContext::anonymous());
        }
        let signed = SignedRequest {
            signature: header(request, "x-signature"),
            attestation: header(request, "x-attestation"),
            method: request.method,
            path: request.path,
            query: request.query,
            body: (!request.body.is_empty()).then_some(request.body),
        };
        let issuer = &self.shared.issuer;
        let device =
            authkestra_devsig::verify(&signed, &issuer.verifier, &issuer.jwks, &issuer.replay)
                .await
                .map_err(|error| refusal(error.refusal()))?;
        self.shared.admit(&device).map_err(refusal)?;
        let idempotency_key = header(request, "idempotency-key");
        Ok(principal_of(
            &device,
            crate::now(),
            self.shared.clock_skew_secs(),
            idempotency_key,
        ))
    }

    fn credential<'r>(&self, request: &RequestContext<'r>) -> Credential<'r> {
        match (
            header(request, "x-signature"),
            header(request, "x-attestation"),
        ) {
            (None, None) => Credential::Absent,
            _ => Credential::Present { redact: None },
        }
    }
}

/// Profile v1's refusal as `CrateStack`'s: the status, `error`, and the `DeviceSignature`
/// challenge.
#[must_use]
pub fn refusal(refusal: Refusal) -> CratestackError {
    let base = if refusal.status == 403 {
        AuthRefusal::forbidden(refusal.error)
    } else {
        AuthRefusal::unauthenticated(refusal.error)
    };
    base.with_member("error", Value::String(refusal.error.to_owned()))
        .with_challenge(format!(
            "{WWW_AUTHENTICATE_SCHEME} error=\"{}\"",
            refusal.error
        ))
        .into_error()
}

/// The RFC 8176 methods a request signed by `role`'s key proves, for the principal's `amr`.
///
/// - Every signed request proves possession of a key bound to the device's attestation: `pop`.
/// - The user-present key signs only after the platform's user-presence test (a biometric or the
///   device credential, behind `KeyRole.userPresent`), so its signature also proves `user`. That
///   is what `payOrder`'s `@authn(amr: ["user"])` asks for.
///
/// Not `hwk`: this server cannot tell a hardware-backed key from a software one (the example lets
/// Windows and Linux fall back to a key in memory), and a claim the server did not check is not a
/// fact.
#[must_use]
pub fn amr_of(role: KeyRole) -> &'static [&'static str] {
    match role {
        KeyRole::UserPresent => &["user", "pop"],
        _ => &["pop"],
    }
}

/// The caller of a verified request, through `CrateStack`'s principal contract: `sub`, `did`, the
/// key role, the `amr` of [`amr_of`], `cnf.jkt`, and, for the user-present key only, an
/// `auth_time`.
///
/// `authkestra-devsig` hands back no signature time, so `auth_time` is the earliest moment the
/// verifier could have accepted the signature from: `now - skew - MAX_SIGNATURE_LIFETIME`. It is
/// never later than when the user was really there, so a `maxAge` requirement errs on the strict
/// side. The ambient key never tests the user, so its requests carry no `auth_time`.
#[must_use]
pub fn principal_of(
    device: &DeviceIdentity,
    now: i64,
    skew_secs: i64,
    idempotency_key: Option<&str>,
) -> CratestackContext {
    let role = device.key_role();
    let mut builder = CratestackContext::builder(device.subject.clone())
        .claim(DEVICE_CLAIM, Value::String(device.device.clone()))
        .key_role(match role {
            KeyRole::UserPresent => cratestack::KeyRole::UserPresent,
            _ => cratestack::KeyRole::Ambient,
        })
        .amr(amr_of(role).iter().copied())
        .cnf_jkt(device.key_thumbprint.clone());
    if role == KeyRole::UserPresent {
        let lifetime = i64::try_from(MAX_SIGNATURE_LIFETIME.as_secs()).unwrap_or(i64::MAX);
        builder = builder.auth_time(now.saturating_sub(skew_secs).saturating_sub(lifetime));
    }
    if let Some(key) = idempotency_key {
        builder = builder.claim(IDEMPOTENCY_CLAIM, Value::String(key.to_owned()));
    }
    builder.build()
}
