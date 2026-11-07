//! The schema's procedures.
//!
//! - **The device ceremonies** (`sendEnrolmentCode`, `beginEnrolment`, `confirmEnrolment`,
//!   `beginRenewal`, `confirmRenewal`) are public, and call Authkestra's handlers through
//!   [`crate::issuer::Issuer`]; what stays here is what the handlers leave to the application:
//!   the phone number and the subject derived from it, the device id, the record of the keys each
//!   device enrolled, and the code the demo "texts".
//! - **The orders** are per user, seeded with two.
//! - **A write under an `Idempotency-Key` runs once** ([`Procedures::once`]): the answer of
//!   `placeOrder` and `payOrder` is kept under the subject and the key, and a retry with the same
//!   arguments gets it back. It is done here, after authentication, and not with `CrateStack`'s
//!   `IdempotencyLayer`: that layer runs in front of the router, before any `AuthProvider`, so it
//!   could only take its namespace from something it reads unverified (an attestation is public,
//!   and changes at every renewal). A refusal (`@allow`, `@authn`, the provider's) never reaches a
//!   body, so it is never kept: the retry after a renewal or a step-up runs.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use authkestra_devsig::KeyRole;
use authkestra_op::OpError;
use authkestra_op::attestation::{compute_cnf_jkt, parse_public_jwk};
use cratestack::serde_json::{Value as Json, json};
use cratestack::{CratestackContext, CratestackError, Value};
use sha2::{Digest as _, Sha256};

use crate::auth::{DEVICE_CLAIM, IDEMPOTENCY_CLAIM};
use crate::cratestack_schema::procedures::{self as procs, ProcedureRegistry};
use crate::cratestack_schema::{
    Account, CodeSent, Cratestack, EnrolledDevice, EnrolmentChallenges, Jwk as WireJwk, Order,
    OrderList, RenewalChallenge, Renewed, Revoked,
};
use crate::issuer::{KeyStatus, OneCode, attributes, hex, random_bytes};
use crate::{DEMO_OTP, Device, Enrolment, Key, MAX_ORDERS, Recorded, Renewal, SentCode, Shared};

/// How long a code, an enrolment and a renewal wait for their next leg.
const CODE_WINDOW: Duration = Duration::from_mins(10);
const ENROLMENT_WINDOW: Duration = Duration::from_mins(5);

/// How many wrong codes one code takes.
const OTP_ATTEMPTS: u8 = 5;

/// How many unfinished codes, enrolments and renewals are held at most, each.
const PENDING_CAPACITY: usize = 1_000;

/// How long, and how many, answers are kept under an `Idempotency-Key`.
const IDEMPOTENCY_TTL: Duration = Duration::from_hours(24);
const IDEMPOTENCY_PER_USER: usize = 200;

#[derive(Clone)]
pub(crate) struct Procedures {
    pub(crate) shared: Arc<Shared>,
}

/// The caller of a signed request, as [`crate::auth::principal_of`] made it.
struct Caller {
    subject: String,
    device_id: String,
    role: KeyRole,
    idempotency_key: Option<String>,
}

fn caller(ctx: &CratestackContext) -> Result<Caller, CratestackError> {
    let unsigned = || CratestackError::Unauthorized("sign the request".to_owned());
    let device_id = match ctx.auth_field(DEVICE_CLAIM) {
        Some(Value::String(id)) => id.clone(),
        _ => return Err(unsigned()),
    };
    Ok(Caller {
        subject: ctx.subject().ok_or_else(unsigned)?.into_owned(),
        device_id,
        role: match ctx.key_role().ok_or_else(unsigned)? {
            cratestack::KeyRole::UserPresent => KeyRole::UserPresent,
            cratestack::KeyRole::Ambient => KeyRole::Ambient,
        },
        idempotency_key: match ctx.auth_field(IDEMPOTENCY_CLAIM) {
            Some(Value::String(key)) => Some(key.clone()),
            _ => None,
        },
    })
}

