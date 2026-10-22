//! The server of fespalier's `cratestack` example: a `CrateStack` `transport rpc` service, no
//! database, in which **a request is signed by the device that sends it** (`fespalier_sign_keypair`,
//! fespalier#267): no password, no token, no `Authorization` header.
//!
//! - Four procedures are public (`beginEnrolment`, `confirmEnrolment`, `beginRenewal`,
//!   `confirmRenewal`): they are how a device becomes known and how its attestation is renewed.
//!   They are unsigned **by name**, in [`PUBLIC_OPS`].
//! - Every other request is checked by [`verify_device`], a layer in front of the generated router
//!   that reads the body (the signature covers its exact bytes), runs [`verify::verify`] and
//!   either answers the refusal itself (`401 {"error": code}`, `403 DEVICE_REVOKED`) or hands the
//!   verified device on as a request extension. The check itself could run in an `AuthProvider`
//!   (it sees the method, path, query and exact body, and `/rpc/batch` authenticates once per
//!   request); it is a layer for two reasons: an `AuthProvider` error cannot shape its status and
//!   body, which the client's classifier needs (cratestack/cratestack#1208), and the idempotency
//!   layer, which runs before the handlers and so before `authenticate`, keys on a
//!   `VerifiedPrincipal` that only a layer in front of it can set.
//! - `CrateStack`'s auth seam, [`AuthProvider`], then only turns that extension into the caller the
//!   procedures and their `@allow(auth() != null)` policies see: it never reads a header or a body.
//!
//! The attestation issuer is this server's own P-256 key. Devices, enrolments, orders and the
//! single-use `jti`s are in memory: a restart forgets them (and a random issuer key makes every old
//! attestation `bad_attestation`: pass `--issuer-scalar-hex` to keep them).

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use cratestack::axum::body::{Body, HttpBody as _};
use cratestack::axum::extract::{Request, State};
use cratestack::axum::http::{HeaderValue, Method, StatusCode, header};
use cratestack::axum::middleware::{Next, from_fn, from_fn_with_state};
use cratestack::axum::response::{IntoResponse, Response};
use cratestack::idempotency::{IdempotencyLayer, IdempotencyStore};
use cratestack::ratelimit::VerifiedPrincipal;
use cratestack::serde_json::{Value as Json, json};
use cratestack::{
    AuthProvider, CratestackContext, CratestackError, RequestContext, Value, include_server_schema,
};
use cratestack_codec_cbor::CborCodec;
use p256::ecdsa::{SigningKey, VerifyingKey};

pub mod idempotency;
pub mod jose;
pub mod verify;

use idempotency::MemoryIdempotency;
use jose::{Jwk, random_token, sign_compact, split, verify_es256};
use verify::{Profile, Received, Refusal, Role, SeenJtis, Verified, verify as verify_request};

include_server_schema!("schema.cstack", db = None);

use cratestack_schema::procedures::{self as procs, ProcedureRegistry};
use cratestack_schema::{
    Account, Cratestack, EnrolledDevice, EnrolmentChallenges, Jwk as WireJwk, Order, OrderList,
    RenewalChallenge, Renewed, Revoked,
};

/// The `aud` of a signature, unless told otherwise.
pub const DEFAULT_AUDIENCE: &str = "fespalier-cratestack";

/// The `iss` of every attestation.
pub const ISSUER: &str = "https://issuer.cratestack.example";

/// The one-time code the demo "sends" to every phone number.
pub const DEMO_OTP: &str = "123456";

/// How long an attestation lives, unless told otherwise: a day.
pub const DEFAULT_ATTESTATION_TTL_SECS: i64 = 24 * 60 * 60;

/// The procedures a device calls before it has a session, or to renew one: unsigned, by name.
pub const PUBLIC_OPS: [&str; 4] = [
    "procedure.beginEnrolment",
    "procedure.confirmEnrolment",
    "procedure.beginRenewal",
    "procedure.confirmRenewal",
];

