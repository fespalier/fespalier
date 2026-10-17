import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'an outcome released before authenticate runs is the one it answers',
    () async {
      final prompt = FakeBiometricPrompt()..hold();
      prompt.release(BiometricOutcome.cancelled);
      expect(await prompt.authenticate('r'), BiometricOutcome.cancelled);
      // The hold is used up: the next prompt answers from the queue.
      expect(await prompt.authenticate('r'), BiometricOutcome.success);
    },
  );

  test('hold, then release after authenticate started', () async {
    final prompt = FakeBiometricPrompt()..hold();
    final answer = prompt.authenticate('r');
    prompt.release(BiometricOutcome.lockedOut);
    expect(await answer, BiometricOutcome.lockedOut);
  });

  group('FakeBiometricSecrets', () {
    test('reads from the map, answers the queue, then the fallback', () async {
      final secrets = FakeBiometricSecrets(
        stored: {'a': '1'},
        outcomes: [BiometricOutcome.cancelled],
      );
      final first = await secrets.read('a', reason: 'one');
      expect((first as SecretRefused).outcome, BiometricOutcome.cancelled);
      expect(await secrets.read('a', reason: 'two'), isA<SecretFound>());
      expect(await secrets.read('b', reason: 'three'), isA<SecretMissing>());
      expect(secrets.reads, 3);
      expect(secrets.readKeys, ['a', 'a', 'b']);
      expect(secrets.reasons, ['one', 'two', 'three']);
    });

    test('a write stores only on success; delete removes', () async {
      final secrets = FakeBiometricSecrets(outcomes: [BiometricOutcome.failed]);
      expect(
        await secrets.write('k', 'v', reason: 'r'),
        BiometricOutcome.failed,
      );
      expect(secrets.stored, isEmpty);
      expect(
        await secrets.write('k', 'v', reason: 'r'),
        BiometricOutcome.success,
      );
      expect(secrets.stored, {'k': 'v'});
      await secrets.delete('k');
      expect(secrets.stored, isEmpty);
      expect((secrets.writes, secrets.deletes), (2, 1));
    });

    test('hold and release, also released before the call', () async {
      final secrets = FakeBiometricSecrets(stored: {'k': 'v'})..hold();
      final answer = secrets.read('k', reason: 'r');
      secrets.release(BiometricOutcome.lockedOut);
      expect(
        (await answer as SecretRefused).outcome,
        BiometricOutcome.lockedOut,
      );
      secrets.hold();
      secrets.release(BiometricOutcome.cancelled);
      expect(
        (await secrets.read('k', reason: 'r') as SecretRefused).outcome,
        BiometricOutcome.cancelled,
      );
      expect(await secrets.read('k', reason: 'r'), isA<SecretFound>());
    });

    test('SecretFound hides its value', () {
      expect(
        const SecretFound('hunter2').toString(),
        isNot(contains('hunter2')),
      );
    });

    test('biometricTestOverrides installs it', () {
      final secrets = FakeBiometricSecrets();
      final container = ProviderContainer(
        overrides: biometricTestOverrides(
          FakeBiometricPrompt(),
          secrets: secrets,
        ),
      );
      addTearDown(container.dispose);
      expect(identical(container.read(biometricSecrets), secrets), isTrue);
    });
  });
}
