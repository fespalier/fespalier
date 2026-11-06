/// Checking an ES256 signature in pure Dart (since 0.21.0): what a server, a demo server and a
/// test do with a `jwk` and a signature a `KeypairSigner` made. No plugin, no platform channel.
/// Since the release after 0.25.0 also EdDSA (Ed25519, strict) and RS256, the other two issuer
/// algorithms of Authkestra's device-signature profile v1: `verifyEd25519` and `verifyRs256`.
/// `fespalier_keypair_dpop`'s `verifyDpopProof` and `fespalier_sign_keypair`'s
/// `verifyDeviceSignature` both build on it.
///
/// ```dart
/// final ok = verifyEs256(jwk, utf8.encode('$header.$payload'), signature);
/// ```
library;

export 'src/ed25519.dart' show publicEd25519Key, verifyEd25519;
export 'src/rs256.dart' show minRsaModulusBits, publicRsaKey, verifyRs256;
export 'src/verify.dart' show publicP256Jwk, verifyEs256;
