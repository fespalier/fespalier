// The unlock state: one prompt per unlock(), the clock-based freshness, and the relock on resume.
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderContainer containerOf(
  FakeBiometricPrompt prompt, {
  BiometricPolicy? policy,
}) {
  final container = ProviderContainer(
    overrides: biometricTestOverrides(prompt, policy: policy),
  );
  addTearDown(container.dispose);
  // Held open the way a guard or a screen holds it.
  container.listen(biometricUnlock, (_, _) {});
  return container;
}

void main() {
  test('it starts locked and a success unlocks at the clock\'s time', () async {
    final at = DateTime(2026, 10, 7, 9);
    await withClock(Clock.fixed(at), () async {
      final prompt = FakeBiometricPrompt();
      final container = containerOf(prompt);
      expect(container.read(biometricUnlock), isA<Locked>());
      final outcome = await container
          .read(biometricUnlock.notifier)
          .unlock('Unlock');
      expect(outcome, BiometricOutcome.success);
      expect(container.read(biometricUnlock), isA<Unlocked>());
      expect((container.read(biometricUnlock) as Unlocked).at, at);
      expect(prompt.reasons, ['Unlock']);
    });
  });

  test(
    'two concurrent unlock() calls show one prompt and share the answer',
    () async {
      final prompt = FakeBiometricPrompt()..hold();
      final container = containerOf(prompt);
      final notifier = container.read(biometricUnlock.notifier);
      final a = notifier.unlock('one');
      final b = notifier.unlock('two');
      expect(identical(a, b), isTrue);
      expect(container.read(biometricUnlock), isA<Unlocking>());
      prompt.release();
      expect(await a, BiometricOutcome.success);
      expect(await b, BiometricOutcome.success);
      expect(prompt.prompts, 1);
      // The flight is over: the next explicit unlock prompts again.
      await notifier.unlock('three');
      expect(prompt.prompts, 2);
    },
  );

  test(
    'a cancel or a failure leaves it locked, and a throw is failed',
    () async {
      final prompt = FakeBiometricPrompt(
        outcomes: [BiometricOutcome.cancelled, BiometricOutcome.lockedOut],
      );
      final container = containerOf(prompt);
      final notifier = container.read(biometricUnlock.notifier);
      expect(await notifier.unlock('r'), BiometricOutcome.cancelled);
      expect(container.read(biometricUnlock), isA<Locked>());
      expect(await notifier.unlock('r'), BiometricOutcome.lockedOut);
      expect(container.read(biometricUnlock), isA<Locked>());
      final throwing = ProviderContainer(
        overrides: [
          appResumeSignal.overrideWith(RefetchSignal.new),
          biometricPrompt.overrideWithValue(_Throws()),
        ],
      );
      addTearDown(throwing.dispose);
      throwing.listen(biometricUnlock, (_, _) {});
      expect(
        await throwing.read(biometricUnlock.notifier).unlock('r'),
        BiometricOutcome.failed,
      );
      expect(throwing.read(biometricUnlock), isA<Locked>());
    },
  );

  test('a failed prompt over an unlock goes back to that unlock', () async {
    final prompt = FakeBiometricPrompt(
      outcomes: [BiometricOutcome.success, BiometricOutcome.cancelled],
    );
    final container = containerOf(prompt);
    final notifier = container.read(biometricUnlock.notifier);
    await notifier.unlock('first');
    final before = container.read(biometricUnlock);
    final second = notifier.unlock('second');
    expect(container.read(biometricUnlock), isA<Unlocking>());
    expect((container.read(biometricUnlock) as Unlocking).wasUnlocked, isTrue);
    await second;
    expect(
      (container.read(biometricUnlock) as Unlocked).at,
      (before as Unlocked).at,
    );
  });

  test('isFresh reads the clock: maxAge, and no maxAge at all', () async {
    final start = DateTime(2026, 10, 7, 9);
    final prompt = FakeBiometricPrompt();
    final container = containerOf(prompt);
    final notifier = container.read(biometricUnlock.notifier);
    expect(notifier.isFresh(), isFalse);
    await withClock(Clock.fixed(start), () => notifier.unlock('r'));
    withClock(Clock.fixed(start.add(const Duration(minutes: 4))), () {
      expect(notifier.isFresh(), isTrue);
      expect(notifier.isFresh(maxAge: const Duration(minutes: 5)), isTrue);
      expect(notifier.isFresh(maxAge: const Duration(minutes: 4)), isFalse);
      expect(notifier.isFresh(maxAge: Duration.zero), isFalse);
    });
  });

  test('lock() gives the unlock back', () async {
    final container = containerOf(FakeBiometricPrompt());
    final notifier = container.read(biometricUnlock.notifier);
    await notifier.unlock('r');
    notifier.lock();
    expect(container.read(biometricUnlock), isA<Locked>());
    expect(notifier.isFresh(), isFalse);
  });

  group('relock on resume', () {
    final start = DateTime(2026, 10, 7, 9);
    const policy = BiometricPolicy(resumeGrace: Duration(seconds: 30));

    test('a resume inside the grace keeps the unlock', () async {
      final container = containerOf(FakeBiometricPrompt(), policy: policy);
      await withClock(
        Clock.fixed(start),
        () => container.read(biometricUnlock.notifier).unlock('r'),
      );
      withClock(Clock.fixed(start.add(const Duration(seconds: 29))), () {
        container.read(appResumeSignal.notifier).fire();
        expect(container.read(biometricUnlock), isA<Unlocked>());
      });
    });

    test(
      'a resume past the grace locks, and a later resume stays locked',
      () async {
        final container = containerOf(FakeBiometricPrompt(), policy: policy);
        await withClock(
          Clock.fixed(start),
          () => container.read(biometricUnlock.notifier).unlock('r'),
        );
        withClock(Clock.fixed(start.add(const Duration(seconds: 30))), () {
          container.read(appResumeSignal.notifier).fire();
          expect(container.read(biometricUnlock), isA<Locked>());
          container.read(appResumeSignal.notifier).fire();
          expect(container.read(biometricUnlock), isA<Locked>());
        });
      },
    );

    test('Duration.zero relocks on every resume', () async {
      final container = containerOf(
        FakeBiometricPrompt(),
        policy: const BiometricPolicy(resumeGrace: Duration.zero),
      );
      await withClock(
        Clock.fixed(start),
        () => container.read(biometricUnlock.notifier).unlock('r'),
      );
      withClock(Clock.fixed(start), () {
        container.read(appResumeSignal.notifier).fire();
        expect(container.read(biometricUnlock), isA<Locked>());
      });
    });

    test(
      'a resume while the sheet is up (the sheet pauses the app) does not drop the prompt',
      () async {
        final prompt = FakeBiometricPrompt()..hold();
        final container = containerOf(
          prompt,
          policy: const BiometricPolicy(resumeGrace: Duration.zero),
        );
        final notifier = container.read(biometricUnlock.notifier);
        final flight = notifier.unlock('r');
        container.read(appResumeSignal.notifier).fire();
        expect(container.read(biometricUnlock), isA<Unlocking>());
        prompt.release();
        expect(await flight, BiometricOutcome.success);
        expect(container.read(biometricUnlock), isA<Unlocked>());
        expect(prompt.prompts, 1);
      },
    );
  });

  test('unconfigured, reading the prompt says what to override', () {
    final container = ProviderContainer(
      overrides: [appResumeSignal.overrideWith(RefetchSignal.new)],
    );
    addTearDown(container.dispose);
    expect(
      () => container.read(biometricPrompt),
      throwsA(
        predicate(
          (Object e) => e.toString().contains('override biometricPrompt'),
        ),
      ),
    );
  });
}

class _Throws extends BiometricPrompt {
  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<BiometricOutcome> authenticate(String reason) =>
      throw StateError('plugin crashed');
}
