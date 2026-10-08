//! The server of fespalier's `cose` example: a `CrateStack` `transport rpc` service, no database,
//! whose every request and response is a `COSE_Sign1` message (CBOR inside), except the one op
//! that registers a device's key.
//!
//! - [`build`] makes the router (`Built::router`) and what a client pins (`Built::hello`).
//! - Reads and writes are `Required`: an unsigned or unknown-key request is an unsigned 401, and
//!   every answer to a signed request is sealed with the server's ESP256 key.
//! - `registerDevice` is `Off`: a request signed by a key nobody has registered is the 401, so
//!   the key has to arrive plain. The call proves nothing about who holds the key, and gains the
//!   caller nothing: a signature by that key is only worth what the server lets a registered
//!   key do, and here that is to read and write its own notes.
//! - Registration and notes are in memory: a restart forgets both.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cratestack::axum::body::{Body, to_bytes};
use cratestack::axum::extract::Request;
use cratestack::axum::http::StatusCode;
use cratestack::axum::middleware::Next;
use cratestack::axum::response::{IntoResponse, Response};
use cratestack::cose::{CoseEnvelope, CoseMode, CoseVerifyKey, P256Signer};
use cratestack::envelope_layer::{EnvelopeMode, PolicyRequest};
use cratestack::idempotency::IdempotencyLayer;
use cratestack::{
    AuthProvider, CratestackContext, CratestackError, InMemoryNonceStore, RequestContext, Value,
    VerifiedSigner, include_server_schema, serde_json,
};
use cratestack_codec_cbor::CborCodec;

pub mod idempotency;
pub mod registry;

use idempotency::MemoryIdempotency;
use registry::DeviceKeys;

include_server_schema!("schema.cstack", db = None);

use cratestack_schema::procedures::{self as procs, ProcedureRegistry};
use cratestack_schema::{Cratestack, DeviceView, Note, NoteList};

/// How many notes a device may keep (the store is in memory).
pub const MAX_NOTES: usize = 1_000;

/// How long a stored answer is replayed for a retry under the same `Idempotency-Key`.
const IDEMPOTENCY_TTL: std::time::Duration = std::time::Duration::from_hours(24);

/// The op id of the one plain call.
pub const REGISTER_OP: &str = "procedure.registerDevice";

/// The `audience` a signed message is bound to, unless told otherwise.
pub const DEFAULT_AUDIENCE: &str = "fespalier-cose";

/// What a client needs to talk to the server, printed by the binary as one JSON line.
#[derive(Clone, Debug)]
pub struct Hello {
    /// The audience the server binds into every message (a configured name, not a hostname).
    pub audience: String,
    /// The server's response key as a JWK (`{"kty":"EC","crv":"P-256","x":..,"y":..}`).
    pub server_public_jwk: serde_json::Value,
}

/// A configured server.
pub struct Built {
    /// The generated router with the envelope layer on top.
    pub router: cratestack::axum::Router,
    /// What to pin.
    pub hello: Hello,
    /// The device registry, to inspect in tests.
    pub devices: DeviceKeys,
    /// The server's response key, to verify its answers in tests.
    pub server_key: CoseVerifyKey,
}

/// Whether `op` (an op id, or `batch`) travels as a signed message: all but the registration.
#[must_use]
pub fn is_signed(op: &str) -> bool {
    op != REGISTER_OP
}

/// The mode of an op: only the registration is plain.
fn mode_of(request: &PolicyRequest<'_>) -> EnvelopeMode {
    if is_signed(request.op()) {
        EnvelopeMode::Required
    } else {
        EnvelopeMode::Off
    }
}

/// Procedures over the registry and a per-device in-memory list of notes.
#[derive(Clone)]
struct Procedures {
    devices: DeviceKeys,
    notes: Arc<Mutex<HashMap<[u8; 32], Vec<Note>>>>,
}

/// Lowercase hex, as the `kid` and `thumbprint` of a `DeviceView` are written.
#[must_use]
pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

/// A P-256 coordinate: 32 bytes as unpadded base64url, as in a JWK.
fn coordinate(name: &str, value: &str) -> Result<[u8; 32], CratestackError> {
    URL_SAFE_NO_PAD
        .decode(value)
        .ok()
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| CratestackError::Validation(format!("{name} is not a P-256 coordinate")))
}

#[allow(
    clippy::unused_async_trait_impl,
    reason = "the trait methods are async; this example keeps its state in memory"
)]
impl ProcedureRegistry for Procedures {
    async fn register_device(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::register_device::Args,
        _authorized: procs::register_device::Authorized,
    ) -> Result<procs::register_device::Output, CratestackError> {
        let (x, y) = (
            coordinate("x", &args.args.x)?,
            coordinate("y", &args.args.y)?,
        );
        let mut sec1 = [0_u8; 65];
        sec1[0] = 0x04;
        sec1[1..33].copy_from_slice(&x);
        sec1[33..].copy_from_slice(&y);
        // Fails for a point that is not on the curve.
        let key = CoseVerifyKey::p256_sec1(&sec1)?;
        let view = DeviceView {
            kid: hex(&key.kid()),
            thumbprint: hex(&key.thumbprint()),
        };
        self.devices.register(key)?;
        Ok(view)
    }

    async fn list_notes(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::list_notes::Args,
        _authorized: procs::list_notes::Authorized,
    ) -> Result<procs::list_notes::Output, CratestackError> {
        let device = signer_of(ctx)?;
        let limit = args
            .args
            .limit
            .map_or(usize::MAX, |limit| usize::try_from(limit).unwrap_or(0));
        let notes = self.notes.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(NoteList {
            notes: notes
                .get(&device)
                .map(|mine| mine.iter().take(limit).cloned().collect())
                .unwrap_or_default(),
        })
    }

