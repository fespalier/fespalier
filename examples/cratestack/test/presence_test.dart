// A sensitive call needs the user-present key, and only it prompts. The rule is the server's
// (`payOrder` declares `@authn(amr: ["user"])`): the app makes an ordinary call, signed by the
// ambient key, the server refuses it with RFC 9470's step-up 401, and the session signs the same
// request again with the user-present key and sends it once more. An ordinary call never asks.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_client/orders_client.dart'
    show
        CratestackRpcCallOptions,
        CratestackRpcException,
        PayOrderArgs,
        PayOrderProcedureArgs,
        ordersClientProceduresApiProvider;

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets(
    'paying is refused for the ambient key, then signed again with the user-present key: one prompt',
    (tester) async {
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
      expect(device.presence!.lastReason, 'Confirm it is you');
      final pays = server.signedCalls.where((c) => c.op == 'payOrder').toList();
      expect(pays, hasLength(2));
      expect(pays[0].signedWith?.name, 'ambient');
      expect(pays[0].refusedWith, 'insufficient_user_authentication');
      expect(pays[1].signedWith?.name, 'userPresent');
      expect(pays[1].refusedWith, isNull);
      expect(
        pays[1].headers['idempotency-key'],
        pays[0].headers['idempotency-key'],
        reason: 'the same request, sent again',
      );
      expect(pays[1].headers['idempotency-key'], isNotEmpty);
      expect(pays[1].body, pays[0].body);
      // The order, and the list under it, load again.
      expect(find.text('Status: paid'), findsOneWidget);
      expect(find.text('Confirm and pay'), findsNothing);
    },
  );

  testWidgets('a cancelled prompt leaves the refusal, and nothing else', (
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
    final pays = server.signedCalls.where((c) => c.op == 'payOrder').toList();
    expect(pays, hasLength(1), reason: 'nothing was signed with the other key');
    expect(pays.single.refusedWith, 'insufficient_user_authentication');

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

  testWidgets(
    'work the user is not looking at never prompts: the refusal is the answer',
    (tester) async {
      final server = FakeOrdersServer();
      final device = FakeDevice();
      final container = await enrol(tester, server, device);
      final before = device.prompts;
      final api = container.read(ordersClientProceduresApiProvider);
      // A generated call has no attributes to give, so background work runs in the zone.
      await expectLater(
        Authorizer.unattended(
          () => api.payOrder(
            PayOrderProcedureArgs(args: PayOrderArgs(id: 1)),
            options: const CratestackRpcCallOptions(idempotencyKey: 'bg-1'),
          ),
        ),
        throwsA(
          isA<CratestackRpcException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.stepUp?.amr, 'stepUp.amr', ['user']),
        ),
      );
      expect(device.prompts, before, reason: 'nobody was asked');
      expect(server.signedCalls.where((c) => c.op == 'payOrder'), hasLength(1));
      expect(container.read(authSession), isA<SignedIn>());
    },
  );

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
    // Called anyway, the refusal stands: there is no key to step up with.
    final api = container.read(ordersClientProceduresApiProvider);
    await expectLater(
      api.payOrder(PayOrderProcedureArgs(args: PayOrderArgs(id: 1))),
      throwsA(
        isA<CratestackRpcException>().having(
          (e) => e.stepUp,
          'stepUp',
          isNotNull,
        ),
      ),
    );
    expect(container.read(authSession), isA<SignedIn>());
  });
}
