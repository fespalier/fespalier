# Secrets behind the biometric: `flutter_secure_storage`

Since 0.19.0. A [`BiometricSecrets`](biometrics.md) is four methods: the port `BiometricUnlock.readSecret`,
`writeSecret` and `deleteSecret` call, and `flutter_secure_storage` is the plugin that implements them. It is a **recipe,
not a dependency of `fespalier_biometrics`**, like `local_auth` ([`biometric-prompts.md`](biometric-prompts.md)): the
package has no platform code, and an app that keeps its secrets with another keystore plugin should not link this one.

**Why the keystore, and not `unlock()`.** A value hidden behind `unlock()` in Dart is plain text in the app's memory or
disk, readable by any code that skips the guard (a debugger, a bug, a plugin). An item the _keystore_ gates cannot be
decrypted without the OS check: iOS asks for it as part of the keychain read (`accessControlFlags`), and Android's
AES key is created with `setUserAuthenticationRequired` (`AndroidOptions.biometric(enforceBiometrics: true)`). The plugin
shows the OS's own sheet on read, so `BiometricSecrets.read` does not call `BiometricPrompt` at all.

The sample is built by `just skill-samples` (`fsp gen`, `flutter analyze`, `flutter test`), against the real plugin;
nothing runs the plugin at test time (a keystore needs a device). Last built on 2026-10-17 against
`flutter_secure_storage` 11.2.0 (`flutter_secure_storage_darwin` 0.4.3). Its floor is the plugin's: Dart 3.8 and
Flutter 3.32, so Flutter 3.35 is fine.

```yaml
# pubspec.yaml dependencies
  flutter_secure_storage: ^11.2.0
```

```dart
// lib/biometric_secrets.dart
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secrets the keystore gates: the platform asks for a biometric as part of the read. Never a Flutter dialog.
final class SecureStorageSecrets extends BiometricSecrets {
  /// [prompt] only answers [isAvailable] (the plugin cannot say whether it would work); it never prompts.
  /// With [strongBiometricOnly], Android refuses a PIN or pattern.
  const SecureStorageSecrets(this.prompt, {this.strongBiometricOnly = false});

  /// The app's own `BiometricPrompt` (the `local_auth` recipe), asked only `isAvailable()`.
  final BiometricPrompt prompt;

  /// True: Android accepts a fingerprint or a face and nothing else.
  final bool strongBiometricOnly;

  // The item is bound to the biometrics enrolled when it was written: a new finger makes it unreadable.
  static const _ios = IOSOptions(
    accessibility: KeychainAccessibility.passcode,
    accessControlFlags: [AccessControlFlag.biometryCurrentSet],
  );

  FlutterSecureStorage get _storage => FlutterSecureStorage(
    iOptions: _ios,
    aOptions: AndroidOptions.biometric(
      enforceBiometrics: true,
      // 11.2.0: a sheet for every read. Without it the key stays open after the first one.
      requireBiometricsPerOperation: true,
      biometricType: strongBiometricOnly
          ? AndroidBiometricType.strongBiometricOnly
          : AndroidBiometricType.biometricOrDeviceCredential,
      // The plugin's default is true: any unexpected error then ERASES every stored secret.
      resetOnError: false,
      biometricPromptTitle: 'Confirm it is you',
      // Required with strongBiometricOnly, and on Android 10 and lower.
      biometricPromptNegativeButton: 'Cancel',
    ),
  );

  @override
  Future<bool> isAvailable() => prompt.isAvailable();

  // The plugin takes no reason: the iOS sheet is the system's, and Android's title is in the options above.
  @override
  Future<SecretRead> read(String key, {required String reason}) async {
    try {
      final value = await _storage.read(key: key);
      return value == null ? const SecretMissing() : SecretFound(value);
    } on PlatformException catch (e) {
      // Item gone, or invalidated by a new enrolment: the same answer as never written.
      if (isItemNotFound(e)) return const SecretMissing();
      return SecretRefused(outcomeOf(e));
    }
  }

  @override
  Future<BiometricOutcome> write(
    String key,
    String value, {
    required String reason,
  }) async {
    try {
      await _storage.write(key: key, value: value);
      return BiometricOutcome.success;
    } on PlatformException catch (e) {
      return outcomeOf(e);
    }
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// errSecItemNotFound, what iOS answers for a missing item or one a new enrolment invalidated.
bool isItemNotFound(PlatformException e) => e.details == -25300;

/// How a plugin error maps to an outcome. Only codes and numbers are read, never the text (it can
/// name the key), and nothing here logs the error.
BiometricOutcome outcomeOf(PlatformException e) {
  // iOS: code "Unexpected security result code", details the OSStatus.
  final status = e.details;
  if (status is int) {
    return switch (status) {
      -128 => BiometricOutcome.cancelled, // errSecUserCanceled
      -25291 || -25308 => BiometricOutcome.unavailable, // not available, UI not allowed
      _ => BiometricOutcome.failed, // errSecAuthFailed (-25293) and the rest
    };
  }
  // Android: code "Exception encountered", the message "Biometric authentication error [10]: ..." or
  // "BIOMETRIC_UNAVAILABLE: ...", the BiometricPrompt error constant in brackets.
  final message = e.message ?? '';
  if (message.startsWith('BIOMETRIC_UNAVAILABLE')) {
    return BiometricOutcome.unavailable;
  }
  final code = RegExp(r'Biometric authentication error \[(\d+)\]')
      .firstMatch(message)
      ?.group(1);
  return switch (code) {
    '5' || '10' || '13' => BiometricOutcome.cancelled, // CANCELED, USER_CANCELED, NEGATIVE_BUTTON
    '7' || '9' => BiometricOutcome.lockedOut, // LOCKOUT, LOCKOUT_PERMANENT
    '1' || '11' || '12' || '14' => BiometricOutcome.unavailable, // HW_UNAVAILABLE, NO_BIOMETRICS, HW_NOT_PRESENT, NO_DEVICE_CREDENTIAL
    _ => BiometricOutcome.failed,
  };
}
```

