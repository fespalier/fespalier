//! The device registry: the keys the server will verify a signed request with.
//!
//! Upstream ships a resolver over a fixed set of keys (`StaticVerifierResolver`), which cannot grow
//! while the server runs, and an Ed25519-only one for `cratestack-auth` device keys. A phone
//! registers a P-256 key at runtime, so this is the example's own `CoseVerifierResolver`.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use cratestack::CratestackError;
use cratestack::cose::{CoseAlg, CoseVerifierResolver, CoseVerifyKey};
use cratestack::envelope_layer::async_trait;

/// How many device keys the registry holds at most.
pub const MAX_DEVICES: usize = 10_000;

/// Registered public keys by `kid` (the first 8 bytes of the RFC 9679 thumbprint).
///
/// Eight bytes collide at about 2^32 keys, so a `kid` maps to a list, and the opener tries
/// each candidate.
#[derive(Clone, Default)]
pub struct DeviceKeys {
    keys: Arc<RwLock<HashMap<[u8; 8], Vec<CoseVerifyKey>>>>,
}

impl DeviceKeys {
    /// An empty registry: every signed request is refused until a device registers.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Remember `key`. Registering the same key twice keeps one copy.
    ///
    /// Registration is the one unauthenticated call, so the registry is bounded: past
    /// [`MAX_DEVICES`] keys a new one is refused (a restart empties it).
    ///
    /// # Errors
    /// When the registry is full and `key` is not already in it.
    pub fn register(&self, key: CoseVerifyKey) -> Result<(), CratestackError> {
        let mut keys = self
            .keys
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let known = keys.get(&key.kid()).is_some_and(|slot| slot.contains(&key));
        if known {
            return Ok(());
        }
        let count: usize = keys.values().map(Vec::len).sum();
        if count >= MAX_DEVICES {
            return Err(CratestackError::TooManyRequests(
                "the device registry is full".to_owned(),
            ));
        }
        keys.entry(key.kid()).or_default().push(key);
        Ok(())
    }

    /// How many distinct keys are registered.
    #[must_use]
    pub fn len(&self) -> usize {
        self.keys
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .map(Vec::len)
            .sum()
    }

    /// Whether no key is registered.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[async_trait]
impl CoseVerifierResolver for DeviceKeys {
    /// An unknown `kid` is `Ok(vec![])`: an `Err` would be a 500, and a distinguishable answer
    /// for "no such key" is the oracle the envelope is built to avoid.
    async fn resolve(
        &self,
        kid: &[u8],
        alg: CoseAlg,
    ) -> Result<Vec<CoseVerifyKey>, CratestackError> {
        let keys = self
            .keys
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(<[u8; 8]>::try_from(kid)
            .ok()
            .and_then(|kid| keys.get(&kid))
            .map(|found| {
                found
                    .iter()
                    .filter(|key| key.supports(alg))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default())
    }
}
