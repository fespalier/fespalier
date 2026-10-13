import 'dart:async';

import 'package:fespalier/fespalier.dart';

import 'prompt.dart';
import 'unlock.dart';

/// [withBiometrics] found no proof: the person cancelled or the check did not pass (since 0.13.0).
final class BiometricDeclined implements Exception {
  /// Declined with [outcome], never [BiometricOutcome.success].
  const BiometricDeclined(this.outcome);

  /// Why the action did not run.
  final BiometricOutcome outcome;

  @override
  String toString() => 'BiometricDeclined(${outcome.name})';
}

/// Runs [action] after a biometric check, for the action that must not run on a borrowed phone
/// (since 0.13.0): paying, deleting the account, showing a secret.
///
/// It prompts only when the unlock is not younger than [maxAge] (default [Duration.zero]: every
/// time), and throws [BiometricDeclined] when the check does not pass, so an action's `Future` fails
/// and the page shows it like any failure. A success counts as an unlock for the guards too.
/// The prompt is the same single flight as `unlock`.
///
/// ```dart
/// Future<void> pay(Ref ref, Order order) =>
///     withBiometrics(ref, 'Confirm the payment', () => ref.read(api).pay(order));
/// ```
Future<T> withBiometrics<T>(
  Ref ref,
  String reason,
  FutureOr<T> Function() action, {
  Duration maxAge = Duration.zero,
}) async {
  final notifier = ref.read(biometricUnlock.notifier);
  if (!notifier.isFresh(maxAge: maxAge)) {
    final outcome = await notifier.unlock(reason);
    if (outcome != BiometricOutcome.success) throw BiometricDeclined(outcome);
  }
  return action();
}
