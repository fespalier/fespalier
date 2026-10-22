import 'dart:typed_data';

import 'role.dart';

/// A P-256 key that signs (since 0.21.0): the seam between a protocol (DPoP, a device-signed
/// request) and wherever the key lives.
///
/// An app implements it to put the key somewhere else (a key held by a server-side HSM, for one).
/// The ones in this package are `HardwareKeypairSigner`, `WebCryptoKeypairSigner` and
/// `SoftwareKeypairSigner`; `KeypairSigners.device` picks one for the platform.
abstract interface class KeypairSigner {
  /// Which key this is: [KeyRole.userPresent] prompts on every [sign].
  KeyRole get role;

  /// The public key as a JWK: `{crv: P-256, kty: EC, x, y}`. Makes the key on first use.
  Future<Map<String, String>> publicJwk();

  /// A 64-byte IEEE P1363 `r||s` ES256 signature of [signingInput] (the signer hashes it with
  /// SHA-256). A [KeyRole.userPresent] key shows the platform's prompt, captioned with [reason]
  /// where the platform has a caption; an ambient key ignores it.
  Future<Uint8List> sign(Uint8List signingInput, {String? reason});

  /// Whether the key is held by a secure element (StrongBox, TEE or Secure Enclave).
  Future<bool> isHardwareBacked();

  /// Whether the key exists, without making it.
  Future<bool> exists();

  /// Deletes the key; the next [publicJwk] makes a new one.
  Future<void> deleteKey();
}
