# fespalier_biometrics

Biometric unlock for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0): a guard that **never prompts**
(`requireUnlocked` reads the unlock state and redirects to the app's unlock page), one single-flight `unlock()` that the
unlock page calls, `withBiometrics` for an action that must ask again, and a relock on resume. The platform check
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
      ref: v0.12.0
  fespalier_biometrics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_biometrics
      ref: v0.12.0
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
`biometric-prompts-local-auth-2.md` (2.x for Flutter before 3.35: the two majors cannot share one source).

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
- **No timer, no listener.** The relock is a watch of core's `appResumeSignal`; an expiry (`maxAge`) is evaluated at the
  next navigation or resume, never by itself. `test/no_timers_test.dart` greps `lib/` for it.
- **Telemetry is constants only:** `fespalier.biometrics.prompt` with `fespalier.biometrics.result` (the outcome's name).
  Never the reason text.
- Not built: a lock screen widget, a passcode of the app's own, storing a secret behind the biometric (that is a
  keystore's job), a timer-based idle lock.
