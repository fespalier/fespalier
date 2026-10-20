//! The scenario runner: the same sequence of calls, driven through every variant, measured.
//!
//! **In process, with no socket.** The runner builds each request itself (a request line,
//! `content-type`, `accept`, an `authorization` header for the plain variants, and the body) and
//! hands it to the router with `tower::ServiceExt::oneshot`, so it can read the server's own
//! [`ExchangeLog`] back afterwards. That log is where the numbers come from, and it holds the HTTP
//! message as the router received and answered it. A request sent through a client and a socket
//! would also carry `host`, `content-length` and the client's own headers, and its response hyper's
//! `content-length` and `date`; none of that exists here, so the counts are lower bounds
//! (`tests/socket.rs` pins the difference over a real socket).
//!
//! What the runner controls is the *scenario*: which calls, in which order, with which arguments.
//! Every variant runs the identical sequence, so a size difference is the encoding's and not the
//! workload's.

use cratestack::axum::Router;
use cratestack::axum::body::{Body, to_bytes};
use cratestack::axum::http::request::Builder;
use cratestack::axum::http::{Method, Request, header};
use cratestack::cose::{
    CoseEnvelope, CoseMode, CoseSigner, CoseVerifyKey, P256Signer, StaticVerifierResolver,
};
use cratestack::{
    Binding, BoundHeaders, CratestackCodec, CratestackError, PathParams, ResponseBinding,
    find_contract,
    serde_json::{self, Value},
};
use cratestack_codec_cbor::CborCodec;
use cratestack_codec_json::JsonCodec;
use tower::ServiceExt as _;

use crate::payload::Payload;
use crate::scenario::{EnvelopeOverhead, Run, Scenario, Signing};
use crate::{Built, DEFAULT_AUDIENCE, REGISTER_OP, Variant, build, cratestack_schema};

/// The media type of a `COSE_Sign1` message, with the type parameter the server expects.
pub const SIGN1: &str = "application/cose; cose-type=\"cose-sign1\"";

/// The media type of a plain CBOR body.
pub const CBOR: &str = "application/cbor";

/// The media type of a plain JSON body.
pub const JSON: &str = "application/json";

/// Encodes a payload the way one variant's body is encoded.
///
/// Public so that `tests/socket.rs` encodes a body the way the runner does.
///
/// # Errors
/// When the value cannot be encoded.
pub fn encode(variant: Variant, value: &Value) -> Result<Vec<u8>, CratestackError> {
    match variant {
        Variant::Json => JsonCodec.encode(value),
        // The `cose` body is the sealed CBOR payload, not the plain one: the envelope layer
        // unwraps it, and it must be CBOR inside.
        Variant::Cbor | Variant::Cose => CborCodec.encode(value),
    }
}

/// The `Content-Type` a call's body carries.
///
/// Not simply the variant's, because a `cose` server leaves one op plain: `registerDevice` is sent
/// before there is a key to sign with, so the envelope layer passes it through to the CBOR codec
/// and it must be declared as CBOR. Sending it as a `cose-sign1` message is refused with a `415`,
/// which is exactly the mistake this function exists to not make.
fn content_type_for(variant: Variant, op: &str) -> &'static str {
    match variant {
        Variant::Cose if crate::scenario::is_registration(op) => CBOR,
        _ => crate::scenario::content_type_of_variant(variant),
    }
}

/// A device that can sign for the `cose` server, built from its public key.
///
/// The plain variants never call this: they carry a `Bearer` header or nothing, and there is no key
/// to hold.
struct Device {
    signer: P256Signer,
    envelope: CoseEnvelope,
}

impl Device {
    /// A device for the `cose` server in `built`.
    ///
    /// # Errors
    /// When the scalar is not a P-256 key, or the client envelope cannot be built.
    fn new(built: &Built, signing: &Signing) -> Result<Self, CratestackError> {
        let signer = crate::scenario::signer_for(&signing.scalar)?;
        let server_key: CoseVerifyKey = built.cose_server_key()?;
        let resolver = StaticVerifierResolver::new().with_key(server_key);
        let envelope = CoseEnvelope::client(
            CoseMode::Sign1,
            std::sync::Arc::new(crate::scenario::signer_for(&signing.scalar)?)
                as std::sync::Arc<dyn CoseSigner>,
            std::sync::Arc::new(resolver),
        )
        .build()?;
        Ok(Self { signer, envelope })
    }

