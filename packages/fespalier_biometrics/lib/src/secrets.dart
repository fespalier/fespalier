import 'package:fespalier/fespalier.dart';

import 'prompt.dart';

/// What a secret kept behind the biometric answers on a read (since 0.19.0).
sealed class SecretRead {
  /// For subclasses.
  const SecretRead();
}

/// The secret was there and the check passed.
final class SecretFound extends SecretRead {
  /// The stored [value]. It goes to the caller of `BiometricUnlock.readSecret` and nowhere else.
  const SecretFound(this.value);

  /// The secret. Never written to state, telemetry or a log by this package.
  final String value;

  /// Hides [value], so a log line or a failed `expect` never prints the secret.
  @override
  String toString() => 'SecretFound(<hidden>)';
}

/// Nothing is stored under that key (or the keystore made the item unreadable: a newly enrolled
/// finger with iOS `biometryCurrentSet` invalidates it, and the platform reports it as gone).
final class SecretMissing extends SecretRead {
  /// The missing answer.
  const SecretMissing();

  @override
  String toString() => 'SecretMissing()';
}

/// The check did not pass, or could not be asked, so the keystore kept the value.
final class SecretRefused extends SecretRead {
  /// Refused with [outcome], never [BiometricOutcome.success].
  const SecretRefused(this.outcome);

  /// Why: cancelled, failed, locked out or unavailable.
  final BiometricOutcome outcome;

  @override
  String toString() => 'SecretRefused(${outcome.name})';
}

/// A store whose items the **keystore** gates (since 0.19.0): the platform asks for the biometric as
/// part of decrypting the item, so no Dart code can read the value by skipping a guard. One per app,
/// written once; the `flutter_secure_storage` recipe in the fespalier-guards skill is about 60 lines,
/// and `FakeBiometricSecrets` in `package:fespalier_biometrics/testing.dart` is the test's.
///
/// An implementation shows the platform's own sheet and nothing of Flutter's. It does not throw for
/// the outcomes of [BiometricOutcome]; one that throws is reported as `BiometricOutcome.failed`.
abstract class BiometricSecrets {
  /// Const so an app can write `const SecureStorageSecrets()`.
  const BiometricSecrets();

  /// Whether this device can gate an item behind a biometric. Cheap.
  Future<bool> isAvailable();

  /// Reads [key] behind the platform's sheet, which shows [reason].
  Future<SecretRead> read(String key, {required String reason});

  /// Stores [value] under [key] so that reading it needs the biometric. [reason] is what a platform
  /// that asks on a write shows.
  Future<BiometricOutcome> write(
    String key,
    String value, {
    required String reason,
  });

  /// Removes [key]. Removing needs no biometric, and a missing key is not an error.
  Future<void> delete(String key);
}

/// The app's secret store (since 0.19.0). Override it in `startup()`:
/// `biometricSecrets.overrideWithValue(const SecureStorageSecrets())`. Reading it unconfigured
/// throws a `StateError` that says so.
final biometricSecrets = Provider<BiometricSecrets>(
  (ref) => throw StateError(
    'fespalier_biometrics: override biometricSecrets in startup() '
    '(biometricSecrets.overrideWithValue(...)); see the flutter_secure_storage recipe in the fespalier-guards skill',
  ),
);
