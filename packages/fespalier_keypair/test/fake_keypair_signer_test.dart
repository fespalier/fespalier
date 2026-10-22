import 'dart:typed_data';

import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  final input = Uint8List.fromList([9, 8, 7]);

  test('has the same key and the same signature on every run', () async {
    final a = FakeKeypairSigner();
    final b = FakeKeypairSigner();
    expect(await a.publicJwk(), await b.publicJwk());
    expect(await a.sign(input), await b.sign(input));
    expect(a.signatures, 1);
    expect(verifiesEs256(fakeJwk0, input, await a.sign(input)), isTrue);
  });

  test(
    'another seed is another key; deleteKey moves to the next key',
    () async {
      final signer = FakeKeypairSigner(seed: 'another');
      final first = await signer.publicJwk();
      expect(first, isNot(fakeJwk0));
      await signer.deleteKey();
      expect(signer.deletes, 1);
      expect(await signer.publicJwk(), isNot(first));
    },
  );

  test('says what it is told about hardware and role', () async {
    expect(await FakeKeypairSigner().isHardwareBacked(), isFalse);
    expect(await FakeKeypairSigner(hardware: true).isHardwareBacked(), isTrue);
    expect(FakeKeypairSigner().role, KeyRole.ambient);
    expect(
      FakeKeypairSigner(role: KeyRole.userPresent).role,
      KeyRole.userPresent,
    );
  });

  test(
    'exists is false until the key is made, and after it is deleted',
    () async {
      final signer = FakeKeypairSigner();
      expect(await signer.exists(), isFalse);
      await signer.publicJwk();
      expect(await signer.exists(), isTrue);
      await signer.deleteKey();
      expect(await signer.exists(), isFalse);
    },
  );

  group('a refused user-presence prompt', () {
    test(
      'is a cancelled prompt, once, and it still counts as a prompt',
      () async {
        final signer = FakeKeypairSigner(role: KeyRole.userPresent)
          ..refuseNextPrompt();
        await expectLater(
          signer.sign(input, reason: 'Pay'),
          throwsA(
            isA<SecureSignerException>().having(
              (e) => e.code,
              'code',
              SignerErrorCode.userAuthenticationCancelled,
            ),
          ),
        );
        expect(signer.prompts, 1);
        expect(signer.signatures, 0);
        expect(await signer.sign(input, reason: 'Pay'), hasLength(64));
        expect(signer.prompts, 2);
        expect(signer.lastReason, 'Pay');
      },
    );

    test(
      'can be refused every time, until prompts are allowed again',
      () async {
        final signer = FakeKeypairSigner(role: KeyRole.userPresent)
          ..refuseNextPrompt(always: true);
        for (var i = 0; i < 3; i++) {
          await expectLater(
            signer.sign(input),
            throwsA(isA<SecureSignerException>()),
          );
        }
        signer.allowPrompts();
        expect(await signer.sign(input), hasLength(64));
      },
    );

    test('never refuses an ambient key, which shows no prompt', () async {
      final signer = FakeKeypairSigner()..refuseNextPrompt();
      expect(await signer.sign(input), hasLength(64));
      expect(signer.prompts, 0);
    });
  });

  group('a lost key', () {
    test(
      'is gone without the app asking, and the next use makes another',
      () async {
        final signer = FakeKeypairSigner();
        final first = await signer.publicJwk();
        await signer.loseKey();
        expect(await signer.exists(), isFalse);
        expect(signer.deletes, 0, reason: 'the app did not delete it');
        expect(await signer.publicJwk(), isNot(first));
        expect(await signer.exists(), isTrue);
      },
    );
  });
}
