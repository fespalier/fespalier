// Enrolling the device is signing in: the phone number, then the code, and the guard sends the user
// back to where they were going.
import 'package:device/app.g.dart';
import 'package:device/demo/demo_api.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  testWidgets('enrolling opens the signed-in route it was going to', (
    tester,
  ) async {
    final server = DemoApi();
    final device = FakeDevice();
    final container = await enrol(
      tester,
      server,
      device,
      initialLocation: '/account',
    );
    // The guard sent the user to the enrolment page with where they were going, and back.
    expect(currentLocation(tester), '/account');
    expect(find.text('Phone: $normalisedPhone'), findsOneWidget);
    expect(find.text('Device: device-1'), findsOneWidget);
    expect(find.text('Signed with the ambient key'), findsOneWidget);
    expect(container.read(authSession), isA<SignedIn>());
    expect(server.smsSent, [normalisedPhone]);
    expect(server.enrolments, 1);
    // The subject came from the phone number the code went to, not from the client.
    expect(container.read(authUser)!.id, 'user-237655000000');
    expect(
      device.prompts,
      1,
      reason: 'the user-present key signed its challenge',
    );
  });

  testWidgets('a signed-out /account says where the user was going', (
    tester,
  ) async {
    final server = DemoApi();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/account'),
      overrides: await deviceOverrides(server, FakeDevice()),
    );
    expect(currentLocation(tester), '/enrol?from=%2Faccount');
    expect(find.text('Enrol to see /account'), findsOneWidget);
    expect(server.served, isEmpty);
  });

  testWidgets('a wrong phone number and a wrong code are field errors', (
    tester,
  ) async {
    final server = DemoApi();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/enrol'),
      overrides: await deviceOverrides(server, FakeDevice()),
    );
    await tester.enterText(find.byType(TextField), 'call me');
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter a phone number like +237 6 55 00 00 00'),
      findsOneWidget,
    );
    expect(server.smsSent, isEmpty);

    await tester.enterText(find.byType(TextField), phone);
    await tester.tap(find.widgetWithText(FilledButton, 'Send code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '000000');
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
    await tester.pumpAndSettle();
    expect(find.text('That code is not right'), findsOneWidget);
    expect(currentLocation(tester), '/enrol');
    expect(server.enrolments, 0);

    // The same challenge, the right code.
    await tester.enterText(find.byType(TextField), DemoApi.demoCode);
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm code'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    expect(find.text('Signed in as $normalisedPhone'), findsOneWidget);
  });

  testWidgets('the web enrols with the ambient key alone', (tester) async {
    final server = DemoApi();
    final device = FakeDevice(userPresent: false);
    await enrol(tester, server, device);
    expect(currentLocation(tester), '/');
    expect(server.enrolments, 1);
    expect(device.prompts, 0);
  });
}
