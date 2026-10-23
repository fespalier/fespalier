# fespalier_keypair

Keys that sign, and nothing else (since 0.21.0): a P-256 key behind a `KeypairSigner`, held in the Secure Enclave
(iOS, macOS) or the AndroidKeyStore (StrongBox or the TEE) through
[flutter-sign-keypair](https://github.com/vaam-apps/flutter-sign-keypair), in a browser's non-extractable
`CryptoKey`, or in memory. ES256 and the JOSE helpers that go with it. It has **no auth concept and no HTTP**: it
links neither `package:http` nor Dio, and none of the other fespalier packages. A protocol builds on it:
[`fespalier_keypair_dpop`](../fespalier_keypair_dpop) (DPoP, RFC 9449) and `fespalier_sign_keypair` (device-signed
sessions).

## Install

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier_keypair:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_keypair
      ref: v0.22.1
```

<!-- x-release-please-end -->

Needs Dart 3.12 and Flutter 3.44 or newer (flutter-sign-keypair needs them), Android minSdk 24, iOS 15 and macOS
10.15. flutter-sign-keypair is not on pub.dev: this package depends on it by git, **pinned to a commit** (the one of
its v0.1.2), so `flutter pub get` clones `github.com/vaam-apps/flutter-sign-keypair`. Pub resolves that dependency
for you; your app does not name it.

## The signer

```dart
abstract interface class KeypairSigner {
  KeyRole get role; // ambient: never prompts. userPresent: prompts on every sign.
  Future<Map<String, String>> publicJwk(); // {crv, kty, x, y}; makes the key on first use
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}); // 64-byte r||s, ES256
  Future<bool> isHardwareBacked();
  Future<bool> exists(); // without making the key
  Future<void> deleteKey();
}
```

A device holds two keys under two key ids: an **ambient** key that signs silently, on every request and in a
background renewal, and a **user-present** key that the secure element releases only after a live human unlocked it
(a biometric, the device credential). `reason` is the caption of that prompt.

| Signer                      | The key                                                                                     | Roles                  |
| --------------------------- | ------------------------------------------------------------------------------------------- | ---------------------- |
| `HardwareKeypairSigner`     | Secure Enclave (iOS, macOS); AndroidKeyStore: StrongBox, then the TEE (`requireHardware`)   | ambient, user-present  |
| `WebCryptoKeypairSigner`    | A non-extractable P-256 `CryptoKey` kept in IndexedDB (web only)                            | ambient                |
| `SoftwareKeypairSigner`     | The scalar in memory, or in a `SoftwareKeyStore` of your own (Windows, Linux, tests)        | ambient                |
| `FakeKeypairSigner` (tests) | A fixed scalar: the same key and signature on every run                                     | either                 |

`KeypairSigners.device(keyId:, role:, fallback:)` picks one for the platform, or refuses:

- Android, iOS, macOS: the hardware key of the role asked for.
- The web: the browser key, for the ambient role, in a secure context. Not a secure element, so `requireHardware`
  refuses it. A user-present key is **refused** (`KeypairUnavailable`): the browser cannot prompt for a `CryptoKey`.
- Windows, Linux, Fuchsia, or a web page with no secure context: `KeypairFallback.refuse` (the default) throws
  `KeypairUnavailable`, early and loud, because a library that promises keys bound to a device must not quietly give
  you a key bound to nothing; `KeypairFallback.software` is a key in memory, **for the ambient role only**: a software
  key never claims to prompt.

## The web key

`WebCryptoKeypairSigner` makes the private key with `extractable: false`, so no script on the page can read it out,
only ask the browser to sign; it keeps the key object in IndexedDB (database `fespalier_keypair`), which survives a
reload and a restart, and exports the public key as a JWK. It is not a secure element (`isHardwareBacked` is false)
and not a defence against script running on your own origin, which can sign while the page is open; what it stops is
a copy of the key, which is what binding a token to a key is for. Clearing the site's data deletes the key.

**UNCHECKED in CI.** No job of this repository runs it in a browser. Its tests (`test/web_crypto_signer_test.dart`)
were run by hand in Chrome (`flutter test --platform chrome`, with DDC and with `--wasm`) and passed; Firefox,
Safari, dart2js and a private window (where a browser may refuse IndexedDB) were not tried. Treat those as unverified.

## JOSE helpers

- `jwkThumbprint(jwk)`: the RFC 7638 thumbprint of a P-256 public key.
- `base64UrlNoPad(bytes)`, `base64UrlDecodeLoose(text)`.
- `compactJws(header, payload, signer, {reason})`: `header.payload.signature`, the members in the order given.
- `package:fespalier_keypair/verify.dart` (pure Dart, for a server, a demo server and a test): `verifyEs256(jwk,
  signingInput, signature)` checks a 64-byte `r||s` ES256 signature (false, never a throw, for anything wrong), and
  `publicP256Jwk(jwk)` returns `{crv, kty, x, y}` for a public P-256 key on the curve and null for anything else.
  `verifyDpopProof` and `verifyDeviceSignature` are built on them.

## Tests

`package:fespalier_keypair/testing.dart` has `FakeKeypairSigner`: a software key from a fixed scalar
(`sha256(seed)`), the same key and, with RFC 6979, the same signature on every run. `deleteKey` and `loseKey` move
to the next key. It plays the two failures a real key has: `refuseNextPrompt()` (the user cancels the biometric
prompt of a user-present key: a `SecureSignerException`, `userAuthenticationCancelled`) and `loseKey()` (the key is
gone behind the app's back: `exists()` is false, and the next use makes another).

## What it costs

One ES256 signature per call, made by the secure element (on a device). No timer, no `Future.delayed`, no listener
and no `DateTime.now()` in the package (`test/no_timers_test.dart` greps `lib/`), and no HTTP (`test/no_http_test.dart`).
