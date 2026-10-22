// A page that goes away stops its loads: `ref.cancellable` puts the provider's abort trigger in the
// zone of the generated call, the generated transport merges it into the request's `abortTrigger`,
// and the transport honours it.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets('leaving the list while it loads aborts the request', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final container = await enrol(tester, server, FakeDevice());
    expect(server.transport.abortCount, 0);

    server.hold('listOrders');
    final router = AppRoutes.router(initialLocation: '/orders');
    await pumpRouter(tester, router, container: container, settle: false);
    await tester.pump();
    expect(server.signedCalls.map((c) => c.op), [
      'listOrders',
    ], reason: 'the load is in flight, the server has not answered');
    expect(server.transport.requests.last.abortable, isTrue);

    router.go('/');
    await tester.pumpAndSettle();
    expect(server.transport.abortCount, 1);
    server.release('listOrders');
    await tester.pumpAndSettle();
    // The abort was no error anywhere: the home page is simply there.
    expect(find.text('Orders'), findsOneWidget);
  });

  testWidgets(
    'leaving the detail page aborts its request, and the list under it',
    (tester) async {
      final server = FakeOrdersServer();
      final container = await enrol(tester, server, FakeDevice());
      // /orders/1 is a page on top of /orders: both load, and both are in flight.
      server.hold('listOrders');
      server.hold('getOrder');
      final router = AppRoutes.router(initialLocation: '/orders/1');
      await pumpRouter(tester, router, container: container, settle: false);
      await tester.pump();
      expect(server.signedCalls.map((c) => c.op), ['listOrders', 'getOrder']);
      expect(server.transport.abortCount, 0);

      router.go('/');
      await tester.pumpAndSettle();
      expect(server.transport.abortCount, 2);
      server.release('listOrders');
      server.release('getOrder');
    },
  );

  testWidgets('a page that stays gets its answer, and nothing is aborted', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final container = await enrol(tester, server, FakeDevice());
    final router = AppRoutes.router(initialLocation: '/orders');
    await pumpRouter(tester, router, container: container);
    expect(find.text('2 x Espresso beans'), findsOneWidget);
    expect(server.transport.abortCount, 0);
  });
}