/// How long an enrolment, and a renewal, wait for their second leg, in seconds.
const ENROLMENT_WINDOW: i64 = 10 * 60;
const RENEWAL_WINDOW: i64 = 5 * 60;

/// How many wrong codes an enrolment takes.
const OTP_ATTEMPTS: u8 = 5;

/// How many unfinished enrolments and renewals are held at most.
const PENDING_CAPACITY: usize = 1_000;

/// How long a stored answer is replayed for a retry under the same `Idempotency-Key`.
const IDEMPOTENCY_TTL: std::time::Duration = std::time::Duration::from_hours(24);

/// How many orders a user may keep (the store is in memory).
pub const MAX_ORDERS: usize = 200;

/// Seconds since the epoch.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// The real clock.
#[must_use]
pub fn system_clock() -> Clock {
    Arc::new(|| {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| {
                i64::try_from(since.as_secs()).unwrap_or(i64::MAX)
            })
    })
}

/// How a server is configured.
#[derive(Clone)]
pub struct Config {
    /// The `aud` every signature must carry.
    pub audience: String,
    /// How long an attestation lives, in seconds.
    pub attestation_ttl_secs: i64,
    /// The issuer's private scalar; `None` draws a fresh one.
    pub issuer_scalar: Option<[u8; 32]>,
    /// The clock: seconds since the epoch.
    pub clock: Clock,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            audience: DEFAULT_AUDIENCE.to_owned(),
            attestation_ttl_secs: DEFAULT_ATTESTATION_TTL_SECS,
            issuer_scalar: None,
            clock: system_clock(),
        }
    }
}

/// What a client needs to talk to the server, printed by the binary as one JSON line.
#[derive(Clone, Debug)]
pub struct Hello {
    /// The audience a signature must name.
    pub audience: String,
    /// The issuer's public key, as a JWK: what attestations verify with.
    pub issuer_jwk: Jwk,
}

/// A configured server.
pub struct Built {
    /// The generated router with the verification layer in front.
    pub router: cratestack::axum::Router,
    /// What a client needs.
    pub hello: Hello,
    /// The state, to inspect in tests.
    pub shared: Arc<Shared>,
    /// The idempotency store, to count its keys in tests.
    pub idempotency: Arc<MemoryIdempotency>,
}

struct Device {
    subject: String,
    phone: String,
    keys: HashMap<Role, Jwk>,
    revoked: bool,
}

struct Enrolment {
    created: i64,
    phone: String,
    keys: HashMap<Role, Jwk>,
    challenges: HashMap<Role, String>,
    attempts: u8,
}

struct Renewal {
    created: i64,
    device_id: String,
    role: Role,
    challenge: String,
}

#[derive(Default)]
struct Store {
    devices: HashMap<String, Device>,
    enrolments: HashMap<String, Enrolment>,
    renewals: HashMap<String, Renewal>,
    orders: HashMap<String, Vec<Order>>,
    seen: SeenJtis,
}

/// Everything the procedures and the verification layer share.
pub struct Shared {
    profile: Profile,
    issuer: SigningKey,
    issuer_keys: Vec<VerifyingKey>,
    ttl: i64,
    clock: Clock,
    state: Mutex<Store>,
}

impl Shared {
    fn state(&self) -> MutexGuard<'_, Store> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn now(&self) -> i64 {
        (self.clock)()
    }

    /// How many devices enrolled.
    #[must_use]
    pub fn device_count(&self) -> usize {
        self.state().devices.len()
    }

    /// Whether a device was revoked.
    #[must_use]
    pub fn is_revoked(&self, device_id: &str) -> bool {
        self.state()
            .devices
            .get(device_id)
            .is_some_and(|device| device.revoked)
    }

    /// How many single-use `jti`s are held.
    #[must_use]
    pub fn seen_jti_count(&self) -> usize {
        self.state().seen.len()
    }

    /// An attestation for `role`'s key `jwk` of a device, issued now.
    fn attest(&self, device_id: &str, device: &Device, role: Role, jwk: &Jwk) -> String {
        let now = self.now();
        sign_compact(
            &self.issuer,
            &json!({ "alg": "ES256", "typ": "JWT" }),
            &json!({
                "iss": self.profile.issuer,
                "sub": device.subject,
                "did": device_id,
                "iat": now,
                "exp": now + self.ttl,
                "cnf": { "jkt": jwk.thumbprint() },
                "att": role.name(),
            }),
        )
    }
}

