// requireUnlocked on a real GoRouter, through fespalier's refGuard (what a generated `redirect:` calls),
// under pumpRouter: it redirects to the unlock page and never prompts, however often it runs again.
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A second reason for the guard to run again.
final noise = NotifierProvider<_Noise, int>(_Noise.new);

class _Noise extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

class _Unlock extends TypedLocation {
  const _Unlock(this.from);
  final String from;

  @override
  String get location => '/unlock?from=${Uri.encodeQueryComponent(from)}';
}

/// `/secret` is behind the unlock (with [maxAge]); `/unlock` is the app's unlock page.
GoRouter routerAt(String location, {Duration? maxAge}) => GoRouter(
  initialLocation: location,
  routes: [
    GoRoute(path: '/', builder: (context, state) => const Text('Home')),
    GoRoute(
      path: '/secret',
      redirect: (context, state) => refGuard(context, '/secret@0', (ref) {
        ref.watch(noise);
        return requireUnlocked(
          ref,
          state.uri,
          unlock: _Unlock.new,
          maxAge: maxAge,
        );
      }),
      builder: (context, state) => const Text('Secret'),
    ),
    GoRoute(
      path: '/unlock',
      builder: (context, state) => Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () async {
            final outcome = await ref
                .read(biometricUnlock.notifier)
                .unlock('Unlock your orders');
            if (outcome == BiometricOutcome.success && context.mounted) {
              context.go(returnTo(state.uri.queryParameters['from']));
            }
          },
          child: const Text('Unlock'),
        ),
      ),
    ),
  ],
);

void main() {
  testWidgets('locked: the guard redirects with from, and shows no prompt', (
    tester,
  ) async {
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      routerAt('/secret?x=1'),
      overrides: biometricTestOverrides(prompt),
    );
    expect(currentLocation(tester), startsWith('/unlock?from='));
    expect(
      Uri.parse(currentLocation(tester)).queryParameters['from'],
      '/secret?x=1',
    );
    expect(prompt.prompts, 0);
  });

  testWidgets('unlock from the page: the route opens, one prompt', (
    tester,
  ) async {
    final prompt = FakeBiometricPrompt();
    await pumpRouter(
      tester,
      routerAt('/secret'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/secret');
    expect(find.text('Secret'), findsOneWidget);
    expect(prompt.prompts, 1);
    expect(prompt.reasons, ['Unlock your orders']);
  });

  testWidgets('ten guard re-runs never prompt again', (tester) async {
    final prompt = FakeBiometricPrompt();
    final container = await pumpRouter(
      tester,
      routerAt('/secret'),
      overrides: biometricTestOverrides(prompt),
    );
    // Locked, with the guard's answer subscribed: re-run it ten times.
    for (var i = 0; i < 10; i++) {
      container.read(noise.notifier).bump();
      await tester.pumpAndSettle();
    }
    expect(prompt.prompts, 0);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      container.read(noise.notifier).bump();
      await tester.pumpAndSettle();
    }
    expect(find.text('Secret'), findsOneWidget);
    expect(prompt.prompts, 1);
  });

  testWidgets('a lock() leaves the page for the unlock page', (tester) async {
    final prompt = FakeBiometricPrompt();
    final container = await pumpRouter(
      tester,
      routerAt('/secret'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsOneWidget);
    container.read(biometricUnlock.notifier).lock();
    await tester.pumpAndSettle();
    expect(currentLocation(tester), startsWith('/unlock'));
    expect(prompt.prompts, 1);
  });

  testWidgets('a prompt over an unlocked page does not send it away', (
    tester,
  ) async {
    final prompt = FakeBiometricPrompt();
    final container = await pumpRouter(
      tester,
      routerAt('/secret'),
      overrides: biometricTestOverrides(prompt),
    );
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    prompt.hold();
    final flight = container.read(biometricUnlock.notifier).unlock('again');
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsOneWidget);
    prompt.release(BiometricOutcome.cancelled);
    await flight;
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsOneWidget);
  });

  testWidgets('maxAge: an older unlock redirects at the next navigation', (
    tester,
  ) async {
    final start = DateTime(2026, 10, 7, 9);
    final prompt = FakeBiometricPrompt();
    final container = await pumpRouter(
      tester,
      routerAt('/', maxAge: const Duration(minutes: 5)),
      overrides: biometricTestOverrides(prompt),
    );
    await withClock(
      Clock.fixed(start),
      () => container.read(biometricUnlock.notifier).unlock('r'),
    );
    final router = GoRouter.of(tester.element(find.text('Home')));
    withClock(Clock.fixed(start.add(const Duration(minutes: 4))), () {
      router.go('/secret');
    });
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/secret');
    router.go('/');
    await tester.pumpAndSettle();
    withClock(Clock.fixed(start.add(const Duration(minutes: 6))), () {
      router.go('/secret');
    });
    await tester.pumpAndSettle();
    expect(currentLocation(tester), startsWith('/unlock'));
    expect(prompt.prompts, 1);
  });

  testWidgets('a resume past the grace relocks and the page is left', (
    tester,
  ) async {
    final start = DateTime(2026, 10, 7, 9);
    final prompt = FakeBiometricPrompt();
    final container = await pumpRouter(
      tester,
      routerAt('/secret'),
      overrides: biometricTestOverrides(
        prompt,
        policy: const BiometricPolicy(resumeGrace: Duration(seconds: 30)),
      ),
    );
    await withClock(Clock.fixed(start), () async {
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
    });
    expect(find.text('Secret'), findsOneWidget);
    withClock(Clock.fixed(start.add(const Duration(seconds: 10))), () {
      container.read(appResumeSignal.notifier).fire();
    });
    await tester.pumpAndSettle();
    expect(find.text('Secret'), findsOneWidget);
    withClock(Clock.fixed(start.add(const Duration(seconds: 31))), () {
      container.read(appResumeSignal.notifier).fire();
    });
    await tester.pumpAndSettle();
    expect(currentLocation(tester), startsWith('/unlock'));
    expect(prompt.prompts, 1);
  });
}
