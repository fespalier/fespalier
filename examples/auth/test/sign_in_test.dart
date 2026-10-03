// The sign-in form against the demo server: a sign-in sends the user back to where they were
// going, with no navigation code in the page, and a failure shows under its field.
import 'package:auth/demo/demo_server.dart';
import 'package:auth/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<void> fill(WidgetTester tester, String user, String password) async {
  await tester.enterText(find.byType(TextField).first, user);
  await tester.enterText(find.byType(TextField).last, password);
}

void main() {
  testWidgets('signing in sends the user back to where they were going', (
    tester,
  ) async {
    final server = DemoServer();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders/1'),
      overrides: demoOverrides(server),
    );
    expect(currentLocation(tester), '/sign-in?from=%2Forders%2F1');

    await fill(tester, 'ada', 'ada');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // No context.go in the page: the sign-in guard sent the user back.
    expect(currentLocation(tester), '/orders/1');
    expect(find.text('Ada Example: order 1'), findsOneWidget);
    expect(server.logins, 1);
    expect(
      server.requests,
      containsAllInOrder(['POST /auth/login', 'GET /orders/1']),
    );
  });

  testWidgets('a wrong password is the field error the backend threw', (
    tester,
  ) async {
    final server = DemoServer();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: demoOverrides(server),
    );
    await fill(tester, 'ada', 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong user name or password'), findsOneWidget);
    expect(currentLocation(tester), '/sign-in');
  });

  testWidgets('empty fields are refused before the backend is asked', (
    tester,
  ) async {
    final server = DemoServer();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: demoOverrides(server),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your user name'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(server.logins, 0);
    expect(server.requests, isEmpty);
  });

  testWidgets('the button is disabled while the sign-in runs', (tester) async {
    final server = DemoServer(latency: const Duration(milliseconds: 100));
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: demoOverrides(server),
    );
    await fill(tester, 'bob', 'bob');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.text('Signing in...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    expect(find.text('Signed in as Bob Example'), findsOneWidget);
  });

  testWidgets('bob is signed in, but /admin is forbidden to him', (
    tester,
  ) async {
    final server = DemoServer();
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/admin'),
      overrides: demoOverrides(server),
    );
    expect(currentLocation(tester), '/sign-in?from=%2Fadmin');
    await container
        .read(authSession.notifier)
        .signIn(const PasswordSignIn(username: 'bob', password: 'bob'));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/forbidden');
  });
}