/// Procedures over [`Shared`].
#[derive(Clone)]
struct Procedures {
    shared: Arc<Shared>,
}

/// The caller of a signed request, as [`DeviceAuth`] recorded it.
struct Caller {
    subject: String,
    device_id: String,
    role: Role,
}

fn field(ctx: &CratestackContext, name: &str) -> Option<String> {
    match ctx.auth_field(name)? {
        Value::String(text) => Some(text.clone()),
        _ => None,
    }
}

fn caller(ctx: &CratestackContext) -> Result<Caller, CratestackError> {
    let unsigned = || CratestackError::Unauthorized("sign the request".to_owned());
    Ok(Caller {
        subject: field(ctx, "id").ok_or_else(unsigned)?,
        device_id: field(ctx, "did").ok_or_else(unsigned)?,
        role: field(ctx, "role")
            .and_then(|name| Role::parse(&name))
            .ok_or_else(unsigned)?,
    })
}

fn token(bytes: usize) -> Result<String, CratestackError> {
    random_token(bytes)
        .map_err(|error| CratestackError::Internal(format!("no randomness: {error}")))
}

fn wire_jwk(name: &str, jwk: &WireJwk) -> Result<Jwk, CratestackError> {
    Jwk::parse(&json!({ "kty": jwk.kty, "crv": jwk.crv, "x": jwk.x, "y": jwk.y })).ok_or_else(
        || CratestackError::Validation(format!("field '{name}' is not a P-256 public key")),
    )
}

/// A phone number as the server keeps it: `+`, then 8 to 15 digits, spaces dropped.
fn normalise_phone(phone: &str) -> Result<String, CratestackError> {
    let phone: String = phone.chars().filter(|c| !c.is_whitespace()).collect();
    let digits = phone.strip_prefix('+').unwrap_or_default();
    if (8..=15).contains(&digits.len()) && digits.chars().all(|c| c.is_ascii_digit()) {
        Ok(phone)
    } else {
        Err(CratestackError::Validation(
            "field 'phone' must look like +237 6 55 00 00 00".to_owned(),
        ))
    }
}

/// Whether `signature` is a compact JWS over `{"challenge": challenge}` made by `jwk`.
fn signs_challenge(jwk: &Jwk, signature: &str, challenge: &str) -> bool {
    let (Some(compact), Some(key)) = (split(signature), jwk.verifying_key()) else {
        return false;
    };
    compact.header.get("alg").and_then(Json::as_str) == Some("ES256")
        && compact.claims.get("challenge").and_then(Json::as_str) == Some(challenge)
        && verify_es256(&key, compact.signing_input.as_bytes(), &compact.signature)
}

fn seeded<'a>(orders: &'a mut HashMap<String, Vec<Order>>, subject: &str) -> &'a mut Vec<Order> {
    orders.entry(subject.to_owned()).or_insert_with(|| {
        [
            (1, "Espresso beans", 2, "placed"),
            (2, "Oat milk", 6, "paid"),
        ]
        .into_iter()
        .map(|(id, item, quantity, status)| Order {
            id,
            item: item.to_owned(),
            quantity,
            status: status.to_owned(),
        })
        .collect()
    })
}

fn user_present_only(caller: &Caller) -> Result<(), CratestackError> {
    if caller.role == Role::UserPresent {
        Ok(())
    } else {
        Err(CratestackError::Forbidden(
            "user_presence_required".to_owned(),
        ))
    }
}

