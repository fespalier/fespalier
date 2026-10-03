// FespalierOtel on the real dartastic SDK, with an in-memory exporter: what a navigation, a
// guard, a data load, an action and a deferred load become. A hand-built router calls the
// runtime helpers the way a generated app.g.dart does.
import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite guardSite = TelemetrySite(
  'checkout/guard.dart',
  route: '/checkout',
);
const TelemetrySite dataSite = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);
const TelemetrySite actionSite = TelemetrySite(
  'items/\$id/action.dart',
  route: '/items/:id',
  name: 'rename',
);

final InMemorySpanExporter exporter = InMemorySpanExporter();

/// What the guard of `/checkout` answers next.
FutureOr<String?> Function() checkout = () => null;

final item = FutureProvider.autoDispose.family<String, int>(
  (ref, id) => traceData(
    ref,
    'd1',
    id,
    Future<String>.microtask(() => 'item $id'),
    telemetry: dataSite,
  ),
);

Widget page(String label) => Scaffold(body: Text(label));

GoRouter router({String initial = '/home'}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(
        path: '/items/:id',
        builder: (context, s) => Consumer(
          builder: (context, ref, _) {
            ref.watch(item(int.parse(s.pathParameters['id']!)));
            return page('item');
          },
        ),
      ),
      GoRoute(path: '/other', builder: (_, _) => page('other')),
      GoRoute(path: '/login', builder: (_, _) => page('login')),
      GoRoute(
        path: '/checkout',
        redirect: (_, state) =>
            traceGuard(state, 'g1@3', checkout(), telemetry: guardSite),
        builder: (_, _) => page('checkout'),
      ),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

List<Span> spans(String prefix) => exporter.findSpansStartingWith(prefix);

Span only(String name) {
  final found = exporter.findSpansByName(name);
  expect(found, hasLength(1), reason: '$name in ${exporter.spanNames}');
  return found.single;
}

void main() {
  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'test',
      serviceVersion: '0.0.1',
      enableLogs: false,
      enableMetrics: false,
      detectPlatformResources: false,
      spanProcessor: SimpleSpanProcessor(exporter),
    );
  });
  setUp(() {
    exporter.clear();
    FespalierTelemetry.install(FespalierOtel());
    checkout = () => null;
  });
  tearDown(() => FespalierTelemetry.install(null));

  group('a navigation', () {
    testWidgets('is a root span, named for its route, with the page events', (
      tester,
    ) async {
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/items/7');
      await tester.pumpAndSettle();
      final nav = only('navigate /items/:id');
      expect(nav.parentSpanContext?.spanId.isValid ?? false, isFalse);
      final a = nav.attributes;
      expect(a.getString('fespalier.operation'), 'navigate');
      expect(a.getString('fespalier.route'), '/items/:id');
      expect(a.getString('fespalier.navigation.kind'), 'go');
      expect(a.getString('fespalier.navigation.outcome'), 'ok');
      expect(a.getString('fespalier.navigation.from'), '/home');
      expect(a.getBool('fespalier.navigation.redirected'), false);
      expect(a.getInt('fespalier.navigation.depth'), 0);
      // Segment values are app data: not recorded unless asked.
      expect(a.getString('url.path'), isNull);
      expect(a.getString('url.query'), isNull);
      expect(nav.spanEvents?.map((e) => e.name), [
        'fespalier.page.leave',
        'fespalier.page.enter',
      ]);
      final leave = nav.spanEvents!.first.attributes!;
      expect(leave.getString('fespalier.route'), '/home');
      expect(leave.getInt('fespalier.page.duration_ms'), isNotNull);
      final enter = nav.spanEvents!.last.attributes!;
      expect(enter.getString('fespalier.route'), '/items/:id');
      expect(enter.getInt('fespalier.page.duration_ms'), isNull);
      expect(nav.status, SpanStatusCode.Unset);
    });

    testWidgets('records the location only when asked', (tester) async {
      FespalierTelemetry.install(FespalierOtel(recordLocations: true));
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/items/7?tab=2');
      await tester.pumpAndSettle();
      final a = only('navigate /items/:id').attributes;
      expect(a.getString('url.path'), '/items/7');
      expect(a.getString('url.query'), 'tab=2');
    });

    testWidgets('every span is made in the fespalier scope, at its version', (
      tester,
    ) async {
      final r = router();
      await pumpRouter(tester, r);
      for (final span in exporter.spans) {
        expect(span.instrumentationScope.name, 'fespalier');
        expect(span.instrumentationScope.version, fespalierVersion);
        expect(span.kind, SpanKind.internal);
      }
      expect(exporter.spans, isNotEmpty);
    });

    testWidgets('not found is an outcome, not an error', (tester) async {
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/nowhere');
      await tester.pumpAndSettle();
      final nav = only('navigate (not found)');
      expect(
        nav.attributes.getString('fespalier.navigation.outcome'),
        'not_found',
      );
      expect(nav.attributes.getString('fespalier.route'), isNull);
      expect(nav.status, SpanStatusCode.Unset);
    });

    testWidgets('a navigation that never committed is superseded', (
      tester,
    ) async {
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/checkout');
      await tester.pump();
      r.go('/items/2');
      await tester.pumpAndSettle();
      final superseded = exporter
          .findSpansByName('navigate')
          .where(
            (s) =>
                s.attributes.getString('fespalier.navigation.outcome') ==
                'superseded',
          );
      expect(superseded, hasLength(1));
      answer.complete(null);
      await tester.pumpAndSettle();
    });
  });

  group('guards, data and actions', () {
    testWidgets('a guard is a child of the navigation it ran in', (
      tester,
    ) async {
      checkout = () => '/login';
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/checkout');
      await tester.pumpAndSettle();
      final nav = only('navigate /login');
      final guard = only('guard checkout/guard.dart');
      expect(guard.parentSpanContext?.spanId, nav.spanContext.spanId);
      final a = guard.attributes;
      expect(a.getString('fespalier.operation'), 'guard');
      expect(a.getString('fespalier.route'), '/checkout');
      expect(a.getString('fespalier.file'), 'checkout/guard.dart');
      expect(a.getString('fespalier.guard.decision'), 'redirect');
      expect(a.getBool('fespalier.async'), false);
      // Where it redirected to is app data.
      expect(a.getString('fespalier.guard.location'), isNull);
      expect(nav.attributes.getBool('fespalier.navigation.redirected'), true);
    });

    testWidgets('a guard records where it redirected to when asked', (
      tester,
    ) async {
      FespalierTelemetry.install(FespalierOtel(recordLocations: true));
      checkout = () => '/login';
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/checkout');
      await tester.pumpAndSettle();
      expect(
        only(
          'guard checkout/guard.dart',
        ).attributes.getString('fespalier.guard.location'),
        '/login',
      );
    });

    testWidgets(
      'an async guard that fails is an error span with the exception',
      (tester) async {
        checkout = () => Future<String?>.error(StateError('boom'));
        final r = router();
        await pumpRouter(tester, r);
        exporter.clear();
        await runZonedGuarded(() async {
          r.go('/checkout');
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pump();
        }, (error, _) {});
        final guard = only('guard checkout/guard.dart');
        expect(guard.status, SpanStatusCode.Error);
        expect(guard.statusDescription, 'Bad state: boom');
        expect(guard.attributes.getString('error.type'), 'StateError');
        expect(guard.attributes.getString('fespalier.guard.decision'), 'error');
        expect(guard.attributes.getBool('fespalier.async'), true);
        expect(guard.spanEvents?.map((e) => e.name), contains('exception'));
      },
    );

    testWidgets('a data load that shows a page is a child of its navigation', (
      tester,
    ) async {
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/items/3');
      await tester.pumpAndSettle();
      final nav = only('navigate /items/:id');
      final data = only('data items/\$id/data.dart');
      expect(data.parentSpanContext?.spanId, nav.spanContext.spanId);
      expect(data.attributes.getString('fespalier.data.state'), 'data');
      expect(data.attributes.getBool('fespalier.data.keyed'), true);
      expect(data.attributes.getBool('fespalier.async'), true);
      expect(data.attributes.getString('fespalier.route'), '/items/:id');
    });

    test('an action is a span of its own, with its name and result', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final rename = actionProvider<String, String>(
        (ref, input) async => input.toUpperCase(),
        invalidates: () => const [],
        telemetry: actionSite,
      );
      c.listen(rename, (_, _) {});
      await c.read(rename.notifier).call('a');
      final span = only('action items/\$id/action.dart#rename');
      expect(span.parentSpanContext?.spanId.isValid ?? false, isFalse);
      expect(span.attributes.getString('fespalier.action.name'), 'rename');
      expect(span.attributes.getString('fespalier.action.result'), 'ok');
      expect(span.attributes.getBool('fespalier.async'), true);
    });

    test('a failed action is an error span', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final rename = actionProvider<String, String>(
        (ref, input) => throw StateError('no'),
        invalidates: () => const [],
        telemetry: actionSite,
      );
      c.listen(rename, (_, _) {});
      expect(() => c.read(rename.notifier).call('a'), throwsStateError);
      final span = only('action items/\$id/action.dart#rename');
      expect(span.status, SpanStatusCode.Error);
      expect(span.attributes.getString('fespalier.action.result'), 'error');
      expect(span.attributes.getString('error.type'), 'StateError');
      expect(span.attributes.getBool('fespalier.async'), false);
    });

    test('a deferred load', () async {
      final lib = DeferredLibrary(
        () async {},
        'shop/page.dart',
        loadsInFakeAsync: true,
        route: '/shop',
      );
      await lib.load();
      final span = only('deferred shop/page.dart');
      expect(span.attributes.getString('fespalier.operation'), 'deferred');
      expect(span.attributes.getString('fespalier.route'), '/shop');
      expect(span.attributes.getString('fespalier.file'), 'shop/page.dart');
      expect(span.attributes.getString('fespalier.deferred.result'), 'ok');
    });
  });

  test('a span is exported at once when it ends: no waiting for a timer', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final rename = actionProvider<String, String>(
      (ref, input) => input,
      invalidates: () => const [],
      telemetry: actionSite,
    );
    c.listen(rename, (_, _) {});
    c.read(rename.notifier).call('a');
    expect(exporter.spanNames, ['action items/\$id/action.dart#rename']);
  });
}
