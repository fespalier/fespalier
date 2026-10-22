//! The device's registration with the server: the one plain call, made once.
//!
//! The server keeps its registry in memory, so a restart forgets every key. A sealed call the server refuses as
//! unsigned forgets the registration here, and the next call registers again. Registering again is safe: the
//! server keeps one copy of a key it already has.

use std::sync::atomic::{AtomicBool, Ordering};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cratestack::CratestackCodec;
use cratestack::client_rust::{CborCodec, RuntimeRequestWire};
use tokio::sync::Mutex as AsyncMutex;

use super::client::cratestack_schema::{self, client::Client};
use super::{Error, encode};

/// The one plain op. Its request is not sealed: the server does not know the key yet.
const REGISTER_PATH: &str = "/rpc/procedure.registerDevice";

/// The registration state of one device.
pub struct Registrar {
    /// The device's public point, as the server takes it (unpadded base64url).
    device_x: String,
    device_y: String,
    /// The key id the server must answer with.
    kid: String,
    registered: AtomicBool,
    /// Single-flight: a second caller waits for the first registration instead of sending its own.
    gate: AsyncMutex<()>,
}

impl Registrar {
    /// A registrar for the device whose public point is `device_x` and `device_y`, with its key id (hex).
    #[must_use]
    pub fn new(device_x: &[u8], device_y: &[u8], kid: String) -> Self {
        Self {
            device_x: URL_SAFE_NO_PAD.encode(device_x),
            device_y: URL_SAFE_NO_PAD.encode(device_y),
            kid,
            registered: AtomicBool::new(false),
            gate: AsyncMutex::new(()),
        }
    }

    /// The device's key id (hex).
    #[must_use]
    pub fn kid(&self) -> &str {
        &self.kid
    }

    /// Whether the server has registered this device's key, as far as this engine knows.
    #[must_use]
    pub fn is_registered(&self) -> bool {
        self.registered.load(Ordering::SeqCst)
    }

    /// Registers the device unless it is registered. Returns `true` when this call registered it.
    ///
    /// # Errors
    /// [`Error::Registration`] when the server does not answer with the device's own key.
    pub async fn ensure(&self, plain: &Client) -> Result<bool, Error> {
        let _gate = self.gate.lock().await;
        if self.is_registered() {
            return Ok(false);
        }
        let args = cratestack_schema::procedures::register_device::Args {
            args: cratestack_schema::RegisterArgs {
                x: self.device_x.clone(),
                y: self.device_y.clone(),
            },
        };
        let body = encode(&args).ok_or(Error::Registration(REGISTER_UNENCODABLE))?;
        let answer = plain
            .runtime()
            .execute_raw_transport(RuntimeRequestWire {
                method: "POST".into(),
                path: REGISTER_PATH.into(),
                canonical_query: None,
                headers: vec![],
                body,
            })
            .await
            .map_err(|_| Error::Registration(REGISTER_UNANSWERED))?;
        if answer.status_code != 200 {
            return Err(Error::Registration(REGISTER_REFUSED));
        }
        let view: cratestack_schema::DeviceView = CratestackCodec::decode(&CborCodec, &answer.body)
            .map_err(|_| Error::Registration(REGISTER_NOT_A_DEVICE))?;
        if view.kid != self.kid {
            return Err(Error::Registration(REGISTER_OTHER_KEY));
        }
        self.registered.store(true, Ordering::SeqCst);
        Ok(true)
    }

    /// Forgets the registration. Returns `true` when there was one to forget.
    pub fn forget(&self) -> bool {
        self.registered.swap(false, Ordering::SeqCst)
    }
}

const REGISTER_UNENCODABLE: &str = "the device could not be registered";
const REGISTER_UNANSWERED: &str = "the server did not answer the registration";
const REGISTER_REFUSED: &str = "the server refused to register the device";
const REGISTER_NOT_A_DEVICE: &str = "the server's answer to the registration is not a device";
const REGISTER_OTHER_KEY: &str = "the server registered another key";
