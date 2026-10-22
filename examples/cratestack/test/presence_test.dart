// A sensitive call asks for the user-present key, and only it prompts: an ordinary call is signed by
// the ambient key and never asks. The generated call has no attributes to give, so it puts
// `confirmHeader` in its options and `ConfirmTransport` (above the session) turns it into the
// signer's attributes; the header itself is never sent.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_client/orders_client.dart'
    show
        CratestackRpcException,
        PayOrderArgs,
        PayOrderProcedureArgs,
        ordersClientProceduresApiProvider;

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets('paying prompts once, and the server saw the user-present key', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final device = FakeDevice();
    final container = await enrol(tester, server, device);
    final router = AppRoutes.router(initialLocation: '/orders/1');
    await pumpRouter(tester, router, container: container);
    final before = device.prompts;
    // Reading is an ordinary request: the ambient key, no prompt.
    expect(server.signedCalls.map((c) => c.signedWith?.name), [
      'ambient',
      'ambient',
    ]);

    await tester.tap(find.text('Confirm and pay'));
    await tester.pumpAndSettle();

    expect(device.prompts, before + 1, reason: 'the user was asked once');
    expect(device.presence!.lastReason, 'Confirm the payment of order 1');
    final pay = server.signedCalls.singleWhere((c) => c.op == 'payOrder');
    expect(pay.signedWith?.name, 'userPresent');
    expect(pay.refusedWith, isNull);
    expect(
      pay.headers,
      isNot(contains('x-fespalier-confirm')),
      reason: 'a request for the signer, never sent',
    );
    expect(pay.headers['idempotency-key'], isNotEmpty);
    // The order, and the list under it, load again.
    expect(find.text('Status: paid'), findsOneWidget);
    expect(find.text('Confirm and pay'), findsNothing);
  });

  testWidgets('a cancelled prompt fails that one call and nothing else', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final device = FakeDevice();
    final container = await enrol(tester, server, device);
    final router = AppRoutes.router(initialLocation: '/orders/1');
    await pumpRouter(tester, router, container: container);

    device.presence!.refuseNextPrompt();
    await tester.tap(find.text('Confirm and pay'));
    await tester.pumpAndSettle();
    expect(
      find.text('Confirmation cancelled. Nothing was paid.'),
      findsOneWidget,
    );
    expect(server.signedCalls.where((c) => c.op == 'payOrder'), isEmpty);

    // Still enrolled, the ambient key still works, and the user can try again.
    expect(container.read(authSession), isA<SignedIn>());
    router.go('/orders');
    await tester.pumpAndSettle();
    expect(find.text('2 x Espresso beans'), findsOneWidget);
    router.go('/orders/1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm and pay'));
    await tester.pumpAndSettle();
    expect(find.text('Status: paid'), findsOneWidget);
  });

  testWidgets('the server refuses a payment signed by the ambient key', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final container = await enrol(tester, server, FakeDevice());
    // Straight through the generated client, without the header that asks for the other key.
    final api = container.read(ordersClientProceduresApiProvider);
    await expectLater(
      api.payOrder(PayOrderProcedureArgs(args: PayOrderArgs(id: 1))),
      throwsA(
        isA<CratestackRpcException>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.message, 'message', 'user_presence_required'),
      ),
    );
    expect(server.signedCalls.last.signedWith?.name, 'ambient');
    expect(
      container.read(authSession),
      isA<SignedIn>(),
      reason: 'a 403 that is not DEVICE_REVOKED ends nothing',
    );
  });

  testWidgets('a device with no user-present key cannot confirm', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final container = await enrol(
      tester,
      server,
      FakeDevice(userPresent: false),
    );
    final router = AppRoutes.router(initialLocation: '/orders/1');
    await pumpRouter(tester, router, container: container);
    expect(
      find.textContaining('This device has no user-present key'),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Confirm and pay'),
    );
    expect(button.onPressed, isNull);
  });
}
