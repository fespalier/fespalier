import 'package:fespalier/fespalier.dart';

/// How a prompt ended (since 0.13.0).
enum BiometricOutcome {
  /// The person proved who they are.
  success,

  /// The person closed the platform's sheet, or chose its fallback.
  cancelled,

  /// The sheet was shown and the check did not pass (a finger or face that did not match, too many
  /// tries on this prompt), or the prompt threw.
  failed,

  /// This device cannot ask: no biometrics enrolled, no hardware, or no passcode set.
  unavailable,

  /// The platform refused to ask for now (too many failed tries; a lockout that a passcode or time lifts).
  lockedOut,
}

/// What asks the platform for a biometric check (since 0.13.0). One per app, written once (the
/// `local_auth` recipes in the fespalier-guards skill are 20 lines); [FakeBiometricPrompt] in
/// `package:fespalier_biometrics/testing.dart` is the test's.
///
/// An implementation shows the platform's own sheet and nothing of Flutter's: no dialog, no
/// "error dialog" of the plugin, no route. It does not throw for the outcomes above; one that throws
/// is reported as [BiometricOutcome.failed].
abstract class BiometricPrompt {
  /// Const so an app can write `const LocalAuthPrompt()`.
  const BiometricPrompt();

  /// Whether [authenticate] can show a sheet on this device. Cheap, and safe to call from an unlock
  /// page's build.
  Future<bool> isAvailable();

  /// Shows the platform's sheet with [reason] (what the person reads: "Unlock your orders") and
  /// returns how it ended.
  Future<BiometricOutcome> authenticate(String reason);
}

/// The app's prompt (since 0.13.0). Override it in `startup()`:
/// `biometricPrompt.overrideWithValue(const LocalAuthPrompt())`. Unlike a guard, reading it
/// unconfigured throws a `StateError` that says so.
final biometricPrompt = Provider<BiometricPrompt>(
  (ref) => throw StateError(
    'fespalier_biometrics: override biometricPrompt in startup() '
    '(biometricPrompt.overrideWithValue(...)); see the local_auth recipe in the fespalier-guards skill',
  ),
);

/// Whether the device can ask now (since 0.13.0): for an unlock page that offers "Use your passcode"
/// instead of a button that cannot work.
final biometricAvailable = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(biometricPrompt).isAvailable(),
);
