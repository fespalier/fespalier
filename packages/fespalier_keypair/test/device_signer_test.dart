import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const native = [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ];
  const withoutSecureElement = {
    TargetPlatform.windows: 'Windows',
    TargetPlatform.linux: 'Linux',
    TargetPlatform.fuchsia: 'Fuchsia',
  };

  KeypairSigner pick({
    bool isWeb = false,
    TargetPlatform platform = TargetPlatform.android,
    KeyRole role = KeyRole.ambient,
    KeypairFallback fallback = KeypairFallback.refuse,
    bool requireHardware = false,
    bool webCryptoSupported = true,
  }) => KeypairSigners.deviceFor(
    isWeb: isWeb,
    platform: platform,
    keyId: 'shop_device',
    role: role,
    fallback: fallback,
    requireHardware: requireHardware,
    webCryptoSupported: webCryptoSupported,
    webCryptoSigner: (id) => FakeKeypairSigner(keyId: id),
  );

  group('Android, iOS and macOS', () {
    test(
      'get the hardware key of the role asked for, whatever the fallback says',
      () {
        for (final platform in native) {
          for (final role in KeyRole.values) {
            for (final fallback in KeypairFallback.values) {
              final signer = pick(
                platform: platform,
                role: role,
                fallback: fallback,
              );
              expect(
                signer,
                isA<HardwareKeypairSigner>(),
                reason: '$platform $role $fallback',
              );
              expect(signer.role, role);
            }
          }
        }
      },
    );

    test('keep the key id and requireHardware they were given', () {
      final signer =
          pick(platform: TargetPlatform.iOS, requireHardware: true)
              as HardwareKeypairSigner;
      expect(signer.keyId, 'shop_device');
      expect(signer.requireHardware, isTrue);
    });

    test(
      'are never native on a web build, whatever platform the browser reports',
      () {
        expect(
          pick(isWeb: true, platform: TargetPlatform.android),
          isNot(isA<HardwareKeypairSigner>()),
        );
      },
    );
  });

  group('the web', () {
    test(
      'gets the browser key for the ambient role, whatever the browser says it is',
      () {
        for (final platform in TargetPlatform.values) {
          final signer = pick(isWeb: true, platform: platform);
          expect(signer, isA<FakeKeypairSigner>(), reason: '$platform');
          expect((signer as FakeKeypairSigner).keyId, 'shop_device');
        }
      },
    );

    test(
      'refuses a user-present key: a browser cannot prompt for a CryptoKey',
      () {
        for (final fallback in KeypairFallback.values) {
          expect(
            () => pick(
              isWeb: true,
              role: KeyRole.userPresent,
              fallback: fallback,
            ),
            throwsA(
              isA<KeypairUnavailable>()
                  .having((e) => e.role, 'role', KeyRole.userPresent)
                  .having(
                    (e) => e.message,
                    'message',
                    startsWith(
                      'fespalier_keypair: the web has no user-present key',
                    ),
                  ),
            ),
            reason: '$fallback',
          );
        }
      },
    );

    test(
      'refuses requireHardware: the browser key is not a secure element',
      () {
        expect(
          () => pick(isWeb: true, requireHardware: true),
          throwsA(isA<KeypairUnavailable>()),
        );
      },
    );

    test('without a browser key, the fallback decides', () {
      expect(
        () => pick(isWeb: true, webCryptoSupported: false),
        throwsA(
          isA<KeypairUnavailable>().having(
            (e) => e.message,
            'message',
            startsWith(
              'fespalier_keypair: the web has no secure element or browser key',
            ),
          ),
        ),
      );
      expect(
        pick(
          isWeb: true,
          webCryptoSupported: false,
          fallback: KeypairFallback.software,
        ),
        isA<SoftwareKeypairSigner>(),
      );
    });
  });

  group('Windows, Linux and Fuchsia', () {
    test('refuse by default, naming the platform', () {
      for (final entry in withoutSecureElement.entries) {
        expect(
          () => pick(platform: entry.key),
          throwsA(
            isA<KeypairUnavailable>()
                .having((e) => e.platform, 'platform', entry.value)
                .having(
                  (e) => e.message,
                  'message',
                  startsWith(
                    'fespalier_keypair: ${entry.value} has no secure element',
                  ),
                ),
          ),
          reason: '${entry.key}',
        );
      }
    });

    test('are an UnsupportedError, which says the fix', () {
      expect(
        () => pick(platform: TargetPlatform.linux),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('fallback: KeypairFallback.software'),
          ),
        ),
      );
    });

    test(
      'get a software key for the ambient role when the fallback says so',
      () {
        for (final platform in withoutSecureElement.keys) {
          final signer = pick(
            platform: platform,
            fallback: KeypairFallback.software,
          );
          expect(signer, isA<SoftwareKeypairSigner>(), reason: '$platform');
          expect(signer.role, KeyRole.ambient);
        }
      },
    );

    test('never get a software key that claims to prompt', () {
      for (final platform in withoutSecureElement.keys) {
        expect(
          () => pick(
            platform: platform,
            role: KeyRole.userPresent,
            fallback: KeypairFallback.software,
          ),
          throwsA(isA<KeypairUnavailable>()),
          reason: '$platform',
        );
      }
    });

    test('refuse a software key when hardware is required', () {
      expect(
        () => pick(
          platform: TargetPlatform.windows,
          fallback: KeypairFallback.software,
          requireHardware: true,
        ),
        throwsA(isA<KeypairUnavailable>()),
      );
    });
  });

  test(
    'device() on a test host (no secure element, not the web) refuses by default',
    () {
      // flutter test runs on the host OS: whichever it is, the answer is a key or the refusal,
      // never a silent software key.
      try {
        final signer = KeypairSigners.device(keyId: 'k');
        expect(signer, isA<HardwareKeypairSigner>());
      } on KeypairUnavailable catch (e) {
        expect(e.role, KeyRole.ambient);
      }
    },
  );
}
