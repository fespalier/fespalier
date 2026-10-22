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
`local_auth` majors cannot share one source. It depends on `clock` and fespalier, starts no timer and adds no listener (the idle lock's ticker is the app's).

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

| Piece                                                                                              | What it does                                                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BiometricPrompt`, `biometricPrompt`                                                               | The platform check: `isAvailable()` and `authenticate(reason)` returning a `BiometricOutcome` (`success`, `cancelled`, `failed`, `unavailable`, `lockedOut`). The provider throws until `startup()` overrides it     |
| `biometricUnlock`, `BiometricUnlock`                                                               | The state (`Locked`, `Unlocking`, `Unlocked(at)`) and its notifier: `unlock(reason)`, `lock()`, `isFresh({maxAge})`                                                                                                  |
| `requireUnlocked(ref, uri, unlock:, maxAge:)`                                                      | The guard: `null` while unlocked, else the unlock page's location with `from`. Synchronous, never prompts                                                                                                            |
| `withBiometrics(ref, reason, action, maxAge:)`                                                     | For an action: prompts unless the unlock is younger than `maxAge` (default: always), throws `BiometricDeclined(outcome)` when it does not pass                                                                       |
| `biometricPolicy`, `BiometricPolicy(resumeGrace:, idleTimeout:)`                                   | When the app relocks: on a return from the background 10 seconds or more after the unlock (`Duration.zero` is every return), and, since 0.19.0, after `idleTimeout` without a touch (null, off, by default)          |
| `biometricIdleTicker`, `BiometricActivity` (since 0.19.0)                                          | The idle lock: a signal the app fires from its own timer, and the widget that records touches and absorbs the first one after the limit. `BiometricUnlock.touch()` and `isIdle()`                                    |
| `biometricAvailable`                                                                               | `FutureProvider<bool>` for the unlock page ("Use your passcode" instead of a button that cannot work); a prompt that throws is an `AsyncError`, never retried (since 0.16.0)                                         |
| `BiometricLockScreen`, `BiometricLockScreenMessages` (since 0.19.0)                                | `package:fespalier_biometrics/material.dart`, the one Material library: an unlock page body whose button prompts on a tap and never otherwise; the `unavailable` builder; replaceable words                          |
| `BiometricSecrets`, `biometricSecrets`, `readSecret`, `writeSecret`, `deleteSecret` (since 0.19.0) | A secret behind the biometric, gated by the keystore ([`biometric-secrets.md`](biometric-secrets.md)): `SecretFound`, `SecretMissing`, `SecretRefused(outcome)`; one sheet at a time; a read does not unlock the app |
| `FakeBiometricPrompt`, `FakeBiometricSecrets`, `biometricTestOverrides`                            | `package:fespalier_biometrics/testing.dart`: queued outcomes, `prompts` count, `hold()` and `release()` for a sheet that is up                                                                                       |

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
import 'package:fespalier_biometrics/material.dart';
import 'package:flutter/material.dart';

/// The body is `BiometricLockScreen` (since 0.19.0): the button, the words for a failed or locked-out try, the
/// "cannot ask" case. It prompts on a tap and never otherwise. Without Material, call
/// `ref.read(biometricUnlock.notifier).unlock(reason)` from your own button.
class UnlockPage extends StatelessWidget {
  const UnlockPage({super.key, this.from});

  /// Where the guard that sent us here was going.
  final String? from;

  @override
  Widget build(BuildContext context) => BiometricLockScreen(
    reason: 'Unlock your vault',
    // The page navigates: nothing watches the unlock for it. returnTo ignores a `from` that leaves the app.
    onUnlocked: () => context.go(returnTo(from)),
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

## A ready-made unlock page (since 0.19.0)

`BiometricLockScreen` (`import 'package:fespalier_biometrics/material.dart'`, the only library of the package that imports
Material; the main one stays free of it) is the body of the unlock page, as the starter above uses it:

```dart
BiometricLockScreen(
  reason: 'Unlock your vault',          // what the platform's sheet says
  onUnlocked: () => context.go(returnTo(from)),
  title: const Text('Vault'),           // optional
  unavailable: (context) => const Text('Use your passcode'), // optional: instead of the button
  messages: const BiometricLockScreenMessages(unlock: 'Deverrouiller'), // optional: another language
)
```

- **It prompts on a tap and never otherwise.** Not in `build` (a rebuild is never a prompt), and not after the first frame:
  the package schedules no frame (`addPostFrameCallback` is forbidden by `test/no_timers_test.dart`).
- The button is disabled while a sheet is up. `failed` and `lockedOut` show `messages.failed` and `messages.lockedOut`; a
  `cancelled` shows nothing. When `biometricAvailable` answers `false` (or a tap ends `unavailable`) the button gives way
  to `unavailable` (default: `messages.unavailable` as a `Text`); while the answer is pending, or if the plugin threw, the
  button stays and a tap reports what happened.
- It opens no dialog, route, menu, sheet or snack bar: the platform's own sheet is the prompt.
- Rejected on purpose: a `BiometricGate` that overlays the whole app when locked. It is a second way to say "locked"
  beside the guard, and a subtree parked under an overlay keeps its secrets in memory.

**Asking as soon as the page opens** is the unlock folder's own `observe.dart` `onEnter` (fespalier runs it after the
frame, never in `build`), and the page leaves with a `ref.listen` on `biometricUnlock` because a hook has no
`BuildContext`. It prompts on every entry, so it is a separate compiled app, not part of the starter above:
[`biometric-lock-screen.md`](biometric-lock-screen.md) has the hook, the page that replaces the starter's, and the test.
The screen shows the outcome of a prompt **it** started: a prompt the hook started that ends `failed`, `lockedOut` or
`unavailable` shows no message, and a tap during the hook's sheet joins it (single flight), so it is still one sheet.
Built already unlocked, the screen shows the button and a tap prompts again.

Unchecked on a device: an `onEnter` prompt on a cold start and right after a relock on resume (iOS may refuse a prompt
while the app is not yet active), the grace with the sheet hiding the app, and VoiceOver and TalkBack on the screen.

## Idle lock (since 0.19.0)

`BiometricPolicy(idleTimeout: Duration(minutes: 2))` locks an unlocked app that nobody touched for that long. Off by
default, so an app that does not set it changes nothing. **The package starts no timer** (`test/no_timers_test.dart` has
no exception for it): the app fires `biometricIdleTicker` from its own `Timer.periodic`, and the package measures time
with `clock`. Three pieces:

- **`BiometricActivity`** in `MaterialApp.router(builder:)`: a `Listener` (pointer down and signal) and a
  `Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent:)` that answers `ignored` call `touch()`, which writes a
  field and not state (no rebuild per touch). A key is seen only when a widget below holds the focus; trackpad pan/zoom starts count too; **soft-keyboard typing does not**.
- **The ticker**: on a tick, `BiometricUnlock` locks when `now - max(unlock, last touch) >= idleTimeout` (a negative age,
  a clock set back, counts as idle). Fire it at most `idleTimeout / 4` apart and **not while the app is hidden**; an
  `idleTimeout` shorter than the period locks late by up to one period. A tick that keeps the unlock tells no listener.
- **The first touch after the limit is absorbed.** Once the limit has passed (by the clock, so right even when the ticker
  is late or the app has none), `BiometricActivity` hit-tests the touch to a box above the page and not to the page, and
  locks on it: the button under the finger is not pressed. Pointer routes are fixed at hit-test time, so a lock from
  `onPointerDown` alone would let that touch through. The box has `hitTest` and `handleEvent` and nothing else.

`requireUnlocked` and `isFresh` treat an idle unlock as locked synchronously, so the next navigation lands on the unlock
page with no tick. `touch()` after the limit does not bring an expired unlock back; a tick during a prompt keeps the
prompt, and a lock that was due applies when it ends without a success. A new `unlock()` starts the idle clock afresh.

The ticker recipe, compiled: a widget for the `builder:` that owns the periodic timer, pauses it while the app is hidden
and fires one tick when it comes back (the age is the clock's, so the lock is prompt). Soft-keyboard typing is not activity: a text field calls `ref.read(biometricUnlock.notifier).touch()` from `onChanged`.

```dart
// lib/idle/idle_lock.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:flutter/widgets.dart';

