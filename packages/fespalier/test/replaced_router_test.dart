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

GoRouter router(String label, {required bool telemetry, bool guarded = false}) {
  final r = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        // A guard that passes, as a generated app's redirect runs it. The guards of a router must
        // not keep its route information provider registered as a binding observer (since 0.21.0).
        redirect: guarded
            ? (context, state) => runRedirect(
                () => refGuard(context, 'g@home $label', (ref) => null),
              )
            : null,
        builder: (_, _) => page('home $label'),
      ),
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
  bool guarded = false,
}) async {
  Widget app(GoRouter r) =>
      ProviderScope(child: MaterialApp.router(routerConfig: r));
  final first = router('a', telemetry: telemetry, guarded: guarded);
  await tester.pumpWidget(app(first));
  await tester.pumpAndSettle();

  final second = router('b', telemetry: telemetry, guarded: guarded);
  addTearDown(second.dispose);
  await tester.pumpWidget(app(second));
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

  // The guards of a router keep a subscription to what they watch and listen to the router's
  // delegate, and nothing else: a listener on the route information provider, which go_router
  // registers as a platform observer for as long as it has one, would take the platform's links for
  // the router that was replaced (#264), in every app with a guard and not only with telemetry.
  testWidgets(
    'with a guard and no telemetry, a replaced router that is not disposed does not take the link',
    (tester) async {
      final first = await replace(
        tester,
        telemetry: false,
        disposeFirst: false,
        guarded: true,
      );
      await sendPlatformLink(
        tester,
        Uri.parse('https://shop.example.com/orders/7'),
      );
      expect(find.text('order 7 b'), findsOneWidget);
      expect(first.routeInformationProvider.value.uri.path, '/home');
    },
  );
}
