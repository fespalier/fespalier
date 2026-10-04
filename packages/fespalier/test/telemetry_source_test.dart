// `fespalier.navigation.source` (since 0.9.0): `navigateFrom` marks the navigation its closure
// starts as coming from a notification, a shortcut, a widget or a link, and telemetry reports it
// in `TelemetryStart.source`. Nothing marks one by itself, and a mark never reaches a later
// navigation.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

late RecordingTelemetry rec;

Widget page(String label) => Scaffold(body: Text(label));

/// A router with the attach call the generated file makes.
GoRouter router({String initial = '/home'}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(
        path: '/orders/:id',
        builder: (_, s) => page('order ${s.pathParameters['id']}'),
      ),
      GoRoute(path: '/settings', builder: (_, _) => page('settings')),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

void main() {
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() => FespalierTelemetry.install(null));

  test('the values, in order', () {
    expect(NavigationSource.values, [
      'notification',
      'shortcut',
      'widget',
      'link',
    ]);
    expect(NavigationSource.notification, 'notification');
    expect(NavigationSource.shortcut, 'shortcut');
    expect(NavigationSource.widget, 'widget');
    expect(NavigationSource.link, 'link');
  });

  test('an unknown source asserts, saying which values there are', () {
    expect(
      () => navigateFrom('banner', () => 1),
      throwsA(
        isA<AssertionError>().having(
          (e) => e.message,
          'message',
          'navigateFrom: `banner` is not a NavigationSource value '
              '(notification, shortcut, widget or link)',
        ),
      ),
    );
  });

  test('it runs the closure once and returns what it returns', () {
    var runs = 0;
    final value = Object();
    final got = navigateFrom(NavigationSource.link, () {
      runs++;
      return value;
    });
    expect(identical(got, value), isTrue);
    expect(runs, 1);
  });

  testWidgets('a cold start: the router built in the closure is the launch', (
    tester,
  ) async {
    final r = navigateFrom(
      NavigationSource.notification,
      () => router(initial: '/orders/42'),
    );
    await pumpRouter(tester, r);
    expect(rec.log, [
      '#1 start navigate /orders/42 source=notification',
      '#1 page enter /orders/:id',
      '#1 end navigate ok route=/orders/:id kind=initial at=/orders/42',
    ]);
  });

  testWidgets('a cold start from the app itself has no source', (tester) async {
    await pumpRouter(tester, router(initial: '/orders/42'));
    expect(rec.log.first, '#1 start navigate /orders/42');
  });

  testWidgets('a go in the closure is marked, and a later one is not', (
    tester,
  ) async {
    final r = router();
    await pumpRouter(tester, r);
    rec.log.clear();
    navigateFrom(NavigationSource.shortcut, () => r.go('/settings'));
    await tester.pumpAndSettle();
    r.go('/orders/1');
    await tester.pumpAndSettle();
    expect(rec.log.where((l) => l.contains(' start navigate ')).toList(), [
      '#2 start navigate /settings source=shortcut',
      '#3 start navigate /orders/1',
    ]);
  });

  testWidgets(
    'a push is marked too, and the end of the navigation says nothing '
    'of it',
    (tester) async {
      final r = router();
      await pumpRouter(tester, r);
      rec.log.clear();
      navigateFrom(
        NavigationSource.widget,
        () => unawaited(r.push<void>('/settings')),
      );
      await tester.pumpAndSettle();
      expect(rec.log.first, '#2 start navigate /settings source=widget');
      expect(rec.log.last, startsWith('#2 end navigate ok'));
      expect(rec.log.last, isNot(contains('source')));
    },
  );

  testWidgets('only the first navigation of the closure is marked', (
    tester,
  ) async {
    final r = router();
    await pumpRouter(tester, r);
    rec.log.clear();
    navigateFrom(NavigationSource.link, () {
      r.go('/settings');
      r.go('/orders/9');
    });
    await tester.pumpAndSettle();
    final starts = rec.log
        .where((l) => l.contains(' start navigate '))
        .toList();
    expect(starts, [
      '#2 start navigate /settings source=link',
      '#3 start navigate /orders/9',
    ]);
  });

  testWidgets('a closure that starts no navigation leaves no mark behind', (
    tester,
  ) async {
    final r = router();
    await pumpRouter(tester, r);
    rec.log.clear();
    navigateFrom(NavigationSource.link, () {});
    // Going where the router already is starts no navigation either, and consumes nothing.
    navigateFrom(NavigationSource.link, () => r.go('/home'));
    r.go('/settings');
    await tester.pumpAndSettle();
    expect(rec.log.first, '#2 start navigate /settings');
  });

  testWidgets('a closure that throws leaves no mark behind', (tester) async {
    final r = router();
    await pumpRouter(tester, r);
    rec.log.clear();
    expect(
      () => navigateFrom<void>(
        NavigationSource.notification,
        () => throw StateError('handler failed'),
      ),
      throwsStateError,
    );
    r.go('/settings');
    await tester.pumpAndSettle();
    expect(rec.log.first, '#2 start navigate /settings');
  });

  testWidgets('with no sink installed the mark is dropped when the closure '
      'returns', (tester) async {
    FespalierTelemetry.install(null);
    final r = router();
    await pumpRouter(tester, r);
    navigateFrom(NavigationSource.notification, () => r.go('/settings'));
    await tester.pumpAndSettle();
    FespalierTelemetry.install(rec);
    r.go('/orders/3');
    await tester.pumpAndSettle();
    expect(rec.log.where((l) => l.contains(' start navigate ')), [
      '#1 start navigate /orders/3',
    ]);
  });

  testWidgets('each sink of a combine is told the source', (tester) async {
    final other = RecordingTelemetry();
    FespalierTelemetry.install(FespalierTelemetry.combine([rec, other]));
    final r = navigateFrom(
      NavigationSource.link,
      () => router(initial: '/orders/5'),
    );
    await pumpRouter(tester, r);
    expect(rec.log.first, '#1 start navigate /orders/5 source=link');
    expect(other.log.first, '#1 start navigate /orders/5 source=link');
  });
}
