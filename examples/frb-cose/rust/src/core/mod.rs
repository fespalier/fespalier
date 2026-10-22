//! The engine: the `CrateStack` client, sealed as `COSE_Sign1`, with the device key signed through a callback.
//!
//! Pure Rust. `api` adapts these types to the Dart side at the boundary and nothing else reaches Dart.
//!
//! A call is accepted when its op, its arguments and its idempotency key are right (`Call::parse`). An accepted call
//! ends with exactly one journal row and one `Called` event, whatever its outcome. A refused call (`BadInput`) has no
//! row: nothing was attempted.

pub mod client;
pub mod error;
pub mod events;
pub mod journal;
pub mod registrar;
pub mod signer;

use std::sync::Arc;
use std::time::Duration;

use cratestack::CratestackCodec;
use cratestack::client_rust::{
    CborCodec, ClientConfig, ClientEnvelope, CratestackClient, RuntimeHeader, RuntimeRequestWire,
    RuntimeResponseWire,
};
use cratestack::cose::{CoseEnvelope, CoseMode, CoseVerifyKey, StaticVerifierResolver};

pub use error::Error;
pub use events::Event;
pub use journal::{Entry as JournalEntry, Outcome as JournalOutcome};

use client::cratestack_schema::{self, procedures};
use events::EventLog;
use journal::Journal;
use registrar::Registrar;
use signer::{SIGN_TIMEOUT, SignFn};

/// The sealed writes and reads of the example's note procedures.
const ADD_NOTE_PATH: &str = "/rpc/procedure.addNote";
const LIST_NOTES_PATH: &str = "/rpc/procedure.listNotes";
/// How long the TCP connect may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How long one whole request may take.
const TOTAL_TIMEOUT: Duration = Duration::from_secs(30);
/// The longest idempotency key: a visible-ASCII header value of this length goes through any proxy.
const MAX_KEY_LEN: usize = 128;

/// The ops the core accepts. Each is a procedure of the schema; `tests/contracts.rs` checks them against the
/// server's `OP_CONTRACTS`. `registerDevice` is not one: the core registers the device itself, plain.
pub const OPS: &[&str] = &["addNote", "listNotes"];

const UNKNOWN_OP: &str = "the core has no op of that name";
const BAD_ARGS: &str = "the arguments are not the op's arguments";
const READ_WITH_KEY: &str = "a read takes no idempotency key";
const WRITE_NEEDS_KEY: &str = "a write needs an idempotency key";
const BAD_KEY: &str = "the idempotency key is not 1 to 128 visible ASCII characters";
const BAD_URL: &str = "the server URL is not a URL";
const BAD_POINT: &str = "not a P-256 point";
const BAD_COORDINATE: &str = "a P-256 coordinate is 32 bytes";
const BAD_CONFIG: &str = "the envelope could not be built";
const CLIENT_UNBUILDABLE: &str = "the HTTP client could not be built";

/// What the engine needs to start. The points are public: the device's and the server's, as x and y (32 bytes each).
#[derive(Clone, Debug)]
pub struct Config {
    /// The server's base URL, `http://` or `https://`.
    pub base_url: String,
    /// The audience every sealed message is bound to.
    pub audience: String,
    /// The device key's public point.
    pub device_x: Vec<u8>,
    /// The device key's public point.
    pub device_y: Vec<u8>,
    /// The server's response key, which the core pins.
    pub server_x: Vec<u8>,
    /// The server's response key, which the core pins.
    pub server_y: Vec<u8>,
}

/// A sealed answer, opened: its status, its `Retry-After` in seconds when the server sent one, and its body as JSON.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Answer {
    /// The status the server sealed.
    pub status: u16,
    /// The `Retry-After` in seconds. It is not sealed (a hint), and only the number form is read.
    pub retry_after: Option<u32>,
    /// The body, decoded from CBOR and written as JSON.
    pub body_json: String,
}

/// The engine's state, read without a call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    /// Whether the server has registered this device's key, as far as the engine knows.
    pub registered: bool,
    /// The key id (hex) of this device's key.
    pub kid: String,
}

/// The kid and the thumbprint of a device key, in hex, as the server writes them in a `DeviceView`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    /// The key id.
    pub kid: String,
    /// The RFC 7638 thumbprint.
    pub thumbprint: String,
}

/// The engine: two `CrateStack` clients over one HTTP client, the registration, the journal and the events.
pub struct Core {
    /// Sealed: every op but the registration.
    sealed: cratestack_schema::client::Client,
    /// Plain: the registration only.
    plain: cratestack_schema::client::Client,
    registrar: Registrar,
    journal: Journal,
    events: EventLog,
}

