# `BiometricLockScreen` and the auto-prompt

Since 0.19.0. [`biometrics.md`](biometrics.md) has the package and its starter (a guarded `/vault`, an unlock page that
asks when the button is tapped). This page is the other shape: the unlock page asks **as it opens**, from its own
`observe.dart` `onEnter`, which fespalier runs after the frame and never in `build`. It is a separate app from the
starter because the hook prompts on every entry, so the starter's "nothing is prompted on a redirect" test would no
longer hold. In your app this **replaces** the starter's `lib/app/unlock/page.dart`; the guard is the starter's.

The hook has no `BuildContext`, so it cannot navigate: the page leaves when the app is unlocked, whoever asked (the hook
or a tap), with a `ref.listen` in the app's own page. The package has no listener.

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

GuardResult guard(Ref ref, {required Uri uri}) =>
    requireUnlocked(ref, uri, unlock: (from) => UnlockRoute(from: from));
```

```dart
// lib/app/unlock/observe.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';

/// Asks when the page opens, unless the app is already unlocked or a sheet is up. `unlock()` never throws.
void onEnter(Ref ref) {
  if (ref.read(biometricUnlock) is Locked) {
    ref.read(biometricUnlock.notifier).unlock('Unlock your vault');
  }
}
```

```dart
// lib/app/unlock/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/material.dart';
import 'package:flutter/material.dart';

class UnlockPage extends ConsumerWidget {
  const UnlockPage({super.key, this.from});

  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Whoever prompted, a hook or the button, the page leaves when the app is unlocked.
    ref.listen(biometricUnlock, (_, next) {
      if (next is Unlocked) context.go(returnTo(from));
    });
    return const BiometricLockScreen(
      reason: 'Unlock your vault',
      onUnlocked: _stay,
    );
  }
}

void _stay() {} // the listener above leaves the page
```

```dart
// test/auto_prompt_test.dart
import 'package:fespalier/testing.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('a redirect to the unlock page asks once, and success goes back', (tester) async {
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.pumpAndSettle();
    expect(prompt.prompts, 1);
    expect(currentLocation(tester), '/vault');
  });

  testWidgets('a cancelled prompt leaves the button, and a tap asks again', (tester) async {
    final prompt = FakeBiometricPrompt(outcomes: [BiometricOutcome.cancelled]);
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/vault'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.pumpAndSettle();
    expect(prompt.prompts, 1);
    expect(currentLocation(tester), startsWith('/unlock'));
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(prompt.prompts, 2);
    expect(currentLocation(tester), '/vault');
  });
}
```

What to know:

- **The screen shows the outcome of a prompt it started.** A prompt the hook started that ends `failed`, `lockedOut` or
  `unavailable` shows no message and does not switch to the `unavailable` builder; the button is the way to try again,
  and a tap during the hook's sheet joins it (`unlock()` is single-flight), so it is still one sheet.
- **Built already unlocked** (a URL visit), the screen shows the button and a tap prompts again
  (`Unlocking(wasUnlocked: true)`); the hook above skips an unlocked app.
- **After a relock** (the app comes back from the background past the grace), the guard sends the person here and the hook
  prompts right then. Whether iOS accepts a prompt at that moment, as at a cold start, is unchecked on a device.
