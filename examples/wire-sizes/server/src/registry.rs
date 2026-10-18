//! A device registry, in memory.
//!
//! Deliberately small: this example is about bytes on the wire, so the store only has to behave,
//! not to survive a restart.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use cratestack::CratestackError;
use cratestack::cose::{CoseAlg, CoseVerifierResolver, CoseVerifyKey};

/// The devices this server knows, by thumbprint.
///
/// It is the envelope layer's [`CoseVerifierResolver`]: a `kid` is looked up among the registered
/// keys, which is how a signed request's device is found. An unknown `kid` resolves to nothing, as
/// the trait requires — never an error, because "no such device" is the caller's `401` to give,
/// not this resolver's.
#[derive(Clone, Default)]
pub struct DeviceKeys(Arc<Mutex<HashMap<[u8; 32], CoseVerifyKey>>>);

#[cfg_attr(not(target_arch = "wasm32"), async_trait::async_trait)]
#[cfg_attr(target_arch = "wasm32", async_trait::async_trait(?Send))]
impl CoseVerifierResolver for DeviceKeys {
    async fn resolve(
        &self,
        kid: &[u8],
        alg: CoseAlg,
    ) -> Result<Vec<CoseVerifyKey>, CratestackError> {
        Ok(self
            .0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .filter(|key| key.kid().as_slice() == kid && key.alg() == alg)
            .cloned()
            .collect())
    }
}

impl DeviceKeys {
    /// An empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Remembers a device key.
    ///
    /// # Errors
    /// Never for a P-256 key: its thumbprint is defined as 32 bytes.
    pub fn register(&self, key: CoseVerifyKey) -> Result<(), CratestackError> {
        let thumbprint: [u8; 32] = key.thumbprint();
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(thumbprint, key);
        Ok(())
    }

    /// How many devices are registered.
    #[must_use]
    pub fn len(&self) -> usize {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).len()
    }

    /// Whether no device is registered.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Whether this thumbprint is known.
    #[must_use]
    pub fn knows(&self, thumbprint: &[u8; 32]) -> bool {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains_key(thumbprint)
    }
}
