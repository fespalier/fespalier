// InboundLaunch and launchRouter (since 0.11.0): a launch beats the platform's initial route and
// marks the first navigation; a platform deep link is tagged `link` (cold start and warm), an
// in-app `go` is not, and the web tags nothing. No timer.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/inbound.dart'
    show debugInboundWeb, debugResetPlatformLinks;
import 'package:fespalier/startup.dart'
    show FespalierAdapter, FespalierAdapters;
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

late RecordingTelemetry rec;

Widget page(String label) => Scaffold(body: Text(label));

GoRouter make({
  String initial = '/home',
  InboundLaunch? launch,
  bool links = true,
  OnEnter? onEnter,
}) => launchRouter(launch, (launch) {
  final r = GoRouter(
    initialLocation: launch?.location ?? initial,
    initialExtra: launch?.extra,
    overridePlatformDefaultLocation: launch != null,
    onEnter: onEnter,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(
        path: '/orders/:id',
        builder: (_, s) => page('order ${s.pathParameters['id']}'),
      ),
      GoRoute(path: '/settings', builder: (_, _) => page('settings')),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}, links: links);

Future<void> legacyPush(WidgetTester tester, String location) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(MethodCall('pushRoute', location)),
    (_) {},
  );
  await tester.pumpAndSettle();
}