/// A role as the client names it (`KeyRole.name` in Dart).
fn role_named(name: &str) -> Option<KeyRole> {
    match name {
        "ambient" => Some(KeyRole::Ambient),
        "userPresent" | "user_present" => Some(KeyRole::UserPresent),
        _ => None,
    }
}

fn role_name(role: KeyRole) -> &'static str {
    match role {
        KeyRole::UserPresent => "userPresent",
        _ => "ambient",
    }
}

fn wire_jwk(name: &str, jwk: &WireJwk) -> Result<Json, CratestackError> {
    let raw = json!({ "kty": jwk.kty, "crv": jwk.crv, "x": jwk.x, "y": jwk.y });
    parse_public_jwk(&raw)
        .map(|_| raw)
        .map_err(|_| CratestackError::Validation(format!("field '{name}' is not a public key")))
}

fn thumbprint(jwk: &Json) -> Result<String, CratestackError> {
    parse_public_jwk(jwk)
        .and_then(|parsed| compute_cnf_jkt(&parsed))
        .map_err(|error| CratestackError::Internal(format!("a stored key: {error}")))
}

/// A phone number as the server keeps it: `+`, then 8 to 15 digits, spaces dropped.
fn normalise_phone(phone: &str) -> Result<String, CratestackError> {
    let phone: String = phone.chars().filter(|c| !c.is_whitespace()).collect();
    let digits = phone.strip_prefix('+').unwrap_or_default();
    if (8..=15).contains(&digits.len()) && digits.chars().all(|c| c.is_ascii_digit()) {
        Ok(phone)
    } else {
        Err(CratestackError::Validation(
            "field 'phone' must look like +237 6 55 00 00 00".to_owned(),
        ))
    }
}

/// The account a phone number is: the subject is derived here, never said by the client.
fn subject_of(phone: &str) -> String {
    let digits: String = phone.chars().filter(char::is_ascii_digit).collect();
    format!("user-{digits}")
}

/// Authkestra's refusal of a ceremony, as the answer the app reads.
fn ceremony_error(error: &OpError) -> CratestackError {
    match error {
        OpError::SecondFactorFailed => {
            CratestackError::Validation("field 'otp' is not the code that was sent".to_owned())
        }
        OpError::BadJwk(_) | OpError::BadAlg(_) => {
            CratestackError::Validation("field 'ambient' is not a public key".to_owned())
        }
        OpError::InvalidChallenge => CratestackError::NotFound("challenge".to_owned()),
        OpError::ChallengeSignatureInvalid => CratestackError::Forbidden(
            "a challenge was not signed by the key it was sent for".to_owned(),
        ),
        // The device is revoked, or its last attestation can no longer be re-issued (past its
        // lifetime and the token manager's leeway, or not bound to the key): either way the
        // session is over, and the app enrols again.
        OpError::PrincipalRevoked | OpError::AttestationInvalid | OpError::KeyNotBound => {
            CratestackError::Forbidden("device_revoked".to_owned())
        }
        other => CratestackError::Internal(format!("the issuer: {other}")),
    }
}

fn seeded<'a>(orders: &'a mut HashMap<String, Vec<Order>>, subject: &str) -> &'a mut Vec<Order> {
    orders.entry(subject.to_owned()).or_insert_with(|| {
        [
            (1, "Espresso beans", 2, "placed"),
            (2, "Oat milk", 6, "paid"),
        ]
        .into_iter()
        .map(|(id, item, quantity, status)| Order {
            id,
            item: item.to_owned(),
            quantity,
            status: status.to_owned(),
        })
        .collect()
    })
}

fn fingerprint(op: &str, args: &Json) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(op.as_bytes());
    hash.update([0]);
    hash.update(args.to_string().as_bytes());
    hash.finalize().into()
}

