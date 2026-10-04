import 'dart:typed_data';

import 'package:flutter_sign_keypair/flutter_sign_keypair.dart';

/// The key id the DPoP key lives under, in the secure element or the software store.
const String defaultDpopKeyId = 'fespalier_dpop';

/// Signs DPoP proofs with an ES256 (P-256) key (since 0.9.0).
///
/// `DpopProof` makes proofs with it. An app implements it to put the key somewhere else (a key
/// held by a server-side HSM, for one); the two in this package are [SignKeypairSigner] and
/// [SoftwareDpopSigner].
abstract interface class DpopSigner {
  /// The public key as a JWK: `{crv: P-256, kty: EC, x, y}`. Makes the key on first use.
  Future<Map<String, String>> publicJwk();

  /// A 64-byte IEEE P1363 `r||s` ES256 signature of [signingInput] (the signer hashes it with
  /// SHA-256).
  Future<Uint8List> sign(Uint8List signingInput);

  /// Whether the key is held by a secure element (StrongBox, TEE or Secure Enclave).
  Future<bool> isHardwareBacked();

  /// Deletes the key; the next [publicJwk] makes a new one.
  Future<void> deleteKey();
}

/// The four operations a key store gives: flutter_sign_keypair's facade and its software signer
/// both have them.
final class _Keys {
  const _Keys({
    required this.get,
    required this.generate,
    required this.sign,
    required this.delete,
  });

  final Future<SecureKey?> Function(String keyId) get;
  final Future<SecureKey> Function(String keyId, bool requireHardware) generate;
  final Future<Uint8List> Function(String keyId, Uint8List input) sign;
  final Future<void> Function(String keyId) delete;
}

/// What the two signers share: the key is made once, on first use, and two callers that arrive
/// together wait for the same creation.
final class _KeyHolder {
  _KeyHolder(this._keys, this.keyId, this.requireHardware);

  final _Keys _keys;
  final String keyId;
  final bool requireHardware;

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
    final existing = await _keys.get(keyId);
    if (existing != null) return existing;
    try {
      return await _keys.generate(keyId, requireHardware);
    } on SecureSignerException catch (e) {
      // Another isolate (or a restart in between) made it first: use that one.
      if (e.code == SignerErrorCode.keyAlreadyExists) {
        final again = await _keys.get(keyId);
        if (again != null) return again;
      }
      rethrow;
    }
  }

  Future<Map<String, String>> publicJwk() async {
    final json = (await key()).publicKey.toJson();
    return <String, String>{
      for (final e in json.entries) e.key: e.value as String,
    };
  }

  Future<Uint8List> sign(Uint8List input) async {
    await key();
    return _keys.sign(keyId, input);
  }

  Future<bool> isHardwareBacked() async => (await key()).isHardwareBacked;

  Future<void> deleteKey() async {
    _key = null;
    await _keys.delete(keyId);
  }
}

/// The hardware key of flutter-sign-keypair (since 0.9.0): StrongBox or the TEE on Android, the
/// Secure Enclave on iOS and macOS. It is an *ambient* key (`KeyProtection.ambient`): it never
/// prompts, because a proof is made for every request and a refresh runs with no screen to show
/// a prompt on.
///
/// The key is made on first use, under [keyId], and found again at the next start.
/// [requireHardware] makes a device that has no secure element fail with a
/// `SecureSignerException` (`hardwareUnavailable`) instead of getting a software key; the iOS
/// simulator, whose keychain is not a secure element, is such a device.
final class SignKeypairSigner implements DpopSigner {
  /// A signer for the key [keyId]. [signKeypair] is for a test (give it a `SignKeypair` made
  /// with a fake platform); the default is the one for this device, made on first use.
  SignKeypairSigner({
    this.keyId = defaultDpopKeyId,
    this.requireHardware = false,
    SignKeypair? signKeypair,
  }) : _given = signKeypair {
    _holder = _KeyHolder(
      _Keys(
        get: (id) => _facade.getKey(keyId: id),
        generate: (id, hardware) =>
            _facade.generateKey(keyId: id, requireHardware: hardware),
        sign: (id, input) => _facade.signRaw(signingInput: input, keyId: id),
        delete: (id) => _facade.deleteKey(keyId: id),
      ),
      keyId,
      requireHardware,
    );
  }

  /// The key id.
  final String keyId;

  /// Whether a device without a secure element fails instead of getting a software key.
  final bool requireHardware;

  final SignKeypair? _given;
  SignKeypair? _made;
  late final _KeyHolder _holder;

  SignKeypair get _facade => _given ?? (_made ??= SignKeypair());

  @override
  Future<Map<String, String>> publicJwk() => _holder.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput) => _holder.sign(signingInput);

  @override
  Future<bool> isHardwareBacked() => _holder.isHardwareBacked();

  @override
  Future<void> deleteKey() => _holder.deleteKey();
}

/// flutter-sign-keypair's pure-Dart signer as a DPoP key (since 0.9.0): the private scalar is
/// in memory, so it is not bound to a device in any way a thief of the process could not copy.
/// It is for the web, Windows and Linux (`DpopFallback.software`), and for tests.
///
/// Without a [store] the key lives as long as the signer: a web page that reloads makes a new
/// key and its session is signed out (the refresh token is bound to the old one). A
/// `SoftwareKeyStore` of your own (`flutter_secure_storage`, an encrypted file) keeps the key,
/// and its safety is the store's.
final class SoftwareDpopSigner implements DpopSigner {
  /// A signer for the key [keyId], kept in [store] (in memory when null).
  SoftwareDpopSigner({
    this.keyId = defaultDpopKeyId,
    SoftwareKeyStore? store,
    SoftwareSecureSigner? signer,
  }) : _signer = signer ?? SoftwareSecureSigner(store: store) {
    _holder = _KeyHolder(
      _Keys(
        get: _signer.getKey,
        generate: (id, hardware) => _signer.generateKey(
          keyId: id,
          requireHardware: hardware,
          overwrite: false,
          protection: KeyProtection.ambient,
        ),
        sign: (id, input) => _signer.sign(keyId: id, payload: input),
        delete: _signer.deleteKey,
      ),
      keyId,
      false,
    );
  }

  /// The key id.
  final String keyId;

  final SoftwareSecureSigner _signer;
  late final _KeyHolder _holder;

  @override
  Future<Map<String, String>> publicJwk() => _holder.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput) => _holder.sign(signingInput);

  @override
  Future<bool> isHardwareBacked() async => false;

  @override
  Future<void> deleteKey() => _holder.deleteKey();
}
