// The observe.dart hooks of the app, through the generated router: the root file sees every page
// (by its pattern), the one in orders/$id sees the order pages with the id they entered with.
// Hooks run at the end of the first frame that shows a change, so every assertion follows a pump.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/analytics.dart';
import 'package:telemetry/app.g.dart';
import 'package:telemetry/session.dart';

Future<ProviderContainer> boot(
  WidgetTester tester,
  GoRouter router, {
  bool signedInUser = true,
}) => pumpRouter(
  tester,
  router,
  overrides: [signedIn.overrideWithValue(signedInUser)],
);

void main() {
  testWidgets('the first page enters, with the root hook only', (tester) async {
    final c = await boot(tester, AppRoutes.router());
    expect(c.read(views), ['enter /']);
  });

  testWidgets('a page with its own observe.dart runs the outer hook first', (
    tester,
  ) async {
    final router = AppRoutes.router();
    final c = await boot(tester, router);
    router.go('/orders/1');
    await tester.pumpAndSettle();
    expect(c.read(views).skip(1), [
      // The tab switch: home is parked (its tab keeps it), orders enters.
      'enter /orders/:id',
      'order 1 opened',
    ]);
  });

  testWidgets(
    'another id is another page: leave with the old, enter with the new',
    (tester) async {
      final router = AppRoutes.router(initialLocation: '/orders/1');
      final c = await boot(tester, router);
      c.read(views.notifier).state = const [];
      router.go('/orders/2');
      await tester.pumpAndSettle();
      expect(c.read(views), [
        // Leave runs innermost first, with the id the page entered with.
        'order 1 closed',
        'leave /orders/:id',
        'enter /orders/:id',
        'order 2 opened',
      ]);
    },
  );

  testWidgets('a page pushed over an order covers it; popping focuses it', (
    tester,
  ) async {
    final router = AppRoutes.router(initialLocation: '/orders/1');
    final c = await boot(tester, router);
    unawaited(router.push<void>('/login'));
    await tester.pumpAndSettle();
    c.read(views.notifier).state = const [];
    router.pop();
    await tester.pumpAndSettle();
    expect(c.read(views), [
      'leave /login',
      // Only the order's own file has an onFocus.
      'order 1 focused',
    ]);
  });

  testWidgets('a guard that redirects shows only where it ended up', (
    tester,
  ) async {
    final router = AppRoutes.router();
    final c = await boot(tester, router, signedInUser: false);
    c.read(views.notifier).state = const [];
    router.go('/settings');
    await tester.pumpAndSettle();
    expect(c.read(views), ['leave /', 'enter /login']);
  });

  testWidgets('leaving the shell leaves every tab that was entered', (
    tester,
  ) async {
    final router = AppRoutes.router();
    final c = await boot(tester, router);
    router.go('/orders/1');
    await tester.pumpAndSettle();
    c.read(views.notifier).state = const [];
    router.go('/login');
    await tester.pumpAndSettle();
    expect(c.read(views), [
      'order 1 closed',
      'leave /orders/:id',
      'leave /',
      'enter /login',
    ]);
  });
}
