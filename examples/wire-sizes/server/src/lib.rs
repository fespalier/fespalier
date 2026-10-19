//! The server of fespalier's `wire-sizes` example: one schema, measured three ways.
//!
//! `examples/cose` shows *how* to sign every call with a device key. This example asks what that
//! costs, in bytes, against the alternatives a person actually weighs:
//!
//! | Variant | Body | Credential |
//! | --- | --- | --- |
//! | `json` | `application/json` | none, unless the caller sends a `Bearer` header |
//! | `cbor` | `application/cbor` | none, unless the caller sends a `Bearer` header |
//! | `cose` | `application/cose; cose-type="cose-sign1"` wrapping CBOR | the signature in the body |
//!
//! **Every variant is measured, not estimated.** [`measure`] records what actually arrived and
//! what was actually sent, headers included, so the report is the wire's own account of itself
//! rather than a client's guess at its own size.
//!
//! The envelope layer exists only in the `cose` variant, and that is the whole comparison: the
//! other two have no signature to verify, and no credential to carry in the body.

pub mod measure;
pub mod payload;
pub mod registry;
pub mod report;
pub mod runner;
pub mod scenario;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use cratestack::cose::{CoseEnvelope, CoseMode, CoseVerifyKey, P256Signer};
use cratestack::envelope_layer::{EnvelopeMode, PolicyRequest};
use cratestack::{
    AuthProvider, CratestackCodec as _, CratestackContext, CratestackError, InMemoryNonceStore,
    RequestContext, Value, VerifiedSigner, include_server_schema, serde_json,
};
use cratestack_codec_cbor::CborCodec;
use cratestack_codec_json::JsonCodec;

use measure::ExchangeLog;
use registry::DeviceKeys;

include_server_schema!("schema.cstack", db = None);

use cratestack_schema::procedures::{self as procs, ProcedureRegistry};
use cratestack_schema::{Cratestack, DeviceView, Note, NoteList};

/// How many notes a device may keep (the store is in memory).
pub const MAX_NOTES: usize = 1_000;

/// The op id of the one plain call.
pub const REGISTER_OP: &str = "procedure.registerDevice";

/// The `audience` a signed message is bound to, unless told otherwise.
pub const DEFAULT_AUDIENCE: &str = "fespalier-wire-sizes";

/// Which wire format a server speaks.
///
/// One server per variant rather than one that sniffs the body: the point is to measure the same
/// call as each format really encodes it, and a server that inspected a request to decide how to
/// answer would be a third contract, not either alternative.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Variant {
    /// Plain JSON, no envelope.
    Json,
    /// Plain CBOR, no envelope.
    Cbor,
    /// CBOR inside a `COSE_Sign1` message.
    Cose,
}

impl Variant {
    /// Parses the `--variant` flag.
    ///
    /// # Errors
    /// When the name is not one of `json`, `cbor` or `cose`.
    pub fn parse(s: &str) -> Result<Self, CratestackError> {
        match s {
            "json" => Ok(Self::Json),
            "cbor" => Ok(Self::Cbor),
            "cose" => Ok(Self::Cose),
            other => Err(CratestackError::Validation(format!(
                "unknown variant {other:?}: expected json, cbor or cose"
            ))),
        }
    }

    /// The name used on the command line and in the report.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Json => "json",
            Self::Cbor => "cbor",
            Self::Cose => "cose",
        }
    }

    /// Every variant, for the runner.
    #[must_use]
    pub fn all() -> [Self; 3] {
        [Self::Json, Self::Cbor, Self::Cose]
    }
}

/// What a client needs to talk to the server, printed by the binary as one JSON line.
#[derive(Clone, Debug)]
pub struct Hello {
    /// Which format this server speaks.
    pub variant: String,
    /// The audience a signed message is bound to (`cose` only; empty otherwise).
    pub audience: String,
    /// The server's response JWK (`cose` only; null otherwise).
    pub server_public_jwk: serde_json::Value,
}

