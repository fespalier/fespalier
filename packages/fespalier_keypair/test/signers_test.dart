import 'dart:typed_data';

import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A platform that records what it was asked, over the package's own software signer. The
/// `SignKeypair` facade installs it as the global instance, so every test makes its own.
final class _Spy extends SoftwareSecureSigner {
  _Spy({this.backing = KeyBacking.software});

  final KeyBacking backing;
  final List<String> calls = [];
  final List<String?> reasons = [];
  final List<({String keyId, bool requireHardware, KeyProtection protection})>
  generated = [];

  /// Makes the first getKey of a key that another isolate is about to make.
  bool raceOnce = false;

  SecureKey _as(SecureKey key) =>
      SecureKey(keyId: key.keyId, publicKey: key.publicKey, backing: backing);

  @override
  Future<SecureKey?> getKey(String keyId) async {
    calls.add('get $keyId');
    if (raceOnce) return null;
    final key = await super.getKey(keyId);
    return key == null ? null : _as(key);
  }

  @override
  Future<SecureKey> generateKey({
    required String keyId,
    required bool requireHardware,
    required bool overwrite,
    required KeyProtection protection,
  }) async {
    calls.add('generate $keyId');
    generated.add((
      keyId: keyId,
      requireHardware: requireHardware,
      protection: protection,
    ));
    // A "secure element" is the software store reporting a hardware backing.
    if (requireHardware && !backing.isHardwareBacked) {
      throw SecureSignerException(
        SignerErrorCode.hardwareUnavailable,
        'no secure element here',
      );
    }
    if (raceOnce) {
      raceOnce = false;
      await super.generateKey(
        keyId: keyId,
        requireHardware: false,
        overwrite: false,
        protection: protection,
      );
      throw SecureSignerException(
        SignerErrorCode.keyAlreadyExists,
        'made by someone else',
      );
    }
    return _as(
      await super.generateKey(
        keyId: keyId,
        requireHardware: false,
        overwrite: overwrite,
        // The software store cannot enforce user presence and refuses a key that says so; the
        // protection asked for is what `generated` records.
        protection: KeyProtection.ambient,
      ),
    );
  }

  @override
  Future<Uint8List> sign({
    required String keyId,
    required Uint8List payload,
    String? reason,
  }) {
    calls.add('sign $keyId');
    reasons.add(reason);
    return super.sign(keyId: keyId, payload: payload, reason: reason);
  }

  @override
  Future<void> deleteKey(String keyId) {
    calls.add('delete $keyId');
    return super.deleteKey(keyId);
  }
}

