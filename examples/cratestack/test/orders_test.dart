// The list, the detail and the write, through the generated providers: each page reads with
// `ref.cancellable`, and a new order is a call with an Idempotency-Key whose validation errors come
// back under their fields.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'support.dart';

Future<void> signedIn(
  WidgetTester tester,
  FakeOrdersServer server, {
  String at = '/orders',
  FakeDevice? device,
}) async {
  final container = await enrol(tester, server, device ?? FakeDevice());
  final router = AppRoutes.router(initialLocation: at);
  await pumpRouter(tester, router, container: container);
}

void main() {
  testWidgets('the list shows the signed-in user\'s orders', (tester) async {
    final server = FakeOrdersServer();
    await signedIn(tester, server);
    expect(find.text('2 x Espresso beans'), findsOneWidget);
    expect(find.text('Order 1, placed'), findsOneWidget);
    expect(find.text('6 x Oat milk'), findsOneWidget);
    expect(find.text('Order 2, paid'), findsOneWidget);
    expect(find.textContaining('Offline'), findsNothing);
  });

  testWidgets('an order opens its detail page', (tester) async {
    final server = FakeOrdersServer();
    await signedIn(tester, server);
    await tester.tap(find.text('2 x Espresso beans'));
    await tester.pumpAndSettle();
    expect(find.text('Order 1'), findsOneWidget);
    expect(find.text('Item: Espresso beans'), findsOneWidget);
    expect(find.text('Quantity: 2'), findsOneWidget);
    expect(find.text('Status: placed'), findsOneWidget);
    expect(server.signedCalls.map((c) => c.op), ['listOrders', 'getOrder']);
    expect(server.signedCalls.last.args, {'id': 1});
  });

  testWidgets('a missing order is the server\'s refusal, not a blank page', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    await signedIn(tester, server, at: '/orders/9');
    expect(find.textContaining('order 9'), findsWidgets);
  });

  testWidgets(
    'placing an order sends an Idempotency-Key and reloads the list',
    (tester) async {
      final server = FakeOrdersServer();
      await signedIn(tester, server);
      await tester.enterText(find.widgetWithText(TextField, 'Item'), 'Tea');
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '3');
      await tester.tap(find.widgetWithText(FilledButton, 'Place order'));
      await tester.pumpAndSettle();

      final placed = server.signedCalls.singleWhere(
        (c) => c.op == 'placeOrder',
      );
      expect(placed.args, {'item': 'Tea', 'quantity': 3});
      expect(
        placed.headers['idempotency-key'],
        matches(RegExp(r'^[0-9a-f]{32}$')),
      );
      expect(placed.signedWith?.name, 'ambient');
      // The list was read again after the write, and shows it.
      expect(server.signedCalls.map((c) => c.op), [
        'listOrders',
        'placeOrder',
        'listOrders',
      ]);
      expect(find.text('3 x Tea'), findsOneWidget);
    },
  );

  testWidgets('the server\'s validation answer is shown under its field', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    await signedIn(tester, server);
    await tester.enterText(find.widgetWithText(TextField, 'Item'), 'Tea');
    await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '100');
    await tester.tap(find.widgetWithText(FilledButton, 'Place order'));
    await tester.pumpAndSettle();

    expect(
      find.text("field 'quantity' must be between 1 and 99"),
      findsOneWidget,
    );
    expect(find.textContaining('3 x'), findsNothing);
    // Only the list's own load: a refused write invalidates nothing.
    expect(server.signedCalls.map((c) => c.op), ['listOrders', 'placeOrder']);
  });

  testWidgets(
    'an empty item is refused on the device, before anything is sent',
    (tester) async {
      final server = FakeOrdersServer();
      await signedIn(tester, server);
      await tester.tap(find.widgetWithText(FilledButton, 'Place order'));
      await tester.pumpAndSettle();
      expect(find.text('Write what you want to order'), findsOneWidget);
      expect(server.signedCalls.map((c) => c.op), ['listOrders']);
    },
  );
}