#[allow(
    clippy::unused_async_trait_impl,
    reason = "the trait methods are async; this example keeps its state in memory"
)]
impl ProcedureRegistry for Procedures {
    async fn begin_enrolment(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::begin_enrolment::Args,
        _authorized: procs::begin_enrolment::Authorized,
    ) -> Result<procs::begin_enrolment::Output, CratestackError> {
        let args = args.args;
        let phone = normalise_phone(&args.phone)?;
        let mut keys = HashMap::from([(Role::Ambient, wire_jwk("ambient", &args.ambient)?)]);
        if let Some(key) = &args.userPresent {
            keys.insert(Role::UserPresent, wire_jwk("userPresent", key)?);
        }
        let challenges = keys
            .keys()
            .map(|role| Ok((*role, token(24)?)))
            .collect::<Result<HashMap<_, _>, CratestackError>>()?;
        let id = token(16)?;
        let now = self.shared.now();
        let mut state = self.shared.state();
        state
            .enrolments
            .retain(|_, e| e.created + ENROLMENT_WINDOW > now);
        if state.enrolments.len() >= PENDING_CAPACITY {
            return Err(CratestackError::Unavailable(
                "too many enrolments are waiting for their code".to_owned(),
            ));
        }
        // A real server texts the code here; the demo's is always DEMO_OTP.
        let answer = EnrolmentChallenges {
            enrolmentId: id.clone(),
            ambient: challenges[&Role::Ambient].clone(),
            userPresent: challenges.get(&Role::UserPresent).cloned(),
        };
        state.enrolments.insert(
            id,
            Enrolment {
                created: now,
                phone,
                keys,
                challenges,
                attempts: 0,
            },
        );
        Ok(answer)
    }

    async fn confirm_enrolment(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::confirm_enrolment::Args,
        _authorized: procs::confirm_enrolment::Authorized,
    ) -> Result<procs::confirm_enrolment::Output, CratestackError> {
        let args = args.args;
        let now = self.shared.now();
        let device_id = format!("device-{}", token(9)?);
        let mut state = self.shared.state();
        let Some(enrolment) = state
            .enrolments
            .get_mut(&args.enrolmentId)
            .filter(|e| e.created + ENROLMENT_WINDOW > now)
        else {
            return Err(CratestackError::NotFound("enrolment".to_owned()));
        };
        if args.otp != DEMO_OTP {
            enrolment.attempts += 1;
            if enrolment.attempts >= OTP_ATTEMPTS {
                state.enrolments.remove(&args.enrolmentId);
            }
            return Err(CratestackError::Validation(
                "field 'otp' is not the code that was sent".to_owned(),
            ));
        }
        let signatures = HashMap::from([
            (Role::Ambient, Some(args.ambient.as_str())),
            (Role::UserPresent, args.userPresent.as_deref()),
        ]);
        let signed_all = enrolment.keys.iter().all(|(role, jwk)| {
            signatures[role]
                .is_some_and(|sig| signs_challenge(jwk, sig, &enrolment.challenges[role]))
        });
        if !signed_all {
            return Err(CratestackError::Forbidden(
                "a challenge was not signed by the key it was sent for".to_owned(),
            ));
        }
        let Some(enrolment) = state.enrolments.remove(&args.enrolmentId) else {
            return Err(CratestackError::NotFound("enrolment".to_owned()));
        };
        let digits: String = enrolment
            .phone
            .chars()
            .filter(char::is_ascii_digit)
            .collect();
        let device = Device {
            subject: format!("user-{digits}"),
            phone: enrolment.phone,
            keys: enrolment.keys,
            revoked: false,
        };
        let attest = |role| {
            device
                .keys
                .get(&role)
                .map(|jwk| self.shared.attest(&device_id, &device, role, jwk))
        };
        let answer = EnrolledDevice {
            deviceId: device_id.clone(),
            userId: device.subject.clone(),
            phone: device.phone.clone(),
            ambient: attest(Role::Ambient).unwrap_or_default(),
            userPresent: attest(Role::UserPresent),
        };
        state.devices.insert(device_id, device);
        Ok(answer)
    }

