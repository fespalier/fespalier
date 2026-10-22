# fespalier_biometrics

Biometric unlock for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0): a guard that **never prompts**
(`requireUnlocked` reads the unlock state and redirects to the app's unlock page), one single-flight `unlock()` that the
unlock page calls, `withBiometrics` for an action that must ask again, a relock when the app comes back from the background, and (since 0.19.0) an idle lock and secrets kept behind the biometric. The platform check
(`local_auth`) is a recipe, not a dependency: the package has no platform code, starts no timer and adds no listener.

The docs cover all of it: [Biometric unlock](https://github.com/fespalier/fespalier/blob/main/docs/guards.md#biometric-unlock-fespalier_biometrics)
(the unlock page, actions, relock, testing). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.21.0
  fespalier_biometrics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_biometrics
      ref: v0.21.0
```

<!-- x-release-please-end -->

## Wire it

```dart
// lib/app/startup.dart: your BiometricPrompt (a local_auth recipe, ~25 lines)
Future<List<Override>> startup() async => [
  biometricPrompt.overrideWithValue(const LocalAuthPrompt()),
];

// lib/app/vault/guard.dart: never prompts; sends the person to the unlock page
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireUnlocked(ref, uri, unlock: (from) => UnlockRoute(from: from));

// lib/app/unlock/page.dart: the only place that prompts
final outcome = await ref.read(biometricUnlock.notifier).unlock('Unlock your vault');
if (outcome == BiometricOutcome.success && context.mounted) context.go(returnTo(from));

// lib/app/vault/reveal/action.dart: asks again, whatever the unlock
Future<String> action(Ref ref, {required String input}) =>
    withBiometrics(ref, 'Show the card number', () => loadCardNumber(ref));
```

The `local_auth` 3.x recipe is the fespalier-guards skill's `biometric-prompts.md` and the 2.x one
`biometric-prompts-local-auth-2.md` (2.x for Flutter before 3.38: the two majors cannot share one source).

## A ready-made unlock page (since 0.19.0)

`package:fespalier_biometrics/material.dart` (the only library here that imports Material) has `BiometricLockScreen`, the
body of the unlock page: a button that prompts **when tapped and never otherwise**, the words for a failed or locked-out
try (`BiometricLockScreenMessages`, for another language), and an `unavailable:` builder for a device that cannot ask. It
opens no dialog, route or snack bar. To ask as the page opens, use the unlock folder's `observe.dart` `onEnter`.

```dart
BiometricLockScreen(
  reason: 'Unlock your vault',
  onUnlocked: () => context.go(returnTo(from)),
)
```

## Idle lock (since 0.19.0)

`BiometricPolicy(idleTimeout:)` locks after that long without a touch or a hardware key. Soft-keyboard typing is not activity: a text field calls
`ref.read(biometricUnlock.notifier).touch()` from `onChanged`. Off by default. The app puts
`BiometricActivity` in `MaterialApp.router(builder:)` and fires `biometricIdleTicker` from its own `Timer.periodic`
(at most `idleTimeout / 4` apart, stopped while hidden); the first touch after the limit is absorbed, so it never
reaches the page under it, and locks. `requireUnlocked` and `isFresh` treat an idle unlock as locked at once. The
fespalier-guards skill has the ticker recipe, and the docs' [Idle lock](https://github.com/fespalier/fespalier/blob/main/docs/guards.md#idle-lock) the rest.

## Test it

```dart
final prompt = FakeBiometricPrompt();
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/vault'),
  overrides: biometricTestOverrides(prompt),
);
expect(currentLocation(tester), startsWith('/unlock')); // locked: redirected
expect(prompt.prompts, 0); // and nothing was prompted
```

`package:fespalier_biometrics/testing.dart` has `FakeBiometricPrompt` (queued outcomes, a `prompts` count, `hold()` and
`release()` for a sheet that is up) and `biometricTestOverrides`.

## Rules

- **A guard never prompts.** A guard that runs again, for any reason, cannot show a second sheet; only `unlock()` and
  `withBiometrics` prompt, single-flight.
- **No timer, no listener.** The idle lock's ticker is the app's. The relock is a watch of core's `appShowSignal` (the app shown again after being hidden, not
  just inactive); an expiry (`maxAge`) is evaluated when a guard next runs, never by itself. `test/no_timers_test.dart` greps `lib/` for it.
- **Telemetry is constants only:** `fespalier.biometrics.prompt` with `fespalier.biometrics.result` (the outcome's name).
  Never the reason text.
- Not built: a passcode of the app's own.

## Secrets behind the biometric (since 0.19.0)

`ref.read(biometricUnlock.notifier).readSecret(key, reason)` reads a value the **keystore** gates (it asks for the
biometric as part of decrypting the item), and answers `SecretFound(value)`, `SecretMissing()` or `SecretRefused(outcome)`;
`writeSecret` and `deleteSecret` are its pair. You write a `BiometricSecrets` once and override `biometricSecrets` in
`startup()`; the package depends on no plugin, and the `flutter_secure_storage` recipe is the fespalier-guards skill's
`biometric-secrets.md`. One sheet at a time (a read waits for an `unlock()` sheet, two reads of one key share one), **a read
does not unlock the app**, the value goes to the caller only, and telemetry carries constants only. `FakeBiometricSecrets` is
in `testing.dart`. The docs' [Secrets behind the biometric](https://github.com/fespalier/fespalier/blob/main/docs/guards.md#secrets-behind-the-biometric) has the rest.
