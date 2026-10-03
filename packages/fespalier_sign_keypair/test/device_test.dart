import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
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
            isA<SignKeypairSigner>(),
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
      final signer = dpop.signer as SignKeypairSigner;
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
            as SignKeypairSigner;
    expect(signer.keyId, 'fespalier_dpop');
  });

  group('refuse (the default)', () {
    test('the web has no secure element, whatever the browser says it is', () {
      for (final platform in TargetPlatform.values) {
        expect(
          () => DpopProof.deviceFor(isWeb: true, platform: platform),
          throwsA(
            isA<DpopUnavailable>().having(
              (e) => e.message,
              'message',
              startsWith(
                'fespalier_sign_keypair: the web has no secure element',
              ),
            ),
          ),
          reason: '$platform',
        );
      }
    });

    test('Windows, Linux and Fuchsia name themselves', () {
      for (final entry in withoutSecureElement.entries) {
        expect(
          () => DpopProof.deviceFor(isWeb: false, platform: entry.key),
          throwsA(
            isA<DpopUnavailable>().having(
              (e) => e.message,
              'message',
              startsWith(
                'fespalier_sign_keypair: ${entry.value} has no secure element',
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
        'Unsupported operation: fespalier_sign_keypair: the web has no secure element for a '
        'DPoP key. Pass fallback: DpopFallback.software for a software key (on the web it does '
        'not survive a reload), or DpopFallback.bearer to send bearer tokens (the client must '
        'not require DPoP-bound tokens)',
      );
      expect(DpopUnavailable('Linux'), isA<UnsupportedError>());
    });

    test(
      'device() on this host (a test runs as Android) is the hardware key, made lazily',
      () {
        expect(DpopProof.device()!.signer, isA<SignKeypairSigner>());
      },
    );
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
          );
          expect(
            dpop!.signer,
            isA<SoftwareDpopSigner>(),
            reason: '$isWeb $platform',
          );
          expect((dpop.signer as SoftwareDpopSigner).keyId, 'k');
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
