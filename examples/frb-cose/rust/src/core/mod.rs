//! The engine: the `CrateStack` client, sealed as `COSE_Sign1`, with the device key signed through a callback.
//!
//! Pure Rust. `api` adapts these types to the Dart side at the boundary and nothing else reaches Dart.

pub mod client;
pub mod signer;

use std::collections::VecDeque;
use std::fmt::Write as _;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cratestack::CratestackCodec;
use cratestack::client_rust::{
    CborCodec, ClientConfig, ClientEnvelope, ClientError, CratestackClient, EnvelopeError,
    RuntimeHeader, RuntimeRequestWire,
};
use cratestack::cose::{CoseEnvelope, CoseMode, CoseVerifyKey, StaticVerifierResolver};
use tokio::sync::{Mutex as AsyncMutex, broadcast};

use client::cratestack_schema;
use signer::SignFn;

/// The plain op that registers the device's key. It is the one call that is not sealed.
const REGISTER_PATH: &str = "/rpc/procedure.registerDevice";
/// The sealed write of the example's one note procedure.
const ADD_NOTE_PATH: &str = "/rpc/procedure.addNote";
/// How long the TCP connect may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How long one whole request may take.
const TOTAL_TIMEOUT: Duration = Duration::from_secs(30);
/// How many events are kept for a listener that starts late, and how far a live listener may fall behind.
const EVENT_BACKLOG: usize = 64;

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

/// Why the engine refused or failed a call. The messages are the engine's own words: a server's body is never in one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// The server answered without a COSE envelope, with this status. Its body was not read.
    Unsigned { status: u16 },
    /// The answer is a COSE message that did not verify.
    Unverified,
    /// The device key did not sign (the callback answered null, timed out or gave no signature). Nothing was sent.
    Seal(String),
    /// The request could not be sent, or its answer could not be read.
    Transport(String),
    /// The op, its arguments or a key is wrong. Nothing was sent.
    BadInput(String),
    /// The server did not register this device's key.
    Registration(String),
}

/// What the engine reports on its stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// The device's key was registered with the server.
    Registered,
    /// A sealed call was answered, with the op's name.
    Called { op: String },
}

/// A sealed answer, opened: its status and its body as JSON.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Answer {
    /// The status the server sealed.
    pub status: u16,
    /// The body, decoded from CBOR and written as JSON.
    pub body_json: String,
}

/// The engine's state, read without a call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    /// Whether the server has registered this device's key.
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

/// The engine: two `CrateStack` clients over one HTTP client, the device signer, and the event stream.
pub struct Core {
    /// Sealed: every op but the registration.
    sealed: cratestack_schema::client::Client,
    /// Plain: the registration only.
    plain: cratestack_schema::client::Client,
    device_x: String,
    device_y: String,
    kid: String,
    /// Set by the signer when the callback did not sign, so the failing call says `Seal`.
    sign_failed: Arc<AtomicBool>,
    registered: Mutex<bool>,
    /// Single-flight: a second call waits for the first registration instead of sending its own.
    register_gate: AsyncMutex<()>,
    events: Mutex<EventLog>,
}

/// The events so far: the last [`EVENT_BACKLOG`] of them, and the live ones. Both change under one lock, so a
/// listener that subscribes at any time sees every event exactly once: the backlog first, then the rest.
struct EventLog {
    backlog: VecDeque<Event>,
    live: broadcast::Sender<Event>,
}

