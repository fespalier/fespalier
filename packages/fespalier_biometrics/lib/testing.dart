/// What tests use from fespalier_biometrics (since 0.13.0).
library;

import 'dart:async';

import 'package:fespalier/testing.dart' show Override;
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier/fespalier.dart' show RefetchSignal, appShowSignal;

export 'package:fespalier_biometrics/fespalier_biometrics.dart'
    show
        BiometricOutcome,
        BiometricPrompt,
        BiometricSecrets,
        SecretFound,
        SecretMissing,
        SecretRead,
        SecretRefused;

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
  Completer<BiometricOutcome>? _taken;

  /// Queues [outcome] after what is queued.
  void enqueue(BiometricOutcome outcome) => _queue.add(outcome);

  /// Makes the next [authenticate] wait until [release], so a test can call `unlock` again while
  /// the sheet is "up".
  void hold() => _held = Completer<BiometricOutcome>();

  /// Ends a held prompt with [outcome]. It may come before the prompt starts: the outcome waits for
  /// the [authenticate] that takes the hold.
  void release([BiometricOutcome outcome = BiometricOutcome.success]) {
    final held = _held ?? _taken;
    if (held != null && !held.isCompleted) held.complete(outcome);
  }

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<BiometricOutcome> authenticate(String reason) {
    prompts++;
    reasons.add(reason);
    final held = _held;
    if (held != null) {
      _held = null;
      _taken = held;
      return held.future;
    }
    final outcome = _queue.isEmpty ? fallback : _queue.removeAt(0);
    return Future<BiometricOutcome>.value(outcome);
  }
}

/// A [BiometricSecrets] for tests: a map in memory, an outcomes queue and counts (since 0.19.0).
/// It shows nothing and gates nothing by itself; a queued [BiometricOutcome] that is not `success`
/// stands for a check that did not pass, and the value stays where it is.
final class FakeBiometricSecrets extends BiometricSecrets {
  /// Starts with [stored] and answers [outcomes] in order, then [fallback].
  FakeBiometricSecrets({
    Map<String, String> stored = const {},
    Iterable<BiometricOutcome> outcomes = const [],
    this.fallback = BiometricOutcome.success,
    this.available = true,
  }) : stored = {...stored},
       _queue = [...outcomes];

  final List<BiometricOutcome> _queue;

  /// What the keystore holds: key to value.
  final Map<String, String> stored;

  /// The answer once the queue is empty.
  final BiometricOutcome fallback;

  /// What [isAvailable] answers.
  bool available;

  /// When set, [read], [write] and [delete] throw it, like a plugin that crashed.
  Object? throws;

  /// How many times [read] was called: the sheets a person saw for reads.
  int reads = 0;

  /// How many times [write] was called.
  int writes = 0;

  /// How many times [delete] was called.
  int deletes = 0;

  /// The key of each [read], in order.
  final List<String> readKeys = [];

  /// The reason of each [read] and [write], in order.
  final List<String> reasons = [];

  Completer<BiometricOutcome>? _held;
  Completer<BiometricOutcome>? _taken;

  /// Queues [outcome] after what is queued.
  void enqueue(BiometricOutcome outcome) => _queue.add(outcome);

  /// Makes the next [read] or [write] wait until [release], so a test can ask again while the sheet is "up".
  void hold() => _held = Completer<BiometricOutcome>();

  /// Ends a held sheet with [outcome]. It may come before the call starts: the outcome waits for the
  /// call that takes the hold.
  void release([BiometricOutcome outcome = BiometricOutcome.success]) {
    final held = _held ?? _taken;
    if (held != null && !held.isCompleted) held.complete(outcome);
  }

  Future<BiometricOutcome> _check() {
    final held = _held;
    if (held != null) {
      _held = null;
      _taken = held;
      return held.future;
    }
    return Future<BiometricOutcome>.value(
      _queue.isEmpty ? fallback : _queue.removeAt(0),
    );
  }

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<SecretRead> read(String key, {required String reason}) async {
    reads++;
    readKeys.add(key);
    reasons.add(reason);
    final error = throws;
    if (error != null) throw error;
    final outcome = await _check();
    if (outcome != BiometricOutcome.success) return SecretRefused(outcome);
    final value = stored[key];
    return value == null ? const SecretMissing() : SecretFound(value);
  }

  @override
  Future<BiometricOutcome> write(
    String key,
    String value, {
    required String reason,
  }) async {
    writes++;
    reasons.add(reason);
    final error = throws;
    if (error != null) throw error;
    final outcome = await _check();
    if (outcome == BiometricOutcome.success) stored[key] = value;
    return outcome;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    final error = throws;
    if (error != null) throw error;
    stored.remove(key);
  }
}

/// The overrides a test of a biometric screen needs (since 0.13.0): [prompt] as the app's prompt, and
/// a return-from-hidden signal that fires only when the test calls `container.read(appShowSignal.notifier).fire()`
/// (the real one needs a `WidgetsBinding`, which a `ProviderContainer` test has not).
List<Override> biometricTestOverrides(
  FakeBiometricPrompt prompt, {
  BiometricPolicy? policy,
  FakeBiometricSecrets? secrets,
}) => [
  biometricPrompt.overrideWithValue(prompt),
  appShowSignal.overrideWith(RefetchSignal.new),
  if (policy != null) biometricPolicy.overrideWithValue(policy),
  if (secrets != null) biometricSecrets.overrideWithValue(secrets),
];
