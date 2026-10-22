import 'package:fespalier/fespalier.dart' show Provider;
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// The name the device key lives under in the secure element.
const String deviceKeyId = 'frb_cose';

/// How the key that signs every call is held. `/core` says it, so a fallback to a software key is never silent.
enum DeviceKeyKind {
  /// No key at all: a build without a core (the web).
  none,

  /// A secure element holds it (the Secure Enclave, StrongBox or the TEE): the signer's `isHardwareBacked()` said so.
  hardware,

  /// The keystore's signer made a key that is **not** hardware-backed. Linux and Windows have no keystore, so
  /// flutter-sign-keypair gives them its own pure-Dart signer, with the key in memory; an iOS simulator's keychain
  /// opens, but it is not a secure element.
  software,

  /// The keystore **threw** (macOS without a signing certificate refuses the keychain; a phone's keystore may fail), so
  /// [openDeviceSigner] fell back to a `SoftwareDpopSigner`: the key is in memory and does not survive a restart.
  inMemory,
}

/// How the device key is held, for the `/core` page. `startup()` overrides it; a build without a core leaves it
/// [DeviceKeyKind.none].
final deviceKeyKind = Provider<DeviceKeyKind>((ref) => DeviceKeyKind.none);

/// Opens the signer of the device key, and says how the key is held.
///
/// The keystore comes first (`SignKeypairSigner`: the Secure Enclave or the AndroidKeyStore; on Linux and Windows its
/// own software signer). Where it throws, and [requireHardware] is false, a `SoftwareDpopSigner` takes over so the
/// example runs on every platform a person may try it on; the kind then says [DeviceKeyKind.inMemory] and a debug build
/// prints the error's class (never its text).
///
/// [requireHardware] true is the other policy: a device without a secure element fails, and so does this function, with
/// the keystore's own error (the splash screen shows it). Nothing falls back.
///
/// [keystore] replaces the keystore signer, for a test.
Future<({DpopSigner signer, DeviceKeyKind kind})> openDeviceSigner({
  bool requireHardware = false,
  DpopSigner Function()? keystore,
}) async {
  try {
    final signer =
        keystore?.call() ??
        SignKeypairSigner(keyId: deviceKeyId, requireHardware: requireHardware);
    await signer.publicJwk();
    final hardware = await signer.isHardwareBacked();
    return (
      signer: signer,
      kind: hardware ? DeviceKeyKind.hardware : DeviceKeyKind.software,
    );
  } on Object catch (error) {
    if (requireHardware) rethrow;
    if (kDebugMode) {
      debugPrint(
        'frb_cose: no keystore (${error.runtimeType}); the device key is a software key in memory.',
      );
    }
    return (
      signer: SoftwareDpopSigner(keyId: deviceKeyId),
      kind: DeviceKeyKind.inMemory,
    );
  }
}
