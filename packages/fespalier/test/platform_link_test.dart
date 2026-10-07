// sendPlatformLink and telemetryFollows (since 0.12.0).
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/inbound.dart' show debugResetPlatformLinks;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget page(String label) => Scaffold(body: Text(label));

// Built the way a generated `AppRoutes.router` does with `links: true` (an app with telemetry
// or adapters), which is what tags and normalises a platform link.
GoRouter make({bool telemetry = false}) => launchRouter(null, (_) {
  final r = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(
        path: '/orders/:id',
        builder: (_, s) => page('order ${s.pathParameters['id']}'),
      ),
    ],
  );
  if (telemetry) telemetryAttach(r, base: () => '/');
  return r;
}, links: true);

void main() {
  tearDown(() {
    FespalierTelemetry.install(null);
    debugResetPlatformLinks();
  });

  testWidgets('sendPlatformLink opens an https link in the router', (
    tester,
  ) async {
    await pumpRouter(tester, make());
    await sendPlatformLink(
      tester,
      Uri.parse('https://shop.example.com/orders/42?ref=mail'),
    );
    expect(find.text('order 42'), findsOneWidget);
    expect(currentLocation(tester), contains('/orders/42?ref=mail'));
  });

  testWidgets('sendPlatformLink opens a custom scheme link', (tester) async {
    await pumpRouter(tester, make());
    await sendPlatformLink(tester, Uri.parse('shop:///orders/7'));
    expect(find.text('order 7'), findsOneWidget);
  });

  testWidgets('a platform link is reported with source link', (tester) async {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    await pumpRouter(tester, make(telemetry: true));
    rec.log.clear();
    await sendPlatformLink(
      tester,
      Uri.parse('https://shop.example.com/orders/9'),
    );
    expect(rec.log.where((l) => l.contains(' start navigate ')), [
      endsWith('source=link'),
    ]);
  });

  testWidgets('telemetryFollows is true only once telemetryAttach ran', (
    tester,
  ) async {
    final plain = make();
    final followed = make(telemetry: true);
    addTearDown(plain.dispose);
    addTearDown(followed.dispose);
    expect(telemetryFollows(plain), isFalse);
    expect(telemetryFollows(followed), isTrue);
  });

  testWidgets('telemetryFollows makes no watch of its own', (tester) async {
    final plain = make();
    addTearDown(plain.dispose);
    expect(telemetryFollows(plain), isFalse);
    expect(telemetryFollows(plain), isFalse);
    telemetryAttach(plain, base: () => '/');
    expect(telemetryFollows(plain), isTrue);
  });
}
