//! The scenario a run drives, and what it cost.
//!
//! [`crate::measure`] is the measurement; [`crate::runner`] is the sending. This module is the
//! vocabulary the two share — what a run *is* ([`Scenario`]), what it *cost* ([`Run`]), and the one
//! table that says how each variant names its body ([`content_type_of_variant`]).
//!
//! **The counts come from the server's measuring layer**, not from the runner's own bookkeeping, so
//! the runner cannot count a header it meant to send and did not. They are the HTTP message as the
//! handler stack saw it: `host`, `content-length`, hyper's `date` and TCP/TLS framing are not part
//! of them (see [`crate::measure`]), so they are lower bounds.

use cratestack::CratestackError;
use cratestack::cose::{CoseMode, P256Signer};

use crate::measure::Exchange;
use crate::{REGISTER_OP, Variant};

/// What one variant's run cost, as the server's measuring layer counted it.
#[derive(Clone, Debug)]
pub struct Run {
    /// The variant measured.
    pub variant: Variant,
    /// Whether the run carried a `Bearer` header.
    pub bearer: bool,
    /// Every exchange the server measured, in order.
    pub exchanges: Vec<Exchange>,
    /// What the envelope added to each sealed call, in the same order as [`Run::sealed`].
    pub overhead: Vec<EnvelopeOverhead>,
}

/// What a `COSE_Sign1` envelope costs beyond the payload it carries.
///
/// Attribution rather than a single unexplained delta: the payload is what the runner encoded, the
/// external AAD is what [`cratestack::cose::external_aad`] builds for the binding, and the rest is
/// the protected header, the 64-byte ESP256 signature and the CBOR framing around all three.
#[derive(Clone, Debug)]
pub struct EnvelopeOverhead {
    /// The op this sealed.
    pub op: String,
    /// The CBOR payload the envelope wrapped, as the runner encoded it.
    pub payload_bytes: usize,
    /// The external AAD the signature is bound to.
    pub aad_bytes: usize,
    /// The whole `COSE_Sign1` body, as the runner sent it.
    pub body_bytes: usize,
}

impl EnvelopeOverhead {
    /// Everything the envelope added: the body minus the payload it carries.
    ///
    /// The external AAD is *not* in the body — it is reconstructed by the verifier from the binding
    /// — so it is reported separately and never counted here. Adding it would count bytes that are
    /// not in the message.
    #[must_use]
    pub fn added_bytes(&self) -> usize {
        self.body_bytes.saturating_sub(self.payload_bytes)
    }

    /// The added bytes as a percentage of the payload they wrap, or `None` for an empty payload.
    #[must_use]
    pub fn added_percent(&self) -> Option<f64> {
        if self.payload_bytes == 0 {
            return None;
        }
        #[allow(
            clippy::cast_precision_loss,
            reason = "a byte count is far below f64's exact-integer range"
        )]
        Some((self.added_bytes() as f64 / self.payload_bytes as f64) * 100.0)
    }
}

impl Run {
    /// Every request byte the router received: the request line (rebuilt), the headers and the body.
    #[must_use]
    pub fn server_request_total(&self) -> usize {
        self.exchanges
            .iter()
            .map(Exchange::request_total_bytes)
            .sum()
    }

    /// Every response byte the router produced: the status line (rebuilt), the headers and the body.
    #[must_use]
    pub fn server_response_total(&self) -> usize {
        self.exchanges
            .iter()
            .map(Exchange::response_total_bytes)
            .sum()
    }

    /// The exchanges of one op, oldest first.
    #[must_use]
    pub fn of_op(&self, op: &str) -> Vec<&Exchange> {
        self.exchanges
            .iter()
            .filter(|e| e.path.ends_with(op))
            .collect()
    }

    /// The sealed calls of this run, oldest first.
    #[must_use]
    pub fn sealed(&self) -> &[EnvelopeOverhead] {
        &self.overhead
    }

    /// Every added byte across this run's sealed calls.
    #[must_use]
    pub fn added_total(&self) -> usize {
        self.overhead
            .iter()
            .map(EnvelopeOverhead::added_bytes)
            .sum()
    }

    /// Every payload byte across this run's sealed calls.
    #[must_use]
    pub fn payload_total(&self) -> usize {
        self.overhead.iter().map(|o| o.payload_bytes).sum()
    }

    /// Whether every call in this run succeeded.
    #[must_use]
    pub fn all_succeeded(&self) -> bool {
        self.exchanges.iter().all(|e| e.status == 200)
    }
}

/// A scenario: what a run sends, so every variant sends exactly the same thing.
///
/// The `Bearer` token is not here: it is a property of the *run* ([`crate::runner::run`] takes it),
/// not of the calls, because the same scenario is measured with and without one. A field here would
/// be a second place to set it, and the two could disagree.
#[derive(Clone, Debug)]
pub struct Scenario {
    /// How many reads to make after registering.
    pub reads: usize,
    /// How many notes to write.
    pub writes: usize,
    /// The note text, the same for every write.
    pub note_text: String,
}

impl Default for Scenario {
    fn default() -> Self {
        Self {
            reads: 3,
            writes: 2,
            note_text: "a note of a typical length".to_owned(),
        }
    }
}