/// A configured server.
pub struct Built {
    /// The generated router with the measuring layer on top.
    pub router: cratestack::axum::Router,
    /// What to pin.
    pub hello: Hello,
    /// The device registry, to inspect in tests.
    pub devices: DeviceKeys,
    /// Every exchange measured, for the report script to read back.
    pub exchanges: ExchangeLog,
    /// The verification half of the response key, so a client built from the same construction can
    /// check the answers. `None` for the plain variants, which seal nothing.
    server_key: Option<CoseVerifyKey>,
}

impl Built {
    /// The verification half of the `cose` server's response key.
    ///
    /// # Errors
    /// For `json` and `cbor`, which have no key: asking one for a key is a caller bug, not a
    /// runtime condition, and a silent `None` would let a signing client be built against a server
    /// that never verifies anything.
    pub fn cose_server_key(&self) -> Result<CoseVerifyKey, CratestackError> {
        self.server_key.clone().ok_or_else(|| {
            CratestackError::Internal(format!(
                "the {} server has no key: only `cose` seals its answers",
                self.hello.variant
            ))
        })
    }
}

/// Whether `op` travels as a signed message in the `cose` variant.
#[must_use]
pub fn is_signed(op: &str) -> bool {
    op != REGISTER_OP
}

/// The mode of an op in the `cose` variant: only the registration is plain.
fn mode_of(request: &PolicyRequest<'_>) -> EnvelopeMode {
    if is_signed(request.op()) {
        EnvelopeMode::Required
    } else {
        EnvelopeMode::Off
    }
}