    async fn begin_renewal(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::begin_renewal::Args,
        _authorized: procs::begin_renewal::Authorized,
    ) -> Result<procs::begin_renewal::Output, CratestackError> {
        let args = args.args;
        let now = self.shared.now();
        let challenge_id = token(16)?;
        let challenge = token(24)?;
        let mut state = self.shared.state();
        // A device this server does not know, or revoked: the client's session is over.
        let known = state
            .devices
            .get(&args.deviceId)
            .filter(|device| !device.revoked);
        let Some(device) = known else {
            return Err(CratestackError::Forbidden("device_revoked".to_owned()));
        };
        let role = Role::parse(&args.role)
            .filter(|role| device.keys.contains_key(role))
            .ok_or_else(|| {
                CratestackError::Validation("field 'role' is not a key of this device".to_owned())
            })?;
        state
            .renewals
            .retain(|_, r| r.created + RENEWAL_WINDOW > now);
        if state.renewals.len() >= PENDING_CAPACITY {
            return Err(CratestackError::Unavailable(
                "too many renewals are waiting".to_owned(),
            ));
        }
        state.renewals.insert(
            challenge_id.clone(),
            Renewal {
                created: now,
                device_id: args.deviceId,
                role,
                challenge: challenge.clone(),
            },
        );
        Ok(RenewalChallenge {
            challengeId: challenge_id,
            challenge,
        })
    }

    async fn confirm_renewal(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::confirm_renewal::Args,
        _authorized: procs::confirm_renewal::Authorized,
    ) -> Result<procs::confirm_renewal::Output, CratestackError> {
        let args = args.args;
        let now = self.shared.now();
        let mut state = self.shared.state();
        // Single use, whatever the outcome.
        let renewal = state
            .renewals
            .remove(&args.challengeId)
            .filter(|r| r.created + RENEWAL_WINDOW > now)
            .ok_or_else(|| CratestackError::NotFound("renewal".to_owned()))?;
        let device = state
            .devices
            .get(&renewal.device_id)
            .filter(|device| !device.revoked)
            .ok_or_else(|| CratestackError::Forbidden("device_revoked".to_owned()))?;
        let jwk = &device.keys[&renewal.role];
        if !signs_challenge(jwk, &args.signature, &renewal.challenge) {
            return Err(CratestackError::Forbidden(
                "the challenge was not signed by the device's key".to_owned(),
            ));
        }
        Ok(Renewed {
            attestation: self
                .shared
                .attest(&renewal.device_id, device, renewal.role, jwk),
        })
    }

    async fn revoke_device(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::revoke_device::Args,
        _authorized: procs::revoke_device::Authorized,
    ) -> Result<procs::revoke_device::Output, CratestackError> {
        let caller = caller(ctx)?;
        let device_id = args.args.deviceId;
        if device_id != caller.device_id {
            return Err(CratestackError::Forbidden(
                "a device revokes itself and no other".to_owned(),
            ));
        }
        let mut state = self.shared.state();
        let device = state
            .devices
            .get_mut(&device_id)
            .ok_or_else(|| CratestackError::NotFound("device".to_owned()))?;
        // A device that holds a user-present key signs out with it: it prompts.
        if device.keys.contains_key(&Role::UserPresent) {
            user_present_only(&caller)?;
        }
        device.revoked = true;
        Ok(Revoked {
            deviceId: device_id,
        })
    }

    async fn account(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        _args: procs::account::Args,
        _authorized: procs::account::Authorized,
    ) -> Result<procs::account::Output, CratestackError> {
        let caller = caller(ctx)?;
        let state = self.shared.state();
        let device = state
            .devices
            .get(&caller.device_id)
            .ok_or_else(|| CratestackError::NotFound("device".to_owned()))?;
        Ok(Account {
            userId: caller.subject,
            phone: device.phone.clone(),
            deviceId: caller.device_id,
            signedWith: caller.role.name().to_owned(),
        })
    }

