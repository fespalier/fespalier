/// Fakes for tests of an app or a protocol built on `fespalier_keypair` (since 0.21.0): a
/// software key that needs no platform, no secure element and no browser.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart'
    show SecureSignerException, SignerErrorCode, SoftwareSecureSigner;

import 'src/role.dart';
import 'src/signer.dart';

/// A software P-256 key from a fixed scalar (since 0.21.0; it was `FakeDpopSigner`): the same
/// key, and with RFC 6979 the same signature, for the same input, on every run and every
/// platform.
///
/// The scalar is `sha256(seed)` (derived when the signer is made, so no key is written in the
/// repository). [deleteKey] and [loseKey] move to the next key (`sha256('$seed#1')`, then `#2`),
/// so a test can see a key change.
///
/// It can also play the two failures a real key has: [refuseNextPrompt] (the user cancels the
/// biometric prompt of a [KeyRole.userPresent] key) and [loseKey] (the key is gone behind the
/// app's back: the keystore was wiped, the biometrics changed, the site data was cleared).
final class FakeKeypairSigner implements KeypairSigner {
  /// A signer of [role] whose first key comes from [seed]. [hardware] is what [isHardwareBacked]
  /// says.
  ///
  /// The default seed is a historical one (it names `fespalier_sign_keypair`, where this key
  /// was born): the golden thumbprints and proofs in the tests of the packages built on this
  /// one were made with it, with Python, and a new seed would remake every one of them.
  FakeKeypairSigner({
    this.role = KeyRole.ambient,
    this.keyId = 'fake',
    this.seed = 'fespalier_sign_keypair fake key',
    this.hardware = false,
  });

  @override
  final KeyRole role;

  /// The key id the fake key is kept under.
  final String keyId;

  /// The text the keys are derived from.
  final String seed;

  /// What [isHardwareBacked] answers.
  final bool hardware;

  /// How many signatures were made.
  int signatures = 0;

  /// How many times [deleteKey] was called.
  int deletes = 0;

  /// How many prompts a [KeyRole.userPresent] key showed (each [sign] shows one), refused or not.
  int prompts = 0;

  /// The `reason` of the last [sign].
  String? lastReason;

  /// How many keys were made so far: the index of the current key.
  int _generation = 0;

  /// Whether the key exists now: false after [deleteKey] or [loseKey] until the next use.
  bool _present = false;

  bool _refuseNext = false;
  bool _refuseAll = false;

  SoftwareSecureSigner _signer = SoftwareSecureSigner();

  /// Makes the next [sign] of a [KeyRole.userPresent] key throw the `SecureSignerException`
  /// (`userAuthenticationCancelled`) that a cancelled prompt throws, once. With [always], every
  /// one until [allowPrompts].
  void refuseNextPrompt({bool always = false}) {
    _refuseNext = true;
    _refuseAll = always;
  }

  /// Stops refusing prompts.
  void allowPrompts() {
    _refuseNext = false;
    _refuseAll = false;
  }

  /// Loses the key behind the app's back: [exists] is false, and the next use makes a new key
  /// (the next one of the seed), as a keystore that was wiped does. Unlike [deleteKey] it is
  /// not counted in [deletes], because the app did not ask for it.
  Future<void> loseKey() async {
    _present = false;
    _signer = SoftwareSecureSigner();
    _generation++;
  }

  Future<void> _ensure() async {
    if (_present) return;
    _present = true;
    final material = _generation == 0 ? seed : '$seed#$_generation';
    await _signer.importKey(
      keyId: keyId,
      privateScalar: Uint8List.fromList(
        sha256.convert(utf8.encode(material)).bytes,
      ),
      overwrite: true,
    );
  }

  @override
  Future<Map<String, String>> publicJwk() async {
    await _ensure();
    final key = await _signer.getKey(keyId);
    return <String, String>{
      for (final e in key!.publicKey.toJson().entries) e.key: e.value as String,
    };
  }

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) async {
    if (role == KeyRole.userPresent) {
      prompts++;
      if (_refuseNext) {
        _refuseNext = _refuseAll;
        throw SecureSignerException(
          SignerErrorCode.userAuthenticationCancelled,
          'the user cancelled the prompt',
        );
      }
    }
    await _ensure();
    signatures++;
    lastReason = reason;
    return _signer.sign(keyId: keyId, payload: signingInput);
  }

  @override
  Future<bool> isHardwareBacked() async => hardware;

  @override
  Future<bool> exists() async => _present;

  @override
  Future<void> deleteKey() async {
    deletes++;
    _present = false;
    _signer = SoftwareSecureSigner();
    _generation++;
  }
}
