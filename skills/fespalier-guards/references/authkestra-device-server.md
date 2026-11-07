# A `DeviceAuthServer` for an Authkestra server (`authkestra-op`)

`fespalier_sign_keypair`'s `DeviceAuthBackend` talks to your server through a `DeviceAuthServer` you write
([`auth-device-sessions.md`](auth-device-sessions.md)). When the server issues its attestations with **Authkestra**
(`authkestra-op`'s framework-agnostic enrolment and re-issuance handlers) and verifies requests with `authkestra-devsig`
(device-signature profile v1), the wire already matches: the client's refusal table is the profile's, and the challenge
signatures `DeviceAuthBackend` makes (`{alg: ES256, typ: JWT}` over `{"challenge": ...}`) are what
`handle_complete_challenge` checks. Two things differ in **shape**, and the recipe absorbs them.
[`examples/cratestack`](../../../examples/cratestack/README.md) is this recipe, compiled and tested end to end against the
real server (`lib/src/device_server.dart`, `server/src/procedures.rs`).

| `DeviceAuthServer`                                                                                             | Authkestra (`authkestra-op`)                                                                                                                                              | The recipe                                                                                                                                                                                                                                                           |
| -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `beginEnrolment(keys, fields)`, then `confirmEnrolment(signatures, proof)`: the code comes with the signatures | `handle_enrol_start` checks the **second factor first**, for **one key**, then issues a challenge; `handle_complete_challenge` takes the challenge and its signature only | A call of the app's own sends the code (`sendCode(phone)`); `beginEnrolment` sends the keys **with the code** (`fields: {'phone', 'otp'}`), and the server calls `handle_enrol_start` once per key; `confirmEnrolment` sends the signatures, and `proof` is not read |
| `beginRenewal(deviceId, role)`: no attestation is passed                                                       | `handle_reissue_start` takes the key's **current attestation** and its JWK, and checks one against the other                                                              | The server keeps, per device key, the JWK it enrolled and the attestation it last issued, and hands those to Authkestra; its `AttestationStatusProvider` answers the key's `att` (or `None` for a revoked device)                                                    |

## The app side

```dart
// lib/src/device_server.dart (the parts that differ from any DeviceAuthServer)
final class OrdersDeviceServer implements DeviceAuthServer {
  // ...the generated client over AuthConfig.transport (no session), as in auth-device-sessions.md

  /// Before leg one: Authkestra checks the code before it issues a challenge.
  Future<void> sendCode(String phone) => _leg(
    () => _procedures.sendEnrolmentCode(
      SendEnrolmentCodeArgs(args: SendCodeArgs(phone: phone)),
    ),
  );

  @override
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start) async {
    final answer = await _leg(
      () => _procedures.beginEnrolment(
        BeginEnrolmentProcedureArgs(
          args: BeginEnrolmentArgs(
            phone: '${start.fields['phone'] ?? ''}',
            otp: '${start.fields['otp'] ?? ''}', // the second factor, with the keys
            ambient: _jwk(start.keys[KeyRole.ambient]!),
            userPresent: switch (start.keys[KeyRole.userPresent]) {
              final jwk? => _jwk(jwk),
              null => null,
            },
          ),
        ),
      ),
    );
    return EnrolmentChallenge(
      challenges: {
        KeyRole.ambient: answer.ambient,
        KeyRole.userPresent: ?answer.userPresent,
      },
      data: {'enrolmentId': answer.enrolmentId},
    );
  }

  @override
  Future<DeviceEnrolment> confirmEnrolment(
    EnrolmentChallenge challenge,
    Map<KeyRole, String> challengeSignatures,
    Object? proof, // not read: the code went with leg one
  ) async { /* the signatures only */ }

  // beginRenewal and confirmRenewal are unchanged: a 403 is AuthRejected (the device is dead).
}
```

The enrolment page asks for the number, calls `sendCode`, then, on the code screen, makes the keys and signs in:

```dart
final challenge = await ref
    .read(deviceBackend)
    .beginEnrolment(fields: {'phone': phone.text, 'otp': code.text});
await ref.read(authSession.notifier).signIn(CompleteEnrolment(challenge));
```

A wrong code is now refused by **leg one** (a `FieldErrors` on `otp` from `beginEnrolment`), before any key signs anything.

## The server side

- **Verifying**: `authkestra_devsig::verify` inside the framework's auth seam (in CrateStack, an `AuthProvider`; no layer in
  front of the router), then the application's own record of the device: unknown is `device_not_active`, revoked is
  `Refusal::device_revoked()`, a key it did not enrol for that role is `key_not_bound`. Send each refusal with the profile's
  status, `{"error": "<code>"}` (or that member in your envelope) and `WWW-Authenticate: DeviceSignature error="<code>"`,
  **on the 403 too** when the body may be CBOR: `DeviceRefusal.error` reads the challenge when the body is not JSON.
- **The key role**: `DeviceIdentity::key_role()` is `att.role`. Issue `att` as `{"status": "active", "role": "ambient" |
"user_present"}`; a user-present signature can map to `amr ["user", "pop"]` for a step-up rule.
- **Renewal past expiry**: `handle_reissue_start` validates the attestation with the token manager's leeway (60 s by
  default), so an attestation refused `attestation_expired` can still be re-issued within it; past it the server answers 403
  and the session ends as `revoked`, and the user enrols again.
- **Revocation and queued work**: a revoked device's next request is `403 device_revoked`, and `DeviceSigner` ends the
  session as `revoked`. Nothing in `fespalier_auth` wipes `fespalier_cratestack`'s queue then: listen for the session ending
  and call `crateStackAccount.clear(scope: <the account that ended>)` (`wipeWhenSessionEnds` in the example's
  `lib/src/session.dart`, installed by `ready()`). Each queued intent is signed when it is sent, so one that waited offline
  goes out with a fresh `jti` and the credential of that moment.

Until CrateStack can mark the enrolment procedures and `--preset fespalier` generates this class, it is hand-written, and
this page is the recipe.
