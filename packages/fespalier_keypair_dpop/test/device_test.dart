import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
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

  test(
    'Android, iOS and macOS get the hardware key, whatever the fallback says',
    () {
      for (final platform in native) {
        for (final fallback in DpopFallback.values) {
          final dpop = DpopProof.deviceFor(
            isWeb: false,
            platform: platform,
            fallback: fallback,
          );
          expect(dpop, isNotNull, reason: '$platform $fallback');
          expect(
            dpop!.signer,
            isA<HardwareKeypairSigner>(),
            reason: '$platform $fallback',
          );
        }
      }
    },
  );

  test(
    'the hardware key keeps the key id and requireHardware it was given',
    () {
      final dpop = DpopProof.deviceFor(
        isWeb: false,
        platform: TargetPlatform.iOS,
        keyId: 'shop_dpop',
        requireHardware: true,
      )!;
      final signer = dpop.signer as HardwareKeypairSigner;
      expect(signer.keyId, 'shop_dpop');
      expect(signer.requireHardware, isTrue);
      expect(dpop.rotateKeyOnSignOut, isTrue);
    },
  );

  test('the default key id is fespalier_dpop', () {
    expect(DpopProof.defaultKeyId, 'fespalier_dpop');
    final signer =
        DpopProof.deviceFor(
              isWeb: false,
              platform: TargetPlatform.android,
            )!.signer
            as HardwareKeypairSigner;
    expect(signer.keyId, 'fespalier_dpop');
  });

  group('refuse (the default)', () {
    test(
      'a web page with no browser key has no secure element, whatever it says it is',
      () {
        for (final platform in TargetPlatform.values) {
          expect(
            () => DpopProof.deviceFor(
              isWeb: true,
              platform: platform,
              webCryptoSupported: false,
            ),
            throwsA(
              isA<DpopUnavailable>().having(
                (e) => e.message,
                'message',
                startsWith(
                  'fespalier_keypair_dpop: the web has no secure element',
                ),
              ),
            ),
            reason: '$platform',
          );
        }
      },
    );

    test('Windows, Linux and Fuchsia name themselves', () {
      for (final entry in withoutSecureElement.entries) {
        expect(
          () => DpopProof.deviceFor(isWeb: false, platform: entry.key),
          throwsA(
            isA<DpopUnavailable>().having(
              (e) => e.message,
              'message',
              startsWith(
                'fespalier_keypair_dpop: ${entry.value} has no secure element',
              ),
            ),
          ),
          reason: '${entry.key}',
        );
      }
    });

    test('says what to do, in exactly these words', () {
      expect(
        DpopUnavailable('the web').toString(),
        'Unsupported operation: fespalier_keypair_dpop: the web has no secure element or '
        'browser key for a DPoP key. Pass fallback: DpopFallback.software for a software key '
        '(its scalar is in memory), or DpopFallback.bearer to send bearer tokens (the client '
        'must not require DPoP-bound tokens)',
      );
      expect(DpopUnavailable('Linux'), isA<UnsupportedError>());
    });

    test(
      'device() on this host (a test runs as Android) is the hardware key, made lazily',
      () {
        expect(DpopProof.device()!.signer, isA<HardwareKeypairSigner>());
      },
    );
  });

  group('the web with a browser key', () {
    DpopProof? onTheWeb({
      DpopFallback fallback = DpopFallback.refuse,
      bool requireHardware = false,
    }) => DpopProof.deviceFor(
      isWeb: true,
      platform: TargetPlatform.android,
      keyId: 'k',
      fallback: fallback,
      requireHardware: requireHardware,
      webCryptoSupported: true,
      webCryptoSigner: (id) => FakeKeypairSigner(keyId: id),
    );

    test(
      'uses the ambient browser key under the key id, whatever the fallback says',
      () {
        for (final fallback in DpopFallback.values) {
          final signer = onTheWeb(fallback: fallback)!.signer;
          expect(signer, isA<FakeKeypairSigner>(), reason: '$fallback');
          expect((signer as FakeKeypairSigner).keyId, 'k');
          expect(signer.role, KeyRole.ambient);
        }
      },
    );

    test('is not a secure element: requireHardware refuses it', () {
      expect(
        () => onTheWeb(requireHardware: true),
        throwsA(isA<DpopUnavailable>()),
      );
      expect(
        onTheWeb(fallback: DpopFallback.bearer, requireHardware: true),
        isNull,
      );
    });
  });

  group('software', () {
    test('gives a software key where there is no secure element', () {
      for (final isWeb in [true, false]) {
        for (final platform in withoutSecureElement.keys) {
          final dpop = DpopProof.deviceFor(
            isWeb: isWeb,
            platform: platform,
            fallback: DpopFallback.software,
            keyId: 'k',
            webCryptoSupported: false,
          );
          expect(
            dpop!.signer,
            isA<SoftwareKeypairSigner>(),
            reason: '$isWeb $platform',
          );
          expect((dpop.signer as SoftwareKeypairSigner).keyId, 'k');
        }
      }
    });

    test('requireHardware says no to a software key', () {
      expect(
        () => DpopProof.deviceFor(
          isWeb: true,
          platform: TargetPlatform.android,
          fallback: DpopFallback.software,
          requireHardware: true,
        ),
        throwsA(isA<DpopUnavailable>()),
      );
    });
  });

  group('bearer', () {
    test('is no DPoP at all: null', () {
      for (final isWeb in [true, false]) {
        for (final platform in withoutSecureElement.keys) {
          expect(
            DpopProof.deviceFor(
              isWeb: isWeb,
              platform: platform,
              fallback: DpopFallback.bearer,
              webCryptoSupported: false,
            ),
            isNull,
            reason: '$isWeb $platform',
          );
        }
      }
      expect(
        DpopProof.deviceFor(
          isWeb: true,
          platform: TargetPlatform.android,
          fallback: DpopFallback.bearer,
          requireHardware: true,
        ),
        isNull,
      );
    });
  });
}
