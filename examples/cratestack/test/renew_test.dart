// Renewal replaces refresh: a silent proof of possession through the generated client, lazy,
// single-flight and with no timer. The attestations live a day against the fake clock; the backend
// renews one within twelve hours of its end, and an expired one is renewed before the call.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orders_client/orders_client.dart'
    show
        ListOrdersArgs,
        ListOrdersProcedureArgs,
        ordersClientProceduresApiProvider;

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets('an expired attestation is renewed once, by two calls together', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final device = FakeDevice();
    final container = await enrol(tester, server, device);
    final prompts = device.prompts;
    final api = container.read(ordersClientProceduresApiProvider);
    server.served.clear();

    // Nothing renews it in the background.
    await tester.pump(const Duration(hours: 25));
    expect(server.renewals, 0);

    await Future.wait([
      api.listOrders(ListOrdersProcedureArgs(args: ListOrdersArgs())),
      api.listOrders(ListOrdersProcedureArgs(args: ListOrdersArgs())),
    ]);
    expect(server.renewals, 1, reason: 'one renewal, shared');
    expect(device.prompts, prompts, reason: 'renewing never asks the user');
    expect(server.served.map((s) => '$s'), [
      'POST beginRenewal',
      'POST confirmRenewal',
      'POST listOrders',
      'POST listOrders',
    ]);
    expect(
      server.served.where((s) => s.signed).every((s) => s.refusedWith == null),
      isTrue,
      reason:
          'both were signed with the new attestation: the old one would be attestation_expired',
    );
    expect(server.authorizationHeaders, 0);

    // Fresh again: a later call renews nothing.
    await api.listOrders(ListOrdersProcedureArgs(args: ListOrdersArgs()));
    expect(server.renewals, 1);
  });

  testWidgets('a 401 attestation_expired renews and sends the call once more', (
    tester,
  ) async {
    // The phone renews only when an attestation has run out (renewAhead zero), and the server's clock
    // is a few seconds ahead of the phone's: it refuses an attestation the phone still holds good.
    final server = FakeOrdersServer(
      attestationLifetime: const Duration(hours: 1),
    );
    final container = await enrol(
      tester,
      server,
      FakeDevice(),
      renewAhead: Duration.zero,
    );
    final api = container.read(ordersClientProceduresApiProvider);
    server.served.clear();

    await tester.pump(const Duration(hours: 1) - const Duration(seconds: 3));
    server.skew = const Duration(seconds: 5);
    await api.listOrders(ListOrdersProcedureArgs(args: ListOrdersArgs()));
    expect(server.renewals, 1);
    expect(
      server.served.map(
        (s) => '$s${s.refusedWith == null ? '' : ' refused ${s.refusedWith}'}',
      ),
      [
        'POST listOrders refused attestation_expired',
        'POST beginRenewal',
        'POST confirmRenewal',
        'POST listOrders',
      ],
    );
  });

  testWidgets('a device the server forgot ends the session as revoked', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final container = await enrol(tester, server, FakeDevice());
    final api = container.read(ordersClientProceduresApiProvider);
    server.forgetDevice('device-1');
    // 401 device_not_active asks for a renewal, and the server answers 403 (it knows no such device):
    // the session is over, as revoked.
    await expectLater(
      api.listOrders(ListOrdersProcedureArgs(args: ListOrdersArgs())),
      throwsA(anything),
    );
    expect(
      container.read(authSession),
      const SignedOut(reason: SignOutReason.revoked),
    );
    final router = AppRoutes.router();
    await pumpRouter(tester, router, container: container);
    expect(find.text('This device was revoked. Enrol again.'), findsOneWidget);
  });

  testWidgets(
    'a revoked device is told 403 DEVICE_REVOKED and signs out as revoked',
    (tester) async {
      final server = FakeOrdersServer();
      final container = await enrol(tester, server, FakeDevice());
      final api = container.read(ordersClientProceduresApiProvider);
      server.revokeAll();
      await expectLater(
        api.listOrders(ListOrdersProcedureArgs(args: ListOrdersArgs())),
        throwsA(anything),
      );
      expect(
        container.read(authSession),
        const SignedOut(reason: SignOutReason.revoked),
      );
    },
  );
}
