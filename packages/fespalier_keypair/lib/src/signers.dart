import 'package:flutter/foundation.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart'
    show SoftwareKeyStore;

import 'hardware_signer.dart';
import 'role.dart';
import 'signer.dart';
import 'software_signer.dart';
import 'web_crypto_signer.dart';

/// What `KeypairSigners.device` does where there is no secure element and the browser has no
/// key either: Windows, Linux, Fuchsia, and a web page that is not a secure context (since
/// 0.21.0).
enum KeypairFallback {
  /// Throw `KeypairUnavailable` (the default): a library that promises keys bound to a device
  /// must not quietly give you a key bound to nothing.
  refuse,

  /// A software key (`SoftwareKeypairSigner`): its scalar is in memory. Ambient only: a
  /// user-present key is never faked.
  software,
}

/// There is no key of this role on this platform, and `KeypairFallback.refuse` was asked for or
/// the fallback cannot give that role (since 0.21.0). Thrown by `KeypairSigners.device`, so from
/// startup, early and loud.
final class KeypairUnavailable extends UnsupportedError {
  /// The error for [platform] (`the web`, `Windows`, `Linux` or `Fuchsia`) and [role].
  KeypairUnavailable(this.platform, this.role)
    : super(switch (role) {
        KeyRole.ambient =>
          'fespalier_keypair: $platform has no secure element or browser key for a device '
              'key. Pass fallback: KeypairFallback.software for a software key (its scalar is '
              'in memory)',
        KeyRole.userPresent =>
          'fespalier_keypair: $platform has no user-present key. It needs a secure element '
              '(Android, iOS or macOS); a software key never claims to prompt',
      });

  /// The platform that has none.
  final String platform;

  /// The role that was asked for.
  final KeyRole role;
}

/// Picks the key for this device (since 0.21.0).
abstract final class KeypairSigners {
  /// This device's signer for the key [keyId] and [role]:
  ///
  /// - Android, iOS and macOS: `HardwareKeypairSigner`, in the secure element.
  /// - The web: `WebCryptoKeypairSigner`, a non-extractable `CryptoKey` kept in IndexedDB, for
  ///   [KeyRole.ambient] in a secure context. It is not a secure element, so [requireHardware]
  ///   refuses it.
  /// - Elsewhere, or where the browser has no key: what [fallback] says. `software` gives a
  ///   `SoftwareKeypairSigner` for [KeyRole.ambient] only; [KeyRole.userPresent] is always
  ///   refused.
  ///
  /// Throws a `KeypairUnavailable` for a combination that has no honest key.
  /// [requireHardware] makes a device whose secure element is missing (the iOS simulator has
  /// only the keychain) fail at its first use with a `SecureSignerException`; where there is no
  /// secure element at all it is `KeypairUnavailable`. [softwareStore] keeps the software key.
  static KeypairSigner device({
    required String keyId,
    KeyRole role = KeyRole.ambient,
    KeypairFallback fallback = KeypairFallback.refuse,
    bool requireHardware = false,
    SoftwareKeyStore? softwareStore,
  }) => deviceFor(
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    keyId: keyId,
    role: role,
    fallback: fallback,
    requireHardware: requireHardware,
    softwareStore: softwareStore,
  );

  /// [device] for the given platform, so a test can see each one, and a package that decides
  /// the platform itself (`DpopProof.deviceFor`) can too. [webCryptoSupported] says whether the
  /// browser has the key (null asks the browser); [webCryptoSigner] makes it (null is
  /// `WebCryptoKeypairSigner`, which off the web cannot be made).
  static KeypairSigner deviceFor({
    required bool isWeb,
    required TargetPlatform platform,
    required String keyId,
    KeyRole role = KeyRole.ambient,
    KeypairFallback fallback = KeypairFallback.refuse,
    bool requireHardware = false,
    SoftwareKeyStore? softwareStore,
    bool? webCryptoSupported,
    KeypairSigner Function(String keyId)? webCryptoSigner,
  }) {
    final native =
        !isWeb &&
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS ||
            platform == TargetPlatform.macOS);
    if (native) {
      return HardwareKeypairSigner(
        keyId: keyId,
        role: role,
        requireHardware: requireHardware,
      );
    }
    if (isWeb &&
        role == KeyRole.ambient &&
        !requireHardware &&
        (webCryptoSupported ?? WebCryptoKeypairSigner.isSupported)) {
      return webCryptoSigner?.call(keyId) ??
          WebCryptoKeypairSigner(keyId: keyId);
    }
    if (fallback == KeypairFallback.software &&
        role == KeyRole.ambient &&
        !requireHardware) {
      return SoftwareKeypairSigner(keyId: keyId, store: softwareStore);
    }
    throw KeypairUnavailable(
      isWeb
          ? 'the web'
          : switch (platform) {
              TargetPlatform.windows => 'Windows',
              TargetPlatform.linux => 'Linux',
              TargetPlatform.fuchsia => 'Fuchsia',
              _ => platform.name,
            },
      role,
    );
  }
}