    /// The `x` and `y` coordinates `registerDevice` takes.
    ///
    /// # Errors
    /// When the key is not a P-256 EC key.
    fn xy(&self) -> Result<(String, String), CratestackError> {
        use base64::Engine as _;

        let sec1 = self
            .signer
            .verify_key()
            .p256_sec1_uncompressed()
            .ok_or_else(|| CratestackError::Internal("the device key is not P-256".to_owned()))?;
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        Ok((b64.encode(&sec1[1..33]), b64.encode(&sec1[33..])))
    }

    /// Seals `payload` for `op`, binding the audience and the contract.
    ///
    /// # Errors
    /// When the payload cannot be sealed.
    async fn seal(
        &self,
        op: &str,
        idempotency_key: Option<&str>,
        payload: &[u8],
    ) -> Result<Vec<u8>, CratestackError> {
        Ok(self
            .envelope
            .seal_request(payload, &binding(op, idempotency_key, None))
            .await?
            .to_vec())
    }
}

/// The binding a signed call is made under: the audience, the op, the contract's hash.
///
/// # Panics
/// When `op` is not an op of the schema. That is a bug in this example rather than a runtime
/// condition — the schema is compiled in, and the runner's op list is a literal beside it — so a
/// missing entry should stop the run loudly instead of being papered over with a zero hash.
fn binding<'a>(
    op: &'a str,
    idempotency_key: Option<&'a str>,
    response: Option<ResponseBinding>,
) -> Binding<'a> {
    let contract_sha = *find_contract(cratestack_schema::OP_CONTRACTS, "POST", op)
        .unwrap_or_else(|| panic!("{op} is not an op of the schema"));
    Binding {
        audience: std::borrow::Cow::Borrowed(DEFAULT_AUDIENCE),
        method: std::borrow::Cow::Borrowed("POST"),
        route: std::borrow::Cow::Borrowed(op),
        path_params: PathParams::EMPTY,
        query: None,
        contract_sha,
        payload_media_type: std::borrow::Cow::Borrowed(CBOR),
        bound_headers: BoundHeaders {
            idempotency_key: idempotency_key.map(std::borrow::Cow::Borrowed),
            if_match: None,
        },
        response,
    }
}

/// Drives a [`Scenario`] against one variant's server, in process, and returns the measurement.
///
/// # Errors
/// When a request cannot be built or sealed. A *refusal* is not an error: it is a measured answer,
/// and one the report wants, so a `403` here is data rather than a failure.
pub async fn run(
    variant: Variant,
    scenario: &Scenario,
    bearer: Option<&str>,
) -> Result<Run, CratestackError> {
    let signing = Signing::fresh()?;
    let built = build(variant, DEFAULT_AUDIENCE, &signing.scalar)?;
    let router = built.router.clone();
    let log = built.exchanges.clone();

    let device = if variant == Variant::Cose {
        Some(Device::new(&built, &signing)?)
    } else {
        None
    };
    let sender = Sender {
        router: &router,
        variant,
        bearer,
        device: device.as_ref(),
    };

    let mut overhead = Vec::new();

    // 1. Register the device. Plain in every variant — the `cose` server leaves it unsigned on
    //    purpose, because a device has to identify itself before it can sign.
    let (x, y) = match &device {
        Some(device) => device.xy()?,
        // The plain variants have no key to register, but the scenario is identical across
        // variants, so they register a key-shaped pair all the same: the *shape* of the payload
        // is what is being measured, not whether the key is real. The coordinates are a real point
        // on the curve, so the server's own validation accepts them.
        None => placeholder_xy()?,
    };
    sender
        .call(
            REGISTER_OP,
            &serde_json::json!({ "args": { "x": x, "y": y } }),
        )
        .await?;

    // 2. Write some notes, then read them back. Every variant sends the same text.
    for i in 0..scenario.writes {
        if let Some(measured) = sender
            .call(
                "procedure.addNote",
                &serde_json::json!({
                    "args": { "text": format!("{} #{i}", scenario.note_text) }
                }),
            )
            .await?
        {
            overhead.push(measured);
        }
    }
    for _ in 0..scenario.reads {
        if let Some(measured) = sender
            .call("procedure.listNotes", &serde_json::json!({ "args": {} }))
            .await?
        {
            overhead.push(measured);
        }
    }

    Ok(Run {
        variant,
        bearer: bearer.is_some(),
        exchanges: log.exchanges(),
        overhead,
    })
}