/// The `Content-Type` a variant's body carries.
///
/// One place, so the variant table is stated once and the runner cannot drift from it.
#[must_use]
pub fn content_type_of_variant(variant: Variant) -> &'static str {
    match variant {
        Variant::Json => "application/json",
        Variant::Cbor => "application/cbor",
        Variant::Cose => "application/cose; cose-type=\"cose-sign1\"",
    }
}

/// A server's ESP256 key and the audience its messages are bound to, for the `cose` variant.
pub struct Signing {
    /// The private scalar the server signs answers with.
    pub scalar: [u8; 32],
    /// The audience.
    pub audience: String,
}

impl Signing {
    /// A fresh signing setup.
    ///
    /// # Errors
    /// When the system's random source fails.
    pub fn fresh() -> Result<Self, CratestackError> {
        Ok(Self {
            scalar: crate::random_scalar()?,
            audience: crate::DEFAULT_AUDIENCE.to_owned(),
        })
    }
}

/// A P-256 signer from a scalar: the server's, or a device's.
///
/// The server and the device each build their signer from a scalar through this one function, so
/// the construction is in one place instead of two.
///
/// # Errors
/// When the scalar is not a valid P-256 key.
pub fn signer_for(scalar: &[u8; 32]) -> Result<P256Signer, CratestackError> {
    P256Signer::from_scalar(scalar)
}

/// The op id of a call a runner makes, for the report.
#[must_use]
pub fn is_registration(op: &str) -> bool {
    op == REGISTER_OP
}

/// The mode a `cose` server seals with, so a runner asserts the policy the server really built
/// rather than assuming one.
#[must_use]
pub fn cose_mode() -> CoseMode {
    CoseMode::Sign1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exchange(path: &str, body: usize) -> Exchange {
        Exchange {
            method: "POST".to_owned(),
            path: path.to_owned(),
            request_headers: vec![("content-type".to_owned(), "application/cbor".to_owned())],
            request_body_bytes: body,
            status: 200,
            response_headers: vec![],
            response_body_bytes: 4,
        }
    }

    #[test]
    fn a_run_totals_what_the_server_saw() {
        let run = Run {
            variant: Variant::Cbor,
            bearer: false,
            exchanges: vec![
                exchange("/rpc/procedure.registerDevice", 70),
                exchange("/rpc/procedure.listNotes", 4),
            ],
            overhead: Vec::new(),
        };
        assert_eq!(
            run.server_request_total(),
            run.exchanges
                .iter()
                .map(Exchange::request_total_bytes)
                .sum::<usize>()
        );
        assert_eq!(
            run.server_response_total(),
            run.exchanges
                .iter()
                .map(Exchange::response_total_bytes)
                .sum::<usize>()
        );
    }

    #[test]
    fn an_op_can_be_pulled_out_of_a_run() {
        let run = Run {
            variant: Variant::Cbor,
            bearer: false,
            exchanges: vec![
                exchange("/rpc/procedure.registerDevice", 70),
                exchange("/rpc/procedure.listNotes", 4),
                exchange("/rpc/procedure.listNotes", 4),
            ],
            overhead: Vec::new(),
        };
        assert_eq!(run.of_op("procedure.listNotes").len(), 2);
        assert_eq!(run.of_op("procedure.registerDevice").len(), 1);
    }

    #[test]
    fn every_variant_has_a_content_type() {
        assert_eq!(content_type_of_variant(Variant::Json), "application/json");
        assert_eq!(content_type_of_variant(Variant::Cbor), "application/cbor");
        assert!(
            content_type_of_variant(Variant::Cose).starts_with("application/cose"),
            "a sealed body is a COSE message"
        );
    }

    #[test]
    fn the_aad_is_never_counted_in_the_added_bytes() {
        let overhead = EnvelopeOverhead {
            op: "procedure.listNotes".to_owned(),
            payload_bytes: 10,
            aad_bytes: 99,
            body_bytes: 120,
        };
        // The body minus the payload: the AAD is rebuilt by the verifier and never travels, so
        // counting it would inflate the envelope by bytes that are not in the message.
        assert_eq!(overhead.added_bytes(), 110);
        assert_eq!(overhead.added_percent(), Some(1100.0));
    }

    #[test]
    fn an_empty_payload_has_no_percentage() {
        let overhead = EnvelopeOverhead {
            op: "procedure.listNotes".to_owned(),
            payload_bytes: 0,
            aad_bytes: 0,
            body_bytes: 80,
        };
        assert_eq!(overhead.added_bytes(), 80);
        assert_eq!(overhead.added_percent(), None, "no division by zero");
    }

    #[test]
    fn a_run_totals_its_envelope_overhead() {
        let run = Run {
            variant: Variant::Cose,
            bearer: false,
            exchanges: Vec::new(),
            overhead: vec![
                EnvelopeOverhead {
                    op: "procedure.addNote".to_owned(),
                    payload_bytes: 36,
                    aad_bytes: 110,
                    body_bytes: 200,
                },
                EnvelopeOverhead {
                    op: "procedure.listNotes".to_owned(),
                    payload_bytes: 10,
                    aad_bytes: 110,
                    body_bytes: 120,
                },
            ],
        };
        assert_eq!(run.payload_total(), 46);
        assert_eq!(run.added_total(), 164 + 110);
        assert_eq!(run.sealed().len(), 2);
    }
}
