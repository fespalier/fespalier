# Biometric prompts: `local_auth` 2.x

Since 0.13.0. The 2.x recipe for a [`BiometricPrompt`](biometrics.md), for an app on a Flutter older than 3.35 (`local_auth`
3.x needs Flutter 3.38 per its pubspec; the 3.x recipe is [`biometric-prompts.md`](biometric-prompts.md)). `local_auth`
is a recipe, not a dependency of `fespalier_biometrics`.

**Pass `useErrorDialogs: false`.** In 2.x it defaults to true, and the plugin then shows its own native dialog for "no
biometrics enrolled" or "no passcode set" on top of your unlock page, which is the dialog this app does not want and the
outcome (`unavailable`) tells the page to show instead.

The sample is built by `just skill-samples`; nothing runs the plugin at test time. Last built on 2026-10-07 against
`local_auth` 2.3.0, the last 2.x. The range below is the one that resolves on the Flutter 3.32 floor.

```yaml
# pubspec.yaml dependencies
  local_auth: ">=2.3.0 <3.0.0"
```

```dart
// lib/biometrics.dart
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
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
        options: AuthenticationOptions(
          biometricOnly: biometricOnly,
          // 2.x shows native error dialogs by default; the unlock page shows the outcome instead.
          useErrorDialogs: false,
          // The sheet pauses the app: retry on foregrounding instead of failing on backgrounding.
          stickyAuth: true,
        ),
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.cancelled;
    } on PlatformException catch (e) {
      return switch (e.code) {
        auth_error.lockedOut || auth_error.permanentlyLockedOut => BiometricOutcome.lockedOut,
        auth_error.notAvailable ||
        auth_error.notEnrolled ||
        auth_error.passcodeNotSet ||
        auth_error.otherOperatingSystem => BiometricOutcome.unavailable,
        _ => BiometricOutcome.failed,
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

- 2.x returns `false` when the person did not pass **without** saying whether they cancelled, so this recipe answers
  `cancelled` for `false`; the unlock page treats it as "try again" either way.
- **Android**: the main activity extends `FlutterFragmentActivity`; the manifest has `USE_BIOMETRIC`; the activity theme
  is an `AppCompat` one. **iOS**: `NSFaceIDUsageDescription` in `Info.plist`.
- The error codes are strings (`error_codes.dart`), so a typo is a silent `failed`: keep the constants.