/// The op the payload sweeps drive: one call carrying a payload of any shape.
pub const PAYLOAD_OP: &str = "procedure.measurePayload";

/// Drives one [`Payload`] through one variant, alone, and returns the measurement.
///
/// A separate entry point from [`run`] because the sweeps need a *shape* (records, nested, blob) that
/// `addNote`'s single `text` field cannot express, and because a sweep wants the payload call on its
/// own rather than behind a registration and a scenario's worth of other calls.
///
/// Registration still happens first: the plain variants need a bearer to be authorized at all, and
/// the `cose` one needs a device key before it can sign. Both are constant across a sweep, so they
/// are paid once per run rather than once per size.
///
/// # Errors
/// When a request cannot be built or sealed. A refusal is a measured answer, not an error.
pub async fn run_payload(
    variant: Variant,
    payload: &Payload,
    bearer: Option<&str>,
) -> Result<Run, CratestackError> {
    let signing = Signing::fresh()?;
    let built = build(variant, DEFAULT_AUDIENCE, &signing.scalar)?;
    let router = built.router.clone();
    let log = built.exchanges.clone();

    let device = if variant == Variant::Cose {
        Some(Device::new(&built, &signing)?)
    } else {
        None
    };
    let sender = Sender {
        router: &router,
        variant,
        bearer,
        device: device.as_ref(),
    };

    let (x, y) = match &device {
        Some(device) => device.xy()?,
        None => placeholder_xy()?,
    };
    sender
        .call(
            REGISTER_OP,
            &serde_json::json!({ "args": { "x": x, "y": y } }),
        )
        .await?;

    // Forgets the registration, so a caller measuring this call sees only this call: two
    // `exchange`s would double the figure an unwary reader adds up.
    log.clear();
    sender
        .call(
            PAYLOAD_OP,
            &serde_json::json!({ "args": { "value": payload.value() } }),
        )
        .await?;

    Ok(Run {
        variant,
        bearer: bearer.is_some(),
        exchanges: log.exchanges(),
        overhead: Vec::new(),
    })
}

/// One variant's way of sending a call, so the scenario loop above reads the same for all of them.
struct Sender<'a> {
    router: &'a Router,
    variant: Variant,
    bearer: Option<&'a str>,
    device: Option<&'a Device>,
}

impl Sender<'_> {
    /// Sends one call and reads the answer.
    ///
    /// The answer's bytes are discarded: the server's measuring layer counted them, and its log is
    /// what the report uses. The call still has to be made, because a request the router never
    /// received is not measured.
    ///
    /// Returns what the envelope added, for a sealed call, so the overhead can be attributed rather
    /// than reported as one unexplained delta.
    async fn call(
        &self,
        op: &str,
        args: &Value,
    ) -> Result<Option<EnvelopeOverhead>, CratestackError> {
        let payload = encode(self.variant, args)?;
        let (body, sealed) = match (self.variant, self.device) {
            (Variant::Cose, Some(device)) if !crate::scenario::is_registration(op) => {
                let sealed = device.seal(op, None, &payload).await?;
                (sealed, true)
            }
            _ => (payload.clone(), false),
        };
        let overhead = if sealed {
            Some(EnvelopeOverhead {
                op: op.to_owned(),
                payload_bytes: payload.len(),
                aad_bytes: device_aad(op)?.len(),
                body_bytes: body.len(),
            })
        } else {
            None
        };
        let request = request_for(self.variant, op, body, self.bearer)?;
        send(self.router, request).await;
        Ok(overhead)
    }
}

/// The external AAD a sealed call of `op` is bound to.
///
/// Reconstructed from the same [`binding`] the sealer used, via the crate's own
/// [`cratestack_cose::external_aad`]: the AAD is not sent (a verifier rebuilds it from the binding),
/// so its size can only be computed, not read from a request. It is reported beside the body, never
/// added to it.
///
/// # Errors
/// When the binding cannot be encoded, which for a non-empty audience it cannot fail.
fn device_aad(op: &str) -> Result<Vec<u8>, CratestackError> {
    cratestack::cose::external_aad(&binding(op, None, None))
}