impl Core {
    /// Builds both clients and the device signer, with the production sign timeout ([`SIGN_TIMEOUT`]). Nothing is
    /// sent: the registration waits for the first call.
    ///
    /// # Errors
    /// When a point is not a P-256 point, the URL does not parse, or the clients cannot be built.
    pub fn open(config: Config, sign: SignFn) -> Result<Self, Error> {
        Self::open_with_timeout(config, sign, SIGN_TIMEOUT)
    }

    /// [`Core::open`] with another sign timeout. The tests use a short one, so a callback that never answers is
    /// checked in milliseconds.
    ///
    /// # Errors
    /// The same as [`Core::open`].
    pub fn open_with_timeout(
        config: Config,
        sign: SignFn,
        sign_timeout: Duration,
    ) -> Result<Self, Error> {
        cratestack::client_rust::ensure_crypto_provider();
        let device = sec1(&config.device_x, &config.device_y)?;
        let kid = hex(&verify_key(&config.device_x, &config.device_y)?.kid());
        let signer = signer::device_signer_within(&device, sign, sign_timeout)
            .map_err(|_| Error::BadInput(BAD_POINT))?;
        let server = verify_key(&config.server_x, &config.server_y)?;
        let envelope = CoseEnvelope::client(
            CoseMode::Sign1,
            Arc::new(signer),
            Arc::new(StaticVerifierResolver::new().with_key(server)),
        )
        .build()
        .map_err(|_| Error::BadInput(BAD_CONFIG))?;
        let envelope = ClientEnvelope::new(envelope, config.audience)
            .map_err(|_| Error::BadInput(BAD_CONFIG))?;
        let url = reqwest::Url::parse(&config.base_url).map_err(|_| Error::BadInput(BAD_URL))?;
        // No redirects: a redirect would send a sealed request somewhere the envelope was not bound to.
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(TOTAL_TIMEOUT)
            .build()
            .map_err(|_| Error::Transport(CLIENT_UNBUILDABLE))?;
        let sealed = CratestackClient::with_http_client(
            ClientConfig::new(url.clone()),
            CborCodec,
            http.clone(),
        )
        .with_envelope(envelope)
        .map_err(|_| Error::BadInput(BAD_CONFIG))?;
        let plain = CratestackClient::with_http_client(ClientConfig::new(url), CborCodec, http);
        Ok(Self {
            sealed: cratestack_schema::client::Client::new(sealed),
            plain: cratestack_schema::client::Client::new(plain),
            registrar: Registrar::new(&config.device_x, &config.device_y, kid),
            journal: Journal::default(),
            events: EventLog::default(),
        })
    }

    /// Makes one sealed call, registering the device first when it is not registered.
    ///
    /// `op` is the procedure's name (`addNote` or `listNotes`) and `args_json` its arguments as JSON. A write
    /// (`addNote`) needs `idempotency_key`, which goes out as the `Idempotency-Key` header, so a retry under the same
    /// key replays the same answer. A read sends no key, because a replayed read would be a stale one.
    ///
    /// # Errors
    /// [`Error::BadInput`] for an unknown op, bad arguments or a bad key (nothing is attempted). The other kinds are
    /// what the device key, the registration, the server or the network did.
    pub async fn call(
        &self,
        op: &str,
        args_json: &str,
        idempotency_key: &str,
    ) -> Result<Answer, Error> {
        let call = Call::parse(op, args_json, idempotency_key)?;
        let result = self.send(&call).await;
        self.journal
            .record(JournalEntry::of(call.op, &call.key, &result));
        self.events.emit(Event::Called { op: call.op });
        result
    }

    /// The backlog of events (the last [`events::BACKLOG`]) and a receiver of the ones after it.
    #[must_use]
    pub fn subscribe(&self) -> (Vec<Event>, tokio::sync::broadcast::Receiver<Event>) {
        self.events.subscribe()
    }

    /// The journal's rows, oldest first.
    #[must_use]
    pub fn journal(&self) -> Vec<JournalEntry> {
        self.journal.entries()
    }

    /// The engine's state, without a call.
    #[must_use]
    pub fn status(&self) -> Status {
        Status {
            registered: self.registrar.is_registered(),
            kid: self.registrar.kid().to_owned(),
        }
    }

    /// Registers if needed, seals the call and opens the answer.
    async fn send(&self, call: &Call) -> Result<Answer, Error> {
        if self.registrar.ensure(&self.plain).await? {
            self.events.emit(Event::Registered);
        }
        let headers = if call.write {
            vec![RuntimeHeader {
                name: "Idempotency-Key".into(),
                value: call.key.clone(),
            }]
        } else {
            vec![]
        };
        let sent = self
            .sealed
            .runtime()
            .execute_raw_transport(RuntimeRequestWire {
                method: "POST".into(),
                path: call.path.into(),
                canonical_query: None,
                headers,
                body: call.body.clone(),
            })
            .await;
        match sent {
            Ok(answer) => open_answer(&answer),
            Err(error) => {
                let error = Error::from_sealed(error);
                // The server does not know this key (a restart, or a registry that was reset): the registration is
                // gone, and the next call registers again.
                if matches!(error, Error::Unsigned { status: 401 }) && self.registrar.forget() {
                    self.events.emit(Event::Forgotten);
                }
                Err(error)
            }
        }
    }
}

