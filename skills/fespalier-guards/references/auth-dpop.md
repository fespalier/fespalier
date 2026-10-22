# Device-bound tokens: DPoP with `fespalier_keypair_dpop`

Since 0.9.0, in its own package since 0.21.0. `package:fespalier_keypair_dpop` is DPoP
([RFC 9449](https://www.rfc-editor.org/rfc/rfc9449)) for `OidcBackend`: every token request, renewal and API call carries a
proof, a JWT signed by a key that lives in the Secure Enclave (iOS, macOS), the AndroidKeyStore (StrongBox, or the TEE) or, on
the web, a non-extractable `CryptoKey`. The server binds the access and refresh tokens to that key (`cnf.jkt`), so a token
copied off the device is useless without the device. `DpopProof` implements `fespalier_oidc`'s `ProofOfPossession` seam, on a
`KeypairSigner` from `fespalier_keypair`: nothing else in the app changes, no generated code changes, and an app that does not
import it is byte-for-byte what it was.

It was `package:fespalier_sign_keypair` until 0.20.0 (`DpopProof`, `DpopSigner`, `SignKeypairSigner`, `SoftwareDpopSigner` and
`FakeDpopSigner` lived there). That package is now the token-free [device-signed session](auth-device-sessions.md); the keys are
`KeypairSigner`, `HardwareKeypairSigner`, `SoftwareKeypairSigner` and `FakeKeypairSigner` in `fespalier_keypair`. A hard
cutover, no re-export.

```yaml
# pubspec.yaml: the same url and the same ref for all of them, or pub refuses to resolve
dependencies:
  fespalier:
    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier, ref: <the tag>}
  fespalier_auth:
    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_auth, ref: <the same tag>}
  fespalier_oidc:
    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_oidc, ref: <the same tag>}
  fespalier_keypair:
    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_keypair, ref: <the same tag>}
  fespalier_keypair_dpop:
    git: {url: https://github.com/fespalier/fespalier, path: packages/fespalier_keypair_dpop, ref: <the same tag>}
```

(A fragment, not a sample: pub resolves them only at a release tag.) They need Dart 3.12 and Flutter 3.44 (their dependency
flutter-sign-keypair needs them), Android minSdk 24, iOS 15 and macOS 10.15. flutter-sign-keypair is **not on pub.dev**:
`fespalier_keypair` depends on it by git, **pinned to a commit**, so `flutter pub get` clones
`github.com/vaam-apps/flutter-sign-keypair`, and your app does not name it. These packages are outside the pub workspace and
the Flutter 3.35 floor job of the repository for that reason.

## Wire it

```dart
// lib/auth_setup.dart
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:http/http.dart' as http;

final issuer = Uri.parse('https://sso.example.com/realms/shop');
final transport = HttpClientTransport(http.Client());

Future<Uri> openBrowser(Uri url, Uri redirect) =>
    throw UnimplementedError('flutter_web_auth_2: see auth-backends.md');

AuthConfig authSetup() => AuthConfig(
  transport: transport,
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(issuer),
    openBrowser: openBrowser,
    transport: transport,
    // The hardware key on Android, iOS and macOS, the browser's key on the web. On Windows and
    // Linux it throws DpopUnavailable (the default), which `startup()` shows early and loud.
    proof: DpopProof.device(),
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

`OidcBackend` signs the token and renewal calls and sends `dpop_jkt` with the authorization request (the code is bound to
the key too); `authTransport` (the `SessionTransport`) signs every request to `apiOrigins` (`Authorization: DPoP <token>` and a
`DPoP` header with `ath`) and answers a nonce challenge once, because `BearerAuthenticator` asks the proof what a response means
(`Resend`); `restoreAuth` signs the user out (`SignedOut(reason: SignOutReason.keyLost)`) when the key a stored session is bound
to is gone (a restored backup, a wiped keychain), through `OidcBackend.check`. `DpopProof.device()` has to be called where it
can throw: from `authSetup()` in `startup()`.

A token whose type is `DPoP` with no `proof:` on the backend is a `StateError` at the first request:
`fespalier_oidc: the access token is DPoP-bound (token_type DPoP), but the backend has no proof of possession: pass proof:
DpopProof.device() (package:fespalier_keypair_dpop) to the backend`.

## Where there is no secure element

`DpopProof.device(fallback: ...)` says what Windows, Linux, Fuchsia and a web page that is not a secure context get:

| `fallback`                      | What happens there                                                                                                                                                    |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DpopFallback.refuse` (default) | `DpopUnavailable`: a library that promises tokens bound to a device must not quietly give you tokens bound to nothing                                                 |
| `DpopFallback.software`         | `SoftwareKeypairSigner`: the key is in memory, its scalar is in the process, and without a `softwareStore:` it does not survive a restart (the session is signed out) |
| `DpopFallback.bearer`           | No DPoP: `device()` returns null and the tokens are plain bearer tokens. The Keycloak client must **not** require DPoP-bound tokens                                   |

`requireHardware: true` makes a device without a secure element fail (the iOS simulator has only the keychain; where there is no
secure element at all it is `DpopUnavailable` unless the fallback is `bearer`), and refuses the web's key, which is not one.

**The web (since 0.21.0).** `DpopProof.device()` uses the browser's non-extractable `CryptoKey`, kept in IndexedDB, so the
session **survives a reload**. Until 0.20.0 it refused on the web by default, and `DpopFallback.software` made a key that did
not survive a reload. That web key is **UNCHECKED in CI**: it was run by hand in Chrome only (Safari, Firefox, a private window
and "clear site data" are untried; `fespalier_keypair`'s README says what was and was not tried). It is not a secure element.

```dart
// lib/auth_setup_open.dart
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';

/// A software key where there is no secure element, and the hardware key elsewhere.
DpopProof? deviceProof() => DpopProof.device(fallback: DpopFallback.software);
```

## What it does

- **A proof** is `{typ: dpop+jwt, alg: ES256, jwk}` and `{jti, htm, htu, iat, ath?, nonce?}`, ES256 signed. `jti` is 16
  random bytes, **new for every send**, retries included; `htu` has no query or fragment; `ath` is only on requests
  that carry an access token; `nonce` is the last `DPoP-Nonce` seen from that origin. One signature per request, made by
  the secure element; nothing is cached (a proof is single-use), and no timer or listener is started.
- **Nonces.** A `DPoP-Nonce` on any response, a 200 included, is kept for its origin (an authorization server and a
  resource server keep their own). A challenge (`400` with `use_dpop_nonce` from an authorization server, `401` with
  `WWW-Authenticate: DPoP error="use_dpop_nonce"` from a resource server) is answered **once**, with a new proof.
- **The clock.** `iat` is `clock.now()`. When a server refuses a proof as not active (`400` `invalid_dpop_proof`, or
  Keycloak's `invalid_request` with `DPoP proof is not active`; a `401` `invalid_dpop_proof` or `invalid_token`) **and**
  the response has a `Date` header more than 5 seconds (`clockCorrectionThreshold`) from the device clock, the
  difference is applied to every later `iat` and the request is sent once more. Nothing is learned from successful
  responses (no drift, deterministic tests). **Keycloak sends neither a nonce nor a `Date`**, so a wrong clock there is
  `invalid_request` / `DPoP proof is not active`: set the clock.
- **Two problems at once** (a server that wants a nonce and a clock that is wrong) take two retries, and a request is
  retried once: the first sign-in or request fails, the nonce is kept, and the next one corrects the clock.
- **The key** is an _ambient_ one (it never prompts, because a proof is made for every request and a renewal runs with no
  screen to show a prompt on), made on first use under the key id `fespalier_dpop`. **Sign-out deletes it**
  (`rotateKeyOnSignOut`, through `AuthBackend.discard`), so the next sign-in makes a new one and an old refresh token, even a
  stolen one, is useless. The signature is 64 bytes `r||s` (a signer that returns another length is a `StateError`:
  `fespalier_keypair_dpop: the signer returned N bytes, not the 64-byte r||s signature that ES256 needs`).
- **A retrier goes over the session transport**, never under it: `RetryClient(TransportClient(ref.watch(authTransport)))`, or
  `dio_smart_retry` on a Dio whose adapter is `TransportAdapter(ref.watch(authTransport))`. Under it the same headers, so the
  same proof, go twice, and the server refuses a reused `jti` (Keycloak: `invalid_request` / `DPoP proof has already been used`;
  the demo server counts them in `reusedProofs`).
- **Cost.** One ES256 signature per authenticated request and per token-endpoint call. Nothing else.

## Keycloak

Keycloak supports DPoP since 26.4. Switch on **Require DPoP bound tokens** on the client (the attribute
`dpop.bound.access.tokens`; `examples/auth/keycloak/realm-fespalier.json` has `fespalier-auth-example-dpop`). Read from
Keycloak 26.8.0:

- Errors are `invalid_request` with descriptions: `DPoP proof is missing`, `DPoP proof is not active`,
  `DPoP proof has already been used`, and `DPoP Proof public key thumbprint does not match dpop_jkt`. A refresh
  token bound to another key is `invalid_grant` / `DPoP confirmation doesn't match DPoP proof`.
- The proof is accepted 20 seconds behind the server's clock and refused 20 seconds ahead (and 120 either way).
- A resource server's 401 is `WWW-Authenticate: DPoP algs="...", error="invalid_token"` for every problem with the proof
  (a missing proof, no `ath`, the wrong `htu`, `htm` or key, a clock that is off); a `Bearer` header for a DPoP-bound
  token gets `Bearer ... error="invalid_token"`. The query string of a request is not part of `htu`.
- A client that does not require DPoP still binds its tokens when it receives a proof.

## Tests

```dart
// test/dpop_proof_test.dart
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_keypair_dpop/verify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a proof is what a server checks', () async {
    final signer = FakeKeypairSigner(); // a software key from a fixed scalar: the same on every run
    final dpop = DpopProof(signer: signer);
    final uri = Uri.parse('https://api.example.com/orders');
    final proof = await dpop.proof(method: 'GET', uri: uri, accessToken: 'an-access-token');
    final decoded = verifyDpopProof(
      proof,
      method: 'GET',
      uri: uri,
      accessToken: 'an-access-token',
      thumbprint: await dpop.thumbprint(),
    );
    expect(decoded.claims['htu'], 'https://api.example.com/orders');
    // Signing out rotates the key: another thumbprint at the next sign-in.
    final before = await dpop.thumbprint();
    await dpop.reset();
    expect(await dpop.thumbprint(), isNot(before));
    expect(signer.deletes, 1);
  });
}
```

`FakeKeypairSigner` (in `package:fespalier_keypair/testing.dart`) is a software key from a fixed scalar (`sha256` of a seed,
derived at run time): the same key and, with RFC 6979, the same signature on every run; `deleteKey` moves to the next key;
`signatures`, `deletes` and `prompts` count. `FakeProof` (`package:fespalier_oidc/testing.dart`) is a proof with no crypto
at all, for a test of `OidcBackend` or a session. `verifyDpopProof` (pure Dart, in `package:fespalier_keypair_dpop/verify.dart`)
checks, in this order: a compact JWS of three parts, `typ` `dpop+jwt`, `alg` `ES256`, a public P-256 `jwk` on the curve,
the signature, `htm`, `htu`, `jti`, `ath`, `nonce`, `iat` within `window` (60 seconds) and, when given, the key's
thumbprint; each failure is a `DpopProofInvalid` that names the check. It does not remember `jti`s: refusing a proof that
was already used is the server's job (`examples/auth/lib/demo/demo_server.dart` does, and `test/dpop_test.dart` there is
the whole story: a nonce challenge, a clock that is two minutes behind, a renewal with the same key, a rotated key, a
`keyLost` restore, and a retrier on each side of the session).

`DpopProof.proof(method:, uri:, accessToken:)` makes one proof for a request made without `fespalier_auth`'s transport, and
`publicJwk()` is the key for a backend that registers devices itself. A key a server can verify **per request, with no token at
all**, is the other package: [`auth-device-sessions.md`](auth-device-sessions.md).

Every message is in [`fespalier-troubleshooting`](../../fespalier-troubleshooting/SKILL.md) (its `diagnostics-auth.md`
page); the rest of `fespalier_auth` is in [`auth-package.md`](auth-package.md) and [`auth-backends.md`](auth-backends.md).