impl Core {
    /// Builds both clients and the device signer. Nothing is sent: the registration waits for the first call.
    ///
    /// # Errors
    /// When a point is not a P-256 point, the URL does not parse, or the clients cannot be built.
    pub fn open(config: Config, sign: SignFn) -> Result<Self, Error> {
        cratestack::client_rust::ensure_crypto_provider();
        let device = sec1(&config.device_x, &config.device_y)?;
        let kid = hex(&verify_key(&config.device_x, &config.device_y)?.kid());
        let sign_failed = Arc::new(AtomicBool::new(false));
        let signer = signer::device_signer(&device, sign, Arc::clone(&sign_failed))
            .map_err(|error| Error::BadInput(error.to_string()))?;
        let server = verify_key(&config.server_x, &config.server_y)?;
        let envelope = CoseEnvelope::client(
            CoseMode::Sign1,
            Arc::new(signer),
            Arc::new(StaticVerifierResolver::new().with_key(server)),
        )
        .build()
        .map_err(|error| Error::BadInput(error.to_string()))?;
        let envelope = ClientEnvelope::new(envelope, config.audience)
            .map_err(|error| Error::BadInput(error.to_string()))?;
        let url = reqwest::Url::parse(&config.base_url)
            .map_err(|error| Error::BadInput(format!("the server URL: {error}")))?;
        // No redirects: a redirect would send a sealed request somewhere the envelope was not bound to.
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(TOTAL_TIMEOUT)
            .build()
            .map_err(|error| Error::Transport(error.to_string()))?;
        let sealed = CratestackClient::with_http_client(
            ClientConfig::new(url.clone()),
            CborCodec,
            http.clone(),
        )
        .with_envelope(envelope)
        .map_err(|error| Error::BadInput(error.to_string()))?;
        let plain = CratestackClient::with_http_client(ClientConfig::new(url), CborCodec, http);
        let (live, _) = broadcast::channel(EVENT_BACKLOG);
        let events = Mutex::new(EventLog {
            backlog: VecDeque::with_capacity(EVENT_BACKLOG),
            live,
        });
        Ok(Self {
            sealed: cratestack_schema::client::Client::new(sealed),
            plain: cratestack_schema::client::Client::new(plain),
            device_x: URL_SAFE_NO_PAD.encode(&config.device_x),
            device_y: URL_SAFE_NO_PAD.encode(&config.device_y),
            kid,
            sign_failed,
            registered: Mutex::new(false),
            register_gate: AsyncMutex::new(()),
            events,
        })
    }

    /// Makes one sealed call, registering the device first when it is not yet registered.
    ///
    /// `op` is the procedure's name (`addNote`); `args_json` are its arguments as JSON; `idempotency_key`
    /// goes out as the `Idempotency-Key` header, so a retry under the same key replays the same answer.
    ///
    /// # Errors
    /// [`Error::BadInput`] for an unknown op or bad arguments (nothing is sent), [`Error::Seal`] when the
    /// device key did not sign (nothing is sent), and the other kinds for what the server or the network did.
    pub async fn call(
        &self,
        op: &str,
        args_json: &str,
        idempotency_key: &str,
    ) -> Result<Answer, Error> {
        let (path, body) = match op {
            "addNote" => {
                let args: cratestack_schema::NoteArgs =
                    serde_json::from_str(args_json).map_err(|error| {
                        Error::BadInput(format!("the arguments of addNote: {error}"))
                    })?;
                let args = cratestack_schema::procedures::add_note::Args { args };
                (ADD_NOTE_PATH, encode(&args)?)
            }
            other => return Err(Error::BadInput(format!("the core has no op `{other}`"))),
        };
        self.ensure_registered().await?;
        self.sign_failed.store(false, Ordering::SeqCst);
        let sent = self
            .sealed
            .runtime()
            .execute_raw_transport(RuntimeRequestWire {
                method: "POST".into(),
                path: path.into(),
                canonical_query: None,
                headers: vec![RuntimeHeader {
                    name: "Idempotency-Key".into(),
                    value: idempotency_key.into(),
                }],
                body,
            })
            .await;
        let answer = match sent {
            Ok(answer) => answer,
            Err(error) => {
                let error = self.sealed_error(error);
                // The server answered (without a usable envelope): the call happened, so it is reported.
                if matches!(error, Error::Unsigned { .. } | Error::Unverified) {
                    self.emit(Event::Called { op: op.to_owned() });
                }
                return Err(error);
            }
        };
        let value: serde_json::Value = CratestackCodec::decode(&CborCodec, &answer.body)
            .map_err(|error| Error::Transport(error.to_string()))?;
        let body_json =
            serde_json::to_string(&value).map_err(|error| Error::Transport(error.to_string()))?;
        self.emit(Event::Called { op: op.to_owned() });
        Ok(Answer {
            status: answer.status_code,
            body_json,
        })
    }

