import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/testing.dart';
import 'package:flutter_sign_keypair/flutter_sign_keypair.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A platform that records what it was asked, over the package's own software signer. The
/// `SignKeypair` facade installs it as the global instance, so every test makes its own.
final class _Spy extends SoftwareSecureSigner {
  _Spy({this.backing = KeyBacking.software});

  final KeyBacking backing;
  final List<String> calls = [];
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
        protection: protection,
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
    return super.sign(keyId: keyId, payload: payload, reason: reason);
  }

  @override
  Future<void> deleteKey(String keyId) {
    calls.add('delete $keyId');
    return super.deleteKey(keyId);
  }
}

void main() {
  group('SignKeypairSigner', () {
    late _Spy spy;
    late SignKeypairSigner signer;

    SignKeypairSigner make({
      String keyId = 'fespalier_dpop',
      bool requireHardware = false,
      _Spy? platform,
    }) => SignKeypairSigner(
      keyId: keyId,
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
            keyId: 'fespalier_dpop',
            requireHardware: false,
            protection: KeyProtection.ambient,
          ),
        ]);
      },
    );

    test('touches nothing until it is used', () {
      expect(spy.calls, isEmpty);
    });

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
      final other = make(keyId: 'shop_dpop');
      await other.publicJwk();
      expect(spy.generated.single.keyId, 'shop_dpop');
      expect(await spy.getKey('fespalier_dpop'), isNull);
    });

    test(
      'signs through signRaw with the key id: 64 bytes that verify',
      () async {
        final input = Uint8List.fromList(List<int>.generate(40, (i) => i));
        final signature = await signer.sign(input);
        expect(signature, hasLength(64));
        expect(spy.calls, contains('sign fespalier_dpop'));
        // A proof signed with it verifies.
        final dpop = DpopProof(signer: signer);
        final proof = await withClock(
          Clock.fixed(t0),
          () => dpop.proof(
            method: 'GET',
            uri: Uri.parse('https://a.example.com/x'),
          ),
        );
        verifyDpopProof(
          proof,
          method: 'GET',
          uri: Uri.parse('https://a.example.com/x'),
          now: t0,
          thumbprint: await dpop.thumbprint(),
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
      expect(spy.calls, contains('delete fespalier_dpop'));
      final second = await signer.publicJwk();
      expect(second, isNot(first));
      expect(spy.generated, hasLength(2));
    });

    test('a signer made without a SignKeypair makes none until used', () {
      // No platform is read: this would throw if it were (a test has no keystore).
      expect(SignKeypairSigner(keyId: 'x').keyId, 'x');
    });
  });

  group('SoftwareDpopSigner', () {
    test('keeps its key for the life of the signer, in memory', () async {
      final signer = SoftwareDpopSigner();
      final jwk = await signer.publicJwk();
      expect(await signer.publicJwk(), jwk);
      expect(await signer.isHardwareBacked(), isFalse);
      expect(await signer.sign(Uint8List.fromList([1])), hasLength(64));
    });

    test(
      'a new signer without a store has another key (a web reload signs out)',
      () async {
        expect(
          await SoftwareDpopSigner().publicJwk(),
          isNot(await SoftwareDpopSigner().publicJwk()),
        );
      },
    );

    test('a store of your own keeps the key across signers', () async {
      final store = InMemorySoftwareKeyStore();
      final first = await SoftwareDpopSigner(store: store).publicJwk();
      expect(await SoftwareDpopSigner(store: store).publicJwk(), first);
      expect(
        await SoftwareDpopSigner(store: InMemorySoftwareKeyStore()).publicJwk(),
        isNot(first),
      );
    });

    test(
      'deleteKey removes it from the store, and the next use makes a new one',
      () async {
        final store = InMemorySoftwareKeyStore();
        final signer = SoftwareDpopSigner(store: store, keyId: 'k');
        final first = await signer.publicJwk();
        expect(await store.read('k'), isNotNull);
        await signer.deleteKey();
        expect(await store.read('k'), isNull);
        expect(await signer.publicJwk(), isNot(first));
      },
    );

    test('proofs made with it verify', () async {
      final dpop = DpopProof(signer: SoftwareDpopSigner());
      final uri = Uri.parse('https://sso.example.com/token');
      final proof = await dpop.proof(method: 'POST', uri: uri);
      final decoded = verifyDpopProof(proof, method: 'POST', uri: uri);
      expect(decoded.thumbprint, await dpop.thumbprint());
    });
  });

  group('FakeDpopSigner', () {
    test('has the same key and the same signature on every run', () async {
      final a = FakeDpopSigner();
      final b = FakeDpopSigner();
      final input = Uint8List.fromList([9, 8, 7]);
      expect(await a.publicJwk(), await b.publicJwk());
      expect(await a.sign(input), await b.sign(input));
      expect(a.signatures, 1);
    });

    test(
      'another seed is another key; deleteKey moves to the next key',
      () async {
        final signer = FakeDpopSigner(seed: 'another');
        final first = await signer.publicJwk();
        expect(first, isNot(fakeJwk0));
        await signer.deleteKey();
        expect(signer.deletes, 1);
        expect(await signer.publicJwk(), isNot(first));
      },
    );

    test('says what it is told about hardware', () async {
      expect(await FakeDpopSigner().isHardwareBacked(), isFalse);
      expect(await FakeDpopSigner(hardware: true).isHardwareBacked(), isTrue);
    });
  });
}
