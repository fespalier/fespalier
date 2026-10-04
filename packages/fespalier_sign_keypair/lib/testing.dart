/// Fakes for tests of an app that signs in with DPoP (since 0.9.0): a software key that needs
/// no platform, and `verifyDpopProof`, which a fake server checks proofs with.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart'
    show SoftwareSecureSigner;

import 'src/signer.dart';

export 'verify.dart';

/// A software P-256 key from a fixed scalar (since 0.9.0): the same key, and with RFC 6979 the
/// same signature, for the same input, on every run and every platform.
///
/// The scalar is `sha256(seed)` (derived when the signer is made, so no key is written in the
/// repository). [deleteKey] moves to the next key (`sha256('$seed#1')`, then `#2`), so a test can
/// see a key change at sign-out.
final class FakeDpopSigner implements DpopSigner {
  /// A signer whose first key comes from [seed]. [hardware] is what [isHardwareBacked] says.
  FakeDpopSigner({
    this.seed = 'fespalier_sign_keypair fake key',
    this.hardware = false,
  });

  /// The text the keys are derived from.
  final String seed;

  /// What [isHardwareBacked] answers.
  final bool hardware;

  /// How many signatures were made.
  int signatures = 0;

  /// How many times [deleteKey] was called.
  int deletes = 0;

  final SoftwareSecureSigner _signer = SoftwareSecureSigner();
  bool _imported = false;

  Future<void> _ensure() async {
    if (_imported) return;
    _imported = true;
    final material = deletes == 0 ? seed : '$seed#$deletes';
    await _signer.importKey(
      keyId: defaultDpopKeyId,
      privateScalar: Uint8List.fromList(
        sha256.convert(utf8.encode(material)).bytes,
      ),
      overwrite: true,
    );
  }

  @override
  Future<Map<String, String>> publicJwk() async {
    await _ensure();
    final key = await _signer.getKey(defaultDpopKeyId);
    return <String, String>{
      for (final e in key!.publicKey.toJson().entries) e.key: e.value as String,
    };
  }

  @override
  Future<Uint8List> sign(Uint8List signingInput) async {
    await _ensure();
    signatures++;
    return _signer.sign(keyId: defaultDpopKeyId, payload: signingInput);
  }

  @override
  Future<bool> isHardwareBacked() async => hardware;

  @override
  Future<void> deleteKey() async {
    deletes++;
    _imported = false;
    await _signer.deleteKey(defaultDpopKeyId);
  }
}
