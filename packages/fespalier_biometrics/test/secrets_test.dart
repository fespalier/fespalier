// Secrets behind the biometric: the port, the one-sheet line, and the promise that a read changes nothing.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const _secret = 'hunter2-the-value';

/// Every state any provider took, as text: what a value held in provider state would show up in.
final class _States extends ProviderObserver {
  final List<String> seen = [];

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) =>
      seen.add('$value');

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) => seen.add('$newValue');
}

final _states = _States();

ProviderContainer containerOf(
  FakeBiometricPrompt prompt,
  FakeBiometricSecrets secrets,
) {
  _states.seen.clear();
  final container = ProviderContainer(
    overrides: biometricTestOverrides(prompt, secrets: secrets),
    observers: [_states],
  );
  addTearDown(container.dispose);
  container.listen(biometricUnlock, (_, _) {});
  return container;
}

void main() {
  test('unconfigured, reading biometricSecrets says what to override', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      () => container.read(biometricSecrets),
      throwsA(
        predicate(
          (e) =>
              e.toString().contains('override biometricSecrets in startup()'),
        ),
      ),
    );
  });

  test('a found secret goes to the caller, and no provider holds it', () async {
    final secrets = FakeBiometricSecrets(stored: {'token': _secret});
    final container = containerOf(FakeBiometricPrompt(), secrets);
    final notifier = container.read(biometricUnlock.notifier);
    final result = await notifier.readSecret('token', 'Show the token');
    expect(result, isA<SecretFound>());
    expect((result as SecretFound).value, _secret);
    expect(result.toString(), isNot(contains(_secret)));
    expect(secrets.reasons, ['Show the token']);
    // Every state any provider took: none mentions the value.
    expect(_states.seen, isNotEmpty);
    expect(_states.seen.join(' | '), isNot(contains(_secret)));
  });

  test('a missing key is SecretMissing', () async {
    final container = containerOf(
      FakeBiometricPrompt(),
      FakeBiometricSecrets(),
    );
    expect(
      await container.read(biometricUnlock.notifier).readSecret('k', 'r'),
      isA<SecretMissing>(),
    );
  });

  test('a refusal is SecretRefused(outcome), never a throw', () async {
    final secrets = FakeBiometricSecrets(
      stored: {'k': _secret},
      outcomes: [
        BiometricOutcome.cancelled,
        BiometricOutcome.lockedOut,
        BiometricOutcome.unavailable,
      ],
    );
    final container = containerOf(FakeBiometricPrompt(), secrets);
    final notifier = container.read(biometricUnlock.notifier);
    for (final expected in [
      BiometricOutcome.cancelled,
      BiometricOutcome.lockedOut,
      BiometricOutcome.unavailable,
    ]) {
      final result = await notifier.readSecret('k', 'r');
      expect(result, isA<SecretRefused>());
      expect((result as SecretRefused).outcome, expected);
    }
    // The queue is empty: the next one passes.
    expect(await notifier.readSecret('k', 'r'), isA<SecretFound>());
  });

  test('a store that throws is SecretRefused(failed)', () async {
    final secrets = FakeBiometricSecrets()..throws = StateError('plugin');
    final container = containerOf(FakeBiometricPrompt(), secrets);
    final notifier = container.read(biometricUnlock.notifier);
    final result = await notifier.readSecret('k', 'r');
    expect((result as SecretRefused).outcome, BiometricOutcome.failed);
    expect(await notifier.writeSecret('k', 'v', 'r'), BiometricOutcome.failed);
    // The line is free again after a throw.
    secrets.throws = null;
    expect(await notifier.readSecret('k', 'r'), isA<SecretMissing>());
  });

  test('two reads of one key share one sheet', () async {
    final secrets = FakeBiometricSecrets(stored: {'k': _secret})..hold();
    final container = containerOf(FakeBiometricPrompt(), secrets);
    final notifier = container.read(biometricUnlock.notifier);
    final a = notifier.readSecret('k', 'one');
    final b = notifier.readSecret('k', 'two');
    expect(identical(a, b), isTrue);
    secrets.release();
    expect(await a, isA<SecretFound>());
    expect(await b, isA<SecretFound>());
    expect(secrets.reads, 1);
    // Over: the next read asks again.
    await notifier.readSecret('k', 'three');
    expect(secrets.reads, 2);
  });

  test('reads of two keys are two sheets, one after the other', () async {
    final secrets = FakeBiometricSecrets(stored: {'a': '1', 'b': '2'})..hold();
    final container = containerOf(FakeBiometricPrompt(), secrets);
    final notifier = container.read(biometricUnlock.notifier);
    final a = notifier.readSecret('a', 'r');
    final b = notifier.readSecret('b', 'r');
    await Future<void>.delayed(Duration.zero);
    expect(secrets.readKeys, ['a']);
    secrets.release();
    await a;
    await b;
    expect(secrets.readKeys, ['a', 'b']);
  });

  test('a read while unlock()\'s sheet is up waits for it', () async {
    final prompt = FakeBiometricPrompt()..hold();
    final secrets = FakeBiometricSecrets(stored: {'k': _secret})..hold();
    final container = containerOf(prompt, secrets);
    final notifier = container.read(biometricUnlock.notifier);
    final unlocking = notifier.unlock('Unlock');
    final reading = notifier.readSecret('k', 'Show');
    await Future<void>.delayed(Duration.zero);
    expect(prompt.prompts, 1);
    expect(secrets.reads, 0, reason: 'the read waits for the unlock sheet');
    prompt.release();
    expect(await unlocking, BiometricOutcome.success);
    await Future<void>.delayed(Duration.zero);
    expect(secrets.reads, 1, reason: 'then the read\'s sheet comes up');
    secrets.release();
    expect(await reading, isA<SecretFound>());
  });

  test('an unlock while a read\'s sheet is up waits for it too', () async {
    final prompt = FakeBiometricPrompt();
    final secrets = FakeBiometricSecrets(stored: {'k': _secret})..hold();
    final container = containerOf(prompt, secrets);
    final notifier = container.read(biometricUnlock.notifier);
    final reading = notifier.readSecret('k', 'Show');
    final unlocking = notifier.unlock('Unlock');
    await Future<void>.delayed(Duration.zero);
    expect(prompt.prompts, 0);
    secrets.release();
    await reading;
    expect(await unlocking, BiometricOutcome.success);
    expect(prompt.prompts, 1);
  });

  test('a read does not unlock the app', () async {
    final container = containerOf(
      FakeBiometricPrompt(),
      FakeBiometricSecrets(stored: {'k': _secret}),
    );
    final states = <UnlockState>[];
    container.listen(biometricUnlock, (_, next) => states.add(next));
    final result = await container
        .read(biometricUnlock.notifier)
        .readSecret('k', 'r');
    expect(result, isA<SecretFound>());
    expect(container.read(biometricUnlock), isA<Locked>());
    expect(states, isEmpty, reason: 'a read tells no listener');
  });

  test(
    'lock() leaves stored secrets alone; deleteSecret removes one',
    () async {
      final secrets = FakeBiometricSecrets(stored: {'a': '1', 'b': '2'});
      final prompt = FakeBiometricPrompt();
      final container = containerOf(prompt, secrets);
      final notifier = container.read(biometricUnlock.notifier);
      await notifier.unlock('r');
      notifier.lock();
      expect(secrets.stored, {'a': '1', 'b': '2'});
      await notifier.deleteSecret('a');
      expect(secrets.stored, {'b': '2'});
      expect(secrets.deletes, 1);
      expect(await notifier.readSecret('a', 'r'), isA<SecretMissing>());
    },
  );

  test(
    'writeSecret stores on success and keeps nothing on a refusal',
    () async {
      final secrets = FakeBiometricSecrets(
        outcomes: [BiometricOutcome.cancelled],
      );
      final container = containerOf(FakeBiometricPrompt(), secrets);
      final notifier = container.read(biometricUnlock.notifier);
      expect(
        await notifier.writeSecret('k', _secret, 'Save'),
        BiometricOutcome.cancelled,
      );
      expect(secrets.stored, isEmpty);
      expect(
        await notifier.writeSecret('k', _secret, 'Save'),
        BiometricOutcome.success,
      );
      expect(secrets.stored, {'k': _secret});
      expect(container.read(biometricUnlock), isA<Locked>());
      expect(_states.seen.join(' | '), isNot(contains(_secret)));
    },
  );

  test('reading a secret without an override throws what to override', () {
    final container = ProviderContainer(
      overrides: biometricTestOverrides(FakeBiometricPrompt()),
    );
    addTearDown(container.dispose);
    container.listen(biometricUnlock, (_, _) {});
    expect(
      () => container.read(biometricUnlock.notifier).readSecret('k', 'r'),
      throwsA(
        predicate((e) => e.toString().contains('override biometricSecrets')),
      ),
    );
  });
}