/// Procedures over the registry and a per-device in-memory list of notes.
///
/// The same procedures serve all three variants, so the payloads compared are identical by
/// construction and a size difference is the encoding's, not the handler's.
#[derive(Clone)]
struct Procedures {
    devices: DeviceKeys,
    notes: Arc<Mutex<HashMap<[u8; 32], Vec<Note>>>>,
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
        let who = who_of(ctx)?;
        let limit = args
            .args
            .limit
            .map_or(usize::MAX, |l| usize::try_from(l).unwrap_or(0));
        let notes = self.notes.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(NoteList {
            notes: notes
                .get(&who)
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
        let who = who_of(ctx)?;
        let mut notes = self.notes.lock().unwrap_or_else(PoisonError::into_inner);
        let mine = notes.entry(who).or_default();
        if mine.len() >= MAX_NOTES {
            return Err(CratestackError::Validation(
                "this device has as many notes as the demo keeps".to_owned(),
            ));
        }
        #[allow(clippy::cast_possible_wrap)]
        let note = Note {
            id: (mine.len() + 1) as i64,
            text: args.args.text,
        };
        mine.push(note.clone());
        Ok(note)
    }

    /// Accepts a payload of any shape and reports how large it was.
    ///
    /// The store is not touched: this op exists so the sweeps can measure a *shape* (a list of
    /// records, a nested object, a blob), which `addNote`'s single `text` field cannot express. It
    /// returns the encoded size it received so a caller can confirm the payload arrived whole —
    /// which matters at the megabyte sizes, where a body limit could silently truncate one.
    async fn measure_payload(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::measure_payload::Args,
        _authorized: procs::measure_payload::Authorized,
    ) -> Result<procs::measure_payload::Output, CratestackError> {
        // The decoded value's own re-encoding, so the figure is the payload's size rather than the
        // request's: headers and framing are `measure.rs`'s business, not this op's.
        let encoded = CborCodec.encode(&args.args.value)?;
        Ok(procs::measure_payload::Output {
            bytes: i64::try_from(encoded.len()).unwrap_or(i64::MAX),
        })
    }
}

/// The verified caller's storage key.
///
/// The `cose` variant gets a real thumbprint from the envelope layer's verdict. The plain variants
/// get the `Bearer` header's identity, which is an opaque string this server never verifies — so it
/// is folded into the same 32-byte shape rather than being required to already be one. Insisting on
/// hex here would have made the plain baseline unable to write a note at all, which is a fact about
/// the token's spelling rather than about the bytes being measured.
fn who_of(ctx: &CratestackContext) -> Result<[u8; 32], CratestackError> {
    if let Some(signer) = ctx.verified_signer() {
        return Ok(*signer.thumbprint());
    }
    let subject = ctx
        .auth
        .as_ref()
        .and_then(|identity| identity.fields.get("id"))
        .and_then(|value| match value {
            Value::String(s) => Some(s.clone()),
            _ => None,
        })
        .ok_or_else(|| CratestackError::Unauthorized("authenticate".to_owned()))?;
    // A hex thumbprint is used as itself, so a caller that presents one is the same caller as
    // before; anything else is folded down, so the two spellings can never collide.
    Ok(hex_to_bytes(&subject)
        .and_then(|b| b.try_into().ok())
        .unwrap_or_else(|| fold_identity(&subject)))
}

/// Folds an opaque identity string into 32 bytes.
///
/// Not a hash with a claimed security property: this only has to give two different strings two
/// different keys with overwhelming likelihood, in a server whose whole job is to count bytes.
fn fold_identity(s: &str) -> [u8; 32] {
    // FNV-1a over the bytes, then a second pass with a different offset so the two halves are not
    // the same value repeated (which would make distinct strings collide more easily).
    let mut out = [0_u8; 32];
    for (half, offset) in [
        (0_usize, 0xcbf2_9ce4_8422_2325_u64),
        (16, 0x9e37_79b9_7f4a_7c15),
    ] {
        let mut hash = offset;
        for byte in s.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        out[half..half + 8].copy_from_slice(&hash.to_le_bytes());
        // The second half also mixes the length, so `"a"` and `"aa"` cannot land together.
        out[half + 8..half + 16]
            .copy_from_slice(&(hash ^ u64::try_from(s.len()).unwrap_or(u64::MAX)).to_le_bytes());
    }
    out
}

/// Decodes a lowercase-hex string, or `None` when it is not hex.
#[must_use]
pub fn hex_to_bytes(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

/// Encodes bytes as lowercase hex.
#[must_use]
pub fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, b| {
        let _ = write!(out, "{b:02x}");
        out
    })
}

fn coordinate(name: &str, value: &str) -> Result<[u8; 32], CratestackError> {
    use base64::Engine as _;

    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|e| CratestackError::Validation(format!("{name} is not base64url: {e}")))?;
    bytes
        .try_into()
        .map_err(|_| CratestackError::Validation(format!("{name} is not 32 bytes")))
}

/// The `cose` variant's auth: the envelope layer verified the signature, and its verdict is the
/// only credential. There is no `Authorization` header to read — which is the whole point.
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

/// The plain variants' auth: a `Bearer` header, or nothing.
///
/// **The token is not verified.** This server measures bytes; a real one would check the token. The
/// number this variant produces is therefore a *realistic-size* header, not a working credential,
/// and the report says so rather than implying the baseline is production-shaped.
#[derive(Clone)]
struct BearerAuth;

impl AuthProvider for BearerAuth {
    type Error = CratestackError;

    fn authenticate(
        &self,
        request: &RequestContext<'_>,
    ) -> impl core::future::Future<Output = Result<CratestackContext, Self::Error>> + Send {
        let subject = request
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(ToOwned::to_owned);
        let context = subject.map_or_else(CratestackContext::anonymous, |token| {
            // Any bearer string authenticates, as itself, so who is asking does not change the
            // payloads compared.
            CratestackContext::authenticated([("id".to_owned(), Value::String(token))])
        });
        core::future::ready(Ok(context))
    }
}

