import 'dart:typed_data';

import 'package:flutter_sign_keypair/flutter_sign_keypair.dart';

/// The operations a key store gives: flutter_sign_keypair's facade and its software signer both
/// have them.
final class KeyStore {
  /// A store over four functions.
  const KeyStore({
    required this.get,
    required this.generate,
    required this.sign,
    required this.delete,
  });

  /// The key under an id, or null.
  final Future<SecureKey?> Function(String keyId) get;

  /// Makes the key under an id.
  final Future<SecureKey> Function(String keyId) generate;

  /// Signs with the key under an id.
  final Future<Uint8List> Function(
    String keyId,
    Uint8List input,
    String? reason,
  )
  sign;

  /// Deletes the key under an id.
  final Future<void> Function(String keyId) delete;
}

/// What the signers over flutter_sign_keypair share: the key is made once, on first use, and two
/// callers that arrive together wait for the same creation.
final class KeyHolder {
  /// A holder of the key [keyId] in [_store].
  KeyHolder(this._store, this.keyId);

  final KeyStore _store;

  /// The key id.
  final String keyId;

  Future<SecureKey>? _key;

  /// The key, made when there is none. A failure is not remembered: the next call tries again.
  Future<SecureKey> key() {
    final known = _key;
    if (known != null) return known;
    final made = _make();
    _key = made;
    made.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_key, made)) _key = null;
      },
    );
    return made;
  }

  Future<SecureKey> _make() async {
    final existing = await _store.get(keyId);
    if (existing != null) return existing;
    try {
      return await _store.generate(keyId);
    } on SecureSignerException catch (e) {
      // Another isolate (or a restart in between) made it first: use that one.
      if (e.code == SignerErrorCode.keyAlreadyExists) {
        final again = await _store.get(keyId);
        if (again != null) return again;
      }
      rethrow;
    }
  }

  /// The public key as a JWK.
  Future<Map<String, String>> publicJwk() async {
    final json = (await key()).publicKey.toJson();
    return <String, String>{
      for (final e in json.entries) e.key: e.value as String,
    };
  }

  /// A signature over [input].
  Future<Uint8List> sign(Uint8List input, {String? reason}) async {
    await key();
    return _store.sign(keyId, input, reason);
  }

  /// Whether the key is in a secure element.
  Future<bool> isHardwareBacked() async => (await key()).isHardwareBacked;

  /// Whether the key exists, without making it.
  Future<bool> exists() async => await _store.get(keyId) != null;

  /// Deletes the key.
  Future<void> deleteKey() async {
    _key = null;
    await _store.delete(keyId);
  }
}
