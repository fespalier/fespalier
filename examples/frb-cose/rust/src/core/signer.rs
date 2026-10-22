//! The device key's signer: an ESP256 `ExternalSigner` whose signature comes from a callback. The key itself is
//! never in Rust: on a device it is the Secure Enclave's or the `AndroidKeyStore`'s, and Dart holds it.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use cratestack::CratestackError;
use cratestack::cose::ExternalSigner;

/// How long a signature may take before the call gives up. A user may background the app mid-call.
pub const SIGN_TIMEOUT: Duration = Duration::from_secs(10);

/// The one message a refused signature carries. The client reports it as a seal failure (`EnvelopeError::Seal`), and
/// the engine maps that to its own text, so this one never reaches a page.
const SIGN_REFUSED: &str = "the device key did not sign";

/// What the callback answers: the signature (DER or `r || s`), or `None` when the key did not sign.
pub type SignFuture = Pin<Box<dyn Future<Output = Option<Vec<u8>>> + Send + 'static>>;

/// The callback. `flutter_rust_bridge`'s `DartFnFuture<Option<Vec<u8>>>` is the same type, so the Dart side's
/// function is this one.
pub type SignFn = Arc<dyn Fn(Vec<u8>) -> SignFuture + Send + Sync + 'static>;

/// The ESP256 signer over the device's public point, with [`SIGN_TIMEOUT`].
///
/// # Errors
/// When the public point is not on the P-256 curve.
pub fn device_signer(public_sec1: &[u8], sign: SignFn) -> Result<ExternalSigner, CratestackError> {
    device_signer_within(public_sec1, sign, SIGN_TIMEOUT)
}

/// The same signer with another timeout (the tests use a short one). When the callback answers `None`, or does not
/// answer within `timeout`, the signing fails and nothing is sent.
///
/// # Errors
/// When the public point is not on the P-256 curve.
pub fn device_signer_within(
    public_sec1: &[u8],
    sign: SignFn,
    timeout: Duration,
) -> Result<ExternalSigner, CratestackError> {
    ExternalSigner::esp256(public_sec1, move |to_be_signed| {
        let sign = Arc::clone(&sign);
        async move {
            // A timeout is no signature: the call is refused, and the app may ask again later.
            let answer = tokio::time::timeout(timeout, sign(to_be_signed))
                .await
                .ok()
                .flatten();
            answer.ok_or_else(|| CratestackError::Internal(SIGN_REFUSED.to_owned()))
        }
    })
}

#[cfg(test)]
#[path = "signer_tests.rs"]
mod tests;