void main() {
  group('HardwareKeypairSigner', () {
    late _Spy spy;
    late HardwareKeypairSigner signer;

    HardwareKeypairSigner make({
      String keyId = 'shop_device',
      KeyRole role = KeyRole.ambient,
      bool requireHardware = false,
      _Spy? platform,
    }) => HardwareKeypairSigner(
      keyId: keyId,
      role: role,
      requireHardware: requireHardware,
      signKeypair: SignKeypair(platform: platform ?? spy),
    );

    setUp(() {
      spy = _Spy();
      signer = make();
    });

    test(
      'makes an ambient key under its key id on first use, and only once',
      () async {
        final jwk = await signer.publicJwk();
        expect(jwk.keys, ['crv', 'kty', 'x', 'y']);
        expect(jwk['kty'], 'EC');
        expect(jwk['crv'], 'P-256');
        expect(await signer.publicJwk(), jwk);
        expect(spy.generated, [
          (
            keyId: 'shop_device',
            requireHardware: false,
            protection: KeyProtection.ambient,
          ),
        ]);
      },
    );

    test('touches nothing until it is used', () {
      expect(spy.calls, isEmpty);
    });

    test('is ambient unless it is made user-present', () {
      expect(signer.role, KeyRole.ambient);
      expect(
        HardwareKeypairSigner(keyId: 'x', role: KeyRole.userPresent).role,
        KeyRole.userPresent,
      );
    });

    test(
      'a user-present signer makes a user-present key, and signs with the reason',
      () async {
        final prompting = make(
          keyId: 'shop_device_user_present',
          role: KeyRole.userPresent,
        );
        await prompting.publicJwk();
        expect(spy.generated.single.protection, KeyProtection.userPresent);
        expect(
          await prompting.sign(Uint8List.fromList([1]), reason: 'Confirm'),
          hasLength(64),
        );
        expect(spy.reasons, ['Confirm']);
      },
    );

    test('exists asks without making the key', () async {
      expect(await signer.exists(), isFalse);
      expect(spy.generated, isEmpty);
      await signer.publicJwk();
      expect(await signer.exists(), isTrue);
      await signer.deleteKey();
      expect(await signer.exists(), isFalse);
      expect(spy.generated, hasLength(1));
    });

    test(
      'a restarted signer finds a key that exists, without a first use',
      () async {
        await signer.publicJwk();
        expect(await make().exists(), isTrue);
      },
    );

    test('two first uses at once make one key', () async {
      final results = await Future.wait([
        signer.publicJwk(),
        signer.publicJwk(),
        signer
            .sign(Uint8List.fromList([1, 2, 3]))
            .then((_) => <String, String>{}),
      ]);
      expect(results[0], results[1]);
      expect(spy.generated, hasLength(1));
    });

    test('finds the key again at the next start', () async {
      final first = await signer.publicJwk();
      final restarted = make();
      expect(await restarted.publicJwk(), first);
      expect(spy.generated, hasLength(1));
    });

    test('uses the key id it is given', () async {
      final other = make(keyId: 'shop_other');
      await other.publicJwk();
      expect(spy.generated.single.keyId, 'shop_other');
      expect(await spy.getKey('shop_device'), isNull);
    });

    test(
      'signs through signRaw with the key id: 64 bytes that verify',
      () async {
        final input = Uint8List.fromList(List<int>.generate(40, (i) => i));
        final signature = await signer.sign(input);
        expect(signature, hasLength(64));
        expect(spy.calls, contains('sign shop_device'));
        // It is the key's signature of the input.
        expect(
          verifiesEs256(await signer.publicJwk(), input, signature),
          isTrue,
        );
        expect(
          verifiesEs256(await signer.publicJwk(), [...input, 0], signature),
          isFalse,
        );
      },
    );

    test(
      'requireHardware passes through, and its failure is not hidden or remembered',
      () async {
        final strict = make(requireHardware: true);
        await expectLater(
          strict.publicJwk(),
          throwsA(
            isA<SecureSignerException>().having(
              (e) => e.code,
              'code',
              SignerErrorCode.hardwareUnavailable,
            ),
          ),
        );
        expect(spy.generated.single.requireHardware, isTrue);
        // The next call asks again, and fails the same way (it is not a cached failure).
        await expectLater(
          strict.publicJwk(),
          throwsA(isA<SecureSignerException>()),
        );
        expect(spy.generated, hasLength(2));
      },
    );

    test(
      'a key made by someone else in between is used (keyAlreadyExists)',
      () async {
        spy.raceOnce = true;
        final jwk = await signer.publicJwk();
        expect(jwk['kty'], 'EC');
        expect(spy.generated, hasLength(1));
      },
    );

    test('isHardwareBacked is what the platform says the key is', () async {
      expect(await signer.isHardwareBacked(), isFalse);
      final secure = _Spy(backing: KeyBacking.secureEnclave);
      expect(await make(platform: secure).isHardwareBacked(), isTrue);
      final tee = _Spy(backing: KeyBacking.trustedExecutionEnvironment);
      expect(await make(platform: tee).isHardwareBacked(), isTrue);
      final keychain = _Spy(backing: KeyBacking.keychain);
      expect(await make(platform: keychain).isHardwareBacked(), isFalse);
    });

    test('deleteKey deletes it, and the next use makes a new one', () async {
      final first = await signer.publicJwk();
      await signer.deleteKey();
      expect(spy.calls, contains('delete shop_device'));
      final second = await signer.publicJwk();
      expect(second, isNot(first));
      expect(spy.generated, hasLength(2));
    });

    test('a signer made without a SignKeypair makes none until used', () {
      // No platform is read: this would throw if it were (a test has no keystore).
      expect(HardwareKeypairSigner(keyId: 'x').keyId, 'x');
    });
  });

  group('SoftwareKeypairSigner', () {
    test('keeps its key for the life of the signer, in memory', () async {
      final signer = SoftwareKeypairSigner(keyId: 'k');
      final jwk = await signer.publicJwk();
      expect(await signer.publicJwk(), jwk);
      expect(await signer.isHardwareBacked(), isFalse);
      expect(await signer.sign(Uint8List.fromList([1])), hasLength(64));
    });

    test(
      'a new signer without a store has another key (a web reload signs out)',
      () async {
        expect(
          await SoftwareKeypairSigner(keyId: 'k').publicJwk(),
          isNot(await SoftwareKeypairSigner(keyId: 'k').publicJwk()),
        );
      },
    );

    test('a store of your own keeps the key across signers', () async {
      final store = InMemorySoftwareKeyStore();
      final first = await SoftwareKeypairSigner(
        keyId: 'k',
        store: store,
      ).publicJwk();
      expect(
        await SoftwareKeypairSigner(keyId: 'k', store: store).publicJwk(),
        first,
      );
      expect(
        await SoftwareKeypairSigner(
          keyId: 'k',
          store: InMemorySoftwareKeyStore(),
        ).publicJwk(),
        isNot(first),
      );
    });

    test(
      'deleteKey removes it from the store, and the next use makes a new one',
      () async {
        final store = InMemorySoftwareKeyStore();
        final signer = SoftwareKeypairSigner(store: store, keyId: 'k');
        final first = await signer.publicJwk();
        expect(await store.read('k'), isNotNull);
        await signer.deleteKey();
        expect(await store.read('k'), isNull);
        expect(await signer.publicJwk(), isNot(first));
      },
    );

    test('signs, and its signature verifies', () async {
      final signer = SoftwareKeypairSigner(keyId: 'k');
      final input = Uint8List.fromList([4, 5, 6]);
      expect(
        verifiesEs256(
          await signer.publicJwk(),
          input,
          await signer.sign(input),
        ),
        isTrue,
      );
    });

    test('is ambient, and exists only once made', () async {
      final signer = SoftwareKeypairSigner(keyId: 'k');
      expect(signer.role, KeyRole.ambient);
      expect(await signer.exists(), isFalse);
      await signer.publicJwk();
      expect(await signer.exists(), isTrue);
    });
  });
}