    async fn list_orders(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::list_orders::Args,
        _authorized: procs::list_orders::Authorized,
    ) -> Result<procs::list_orders::Output, CratestackError> {
        let caller = caller(ctx)?;
        let limit = args
            .args
            .limit
            .map_or(usize::MAX, |limit| usize::try_from(limit).unwrap_or(0));
        let mut state = self.shared.state();
        let mine = seeded(&mut state.orders, &caller.subject);
        Ok(OrderList {
            orders: mine.iter().take(limit).cloned().collect(),
        })
    }

    async fn get_order(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::get_order::Args,
        _authorized: procs::get_order::Authorized,
    ) -> Result<procs::get_order::Output, CratestackError> {
        let caller = caller(ctx)?;
        let id = args.args.id;
        let mut state = self.shared.state();
        seeded(&mut state.orders, &caller.subject)
            .iter()
            .find(|order| order.id == id)
            .cloned()
            .ok_or_else(|| CratestackError::NotFound(format!("order {id}")))
    }

    async fn place_order(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::place_order::Args,
        _authorized: procs::place_order::Authorized,
    ) -> Result<procs::place_order::Output, CratestackError> {
        let caller = caller(ctx)?;
        let args = args.args;
        let item = args.item.trim().to_owned();
        if item.is_empty() || item.chars().count() > 40 {
            return Err(CratestackError::Validation(
                "field 'item' must be 1 to 40 characters".to_owned(),
            ));
        }
        if !(1..=99).contains(&args.quantity) {
            return Err(CratestackError::Validation(
                "field 'quantity' must be between 1 and 99".to_owned(),
            ));
        }
        let mut state = self.shared.state();
        let mine = seeded(&mut state.orders, &caller.subject);
        if mine.len() >= MAX_ORDERS {
            return Err(CratestackError::Validation(
                "field 'item' cannot be added: this account has as many orders as the demo keeps"
                    .to_owned(),
            ));
        }
        let order = Order {
            id: mine.last().map_or(1, |last| last.id + 1),
            item,
            quantity: args.quantity,
            status: "placed".to_owned(),
        };
        mine.push(order.clone());
        Ok(order)
    }

    async fn pay_order(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::pay_order::Args,
        _authorized: procs::pay_order::Authorized,
    ) -> Result<procs::pay_order::Output, CratestackError> {
        let caller = caller(ctx)?;
        // Paying moves money: only the key that proves the user is there may ask for it.
        user_present_only(&caller)?;
        let id = args.args.id;
        let mut state = self.shared.state();
        let order = seeded(&mut state.orders, &caller.subject)
            .iter_mut()
            .find(|order| order.id == id)
            .ok_or_else(|| CratestackError::NotFound(format!("order {id}")))?;
        if order.status == "paid" {
            return Err(CratestackError::Conflict(format!(
                "order {id} is already paid"
            )));
        }
        "paid".clone_into(&mut order.status);
        Ok(order.clone())
    }
}

/// The device a request was signed by, as [`verify_device`] verified it: a request extension.
#[derive(Clone, Debug)]
struct VerifiedDevice(Verified);

/// Turns the verified device, if the verification layer recorded one, into the caller procedures
/// see. It authenticates exactly when [`verify_device`] verified a device, and trusts nothing else:
/// no header and no body is read here.
#[derive(Clone)]
struct DeviceAuth;

impl AuthProvider for DeviceAuth {
    type Error = CratestackError;

    fn authenticate(
        &self,
        request: &RequestContext<'_>,
    ) -> impl core::future::Future<Output = Result<CratestackContext, Self::Error>> + Send {
        let context = request.extensions.get::<VerifiedDevice>().map_or_else(
            CratestackContext::anonymous,
            |VerifiedDevice(device)| {
                CratestackContext::authenticated([
                    ("id".to_owned(), Value::String(device.subject.clone())),
                    ("did".to_owned(), Value::String(device.device_id.clone())),
                    (
                        "role".to_owned(),
                        Value::String(device.role.name().to_owned()),
                    ),
                ])
            },
        );
        core::future::ready(Ok(context))
    }
}

