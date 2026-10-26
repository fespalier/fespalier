# fespalier_keypair_dpop

**DPoP** ([RFC 9449](https://www.rfc-editor.org/rfc/rfc9449)) for [`fespalier_oidc`](../fespalier_oidc) (since 0.21.0; it
was `fespalier_sign_keypair` from 0.9.0 to 0.20.0): proofs signed by a key of
[`fespalier_keypair`](../fespalier_keypair), which lives in the Secure Enclave (iOS, macOS), the AndroidKeyStore
(StrongBox or the TEE), or a browser's non-extractable `CryptoKey`. The server binds the access and refresh tokens to
the key (`cnf.jkt`), so a token copied off the device is useless without the device. `DpopProof` implements
`fespalier_oidc`'s `ProofOfPossession`. It links neither `package:http` nor Dio.

The docs cover it in context:
[Device-bound tokens](https://github.com/fespalier/fespalier/blob/main/docs/auth.md#device-bound-tokens-dpop-with-fespalier_keypair_dpop).
This page is the short version.

## Install

Add it next to fespalier, `fespalier_auth` and `fespalier_oidc`, with the same `url` and the same `ref` for all of
them: pub resolves them to one package each only if they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.24.0
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.24.0
  fespalier_oidc:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_oidc
      ref: v0.24.0
  fespalier_keypair:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_keypair
      ref: v0.24.0
  fespalier_keypair_dpop:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_keypair_dpop
      ref: v0.24.0
```

<!-- x-release-please-end -->

Needs Dart 3.12 and Flutter 3.44 or newer (flutter-sign-keypair needs them), Android minSdk 24, iOS 15 and
macOS 10.15. flutter-sign-keypair is not on pub.dev: `fespalier_keypair` depends on it by git, **pinned to a commit**
(the one of its v0.1.2), so `flutter pub get` clones `github.com/vaam-apps/flutter-sign-keypair`. Pub resolves that
dependency for you; your app does not name it.

## Wire it

Give the backend a proof maker. `DpopProof.device()` is the right one for this device:

```dart
// lib/auth_setup.dart
AuthConfig authSetup() => AuthConfig(
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(issuer),
    openBrowser: openBrowser,
    proof: DpopProof.device(), // throws DpopUnavailable on Windows and Linux unless a fallback is given
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

Nothing else changes: `OidcBackend` signs the token and refresh calls and sends `dpop_jkt` with the authorization
request, `SessionTransport` signs every request to `apiOrigins` (`Authorization: DPoP <token>` and a `DPoP` proof with
`ath`), answers a nonce challenge once, and `restoreAuth` signs the user out (`SignedOut(keyLost)`) when the key a
stored session is bound to is gone.

## Platforms and fallbacks

`DpopProof.device()` asks `KeypairSigners.device` for the **ambient** key (DPoP signs every request and every
renewal, with no screen to show a prompt on):

| Platform                  | The key                                                                      |
| ------------------------- | ---------------------------------------------------------------------------- |
| Android                   | AndroidKeyStore: StrongBox, then the TEE, then software (`requireHardware`)  |
| iOS, macOS                | Secure Enclave, or the keychain on a simulator (`requireHardware`)           |
| Web                       | A non-extractable `CryptoKey` in IndexedDB (not a secure element; see below) |
| Windows, Linux, Fuchsia   | **None**: `DpopFallback` says what happens                                   |

`DpopProof.device(fallback: ...)`: `DpopFallback.refuse` (the default) throws `DpopUnavailable` where there is no
key, early and loud, because a library that promises tokens bound to a device must not quietly give you tokens bound
to nothing. `DpopFallback.software` is a key in memory (`SoftwareKeypairSigner`: the scalar is in the process; pass
`softwareStore:` to keep it across restarts), and `DpopFallback.bearer` returns null, so the tokens are plain bearer
tokens (the client must not require DPoP-bound ones). `requireHardware: true` makes a device without a secure element
fail with the `SecureSignerException` of flutter-sign-keypair (the iOS simulator has only the keychain), and refuses
the web's key, which is not a secure element.

**Behaviour change since 0.21.0**: on the web `DpopProof.device()` used to refuse by default (and, with
`DpopFallback.software`, made a key that did not survive a reload, so the session was signed out). It now uses the
browser's non-extractable key, kept in IndexedDB, so the session survives a reload. That key is **UNCHECKED in CI**
(see [`fespalier_keypair`](../fespalier_keypair#the-web-key)): run by hand in Chrome only.

The key is made on first use, under the key id `fespalier_dpop`, and sign-out deletes it (`rotateKeyOnSignOut`), so
the next sign-in makes a new one: an old refresh token, even a stolen one, is useless.

## Keycloak

Keycloak supports DPoP since 26.4. On the client, switch on **Require DPoP bound tokens** (the attribute
`dpop.bound.access.tokens`), which makes both tokens DPoP-bound for a public client. Without it, a client that
receives a proof still gets DPoP tokens, but one that sends none gets bearer tokens. Read from Keycloak 26.8.0:

- **Errors are `invalid_request` with descriptions**: `DPoP proof is missing`, `DPoP proof is not active` (the
  clock), `DPoP proof has already been used` (a proof sent twice), and
  `DPoP Proof public key thumbprint does not match dpop_jkt`; a refresh token bound to another key is
  `invalid_grant` / `DPoP confirmation doesn't match DPoP proof`.
- **No `DPoP-Nonce`, and no `Date` header**: a wrong device clock cannot be corrected from Keycloak's own
  answer (see below).
- Resource-server answers are 401 with `WWW-Authenticate: DPoP algs="...", error="invalid_token"` for every
  problem with the proof.

## What a proof is

`{"typ":"dpop+jwt","alg":"ES256","jwk":{crv,kty,x,y}}` and `{jti, htm, htu, iat, ath?, nonce?}`, signed ES256 by the
key. `jti` is 16 random bytes, new for every send, retries included; `htu` has no query or fragment; `ath` is only on
requests that carry an access token; `nonce` is the last `DPoP-Nonce` seen from that origin. One signature per
request, made by the secure element; nothing is cached between requests, and no timer or listener is started.

- **Nonces.** A `DPoP-Nonce` on any response is kept for its origin. A challenge (`400` with `use_dpop_nonce` from
  an authorization server, `401` with `WWW-Authenticate: DPoP error="use_dpop_nonce"` from a resource server) is
  answered once, with a new proof.
- **Clock.** `iat` is the device clock (`clock.now()`). When a server refuses a proof as not active (`400`
  `invalid_dpop_proof`, or Keycloak's `invalid_request`; a `401` `invalid_dpop_proof` or `invalid_token`) **and** the
  response has a `Date` header that differs from the device clock by more than `clockCorrectionThreshold` (5
  seconds), the difference is applied to every later `iat` and the request is sent once more. Nothing is learned from
  successful responses, so there is no drift and tests are deterministic. A server that sends no `Date` (Keycloak,
  behind no proxy) cannot correct a wrong clock: set the clock.
- **Two problems at once** (a server that requires a nonce and a device clock that is wrong) take two retries, and a
  request is retried once: the first sign-in or request fails, the nonce is kept, and the next one corrects the
  clock.

Do not put `package:http`'s `RetryClient` **under** the session client: it sends the same headers again, so the same
proof, and the server refuses a reused `jti`. Wrap the session client in it instead.

## Tests

`package:fespalier_keypair/testing.dart` has `FakeKeypairSigner` (a software key from a fixed scalar, the same key
and, with RFC 6979, the same signature on every run, and `deleteKey` moves to the next key), and
`package:fespalier_keypair_dpop/verify.dart` has `verifyDpopProof`, which a fake server checks every proof with: `typ`, `alg`, the key, the signature, `htm`, `htu`,
`jti`, `ath`, `nonce`, `iat` and the key's thumbprint, each failing with a `DpopProofInvalid` that names the check.
It does not remember `jti`s: refusing a proof that was used is the server's job.

```dart
final dpop = DpopProof(signer: FakeKeypairSigner());
final proof = await dpop.proof(method: 'GET', uri: uri, accessToken: token);
verifyDpopProof(proof, method: 'GET', uri: uri, accessToken: token, thumbprint: await dpop.thumbprint());
```

`DpopProof.proof(...)` makes one proof for a request made without `fespalier_auth`'s clients, and `publicJwk()` is
the key for a backend that registers devices itself.

## What it costs

One ES256 signature per authenticated request and per token-endpoint call (the secure element's, on a device). A
proof is single-use, so nothing is cached. No timer, no `Future.delayed`, no listener and no `DateTime.now()` in
the package (a test greps `lib/` for them). An app that does not import it is unchanged.

Signing a sensitive operation with the user-present key is not DPoP's job: that key is `KeyRole.userPresent` of
`fespalier_keypair`, which `fespalier_sign_keypair` uses for device-signed requests.
