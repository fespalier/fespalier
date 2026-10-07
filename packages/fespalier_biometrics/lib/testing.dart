/// What tests use from fespalier_biometrics (since 0.13.0).
library;

import 'dart:async';

import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier/fespalier.dart' show RefetchSignal, appResumeSignal;

export 'package:fespalier_biometrics/fespalier_biometrics.dart'
    show BiometricOutcome, BiometricPrompt;

/// A [BiometricPrompt] for tests: answers from a queue and counts (since 0.13.0). It shows nothing.
final class FakeBiometricPrompt extends BiometricPrompt {
  /// Answers [outcomes] in order, then [fallback].
  FakeBiometricPrompt({
    Iterable<BiometricOutcome> outcomes = const [],
    this.fallback = BiometricOutcome.success,
    this.available = true,
  }) : _queue = [...outcomes];

  final List<BiometricOutcome> _queue;

  /// The answer once the queue is empty.
  final BiometricOutcome fallback;

  /// What [isAvailable] answers.
  bool available;

  /// How many times [authenticate] was called: the number of sheets the person saw.
  int prompts = 0;

  /// The reason of each call, in order.
  final List<String> reasons = [];

  Completer<BiometricOutcome>? _held;

  /// Queues [outcome] after what is queued.
  void enqueue(BiometricOutcome outcome) => _queue.add(outcome);

  /// Makes the next [authenticate] wait until [release], so a test can call `unlock` again while
  /// the sheet is "up".
  void hold() => _held = Completer<BiometricOutcome>();

  /// Ends a held prompt with [outcome].
  void release([BiometricOutcome outcome = BiometricOutcome.success]) {
    _held?.complete(outcome);
    _held = null;
  }

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<BiometricOutcome> authenticate(String reason) {
    prompts++;
    reasons.add(reason);
    final held = _held;
    if (held != null) return held.future;
    final outcome = _queue.isEmpty ? fallback : _queue.removeAt(0);
    return Future<BiometricOutcome>.value(outcome);
  }
}

/// The overrides a test of a biometric screen needs (since 0.13.0): [prompt] as the app's prompt, and
/// a resume signal that fires only when the test calls `container.read(appResumeSignal.notifier).fire()`
/// (the real one needs a `WidgetsBinding`, which a `ProviderContainer` test has not).
List<Override> biometricTestOverrides(
  FakeBiometricPrompt prompt, {
  BiometricPolicy? policy,
}) => [
  biometricPrompt.overrideWithValue(prompt),
  appResumeSignal.overrideWith(RefetchSignal.new),
  if (policy != null) biometricPolicy.overrideWithValue(policy),
];
