/// DPoP (RFC 9449) for `fespalier_oidc` (since 0.21.0; it was `fespalier_sign_keypair`, from
/// 0.9.0): proofs signed by a `KeypairSigner` of `fespalier_keypair`, in the Secure Enclave on iOS
/// and macOS, the AndroidKeyStore on Android, or a browser's non-extractable `CryptoKey`.
///
/// ```dart
/// OidcBackend(
///   issuer: issuer,
///   clientId: 'shop-app',
///   redirectUri: Uri.parse('com.example.shop:/callback'),
///   openBrowser: openBrowser,
///   transport: transport, // an HttpTransport, the one of AuthConfig.transport
///   proof: DpopProof.device(), // throws DpopUnavailable on Windows and Linux unless a fallback is given
/// )
/// ```
library;

export 'src/dpop_proof.dart' show DpopFallback, DpopProof, DpopUnavailable;
export 'src/jose.dart' show accessTokenHash, dpopHtu;
