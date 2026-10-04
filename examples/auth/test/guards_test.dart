// The guards of lib/app: a session for the (signed-in) group, a role for /admin, and the sign-in
// page's own guard. fakeAuth signs a test in or out with no network.
import 'dart:async';

import 'package:auth/api.dart';
import 'package:auth/app.g.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const ada = AuthUser(id: 'ada-id', name: 'Ada Example', roles: {'admin'});
const bob = AuthUser(id: 'bob-id', name: 'Bob Example');

/// An API that answers an empty list of orders.
List<Override> signedIn(AuthUser user) => fakeAuth(
  signedInAs: user,
  apiOrigins: [apiOrigin],
  client: MockClient((request) async => http.Response('[]', 200)),
);

void main() {
  testWidgets('signed out, /orders goes to sign-in with where it was going', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders'),
      overrides: fakeAuth(),
    );
    expect(currentLocation(tester), '/sign-in?from=%2Forders');
    expect(find.text('Sign in to see /orders'), findsOneWidget);
  });

  testWidgets('signed in, /orders opens', (tester) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders'),
      overrides: signedIn(ada),
    );
    expect(currentLocation(tester), '/orders');
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('the home page is public', (tester) async {
    await pumpRouter(tester, AppRoutes.router(), overrides: fakeAuth());
    expect(currentLocation(tester), '/');
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('/admin: an admin gets in, bob is sent to /forbidden', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/admin'),
      overrides: signedIn(ada),
    );
    expect(currentLocation(tester), '/admin');
    expect(find.text('Only an admin sees this.'), findsOneWidget);

    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/admin'),
      overrides: signedIn(bob),
    );
    expect(currentLocation(tester), '/forbidden');
  });

  testWidgets('signing out on /orders/1 moves to sign-in, from that page', (
    tester,
  ) async {
    final container = await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/orders/1'),
      overrides: signedIn(ada),
    );
    expect(currentLocation(tester), '/orders/1');
    unawaited(container.read(authSession.notifier).signOut());
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/sign-in?from=%2Forders%2F1');
  });

  testWidgets('a signed-in user on /sign-in goes home, and never off the app', (
    tester,
  ) async {
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/sign-in'),
      overrides: signedIn(ada),
    );
    expect(currentLocation(tester), '/');
    await pumpRouter(
      tester,
      AppRoutes.router(
        initialLocation:
            '/sign-in?from=${Uri.encodeQueryComponent('//evil.example.com')}',
      ),
      overrides: signedIn(ada),
    );
    expect(currentLocation(tester), '/');
  });

  testWidgets('the home page says who is signed in, and signs out', (
    tester,
  ) async {
    await pumpRouter(tester, AppRoutes.router(), overrides: signedIn(ada));
    expect(find.text('Signed in as Ada Example'), findsOneWidget);
    expect(find.text('Admin'), findsWidgets);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Signed out'), findsOneWidget);
  });
}
