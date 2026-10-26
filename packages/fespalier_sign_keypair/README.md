# fespalier_sign_keypair

**Token-free device-signed sessions** for [`fespalier_auth`](../fespalier_auth) (since 0.21.0), the scheme Webank runs in
production ([fespalier#267](https://github.com/fespalier/fespalier/issues/267)). There is no OIDC provider, no access
token, no refresh token, no DPoP and no `Authorization` header. "Signed in" means this device's key is enrolled and holds
a valid attestation; every request then carries its own signature over its method, path, query and exact body bytes.

You get the same `authSession` states, guards (`requireSignedIn`, `redirectIfSignedIn`), restore, `keyLost` and sign-out as
an OIDC app, from the same `fespalier_auth` core. It depends on `fespalier_auth` and [`fespalier_keypair`](../fespalier_keypair)
(the keys), and on no HTTP client (`test/no_http_test.dart` greps `lib/` and the pubspec); it talks to your server through
the `DeviceAuthServer` you write.

Until 0.21.0 this package held DPoP. DPoP is now [`fespalier_keypair_dpop`](../fespalier_keypair_dpop), a hard cutover with
no re-export.

## Install

Next to fespalier, `fespalier_auth` and `fespalier_keypair`, with the same `url` and `ref` for all of them:

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier_sign_keypair:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_sign_keypair
      ref: v0.24.0
```

<!-- x-release-please-end -->

Needs Dart 3.12 and Flutter 3.44 or newer (flutter-sign-keypair needs them). It is not published to pub.dev.

## The scheme

A device holds two keys (P-256, ES256, raw `r||s`): an **ambient** key that never prompts and signs every ordinary
request, and, where the platform has a secure element, a **user-present** key (a biometric or the device credential) for
the calls worth a prompt. The web has the ambient key only (a non-extractable `CryptoKey` in IndexedDB).

```mermaid
sequenceDiagram
  participant App
  participant Backend as DeviceAuthBackend
  participant Keys as Device keys
  participant Server as your DeviceAuthServer
  App->>Backend: beginEnrolment(fields: phone)
  Backend->>Keys: publicJwk() of each role (makes the keys)
  Backend->>Server: beginEnrolment(public JWKs + fields)  [unsigned]
  Server-->>App: one challenge per key, and an OTP is sent
  App->>Backend: signIn(CompleteEnrolment(challenge, proof: otp))
  Backend->>Keys: sign {"challenge": ...} (the user-present key prompts)
  Backend->>Server: confirmEnrolment(signatures, otp)  [unsigned]
  Server-->>Backend: deviceId, user, an attestation per key
  Backend-->>App: SignedIn (credential: deviceId + attestations)
```

An **attestation** is a JWS signed by your issuer with the claims `iss`, `sub`, `did`, `iat`, `exp`, `cnf.jkt` (the RFC 7638
thumbprint of the key) and a status. It lasts about a day, and on its own it is useless: it counts only next to a fresh
signature from the bound key.

**Every signed request** carries `X-Attestation` (the stored attestation, unchanged) and `X-Signature` (a compact JWS,
header `{"alg":"ES256","jwk":{crv,kty,x,y}}`) with these claims, and no `Authorization`:

| Claim        | Meaning                                                                         |
| ------------ | ------------------------------------------------------------------------------- |
| `iat`, `exp` | `exp` is `iat` plus the profile's lifetime, at most 300 s                       |
| `jti`        | 128 random bits, fresh on every send: retries and replays included              |
| `mth`        | the HTTP method, upper-case                                                     |
| `pth`        | `uri.path` (`/` for an empty path)                                              |
| `qsh`        | lower-case hex SHA-256 of the raw query; left out when there is none            |
| `bdh`        | lower-case hex SHA-256 of the exact body bytes on the wire; left out when empty |
| `aud`        | the API's audience (`DeviceSignatureProfile.audience`)                          |

`bdh` covers JSON, CBOR and multipart alike, because `fespalier_auth`'s `SessionTransport` hands the signer the final bytes
(`TransportRequest.body`): package:http multipart is finalized once, and Dio's `FormData` arrives finalized from
`TransportAdapter`. **A streamed body cannot be signed** (its bytes are not known before they are sent), so a request with
one is refused with an `ArgumentError`. Note that `package:http`'s `RetryClient` sends a copy of every request as a stream,
so it can retry bodiless requests only; for writes retry in Dio (`dio_smart_retry`) or in your own transport.

### Renewal, in place of refresh

```mermaid
stateDiagram-v2
  [*] --> Restoring
  Restoring --> SignedOut: no stored session
  Restoring --> SignedOut_keyLost: ambient key gone, or not the one the attestation is bound to
  Restoring --> SignedIn: key matches cnf.jkt
  SignedOut --> SignedIn: enrolment (two unsigned legs)
  SignedIn --> Renewing: ambient attestation within 12 h of expiry, or 401 attestation_expired / device_not_active
  Renewing --> SignedIn: new attestation (single flight, one re-signed retry)
  Renewing --> SignedOut_revoked: the server says the device is dead (403)
  SignedIn --> SignedOut_keyLost: 401 key_not_bound / bad_jwk / missing_credential
  SignedIn --> SignedOut_revoked: 403 DEVICE_REVOKED
  SignedIn --> SignedOut_user: sign-out (best-effort revoke, then both keys deleted)
```

Renewal is a silent proof of possession: `beginRenewal(deviceId, role)` returns a challenge, the key signs it,
`confirmRenewal` returns a fresh attestation. It is lazy (the first request that finds the ambient attestation within
`renewAhead`, 12 h by default, of its expiry, or the first that is refused) and single-flight (concurrent 401s share one
renewal), and a request is re-sent at most once, signed again. The user-present attestation renews only when a server
refuses it, with a prompt.

The default classifier ([`webankRefusals`](lib/src/signer.dart)) sorts a refusal by status and the `error` of its JSON body:

- **Renewable**: 401 `attestation_expired`, `device_not_active`: renew the attestation of the key that signed, send once more.
- **Confirmed dead**: 401 `key_not_bound`, `bad_jwk`, `missing_credential`: `SignedOut(keyLost)`, both keys deleted;
  403 `DEVICE_REVOKED`: `SignedOut(revoked)`, both keys deleted.
- **Anything else is ambiguous**: it never wipes and never loops. Pass `classify:` to `DeviceAuthBackend` to read your own codes.

## Wire it

```dart
// lib/auth_setup.dart
final backend = DeviceAuthBackend(
  server: ShopDeviceServer(transport), // your endpoints
  keys: DeviceKeys.device(), // ambient + user-present where the device has it
  profile: const DeviceSignatureProfile(audience: 'https://api.example.com'),
);

AuthConfig authSetup() => AuthConfig(
  backend: backend,
  transport: transport, // the transport the enrolment and renewal legs go through: no session on it
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

Send API calls through `ref.watch(authTransport)` (or a `TransportClient` / `TransportAdapter` over it); the session signs
each one. A phone screen starts the ceremony, a code screen finishes it:

```dart
final challenge = await backend.beginEnrolment(fields: {'phone': phone}); // FieldErrors for a wrong number
// ... the one-time code screen ...
await ref.read(authSession.notifier).signIn(CompleteEnrolment(challenge, proof: code)); // FieldErrors for a wrong code
```

A request the user is looking at can ask for the user-present key; background and queued work never should (a prompt on
a request nobody is waiting for is a bug, and a queue stores the payload and the `Idempotency-Key`, never a signature):

```dart
await dio.post('/transfers', data: body, options: Options(extra: {
  DeviceSigner.roleAttribute: KeyRole.userPresent,
  DeviceSigner.reasonAttribute: 'Confirm the transfer',
}));
```

A refused prompt is a `UserPresenceRefused` that fails that one request: the session, the ambient key and every ordinary
request go on working. For a rule of your own pass `policy:` (`KeyRole Function(TransportRequest)`). A device without a
user-present key (the web) fails such a request with a `StateError` that says so.

The enrolment and renewal calls are unsigned **by name, not by origin**: send them through the transport you gave
`AuthConfig.transport` (no session on it), or list their paths in `unsignedPaths:` when they go through `authTransport`.

### `DeviceAuthServer`, the seam you write

```dart
final class ShopDeviceServer implements DeviceAuthServer {
  ShopDeviceServer(this.transport);
  final HttpTransport transport; // AuthConfig.transport

  @override
  Future<EnrolmentChallenge> beginEnrolment(EnrolmentStart start) async {
    // POST /devices/enrol/begin {phone: start.fields['phone'], keys: {ambient: {...jwk}, userPresent: {...jwk}}}
    // -> {enrolmentId, challenges: {ambient: "...", userPresent: "..."}}; a 422 becomes FieldErrors.
    final json = await _post('/devices/enrol/begin', {...});
    return EnrolmentChallenge(
      challenges: {for (final e in json['challenges'].entries) KeyRole.values.byName(e.key): e.value as String},
      data: {'enrolmentId': json['enrolmentId']},
    );
  }

  @override
  Future<DeviceEnrolment> confirmEnrolment(EnrolmentChallenge challenge, Map<KeyRole, String> signatures, Object? proof) async {
    // POST /devices/enrol/confirm {enrolmentId, otp: proof, signatures: {ambient: "<jws>", ...}}
    // -> {deviceId, user: {id, ...}, attestations: {ambient: "<jws>", ...}}
    // The server derives the subject from the OTP-verified phone; the client never says who it is.
  }

  @override
  Future<RoleChallenge> beginRenewal(String deviceId, KeyRole role) async {/* POST /devices/renew/begin; 403 -> throw const AuthRejected('device_revoked') */}

  @override
  Future<Attestation> confirmRenewal(RoleChallenge challenge, String signature) async {/* POST /devices/renew/confirm -> Attestation.parse(jws) */}

  @override
  Future<void> revoke(DeviceCredential credential, DeviceSigner signer) async {
    final request = TransportRequest(method: 'DELETE', uri: Uri.parse('https://api.example.com/devices/${credential.deviceId}'));
    final headers = await signer.signFor(credential, request); // user-present when the device has it
    await transport.send(request.copyWith(headers: headers));
  }
}
```

A refusal that means "this device is dead" (a 403) is thrown as `AuthRejected`; the backend turns it into
`SignedOut(revoked)`. Anything that means "could not ask" (offline, a 5xx) is thrown as it is, and the session stays.
Whatever your answers carry that the next leg needs (an enrolment id, a challenge id) goes in the `data` map.

### Sign-out and restore

`signOut()` calls `revoke` first, best effort (signed with the user-present key when the device has one, so it prompts),
then deletes **both** keys and the stored session, whatever the revoke did: a failed revoke, or a refused prompt, still
ends in a signed-out device with no keys. A restore signs the user out as `keyLost` when the ambient key is gone or is not
the one the stored attestation is bound to (it never makes a key to check); a lost user-present key is not a lost session.

The store keeps `{"v": 2, "backend": "device", "credential": {"deviceId", "attestations": {role: jws}}, "user": ...}`:
the attestations only, no private material.

## Verifying on a server

`package:fespalier_sign_keypair/verify.dart` is pure Dart, for a demo server and for tests:

```dart
final verified = verifyDeviceSignature(
  method: request.method, uri: request.uri, headers: request.headers, body: bodyBytes,
  profile: profile, issuerKeys: [issuerJwk], seenJtis: seenJtis,
);
```

In order: the attestation's issuer signature and expiry; `cnf.jkt` equals the thumbprint of the signature's `jwk`; the
signature; freshness with 30 s of skew and a lifetime of at most 300 s; `mth`, `pth`, `aud`, `qsh` and `bdh` (a hash on one
side only is refused); a `jti` that was not used before (added to `seenJtis` only when everything passed). A failure is a
`DeviceSignatureInvalid` whose `code` (`attestation_expired`, `key_not_bound`, `bad_jwk`, `missing_credential`,
`signature_expired`, `replay`, `mismatch`, ...) is the one the client classifier reads. Replay storage, the issuer, denylists
and access tiers stay with your backend.

## Tests

`package:fespalier_sign_keypair/testing.dart` has `FakeDeviceAuthServer`: it checks the one-time code, verifies each
challenge signature against the registered key, issues attestations signed by a test issuer key (`issuerKeys`, for
`verifyDeviceSignature`), renews and revokes, and can be told to refuse (`renewalError`, `revokeError`, `revokeDevice`),
hold a renewal in flight (`renewalGate`) or issue short-lived or foreign attestations (`issue`). With
`FakeKeypairSigner` (`package:fespalier_keypair/testing.dart`), which counts prompts and can refuse one or lose its key,
the whole scheme runs in a unit test with a fake clock (`clock.now()`, no timer).

## What it costs

One ES256 signature per request (made by the secure element on a device), one SHA-256 over the body, 128 random bits. No
timer, no `Future.delayed`, no listener and no `DateTime.now()` (`test/no_timers_test.dart` greps `lib/`).

## UNCHECKED on a device

No CI job runs these; the tests use `FakeKeypairSigner`. Treat them as unverified until someone has tried them on hardware
(they belong in a `human-test` issue, like [#133](https://github.com/fespalier/fespalier/issues/133)):

- **The user-present prompt**: the Secure Enclave (iOS, macOS) and StrongBox / TEE (Android) biometric or device-credential
  prompt, its caption (`reason`), a cancelled prompt (`userAuthenticationCancelled`), a device with no screen lock
  (`userAuthenticationRequired`) and how each surfaces as `UserPresenceRefused`.
- **Biometric invalidation**: enrolling or removing a fingerprint or face destroys the user-present key
  (`keyInvalidated`) and leaves the ambient key; the session must stay signed in, and the next user-present call must say
  so. Re-enrolling just the user-present key is not built.
- **The web key** across a reload, a restart and "clear site data", and `WebCryptoKeypairSigner` in Safari and Firefox
  (tried only in Chrome); IndexedDB refused in a private window; no user-present key on the web.
- **Hardware-backed keys** (`isHardwareBacked`) on real StrongBox / Secure Enclave devices, and the keystore refusing
  (the fallback to a software key is `DeviceKeys.device(fallback: KeypairFallback.software)`, ambient only).
- **A real backend** issuing attestations and enforcing the profile: only `verifyDeviceSignature` is tested here.
