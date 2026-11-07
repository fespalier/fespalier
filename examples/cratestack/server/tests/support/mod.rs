//! The device's side of the protocol, in Rust: what Dart's `DeviceSigner` and `DeviceAuthBackend`
//! do, with an ES256 key, so a test drives the server the way the app does. The JWS are made with
//! `jsonwebtoken` (test code only: the server itself signs and verifies nothing by hand).

#![allow(dead_code, reason = "each test binary uses a different subset")]
#![allow(clippy::expect_used, clippy::unwrap_used, reason = "tests may unwrap")]
#![allow(
    clippy::needless_pass_by_value,
    clippy::format_collect,
    clippy::struct_field_names,
    reason = "a test rig"
)]

use std::cell::Cell;
use std::collections::HashMap;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cratestack::CratestackCodec as _;
use cratestack::axum::Router;
use cratestack::axum::body::{Body, Bytes, to_bytes};
use cratestack::axum::http::{HeaderMap, Method, Request, StatusCode, header};
use cratestack::serde_json::{self, Value, json};
use cratestack_codec_cbor::CborCodec;
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use orders_demo_server::{Built, Config, DEFAULT_AUDIENCE, DEMO_OTP, build};
use p256::ecdsa::SigningKey;
use p256::pkcs8::EncodePrivateKey as _;
use sha2::{Digest as _, Sha256};

pub const CBOR: &str = "application/cbor";

/// A server, with the test route.
pub struct World {
    pub built: Built,
    pub router: Router,
}

pub async fn world() -> World {
    world_with(Config::default()).await
}

pub async fn world_with(mut config: Config) -> World {
    config.issuer_seed.get_or_insert([0x42; 32]);
    config.test_hooks = true;
    let built = build(&config).await.expect("server");
    let router = built.router.clone();
    World { built, router }
}

pub fn now() -> i64 {
    i64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs(),
    )
    .unwrap()
}

pub fn cbor(value: &Value) -> Vec<u8> {
    CborCodec.encode(value).expect("encode")
}

pub struct Answer {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Bytes,
}

impl Answer {
    /// The decoded body, whichever the content type says.
    pub fn json(&self) -> Value {
        let content_type = self
            .headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        if content_type.starts_with("application/json") {
            serde_json::from_slice(&self.body).expect("json")
        } else if self.body.is_empty() {
            Value::Null
        } else {
            CborCodec.decode(&self.body).expect("cbor")
        }
    }

    /// The envelope's `error` member: the profile's code.
    pub fn error(&self) -> Option<String> {
        self.json()
            .get("error")
            .and_then(Value::as_str)
            .map(str::to_owned)
    }

    /// The `WWW-Authenticate` values.
    pub fn challenges(&self) -> Vec<String> {
        self.headers
            .get_all(header::WWW_AUTHENTICATE)
            .iter()
            .filter_map(|v| v.to_str().ok().map(str::to_owned))
            .collect()
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
    pub body: Vec<u8>,
    pub idempotency_key: Option<String>,
}

impl Parts {
    pub fn rpc(op: &str, input: &Value) -> Self {
        Self {
            method: "POST".to_owned(),
            path: format!("/rpc/procedure.{op}"),
            body: cbor(input),
            idempotency_key: None,
        }
    }

    pub fn request(&self, headers: &[(String, String)]) -> Request<Body> {
        let mut builder = Request::builder()
            .method(Method::from_bytes(self.method.as_bytes()).expect("method"))
            .uri(&self.path)
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

/// An unsigned call.
pub async fn call(world: &World, op: &str, input: &Value) -> Answer {
    send(&world.router, Parts::rpc(op, input).request(&[])).await
}

/// A key role, as the client names it.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Role {
    Ambient,
    UserPresent,
}

impl Role {
    pub fn name(self) -> &'static str {
        match self {
            Role::Ambient => "ambient",
            Role::UserPresent => "userPresent",
        }
    }
}

pub fn key(seed: u8) -> SigningKey {
    SigningKey::from_bytes(&[seed; 32].into()).expect("scalar")
}

pub fn jwk(key: &SigningKey) -> Value {
    let point = key.verifying_key().to_encoded_point(false);
    json!({
        "kty": "EC",
        "crv": "P-256",
        "x": URL_SAFE_NO_PAD.encode(point.x().unwrap()),
        "y": URL_SAFE_NO_PAD.encode(point.y().unwrap()),
    })
}

fn es256(key: &SigningKey, header: Header, claims: &Value) -> String {
    let der = key.to_pkcs8_der().expect("pkcs8");
    jsonwebtoken::encode(&header, claims, &EncodingKey::from_ec_der(der.as_bytes()))
        .expect("signed")
}

/// `{alg: ES256, typ: JWT}` over `{"challenge": ..}`, as `DeviceAuthBackend` signs a challenge.
pub fn sign_challenge(key: &SigningKey, challenge: &str) -> String {
    es256(
        key,
        Header::new(Algorithm::ES256),
        &json!({ "challenge": challenge }),
    )
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The claims of a compact JWS, unverified.
pub fn claims_of(jws: &str) -> Value {
    let payload = jws.split('.').nth(1).expect("a compact JWS");
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).expect("base64url")).expect("json")
}

