/// Biometric unlock for fespalier (since 0.13.0): a guard that never prompts (`requireUnlocked`),
/// one single-flight `unlock()` that the app's unlock page calls, `withBiometrics` for an action,
/// a relock policy driven by the app coming back from the background, and (since 0.19.0) an idle lock and, in
/// `package:fespalier_biometrics/material.dart`, `BiometricLockScreen`, an unlock page body. The platform plugin (`local_auth`) is a recipe
/// in the fespalier-guards skill, not a dependency: this library has no platform code.
library;

export 'src/actions.dart' show BiometricDeclined, withBiometrics;
export 'src/guard.dart' show requireUnlocked;
export 'src/idle.dart' show BiometricActivity, biometricIdleTicker;
export 'src/policy.dart' show BiometricPolicy;
export 'src/prompt.dart'
    show BiometricOutcome, BiometricPrompt, biometricAvailable, biometricPrompt;
export 'src/telemetry.dart' show biometricPromptOp, biometricResultAttribute;
export 'src/unlock.dart'
    show
        BiometricUnlock,
        Locked,
        UnlockState,
        Unlocked,
        Unlocking,
        biometricPolicy,
        biometricUnlock;
