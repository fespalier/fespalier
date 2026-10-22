/// Keys that sign, and nothing else (since 0.21.0): a P-256 key behind a `KeypairSigner`, held in
/// the Secure Enclave or the AndroidKeyStore (flutter-sign-keypair), in a browser's non-extractable
/// `CryptoKey`, or in memory. No token, no session, no HTTP: a protocol builds on it
/// (`fespalier_keypair_dpop`, `fespalier_sign_keypair`).
///
/// ```dart
/// final signer = KeypairSigners.device(keyId: 'shop_device', role: KeyRole.ambient);
/// final jwk = await signer.publicJwk(); // makes the key on first use
/// final jws = await compactJws({'alg': 'ES256', 'jwk': jwk}, {'iat': 1}, signer);
/// ```
library;

// What its signers take and throw, so an app names no second package for them.
export 'package:flutter_sign_keypair/flutter_sign_keypair.dart'
    show
        InMemorySoftwareKeyStore,
        SecureSignerException,
        SignerErrorCode,
        SoftwareKeyStore;
export 'src/jose.dart'
    show base64UrlDecodeLoose, base64UrlNoPad, compactJws, jwkThumbprint;
export 'src/hardware_signer.dart' show HardwareKeypairSigner;
export 'src/role.dart' show KeyRole;
export 'src/signer.dart' show KeypairSigner;
export 'src/signers.dart'
    show KeypairFallback, KeypairSigners, KeypairUnavailable;
export 'src/software_signer.dart' show SoftwareKeypairSigner;
export 'src/web_crypto_signer.dart' show WebCryptoKeypairSigner;
