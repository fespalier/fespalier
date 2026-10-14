// The adapters this app lists (fespalier_push, fespalier_analytics) answer nothing to onEnter, so
// the generated router passes go_router no onEnter: navigation parses synchronously, as in an app
// without adapters. A go() followed by a push() in one handler keeps both (since 0.16.0; before
// it, the go was lost, because any onEnter makes go_router parse asynchronously).
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugins/app.g.dart';

/// The router's stack, bottom first: a matched location, or a pushed page's.
List<String> stack(GoRouter router) => [
  for (final match in router.routerDelegate.currentConfiguration.matches)
    match is ImperativeRouteMatch
        ? match.matches.uri.path
        : match.matchedLocation,
];

void main() {
  testWidgets('the adapters leave go_router no onEnter', (tester) async {
    expect(AppAdapters.handlesEnter, isFalse);
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    expect(router.configuration.topOnEnter, isNull);
  });

  testWidgets('go() commits at once', (tester) async {
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    router.go('/orders/7');
    // No pump, no await: the very same call stack.
    expect(router.routerDelegate.currentConfiguration.uri.path, '/orders/7');
  });

  testWidgets('go() then push() in one handler keeps the go', (tester) async {
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    router.go('/orders/7');
    unawaited(router.push('/login'));
    await tester.pumpAndSettle();
    // /orders/:id is a child of the home page's route.
    expect(stack(router), ['/', '/orders/7', '/login']);
    expect(currentLocation(tester), '/login');
  });
}
