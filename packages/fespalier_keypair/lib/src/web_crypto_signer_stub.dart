import 'dart:typed_data';

import 'role.dart';
import 'signer.dart';

/// The browser's key, as `WebCryptoKeypairSigner` is on the web (since 0.21.0). This is the
/// build for every other platform: [isSupported] is false and the constructor throws an
/// [UnsupportedError].
///
/// The web implementation is UNCHECKED IN CI (see `web_crypto_signer_web.dart`).
final class WebCryptoKeypairSigner implements KeypairSigner {
  /// Always throws: there is no browser here.
  WebCryptoKeypairSigner({
    required this.keyId,
    KeyRole role = KeyRole.ambient,
  }) {
    throw UnsupportedError(
      'fespalier_keypair: WebCryptoKeypairSigner works in a browser only; '
      'use KeypairSigners.device, which picks a key for the platform',
    );
  }

  /// Whether this browser can hold the key: a secure context with `crypto.subtle` and
  /// IndexedDB. False off the web.
  static bool get isSupported => false;

  /// The key id.
  final String keyId;

  @override
  KeyRole get role => KeyRole.ambient;

  @override
  Future<Map<String, String>> publicJwk() => throw UnimplementedError();

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) =>
      throw UnimplementedError();

  @override
  Future<bool> isHardwareBacked() => throw UnimplementedError();

  @override
  Future<bool> exists() => throw UnimplementedError();

  @override
  Future<void> deleteKey() => throw UnimplementedError();
}
