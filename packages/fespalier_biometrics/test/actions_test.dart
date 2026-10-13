import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

final _ref = Provider<Ref>((ref) => ref);

void main() {
  late FakeBiometricPrompt prompt;
  late ProviderContainer container;

  Ref refOf() => container.read(_ref);

  void setUpWith(FakeBiometricPrompt p) {
    prompt = p;
    container = ProviderContainer(overrides: biometricTestOverrides(p));
    addTearDown(container.dispose);
    container.listen(biometricUnlock, (_, _) {});
  }

  test('it prompts, then runs the action and returns its value', () async {
    setUpWith(FakeBiometricPrompt());
    final value = await withBiometrics(refOf(), 'Confirm', () => 42);
    expect(value, 42);
    expect(prompt.reasons, ['Confirm']);
    // A success counts as an unlock.
    expect(container.read(biometricUnlock), isA<Unlocked>());
  });

  test('a cancel throws BiometricDeclined and the action never runs', () async {
    setUpWith(FakeBiometricPrompt(outcomes: [BiometricOutcome.cancelled]));
    var ran = false;
    await expectLater(
      withBiometrics(refOf(), 'Confirm', () => ran = true),
      throwsA(
        isA<BiometricDeclined>().having(
          (e) => e.outcome,
          'outcome',
          BiometricOutcome.cancelled,
        ),
      ),
    );
    expect(ran, isFalse);
  });

  test('every outcome but success declines', () async {
    for (final outcome in BiometricOutcome.values.where(
      (o) => o != BiometricOutcome.success,
    )) {
      setUpWith(FakeBiometricPrompt(outcomes: [outcome]));
      await expectLater(
        withBiometrics(refOf(), 'r', () => 1),
        throwsA(isA<BiometricDeclined>()),
        reason: outcome.name,
      );
    }
  });

  test(
    'maxAge: a fresh unlock skips the prompt, an old one asks again',
    () async {
      setUpWith(FakeBiometricPrompt());
      final start = DateTime(2026, 10, 7, 9);
      await withClock(
        Clock.fixed(start),
        () => withBiometrics(
          refOf(),
          'a',
          () => 1,
          maxAge: const Duration(minutes: 1),
        ),
      );
      await withClock(
        Clock.fixed(start.add(const Duration(seconds: 30))),
        () => withBiometrics(
          refOf(),
          'b',
          () => 1,
          maxAge: const Duration(minutes: 1),
        ),
      );
      expect(prompt.prompts, 1);
      await withClock(
        Clock.fixed(start.add(const Duration(minutes: 2))),
        () => withBiometrics(
          refOf(),
          'c',
          () => 1,
          maxAge: const Duration(minutes: 1),
        ),
      );
      expect(prompt.prompts, 2);
    },
  );

  test('the default maxAge asks every time', () async {
    setUpWith(FakeBiometricPrompt());
    await withBiometrics(refOf(), 'a', () => 1);
    await withBiometrics(refOf(), 'b', () => 1);
    expect(prompt.prompts, 2);
  });

  test('an action that throws leaves its error as it was', () async {
    setUpWith(FakeBiometricPrompt());
    await expectLater(
      withBiometrics<void>(refOf(), 'r', () => throw ArgumentError('x')),
      throwsArgumentError,
    );
  });
}
