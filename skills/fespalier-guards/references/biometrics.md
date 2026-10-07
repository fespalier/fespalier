# `fespalier_biometrics`: an unlock guard that never prompts

Since 0.13.0. A route behind a biometric check (an orders list, a wallet, a secret) needs three things that must not be
mixed up: a **state** (is the app unlocked), a **guard** (send the person to the unlock page when it is not) and **one
function that prompts** (`unlock()`, called by the unlock page or an action). `package:fespalier_biometrics` keeps them
apart on purpose: **a guard never prompts.** A guard runs again whenever something it watches changes, on every
navigation and on a cold deep link; a guard that showed the platform's sheet would show it again each time. This one
reads the state and redirects, and only an explicit `unlock()` prompts, **single-flight** (a second call while a sheet is
up gets the same `Future`).

The package has no platform code and no `local_auth` dependency: the platform check is a `BiometricPrompt` the app writes
once, a recipe of about 25 lines in [`biometric-prompts.md`](biometric-prompts.md) (`local_auth` 3.x) or
[`biometric-prompts-local-auth-2.md`](biometric-prompts-local-auth-2.md) (2.x, for Flutter before 3.38), because the two
`local_auth` majors cannot share one source. It depends on `clock` and fespalier, starts no timer and adds no listener.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_biometrics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_biometrics
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. `docs/guards.md` has the annotated block.)

## What it is made of

| Piece                                              | What it does                                                                                                                                                                                                     |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BiometricPrompt`, `biometricPrompt`               | The platform check: `isAvailable()` and `authenticate(reason)` returning a `BiometricOutcome` (`success`, `cancelled`, `failed`, `unavailable`, `lockedOut`). The provider throws until `startup()` overrides it |
| `biometricUnlock`, `BiometricUnlock`               | The state (`Locked`, `Unlocking`, `Unlocked(at)`) and its notifier: `unlock(reason)`, `lock()`, `isFresh({maxAge})`                                                                                              |
| `requireUnlocked(ref, uri, unlock:, maxAge:)`      | The guard: `null` while unlocked, else the unlock page's location with `from`. Synchronous, never prompts                                                                                                        |
| `withBiometrics(ref, reason, action, maxAge:)`     | For an action: prompts unless the unlock is younger than `maxAge` (default: always), throws `BiometricDeclined(outcome)` when it does not pass                                                                   |
| `biometricPolicy`, `BiometricPolicy(resumeGrace:)` | When the app relocks on a return from the background. Default: 10 seconds or more after the unlock; `Duration.zero` is every return                                                                              |
| `biometricAvailable`                               | `FutureProvider<bool>` for the unlock page ("Use your passcode" instead of a button that cannot work)                                                                                                            |
| `FakeBiometricPrompt`, `biometricTestOverrides`    | `package:fespalier_biometrics/testing.dart`: queued outcomes, `prompts` count, `hold()` and `release()` for a sheet that is up                                                                                   |

## The starter

A guarded folder, the unlock page beside it (a guard on the unlock page would redirect to itself), an action that asks
again, and the test. The prompt is the app's: this page uses a fake, [`biometric-prompts.md`](biometric-prompts.md) has the
real one.

```dart
// lib/app/vault/page.dart
import 'package:flutter/material.dart';

class VaultPage extends StatelessWidget {
  const VaultPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Vault');
}
```

```dart
// lib/app/vault/guard.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:my_app/app.g.dart';

/// Guards /vault and everything below it. Synchronous, so a cold deep link shows the unlock page in its first frame,
/// and it never prompts: the unlock page does. `maxAge` makes an unlock older than five minutes count as locked at the
/// next navigation (there is no timer, so a page already open stays open).
GuardResult guard(Ref ref, {required Uri uri}) => requireUnlocked(
  ref,
  uri,
  unlock: (from) => UnlockRoute(from: from),
  maxAge: const Duration(minutes: 5),
);
```

```dart
// lib/app/unlock/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:flutter/material.dart';

class UnlockPage extends ConsumerWidget {
  const UnlockPage({super.key, this.from});

  /// Where the guard that sent us here was going.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton(
    onPressed: () async {
      final outcome = await ref.read(biometricUnlock.notifier).unlock('Unlock your vault');
      // The page navigates: nothing watches the unlock for it. returnTo ignores a `from` that leaves the app.
      if (outcome == BiometricOutcome.success && context.mounted) {
        context.go(returnTo(from));
      }
    },
    child: const Text('Unlock'),
  );
}
```

```dart
// lib/app/vault/reveal/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';

/// Asks again, whatever the unlock: the default `maxAge` is zero. A cancel throws BiometricDeclined, which is the
/// action's error like any other.
Future<String> action(Ref ref, {required String input}) =>
    withBiometrics(ref, 'Show the card number', () => '4242 4242 4242 4242');
```

```dart
// lib/app/vault/reveal/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class RevealPage extends ConsumerWidget {
  const RevealPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reveal = RevealRoute.useAction(ref);
    return Column(
      children: [
        FilledButton(
          onPressed: reveal.isPending ? null : () => reveal.call('card'),
          child: const Text('Reveal'),
        ),
        if (reveal.state.value case final number?) Text(number),
        if (reveal.hasError) const Text('Not shown'),
      ],
    );
  }
}
```

```yaml
# pubspec.yaml dependencies
  clock: ^1.1.1