/// Builds the server for one [Variant].
///
/// # Errors
/// When the `cose` variant's envelope cannot be built. The other variants cannot fail here, but the
/// signature is shared so a caller has one shape to handle.
pub fn build(
    variant: Variant,
    audience: &str,
    server_scalar: &[u8; 32],
) -> Result<Built, CratestackError> {
    let devices = DeviceKeys::new();
    let exchanges = ExchangeLog::new();
    let procedures = Procedures {
        devices: devices.clone(),
        notes: Arc::default(),
    };
    let db = Cratestack::builder().build();

    let (router, audience_used, jwk) = match variant {
        Variant::Json => (
            cratestack_schema::axum::rpc_router(
                db,
                procedures,
                (),
                JsonCodec,
                BearerAuth,
                cratestack::DEFAULT_BODY_LIMIT_BYTES,
            ),
            String::new(),
            serde_json::Value::Null,
        ),
        Variant::Cbor => (
            cratestack_schema::axum::rpc_router(
                db,
                procedures,
                (),
                CborCodec,
                BearerAuth,
                cratestack::DEFAULT_BODY_LIMIT_BYTES,
            ),
            String::new(),
            serde_json::Value::Null,
        ),
        Variant::Cose => {
            let signer = P256Signer::from_scalar(server_scalar)?;
            let server_key = signer.verify_key();
            let envelope = CoseEnvelope::server(
                CoseMode::Sign1,
                Arc::new(signer),
                Arc::new(devices.clone()),
                Arc::new(InMemoryNonceStore::new()),
            )
            .build()?;
            let layer =
                cratestack_schema::axum::envelope_layer(envelope, mode_of, audience).build()?;
            let router = cratestack_schema::axum::rpc_router(
                db,
                procedures,
                (),
                CborCodec,
                SignerAuth,
                cratestack::DEFAULT_BODY_LIMIT_BYTES,
            )
            .layer(layer);
            (router, audience.to_owned(), jwk_of(&server_key)?)
        }
    };

    // The `cose` key out of the match, so `Built` can hand it to a client that will verify
    // answers. Rebuilt from the same scalar rather than moved out of the match arm, so the arm
    // stays a plain expression.
    let server_key = if variant == Variant::Cose {
        Some(P256Signer::from_scalar(server_scalar)?.verify_key())
    } else {
        None
    };

    // Outermost: the measurement. Outside every other layer on purpose — a refusal from the
    // envelope layer or the codec is a real exchange with a real size, and a comparison that only
    // weighed successful calls would be measuring something else.
    let router = router.layer(cratestack::axum::middleware::from_fn({
        let log = exchanges.clone();
        move |request: cratestack::axum::extract::Request,
              next: cratestack::axum::middleware::Next| {
            measure::measure(log.clone(), request, next)
        }
    }));

    Ok(Built {
        router,
        hello: Hello {
            variant: variant.name().to_owned(),
            audience: audience_used,
            server_public_jwk: jwk,
        },
        devices,
        exchanges,
        server_key,
    })
}

/// The server's JWK, from the verification half of its key.
fn jwk_of(key: &CoseVerifyKey) -> Result<serde_json::Value, CratestackError> {
    use base64::Engine as _;

    let sec1 = key
        .p256_sec1_uncompressed()
        .ok_or_else(|| CratestackError::Internal("the server key is not P-256".to_owned()))?;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    // `04 || x || y`, 65 bytes.
    Ok(serde_json::json!({
        "kty": "EC",
        "crv": "P-256",
        "x": b64.encode(&sec1[1..33]),
        "y": b64.encode(&sec1[33..]),
    }))
}

/// A fresh private scalar for the server's ESP256 key.
///
/// # Errors
/// When the system's random source fails.
pub fn random_scalar() -> Result<[u8; 32], CratestackError> {
    let mut scalar = [0_u8; 32];
    getrandom::fill(&mut scalar)
        .map_err(|e| CratestackError::Internal(format!("no randomness: {e}")))?;
    Ok(scalar)
}