    async fn add_note(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::add_note::Args,
        _authorized: procs::add_note::Authorized,
    ) -> Result<procs::add_note::Output, CratestackError> {
        let device = signer_of(ctx)?;
        let mut notes = self.notes.lock().unwrap_or_else(PoisonError::into_inner);
        let mine = notes.entry(device).or_default();
        if mine.len() >= MAX_NOTES {
            return Err(CratestackError::Validation(
                "this device has as many notes as the demo keeps".to_owned(),
            ));
        }
        let note = Note {
            id: i64::try_from(mine.len() + 1).unwrap_or(i64::MAX),
            text: args.args.text,
        };
        mine.push(note.clone());
        Ok(note)
    }
}

/// The device a request was signed by: the thumbprint the envelope verified.
fn signer_of(ctx: &CratestackContext) -> Result<[u8; 32], CratestackError> {
    ctx.verified_signer()
        .map(|signer| *signer.thumbprint())
        .ok_or_else(|| CratestackError::Unauthorized("sign the request".to_owned()))
}

/// Authenticated exactly when the envelope verified a signer. The envelope does not authenticate
/// by itself: it records the signer, and the `AuthProvider` decides what that means.
#[derive(Clone)]
struct SignerAuth;

impl AuthProvider for SignerAuth {
    type Error = CratestackError;

    fn authenticate(
        &self,
        request: &RequestContext<'_>,
    ) -> impl core::future::Future<Output = Result<CratestackContext, Self::Error>> + Send {
        let context = request.extensions.get::<VerifiedSigner>().map_or_else(
            CratestackContext::anonymous,
            |signer| {
                CratestackContext::authenticated([(
                    "id".to_owned(),
                    Value::String(hex(signer.thumbprint())),
                )])
            },
        );
        core::future::ready(Ok(context))
    }
}

/// The server's JWK, from the verification half of its key.
fn jwk_of(key: &CoseVerifyKey) -> Result<serde_json::Value, CratestackError> {
    let sec1 = key
        .p256_sec1_uncompressed()
        .ok_or_else(|| CratestackError::Internal("the server key is not P-256".to_owned()))?;
    Ok(serde_json::json!({
        "kty": "EC",
        "crv": "P-256",
        "x": URL_SAFE_NO_PAD.encode(&sec1[1..33]),
        "y": URL_SAFE_NO_PAD.encode(&sec1[33..]),
    }))
}

/// A fresh private scalar for the server's ESP256 key.
///
/// # Errors
/// When the operating system has no randomness.
pub fn random_scalar() -> Result<[u8; 32], CratestackError> {
    loop {
        let mut scalar = [0_u8; 32];
        getrandom::fill(&mut scalar)
            .map_err(|error| CratestackError::Internal(format!("no randomness: {error}")))?;
        // Zero, or not below the group order: draw again (about 2^-32 of draws).
        if P256Signer::from_scalar(&scalar).is_ok() {
            return Ok(scalar);
        }
    }
}

/// Build the server: the generated RPC router under the envelope layer.
///
/// `server_scalar` is the private scalar of the ESP256 key every response is sealed with.
///
/// # Errors
/// When the scalar is not a valid P-256 key, or the envelope cannot be built.
pub fn build(audience: &str, server_scalar: &[u8; 32]) -> Result<Built, CratestackError> {
    let signer = P256Signer::from_scalar(server_scalar)?;
    let server_key = signer.verify_key();
    let devices = DeviceKeys::new();
    let envelope = CoseEnvelope::server(
        CoseMode::Sign1,
        Arc::new(signer),
        Arc::new(devices.clone()),
        // Per-process replay cache: fine for one process, a shared store is needed for several.
        Arc::new(InMemoryNonceStore::new()),
    )
    .build()?;
    let layer = cratestack_schema::axum::envelope_layer(envelope, mode_of, audience).build()?;
    let procedures = Procedures {
        devices: devices.clone(),
        notes: Arc::default(),
    };
    let router = cratestack_schema::axum::rpc_router(
        Cratestack::builder().build(),
        procedures,
        (),
        CborCodec,
        SignerAuth,
        cratestack::DEFAULT_BODY_LIMIT_BYTES,
    )
    // Inside the envelope layer: it sees the plain CBOR the envelope unwrapped (the same bytes on
    // every attempt) and the verified device as its principal, so a retry under the same key is
    // replayed, and sealed anew by the envelope layer for the request that asked.
    .layer(IdempotencyLayer::new(
        Arc::new(MemoryIdempotency::new()),
        IDEMPOTENCY_TTL,
    ))
    // The envelope layer next ...
    .layer(layer)
    // ... and outermost, one that reads the whole body first. The envelope layer refuses from
    // the headers alone (a content type, a contract selector) before it reads the body, and
    // hyper then closes the connection with the body unread, which the OS turns into a reset
    // that a client can see before the answer. Reading it first makes every refusal an answer.
    .layer(cratestack::axum::middleware::from_fn(read_body_first));
    Ok(Built {
        router,
        hello: Hello {
            audience: audience.to_owned(),
            server_public_jwk: jwk_of(&server_key)?,
        },
        devices,
        server_key,
    })
}

/// Reads the request body (up to the codec's limit) before anything can answer.
async fn read_body_first(request: Request, next: Next) -> Response {
    let (parts, body) = request.into_parts();
    match to_bytes(body, cratestack::DEFAULT_BODY_LIMIT_BYTES).await {
        Ok(bytes) => {
            next.run(Request::from_parts(parts, Body::from(bytes)))
                .await
        }
        Err(_) => StatusCode::PAYLOAD_TOO_LARGE.into_response(),
    }
}
