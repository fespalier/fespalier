//! The server of fespalier's `cratestack` example: a `CrateStack` `transport rpc` service, no
//! database, in which **a request is signed by the device that sends it** (`fespalier_sign_keypair`,
//! fespalier#267): no password, no token, no `Authorization` header. It is built on the public
//! seams of three projects (fespalier#310), with no cryptography of its own:
//!
//! - **Authkestra verifies and issues.** `authkestra-devsig` verifies every signed request
//!   ([`auth`]); `authkestra-op`'s enrolment and re-issuance handlers issue the attestations
//!   ([`issuer`]).
//! - **`CrateStack` hosts it** through its pluggable-auth seam: [`auth::DeviceAuth`] is an
//!   `AuthProvider`, and its refusals go out as `AuthRefusal`s (cratestack#1243, #1208). Nothing
//!   sits in front of the generated router.
//! - **The step-up rule is in the schema.** `payOrder` declares `@authn(amr: ["user"])`
//!   (cratestack#1244): a request signed by the user-present key has `amr` `["user", "pop"]`
//!   ([`auth::amr_of`]), the ambient key's `["pop"]`, so an ambient-key payment is refused before
//!   the procedure runs with RFC 9470's step-up 401, and the app's session signs it again with the
//!   user-present key and sends it once more.
//!
//! Devices, enrolments, orders, the answers kept under an `Idempotency-Key` and the single-use
//! `jti`s are in memory: a restart forgets them (and a fresh issuer key makes every old
//! attestation `unknown_kid`: pass `--issuer-seed-hex` to keep it).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

use authkestra_devsig::{DeviceIdentity, KeyRole, Refusal, VerifyError};
use cratestack::serde_json::Value as Json;
use cratestack::{CratestackError, include_server_schema};
use cratestack_codec_cbor::CborCodec;

pub mod auth;
pub mod issuer;
mod procedures;
pub mod test_hooks;

use issuer::{Issuer, IssuerConfig};

include_server_schema!("schema.cstack", db = None);

use cratestack_schema::{Cratestack, Order};

/// The `aud` of a signature, unless told otherwise.
pub const DEFAULT_AUDIENCE: &str = "fespalier-cratestack";

/// The one-time code the demo "sends" to every phone number.
pub const DEMO_OTP: &str = "123456";

/// How long an attestation lives, unless told otherwise: a day.
pub const DEFAULT_ATTESTATION_TTL_SECS: u64 = 24 * 60 * 60;

/// How many orders a user may keep (the store is in memory).
pub const MAX_ORDERS: usize = 200;

/// How a server is configured.
#[derive(Clone, Debug)]
pub struct Config {
    /// The `aud` every signature must carry.
    pub audience: String,
    /// How long an attestation lives, in seconds.
    pub attestation_ttl_secs: u64,
    /// How far a clock may differ from this server's, in seconds: 30, profile v1's. A test that
    /// wants an attestation refused as soon as it expires sets 0.
    pub clock_skew_secs: u64,
    /// The issuer's Ed25519 seed; `None` draws a fresh one.
    pub issuer_seed: Option<[u8; 32]>,
    /// Whether `POST /test/revoke` exists ([`test_hooks`]): only for the end-to-end tests.
    pub test_hooks: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            audience: DEFAULT_AUDIENCE.to_owned(),
            attestation_ttl_secs: DEFAULT_ATTESTATION_TTL_SECS,
            clock_skew_secs: authkestra_devsig::RECOMMENDED_CLOCK_SKEW.as_secs(),
            issuer_seed: None,
            test_hooks: false,
        }
    }
}

/// What a client needs to talk to the server, printed by the binary as one JSON line.
#[derive(Clone, Debug)]
pub struct Hello {
    /// The audience a signature must name.
    pub audience: String,
    /// The issuer's public key, as a JWK (with its `kid`): what attestations verify with.
    pub issuer_jwk: Json,
}

/// A configured server.
pub struct Built {
    /// The generated router (and, with `test_hooks`, the one test route).
    pub router: cratestack::axum::Router,
    /// What a client needs.
    pub hello: Hello,
    /// The state, to inspect in tests.
    pub shared: Arc<Shared>,
}

/// A key a device enrolled: its thumbprint, its public JWK, and the attestation last issued for
/// it, which a renewal hands to Authkestra as the one to re-issue.
pub(crate) struct Key {
    pub(crate) jkt: String,
    pub(crate) jwk: Json,
    pub(crate) attestation: String,
}

pub(crate) struct Device {
    pub(crate) phone: String,
    pub(crate) keys: HashMap<KeyRole, Key>,
    pub(crate) revoked: bool,
}

