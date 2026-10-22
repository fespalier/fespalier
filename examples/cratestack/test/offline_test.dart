// Offline: a `TransportUnsent` reads as `CrateStackOffline` (CrateStackErrors with
// TransportFailures.read), and `ref.serve` answers with the copy this phone saved of the last list.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets(
    'the last list is served from the device when the server cannot be reached',
    (tester) async {
      final server = FakeOrdersServer();
      final container = await enrol(tester, server, FakeDevice());
      final router = AppRoutes.router(initialLocation: '/orders');
      await pumpRouter(tester, router, container: container);
      expect(find.text('2 x Espresso beans'), findsOneWidget);
      expect(find.textContaining('Offline'), findsNothing);

      server.offline = true;
      container.invalidate(OrdersRoute.data);
      await tester.pumpAndSettle();
      expect(find.textContaining('Offline copy, as of'), findsOneWidget);
      expect(find.text('2 x Espresso beans'), findsOneWidget);

      // Back online, "Try again" reads the server again.
      server.offline = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Offline'), findsNothing);
    },
  );

  testWidgets('with nothing saved yet, offline says so', (tester) async {
    final server = FakeOrdersServer();
    final container = await enrol(tester, server, FakeDevice());
    server.offline = true;
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders'),
      container: container,
    );
    expect(find.text('Offline: not loaded on this phone yet'), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget, reason: 'only the banner');
  });

  testWidgets('an answer from the server is never covered by the copy', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final container = await enrol(tester, server, FakeDevice());
    final router = AppRoutes.router(initialLocation: '/orders');
    await pumpRouter(tester, router, container: container);
    // The server lost this device: 401 device_not_active is its answer, not a reason to show the copy.
    server.forgetDevice('device-1');
    container.invalidate(OrdersRoute.data);
    await tester.pumpAndSettle();
    expect(find.textContaining('Offline'), findsNothing);
  });
}
