/// Device-bound sessions for `fespalier_auth` (since 0.9.0): DPoP (RFC 9449) proofs signed by
/// the hardware-backed ES256 key of flutter-sign-keypair, in the Secure Enclave on iOS and macOS
/// and the AndroidKeyStore on Android.
///
/// ```dart
/// OidcBackend(
///   issuer: issuer,
///   clientId: 'shop-app',
///   redirectUri: Uri.parse('com.example.shop:/callback'),
///   openBrowser: openBrowser,
///   proof: DpopProof.device(), // throws DpopUnavailable on the web unless a fallback is given
/// )
/// ```
library;

export 'src/dpop_proof.dart' show DpopFallback, DpopProof, DpopUnavailable;
export 'src/jose.dart' show accessTokenHash, dpopHtu, jwkThumbprint;
export 'src/signer.dart' show DpopSigner, SignKeypairSigner, SoftwareDpopSigner;
