# cratestack

A [CrateStack](https://cratestack.dev) backend, a Flutter client **generated** from its schema by
`cratestack generate-dart --preset fespalier`, and **device-signed sessions**
([`fespalier_sign_keypair`](../../packages/fespalier_sign_keypair), the scheme Webank runs, fespalier#267): no password,
no token, no `Authorization` header. A small orders app that shows how the three fit together, with tests on both sides
and a cross-language end-to-end test (Dart signs, Rust verifies). The server is built on the public seams of three
projects, with no cryptography of its own (fespalier#310): **Authkestra** verifies and issues, **CrateStack** hosts it
through its pluggable-auth seam and declares the step-up rule in the schema, and **fespalier** consumes it through the
generated client and its session.

- [`server/`](server) is a standalone Rust crate, `cratestack-api` 0.17.2 (`@authn` since 0.17.1; 0.17.2 keeps no
  `Idempotency-Key` for a refusal) and Authkestra at one commit, no database. `schema.cstack` is the contract: five
  **public** procedures (`sendEnrolmentCode`, `beginEnrolment`, `confirmEnrolment`, `beginRenewal`, `confirmRenewal`), the
  signed ones (`listOrders`, `getOrder`, `placeOrder`, `payOrder`, `account`, `revokeDevice`), and `payOrder`'s **step-up
  rule**, `@authn(amr: ["user"])`. `authkestra-op`'s enrolment and re-issuance handlers issue the attestations
  (`src/issuer.rs`); `authkestra-devsig` verifies every signed request inside the server's CrateStack `AuthProvider`
  (`src/auth.rs`), with **no layer in front of the generated router**, and its refusals go out as CrateStack
  `AuthRefusal`s in Authkestra's device-signature profile v1.
- [`client/`](client) is what `scripts/cratestack-client.sh generate` writes: a Riverpod package that sends through
  fespalier's `HttpTransport` and links **no Dio**. It is committed, with the files `build_runner` writes from it, and CI
  generates it again and compares.
- The app (`lib/`, package `cratestack_example`) is an ordinary fespalier app: `lib/app/` has `startup.dart`, an enrolment
  page, a guarded group and the orders pages with their `data.dart` and `action.dart`.

Read it with the skills [`fespalier-cratestack`](../../skills/fespalier-cratestack/SKILL.md) (the wiring) and
[`fespalier-guards`](../../skills/fespalier-guards/SKILL.md) (device sessions). [CrateStack and fespalier](../../docs/cratestack.md),
[HTTP transport](../../docs/transport.md) and [Device-signed sessions](../../docs/auth.md#device-signed-sessions-fespalier_sign_keypair)
are the pages. [`examples/device`](../device/README.md) is the same session against a server written in Dart;
[`examples/cose`](../cose/README.md) signs the calls themselves instead of the session.

## What it shows

```mermaid
sequenceDiagram
  participant P as Pages
  participant B as DeviceAuthBackend
  participant G as Generated client (orders_client)
  participant S as Session (authTransport)
  participant R as server/: CrateStack router
  participant A as Authkestra (op, devsig)
  P->>G: sendEnrolmentCode(phone)  [OrdersDeviceServer, plain chain]
  G->>R: POST /rpc/procedure.sendEnrolmentCode
  R-->>P: the code is "sent" (the demo's is 123456)
  P->>B: beginEnrolment(phone, code)
  B->>G: beginEnrolment(keys, phone, code)  [plain chain, no session]
  G->>R: POST /rpc/procedure.beginEnrolment
  R->>A: handle_enrol_start, once per key: the code first, then a challenge
  R-->>B: a challenge per key
  P->>B: signIn(CompleteEnrolment(challenge))
  B->>G: confirmEnrolment(signatures)  [plain chain]
  G->>R: POST /rpc/procedure.confirmEnrolment
  R->>A: handle_complete_challenge, per key: the signature, then the attestation (cnf.jkt computed by Authkestra)
  R-->>B: deviceId, an attestation per key (iss, sub, did, exp, cnf.jkt, att {status, role})
  B-->>P: SignedIn
  P->>G: listOrders (in ref.cancellable)
  G->>S: the request, as the adapter encoded it
  S->>R: X-Attestation + X-Signature over method, path, query and the exact body (no Authorization)
  R->>A: AuthProvider: authkestra_devsig::verify, then the device's record (known, not revoked, the key it enrolled)
  R-->>P: 200
  Note over S,R: a 401 attestation_expired renews the attestation (beginRenewal: handle_reissue_start; confirmRenewal) and sends the call once more
  P->>G: payOrder (an ordinary call, with an Idempotency-Key)
  S->>R: signed by the ambient key
  R-->>S: 401 step-up: WWW-Authenticate Bearer error="insufficient_user_authentication" (@authn(amr: ["user"]))
  Note over S: once, and only for a call the user is looking at (never inside Authorizer.unattended)
  S->>R: the same request (same body, same key), signed by the user-present key, which prompts
  R-->>P: 200 (amr ["user", "pop"])
  Note over S,P: a cancelled prompt: the 401 is the answer, a CratestackRpcException whose stepUp is set; the session stays
```

A device revoked while the phone had writes queued offline (`fespalier_cratestack` intents; the end-to-end test plays it
with the operator's `POST /test/revoke`, which exists only with `--test-hooks`):

```mermaid
sequenceDiagram
  participant Q as IntentQueue
  participant S as Session (authTransport)
  participant R as server/
  Note over Q,S: offline: each write is saved once (its bytes and its Idempotency-Key), tried, and kept
  Q->>S: placeOrder (intent 1)
  S--xR: signed now (a fresh jti), but nothing leaves: TransportUnsent, kept under its key
  Note over R: the operator revokes the device
  Note over Q,R: back online: drain()
  Q->>S: intent 1, the same bytes and key
  S->>R: signed at send time: a new signature and jti, never the one made offline
  R-->>S: 403 device_revoked (WWW-Authenticate: DeviceSignature error="device_revoked")
  S-->>Q: the session ends as revoked; nothing else is sent
  Note over Q: wipeWhenSessionEnds: crateStackAccount.clear(scope: the account that ended), every queued intent gone
```

```mermaid
stateDiagram-v2
  [*] --> Restoring
  Restoring --> SignedOut: no stored session
  Restoring --> SignedOut_keyLost: ambient key gone, or not the one the attestation is bound to
  Restoring --> SignedIn: key matches cnf.jkt
  SignedOut --> Enrolling: sendEnrolmentCode, then beginEnrolment with the code (public)
  Enrolling --> SignedIn: confirmEnrolment (public)
  SignedIn --> Renewing: ambient attestation within 12 h of its end, or 401 attestation_expired / device_not_active / unknown_kid
  Renewing --> SignedIn: new attestation (one renewal, shared by the calls that wait)
  Renewing --> SignedOut_revoked: beginRenewal answers 403 (a device the server never saw, or revoked)
  SignedIn --> SignedOut_revoked: 403 device_revoked (the queued intents and saved reads are wiped)
  SignedIn --> SignedOut_keyLost: 401 key_not_bound / bad_jwk / missing_credential (wiped too)
  SignedIn --> SignedOut_user: sign-out (revokeDevice, then both keys deleted)
```

One request's step-up, inside `SignedIn` (the session does not change):

```mermaid
stateDiagram-v2
  [*] --> Ambient: the call, signed by the ambient key
  Ambient --> Done: 2xx, or any other refusal
  Ambient --> Stands: 401 step-up, and the call may not ask (unattended, stepUpAttribute false, no user-present key)
  Ambient --> UserPresent: 401 step-up: sign the same request with the user-present key (one prompt)
  UserPresent --> Stands: the prompt is cancelled (UserPresenceRefused): the 401 is the answer
  UserPresent --> Done: 2xx
  UserPresent --> Stands: 401 step-up again: never a second escalation
  Stands --> [*]
  Done --> [*]
```

| Where                                                             | What                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`lib/app/startup.dart`](lib/app/startup.dart)                    | The **one transport**: `PortalTransport(WriteGuardTransport(HttpClientTransport(http.Client())))`, the only place `package:http` is named. `restoreAuth` puts the session on top of it, and `ordersOverrides` hands the session to the generated client                                                                                                                                                                                                                                                                                                                                                                 |
| [`lib/src/wiring.dart`](lib/src/wiring.dart)                      | `authSetup`: `AuthConfig(backend: DeviceAuthBackend(...), transport: <the plain chain>, apiOrigins: [server])`. `ordersOverrides`: `ordersClientTransportProvider` is `ref.watch(authTransport)`, `ordersClientBaseUriProvider` the origin, and the error reader and the account for `fespalier_cratestack`; `stepUpReason` is the caption of the step-up prompt                                                                                                                                                                                                                                                        |
| [`lib/src/device_server.dart`](lib/src/device_server.dart)        | The `DeviceAuthServer`: the public legs go through the **generated client over the plain chain** (built from the same generated classes the provider builds, with `AuthConfig.transport` in the session's place); the revocation is signed by hand with `signer.signFor`. Authkestra checks the code before it issues a challenge, so the code is asked for first (`sendCode`) and sent with the keys in leg one (`fields: {'phone', 'otp'}`); leg two carries the signatures only |
| [`lib/src/intents.dart`](lib/src/intents.dart), [`lib/src/session.dart`](lib/src/session.dart) | `OrdersIntentTransport`, the `CrateStackTransport` the intent queue sends through (the generated adapter, on the session, so a queued write is signed when it is sent), and `wipeWhenSessionEnds`, which `ready()` installs: a session that ends without the user asking wipes the account's queue and saved reads |
| `lib/app/(signed-in)/orders/data.dart`                            | The list: the generated call inside `ref.cancellable` (leaving the page aborts the load), served by `ref.serve` (offline, the copy this phone saved) |
| `lib/app/(signed-in)/orders/action.dart`                          | `placeOrder` with an `Idempotency-Key`; a validation answer is `FieldErrors` under its field; the list is invalidated |
| `lib/app/(signed-in)/orders/$id/`                                 | The detail, and `pay`: an ordinary call that the server steps up (`@authn`) and the session completes with the **user-present key**; a cancelled prompt is the refusal (`stepUp` set) |
| [`server/src/auth.rs`](server/src/auth.rs)                        | `DeviceAuth`, CrateStack's `AuthProvider`: no credential is anonymous (the schema's policies decide); a credential is verified by `authkestra_devsig::verify` and checked against the device's record (`device_not_active`, `device_revoked`, `key_not_bound`). Every refusal is an `AuthRefusal` with the profile's status, the code as the `error` member and a `WWW-Authenticate: DeviceSignature error="<code>"` challenge (on the 403 too: the body is CBOR). `principal_of` gives the procedures `key_role`, `amr` from the key and, for the user-present key, an `auth_time` |
| [`server/src/issuer.rs`](server/src/issuer.rs)                    | Authkestra's side: the token manager with the server's Ed25519 issuer key, the challenge store, profile v1's `VerifierConfig`, the issuer JWKS, the replay store, and the two hooks the handlers leave to the application (`OneCode`, the second factor; `KeyStatus`, the device's status at a renewal) |
| [`server/src/procedures.rs`](server/src/procedures.rs)            | The procedures: the ceremonies call `handle_enrol_start`, `handle_reissue_start` and `handle_complete_challenge`; the orders; `placeOrder` and `payOrder` run once per user and `Idempotency-Key` (after authentication: see below) |
| [`server/src/test_hooks.rs`](server/src/test_hooks.rs)            | `POST /test/revoke`, an operator's revocation, only with `--test-hooks`: not in the schema, so the generated client has no such call, and a route merged next to the router, not a layer |

## Screenshots

| `/`                                                                                                                                                                             | `/enrol`                                                                                                                                               | `/orders`, not enrolled                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ![The cratestack example's public home page: CrateStack example in the app bar, Not enrolled, and an Enrol this device button.](../../docs/images/examples/cratestack/home.png) | ![The enrolment page: a back arrow and the title Enrol, a Phone number field and a Send code button.](../../docs/images/examples/cratestack/enrol.png) | ![The enrolment page a device that is not enrolled gets for /orders: Enrol to see /orders above a Phone number field and a Send code button.](../../docs/images/examples/cratestack/guarded.png) |

A release web build in Chromium, 390 × 844 CSS pixels at 2× (`just example-screenshots cratestack`). The signed-in screens
need the server, which that check does not run.

## Run it

Two terminals. The server first (Rust, the toolchain in `server/rust-toolchain.toml`):

```sh
cd examples/cratestack/server
cargo run --locked -- --listen 127.0.0.1:8788
# {"addr":"127.0.0.1:8788","audience":"fespalier-cratestack","issuer_jwk":{...}}
```

Then the app:

```sh
cd examples/cratestack
flutter create --empty . --platforms=android,ios,web   # adds the platform folders, .gitignore and .metadata
flutter pub get
flutter run --dart-define=ORDERS_SERVER_URL=http://127.0.0.1:8788
```

Enrol with any phone number (`+237 6 55 00 00 00`) and the code `123456`. `ORDERS_AUDIENCE` must be the server's
`--audience` (the default is the same string in both). An Android emulator reaches the host at `10.0.2.2`, or through
`adb reverse tcp:8788 tcp:8788`; plain HTTP needs the platform's cleartext allowance (see [`examples/cose`](../cose/README.md#on-an-android-emulator-or-a-phone)).
The keys are in the Secure Enclave or the AndroidKeyStore where the platform has them; the web has the ambient key only
(paying says it cannot confirm), and Windows and Linux ask for `KeypairFallback.software`, a key in memory.

The server forgets everything at a restart (devices, orders, the single-use `jti`s), and draws a new Ed25519 issuer key
unless it is given `--issuer-seed-hex` (64 hex digits): an old session then reads `unknown_kid`, which the client renews on,
and the renewal's 403 for a device the server never saw ends the session as revoked, so enrol again. `--test-hooks` adds
the end-to-end test's `POST /test/revoke`; never pass it to a server anyone else can reach.

## Decisions

- **RPC, not REST.** Every procedure is `POST /rpc/procedure.<name>`, errors are typed (`CratestackRpcException` with a
  status, a code and a message), and a call takes an `Idempotency-Key` in its options. Public and signed procedures are the
  same shape: a request with no credential is anonymous, which the public procedures' `@allow(true)` lets in and every
  other procedure's `@allow(auth() != null)` refuses (403, with no profile code, so a client reads nothing into it).
- **No Dio, and the test says so.** `test/no_http_test.dart` greps the app, the generated client and both pubspecs, and the
  resolved package graph: Dio is nowhere, and `package:http` is named in `lib/app/startup.dart` alone.
- **`--fespalier-ref` is a commit of fespalier, not a tag.** The preset pins `fespalier_transport` by git. fespalier 0.21.0
  is not released, so the default (`v0.21.0`) resolves to nothing yet; inside this repository `pubspec.yaml` overrides it
  with the checkout anyway, so the pin is never fetched. A commit is not a `ref: v...`, which `cli/tests/versions.rs` reads
  as fespalier's own version and release-please would never bump. In your own app leave `--fespalier-ref` out.
- **Authkestra is pinned to one commit.** Device-signature profile v1 (Authkestra#440) is in no crates.io release yet, so
  `authkestra-devsig`, `authkestra-op` and `authkestra-engine` are git dependencies at one `rev`, in `server/Cargo.toml`
  and `server/Cargo.lock` (`cli/tests/versions.rs` keeps them equal). Only this example depends on Authkestra: CI's
  `cratestack` job checks with `cargo tree -i` that no CrateStack crate reaches it. `rustls-no-provider`: the engine's HTTP
  client is never built here, so no TLS provider (and no C code) is compiled in. The issuer key is Ed25519 (the token
  manager signs RS256 or EdDSA, and profile v1 accepts both).
- **CrateStack is pinned to 0.17.2, on both sides**: the server's two CrateStack dependencies are `=0.17.2`, the first
  release with `@authn` and the generated clients' `StepUpRequired` (cratestack/cratestack#1244), and `CRATESTACK_REV` in
  `scripts/cratestack-client.sh` is the commit of its tag `v0.17.2`, which the CLI is built from (a commit, never a tag
  name). `just cratestack-cli` installs the CLI. `--no-native-cbor`: the pure-Dart `cbor`, so the client needs no native
  library.
- **Step-up is the server's rule, and the session follows it.** `payOrder` declares `@authn(amr: ["user"])` (RFC 8176
  `user`, a user-presence test). The server's principal says how a request was signed: `amr` `["user", "pop"]` and an
  `auth_time` for the user-present key (the earliest the verifier could have accepted the signature from, `now - skew -
  300 s`: `authkestra-devsig` hands back no signature time, and a lower bound errs on the strict side of a `maxAge`), `["pop"]` and no `auth_time` for the ambient one. Not `hwk`:
  the server cannot tell a hardware-backed key from the software fallback, and it claims nothing it did not check. An
  ambient-key payment is refused before the procedure runs with RFC 9470's 401, which carries `WWW-Authenticate: Bearer
error="insufficient_user_authentication"` on the RPC unary response too (the body is CBOR, so the client reads the
  header); the session's `DeviceSigner` signs the same request again with the user-present key and sends it once more
  (since 0.25.0). Nothing in the app asks for the key: the confirm header and `ConfirmTransport` of 0.21.0 are gone.
- **A write runs once per user and `Idempotency-Key`, decided after authentication.** `placeOrder` and `payOrder` keep
  their answer under the subject and the key (`server/src/procedures.rs`), and a retry with the same arguments gets it
  back; the same key with other arguments is `422 idempotency_key_conflict`. CrateStack's `IdempotencyLayer` is not used:
  it runs in front of the router, before any `AuthProvider`, so without a layer of our own in front of it its namespace
  could only come from something it reads unverified (an attestation is public, and changes at every renewal, which would
  run a retry twice). A refusal never reaches a procedure, so it is never kept: the session's retry after a renewal or a
  step-up (the very same request, under the same key) runs once.
- **The generated files are committed.** `client/` (the generator's output, formatted, and `*.g.dart`, `*.mapper.dart`,
  `*.builder.dart` from `build_runner`) is in the repository, like `lib/app.g.dart`, so a clone builds with `flutter pub
get`. `scripts/cratestack-client.sh check` generates again into a temporary directory and compares everything the
  generator writes; the `build_runner` files are not compared (their text depends on the builders' resolution, and a stale
  one does not compile). Never edit a file in `client/`: change `server/schema.cstack` and run `just cratestack-client`.

## What the generated client could not do, and what the example does about it

Each of these is a gap to close upstream; none needs a change to CrateStack here. (Over RPC a rejected field is
`422 invalid_argument`, which `fespalier_cratestack` reads like REST's `VALIDATION_ERROR`: no workaround is needed.)

- **A call cannot carry attributes for the session.** `CratestackRpcCallOptions` has headers, an idempotency key and an
  abort trigger; `CratestackHttpRequest.extra` (which the fespalier transport forwards as `TransportRequest.attributes`) is
  never filled by the RPC adapter ([cratestack/cratestack#1207](https://github.com/cratestack/cratestack/issues/1207)). The
  user-present key no longer needs one (the server's step-up asks for it), and work the user is not looking at, which must
  never prompt, runs inside `Authorizer.unattended(...)`, the zone form of `Authorizer.stepUpAttribute: false`.
- **Authkestra's enrolment is shaped differently from `DeviceAuthServer`.** It checks the second factor before it issues a
  challenge, one key at a time, and re-issues an attestation from that attestation and its JWK. `DeviceAuthServer` sends
  the code with the signatures and renews by device and role. The recipe absorbs both: the code is asked for first and sent
  in leg one, and the server hands Authkestra the attestation it last issued for the key being renewed. A generated
  `DeviceAuthServer` (a `--preset fespalier` that knows the enrolment procedures) would remove the hand-written one; until
  then `lib/src/device_server.dart` is the recipe.
- **Idempotency before authentication.** `IdempotencyLayer` keys on a principal it derives before any `AuthProvider`
  runs, which is why the old example kept a verification layer in front of it. With the check in the provider, the
  example keeps a write's answer in its procedures instead (see Decisions). An admission step that runs after
  `authenticate` would let the layer come back.
- **An intent the session ended is unclassified.** When a queued write is refused with `403 device_revoked`, the session
  throws `AuthRejected`, which no `fespalier_cratestack` reader knows, so the intent is kept under its key; the app's
  `wipeWhenSessionEnds` is what removes it, with the rest of the account's data.
- **A renewal shared by several calls may inherit the abort trigger of the first (suspected, not yet confirmed).** `ref.cancellable` puts the page's trigger
  in the zone, `SessionTransport` starts the single-flight renewal in that zone, and a page that goes away might abort the
  renewal for every call that waits for it. `OrdersDeviceServer` runs each leg in a zone with a trigger that never fires.
  (Upstream: the session should start a renewal outside the caller's zone.)

## Tests

`test/` runs against `test/fake_server.dart`, an in-memory server on `FakeTransport` that checks every signed call with
`verifyDeviceSignature`, on a fake clock and `FakeKeypairSigner` keys. No test here touches a secure element.

- `enrol_test.dart`: the unsigned legs (the code, then the keys with it, then the signatures), every later call signed with no `Authorization`, field errors for a wrong number
  or code, and the guard to the enrolment and back.
- `orders_test.dart`: the list, the detail, a missing order, a new order (the `Idempotency-Key`, the list loaded again) and
  the server's validation answer under its field.
- `abort_test.dart`: leaving a page aborts its request (`FakeTransport.abortCount`), the detail's and the list under it.
- `offline_test.dart`: a `TransportUnsent` reads as offline and the list is the copy this phone saved; nothing saved is said;
  a refusal is never covered by the copy.
- `renew_test.dart`: an expired attestation is renewed once for two calls; a `401 attestation_expired` renews and sends
  the call again; a forgotten or revoked device ends the session as `revoked`.
- `presence_test.dart`: paying is refused for the ambient key and signed again with the user-present key (one prompt, the
  same request and `Idempotency-Key`); a cancelled prompt leaves the refusal and nothing else; work inside
  `Authorizer.unattended` never prompts; a device with no user-present key cannot confirm.
- `sign_out_test.dart`: sign-out revokes the device (signed with the user-present key), deletes both keys, and wipes what the
  phone saved.
- `wiring_test.dart`, `no_http_test.dart`: the chain and the generated seams.
- `e2e_test.dart` starts the **real server binary** (`ORDERS_SERVER_BIN`; skipped without it, a failure with
  `FSP_REQUIRE_ORDERS_SERVER=1`) and drives the app's own wiring over real sockets: enrolment, signed reads and writes, a
  write replayed under one key, the step-up (an ambient-key `payOrder` refused, then completed with one user-present
  signature and one retry; a cancelled prompt surfacing the 401; unattended work never prompting), a replayed or tampered
  or unsigned request, sign-out and
  `device_revoked`, a renewal before a call and after a real `401 attestation_expired`, a restarted server that forgot the
  device, `keyLost` after a real `401 key_not_bound`, `revoked` after an operator's revocation, and **the revocation of a
  device with queued intents** (three writes queued offline, the device revoked, the network back: one send, refused, the
  session ended as revoked, the queue wiped, nothing sent after the refusal, and the send signed at send time with a jti of
  its own). The server has its own tests in `server/tests/` (`api.rs` for the router with a Rust device; `profile_v1.rs`
  runs Authkestra's profile v1 vectors, the copy `fespalier_sign_keypair` vendors, through `authkestra_devsig::verify_at`
  and the server's refusal rendering, so the client's copy, the Authkestra commit and the wire form agree).
  `--clock-skew-secs` (30 by default, the profile's) and `--attestation-ttl-secs` let the end-to-end test see an
  attestation refused as soon as it expires.

```sh
just cratestack          # the server's gates, the client compared with a fresh one, then the app's tests with the server required
cd examples/cratestack && flutter pub get && flutter test   # the end-to-end test skips without ORDERS_SERVER_BIN
```

## Unchecked on a device

No CI job runs these; the tests use `FakeKeypairSigner`. They belong in a `human-test` issue, like the device example's:

- **The user-present prompt**: the biometric or device-credential prompt, its caption (`stepUpReason`, here "Confirm it
  is you"), a cancelled prompt, a device with no screen lock, and how each surfaces: as the step-up refusal for a call the
  session escalated, as `UserPresenceRefused` for one signed with that key from the start.
- **Biometric invalidation** (enrolling or removing a fingerprint destroys the user-present key and leaves the ambient one).
- **The web key** across a reload, a restart and "clear site data", in Safari and Firefox.
- **Hardware-backed keys** on real StrongBox and Secure Enclave devices, and the fallback to a software key.
- **A real network**: the app against `server/` from a phone, over plain HTTP and over TLS. No test here sends a request
  from a phone.