/// Builds the HTTP request for one call: the headers that variant sends, and the body.
///
/// It sets no `host` and no `content-length`, because no connection is opened; a client on a
/// socket would add both (see the module docs). Public so that `tests/socket.rs` sends the very
/// request the runner sends, with those two added.
///
/// # Errors
/// When the request cannot be built.
pub fn request_for(
    variant: Variant,
    op: &str,
    body: Vec<u8>,
    bearer: Option<&str>,
) -> Result<Request<Body>, CratestackError> {
    let content_type = content_type_for(variant, op);
    let mut builder: Builder = Request::builder()
        .method(Method::POST)
        .uri(format!("/rpc/{op}"))
        .header(header::CONTENT_TYPE, content_type)
        .header(header::ACCEPT, content_type);
    if let Some(token) = bearer {
        builder = builder.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    builder
        .body(Body::from(body))
        .map_err(|e| CratestackError::Internal(format!("request: {e}")))
}

/// Drives the router once and reads the response to the end.
///
/// The response's bytes are not returned. The measuring layer counted them before the router
/// returned ([`crate::measure`]), and that count is the report's; one taken here would be a count
/// of the same message.
async fn send(router: &Router, request: Request<Body>) {
    // `oneshot` is infallible for an axum `Router`: its error type is `Infallible`, so a `Result`
    // here would claim a failure that cannot happen.
    match router.clone().oneshot(request).await {
        Ok(response) => {
            // Read the body to the end, as a client would. The measuring layer has already
            // recorded the exchange by the time the router returns.
            let (_, body) = response.into_parts();
            let _ = to_bytes(body, usize::MAX).await;
        }
        Err(never) => match never {},
    }
}

/// A P-256 public key's coordinates, for the plain variants' key-shaped registration.
///
/// The bytes are a real point on the curve, so the server's own validation accepts them; the
/// private half is thrown away, which is fine because nothing will ever sign with it. Public so
/// that `tests/socket.rs` registers the same kind of key.
///
/// # Errors
/// When the system's random source fails.
pub fn placeholder_xy() -> Result<(String, String), CratestackError> {
    use base64::Engine as _;

    let scalar = crate::random_scalar()?;
    let signer = P256Signer::from_scalar(&scalar)?;
    let sec1 = signer
        .verify_key()
        .p256_sec1_uncompressed()
        .ok_or_else(|| CratestackError::Internal("the key is not P-256".to_owned()))?;
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    Ok((b64.encode(&sec1[1..33]), b64.encode(&sec1[33..])))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::expect_used, reason = "tests may expect")]

    use super::*;

    #[test]
    fn every_variant_has_a_content_type() {
        assert_eq!(content_type_for(Variant::Json, "procedure.listNotes"), JSON);
        assert_eq!(content_type_for(Variant::Cbor, "procedure.listNotes"), CBOR);
        assert_eq!(
            content_type_for(Variant::Cose, "procedure.listNotes"),
            SIGN1
        );
        // A `cose` server's one plain op is declared as CBOR, or the envelope layer refuses it
        // with a `415` before it ever reaches the codec.
        assert_eq!(content_type_for(Variant::Cose, REGISTER_OP), CBOR);
    }

    #[test]
    fn the_placeholder_key_is_a_real_point() {
        let (x, y) = placeholder_xy().expect("a random key");
        assert!(!x.is_empty() && !y.is_empty());
        // A P-256 coordinate is 32 bytes as unpadded base64url, so 43 characters.
        assert_eq!(x.len(), 43, "x should be 32 bytes of base64url");
        assert_eq!(y.len(), 43, "y should be 32 bytes of base64url");
    }

    #[test]
    fn json_bodies_are_json_and_cbor_bodies_are_not() {
        let value = serde_json::json!({ "args": { "limit": 3 } });
        let as_json = encode(Variant::Json, &value).expect("json");
        // A JSON body starts with `{`.
        assert_eq!(as_json[0], b'{');
        let as_cbor = encode(Variant::Cbor, &value).expect("cbor");
        // A CBOR map starts with 0xa0..0xbf.
        assert!(
            (0xa0..=0xbf).contains(&as_cbor[0]),
            "expected a CBOR map, got {:#04x}",
            as_cbor[0]
        );
    }
}