```dart
// test/biometric_secrets_test.dart
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/biometric_secrets.dart';

void main() {
  test('the recipe is a const BiometricSecrets, built without touching the plugin', () {
    final secrets = SecureStorageSecrets(FakeBiometricPrompt());
    expect(secrets, isA<BiometricSecrets>());
    expect(secrets.strongBiometricOnly, isFalse);
  });

  test('plugin errors map to outcomes by code, never by text', () {
    PlatformException ios(int status) => PlatformException(
      code: 'Unexpected security result code',
      message: 'names the key',
      details: status,
    );
    PlatformException android(String message) =>
        PlatformException(code: 'Exception encountered', message: message);

    expect(outcomeOf(ios(-128)), BiometricOutcome.cancelled);
    expect(outcomeOf(ios(-25293)), BiometricOutcome.failed);
    expect(outcomeOf(ios(-25308)), BiometricOutcome.unavailable);
    expect(isItemNotFound(ios(-25300)), isTrue);
    expect(outcomeOf(android('Biometric authentication error [10]: x')), BiometricOutcome.cancelled);
    expect(outcomeOf(android('Biometric authentication error [7]: x')), BiometricOutcome.lockedOut);
    expect(outcomeOf(android('BIOMETRIC_UNAVAILABLE: No fingerprint')), BiometricOutcome.unavailable);
    expect(outcomeOf(android('anything else')), BiometricOutcome.failed);
  });

  test('the app uses the fake in tests, wired as biometricSecrets', () async {
    final secrets = FakeBiometricSecrets(stored: {'token': 'abc'});
    final container = ProviderContainer(
      overrides: biometricTestOverrides(FakeBiometricPrompt(), secrets: secrets),
    );
    addTearDown(container.dispose);
    container.listen(biometricUnlock, (_, _) {});
    final read = await container
        .read(biometricUnlock.notifier)
        .readSecret('token', 'Show the token');
    expect((read as SecretFound).value, 'abc');
  });
}
```

Wire it in `startup()`, next to the prompt (the same `LocalAuthPrompt`, which answers `isAvailable()`):

```dart
// in startup(): a fragment, not a sample
const prompt = LocalAuthPrompt(biometricOnly: true);
return [
  biometricPrompt.overrideWithValue(prompt),
  biometricSecrets.overrideWithValue(const SecureStorageSecrets(prompt)),
];
```

Read and write from an event handler, never from `build` or a guard:

```dart
final secret = await ref.read(biometricUnlock.notifier).readSecret('card', 'Show the card number');
switch (secret) {
  SecretFound(:final value) => showCard(value),
  SecretMissing() => askForTheCardAgain(),   // never saved, or a new finger was enrolled
  SecretRefused(:final outcome) => showWhy(outcome),
}
```

## Platform setup (the plugin's, not fespalier's)

The plugin's README per platform is the source; the parts that bite:

- **Android**: `USE_BIOMETRIC` in the manifest, and the main activity extends `FlutterFragmentActivity`, the same as for
  `local_auth`. `enforceBiometrics: true` needs Android 9 (API 28), and `strongBiometricOnly` is only fully enforced from
  Android 11 (API 30); on Android 10 and lower a PIN is never accepted, whatever `biometricType` says.
- **iOS**: `NSFaceIDUsageDescription` in `Info.plist`. A simulator needs a passcode and an enrolled face or finger, or
  the write fails (`unavailable` or `failed`).
- **macOS**: pass the same options as `mOptions: MacOsOptions(...)`; the keychain-sharing entitlement is the plugin's.

## What the answers mean

- A new finger or face enrolled after the write makes the iOS item unreadable with `biometryCurrentSet`; the keychain
  answers "not found", which the recipe returns as `SecretMissing`. The app asks for the secret again and writes it
  again. (`biometryAny` would survive a new enrolment: weaker.) UNCHECKED on a device.
- `biometricOrDeviceCredential` (the default) lets a person who knows the PIN read the secret: that is the Android
  setting for "any way the phone itself accepts". `strongBiometricOnly` is the stricter one. UNCHECKED on a device.
- The recipe keeps the plugin's `resetOnError` off: the default (true) deletes every stored secret after an unexpected
  Android error, which an app would rather decide itself (`deleteSecret` per key).
- Version 10.x of the plugin: `AndroidOptions.biometric(enforceBiometrics: true)` and `IOSOptions(accessControlFlags:)`
  are the same; `biometricType` exists from 10.3.0, and `requireBiometricsPerOperation` is **11.2.0 and newer**. Without
  it, Android keeps the key open in memory after the first authentication and later reads show no sheet until the
  process restarts: delete that line for 10.x, and treat the first read of a session as the only gated one.
- Reading a secret **does not unlock the app** (the state stays as it was), and the value is returned to the caller only.
  Locking leaves stored secrets alone; `deleteSecret` removes one, and sign-out should delete the account's.