/// The protected header of a compact JWS.
pub fn header_of(jws: &str) -> Value {
    let head = jws.split('.').next().expect("a compact JWS");
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(head).expect("base64url")).expect("json")
}

/// A device: an ambient key and, unless it is the web's, a user-present key.
pub struct Device {
    pub ambient: SigningKey,
    pub presence: Option<SigningKey>,
    pub device_id: String,
    pub attestations: HashMap<Role, String>,
    jti: Cell<u64>,
}

impl Device {
    pub fn new(seed: u8, user_present: bool) -> Self {
        Self {
            ambient: key(seed),
            presence: user_present.then(|| key(seed.wrapping_add(100))),
            device_id: String::new(),
            attestations: HashMap::new(),
            jti: Cell::new(0),
        }
    }

    pub fn key(&self, role: Role) -> &SigningKey {
        match role {
            Role::Ambient => &self.ambient,
            Role::UserPresent => self.presence.as_ref().expect("a user-present key"),
        }
    }

    /// The code, then the keys with it: the first leg's answer.
    pub async fn begin(&self, world: &World, phone: &str, otp: &str) -> Answer {
        let sent = call(
            world,
            "sendEnrolmentCode",
            &json!({"args": {"phone": phone}}),
        )
        .await;
        if sent.status != StatusCode::OK {
            return sent;
        }
        call(
            world,
            "beginEnrolment",
            &json!({"args": {
                "phone": phone,
                "otp": otp,
                "ambient": jwk(&self.ambient),
                "userPresent": self.presence.as_ref().map(jwk),
            }}),
        )
        .await
    }

    /// Enrols the device by the public legs.
    pub async fn enrol(&mut self, world: &World, phone: &str) -> Answer {
        let begin = self.begin(world, phone, DEMO_OTP).await;
        assert_eq!(begin.status, StatusCode::OK, "{:?}", begin.json());
        let begin = begin.json();
        let confirm = call(
            world,
            "confirmEnrolment",
            &json!({"args": {
                "enrolmentId": begin["enrolmentId"],
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
        URL_SAFE_NO_PAD.encode(format!("jti-{}-{n}", self.device_id))
    }

    /// The `X-Attestation` and `X-Signature` headers for `parts`, as `DeviceSigner.signFor` makes
    /// them: `key` signs, `attestation` is presented.
    pub fn headers_with(
        &self,
        key: &SigningKey,
        attestation: &str,
        parts: &Parts,
    ) -> Vec<(String, String)> {
        let iat = now();
        let mut claims = json!({
            "iat": iat,
            "exp": iat + 120,
            "jti": self.fresh_jti(),
            "mth": parts.method.to_uppercase(),
            "pth": parts.path,
            "aud": DEFAULT_AUDIENCE,
        });
        if !parts.body.is_empty() {
            claims["bdh"] = json!(sha256_hex(&parts.body));
        }
        let mut header = Header::new(Algorithm::ES256);
        header.typ = None;
        header.jwk = Some(serde_json::from_value(jwk(key)).expect("a JWK"));
        vec![
            ("x-attestation".to_owned(), attestation.to_owned()),
            ("x-signature".to_owned(), es256(key, header, &claims)),
        ]
    }

    /// The headers for `parts` with `role`'s key and attestation.
    pub fn headers(&self, role: Role, parts: &Parts) -> Vec<(String, String)> {
        self.headers_with(self.key(role), &self.attestations[&role], parts)
    }

    /// A signed call with `role`'s key.
    pub async fn call(&self, world: &World, role: Role, op: &str, input: &Value) -> Answer {
        let parts = Parts::rpc(op, input);
        send(&world.router, parts.request(&self.headers(role, &parts))).await
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
