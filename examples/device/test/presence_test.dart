// A sensitive action asks for the user-present key through the request's attributes, and only it
// prompts: an ordinary request is signed by the ambient key and never asks.
import 'package:device/app.g.dart';
import 'package:device/demo/demo_api.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets(
    'sending money prompts, and the server saw the user-present key',
    (tester) async {
      final server = DemoApi();
      final device = FakeDevice();
      final container = await enrol(tester, server, device);
      final router = AppRoutes.router(initialLocation: '/transfer');
      await pumpRouter(tester, router, container: container);
      final enrolPrompts = device.prompts;
      server.served.clear();

      // The account page is an ordinary request: the ambient key, no prompt.
      router.go('/account');
      await tester.pumpAndSettle();
      expect(server.served.single.signedWith?.name, 'ambient');
      expect(device.prompts, enrolPrompts);

      router.go('/transfer');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm and send'));
      await tester.pumpAndSettle();

      expect(
        device.prompts,
        enrolPrompts + 1,
        reason: 'the user was asked once',
      );
      expect(device.presence!.lastReason, 'Confirm the transfer');
      expect(find.text('Transfer 1 sent to Ada'), findsOneWidget);
      expect(server.transfers, ['Ada']);
      final transfer = server.served.last;
      expect('$transfer', 'POST /transfers');
      expect(transfer.signedWith?.name, 'userPresent');
      expect(transfer.refusedWith, isNull);
    },
  );

  testWidgets('a cancelled prompt fails that one request and nothing else', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice();
    final container = await enrol(tester, server, device);
    final router = AppRoutes.router(initialLocation: '/transfer');
    await pumpRouter(tester, router, container: container);

    device.presence!.refuseNextPrompt();
    await tester.tap(find.text('Confirm and send'));
    await tester.pumpAndSettle();
    expect(
      find.text('Confirmation cancelled. Nothing was sent.'),
      findsOneWidget,
    );
    expect(server.transfers, isEmpty);

    // Still enrolled, and the ambient key still works.
    router.go('/account');
    await tester.pumpAndSettle();
    expect(find.text('Device: device-1'), findsOneWidget);

    // And the user can try again.
    router.go('/transfer');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm and send'));
    await tester.pumpAndSettle();
    expect(server.transfers, ['Ada']);
  });

  testWidgets('a device with no user-present key cannot confirm', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice(userPresent: false);
    final container = await enrol(tester, server, device);
    final router = AppRoutes.router(initialLocation: '/transfer');
    await pumpRouter(tester, router, container: container);
    expect(
      find.textContaining('This device has no user-present key'),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Confirm and send'),
    );
    expect(button.onPressed, isNull);
  });
}
