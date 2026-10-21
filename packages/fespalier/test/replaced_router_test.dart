// A router the app replaces without dispose() (#264). With telemetry attached, the replaced
// router's route information provider keeps telemetry's listener, so go_router keeps the provider
// registered as a binding observer, and it answers the platform link before the router on screen
// does. docs/observability.md says so and asks for a dispose; a fix moves the link to the router on
// screen, and then this file and the docs change together. No timer.
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

/// Shows a router, then replaces it with a second one, as an app does with `MaterialApp.router`.
/// Returns the replaced router. [disposeFirst] disposes it after the swap; without it the test
/// disposes it at the end, because a router left undisposed keeps taking links for the rest of the
/// run (the lesson of #263).
Future<GoRouter> replace(
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
  return first;
}

void main() {
  setUp(() => FespalierTelemetry.install(RecordingTelemetry()));
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets(
    'with telemetry, a replaced router that is not disposed keeps the platform links (#264)',
    (tester) async {
      final first = await replace(tester, telemetry: true, disposeFirst: false);
      await sendPlatformLink(
        tester,
        Uri.parse('https://shop.example.com/orders/7'),
      );
      // The limit docs/observability.md states. If this fails, the link reaches the router on
      // screen: update this test and the docs together.
      expect(
        find.text('home b'),
        findsOneWidget,
        reason: 'the router on screen did not get the link',
      );
      expect(
        first.routeInformationProvider.value.uri.path,
        '/orders/7',
        reason: 'the replaced router took the link (the documented limit)',
      );
    },
  );

  testWidgets(
    'control: without telemetry, a replaced router that is not disposed does not take the link',
    (tester) async {
      final first = await replace(
        tester,
        telemetry: false,
        disposeFirst: false,
      );
      await sendPlatformLink(
        tester,
        Uri.parse('https://shop.example.com/orders/7'),
      );
      expect(find.text('order 7 b'), findsOneWidget);
      expect(first.routeInformationProvider.value.uri.path, '/home');
    },
  );

  testWidgets(
    'with telemetry, a replaced router that is disposed does not take the link',
    (tester) async {
      final first = await replace(tester, telemetry: true, disposeFirst: true);
      await sendPlatformLink(
        tester,
        Uri.parse('https://shop.example.com/orders/7'),
      );
      expect(find.text('order 7 b'), findsOneWidget);
      expect(first.routeInformationProvider.value.uri.path, '/home');
    },
  );
}
