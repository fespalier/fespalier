# Biometric prompts: `local_auth` 3.x

Since 0.13.0. A [`BiometricPrompt`](biometrics.md) is two methods, and `local_auth` is the plugin that implements them.
It is a **recipe, not a dependency of `fespalier_biometrics`**: `local_auth` 2.x and 3.x cannot share one source (2.x
takes `AuthenticationOptions`, 3.x takes named parameters and throws `LocalAuthException`, and 3.x needs Flutter 3.35 or
newer), and an app that already uses another plugin should not link this one. This page is `local_auth` **3.x**;
[`biometric-prompts-local-auth-2.md`](biometric-prompts-local-auth-2.md) is 2.x.

The sample is built by `just skill-samples` (`fsp gen`, `flutter analyze`); nothing runs the plugin at test time. Last
built on 2026-10-07 against `local_auth` 3.0.2 (`LocalAuthException` codes of `local_auth_platform_interface` 1.1.0).
Its floor is the app's: Flutter 3.38 per the plugin's own pubspec.

```yaml
# pubspec.yaml dependencies
  local_auth: ^3.0.2
```

```dart
// lib/biometrics.dart
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:local_auth/local_auth.dart';

/// The platform's own biometric (or, without [biometricOnly], device credential) sheet. Never a Flutter dialog.
final class LocalAuthPrompt extends BiometricPrompt {
  const LocalAuthPrompt({this.biometricOnly = false});

  /// True: only a fingerprint or a face, no passcode fallback.
  final bool biometricOnly;

  @override
  Future<bool> isAvailable() async {
    final auth = LocalAuthentication();
    if (biometricOnly) return (await auth.getAvailableBiometrics()).isNotEmpty;
    return auth.isDeviceSupported();
  }

  @override
  Future<BiometricOutcome> authenticate(String reason) async {
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: reason,
        biometricOnly: biometricOnly,
        // The sheet pauses the app: retry on foregrounding instead of failing on backgrounding.
        persistAcrossBackgrounding: true,
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.userRequestedFallback => BiometricOutcome.cancelled,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
        LocalAuthExceptionCode.uiUnavailable => BiometricOutcome.unavailable,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => BiometricOutcome.lockedOut,
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.deviceError ||
        LocalAuthExceptionCode.unknownError => BiometricOutcome.failed,
      };
    }
  }
}
```

```dart
// test/local_auth_prompt_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/biometrics.dart';

void main() {
  test('the recipe is a const BiometricPrompt, built without touching the plugin', () {
    expect(const LocalAuthPrompt(), isNotNull);
    expect(const LocalAuthPrompt(biometricOnly: true).biometricOnly, isTrue);
  });
}
```

Wire it in `startup()`: `biometricPrompt.overrideWithValue(const LocalAuthPrompt())`.

## Platform setup (the plugin's, not fespalier's)

The plugin's README per platform is the source; the parts that bite:

- **Android**: the main activity extends `FlutterFragmentActivity`, not `FlutterActivity`; the manifest has
  `USE_BIOMETRIC`; the theme of the activity is an `AppCompat` one. Without these the sheet never shows and
  `uiUnavailable` is the answer (`unavailable` here).
- **iOS**: `NSFaceIDUsageDescription` in `Info.plist`, or Face ID devices fail at the first prompt.
- The exhaustive `switch` has no default on purpose: a `local_auth` release that adds a code fails `flutter analyze`
  until you place it.
- The sheet is the platform's. The plugin's 2.x `useErrorDialogs` (native error dialogs) has no 3.x equivalent: the
  codes above are the app's to show, usually on the unlock page.
