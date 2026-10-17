// The idle lock: the ticker the app fires, the age by package:clock, and BiometricActivity's touch
// recording and absorbing of the first touch after the limit. No test here waits for a real time.
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_biometrics/fespalier_biometrics.dart';
import 'package:fespalier_biometrics/testing.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const limit = Duration(minutes: 1);
final start = DateTime(2026, 10, 7, 9);

/// A clock a test moves by hand.
class Hands {
  DateTime now = start;
  Clock get clock => Clock(() => now);
  void advance(Duration d) => now = now.add(d);
}

/// A container with the unlock held open, the way a guard holds it, and every state it went through.
({ProviderContainer container, List<UnlockState> seen, BiometricUnlock unlock})
open(
  FakeBiometricPrompt prompt, {
  BiometricPolicy? policy = const BiometricPolicy(idleTimeout: limit),
}) {
  final container = ProviderContainer(
    overrides: biometricTestOverrides(prompt, policy: policy),
  );
  addTearDown(container.dispose);
  final seen = <UnlockState>[];
  container.listen(biometricUnlock, (_, next) => seen.add(next));
  return (
    container: container,
    seen: seen,
    unlock: container.read(biometricUnlock.notifier),
  );
}

void tick(ProviderContainer c) => c.read(biometricIdleTicker.notifier).fire();

