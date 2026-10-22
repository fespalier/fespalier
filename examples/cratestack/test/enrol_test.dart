// Enrolling the device is signing in: two unsigned legs through the generated client over the plain
// chain, and from then on every call is signed, with no Authorization header at all.
import 'package:cratestack_example/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_server.dart';
import 'support.dart';

void main() {
  testWidgets('enrolling signs the device in, and the legs go out unsigned', (
    tester,
  ) async {
    final server = FakeOrdersServer();
    final device = FakeDevice();
    final container = await enrol(tester, server, device);

    expect(container.read(authSession), isA<SignedIn>());
    expect(container.read(authUser)?.name, '+237655000000');
    expect(server.enrolments, 1);
    // The page went back to where it was going: the public home.
    expect(find.text('Signed in as +237655000000'), findsOneWidget);

    expect(server.served.map((s) => '$s'), [
      'POST beginEnrolment',
      'POST confirmEnrolment',
    ]);
    expect(
      server.served.any((s) => s.signed),
      isFalse,
      reason:
          'a device with no session cannot sign: the legs are unsigned by construction',
    );
    // The server derives the subject from the phone; the client never says who it is.
    expect(
      server.served.first.args.keys,
      unorderedEquals(['phone', 'ambient', 'userPresent']),
    );
  });

  testWidgets(
    'every call after that is signed by the device, with no Authorization',
    (tester) async {
      final server = FakeOrdersServer();
      final device = FakeDevice();
      final container = await enrol(tester, server, device);
      final router = AppRoutes.router(initialLocation: '/orders');
      await pumpRouter(tester, router, container: container);
      router.go('/orders/1');
      await tester.pumpAndSettle();

      final calls = server.signedCalls;
      expect(calls.map((c) => c.op), ['listOrders', 'getOrder']);
      for (final call in calls) {
        expect(call.headers, contains('x-attestation'));
        expect(call.headers, contains('x-signature'));
        expect(call.signedWith?.name, 'ambient');
        expect(call.refusedWith, isNull);
      }
      expect(server.authorizationHeaders, 0);
    },
  );

  testWidgets(
    'a wrong number or code is the FieldErrors the server answered, under its field',
    (tester) async {
      final server = FakeOrdersServer();
      await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/enrol'),
        overrides: await appOverrides(server, FakeDevice()),
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      expect(find.textContaining("field 'phone'"), findsOneWidget);

      await tester.enterText(find.byType(TextField), phone);
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '000000');
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
      await tester.pumpAndSettle();
      expect(find.textContaining("field 'otp'"), findsOneWidget);
      expect(server.enrolments, 0);

      await tester.enterText(find.byType(TextField), FakeOrdersServer.otp);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
      await tester.pumpAndSettle();
      expect(server.enrolments, 1);
    },
  );

  testWidgets(
    'a guarded page sends a device that is not enrolled to the enrolment, and back',
    (tester) async {
      final server = FakeOrdersServer();
      final container = await pumpRouter(
        tester,
        AppRoutes.router(initialLocation: '/orders'),
        overrides: await appOverrides(server, FakeDevice()),
      );
      expect(find.text('Enrol to see /orders'), findsOneWidget);
      expect(server.served, isEmpty, reason: 'nothing was asked of the server');

      await tester.enterText(find.byType(TextField), phone);
      await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), FakeOrdersServer.otp);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
      await tester.pumpAndSettle();
      expect(container.read(authSession), isA<SignedIn>());
      expect(find.text('1 x Espresso beans'), findsNothing);
      expect(find.text('2 x Espresso beans'), findsOneWidget);
    },
  );
}
