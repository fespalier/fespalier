//! The client side of a signed exchange, built from `cratestack-cose`'s own sealer: what the
//! Dart sealer of the example has to reproduce byte for byte.

#![allow(dead_code, reason = "each test binary uses a different subset")]
#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::borrow::Cow;
use std::sync::Arc;

pub use cose_demo_server::hex;
use cose_demo_server::{Built, DEFAULT_AUDIENCE, build, cratestack_schema};
use cratestack::axum::Router;
use cratestack::axum::body::{Body, Bytes, to_bytes};
use cratestack::axum::http::{HeaderMap, Method, Request, StatusCode, header};
use cratestack::cose::{
    CoseEnvelope, CoseMode, CoseSigner, P256Signer, StaticVerifierResolver, request_digest,
};
use cratestack::{
    Binding, BoundHeaders, CratestackCodec, PathParams, ResponseBinding, find_contract,
    serde_json::{self, Value},
};
use cratestack_codec_cbor::CborCodec;
use tower::ServiceExt;

pub const SIGN1: &str = "application/cose; cose-type=\"cose-sign1\"";
pub const CBOR: &str = "application/cbor";

/// The server's response key. Fixed, so a failing run can be reproduced.
pub const SERVER_SCALAR: [u8; 32] = [0x11; 32];

pub fn scalar(byte: u8) -> [u8; 32] {
    [byte; 32]
}

/// A running (in-process) server and a device that can sign for it.
pub struct World {
    pub built: Built,
    pub router: Router,
}

pub fn world() -> World {
    let built = build(DEFAULT_AUDIENCE, &SERVER_SCALAR).expect("server");
    let router = built.router.clone();
    World { built, router }
}

/// A device with a P-256 key. `clock` offsets the `iat` it signs with, in seconds.
pub struct Device {
    pub signer: Arc<P256Signer>,
    client: CoseEnvelope,
}

impl Device {
    pub fn new(world: &World, seed: u8, clock_offset: i64) -> Self {
        let signer = Arc::new(P256Signer::from_scalar(&scalar(seed)).expect("scalar"));
        let resolver = StaticVerifierResolver::new().with_key(world.built.server_key.clone());
        let client = CoseEnvelope::client(
            CoseMode::Sign1,
            Arc::clone(&signer) as Arc<dyn CoseSigner>,
            Arc::new(resolver),
        )
        .clock(move || now() + clock_offset)
        .build()
        .expect("client envelope");
        Self { signer, client }
    }

    /// The JWK coordinates `registerDevice` takes.
    pub fn xy(&self) -> (String, String) {
        use base64::Engine as _;
        use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
        let sec1 = self
            .signer
            .verify_key()
            .p256_sec1_uncompressed()
            .expect("P-256");
        (B64.encode(&sec1[1..33]), B64.encode(&sec1[33..]))
    }

    /// `registerDevice`, plain.
    pub async fn register(&self, world: &World) -> Answer {
        let (x, y) = self.xy();
        let payload = cbor(&serde_json::json!({ "args": { "x": x, "y": y } }));
        send(&world.router, plain("procedure.registerDevice", &payload)).await
    }

    /// A sealed call to `op` (`listNotes`, `addNote`, ...).
    pub fn call(&self, op: &'static str, input: &Value) -> Call<'_> {
        Call {
            device: self,
            route: op,
            payload: cbor(input),
            extra: Vec::new(),
        }
    }
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("clock")
        .as_secs()
        .try_into()
        .expect("fits")
}

pub fn cbor(value: &Value) -> Vec<u8> {
    CborCodec.encode(value).expect("encode")
}

pub fn from_cbor(bytes: &[u8]) -> Value {
    CborCodec.decode(bytes).expect("decode")
}

pub fn plain(op: &str, payload: &[u8]) -> Request<Body> {
    Request::builder()
        .method(Method::POST)
        .uri(format!("/rpc/{op}"))
        .header(header::CONTENT_TYPE, CBOR)
        .header(header::ACCEPT, CBOR)
        .body(Body::from(payload.to_vec()))
        .expect("request")
}

/// A call as sealed: the bytes sent, and what its response is bound to.
pub struct Sealed {
    pub bytes: Bytes,
    route: &'static str,
    idempotency_key: Option<String>,
}

pub struct Call<'a> {
    device: &'a Device,
    route: &'static str,
    payload: Vec<u8>,
    extra: Vec<(&'static str, String)>,
}

impl<'a> Call<'a> {
    pub fn header(mut self, name: &'static str, value: impl Into<String>) -> Self {
        self.extra.push((name, value.into()));
        self
    }