/// An error answer in the shape both sides read: `CrateStack`'s `{code, message}` envelope for the
/// generated client, and the `error` the device-session classifier (`webankRefusals`) reads.
fn refusal_response(status: StatusCode, error: &str, code: &str, message: &str) -> Response {
    let mut response = (
        status,
        json!({ "error": error, "code": code, "message": message }).to_string(),
    )
        .into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    response
}

fn refused(refusal: Refusal) -> Response {
    match refusal {
        Refusal::Overloaded => refusal_response(
            StatusCode::SERVICE_UNAVAILABLE,
            refusal.code(),
            "unavailable",
            "too many signatures are being remembered",
        ),
        Refusal::Mismatch(claim) => refusal_response(
            StatusCode::UNAUTHORIZED,
            refusal.code(),
            "unauthenticated",
            &format!("the signature's {claim} does not match the request"),
        ),
        other => refusal_response(
            StatusCode::UNAUTHORIZED,
            other.code(),
            "unauthenticated",
            other.code(),
        ),
    }
}

/// How much past the limit is read and thrown away before answering `413`, so the answer is not
/// cut off by a reset (an unbounded drain would defeat the limit).
const DRAIN_PAST_LIMIT: usize = 4 * cratestack::DEFAULT_BODY_LIMIT_BYTES;

/// Reads the request body (up to the codec's limit): the signature covers its exact bytes.
async fn read_body(mut body: Body) -> Result<Vec<u8>, Box<Response>> {
    let limit = cratestack::DEFAULT_BODY_LIMIT_BYTES;
    let (mut kept, mut seen) = (Vec::new(), 0_usize);
    loop {
        match std::future::poll_fn(|cx| Pin::new(&mut body).poll_frame(cx)).await {
            None => break,
            // The connection broke or the body was malformed: not a size problem.
            Some(Err(_)) => return Err(Box::new(StatusCode::BAD_REQUEST.into_response())),
            Some(Ok(frame)) => {
                if let Some(data) = frame.data_ref() {
                    seen = seen.saturating_add(data.len());
                    if seen <= limit {
                        kept.extend_from_slice(data);
                    } else if seen > limit.saturating_add(DRAIN_PAST_LIMIT) {
                        break;
                    }
                }
            }
        }
    }
    if seen > limit {
        return Err(Box::new(StatusCode::PAYLOAD_TOO_LARGE.into_response()));
    }
    Ok(kept)
}

/// Verifies a request and checks that the device it names is enrolled and not revoked, under one
/// lock: the refusal is the response to send.
fn admit(shared: &Shared, received: &Received<'_>) -> Result<Verified, Box<Response>> {
    let mut state = shared.state();
    let Store { devices, seen, .. } = &mut *state;
    let verified = verify_request(
        &shared.profile,
        &shared.issuer_keys,
        received,
        shared.now(),
        seen,
    )
    .map_err(|refusal| Box::new(refused(refusal)))?;
    let Some(device) = devices.get(&verified.device_id) else {
        // Signed by an issuer this server trusts, for a device it has no record of (a restart
        // forgot it): the client renews, and the renewal's answer says the device is gone.
        return Err(Box::new(refusal_response(
            StatusCode::UNAUTHORIZED,
            "device_not_active",
            "unauthenticated",
            "this device is not known",
        )));
    };
    if device.revoked {
        return Err(Box::new(refusal_response(
            StatusCode::FORBIDDEN,
            "DEVICE_REVOKED",
            "permission_denied",
            "this device was revoked",
        )));
    }
    match device.keys.get(&verified.role) {
        Some(jwk) if jwk.thumbprint() == verified.jkt => Ok(verified),
        _ => Err(Box::new(refusal_response(
            StatusCode::UNAUTHORIZED,
            "key_not_bound",
            "unauthenticated",
            "this key is not one of the device's",
        ))),
    }
}

