import 'package:fespalier_keypair/fespalier_keypair.dart';

/// The keys a device holds (since 0.21.0): an ambient key that signs every request, and, where
/// the platform has a secure element to unlock it with, a user-present key for the calls worth a
/// prompt. The web has the ambient key only.
final class DeviceKeys {
  /// Keys with the given signers. [ambient] must be a [KeyRole.ambient] signer and [userPresent]
  /// a [KeyRole.userPresent] one (or null: the device has none).
  DeviceKeys({required this.ambient, this.userPresent}) {
    if (ambient.role != KeyRole.ambient) {
      throw ArgumentError.value(
        ambient.role,
        'ambient',
        'the ambient signer must have the role KeyRole.ambient',
      );
    }
    if (userPresent != null && userPresent!.role != KeyRole.userPresent) {
      throw ArgumentError.value(
        userPresent!.role,
        'userPresent',
        'the user-present signer must have the role KeyRole.userPresent',
      );
    }
  }

  /// This device's keys: [KeypairSigners.device] for each role, under the key ids
  /// `<keyId>.ambient` and `<keyId>.user_present`. A platform that has no user-present key
  /// (the web, Windows, Linux: `KeypairUnavailable`) gets none, and enrols with the ambient key
  /// only; the ambient key is refused with `KeypairUnavailable` where [fallback] says so, early
  /// and loud. A user-present key that exists but cannot be made (no screen lock) throws at
  /// enrolment instead: the device cannot hold the key the app asked for.
  factory DeviceKeys.device({
    String keyId = 'fespalier_device',
    KeypairFallback fallback = KeypairFallback.refuse,
    bool userPresent = true,
  }) {
    KeypairSigner? presence;
    if (userPresent) {
      try {
        presence = KeypairSigners.device(
          keyId: '$keyId.user_present',
          role: KeyRole.userPresent,
        );
      } on KeypairUnavailable {
        presence = null;
      }
    }
    return DeviceKeys(
      ambient: KeypairSigners.device(
        keyId: '$keyId.ambient',
        role: KeyRole.ambient,
        fallback: fallback,
      ),
      userPresent: presence,
    );
  }

  /// The key that never prompts.
  final KeypairSigner ambient;

  /// The key that prompts on every signature; null where the device has none.
  final KeypairSigner? userPresent;

  /// The signer of [role], or null when the device has none.
  KeypairSigner? operator [](KeyRole role) => switch (role) {
    KeyRole.ambient => ambient,
    KeyRole.userPresent => userPresent,
  };

  /// The roles the device holds a key for.
  List<KeyRole> get roles => [
    KeyRole.ambient,
    if (userPresent != null) KeyRole.userPresent,
  ];
}