/// The app's idle limit, and the ticker's period: at most a quarter of it.
const idleTimeout = Duration(minutes: 2);
const idlePeriod = Duration(seconds: 30);

/// Use in `MaterialApp.router(builder: (context, child) => IdleLock(child: child!))`, and give
/// `biometricPolicy` `BiometricPolicy(idleTimeout: idleTimeout)` in `startup()`.
class IdleLock extends ConsumerStatefulWidget {
  const IdleLock({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IdleLock> createState() => _IdleLockState();
}

class _IdleLockState extends ConsumerState<IdleLock> with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer ??= Timer.periodic(idlePeriod, (_) => _tick());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() => ref.read(biometricIdleTicker.notifier).fire();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
        // Back from the background Flutter reports hidden, inactive, resumed: the first of these that
        // finds the timer stopped starts it and ticks once. The age is the clock's, so a due lock is prompt.
        final wasStopped = _timer == null;
        _start();
        if (wasStopped) _tick();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BiometricActivity(child: widget.child);
}
```

```dart
// test/idle_lock_test.dart
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/idle/idle_lock.dart';

void main() {
  testWidgets('the app\'s timer ticks, and a tick after the limit locks', (tester) async {
    var now = DateTime(2026, 10, 7, 9);
    await withClock(Clock(() => now), () async {
      final container = ProviderContainer(
        overrides: biometricTestOverrides(
          FakeBiometricPrompt(),
          policy: const BiometricPolicy(idleTimeout: idleTimeout),
        ),
      );
      addTearDown(container.dispose);
      container.listen(biometricUnlock, (_, _) {});
      await container.read(biometricUnlock.notifier).unlock('Unlock');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: IdleLock(child: Text('App')),
          ),
        ),
      );
      // A period before the limit: the timer ticks and the unlock stays.
      now = now.add(idlePeriod);
      await tester.pump(idlePeriod);
      expect(container.read(biometricUnlock), isA<Unlocked>());
      // Nobody touched the screen for the whole limit: the next tick locks.
      now = now.add(idleTimeout);
      await tester.pump(idlePeriod);
      expect(container.read(biometricUnlock), isA<Locked>());
      // Dispose the widget: the timer goes with it.
      await tester.pumpWidget(const SizedBox());
    });
  });
}
```

Test the ticker with `container.read(biometricIdleTicker.notifier).fire()` in a `ProviderContainer`, and the page-level
behaviour (a touch before and after the limit) with a widget test around `BiometricActivity` and a mutable clock, as the
package's own `test/idle_test.dart` does.

## Behaviour to rely on

- **A guard never prompts, and a guard that runs again never re-prompts.** The guard watches only whether the app is
  unlocked: a prompt coming and going (`Unlocking`) and a second `Unlocked` stamp do not run it. A lock (`lock()`, or the
  policy's relock) does, and the router leaves the page (a pushed page too, since 0.21.0). Ten re-runs
  of the guard are zero prompts (`test/guard_test.dart`).
- **`unlock()` is single-flight and never throws.** Two buttons, a double tap or a guard that runs again while a sheet is
  up get the same `Future`. A prompt that throws is `BiometricOutcome.failed`. A prompt that does not succeed leaves the
  state as it was before the call: locked stays locked, and an unlocked app whose `withBiometrics` was cancelled stays
  unlocked.
- **A prompt over an unlocked page does not move the page.** `Unlocking` carries `wasUnlocked`, and the guard treats it
  as unlocked, so `withBiometrics` on `/vault` does not send the person to the unlock page while the sheet is showing.
- **The unlock page navigates.** Nothing in the package watches the unlock for it; it calls `context.go(returnTo(from))` after a
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
- **The idle lock is evaluated too.** Without the app's ticker an idle unlock still ends at the next navigation
  (`requireUnlocked`, `isFresh`) and at the first touch after the limit (`BiometricActivity`); the ticker is what locks a
  screen nobody touches. Never put a `Timer` in the package or in core for it.
- **An expiry is evaluated, not scheduled.** `maxAge` is compared with `clock.now()` when a guard runs or `isFresh` is
  asked, that is at the next navigation (or a re-run of the guard), never by itself. A page left open stays open past
  its `maxAge`. A clock set back counts as expired for both `maxAge` and the grace.
- **Telemetry** (`fespalier.biometrics.prompt`, with `fespalier.biometrics.result` set to the outcome's name) is reported
  to an installed sink and nothing else: never the reason text. Outcomes map to `ok`, `cancelled`, `rejected` (failed,
  locked out), `skipped` (unavailable) and `error` (a prompt that threw). A secret read, write or delete (since 0.19.0) is
  `fespalier.biometrics.secret` with `fespalier.biometrics.secret_op` (`read`, `write`, `delete`) and the same
  `fespalier.biometrics.result` (`found`, `missing`, `success`, or an outcome's name): never the key, the value, the reason
  or the store's error, and a store that threw ends `error` with no error object.
- `appShowSignal` is core's, and an `autoDispose` provider: the unlock state keeps it alive for the app's life, which
  is one `AppLifecycleListener` core owns. A `ProviderContainer` test has no `WidgetsBinding`, which is what
  `biometricTestOverrides` replaces it for.

## Secrets (since 0.19.0)

[`biometric-secrets.md`](biometric-secrets.md) is the `flutter_secure_storage` recipe. `readSecret(key, reason)` goes
through one line of sheets with `unlock()`: it waits for an `unlock()` sheet that is up, two reads of one key share one
`Future`, and **it does not unlock the app** (no state change, no listener told), because a device-credential fallback
accepts a PIN and a read is consent to one value. The value is returned to the caller and held by no provider;
`SecretFound.toString()` hides it. A refusal is `SecretRefused(outcome)`, a store that throws is `SecretRefused(failed)`,
and `lock()` leaves stored secrets alone (delete them at sign-out with `deleteSecret`). A store that fails makes `deleteSecret`'s `Future` fail (the secret may still be there). An `unlock()` queued behind a read's sheet is `Unlocking` at once, and a store that never answers blocks every later `unlock()` (no timer is allowed to cut it).

## Traps

- **A `requireUnlocked` on the unlock page.** `unlock/` sits beside the guarded folder, not in it, or the guard redirects to the
  page that redirects.
- **Calling `unlock()` from `build` or from a guard.** That is the prompt-on-rerun bug this package exists to prevent.
  Call it from an event handler (`BiometricLockScreen`'s button is one) or an `observe.dart` `onEnter`. A guard that must stay `FutureOr<String?>` never awaits a prompt.
- **A secret kept after a lock.** Locking does not clear data providers: a `data.dart` that loaded the vault stays in
  memory, and the app decides whether to invalidate it (`ref.invalidate`) when `biometricUnlock` goes to `Locked`.
- **A biometric check is not authentication to a server.** It proves a person is at the phone; it signs nothing. Use
  [`fespalier_sign_keypair`](auth-dpop.md) for a key the server can verify.

## Testing

`FakeBiometricPrompt` answers from a queue (`outcomes:`, then `fallback`, default `success`), counts `prompts` and records
`reasons`; `hold()` keeps the next sheet "up" until `release([outcome])`, so a test can call `unlock` twice. In a
`pumpRouter` test pass `biometricTestOverrides(prompt, policy: ...)`; with a `ProviderContainer`, the same list, and fire
the resume yourself: `container.read(appShowSignal.notifier).fire()` inside `withClock(Clock.fixed(...))` (`appShowSignal`, not `appResumeSignal`). `FakeBiometricSecrets` (a `stored` map, `outcomes`, `reads`/`writes`/`deletes`, `hold()`/`release()`, `throws`) goes in with
`biometricTestOverrides(prompt, secrets: fake)`. Without
overriding `biometricPrompt`, reading it throws `fespalier_biometrics: override biometricPrompt in startup()`.