/// One accepted call: the op's path, its arguments as CBOR, and the key a write sends.
struct Call {
    op: &'static str,
    path: &'static str,
    body: Vec<u8>,
    /// The idempotency key of a write; empty for a read.
    key: String,
    write: bool,
}

impl Call {
    /// Checks the op, the arguments and the key, and encodes the arguments.
    fn parse(op: &str, args_json: &str, key: &str) -> Result<Self, Error> {
        match op {
            "addNote" => {
                check_key(key)?;
                let args: cratestack_schema::NoteArgs =
                    serde_json::from_str(args_json).map_err(|_| Error::BadInput(BAD_ARGS))?;
                let body = encode(&procedures::add_note::Args { args })
                    .ok_or(Error::BadInput(BAD_ARGS))?;
                Ok(Self {
                    op: "addNote",
                    path: ADD_NOTE_PATH,
                    body,
                    key: key.to_owned(),
                    write: true,
                })
            }
            "listNotes" => {
                if !key.is_empty() {
                    return Err(Error::BadInput(READ_WITH_KEY));
                }
                let args: cratestack_schema::ListArgs =
                    serde_json::from_str(args_json).map_err(|_| Error::BadInput(BAD_ARGS))?;
                let body = encode(&procedures::list_notes::Args { args })
                    .ok_or(Error::BadInput(BAD_ARGS))?;
                Ok(Self {
                    op: "listNotes",
                    path: LIST_NOTES_PATH,
                    body,
                    key: String::new(),
                    write: false,
                })
            }
            _ => Err(Error::BadInput(UNKNOWN_OP)),
        }
    }
}

/// The key of a write: visible ASCII, at most [`MAX_KEY_LEN`] bytes.
fn check_key(key: &str) -> Result<(), Error> {
    if key.is_empty() {
        return Err(Error::BadInput(WRITE_NEEDS_KEY));
    }
    if key.len() > MAX_KEY_LEN || !key.bytes().all(|byte| byte.is_ascii_graphic()) {
        return Err(Error::BadInput(BAD_KEY));
    }
    Ok(())
}

/// The opened answer, as the app reads it. A body the engine cannot write as JSON is a transport failure.
fn open_answer(answer: &RuntimeResponseWire) -> Result<Answer, Error> {
    let value: serde_json::Value = CratestackCodec::decode(&CborCodec, &answer.body)
        .map_err(|_| Error::Transport(error::ANSWER_UNREADABLE))?;
    let body_json =
        serde_json::to_string(&value).map_err(|_| Error::Transport(error::ANSWER_UNREADABLE))?;
    let retry_after = answer
        .headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case("retry-after"))
        .and_then(|header| header.value.trim().parse::<u32>().ok());
    Ok(Answer {
        status: answer.status_code,
        retry_after,
        body_json,
    })
}

/// The kid and thumbprint of a device key, from its public x and y.
///
/// # Errors
/// When a coordinate is not 32 bytes or the point is not on the P-256 curve.
pub fn identity(x: &[u8], y: &[u8]) -> Result<Identity, Error> {
    let key = verify_key(x, y)?;
    Ok(Identity {
        kid: hex(&key.kid()),
        thumbprint: hex(&key.thumbprint()),
    })
}

fn encode<T: serde::Serialize>(value: &T) -> Option<Vec<u8>> {
    CratestackCodec::encode(&CborCodec, value).ok()
}

/// The SEC1 uncompressed point (`0x04 || x || y`) of a P-256 key.
fn sec1(x: &[u8], y: &[u8]) -> Result<Vec<u8>, Error> {
    if x.len() != 32 || y.len() != 32 {
        return Err(Error::BadInput(BAD_COORDINATE));
    }
    let mut point = Vec::with_capacity(65);
    point.push(0x04);
    point.extend_from_slice(x);
    point.extend_from_slice(y);
    Ok(point)
}

fn verify_key(x: &[u8], y: &[u8]) -> Result<CoseVerifyKey, Error> {
    CoseVerifyKey::p256_sec1(&sec1(x, y)?).map_err(|_| Error::BadInput(BAD_POINT))
}

/// Lowercase hex, as the server writes a `kid` and a `thumbprint`.
fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}
