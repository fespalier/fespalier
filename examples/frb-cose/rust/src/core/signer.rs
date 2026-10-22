//! The device key's signer: an ESP256 `ExternalSigner` whose signature comes from a callback. The key itself
//! is never in Rust: on a device it is the Secure Enclave's or the `AndroidKeyStore`'s, and Dart holds it.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use cratestack::CratestackError;
use cratestack::cose::ExternalSigner;

/// How long a signature may take before the call gives up. A user may background the app mid-call.
pub const SIGN_TIMEOUT: Duration = Duration::from_secs(10);

/// What the callback returns: the signature (DER or `r || s`), or `None` when the key did not sign.
pub type SignFuture = Pin<Box<dyn Future<Output = Option<Vec<u8>>> + Send + 'static>>;

/// The callback. `flutter_rust_bridge`'s `DartFnFuture<Option<Vec<u8>>>` is the same type, so the Dart side's
/// function is this one.
pub type SignFn = Arc<dyn Fn(Vec<u8>) -> SignFuture + Send + Sync + 'static>;

/// The ESP256 signer over the device's public point. When the callback answers `None`, or does not answer
/// within [`SIGN_TIMEOUT`], `failed` is set and the signing fails, so no request leaves.
///
/// # Errors
/// When the public point is not on the P-256 curve.
pub fn device_signer(
    public_sec1: &[u8],
    sign: SignFn,
    failed: Arc<AtomicBool>,
) -> Result<ExternalSigner, CratestackError> {
    ExternalSigner::esp256(public_sec1, move |to_be_signed| {
        let sign = Arc::clone(&sign);
        let failed = Arc::clone(&failed);
        async move {
            // A timeout is no signature: the call is refused, and the app may ask again later.
            let answer = tokio::time::timeout(SIGN_TIMEOUT, sign(to_be_signed))
                .await
                .unwrap_or_default();
            answer.ok_or_else(|| {
                failed.store(true, Ordering::SeqCst);
                CratestackError::Internal("the device key did not sign".to_owned())
            })
        }
    })
}
