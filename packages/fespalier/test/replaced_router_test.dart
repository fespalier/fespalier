// A router the app replaces without dispose() (#264). With telemetry attached, the replaced
// router's route information provider keeps telemetry's listener, so go_router keeps the provider
// registered as a binding observer, and it answers every platform link before the router on
// screen does. No timer.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget page(String text) => Scaffold(body: Text(text));

GoRouter router(String label, {required bool telemetry}) {
  final r = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home $label')),
      GoRoute(
        path: '/orders/:id',
        builder: (_, s) => page('order ${s.pathParameters['id']} $label'),
      ),
    ],
  );
  if (telemetry) telemetryAttach(r, base: () => '/');
  return r;
}

/// Shows [first], replaces it with a second router, and sends a platform link. [disposeFirst]
/// disposes the replaced router after the swap, as an app does; without it the test disposes it
/// at the end, because a router left undisposed keeps taking links for the rest of the run.
Future<void> replaceAndSendLink(
  WidgetTester tester, {
  required bool telemetry,
  required bool disposeFirst,
}) async {
  final first = router('a', telemetry: telemetry);
  await tester.pumpWidget(MaterialApp.router(routerConfig: first));
  await tester.pumpAndSettle();

  final second = router('b', telemetry: telemetry);
  addTearDown(second.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: second));
  await tester.pumpAndSettle();

  if (disposeFirst) {
    first.dispose();
  } else {
    addTearDown(first.dispose);
  }

  await sendPlatformLink(
    tester,
    Uri.parse('https://shop.example.com/orders/7'),
  );

  expect(
    find.text('order 7 b'),
    findsOneWidget,
    reason: 'the router on screen takes the link',
  );
  expect(
    first.routeInformationProvider.value.uri.path,
    '/home',
    reason: 'the replaced router does not take the link',
  );
}

void main() {
  setUp(() => FespalierTelemetry.install(RecordingTelemetry()));
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets(
    'with telemetry, a replaced router that is not disposed does not take the link (#264)',
    (tester) =>
        replaceAndSendLink(tester, telemetry: true, disposeFirst: false),
  );

  testWidgets(
    'control: without telemetry, a replaced router that is not disposed does not take the link',
    (tester) =>
        replaceAndSendLink(tester, telemetry: false, disposeFirst: false),
  );

  testWidgets(
    'with telemetry, a replaced router that is disposed does not take the link',
    (tester) => replaceAndSendLink(tester, telemetry: true, disposeFirst: true),
  );
}
