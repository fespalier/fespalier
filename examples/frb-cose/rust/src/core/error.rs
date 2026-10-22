//! What the engine reports when a call fails, and how the client's errors map onto it.
//!
//! Every message is a `&'static str` of this crate. A server's text, a client's error text and a caller's own
//! arguments cannot reach a message, so telemetry and a page may show one as it is. The only variable part is a
//! number: an HTTP status.

use std::fmt;

use cratestack::client_rust::{ClientError, EnvelopeError};

/// Why the engine refused or failed a call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// The server answered without a COSE envelope, with this status. Its body was not read.
    Unsigned { status: u16 },
    /// The answer is a COSE message that did not verify, or its key could not be resolved.
    Unverified,
    /// The device key did not sign (the callback answered null, or did not answer in time). Nothing was sent.
    Seal(&'static str),
    /// The sealed request could not be sent, or its answer could not be read.
    Transport(&'static str),
    /// The op, its arguments or its key are wrong. Nothing was attempted.
    BadInput(&'static str),
    /// The server would not register this device's key. Nothing sealed was sent.
    Registration(&'static str),
}

/// The device key did not sign: the callback answered null, or it did not answer within the timeout.
const SEAL: &str = "the device key did not sign, or did not answer in time";
/// The server did not answer, or answered in a way the engine does not read as a COSE message.
const NO_ANSWER: &str = "the server did not answer";
/// The request timed out.
const TIMED_OUT: &str = "the server did not answer in time";
/// The server could not be connected to.
const UNREACHABLE: &str = "the server could not be reached";
/// The sealed answer opened, but its body is not CBOR the engine can write as JSON.
pub(crate) const ANSWER_UNREADABLE: &str = "the answer could not be read";
/// The call cannot be sent in this form.
const NOT_SENT: &str = "the call cannot be sent";

impl Error {
    /// The engine's error for a failure of the sealed client. `EnvelopeError::Seal` is the device key's refusal
    /// (typed by the client, so no flag is needed); a transport failure is named by its class, never by its text.
    pub(crate) fn from_sealed(error: ClientError) -> Self {
        match error {
            ClientError::Envelope(EnvelopeError::Unsigned { status }) => Self::Unsigned { status },
            // The client's contract refusal is an unsigned 426 whose body names the op. The status is what matters.
            ClientError::Envelope(EnvelopeError::ContractUnsupported { .. }) => {
                Self::Unsigned { status: 426 }
            }
            ClientError::Envelope(EnvelopeError::Unverified | EnvelopeError::Open(_)) => {
                Self::Unverified
            }
            ClientError::Envelope(EnvelopeError::Seal(_)) => Self::Seal(SEAL),
            ClientError::Envelope(EnvelopeError::StreamsUnsupported) | ClientError::BadInput(_) => {
                Self::BadInput(NOT_SENT)
            }
            ClientError::Transport(error) if error.reqwest_error().is_timeout() => {
                Self::Transport(TIMED_OUT)
            }
            ClientError::Transport(error) if error.reqwest_error().is_connect() => {
                Self::Transport(UNREACHABLE)
            }
            // Any other failure of the client (a codec, a state or a middleware error): the answer did not come.
            _ => Self::Transport(NO_ANSWER),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
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
