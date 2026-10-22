//! The device's side of the protocol, in Rust: what Dart's `DeviceSigner` and `DeviceAuthBackend`
//! do, written independently of the server's own verifier, so a test fails when the two disagree.

#![allow(dead_code, reason = "each test binary uses a different subset")]
#![allow(clippy::unused_self, clippy::struct_field_names, reason = "a test rig")]
#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use cratestack::CratestackCodec as _;
use cratestack::axum::Router;
use cratestack::axum::body::{Body, Bytes, to_bytes};
use cratestack::axum::http::{HeaderMap, Method, Request, StatusCode, header};
use cratestack::serde_json::{Value, json};
use cratestack_codec_cbor::CborCodec;
use orders_demo_server::jose::{Jwk, b64, sha256_hex, sign_compact, signing_key, split};
use orders_demo_server::verify::Role;
use orders_demo_server::{Built, Config, DEFAULT_AUDIENCE, DEMO_OTP, build};
use p256::ecdsa::{SigningKey, VerifyingKey};

pub const CBOR: &str = "application/cbor";

/// A server on a clock the test moves.
pub struct World {
    pub built: Built,
    pub router: Router,
    pub clock: Arc<AtomicI64>,
}

pub const START: i64 = 1_800_000_000;

pub fn world() -> World {
    world_with(Config::default())
}

pub fn world_with(mut config: Config) -> World {
    let clock = Arc::new(AtomicI64::new(START));
    let reader = Arc::clone(&clock);
    config.clock = Arc::new(move || reader.load(Ordering::SeqCst));
    config.issuer_scalar = Some([0x42; 32]);
    let built = build(&config).expect("server");
    let router = built.router.clone();
    World {
        built,
        router,
        clock,
    }
}

impl World {
    pub fn now(&self) -> i64 {
        self.clock.load(Ordering::SeqCst)
    }

    pub fn advance(&self, seconds: i64) {
        self.clock.fetch_add(seconds, Ordering::SeqCst);
    }

    pub fn issuer(&self) -> VerifyingKey {
        *signing_key(&[0x42; 32]).expect("scalar").verifying_key()
    }
}

pub fn cbor(value: &Value) -> Vec<u8> {
    CborCodec.encode(value).expect("encode")
}

pub fn from_cbor(bytes: &[u8]) -> Value {
    CborCodec.decode(bytes).expect("decode")
}

pub struct Answer {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl Answer {
    /// The decoded body, whichever the content type says (CBOR for a success, JSON for a refusal
    /// the verification layer wrote).
    pub fn json(&self) -> Value {
        let content_type = self
            .headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if content_type.starts_with("application/json") {
            cratestack::serde_json::from_slice(&self.body).expect("json")
        } else {
            from_cbor(&self.body)
        }
    }

    pub fn error(&self) -> Option<String> {
        self.json()
            .get("error")
            .and_then(Value::as_str)
            .map(str::to_owned)
    }
}

pub async fn send(router: &Router, request: Request<Body>) -> Answer {
    use tower::ServiceExt as _;
    let response = router.clone().oneshot(request).await.expect("infallible");
    let (parts, body) = response.into_parts();
    Answer {
        status: parts.status,
        headers: parts.headers,
        body: to_bytes(body, usize::MAX).await.expect("body"),
    }
}

/// What a signed request is made of, so a test can change one part.
#[derive(Clone)]
pub struct Parts {
    pub method: String,
    pub path: String,
    pub query: Option<String>,
    pub body: Vec<u8>,
    pub idempotency_key: Option<String>,
}

impl Parts {
    pub fn rpc(op: &str, input: &Value) -> Self {
        Self {
            method: "POST".to_owned(),
            path: format!("/rpc/procedure.{op}"),
            query: None,
            body: cbor(input),
            idempotency_key: None,
        }
    }

    pub fn request(&self, headers: &[(String, String)]) -> Request<Body> {
        let uri = match &self.query {
            Some(query) => format!("{}?{query}", self.path),
            None => self.path.clone(),
        };
        let mut builder = Request::builder()
            .method(Method::from_bytes(self.method.as_bytes()).expect("method"))
            .uri(uri)
            .header(header::CONTENT_TYPE, CBOR)
            .header(header::ACCEPT, CBOR);
        if let Some(key) = &self.idempotency_key {
            builder = builder.header("idempotency-key", key);
        }
        for (name, value) in headers {
            builder = builder.header(name, value);
        }
        builder
            .body(Body::from(self.body.clone()))
            .expect("request")
    }
}

/// A device: an ambient key and, unless it is the web's, a user-present key.
pub struct Device {
    pub ambient: SigningKey,
    pub presence: Option<SigningKey>,
    pub device_id: String,
    pub attestations: std::collections::HashMap<Role, String>,
    jti: std::cell::Cell<u64>,
}

pub fn key(seed: u8) -> SigningKey {
    signing_key(&[seed; 32]).expect("scalar")
}

fn wire_jwk(key: &SigningKey) -> Value {
    Jwk::of(key.verifying_key()).to_json()
}

/// `{alg: ES256, typ: JWT}` over `{"challenge": ..}`, as `DeviceAuthBackend` signs a challenge.
pub fn sign_challenge(key: &SigningKey, challenge: &str) -> String {
    sign_compact(
        key,
        &json!({"alg": "ES256", "typ": "JWT"}),
        &json!({ "challenge": challenge }),
    )
}

pub async fn call(world: &World, op: &str, input: &Value) -> Answer {
    send(&world.router, Parts::rpc(op, input).request(&[])).await
}

impl Device {
    pub fn new(seed: u8, user_present: bool) -> Self {
        Self {
            ambient: key(seed),
            presence: user_present.then(|| key(seed.wrapping_add(100))),
            device_id: String::new(),
            attestations: std::collections::HashMap::new(),
            jti: std::cell::Cell::new(0),
        }
    }

