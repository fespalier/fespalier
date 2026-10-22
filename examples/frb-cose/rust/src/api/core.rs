//! The surface Dart gets: `lib/src/rust/api/core.dart` is generated from this file. Every type here is a struct
//! or a fieldless enum, and the engine's types are converted at this boundary (`crate::core`).

use std::sync::Arc;

use flutter_rust_bridge::{DartFnFuture, frb};
use tokio::sync::broadcast;

use crate::core::{self as engine, Core};
use crate::frb_generated::StreamSink;

/// The server and the two public keys, as the app reads them from its build configuration.
pub struct CoreConfig {
    /// The server's base URL.
    pub base_url: String,
    /// The audience every sealed message is bound to.
    pub audience: String,
    /// The device key's public x (32 bytes).
    pub device_x: Vec<u8>,
    /// The device key's public y (32 bytes).
    pub device_y: Vec<u8>,
    /// The server's response key, x (32 bytes).
    pub server_x: Vec<u8>,
    /// The server's response key, y (32 bytes).
    pub server_y: Vec<u8>,
}

/// Why a call failed.
pub enum CoreErrorKind {
    /// The server answered without a COSE envelope (`status`). Its body was not read.
    Unsigned,
    /// The server's answer is a COSE message that did not verify.
    Unverified,
    /// The device key did not sign. Nothing was sent.
    Seal,
    /// The request could not be sent, or its answer could not be read.
    Transport,
    /// The op or its arguments are wrong. Nothing was sent.
    BadInput,
    /// The server did not register this device's key.
    Registration,
}

/// A failed call. `message` is the engine's own words and never a server's text.
pub struct CoreError {
    /// The kind, which decides what the app does.
    pub kind: CoreErrorKind,
    /// The HTTP status, for `Unsigned`.
    pub status: Option<u16>,
    /// What went wrong, for a person reading a log.
    pub message: String,
}

/// A sealed answer, opened. A non-2xx status is an answer too: its body carries the server's error code.
pub struct CoreAnswer {
    /// The status the server sealed.
    pub status: u16,
    /// The `Retry-After` in seconds, when the server sent one in that form. It is a hint, not sealed.
    pub retry_after: Option<u32>,
    /// The body, as JSON.
    pub body_json: String,
}

/// What the engine reports.
pub enum CoreEventKind {
    /// The device's key was registered with the server.
    Registered,
    /// The server stopped knowing the device's key, so the next call registers again.
    Forgotten,
    /// A call the engine accepted ended. Its journal row is written first.
    Called,
}

/// One event of the engine's stream.
pub struct CoreEvent {
    /// What happened.
    pub kind: CoreEventKind,
    /// The op of a `Called` event; empty otherwise.
    pub op: String,
}

/// How an accepted call ended.
pub enum JournalOutcome {
    /// The server sealed its answer, and it opened: `status` is the sealed one.
    Answered,
    /// The server answered without a COSE envelope: `status` is its own.
    Unsigned,
    /// The answer did not verify, so it is not the server's word.
    Unverified,
    /// The device key did not sign. Nothing sealed was sent.
    NotSigned,
    /// The device was not registered. Nothing sealed was sent.
    NotRegistered,
    /// The sealed request got no usable answer.
    Unreachable,
    /// The engine refused the call while it was sending it. Nothing sealed was sent.
    Rejected,
}

/// One row of the journal. It holds no payload: no arguments and no body.
pub struct JournalEntry {
    /// The op.
    pub op: String,
    /// The idempotency key the call used; empty for a read.
    pub idempotency_key: String,
    /// How the call ended.
    pub outcome: JournalOutcome,
    /// The HTTP status, when the server answered.
    pub status: Option<u16>,
    /// Whether a sealed request went to the network.
    pub sent: bool,
}

/// The engine's state, read without a call.
pub struct CoreStatus {
    /// Whether the server has registered this device's key.
    pub registered: bool,
    /// The key id (hex) of this device's key.
    pub kid: String,
}

/// The kid and thumbprint of a device key, computed in Rust.
pub struct DeviceIdentity {
    /// The key id (hex).
    pub kid: String,
    /// The RFC 7638 thumbprint (hex).
    pub thumbprint: String,
}

/// The engine, held by Dart as an opaque object.
pub struct NotesCore {
    core: Arc<Core>,
}

impl NotesCore {
    /// Opens the engine. `sign` is the device key: it receives the bytes to sign and answers the signature, or
    /// null when the key does not sign. Nothing is sent and the callback is not called until the first call.
    ///
    /// # Errors
    /// When a point is not on the P-256 curve, the URL does not parse or the HTTP client cannot be built.
    pub fn open(
        config: CoreConfig,
        sign: impl Fn(Vec<u8>) -> DartFnFuture<Option<Vec<u8>>> + Send + Sync + 'static,
    ) -> Result<NotesCore, CoreError> {
        let config = engine::Config {
            base_url: config.base_url,
            audience: config.audience,
            device_x: config.device_x,
            device_y: config.device_y,
            server_x: config.server_x,
            server_y: config.server_y,
        };
        let sign: engine::signer::SignFn = Arc::new(sign);
        let core = Core::open(config, sign)?;
        Ok(NotesCore {
            core: Arc::new(core),
        })
    }

