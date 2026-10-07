# fespalier_sign_keypair

Device-bound sessions for [`fespalier_auth`](../fespalier_auth) (since 0.9.0): **DPoP**
([RFC 9449](https://www.rfc-editor.org/rfc/rfc9449)) proofs signed by a key that lives in the Secure Enclave
(iOS, macOS) or the AndroidKeyStore (StrongBox or the TEE), through
[flutter-sign-keypair](https://github.com/vaam-apps/flutter-sign-keypair). The server binds the access and refresh
tokens to the key (`cnf.jkt`), so a token copied off the device is useless without the device.

The docs cover it in context:
[Device-bound tokens](https://github.com/fespalier/fespalier/blob/main/docs/auth.md#device-bound-tokens-dpop-with-fespalier_sign_keypair).
This page is the short version.

## Install

Add it next to fespalier and `fespalier_auth`, with the same `url` and the same `ref` for all three: pub resolves
them to one package each only if they are the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.9.1
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.9.1
  fespalier_sign_keypair:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_sign_keypair
      ref: v0.9.1
```

<!-- x-release-please-end -->

Needs Dart 3.12 and Flutter 3.44 or newer (flutter-sign-keypair needs them), Android minSdk 24, iOS 15 and
macOS 10.15. flutter-sign-keypair is not on pub.dev: this package depends on it by git, **pinned to a commit** (the
one of its v0.1.2), so `flutter pub get` clones `github.com/vaam-apps/flutter-sign-keypair`. Pub resolves that
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
    proof: DpopProof.device(), // throws DpopUnavailable on the web unless a fallback is given
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

Nothing else changes: `OidcBackend` signs the token and refresh calls and sends `dpop_jkt` with the authorization
request, `authHttpClient` signs every request to `apiOrigins` (`Authorization: DPoP <token>` and a `DPoP` proof with
`ath`), answers a nonce challenge once, and `restoreAuth` signs the user out (`SignedOut(keyLost)`) when the key a
stored session is bound to is gone.

## Platforms and fallbacks

| Platform                     | The key                                                                     |
| ---------------------------- | --------------------------------------------------------------------------- |
| Android                      | AndroidKeyStore: StrongBox, then the TEE, then software (`requireHardware`) |
| iOS, macOS                   | Secure Enclave, or the keychain on a simulator (`requireHardware`)          |
| Web, Windows, Linux, Fuchsia | **None**: `DpopFallback` says what happens                                  |

`DpopProof.device(fallback: ...)`: `DpopFallback.refuse` (the default) throws `DpopUnavailable` where there is no
secure element, early and loud, because a library that promises tokens bound to a device must not quietly give you
tokens bound to nothing. `DpopFallback.software` is a key in memory (`SoftwareDpopSigner`: the scalar is in the
process, and **on the web it does not survive a reload**, so the session is signed out; pass `softwareStore:` to keep
it), and `DpopFallback.bearer` returns null, so the tokens are plain bearer tokens (the client must not require
DPoP-bound ones). `requireHardware: true` makes a device without a secure element fail with the
`SecureSignerException` of flutter-sign-keypair (the iOS simulator has only the keychain).

The key is an _ambient_ key (`KeyProtection.ambient`): it never prompts, because a proof is made for every request
and a refresh runs with no screen to show a prompt on. It is made on first use, under the key id `fespalier_dpop`,
and sign-out deletes it (`rotateKeyOnSignOut`), so the next sign-in makes a new one: an old refresh token, even a
stolen one, is useless.

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

`package:fespalier_sign_keypair/testing.dart` has `FakeDpopSigner` (a software key from a fixed scalar, the same key
and, with RFC 6979, the same signature on every run, and `deleteKey` moves to the next key) and exports
`verifyDpopProof`, which a fake server checks every proof with: `typ`, `alg`, the key, the signature, `htm`, `htu`,
`jti`, `ath`, `nonce`, `iat` and the key's thumbprint, each failing with a `DpopProofInvalid` that names the check.
It does not remember `jti`s: refusing a proof that was used is the server's job.

```dart
final dpop = DpopProof(signer: FakeDpopSigner());
final proof = await dpop.proof(method: 'GET', uri: uri, accessToken: token);
verifyDpopProof(proof, method: 'GET', uri: uri, accessToken: token, thumbprint: await dpop.thumbprint());
```

`DpopProof.proof(...)` makes one proof for a request made without `fespalier_auth`'s clients, and `publicJwk()` is
the key for a backend that registers devices itself.

## What it costs

One ES256 signature per authenticated request and per token-endpoint call (the secure element's, on a device). A
proof is single-use, so nothing is cached. No timer, no `Future.delayed`, no listener and no `DateTime.now()` in
the package (a test greps `lib/` for them). An app that does not import it is unchanged.

Not done: signing a sensitive operation with flutter-sign-keypair's user-present key (a biometric prompt), which
would be a second, prompting key beside this one; it is a follow-up.
