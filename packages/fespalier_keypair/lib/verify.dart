/// Checking an ES256 signature in pure Dart (since 0.21.0): what a server, a demo server and a
/// test do with a `jwk` and a signature a `KeypairSigner` made. No plugin, no platform channel.
/// `fespalier_keypair_dpop`'s `verifyDpopProof` and `fespalier_sign_keypair`'s
/// `verifyDeviceSignature` both build on it.
///
/// ```dart
/// final ok = verifyEs256(jwk, utf8.encode('$header.$payload'), signature);
/// ```
library;

export 'src/verify.dart' show publicP256Jwk, verifyEs256;