pub(crate) struct SentCode {
    pub(crate) code: String,
    pub(crate) sent: Instant,
    pub(crate) attempts: u8,
}

pub(crate) struct Enrolment {
    pub(crate) created: Instant,
    pub(crate) subject: String,
    pub(crate) phone: String,
    /// The JWK and the challenge Authkestra issued, by role.
    pub(crate) keys: HashMap<KeyRole, (Json, String)>,
}

pub(crate) struct Renewal {
    pub(crate) created: Instant,
    pub(crate) device_id: String,
    pub(crate) role: KeyRole,
}

pub(crate) struct Recorded {
    pub(crate) op: &'static str,
    pub(crate) fingerprint: [u8; 32],
    pub(crate) answer: Order,
    pub(crate) expires: Instant,
}

#[derive(Default)]
pub(crate) struct Store {
    pub(crate) devices: HashMap<String, Device>,
    pub(crate) codes: HashMap<String, SentCode>,
    pub(crate) enrolments: HashMap<String, Enrolment>,
    pub(crate) renewals: HashMap<String, Renewal>,
    pub(crate) orders: HashMap<String, Vec<Order>>,
    /// The answer of a write, by subject and `Idempotency-Key`.
    pub(crate) recorded: HashMap<(String, String), Recorded>,
}

/// Everything the procedures and the provider share.
pub struct Shared {
    pub(crate) issuer: Issuer,
    clock_skew_secs: u64,
    state: Mutex<Store>,
}

impl Shared {
    pub(crate) fn state(&self) -> MutexGuard<'_, Store> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn clock_skew_secs(&self) -> i64 {
        i64::try_from(self.clock_skew_secs).unwrap_or(i64::MAX)
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

    /// How many answers are kept under an `Idempotency-Key`.
    #[must_use]
    pub fn recorded_count(&self) -> usize {
        self.state().recorded.len()
    }

    /// Revokes a device, whoever asks: the operator's side of a revocation ([`test_hooks`]).
    /// `false` when there is no such device.
    pub fn revoke(&self, device_id: &str) -> bool {
        match self.state().devices.get_mut(device_id) {
            Some(device) => {
                device.revoked = true;
                true
            }
            None => false,
        }
    }

    /// Checks a verified request against this server's devices: the profile's refusal when the
    /// device is unknown (`device_not_active`), revoked (`device_revoked`), or signed with a key
    /// it did not enrol for that role (`key_not_bound`).
    pub(crate) fn admit(&self, device: &DeviceIdentity) -> Result<(), Refusal> {
        let state = self.state();
        let Some(known) = state.devices.get(&device.device) else {
            // Signed under this issuer's key, for a device it has no record of (a restart forgot
            // it): the client renews, and the renewal says the device is gone.
            return Err(VerifyError::DeviceNotActive.refusal());
        };
        if known.revoked {
            return Err(Refusal::device_revoked());
        }
        match known.keys.get(&device.key_role()) {
            Some(key) if key.jkt == device.key_thumbprint => Ok(()),
            _ => Err(VerifyError::KeyNotBound.refusal()),
        }
    }
}

/// Seconds since the epoch, by the system clock (Authkestra reads the same one).
pub(crate) fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| {
            i64::try_from(since.as_secs()).unwrap_or(i64::MAX)
        })
}

/// Build the server: the generated RPC router, its auth provider over Authkestra.
///
/// # Errors
/// When there is no randomness, or the issuer key cannot be made.
pub async fn build(config: &Config) -> Result<Built, CratestackError> {
    let issuer = Issuer::new(&IssuerConfig {
        audience: config.audience.clone(),
        attestation_ttl_secs: config.attestation_ttl_secs,
        clock_skew_secs: config.clock_skew_secs,
        seed: config.issuer_seed,
    })
    .await?;
    let hello = Hello {
        audience: config.audience.clone(),
        issuer_jwk: issuer.public_jwk.clone(),
    };
    let shared = Arc::new(Shared {
        issuer,
        clock_skew_secs: config.clock_skew_secs,
        state: Mutex::new(Store::default()),
    });
    let mut router = cratestack_schema::axum::rpc_router(
        Cratestack::builder().build(),
        procedures::Procedures {
            shared: Arc::clone(&shared),
        },
        (),
        CborCodec,
        auth::DeviceAuth {
            shared: Arc::clone(&shared),
        },
        cratestack::DEFAULT_BODY_LIMIT_BYTES,
    );
    if config.test_hooks {
        router = router.merge(test_hooks::routes(Arc::clone(&shared)));
    }
    Ok(Built {
        router,
        hello,
        shared,
    })
}
