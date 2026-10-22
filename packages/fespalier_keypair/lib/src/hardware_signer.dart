import 'dart:typed_data';

import 'package:flutter_sign_keypair/flutter_sign_keypair.dart';

import 'key_holder.dart';
import 'role.dart';
import 'signer.dart';

/// The hardware key of flutter-sign-keypair (since 0.21.0; it was `SignKeypairSigner`):
/// StrongBox or the TEE on Android, the Secure Enclave on iOS and macOS.
///
/// [KeyRole.ambient] is `KeyProtection.ambient`: it never prompts, so a proof or a signature can
/// be made for every request and a renewal can run with no screen to show a prompt on.
/// [KeyRole.userPresent] is `KeyProtection.userPresent`: every [sign] shows the platform's
/// biometric or device-credential prompt, and is refused (a `SecureSignerException`) if the user
/// cancels it. The two roles are two keys, so they need two different [keyId]s.
///
/// The key is made on first use, under [keyId], and found again at the next start.
/// [requireHardware] makes a device that has no secure element fail with a
/// `SecureSignerException` (`hardwareUnavailable`) instead of getting a software key; the iOS
/// simulator, whose keychain is not a secure element, is such a device.
final class HardwareKeypairSigner implements KeypairSigner {
  /// A signer for the key [keyId]. [signKeypair] is for a test (give it a `SignKeypair` made
  /// with a fake platform); the default is the one for this device, made on first use.
  HardwareKeypairSigner({
    required this.keyId,
    this.role = KeyRole.ambient,
    this.requireHardware = false,
    SignKeypair? signKeypair,
  }) : _given = signKeypair {
    _holder = KeyHolder(
      KeyStore(
        get: (id) => _facade.getKey(keyId: id),
        generate: (id) => _facade.generateKey(
          keyId: id,
          requireHardware: requireHardware,
          protection: switch (role) {
            KeyRole.ambient => KeyProtection.ambient,
            KeyRole.userPresent => KeyProtection.userPresent,
          },
        ),
        sign: (id, input, reason) =>
            _facade.signRaw(signingInput: input, keyId: id, reason: reason),
        delete: (id) => _facade.deleteKey(keyId: id),
      ),
      keyId,
    );
  }

  /// The key id.
  final String keyId;

  @override
  final KeyRole role;

  /// Whether a device without a secure element fails instead of getting a software key.
  final bool requireHardware;

  final SignKeypair? _given;
  SignKeypair? _made;
  late final KeyHolder _holder;

  SignKeypair get _facade => _given ?? (_made ??= SignKeypair());

  @override
  Future<Map<String, String>> publicJwk() => _holder.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) =>
      _holder.sign(signingInput, reason: reason);

  @override
  Future<bool> isHardwareBacked() => _holder.isHardwareBacked();

  @override
  Future<bool> exists() => _holder.exists();

  @override
  Future<void> deleteKey() => _holder.deleteKey();
}