impl Procedures {
    /// Runs `write` once per subject and `Idempotency-Key`: a retry with the same arguments gets
    /// the kept answer, the same key with other arguments is `idempotency_key_conflict`. Under one
    /// lock, so two sends of one write never both run. Only a success is kept.
    fn once(
        &self,
        caller: &Caller,
        op: &'static str,
        args: &Json,
        write: impl FnOnce(&mut crate::Store) -> Result<Order, CratestackError>,
    ) -> Result<Order, CratestackError> {
        let mut state = self.shared.state();
        let Some(key) = caller.idempotency_key.clone() else {
            return write(&mut state);
        };
        let now = Instant::now();
        state.recorded.retain(|_, kept| kept.expires > now);
        let print = fingerprint(op, args);
        let slot = (caller.subject.clone(), key);
        if let Some(kept) = state.recorded.get(&slot) {
            return if kept.op == op && kept.fingerprint == print {
                Ok(kept.answer.clone())
            } else {
                Err(CratestackError::Validation(
                    "idempotency_key_conflict: this key was used for another request".to_owned(),
                ))
            };
        }
        let answer = write(&mut state)?;
        let held = state
            .recorded
            .keys()
            .filter(|(subject, _)| *subject == caller.subject)
            .count();
        if held < IDEMPOTENCY_PER_USER {
            state.recorded.insert(
                slot,
                Recorded {
                    op,
                    fingerprint: print,
                    answer: answer.clone(),
                    expires: now + IDEMPOTENCY_TTL,
                },
            );
        }
        Ok(answer)
    }
}

#[allow(
    clippy::unused_async_trait_impl,
    reason = "the trait methods are async; this example keeps its state in memory"
)]
impl ProcedureRegistry for Procedures {
    async fn send_enrolment_code(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::send_enrolment_code::Args,
        _authorized: procs::send_enrolment_code::Authorized,
    ) -> Result<procs::send_enrolment_code::Output, CratestackError> {
        let phone = normalise_phone(&args.args.phone)?;
        let mut state = self.shared.state();
        let now = Instant::now();
        state
            .codes
            .retain(|_, code| now.duration_since(code.sent) < CODE_WINDOW);
        if state.codes.len() >= PENDING_CAPACITY {
            return Err(CratestackError::Unavailable(
                "too many codes are waiting".to_owned(),
            ));
        }
        // A real server texts a fresh code here; the demo's is always DEMO_OTP.
        state.codes.insert(
            subject_of(&phone),
            SentCode {
                code: DEMO_OTP.to_owned(),
                sent: now,
                attempts: 0,
            },
        );
        Ok(CodeSent { phone })
    }

    async fn begin_enrolment(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::begin_enrolment::Args,
        _authorized: procs::begin_enrolment::Authorized,
    ) -> Result<procs::begin_enrolment::Output, CratestackError> {
        let args = args.args;
        let phone = normalise_phone(&args.phone)?;
        let subject = subject_of(&phone);
        let mut keys = vec![(KeyRole::Ambient, wire_jwk("ambient", &args.ambient)?)];
        if let Some(key) = &args.userPresent {
            keys.push((KeyRole::UserPresent, wire_jwk("userPresent", key)?));
        }
        let device_id = format!("device-{}", hex(&random_bytes::<9>()?));
        let code = OneCode {
            sent: {
                let now = Instant::now();
                self.shared
                    .state()
                    .codes
                    .get(&subject)
                    .filter(|code| now.duration_since(code.sent) < CODE_WINDOW)
                    .map(|code| code.code.clone())
            },
        };
        // One Authkestra enrolment per key, each checking the code first.
        let mut challenges = HashMap::new();
        for (role, jwk) in keys {
            let issued = self
                .shared
                .issuer
                .enrol(&subject, &device_id, role, jwk.clone(), &code, &args.otp)
                .await;
            match issued {
                Ok(answer) => {
                    challenges.insert(role, (jwk, answer.challenge));
                }
                Err(error) => {
                    if matches!(error, OpError::SecondFactorFailed) {
                        let mut state = self.shared.state();
                        if let Some(sent) = state.codes.get_mut(&subject) {
                            sent.attempts += 1;
                            if sent.attempts >= OTP_ATTEMPTS {
                                state.codes.remove(&subject);
                            }
                        }
                    }
                    return Err(ceremony_error(&error));
                }
            }
        }
        let mut state = self.shared.state();
        // The code is single use: it was good for these keys, and is gone.
        state.codes.remove(&subject);
        let now = Instant::now();
        state
            .enrolments
            .retain(|_, e| now.duration_since(e.created) < ENROLMENT_WINDOW);
        if state.enrolments.len() >= PENDING_CAPACITY {
            return Err(CratestackError::Unavailable(
                "too many enrolments are waiting".to_owned(),
            ));
        }
        let answer = EnrolmentChallenges {
            enrolmentId: device_id.clone(),
            ambient: challenges
                .get(&KeyRole::Ambient)
                .map(|(_, challenge)| challenge.clone())
                .unwrap_or_default(),
            userPresent: challenges
                .get(&KeyRole::UserPresent)
                .map(|(_, challenge)| challenge.clone()),
        };
        state.enrolments.insert(
            device_id,
            Enrolment {
                created: now,
                subject,
                phone,
                keys: challenges,
            },
        );
        Ok(answer)
    }