    pub fn key(&self, role: Role) -> &SigningKey {
        match role {
            Role::Ambient => &self.ambient,
            Role::UserPresent => self.presence.as_ref().expect("a user-present key"),
        }
    }

    /// Enrols the device by the two public legs.
    pub async fn enrol(&mut self, world: &World, phone: &str) -> Answer {
        let begin = call(
            world,
            "beginEnrolment",
            &json!({"args": {
                "phone": phone,
                "ambient": wire_jwk(&self.ambient),
                "userPresent": self.presence.as_ref().map(wire_jwk),
            }}),
        )
        .await;
        assert_eq!(begin.status, StatusCode::OK, "{:?}", begin.json());
        let begin = begin.json();
        let confirm = call(
            world,
            "confirmEnrolment",
            &json!({"args": {
                "enrolmentId": begin["enrolmentId"],
                "otp": DEMO_OTP,
                "ambient": sign_challenge(&self.ambient, begin["ambient"].as_str().unwrap()),
                "userPresent": self.presence.as_ref().map(|key| {
                    sign_challenge(key, begin["userPresent"].as_str().unwrap())
                }),
            }}),
        )
        .await;
        if confirm.status == StatusCode::OK {
            let done = confirm.json();
            done["deviceId"]
                .as_str()
                .unwrap()
                .clone_into(&mut self.device_id);
            self.attestations
                .insert(Role::Ambient, done["ambient"].as_str().unwrap().to_owned());
            if let Some(attestation) = done["userPresent"].as_str() {
                self.attestations
                    .insert(Role::UserPresent, attestation.to_owned());
            }
        }
        confirm
    }

    fn fresh_jti(&self) -> String {
        let n = self.jti.get() + 1;
        self.jti.set(n);
        b64(format!("jti-{}-{n}", self.device_id).as_bytes())
    }

    /// The `X-Attestation` and `X-Signature` headers for `parts`, as `DeviceSigner.signFor` makes
    /// them, with `iat` the world's clock plus `iat_offset` and a signature that lives `lifetime`.
    pub fn headers(
        &self,
        world: &World,
        role: Role,
        parts: &Parts,
        iat_offset: i64,
        lifetime: i64,
    ) -> Vec<(String, String)> {
        let attestation = self.attestations[&role].clone();
        self.headers_with(
            world,
            self.key(role),
            &attestation,
            parts,
            iat_offset,
            lifetime,
        )
    }

    pub fn headers_with(
        &self,
        world: &World,
        key: &SigningKey,
        attestation: &str,
        parts: &Parts,
        iat_offset: i64,
        lifetime: i64,
    ) -> Vec<(String, String)> {
        let iat = world.now() + iat_offset;
        let mut claims = json!({
            "iat": iat,
            "exp": iat + lifetime,
            "jti": self.fresh_jti(),
            "mth": parts.method.to_uppercase(),
            "pth": if parts.path.is_empty() { "/" } else { &parts.path },
            "aud": DEFAULT_AUDIENCE,
        });
        if let Some(query) = parts.query.as_deref().filter(|q| !q.is_empty()) {
            claims["qsh"] = json!(sha256_hex(query.as_bytes()));
        }
        if !parts.body.is_empty() {
            claims["bdh"] = json!(sha256_hex(&parts.body));
        }
        let signature = sign_compact(key, &json!({"alg": "ES256", "jwk": wire_jwk(key)}), &claims);
        vec![
            ("x-attestation".to_owned(), attestation.to_owned()),
            ("x-signature".to_owned(), signature),
        ]
    }

    /// A signed call with `role`'s key.
    pub async fn call(&self, world: &World, role: Role, op: &str, input: &Value) -> Answer {
        let parts = Parts::rpc(op, input);
        let headers = self.headers(world, role, &parts, 0, 300);
        send(&world.router, parts.request(&headers)).await
    }

    /// A signed call from the ambient key.
    pub async fn ambient(&self, world: &World, op: &str, input: &Value) -> Answer {
        self.call(world, Role::Ambient, op, input).await
    }

    /// The two renewal legs for `role`.
    pub async fn renew(&mut self, world: &World, role: Role) -> Answer {
        let begin = call(
            world,
            "beginRenewal",
            &json!({"args": {"deviceId": self.device_id, "role": role.name()}}),
        )
        .await;
        if begin.status != StatusCode::OK {
            return begin;
        }
        let begin = begin.json();
        let confirm = call(
            world,
            "confirmRenewal",
            &json!({"args": {
                "challengeId": begin["challengeId"],
                "signature": sign_challenge(self.key(role), begin["challenge"].as_str().unwrap()),
            }}),
        )
        .await;
        if confirm.status == StatusCode::OK {
            let attestation = confirm.json()["attestation"].as_str().unwrap().to_owned();
            self.attestations.insert(role, attestation);
        }
        confirm
    }
}

/// The claims of a compact JWS.
pub fn claims_of(jws: &str) -> Value {
    Value::Object(split(jws).expect("a compact JWS").claims)
}
