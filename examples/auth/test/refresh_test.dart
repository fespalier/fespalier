// Refresh: lazy, single-flight, with no timer. The demo server's tokens live five minutes against
// the fake clock, and rotate: a refresh token is good once, so a second refresh would fail.
import 'package:auth/app.g.dart';
import 'package:auth/demo/demo_server.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('/orders and /orders/1 opened together share one refresh', (
    tester,
  ) async {
    final server = DemoServer();
    final store = await signedInStore(server, 'ada');
    server.requests.clear();
    final router = AppRoutes.router();
    final container = await pumpRouter(
      tester,
      router,
      overrides: demoOverrides(server, store: store),
    );
    expect(find.text('Signed in as Ada Example'), findsOneWidget);

    // The access token (five minutes) is stale; nothing refreshes it in the background.
    await tester.pump(const Duration(minutes: 6));
    expect(server.refreshes, 0);

    // Opening /orders/1 runs the data.dart of /orders and of /orders/1: two requests, one refresh.
    router.go('/orders/1');
    await tester.pumpAndSettle();
    expect(find.text('Ada Example: order 1'), findsOneWidget);
    expect(server.refreshes, 1);
    expect(
      server.requests.where((r) => r == 'POST /auth/refresh'),
      hasLength(1),
    );
    expect(container.read(authSession), isA<SignedIn>());

    // Fresh again: a later request refreshes nothing.
    router.go('/orders');
    await tester.pumpAndSettle();
    expect(server.refreshes, 1);
  });

  testWidgets('a refresh does not run the guards again or reload the data', (
    tester,
  ) async {
    final server = DemoServer();
    final store = await signedInStore(server, 'ada');
    final router = AppRoutes.router(initialLocation: '/orders');
    final container = await pumpRouter(
      tester,
      router,
      overrides: demoOverrides(server, store: store),
    );
    final orders = server.requests.where((r) => r == 'GET /orders').length;
    await tester.pump(const Duration(minutes: 6));
    final tokens = container.read(authSession.notifier).tokens();
    expect(tokens, isA<Future<AuthTokens>>());
    await tokens;
    await tester.pumpAndSettle();
    expect(server.refreshes, 1);
    expect(currentLocation(tester), '/orders');
    expect(
      server.requests.where((r) => r == 'GET /orders'),
      hasLength(orders),
      reason: 'authUserId did not change: the data was not loaded again',
    );
  });

  testWidgets(
    'a refresh token the server refuses signs the user out, and says so',
    (tester) async {
      final server = DemoServer();
      final store = await signedInStore(server, 'ada');
      final router = AppRoutes.router();
      await pumpRouter(
        tester,
        router,
        overrides: demoOverrides(server, store: store),
      );
      server.endSessions();
      await tester.pump(const Duration(minutes: 6));
      router.go('/orders');
      await tester.pumpAndSettle();
      expect(currentLocation(tester), '/sign-in?from=%2Forders');
      expect(find.text('Your session expired. Sign in again.'), findsOneWidget);
      expect(store.value, isNull, reason: 'the store was cleared');
    },
  );

  testWidgets('a 401 to a token the server dropped refreshes once and loads', (
    tester,
  ) async {
    final server = DemoServer();
    final store = await signedInStore(server, 'ada');
    final router = AppRoutes.router();
    await pumpRouter(
      tester,
      router,
      overrides: demoOverrides(server, store: store),
    );
    // The token has not expired for the app, but the server forgot it.
    server.expireAccessTokens();
    router.go('/orders');
    await tester.pumpAndSettle();
    expect(find.text('Ada Example: order 1'), findsOneWidget);
    expect(server.refreshes, 1);
    expect(
      server.requests,
      containsAllInOrder(['GET /orders', 'POST /auth/refresh', 'GET /orders']),
    );
  });
}