Future<void> platformPush(WidgetTester tester, String location) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    const JSONMethodCodec().encodeMethodCall(
      MethodCall('pushRouteInformation', {'location': location}),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

Iterable<String> starts() =>
    rec.log.where((l) => l.contains(' start navigate '));

void platformRoute(WidgetTester tester, String location) {
  tester.binding.platformDispatcher.defaultRouteNameTestValue = location;
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
}

void main() {
  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    debugInboundWeb = null;
    debugResetPlatformLinks();
  });

  test('InboundLaunch.to takes the typed location, and asserts the source', () {
    final launch = InboundLaunch.to(
      const _Route('/orders/42'),
      source: NavigationSource.shortcut,
      extra: 7,
    );
    expect(launch.location, '/orders/42');
    expect(launch.source, 'shortcut');
    expect(launch.extra, 7);
    expect(
      () => InboundLaunch('/x', source: 'banner'),
      throwsA(isA<AssertionError>()),
    );
  });

  testWidgets('a launch beats the platform route and marks the navigation', (
    tester,
  ) async {
    platformRoute(tester, '/settings');
    final r = make(
      launch: InboundLaunch(
        '/orders/42',
        source: NavigationSource.notification,
      ),
    );
    await pumpRouter(tester, r);
    expect(find.text('order 42'), findsOneWidget);
    expect(starts(), ['#1 start navigate /orders/42 source=notification']);
  });

  testWidgets('without a launch the platform route still wins, tagged link', (
    tester,
  ) async {
    platformRoute(tester, '/settings');
    await pumpRouter(tester, make());
    expect(find.text('settings'), findsOneWidget);
    expect(starts(), ['#1 start navigate /settings source=link']);
  });

  testWidgets('a cold start at the root is not a link', (tester) async {
    await pumpRouter(tester, make());
    expect(starts(), ['#1 start navigate /home']);
  });

  testWidgets('with links off nothing is tagged', (tester) async {
    platformRoute(tester, '/settings');
    await pumpRouter(tester, make(links: false));
    expect(starts(), ['#1 start navigate /settings']);
  });

  testWidgets('a warm platform link is tagged, an in-app go to it is not', (
    tester,
  ) async {
    final r = make();
    await pumpRouter(tester, r);
    rec.log.clear();
    await platformPush(tester, '/orders/7');
    expect(find.text('order 7'), findsOneWidget);
    r.go('/settings');
    await tester.pumpAndSettle();
    r.go('/orders/7');
    await tester.pumpAndSettle();
    expect(starts(), [
      '#2 start navigate /orders/7 source=link',
      '#3 start navigate /settings',
      '#4 start navigate /orders/7',
    ]);
  });

  testWidgets('navigateFrom wins over a platform link', (tester) async {
    final r = make();
    await pumpRouter(tester, r);
    rec.log.clear();
    navigateFrom(NavigationSource.widget, () => r.go('/settings'));
    await tester.pumpAndSettle();
    expect(starts(), ['#2 start navigate /settings source=widget']);
  });

  testWidgets('on the web nothing is tagged', (tester) async {
    debugInboundWeb = true;
    platformRoute(tester, '/settings');
    final r = make();
    await pumpRouter(tester, r);
    await platformPush(tester, '/orders/7');
    expect(starts().where((l) => l.contains('source=')), isEmpty);
  });

  testWidgets('FespalierAdapters.onEnter sees a platform link as link', (
    tester,
  ) async {
    final seen = <(String, bool, String?)>[];
    final all = FespalierAdapters([_Spy(seen)]);
    final r = make(onEnter: all.onEnter);
    await pumpRouter(tester, r);
    await platformPush(tester, '/orders/7');
    r.go('/settings');
    await tester.pumpAndSettle();
    expect(seen, [
      ('/home', true, null),
      ('/orders/7', false, 'link'),
      ('/settings', false, null),
    ]);
  });

  testWidgets('a cold start link reaches onEnter as the initial link', (
    tester,
  ) async {
    platformRoute(tester, '/settings');
    final seen = <(String, bool, String?)>[];
    final r = make(onEnter: FespalierAdapters([_Spy(seen)]).onEnter);
    await pumpRouter(tester, r);
    expect(seen, [('/settings', true, 'link')]);
  });

  testWidgets('a launch does not stop later platform links being tagged', (
    tester,
  ) async {
    final seen = <(String, bool, String?)>[];
    final r = make(
      launch: InboundLaunch('/orders/42', source: NavigationSource.shortcut),
      onEnter: FespalierAdapters([_Spy(seen)]).onEnter,
    );
    await pumpRouter(tester, r);
    rec.log.clear();
    await platformPush(tester, '/settings');
    expect(starts(), ['#2 start navigate /settings source=link']);
    expect(seen.last, ('/settings', false, 'link'));
  });

  for (final payload in [
    'https://example.com/orders/7',
    'https://example.com/orders/7/',
    'vaam://app/orders/7',
    'orders/7',
  ]) {
    testWidgets('a platform payload of $payload is tagged and seen as link', (
      tester,
    ) async {
      final seen = <(String, bool, String?)>[];
      final r = make(onEnter: FespalierAdapters([_Spy(seen)]).onEnter);
      await pumpRouter(tester, r);
      rec.log.clear();
      await platformPush(tester, payload);
      expect(starts().single, endsWith('source=link'));
      expect(seen.last.$3, 'link');
    });
  }

  testWidgets('the legacy pushRoute is a link too', (tester) async {
    final r = make();
    await pumpRouter(tester, r);
    rec.log.clear();
    await legacyPush(tester, '/orders/7');
    expect(starts(), ['#2 start navigate /orders/7 source=link']);
  });

  testWidgets(
    'a router made with links off is never tagged, whatever ran before',
    (tester) async {
      make().dispose(); // registers the observer
      final r = make(links: false);
      await pumpRouter(tester, r);
      rec.log.clear();
      await platformPush(tester, '/orders/7');
      expect(starts().single, endsWith('start navigate /orders/7'));
    },
  );

  testWidgets('a Block.then rewrite keeps the link mark', (tester) async {
    final r = make(onEnter: FespalierAdapters([_Rewrite()]).onEnter);
    await pumpRouter(tester, r);
    rec.log.clear();
    await platformPush(tester, 'vaam://app/custom');
    expect(find.text('order 9'), findsOneWidget);
    expect(starts(), [
      '#2 start navigate vaam://app/custom source=link',
      '#3 start navigate /orders/9 source=link',
    ]);
  });

  testWidgets('a launch is not passed to make on the web', (tester) async {
    debugInboundWeb = true;
    InboundLaunch? got = InboundLaunch('/x', source: NavigationSource.link);
    // The debug assert says a launch is not used on the web; the router still gets none.
    try {
      launchRouter(null, (l) {
        got = l;
        return make();
      });
    } finally {
      debugInboundWeb = null;
    }
    expect(got, isNull);
  });
}

class _Route extends TypedLocation {
  const _Route(this.location);

  @override
  final String location;
}

class _Spy extends FespalierAdapter {
  _Spy(this.seen);

  final List<(String, bool, String?)> seen;

  @override
  FutureOr<OnEnterResult>? onEnter(InboundNavigation navigation) {
    seen.add((navigation.next.uri.path, navigation.initial, navigation.source));
    return null;
  }
}

class _Rewrite extends FespalierAdapter {
  @override
  FutureOr<OnEnterResult>? onEnter(InboundNavigation navigation) {
    if (navigation.next.uri.path != '/custom') return null;
    return Block.then(() => navigation.router.go('/orders/9'));
  }
}