    /// The events so far (the last [`EVENT_BACKLOG`]) and a receiver of the ones after them. A listener that starts
    /// after a call still sees that call's event, so none is lost to the time a listener takes to start.
    #[must_use]
    pub fn subscribe(&self) -> (Vec<Event>, broadcast::Receiver<Event>) {
        let log = self.events.lock().unwrap_or_else(PoisonError::into_inner);
        (log.backlog.iter().cloned().collect(), log.live.subscribe())
    }

    /// The engine's state, without a call.
    #[must_use]
    pub fn status(&self) -> Status {
        Status {
            registered: *self
                .registered
                .lock()
                .unwrap_or_else(PoisonError::into_inner),
            kid: self.kid.clone(),
        }
    }

    /// Registers the device's key once. Concurrent callers wait for the first one.
    async fn ensure_registered(&self) -> Result<(), Error> {
        let _gate = self.register_gate.lock().await;
        if *self
            .registered
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
        {
            return Ok(());
        }
        let args = cratestack_schema::procedures::register_device::Args {
            args: cratestack_schema::RegisterArgs {
                x: self.device_x.clone(),
                y: self.device_y.clone(),
            },
        };
        let answer = self
            .plain
            .runtime()
            .execute_raw_transport(RuntimeRequestWire {
                method: "POST".into(),
                path: REGISTER_PATH.into(),
                canonical_query: None,
                headers: vec![],
                body: encode(&args)?,
            })
            .await
            .map_err(|error| Error::Transport(error.to_string()))?;
        if answer.status_code != 200 {
            return Err(Error::Registration(format!(
                "the server answered {} to registerDevice",
                answer.status_code
            )));
        }
        let view: cratestack_schema::DeviceView = CratestackCodec::decode(&CborCodec, &answer.body)
            .map_err(|error| Error::Registration(error.to_string()))?;
        if view.kid != self.kid {
            return Err(Error::Registration(
                "the server registered another key".to_owned(),
            ));
        }
        *self
            .registered
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = true;
        self.emit(Event::Registered);
        Ok(())
    }

    /// Records an event and tells the live listeners. With no listener the event is still in the backlog.
    fn emit(&self, event: Event) {
        let mut log = self.events.lock().unwrap_or_else(PoisonError::into_inner);
        if log.backlog.len() == EVENT_BACKLOG {
            log.backlog.pop_front();
        }
        log.backlog.push_back(event.clone());
        let _ = log.live.send(event);
    }

    /// The error of a sealed call. A signature that did not come back is `Seal` whatever the client reported.
    fn sealed_error(&self, error: ClientError) -> Error {
        if self.sign_failed.swap(false, Ordering::SeqCst) {
            return Error::Seal("the device key did not sign".to_owned());
        }
        match error {
            ClientError::Envelope(EnvelopeError::Unsigned { status }) => Error::Unsigned { status },
            ClientError::Envelope(EnvelopeError::Unverified) => Error::Unverified,
            other => Error::Transport(other.to_string()),
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsigned { status } => {
                write!(f, "the server answered {status} without a COSE envelope")
            }
            Self::Unverified => f.write_str("the answer failed COSE verification"),
            Self::Seal(text)
            | Self::Transport(text)
            | Self::BadInput(text)
            | Self::Registration(text) => f.write_str(text),
        }
    }
}

/// The kid and thumbprint of a device key, from its public point.
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

fn encode<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, Error> {
    CratestackCodec::encode(&CborCodec, value).map_err(|error| Error::BadInput(error.to_string()))
}

/// The SEC1 uncompressed point (`0x04 || x || y`) of a P-256 key.
fn sec1(x: &[u8], y: &[u8]) -> Result<Vec<u8>, Error> {
    if x.len() != 32 || y.len() != 32 {
        return Err(Error::BadInput("a P-256 coordinate is 32 bytes".to_owned()));
    }
    let mut point = Vec::with_capacity(65);
    point.push(0x04);
    point.extend_from_slice(x);
    point.extend_from_slice(y);
    Ok(point)
}

fn verify_key(x: &[u8], y: &[u8]) -> Result<CoseVerifyKey, Error> {
    CoseVerifyKey::p256_sec1(&sec1(x, y)?)
        .map_err(|error| Error::BadInput(format!("not a P-256 point: {error}")))
}

/// Lowercase hex, as the server writes a `kid` and a `thumbprint`.
fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}
