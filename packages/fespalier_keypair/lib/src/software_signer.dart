import 'dart:typed_data';

import 'package:flutter_sign_keypair/flutter_sign_keypair.dart';

import 'key_holder.dart';
import 'role.dart';
import 'signer.dart';

/// flutter-sign-keypair's pure-Dart signer as an ambient key (since 0.21.0; it was
/// `SoftwareDpopSigner`): the private scalar is in memory, so it is not bound to a device in any
/// way a thief of the process could not copy. It is for Windows and Linux (`KeypairFallback.software`)
/// and for tests; the web has `WebCryptoKeypairSigner`, whose key cannot be read at all.
///
/// It is always [KeyRole.ambient]: with no secure element there is nothing to withhold a
/// signature until a human is there, so a software key never claims to be a user-present one.
///
/// Without a [store] the key lives as long as the signer. A `SoftwareKeyStore` of your own
/// (`flutter_secure_storage`, an encrypted file) keeps the key, and its safety is the store's.
final class SoftwareKeypairSigner implements KeypairSigner {
  /// A signer for the key [keyId], kept in [store] (in memory when null).
  SoftwareKeypairSigner({
    required this.keyId,
    SoftwareKeyStore? store,
    SoftwareSecureSigner? signer,
  }) : _signer = signer ?? SoftwareSecureSigner(store: store) {
    _holder = KeyHolder(
      KeyStore(
        get: _signer.getKey,
        generate: (id) => _signer.generateKey(
          keyId: id,
          requireHardware: false,
          overwrite: false,
          protection: KeyProtection.ambient,
        ),
        sign: (id, input, reason) => _signer.sign(keyId: id, payload: input),
        delete: _signer.deleteKey,
      ),
      keyId,
    );
  }

  /// The key id.
  final String keyId;

  final SoftwareSecureSigner _signer;
  late final KeyHolder _holder;

  @override
  KeyRole get role => KeyRole.ambient;

  @override
  Future<Map<String, String>> publicJwk() => _holder.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) =>
      _holder.sign(signingInput);

  @override
  Future<bool> isHardwareBacked() async => false;

  @override
  Future<bool> exists() => _holder.exists();

  @override
  Future<void> deleteKey() => _holder.deleteKey();
}