void main() {
  group('the ticker', () {
    test('without idleTimeout a tick never locks', () async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final h = open(FakeBiometricPrompt(), policy: const BiometricPolicy());
        await h.unlock.unlock('r');
        hands.advance(const Duration(days: 30));
        tick(h.container);
        expect(h.container.read(biometricUnlock), isA<Unlocked>());
        expect(h.unlock.isIdle(), isFalse);
      });
    });

    test(
      'a tick at idleTimeout of no activity locks; one before keeps the unlock',
      () async {
        final hands = Hands();
        await withClock(hands.clock, () async {
          final h = open(FakeBiometricPrompt());
          await h.unlock.unlock('r');
          h.seen.clear();
          hands.advance(limit - const Duration(seconds: 1));
          tick(h.container);
          expect(h.container.read(biometricUnlock), isA<Unlocked>());
          hands.advance(const Duration(seconds: 1));
          tick(h.container);
          expect(h.container.read(biometricUnlock), isA<Locked>());
          expect(h.unlock.isFresh(), isFalse);
          // The tick that locks tells exactly once; the one before it told nobody.
          expect(h.seen, hasLength(1));
          expect(h.seen.single, isA<Locked>());
        });
      },
    );

    test('activity resets the idle clock', () async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final h = open(FakeBiometricPrompt());
        await h.unlock.unlock('r');
        hands.advance(limit - const Duration(seconds: 1));
        h.unlock.touch();
        hands.advance(const Duration(seconds: 2));
        tick(h.container);
        expect(h.container.read(biometricUnlock), isA<Unlocked>());
        hands.advance(limit);
        tick(h.container);
        expect(h.container.read(biometricUnlock), isA<Locked>());
      });
    });

    test(
      'idle runs from the later of the unlock and the last activity',
      () async {
        final hands = Hands();
        await withClock(hands.clock, () async {
          final h = open(FakeBiometricPrompt());
          await h.unlock.unlock('r');
          h.unlock.touch();
          hands.advance(const Duration(seconds: 50));
          // A new unlock is later than the touch: the touch must not count against it.
          await h.unlock.unlock('again');
          hands.advance(const Duration(seconds: 50));
          tick(h.container);
          expect(h.container.read(biometricUnlock), isA<Unlocked>());
          hands.advance(const Duration(seconds: 10));
          tick(h.container);
          expect(h.container.read(biometricUnlock), isA<Locked>());
        });
      },
    );

    test('a clock set back counts as idle', () async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final h = open(FakeBiometricPrompt());
        await h.unlock.unlock('r');
        hands.advance(const Duration(seconds: 5));
        h.unlock.touch();
        hands.now = start.subtract(const Duration(hours: 1));
        expect(h.unlock.isIdle(), isTrue);
        tick(h.container);
        expect(h.container.read(biometricUnlock), isA<Locked>());
      });
    });

    test(
      'a tick during a prompt keeps the prompt, and a lock that was due applies when it ends without success',
      () async {
        final hands = Hands();
        await withClock(hands.clock, () async {
          final prompt = FakeBiometricPrompt();
          final h = open(prompt);
          await h.unlock.unlock('r');
          hands.advance(limit);
          prompt.hold();
          final running = h.unlock.unlock('again');
          tick(h.container);
          expect(h.container.read(biometricUnlock), isA<Unlocking>());
          expect(prompt.prompts, 2);
          prompt.release(BiometricOutcome.cancelled);
          await running;
          expect(h.container.read(biometricUnlock), isA<Locked>());
        });
      },
    );

    test('a success after the due tick unlocks again, from now', () async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final prompt = FakeBiometricPrompt();
        final h = open(prompt);
        await h.unlock.unlock('r');
        hands.advance(limit);
        prompt.hold();
        final running = h.unlock.unlock('again');
        tick(h.container);
        prompt.release();
        await running;
        expect(h.container.read(biometricUnlock), isA<Unlocked>());
        expect(h.unlock.isIdle(), isFalse);
      });
    });

    test('a tick while locked changes nothing', () async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final h = open(FakeBiometricPrompt());
        tick(h.container);
        tick(h.container);
        // Riverpod rebuilds lazily: read, or build() never runs before the expect.
        expect(h.container.read(biometricUnlock), isA<Locked>());
        expect(h.seen, isEmpty);
      });
    });

    test('a tick that keeps the unlock tells no listener', () async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final h = open(FakeBiometricPrompt());
        await h.unlock.unlock('r');
        h.seen.clear();
        hands.advance(const Duration(seconds: 1));
        tick(h.container);
        h.container.read(biometricUnlock);
        expect(h.seen, isEmpty);
      });
    });

    test(
      'touch does nothing locked, without a limit, or after the limit',
      () async {
        final hands = Hands();
        await withClock(hands.clock, () async {
          final h = open(FakeBiometricPrompt());
          h.unlock.touch();
          await h.unlock.unlock('r');
          hands.advance(limit);
          h.unlock.touch();
          // The late touch did not bring the expired unlock back.
          expect(h.unlock.isIdle(), isTrue);
        });
      },
    );
  });

  group('BiometricActivity', () {
    Future<
      ({
        ProviderContainer container,
        BiometricUnlock unlock,
        ValueNotifier<int> presses,
      })
    >
    pumpApp(
      WidgetTester tester,
      Hands hands, {
      Widget? extra,
      BiometricPolicy? policy = const BiometricPolicy(idleTimeout: limit),
    }) async {
      final presses = ValueNotifier(0);
      final prompt = FakeBiometricPrompt();
      final container = ProviderContainer(
        overrides: biometricTestOverrides(prompt, policy: policy),
      );
      addTearDown(container.dispose);
      container.listen(biometricUnlock, (_, _) {});
      final unlock = container.read(biometricUnlock.notifier);
      await unlock.unlock('r');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => BiometricActivity(child: child!),
            home: Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => presses.value++,
                    child: const Text('Press'),
                  ),
                  ?extra,
                ],
              ),
            ),
          ),
        ),
      );
      return (container: container, unlock: unlock, presses: presses);
    }

    testWidgets('a pointer down inside BiometricActivity records activity', (
      tester,
    ) async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final app = await pumpApp(tester, hands);
        hands.advance(limit - const Duration(seconds: 1));
        await tester.tap(find.text('Press'));
        hands.advance(const Duration(seconds: 30));
        // Without the touch this would be 89 s old; with it, 30 s.
        expect(app.unlock.isIdle(), isFalse);
        hands.advance(limit);
        expect(app.unlock.isIdle(), isTrue);
      });
    });

    testWidgets(
      'the first touch after the limit is absorbed and locks: the button under it is not pressed',
      (tester) async {
        final hands = Hands();
        await withClock(hands.clock, () async {
          final app = await pumpApp(tester, hands);
          // No tick was fired: the time alone decides.
          hands.advance(limit);
          await tester.tap(find.text('Press'));
          await tester.pump();
          expect(app.presses.value, 0);
          expect(app.container.read(biometricUnlock), isA<Locked>());
        });
      },
    );

    testWidgets('a key event no descendant handled records activity', (
      tester,
    ) async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final app = await pumpApp(
          tester,
          hands,
          extra: const Focus(autofocus: true, child: SizedBox(height: 10)),
        );
        await tester.pump();
        hands.advance(limit - const Duration(seconds: 1));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        hands.advance(const Duration(seconds: 30));
        expect(app.unlock.isIdle(), isFalse);
      });
    });

    testWidgets('a trackpad pan or zoom start records activity', (
      tester,
    ) async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final app = await pumpApp(tester, hands);
        final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
        hands.advance(limit - const Duration(seconds: 1));
        final at = tester.getCenter(find.text('Press'));
        await tester.sendEventToBinding(trackpad.panZoomStart(at));
        await tester.sendEventToBinding(trackpad.panZoomEnd());
        hands.advance(const Duration(seconds: 30));
        expect(app.unlock.isIdle(), isFalse);
      });
    });

    testWidgets('a trackpad pan or zoom start after the limit locks', (
      tester,
    ) async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final app = await pumpApp(tester, hands);
        final trackpad = TestPointer(1, PointerDeviceKind.trackpad);
        hands.advance(limit);
        final at = tester.getCenter(find.text('Press'));
        await tester.sendEventToBinding(trackpad.panZoomStart(at));
        await tester.sendEventToBinding(trackpad.panZoomEnd());
        expect(app.container.read(biometricUnlock), isA<Locked>());
      });
    });

    testWidgets('a touch before the limit reaches the page', (tester) async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final app = await pumpApp(tester, hands);
        hands.advance(limit - const Duration(seconds: 1));
        await tester.tap(find.text('Press'));
        await tester.pump();
        expect(app.presses.value, 1);
        expect(app.container.read(biometricUnlock), isA<Unlocked>());
      });
    });

    testWidgets('without an idleTimeout every touch reaches the page', (
      tester,
    ) async {
      final hands = Hands();
      await withClock(hands.clock, () async {
        final app = await pumpApp(
          tester,
          hands,
          policy: const BiometricPolicy(),
        );
        hands.advance(const Duration(days: 3));
        await tester.tap(find.text('Press'));
        expect(app.presses.value, 1);
        expect(app.container.read(biometricUnlock), isA<Unlocked>());
      });
    });
  });
}