    async fn confirm_enrolment(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::confirm_enrolment::Args,
        _authorized: procs::confirm_enrolment::Authorized,
    ) -> Result<procs::confirm_enrolment::Output, CratestackError> {
        let args = args.args;
        // Single use, whatever the outcome.
        let enrolment = self
            .shared
            .state()
            .enrolments
            .remove(&args.enrolmentId)
            .filter(|e| e.created.elapsed() < ENROLMENT_WINDOW)
            .ok_or_else(|| CratestackError::NotFound("enrolment".to_owned()))?;
        let mut keys = HashMap::new();
        for (role, (jwk, challenge)) in enrolment.keys {
            let signature = match role {
                KeyRole::UserPresent => args.userPresent.as_deref(),
                _ => Some(args.ambient.as_str()),
            }
            .ok_or_else(|| {
                CratestackError::Forbidden("every key must sign its challenge".to_owned())
            })?;
            let issued = self
                .shared
                .issuer
                .complete(&challenge, signature)
                .await
                .map_err(|error| ceremony_error(&error))?;
            keys.insert(
                role,
                Key {
                    jkt: thumbprint(&jwk)?,
                    jwk,
                    attestation: issued.attestation,
                },
            );
        }
        let attestation = |role| keys.get(&role).map(|key: &Key| key.attestation.clone());
        let answer = EnrolledDevice {
            deviceId: args.enrolmentId.clone(),
            userId: enrolment.subject.clone(),
            phone: enrolment.phone.clone(),
            ambient: attestation(KeyRole::Ambient).unwrap_or_default(),
            userPresent: attestation(KeyRole::UserPresent),
        };
        self.shared.state().devices.insert(
            args.enrolmentId,
            Device {
                phone: enrolment.phone,
                keys,
                revoked: false,
            },
        );
        Ok(answer)
    }