/// The layer in front of the router: verifies a device-signed request before anything else sees it.
///
/// A public procedure ([`PUBLIC_OPS`]) passes as it is. Anything else must carry a valid
/// attestation and signature ([`verify_request`]) from a device that is enrolled and not revoked;
/// the refusal is answered here, with the code the client reads. A verified device goes on as a
/// request extension, and as the `VerifiedPrincipal` the idempotency layer keys on.
async fn verify_device(
    State(shared): State<Arc<Shared>>,
    request: Request,
    next: Next,
) -> Response {
    let (mut parts, body) = request.into_parts();
    let bytes = match read_body(body).await {
        Ok(bytes) => bytes,
        Err(response) => return *response,
    };
    let is_public = parts.method == Method::POST
        && parts
            .uri
            .path()
            .strip_prefix("/rpc/")
            .is_some_and(|op| PUBLIC_OPS.contains(&op));
    if !is_public {
        let header = |name: &str| parts.headers.get(name).and_then(|v| v.to_str().ok());
        let received = Received {
            method: parts.method.as_str(),
            path: parts.uri.path(),
            query: parts.uri.query(),
            attestation: header(shared.profile.attestation_header),
            signature: header(shared.profile.signature_header),
            body: &bytes,
        };
        match admit(&shared, &received) {
            Ok(verified) => {
                parts
                    .extensions
                    .insert(VerifiedPrincipal(verified.subject.clone()));
                parts.extensions.insert(VerifiedDevice(verified));
            }
            Err(response) => return *response,
        }
    }
    next.run(Request::from_parts(parts, Body::from(bytes)))
        .await
}

/// Build the server: the generated RPC router under the verification layer.
///
/// # Errors
/// When the issuer's scalar is not a valid P-256 key, or there is no randomness.
pub fn build(config: &Config) -> Result<Built, CratestackError> {
    let scalar = match config.issuer_scalar {
        Some(scalar) => scalar,
        None => jose::random_scalar()
            .map_err(|error| CratestackError::Internal(format!("no randomness: {error}")))?,
    };
    let issuer = jose::signing_key(&scalar).ok_or_else(|| {
        CratestackError::Internal("the issuer scalar is not a P-256 key".to_owned())
    })?;
    let issuer_public = *issuer.verifying_key();
    let shared = Arc::new(Shared {
        profile: Profile::new(&config.audience, ISSUER),
        issuer,
        issuer_keys: vec![issuer_public],
        ttl: config.attestation_ttl_secs,
        clock: Arc::clone(&config.clock),
        state: Mutex::new(Store::default()),
    });
    let idempotency = Arc::new(MemoryIdempotency::new());
    let router = cratestack_schema::axum::rpc_router(
        Cratestack::builder().build(),
        Procedures {
            shared: Arc::clone(&shared),
        },
        (),
        CborCodec,
        DeviceAuth,
        cratestack::DEFAULT_BODY_LIMIT_BYTES,
    )
    // Inside the verification layer: it sees the user a device belongs to as its principal, so a
    // retry under the same key is replayed.
    .layer(IdempotencyLayer::new(
        Arc::clone(&idempotency) as Arc<dyn IdempotencyStore>,
        IDEMPOTENCY_TTL,
    ))
    // Only a verified device may hold a key: for anyone else the header is dropped, so the store
    // is never reached by a caller who can mint an identity (an unsigned call), and cannot be
    // filled by one.
    .layer(from_fn(keys_for_verified_callers_only))
    .layer(from_fn_with_state(Arc::clone(&shared), verify_device));
    Ok(Built {
        router,
        hello: Hello {
            audience: config.audience.clone(),
            issuer_jwk: Jwk::of(&issuer_public),
        },
        shared,
        idempotency,
    })
}

/// Drops the `Idempotency-Key` of a request no layer verified a device for.
async fn keys_for_verified_callers_only(mut request: Request, next: Next) -> Response {
    if request.extensions().get::<VerifiedPrincipal>().is_none() {
        request.headers_mut().remove("idempotency-key");
    }
    next.run(request).await
}