    /// Makes one sealed call. `op` is the procedure's name, `args_json` its arguments, and `idempotency_key` the
    /// key a retry reuses.
    ///
    /// # Errors
    /// Every failure of the engine: a bad op or argument (nothing sent), a device key that did not sign (nothing
    /// sent), an answer the server did not seal, or a network failure.
    pub async fn call(
        &self,
        op: String,
        args_json: String,
        idempotency_key: String,
    ) -> Result<CoreAnswer, CoreError> {
        Ok(self
            .core
            .call(&op, &args_json, &idempotency_key)
            .await?
            .into())
    }

    /// The engine's events: the last few so far, then each new one, until the Dart side cancels.
    // Async only so that flutter_rust_bridge runs it on its async runtime, where `spawn` has a reactor. The body
    // has nothing to await: subscribing and forwarding never block.
    #[allow(
        clippy::unused_async,
        reason = "runs on flutter_rust_bridge's async runtime; see the comment above"
    )]
    pub async fn changes(&self, sink: StreamSink<CoreEvent>) {
        let (backlog, mut events) = self.core.subscribe();
        flutter_rust_bridge::spawn(async move {
            for event in backlog {
                if sink.add(event.into()).is_err() {
                    return;
                }
            }
            loop {
                match events.recv().await {
                    Ok(event) => {
                        if sink.add(event.into()).is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    /// The journal: the rows of the calls the engine accepted, oldest first, the newest 32 of them.
    #[frb(sync)]
    pub fn journal(&self) -> Vec<JournalEntry> {
        self.core.journal().into_iter().map(Into::into).collect()
    }

    /// The engine's state, without a call.
    #[frb(sync)]
    pub fn status(&self) -> CoreStatus {
        let status = self.core.status();
        CoreStatus {
            registered: status.registered,
            kid: status.kid,
        }
    }
}

/// The kid and thumbprint of a device key, from its public x and y.
#[frb(sync)]
pub fn device_identity(device_x: Vec<u8>, device_y: Vec<u8>) -> Result<DeviceIdentity, CoreError> {
    let identity = engine::identity(&device_x, &device_y)?;
    Ok(DeviceIdentity {
        kid: identity.kid,
        thumbprint: identity.thumbprint,
    })
}

impl From<engine::Error> for CoreError {
    fn from(error: engine::Error) -> Self {
        let message = error.to_string();
        let (kind, status) = match error {
            engine::Error::Unsigned { status } => (CoreErrorKind::Unsigned, Some(status)),
            engine::Error::Unverified => (CoreErrorKind::Unverified, None),
            engine::Error::Seal(_) => (CoreErrorKind::Seal, None),
            engine::Error::Transport(_) => (CoreErrorKind::Transport, None),
            engine::Error::BadInput(_) => (CoreErrorKind::BadInput, None),
            engine::Error::Registration(_) => (CoreErrorKind::Registration, None),
        };
        Self {
            kind,
            status,
            message,
        }
    }
}

impl From<engine::Answer> for CoreAnswer {
    fn from(answer: engine::Answer) -> Self {
        Self {
            status: answer.status,
            retry_after: answer.retry_after,
            body_json: answer.body_json,
        }
    }
}

impl From<engine::Event> for CoreEvent {
    fn from(event: engine::Event) -> Self {
        let (kind, op) = match event {
            engine::Event::Registered => (CoreEventKind::Registered, ""),
            engine::Event::Forgotten => (CoreEventKind::Forgotten, ""),
            engine::Event::Called { op } => (CoreEventKind::Called, op),
        };
        Self {
            kind,
            op: op.to_owned(),
        }
    }
}

impl From<engine::JournalEntry> for JournalEntry {
    fn from(entry: engine::JournalEntry) -> Self {
        Self {
            op: entry.op.to_owned(),
            idempotency_key: entry.idempotency_key,
            outcome: entry.outcome.into(),
            status: entry.status,
            sent: entry.sent,
        }
    }
}

impl From<engine::JournalOutcome> for JournalOutcome {
    fn from(outcome: engine::JournalOutcome) -> Self {
        match outcome {
            engine::JournalOutcome::Answered => Self::Answered,
            engine::JournalOutcome::Unsigned => Self::Unsigned,
            engine::JournalOutcome::Unverified => Self::Unverified,
            engine::JournalOutcome::NotSigned => Self::NotSigned,
            engine::JournalOutcome::NotRegistered => Self::NotRegistered,
            engine::JournalOutcome::Unreachable => Self::Unreachable,
            engine::JournalOutcome::Rejected => Self::Rejected,
        }
    }
}