    async fn begin_renewal(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::begin_renewal::Args,
        _authorized: procs::begin_renewal::Authorized,
    ) -> Result<procs::begin_renewal::Output, CratestackError> {
        let args = args.args;
        let role = role_named(&args.role).ok_or_else(|| {
            CratestackError::Validation("field 'role' is not a key role".to_owned())
        })?;
        // `DeviceAuthServer.beginRenewal` names a device and a role: the attestation Authkestra
        // re-issues is the one this server last issued for that key, read with the key's JWK and
        // the device's status under one lock. A device this server does not know is dead.
        let (attestation, jwk, status) = {
            let state = self.shared.state();
            let device = state
                .devices
                .get(&args.deviceId)
                .ok_or_else(|| CratestackError::Forbidden("device_revoked".to_owned()))?;
            let key = device.keys.get(&role).ok_or_else(|| {
                CratestackError::Validation("field 'role' is not a key of this device".to_owned())
            })?;
            let status = KeyStatus {
                attributes: (!device.revoked).then(|| attributes(role)),
            };
            (key.attestation.clone(), key.jwk.clone(), status)
        };
        let challenge = self
            .shared
            .issuer
            .reissue(&attestation, jwk, &status)
            .await
            .map_err(|error| ceremony_error(&error))?;
        let mut state = self.shared.state();
        state
            .renewals
            .retain(|_, r| r.created.elapsed() < ENROLMENT_WINDOW);
        if state.renewals.len() >= PENDING_CAPACITY {
            return Err(CratestackError::Unavailable(
                "too many renewals are waiting".to_owned(),
            ));
        }
        state.renewals.insert(
            challenge.challenge.clone(),
            Renewal {
                created: Instant::now(),
                device_id: args.deviceId,
                role,
            },
        );
        Ok(RenewalChallenge {
            challengeId: challenge.challenge.clone(),
            challenge: challenge.challenge,
        })
    }

    async fn confirm_renewal(
        &self,
        _db: &Cratestack,
        _ctx: &CratestackContext,
        args: procs::confirm_renewal::Args,
        _authorized: procs::confirm_renewal::Authorized,
    ) -> Result<procs::confirm_renewal::Output, CratestackError> {
        let args = args.args;
        let renewal = self
            .shared
            .state()
            .renewals
            .remove(&args.challengeId)
            .ok_or_else(|| CratestackError::NotFound("renewal".to_owned()))?;
        let issued = self
            .shared
            .issuer
            .complete(&args.challengeId, &args.signature)
            .await
            .map_err(|error| ceremony_error(&error))?;
        let mut state = self.shared.state();
        // Revoked while the challenge was out: the new attestation is never handed over.
        let key = state
            .devices
            .get_mut(&renewal.device_id)
            .filter(|device| !device.revoked)
            .and_then(|device| device.keys.get_mut(&renewal.role))
            .ok_or_else(|| CratestackError::Forbidden("device_revoked".to_owned()))?;
        key.attestation.clone_from(&issued.attestation);
        Ok(Renewed {
            attestation: issued.attestation,
        })
    }

    async fn revoke_device(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::revoke_device::Args,
        _authorized: procs::revoke_device::Authorized,
    ) -> Result<procs::revoke_device::Output, CratestackError> {
        let caller = caller(ctx)?;
        let device_id = args.args.deviceId;
        if device_id != caller.device_id {
            return Err(CratestackError::Forbidden(
                "a device revokes itself and no other".to_owned(),
            ));
        }
        let mut state = self.shared.state();
        let device = state
            .devices
            .get_mut(&device_id)
            .ok_or_else(|| CratestackError::NotFound("device".to_owned()))?;
        // A device that holds a user-present key signs out with it: it prompts. Not an `@authn`:
        // the rule depends on what this device enrolled (the web has no user-present key and must
        // still be able to sign out), which a schema attribute cannot see. `DeviceAuthServer.revoke`
        // signs this call with the user-present key itself, so it is never a step-up.
        if device.keys.contains_key(&KeyRole::UserPresent) && caller.role != KeyRole::UserPresent {
            return Err(CratestackError::Forbidden(
                "user_presence_required".to_owned(),
            ));
        }
        device.revoked = true;
        Ok(Revoked {
            deviceId: device_id,
        })
    }

    async fn account(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        _args: procs::account::Args,
        _authorized: procs::account::Authorized,
    ) -> Result<procs::account::Output, CratestackError> {
        let caller = caller(ctx)?;
        let state = self.shared.state();
        let device = state
            .devices
            .get(&caller.device_id)
            .ok_or_else(|| CratestackError::NotFound("device".to_owned()))?;
        Ok(Account {
            userId: caller.subject,
            phone: device.phone.clone(),
            deviceId: caller.device_id,
            signedWith: role_name(caller.role).to_owned(),
        })
    }

