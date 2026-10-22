// A guard must never return a `SynchronousFuture` (docs/guards.md, "What go_router still skips, and
// the limits of a re-run", number 11): go_router calls `catchError` on the `Future` of a redirect, and
// on a `SynchronousFuture` that never completes, so the navigation never ends. This pins go_router's
// behaviour (the probe F of the review of #268): when a go_router release completes it, the limit and
// this test can go.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/navigation_kind.dart' show pushedMatches;
import 'package:fespalier/testing.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _stack(GoRouter r) {
  final pushed = <ImperativeRouteMatch>[];
  pushedMatches(r.routerDelegate.currentConfiguration.matches, pushed);
  return [
    r.routerDelegate.currentConfiguration.uri.toString(),
    for (final e in pushed) e.matches.uri.toString(),
  ];
}

GoRouter _router({required bool synchronous}) => GoRouter(
  initialLocation: '/home',
  routes: [
    GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    GoRoute(path: '/login', builder: (_, _) => const Text('LOGIN')),
    GoRoute(
      path: '/sf',
      redirect: (context, state) => runRedirect(
        state,
        () => refGuard(
          context,
          'g@sf',
          (ref) => synchronous
              ? SynchronousFuture<String?>('/login')
              : Future<String?>.value('/login'),
        ),
      ),
      builder: (context, state) =>
          refusedView(context, state) ?? const Text('SF'),
    ),
  ],
);

void main() {
  testWidgets('a guard that returns a Future redirects a push (control)', (
    tester,
  ) async {
    final r = _router(synchronous: false);
    await pumpRouter(tester, r);
    unawaited(r.push<void>('/sf'));
    await tester.pumpAndSettle();
    expect(_stack(r), ['/home', '/login']);
  });

  testWidgets('a guard that returns a SynchronousFuture never lands the push', (
    tester,
  ) async {
    final r = _router(synchronous: true);
    await pumpRouter(tester, r);
    unawaited(r.push<void>('/sf'));
    await tester.pumpAndSettle();
    expect(_stack(r), ['/home'], reason: 'go_router never completes it');
    expect(find.text('SF'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
