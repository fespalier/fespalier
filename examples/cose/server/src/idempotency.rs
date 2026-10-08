//! An in-memory `IdempotencyStore`: the answer to a write is kept under the caller's
//! `Idempotency-Key`, so a retry after a lost answer is replayed and not run again.
//!
//! The layer is installed *inside* the envelope layer, so it sees the plain CBOR request the
//! envelope unwrapped (the same bytes on every attempt, whatever the signature) and the verified
//! device as its principal. Its replayed answer is sealed by the envelope layer anew, for the
//! request that asked. A real server uses `SqlxIdempotencyStore` (or Redis); this one is lost at
//! a restart and bounded in size.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::SystemTime;

use cratestack::CratestackError;
use cratestack::envelope_layer::async_trait;
use cratestack::idempotency::{IdempotencyRecord, IdempotencyStore, ReservationOutcome};
use cratestack::uuid::Uuid;

/// How many live keys one device may hold, and how many the store holds in all.
const PER_PRINCIPAL: usize = 200;
const CAPACITY: usize = 50_000;

struct Entry {
    token: Uuid,
    hash: [u8; 32],
    expires_at: SystemTime,
    record: Option<IdempotencyRecord>,
}

/// The store.
#[derive(Default)]
pub struct MemoryIdempotency {
    entries: Mutex<HashMap<(String, String), Entry>>,
}

impl MemoryIdempotency {
    /// How many keys are held (live or not yet swept).
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len()
    }

    /// Whether no key is held.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// An empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl IdempotencyStore for MemoryIdempotency {
    async fn reserve_or_fetch(
        &self,
        principal: &str,
        key: &str,
        request_hash: [u8; 32],
        expires_at: SystemTime,
    ) -> Result<ReservationOutcome, CratestackError> {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let now = SystemTime::now();
        let id = (principal.to_owned(), key.to_owned());
        let reusable = entries.get(&id).is_none_or(|entry| entry.expires_at <= now);
        if reusable {
            let mine = |entries: &HashMap<(String, String), Entry>| {
                entries
                    .keys()
                    .filter(|(owner, _)| owner == principal)
                    .count()
            };
            if entries.len() >= CAPACITY || mine(&entries) >= PER_PRINCIPAL {
                entries.retain(|_, entry| entry.expires_at > now);
            }
            if entries.len() >= CAPACITY || mine(&entries) >= PER_PRINCIPAL {
                // Still full of live keys. This fails before the handler runs, so the write did
                // not happen, and a 503 is the answer a client keeps its key through (a 4xx would
                // drop its queued write): sealed, like any answer that passed the envelope.
                return Err(CratestackError::Unavailable(
                    "too many idempotency keys held".to_owned(),
                ));
            }
            // A new key, or an expired one reclaimed under a fresh token.
            let token = Uuid::new_v4();
            entries.insert(
                id,
                Entry {
                    token,
                    hash: request_hash,
                    expires_at,
                    record: None,
                },
            );
            return Ok(ReservationOutcome::Reserved { token });
        }
        let Some(entry) = entries.get(&id) else {
            return Ok(ReservationOutcome::InFlight);
        };
        Ok(if entry.hash == request_hash {
            entry
                .record
                .clone()
                .map_or(ReservationOutcome::InFlight, ReservationOutcome::Replay)
        } else {
            ReservationOutcome::Conflict
        })
    }

    async fn complete(
        &self,
        principal: &str,
        key: &str,
        token: Uuid,
        status: u16,
        headers: &[u8],
        body: &[u8],
    ) -> Result<(), CratestackError> {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(entry) = entries.get_mut(&(principal.to_owned(), key.to_owned()))
            && entry.token == token
        {
            let now = SystemTime::now();
            entry.record = Some(IdempotencyRecord {
                key: key.to_owned(),
                principal_fingerprint: principal.to_owned(),
                request_hash: entry.hash,
                response_status: status,
                response_headers: headers.to_vec(),
                response_body: body.to_vec(),
                created_at: now,
                expires_at: entry.expires_at,
            });
        }
        Ok(())
    }

    async fn release(
        &self,
        principal: &str,
        key: &str,
        token: Uuid,
    ) -> Result<(), CratestackError> {
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        let id = (principal.to_owned(), key.to_owned());
        if entries.get(&id).is_some_and(|entry| entry.token == token) {
            entries.remove(&id);
        }
        Ok(())
    }
}