    fn binding<'b>(
        route: &'static str,
        idempotency_key: Option<&'b str>,
        response: Option<ResponseBinding>,
    ) -> Binding<'b> {
        Binding {
            audience: Cow::Borrowed(DEFAULT_AUDIENCE),
            method: Cow::Borrowed("POST"),
            route: Cow::Borrowed(route),
            path_params: PathParams::EMPTY,
            query: None,
            contract_sha: *find_contract(cratestack_schema::OP_CONTRACTS, "POST", route)
                .expect("an op of the schema"),
            payload_media_type: Cow::Borrowed(CBOR),
            bound_headers: BoundHeaders {
                idempotency_key: idempotency_key.map(Cow::Borrowed),
                if_match: None,
            },
            response,
        }
    }

    /// Seal the payload; the request carries the headers added with [`Call::header`].
    pub async fn seal(self) -> (Sealed, Request<Body>) {
        let idem = self
            .extra
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("idempotency-key"))
            .map(|(_, value)| value.clone());
        let bytes = self
            .device
            .client
            .seal_request(
                &self.payload,
                &Self::binding(self.route, idem.as_deref(), None),
            )
            .await
            .expect("seal");
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri(format!("/rpc/{}", self.route))
            .header(header::CONTENT_TYPE, SIGN1)
            .header(header::ACCEPT, SIGN1);
        for (name, value) in &self.extra {
            builder = builder.header(*name, value);
        }
        let request = builder.body(Body::from(bytes.clone())).expect("request");
        (
            Sealed {
                bytes,
                route: self.route,
                idempotency_key: idem,
            },
            request,
        )
    }

    /// Seal and send; the answer is checked against the request it answers.
    pub async fn send(self, world: &World) -> Exchange<'a> {
        let device = self.device;
        let (sealed, request) = self.seal().await;
        let answer = send(&world.router, request).await;
        Exchange {
            device,
            sealed,
            answer,
        }
    }
}

pub struct Exchange<'a> {
    device: &'a Device,
    pub sealed: Sealed,
    pub answer: Answer,
}

impl Exchange<'_> {
    /// Verify the answer as a response to this request (kind 1, request digest, status) and
    /// return its CBOR payload as JSON.
    pub async fn open(&self) -> Value {
        let binding = Call::binding(
            self.sealed.route,
            self.sealed.idempotency_key.as_deref(),
            Some(ResponseBinding {
                request: request_digest(&self.sealed.bytes),
                status: self.answer.status.as_u16(),
            }),
        );
        let opened = self
            .device
            .client
            .open_response(self.answer.body.clone(), &binding)
            .await
            .expect("a response sealed by the server key");
        from_cbor(&opened.payload)
    }
}

pub struct Answer {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl Answer {
    pub fn content_type(&self) -> &str {
        self.headers
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
    }

    pub fn is_sealed(&self) -> bool {
        self.content_type() == SIGN1
    }
}

pub async fn send(router: &Router, request: Request<Body>) -> Answer {
    let response = router.clone().oneshot(request).await.expect("infallible");
    let (parts, body) = response.into_parts();
    Answer {
        status: parts.status,
        headers: parts.headers,
        body: to_bytes(body, usize::MAX).await.expect("body"),
    }
}