    async fn list_orders(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::list_orders::Args,
        _authorized: procs::list_orders::Authorized,
    ) -> Result<procs::list_orders::Output, CratestackError> {
        let caller = caller(ctx)?;
        let limit = args
            .args
            .limit
            .map_or(usize::MAX, |limit| usize::try_from(limit).unwrap_or(0));
        let mut state = self.shared.state();
        let mine = seeded(&mut state.orders, &caller.subject);
        Ok(OrderList {
            orders: mine.iter().take(limit).cloned().collect(),
        })
    }

    async fn get_order(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::get_order::Args,
        _authorized: procs::get_order::Authorized,
    ) -> Result<procs::get_order::Output, CratestackError> {
        let caller = caller(ctx)?;
        let id = args.args.id;
        let mut state = self.shared.state();
        seeded(&mut state.orders, &caller.subject)
            .iter()
            .find(|order| order.id == id)
            .cloned()
            .ok_or_else(|| CratestackError::NotFound(format!("order {id}")))
    }

    async fn place_order(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::place_order::Args,
        _authorized: procs::place_order::Authorized,
    ) -> Result<procs::place_order::Output, CratestackError> {
        let caller = caller(ctx)?;
        let args = args.args;
        let wire = json!({ "item": args.item, "quantity": args.quantity });
        let item = args.item.trim().to_owned();
        if item.is_empty() || item.chars().count() > 40 {
            return Err(CratestackError::Validation(
                "field 'item' must be 1 to 40 characters".to_owned(),
            ));
        }
        if !(1..=99).contains(&args.quantity) {
            return Err(CratestackError::Validation(
                "field 'quantity' must be between 1 and 99".to_owned(),
            ));
        }
        self.once(&caller, "placeOrder", &wire, |state| {
            let mine = seeded(&mut state.orders, &caller.subject);
            if mine.len() >= MAX_ORDERS {
                return Err(CratestackError::Validation(
                    "field 'item' cannot be added: this account has as many orders as the demo keeps"
                        .to_owned(),
                ));
            }
            let order = Order {
                id: mine.last().map_or(1, |last| last.id + 1),
                item,
                quantity: args.quantity,
                status: "placed".to_owned(),
            };
            mine.push(order.clone());
            Ok(order)
        })
    }

    async fn pay_order(
        &self,
        _db: &Cratestack,
        ctx: &CratestackContext,
        args: procs::pay_order::Args,
        _authorized: procs::pay_order::Authorized,
    ) -> Result<procs::pay_order::Output, CratestackError> {
        // Paying needs the user-present key: `@authn(amr: ["user"])` in schema.cstack, which the
        // generated code checks before this runs, and refuses with the step-up 401.
        let caller = caller(ctx)?;
        let id = args.args.id;
        self.once(&caller, "payOrder", &json!({ "id": id }), |state| {
            let order = seeded(&mut state.orders, &caller.subject)
                .iter_mut()
                .find(|order| order.id == id)
                .ok_or_else(|| CratestackError::NotFound(format!("order {id}")))?;
            if order.status == "paid" {
                return Err(CratestackError::Conflict(format!(
                    "order {id} is already paid"
                )));
            }
            "paid".clone_into(&mut order.status);
            Ok(order.clone())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phone_number_is_normalised_or_refused() {
        assert_eq!(
            normalise_phone("+237 6 55 00 00 00").ok().as_deref(),
            Some("+237655000000")
        );
        assert!(normalise_phone("hello").is_err());
        assert_eq!(subject_of("+237655000000"), "user-237655000000");
    }

    #[test]
    fn a_fingerprint_follows_the_op_and_the_arguments() {
        let args = json!({ "id": 1 });
        assert_eq!(
            fingerprint("payOrder", &args),
            fingerprint("payOrder", &args)
        );
        assert_ne!(
            fingerprint("payOrder", &args),
            fingerprint("getOrder", &args)
        );
        assert_ne!(
            fingerprint("payOrder", &args),
            fingerprint("payOrder", &json!({ "id": 2 }))
        );
    }
}