```

```dart
// test/vault_test.dart
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_biometrics/testing.dart'; // also exports BiometricOutcome
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('locked: the vault sends the person to unlock, and nothing is prompted', (tester) async {
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    expect(currentLocation(tester), startsWith('/unlock'));
    expect(prompt.prompts, 0);
  });

  testWidgets('unlocking goes back to where the guard was going, with one prompt', (tester) async {
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/vault');
    expect(prompt.prompts, 1);
    expect(prompt.reasons, ['Unlock your vault']);
  });

  testWidgets('a cancel stays on the unlock page', (tester) async {
    final prompt = FakeBiometricPrompt(outcomes: [BiometricOutcome.cancelled]);
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), startsWith('/unlock'));
  });

  testWidgets('the reveal action asks again even when unlocked', (tester) async {
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    GoRouter.of(tester.element(find.text('Vault'))).go('/vault/reveal');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reveal'));
    await tester.pumpAndSettle();
    expect(find.text('4242 4242 4242 4242'), findsOneWidget);
    expect(prompt.prompts, 2);
  });

  testWidgets('an unlock older than maxAge sends the next navigation to unlock', (tester) async {
    final start = DateTime(2026, 10, 7, 9);
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    await withClock(Clock.fixed(start), () async {
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
    });
    expect(currentLocation(tester), '/vault');
    final router = GoRouter.of(tester.element(find.text('Vault')));
    router.go('/');
    await tester.pumpAndSettle();
    withClock(Clock.fixed(start.add(const Duration(minutes: 6))), () => router.go('/vault'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), startsWith('/unlock'));
  });
}
```

```dart
// in lib/app/startup.dart (a fragment: LocalAuthPrompt is the class of biometric-prompts.md)
Future<List<Override>> startup() async => [
  biometricPrompt.overrideWithValue(const LocalAuthPrompt()),
];
```

## Behaviour to rely on

- **A guard never prompts, and a guard that runs again never re-prompts.** The guard watches only whether the app is
  unlocked: a prompt coming and going (`Unlocking`) and a second `Unlocked` stamp do not run it. A lock (`lock()`, or the
  policy's relock) does, and the router leaves the page. Ten re-runs of the guard are zero prompts
  (`test/guard_test.dart`).
- **`unlock()` is single-flight and never throws.** Two buttons, a double tap or a guard that runs again while a sheet is
  up get the same `Future`. A prompt that throws is `BiometricOutcome.failed`. A prompt that does not succeed leaves the
  state as it was before the call: locked stays locked, and an unlocked app whose `withBiometrics` was cancelled stays
  unlocked.
- **A prompt over an unlocked page does not move the page.** `Unlocking` carries `wasUnlocked`, and the guard treats it
  as unlocked, so `withBiometrics` on `/vault` does not send the person to the unlock page while the sheet is showing.
- **The unlock page navigates.** Nothing watches the unlock for it; it calls `context.go(returnTo(from))` after a
  success. `returnTo` ignores a `from` that is not a path in the app.
- **Relock when the app comes back, with no timer and no listener.** `BiometricUnlock` watches core's `appShowSignal`
  (since 0.13.0: `onShow`, visible again **after being hidden**), so a return from the background runs its `build`
  again; it goes back to `Locked` when the return is at least `resumeGrace` after the unlock. It is not
  `appResumeSignal`: a notification shade, Control Center, a call banner and the platform's own biometric sheet go
  inactive and back, and none of them relocks. A return while a sheet is up never drops the prompt, and one past the
  grace still relocks when the sheet ends without a success.
- **The default grace is a trade-off.** 10 seconds, not zero, because the platform's sheet and some system overlays can
  hide the app and show it just after the answer: with `Duration.zero` the sheet could undo its own unlock. The price is
  a 10-second window after each unlock in which leaving the app and coming back asks nothing. Guard something worth
  more with a shorter grace or zero, and check on a device.
- **An expiry is evaluated, not scheduled.** `maxAge` is compared with `clock.now()` when a guard runs or `isFresh` is
  asked, that is at the next navigation (or a re-run of the guard), never by itself. A page left open stays open past
  its `maxAge`. A clock set back counts as expired for both `maxAge` and the grace.
- **Telemetry** (`fespalier.biometrics.prompt`, with `fespalier.biometrics.result` set to the outcome's name) is reported
  to an installed sink and nothing else: never the reason text. Outcomes map to `ok`, `cancelled`, `rejected` (failed,
  locked out), `skipped` (unavailable) and `error` (a prompt that threw).
- `appShowSignal` is core's, and an `autoDispose` provider: the unlock state keeps it alive for the app's life, which
  is one `AppLifecycleListener` core owns. A `ProviderContainer` test has no `WidgetsBinding`, which is what
  `biometricTestOverrides` replaces it for.

## Traps

- **A guard on the unlock page.** `unlock/` sits beside the guarded folder, not in it, or the guard redirects to the
  page that redirects.
- **Calling `unlock()` from `build` or from a guard.** That is the prompt-on-rerun bug this package exists to prevent.
  Call it from an event handler. A guard that must stay `FutureOr<String?>` never awaits a prompt.
- **A secret kept after a lock.** Locking does not clear data providers: a `data.dart` that loaded the vault stays in
  memory, and the app decides whether to invalidate it (`ref.invalidate`) when `biometricUnlock` goes to `Locked`.
- **A biometric check is not authentication to a server.** It proves a person is at the phone; it signs nothing. Use
  [`fespalier_sign_keypair`](auth-dpop.md) for a key the server can verify.

## Testing

`FakeBiometricPrompt` answers from a queue (`outcomes:`, then `fallback`, default `success`), counts `prompts` and records
`reasons`; `hold()` keeps the next sheet "up" until `release([outcome])`, so a test can call `unlock` twice. In a
`pumpRouter` test pass `biometricTestOverrides(prompt, policy: ...)`; with a `ProviderContainer`, the same list, and fire
the resume yourself: `container.read(appResumeSignal.notifier).fire()` inside `withClock(Clock.fixed(...))`. Without
overriding `biometricPrompt`, reading it throws `fespalier_biometrics: override biometricPrompt in startup()`.
