// FespalierOtel on the real dartastic SDK, with an in-memory exporter: what a navigation, a
// guard, a data load, an action and a deferred load become. A hand-built router calls the
// runtime helpers the way a generated app.g.dart does.
import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/telemetry.dart'
    show telemetryNavigationEnd, telemetryNavigationStart;
import 'package:fespalier/testing.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite guardSite = TelemetrySite(
  'checkout/guard.dart',
  route: '/checkout',
);
const TelemetrySite redirectSite = TelemetrySite(
  'old/redirect.dart',
  route: '/old',
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

/// The golden lists of what fespalier emits, contract version 1. A name that is not in them was
/// added (add it here, and to docs/telemetry-conventions.md); one that is gone was renamed or
/// removed, which is version 2. Each test is checked against them when it ends, and the file as a
/// whole when its last test has run (`tearDownAll`).
const Set<String> contractSpans = {
  'navigate',
  'navigate (not found)',
  'guard',
  'redirect',
  'data',
  'action',
  'deferred',
  'auth',
  'image',
  'custom',
  'http',
};
const Set<String> contractKeys = {
  'fespalier.operation',
  'fespalier.route',
  'fespalier.file',
  'fespalier.async',
  'error.type',
  'fespalier.navigation.kind',
  'fespalier.navigation.outcome',
  'fespalier.navigation.from',
  'fespalier.navigation.redirected',
  'fespalier.navigation.depth',
  'fespalier.navigation.source',
  'url.path',
  'url.query',
  'fespalier.guard.decision',
  'fespalier.guard.location',
  'fespalier.data.state',
  'fespalier.data.keyed',
  'fespalier.data.attempt',
  'fespalier.data.source',
  'fespalier.action.name',
  'fespalier.action.result',
  'fespalier.action.rolled_back',
  'fespalier.action.invalid',
  'fespalier.deferred.result',
  'fespalier.auth.operation',
  'fespalier.auth.result',
  'fespalier.auth.backend',
  'fespalier.auth.trigger',
  'fespalier.auth.scheme',
  'fespalier.image.cdn',
  'fespalier.image.width',
  'fespalier.image.preload',
  'fespalier.image.result',
  'fespalier.image.status',
  'fespalier.custom.name',
  'fespalier.custom.result',
  'http.request.method',
  'server.address',
  'server.port',
  'url.scheme',
  'http.response.status_code',
  'http.request.resend_count',
};
const Set<String> contractEvents = {
  'fespalier.page.enter',
  'fespalier.page.focus',
  'fespalier.page.leave',
  'exception',
};

/// The keys of the events that start with `fespalier.`.
const Set<String> contractEventKeys = {
  'fespalier.route',
  'fespalier.page.duration_ms',
};

/// The names fespalier emitted: spans, their attribute keys, events and their attribute keys.
class Emitted {
  final Set<String> spans = {};
  final Set<String> keys = {};
  final Set<String> events = {};
  final Set<String> eventKeys = {};

  void addAll(Emitted other) {
    spans.addAll(other.spans);
    keys.addAll(other.keys);
    events.addAll(other.events);
    eventKeys.addAll(other.eventKeys);
  }

  void clear() {
    spans.clear();
    keys.clear();
    events.clear();
    eventKeys.clear();
  }
}

/// What the running test made fespalier emit so far (cleared by `setUp`, checked by `tearDown`).
final Emitted thisTest = Emitted();

/// What the tests that have ended made fespalier emit, for the check of the whole file.
final Emitted seen = Emitted();

/// Adds what the exporter holds now to [thisTest]. A test that clears the exporter calls it first.
void remember() {
  for (final span in exporter.spans) {
    // The spans of an HTTP client the tests simulate are not fespalier's.
    if (span.instrumentationScope.name != 'fespalier') continue;
    // A span's name is its operation, then what it is about (a route, a file).
    // A custom span is named by its package (`fespalier.push.open`), and its own
    // `fespalier.push.*` keys are that package's contract, not version 1's.
    final custom = span.name.startsWith('fespalier.');
    // An HTTP span (`OtelTransport`) is named by its method.
    final http = span.attributes.getString('fespalier.operation') == 'http';
    thisTest.spans.add(
      http ? 'http' : (custom ? 'custom' : span.name.split(' ').first),
    );
    if (span.name == 'navigate (not found)') thisTest.spans.add(span.name);
    thisTest.keys.addAll(
      span.attributes.keys.where(
        (k) => !custom || !k.startsWith('fespalier.push.'),
      ),
    );
    for (final event in span.spanEvents ?? const <SpanEvent>[]) {
      thisTest.events.add(event.name);
      thisTest.eventKeys.addAll(event.attributes?.keys ?? const <String>[]);
    }
  }
}

/// Fails when [emitted] holds a name the contract does not list: it was added.
void expectWithinContract(Emitted emitted) {
  const reason =
      'a name that is not in the contract was added (add it to the lists at the top of this file, '
      'and to docs/telemetry-conventions.md)';
  expect(contractSpans, containsAll(emitted.spans), reason: reason);
  expect(contractKeys, containsAll(emitted.keys), reason: reason);
  expect(contractEvents, containsAll(emitted.events), reason: reason);
  expect(
    contractEventKeys,
    containsAll(emitted.eventKeys.where((k) => k.startsWith('fespalier.'))),
    reason: reason,
  );
}

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

/// A data load that makes an HTTP-like request after an await, as `data()` does with a client.
final itemWithRequest = FutureProvider.autoDispose.family<String, int>(
  (ref, id) => traceDataCall(ref, 'd2', id, () async {
    await Future<void>.delayed(Duration.zero);
    OTel.tracerProvider().getTracer('http').startSpan('GET /items/$id').end();
    return 'item $id';
  }, telemetry: dataSite),
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
        path: '/old',
        redirect: (_, state) => runRedirect(
          state,
          () => traceGuard(state, 'r4', '/other', telemetry: redirectSite),
        ),
      ),
      GoRoute(
        path: '/checkout',
        redirect: (_, state) => runRedirect(
          state,
          () => traceGuard(state, 'g1@3', checkout(), telemetry: guardSite),
        ),
        builder: (_, _) => page('checkout'),
      ),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

/// A page that calls [read] in its `initState`, the first thing that runs when the page is built.
class ScreenProbe extends StatefulWidget {
  const ScreenProbe(this.read, {super.key});

  /// Called once, from `initState`.
  final void Function() read;

  @override
  State<ScreenProbe> createState() => _ScreenProbeState();
}

class _ScreenProbeState extends State<ScreenProbe> {
  @override
  void initState() {
    super.initState();
    widget.read();
  }

  @override
  Widget build(BuildContext context) => page('probe');
}

/// A router with `/home` and `/probe` (whose page is a [ScreenProbe] calling [read]), attached to
/// telemetry.
GoRouter probeRouter(void Function() read, {String initial = '/home'}) {
  final r = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(path: '/probe', builder: (_, _) => ScreenProbe(read)),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

/// The string attribute [key] of [span].
String? a(Span span, String key) => span.attributes.getString(key);

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
    thisTest.clear();
    FespalierTelemetry.install(FespalierOtel());
    checkout = () => null;
  });
  tearDown(() {
    remember();
    FespalierTelemetry.install(null);
    seen.addAll(thisTest);
    // Last, so that a name added by this one test fails this one test, in any order.
    expectWithinContract(thisTest);
  });

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

    testWidgets(
      'a redirect.dart is a redirect span, and a pop focuses the page below',
      (tester) async {
        final r = router();
        await pumpRouter(tester, r);
        exporter.clear();
        r.go('/old');
        await tester.pumpAndSettle();
        final redirect = only('redirect old/redirect.dart');
        expect(
          redirect.attributes.getString('fespalier.operation'),
          'redirect',
        );
        expect(
          redirect.attributes.getString('fespalier.guard.decision'),
          'redirect',
        );
        expect(
          only(
            'navigate /other',
          ).attributes.getBool('fespalier.navigation.redirected'),
          true,
        );
        unawaited(r.push<void>('/login'));
        await tester.pumpAndSettle();
        remember();
        exporter.clear();
        r.pop();
        await tester.pumpAndSettle();
        final pop = only('navigate /other');
        expect(pop.attributes.getString('fespalier.navigation.kind'), 'pop');
        expect(pop.spanEvents?.map((e) => e.name), [
          'fespalier.page.leave',
          'fespalier.page.focus',
        ]);
      },
    );

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

    testWidgets('a guard that fails ends its navigation as error, with the '
        'exception on the guard', (tester) async {
      checkout = () => Future<String?>.error(StateError('boom'));
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      await runZonedGuarded(() async {
        r.go('/checkout');
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
      }, (error, _) {});
      final nav = only('navigate');
      expect(nav.attributes.getString('fespalier.navigation.outcome'), 'error');
      expect(nav.status, SpanStatusCode.Error);
      expect(nav.spanEvents?.map((e) => e.name), isNot(contains('exception')));
      expect(nav.attributes.getString('fespalier.route'), isNull);
      final guard = only('guard checkout/guard.dart');
      expect(guard.attributes.getString('fespalier.guard.decision'), 'error');
      expect(guard.status, SpanStatusCode.Error);
      final exception = guard.spanEvents!.singleWhere(
        (e) => e.name == 'exception',
      );
      expect(exception.attributes?.getString('exception.type'), 'StateError');
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

  group('onScreen (since 0.19.0)', () {
    testWidgets(
      'is told the pattern of a committed navigation, never the location',
      (tester) async {
        final screens = <String?>[];
        FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
        final r = router();
        await pumpRouter(tester, r);
        screens.clear();
        r.go('/items/7?tab=2');
        await tester.pumpAndSettle();
        expect(screens, ['/items/:id']);
        for (final screen in screens) {
          expect(screen, isNot(contains('7')));
          expect(screen, isNot(contains('?')));
        }
      },
    );

    testWidgets('a pop tells the page below again', (tester) async {
      final screens = <String?>[];
      FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
      final r = router();
      await pumpRouter(tester, r);
      screens.clear();
      r.go('/other');
      await tester.pumpAndSettle();
      unawaited(r.push<void>('/login'));
      await tester.pumpAndSettle();
      r.pop();
      await tester.pumpAndSettle();
      expect(screens, ['/other', '/login', '/other']);
    });

    testWidgets('a navigation that matched no route tells null', (
      tester,
    ) async {
      final screens = <String?>[];
      FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
      final r = router();
      await pumpRouter(tester, r);
      screens.clear();
      r.go('/nowhere');
      await tester.pumpAndSettle();
      expect(screens, [null]);
    });

    testWidgets('a superseded navigation tells nothing', (tester) async {
      final screens = <String?>[];
      FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
      final answer = Completer<String?>();
      checkout = () => answer.future;
      final r = router();
      await pumpRouter(tester, r);
      screens.clear();
      r.go('/checkout');
      await tester.pump();
      r.go('/items/2');
      await tester.pumpAndSettle();
      expect(screens, ['/items/:id']);
      answer.complete(null);
      await tester.pumpAndSettle();
      expect(screens, ['/items/:id']);
    });

    testWidgets('a throwing onScreen costs nothing', (tester) async {
      // Core prints the first error a sink lets out, once, and then keeps every later diagnostic
      // quiet: an `onScreen` that throws must stay inside `FespalierOtel.commit`.
      final printed = <String?>[];
      final saved = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message);
      try {
        FespalierTelemetry.install(
          FespalierOtel(onScreen: (_) => throw StateError('x')),
        );
        final r = router();
        await pumpRouter(tester, r);
        exporter.clear();
        r.go('/items/7');
        await tester.pumpAndSettle();
      } finally {
        debugPrint = saved;
      }
      expect(
        only('navigate /items/:id').attributes.getString('fespalier.route'),
        '/items/:id',
      );
      expect(tester.takeException(), isNull);
      expect(printed, isEmpty);
    });

    test(
      'a commit told for another operation than a navigation is not heard',
      () {
        final screens = <String?>[];
        FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
        const commit = TelemetryCommit(TelemetryOutcome.ok, route: '/x');
        final data = FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.data, site: dataSite),
        );
        FespalierTelemetry.current!.commit(data, commit);
        FespalierTelemetry.finish(
          data,
          const TelemetryEnd(TelemetryOutcome.ok),
        );
        expect(screens, isEmpty);
        // The same call for a navigation's token is heard: the check above is the operation's.
        final navigation = FespalierTelemetry.begin(
          TelemetryStart(TelemetryOp.navigate, uri: Uri.parse('/x')),
        );
        FespalierTelemetry.current!.commit(navigation, commit);
        FespalierTelemetry.finish(
          navigation,
          const TelemetryEnd(TelemetryOutcome.ok, route: '/x'),
        );
        expect(screens, ['/x']);
      },
    );

    testWidgets('without the SDK it is not called', (tester) async {
      final screens = <String?>[];
      FespalierTelemetry.install(
        FespalierOtel(isReady: () => false, onScreen: screens.add),
      );
      final r = router();
      await pumpRouter(tester, r);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(screens, isEmpty);
    });

    testWidgets('is told at the commit, inside go(), once', (tester) async {
      final screens = <String?>[];
      FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
      final r = router();
      await pumpRouter(tester, r);
      screens.clear();
      r.go('/items/7');
      // No pump: the commit of a synchronous location is inside go().
      expect(screens, ['/items/:id']);
      await tester.pumpAndSettle();
      expect(screens, ['/items/:id']);
    });

    testWidgets('the new page\'s initState already sees its own screen', (
      tester,
    ) async {
      final screens = <String?>[];
      final seen = <String?>[];
      FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
      final r = probeRouter(() => seen.add(screens.lastOrNull));
      await pumpRouter(tester, r);
      r.go('/probe');
      await tester.pumpAndSettle();
      expect(seen, ['/probe']);
    });

    testWidgets('the first page\'s initState sees its own screen too', (
      tester,
    ) async {
      final screens = <String?>[];
      final seen = <String?>[];
      FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
      final r = probeRouter(
        () => seen.add(screens.lastOrNull),
        initial: '/probe',
      );
      await pumpRouter(tester, r);
      expect(seen, ['/probe']);
      expect(screens, ['/probe']);
    });

    testWidgets(
      'two commits before one frame tell both, and the span names the last',
      (tester) async {
        final screens = <String?>[];
        FespalierTelemetry.install(FespalierOtel(onScreen: screens.add));
        final r = router();
        await pumpRouter(tester, r);
        screens.clear();
        checkout = () => null;
        r.go('/checkout');
        checkout = () => '/login';
        r.refresh();
        await tester.pumpAndSettle();
        expect(screens, ['/checkout', '/login']);
        expect(
          only('navigate /login').attributes.getString('fespalier.route'),
          '/login',
        );
      },
    );

    testWidgets('behind a combine it still hears the commit', (tester) async {
      final screens = <String?>[];
      FespalierTelemetry.install(
        FespalierTelemetry.combine([
          RecordingTelemetry(),
          FespalierOtel(onScreen: screens.add),
        ]),
      );
      final r = router();
      await pumpRouter(tester, r);
      screens.clear();
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(screens, ['/items/:id']);
    });
  });

  group('where a navigation came from (since 0.9.0)', () {
    testWidgets('a go in navigateFrom has the source, a later one has none', (
      tester,
    ) async {
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      navigateFrom(NavigationSource.notification, () => r.go('/items/7'));
      await tester.pumpAndSettle();
      expect(
        a(only('navigate /items/:id'), 'fespalier.navigation.source'),
        'notification',
      );
      exporter.clear();
      r.go('/other');
      await tester.pumpAndSettle();
      expect(a(only('navigate /other'), 'fespalier.navigation.source'), isNull);
    });

    testWidgets('a cold start from a link is initial, with its source', (
      tester,
    ) async {
      final r = navigateFrom(
        NavigationSource.link,
        () => router(initial: '/items/2'),
      );
      await pumpRouter(tester, r);
      final nav = only('navigate /items/:id');
      expect(a(nav, 'fespalier.navigation.kind'), 'initial');
      expect(a(nav, 'fespalier.navigation.source'), 'link');
    });

    testWidgets('only a navigation has it', (tester) async {
      checkout = () => '/login';
      final r = router();
      await pumpRouter(tester, r);
      exporter.clear();
      navigateFrom(NavigationSource.shortcut, () => r.go('/checkout'));
      await tester.pumpAndSettle();
      for (final span in exporter.spans) {
        final isNavigate = span.name.startsWith('navigate');
        expect(
          a(span, 'fespalier.navigation.source'),
          isNavigate ? 'shortcut' : isNull,
          reason: span.name,
        );
      }
    });
  });

  group('data and actions are the current span (since 0.9.0)', () {
    /// What an HTTP client's instrumentation (`otel_http`, `otel_dio`) does: a span under whatever
    /// span is current, made with the SDK's own tracer.
    Span http(String name) {
      final span = OTel.tracerProvider().getTracer('http').startSpan(name);
      span.end();
      return exporter.findSpansByName(name).single;
    }

    test('a span made inside data(), after an await, is its child', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceDataCall(ref, 'd1', 7, () async {
          await Future<void>.delayed(Duration.zero);
          http('GET /items/7');
          return 'item 7';
        }, telemetry: dataSite),
      );
      expect(await c.read(provider.future), 'item 7');
      final data = only('data items/\$id/data.dart');
      final request = only('GET /items/7');
      expect(request.parentSpanContext?.spanId, data.spanContext.spanId);
      expect(request.spanContext.traceId, data.spanContext.traceId);
      expect(data.attributes.getString('fespalier.data.state'), 'data');
    });

    test('and one made in the sync part of data() is too', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<String>(
        (ref) => traceDataCall(ref, 'd1', null, () {
          http('GET /sync');
          return 'value';
        }, telemetry: dataSite),
      );
      expect(c.read(provider), 'value');
      expect(
        only('GET /sync').parentSpanContext?.spanId,
        only('data items/\$id/data.dart').spanContext.spanId,
      );
    });

    test('nothing stays current after the call', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = FutureProvider.autoDispose<String>(
        (ref) => traceDataCall(
          ref,
          'd1',
          null,
          () async => 'x',
          telemetry: dataSite,
        ),
      );
      await c.read(provider.future);
      http('GET /after');
      expect(only('GET /after').parentSpanContext?.spanId.isValid, isNot(true));
    });

    test('a span made in an action, after an await, is its child', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final rename = actionProvider<String, String>(
        (ref, input) async {
          await Future<void>.delayed(Duration.zero);
          http('POST /items');
          return input;
        },
        invalidates: () => const [],
        telemetry: actionSite,
      );
      c.listen(rename, (_, _) {});
      await c.read(rename.notifier).call('a');
      expect(
        only('POST /items').parentSpanContext?.spanId,
        only('action items/\$id/action.dart#rename').spanContext.spanId,
      );
    });

    test('a failed data() is an error span, and the error is Riverpod\'s', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final provider = Provider.autoDispose<String>(
        (ref) => traceDataCall<String>(
          ref,
          'd1',
          null,
          () => throw StateError('sync'),
          telemetry: dataSite,
        ),
      );
      expect(() => c.read(provider), throwsA(isA<Object>()));
      final data = only('data items/\$id/data.dart');
      expect(data.status, SpanStatusCode.Error);
      expect(data.attributes.getString('fespalier.data.state'), 'error');
      expect(data.attributes.getBool('fespalier.async'), false);
    });

    testWidgets('next to another sink the data span still has its own '
        'navigation as parent, and the request is its child', (tester) async {
      final rec = RecordingTelemetry();
      FespalierTelemetry.install(
        FespalierTelemetry.combine([rec, FespalierOtel()]),
      );
      final r = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(path: '/home', builder: (_, _) => page('home')),
          GoRoute(
            path: '/items/:id',
            builder: (context, s) => Consumer(
              builder: (context, ref, _) {
                ref.watch(itemWithRequest(int.parse(s.pathParameters['id']!)));
                return page('item');
              },
            ),
          ),
        ],
      );
      telemetryAttach(r, base: () => '/');
      await pumpRouter(tester, r);
      exporter.clear();
      r.go('/items/5');
      await tester.pumpAndSettle();
      final nav = only('navigate /items/:id');
      final data = only('data items/\$id/data.dart');
      final request = only('GET /items/5');
      expect(data.parentSpanContext?.spanId, nav.spanContext.spanId);
      expect(request.parentSpanContext?.spanId, data.spanContext.spanId);
      // The other sink was handed its own token as the parent, not ours.
      expect(
        rec.log,
        contains('#3 start data items/\$id/data.dart keyed parent=#2'),
      );
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

  group('an auth span (fespalier_auth, since 0.9.0)', () {
    test(
      'a renewal: its step, backend, trigger and scheme, and nothing else',
      () {
        final token = FespalierTelemetry.begin(
          const TelemetryStart(
            TelemetryOp.auth,
            authStep: 'renew',
            authBackend: 'oidc',
            authTrigger: 'unauthorized',
            authScheme: 'dpop',
          ),
        );
        FespalierTelemetry.finish(
          token,
          const TelemetryEnd(TelemetryOutcome.ok, isAsync: true),
        );
        final span = only('auth renew');
        expect(span.parentSpanContext?.spanId.isValid ?? false, isFalse);
        final a = span.attributes;
        expect(a.getString('fespalier.operation'), 'auth');
        expect(a.getString('fespalier.auth.operation'), 'renew');
        expect(a.getString('fespalier.auth.backend'), 'oidc');
        expect(a.getString('fespalier.auth.trigger'), 'unauthorized');
        expect(a.getString('fespalier.auth.scheme'), 'dpop');
        expect(a.getString('fespalier.auth.result'), 'ok');
        expect(a.getBool('fespalier.async'), true);
        expect(span.status, SpanStatusCode.Unset);
        expect(a.keys.toSet(), {
          'fespalier.operation',
          'fespalier.auth.operation',
          'fespalier.auth.backend',
          'fespalier.auth.trigger',
          'fespalier.auth.scheme',
          'fespalier.auth.result',
          'fespalier.async',
        });
      },
    );

    test('rejected, cancelled, none and expired are not errors', () {
      for (final outcome in [
        TelemetryOutcome.rejected,
        TelemetryOutcome.cancelled,
        TelemetryOutcome.none,
        TelemetryOutcome.expired,
      ]) {
        exporter.clear();
        final token = FespalierTelemetry.begin(
          const TelemetryStart(
            TelemetryOp.auth,
            authStep: 'sign_in',
            authBackend: 'fake',
          ),
        );
        FespalierTelemetry.finish(token, TelemetryEnd(outcome));
        final span = only('auth sign_in');
        expect(span.status, SpanStatusCode.Unset, reason: outcome);
        expect(a(span, 'fespalier.auth.result'), outcome);
        expect(a(span, 'fespalier.auth.trigger'), isNull);
        expect(a(span, 'fespalier.auth.scheme'), isNull);
      }
    });

    test('an error is an error span with the class, never the text', () {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.auth,
          authStep: 'renew',
          authBackend: 'oidc',
        ),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: const FormatException(
            'https://sso.example.com/token for ada@example.com',
          ),
          stackTrace: StackTrace.current,
        ),
      );
      final span = only('auth renew');
      expect(span.status, SpanStatusCode.Error);
      expect(a(span, 'fespalier.auth.result'), 'error');
      expect(a(span, 'error.type'), 'FormatException');
      // The text of an auth error may name a host or an account: nothing of it is exported.
      expect(span.statusDescription, isNull);
      expect(span.spanEvents, isNull);
      expect(
        span.attributes.toList().map((e) => '${e.value}').join(' '),
        isNot(anyOf(contains('example.com'), contains('ada'))),
      );
    });
  });

  group('a custom span (a package\'s own operation, since 0.11.0)', () {
    test('the name, the start and end attributes and the result', () {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.custom,
          name: 'fespalier.push.open',
          attributes: {'fespalier.push.kind': 'alert', 'fespalier.push.n': 2},
        ),
      );
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(
          TelemetryOutcome.ok,
          isAsync: true,
          attributes: {
            'fespalier.push.ratio': 0.5,
            'fespalier.push.fresh': true,
          },
        ),
      );
      final span = only('fespalier.push.open');
      final attrs = span.attributes;
      expect(attrs.getString('fespalier.operation'), 'custom');
      expect(attrs.getString('fespalier.custom.name'), 'fespalier.push.open');
      expect(attrs.getString('fespalier.custom.result'), 'ok');
      expect(attrs.getString('fespalier.push.kind'), 'alert');
      expect(attrs.getInt('fespalier.push.n'), 2);
      expect(attrs.getDouble('fespalier.push.ratio'), 0.5);
      expect(attrs.getBool('fespalier.push.fresh'), true);
      expect(span.status, SpanStatusCode.Unset);
    });

    test('a convention key wins over the package\'s, and an end key outside '
        'the package prefix is dropped', () {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.custom,
          name: 'fespalier.push.open',
          attributes: {'fespalier.push.kind': 'alert'},
        ),
      );
      FespalierTelemetry.finish(
        token,
        const TelemetryEnd(
          TelemetryOutcome.cancelled,
          attributes: {
            'fespalier.push.ok': 1,
            'fespalier.custom.result': 'forged',
            'fespalier.image.cdn': 'x',
          },
        ),
      );
      final attrs = only('fespalier.push.open').attributes;
      expect(attrs.getString('fespalier.custom.result'), 'cancelled');
      expect(attrs.getInt('fespalier.push.ok'), 1);
      expect(attrs.getString('fespalier.image.cdn'), isNull);
    });

    test('an error object is never exported, only its class', () {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.custom, name: 'fespalier.push.open'),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          error: const FormatException('https://push.example.com/token/abc'),
          stackTrace: StackTrace.current,
        ),
      );
      final span = only('fespalier.push.open');
      expect(span.status, SpanStatusCode.Error);
      expect(span.statusDescription, isNull);
      expect(span.spanEvents, isNull);
      expect(a(span, 'fespalier.custom.result'), 'error');
      expect(a(span, 'error.type'), 'FormatException');
    });
  });

  group('an image span (fespalier_image, since 0.9.0)', () {
    test(
      'a load: the builder, the bucket and whether a precache started it',
      () {
        final token = FespalierTelemetry.begin(
          const TelemetryStart(
            TelemetryOp.image,
            imageCdn: 'emgr',
            imageWidth: 640,
            imagePreload: true,
          ),
        );
        FespalierTelemetry.finish(
          token,
          const TelemetryEnd(TelemetryOutcome.ok, isAsync: true),
        );
        final span = only('image emgr');
        final attrs = span.attributes;
        expect(attrs.getString('fespalier.operation'), 'image');
        expect(attrs.getString('fespalier.image.cdn'), 'emgr');
        expect(attrs.getInt('fespalier.image.width'), 640);
        expect(attrs.getBool('fespalier.image.preload'), true);
        expect(attrs.getString('fespalier.image.result'), 'ok');
        expect(span.status, SpanStatusCode.Unset);
        expect(attrs.keys.toSet(), {
          'fespalier.operation',
          'fespalier.image.cdn',
          'fespalier.image.width',
          'fespalier.image.preload',
          'fespalier.image.result',
        });
      },
    );

    test(
      'a failed load is an error span with its HTTP status, and no exception event',
      () {
        final token = FespalierTelemetry.begin(
          const TelemetryStart(
            TelemetryOp.image,
            imageCdn: 'cloudinary',
            imageWidth: 128,
          ),
        );
        FespalierTelemetry.finish(
          token,
          const TelemetryEnd(
            TelemetryOutcome.error,
            isAsync: true,
            imageStatus: 404,
          ),
        );
        final span = only('image cloudinary');
        expect(span.status, SpanStatusCode.Error);
        expect(span.statusDescription, isNull);
        expect(a(span, 'fespalier.image.result'), 'error');
        expect(span.attributes.getInt('fespalier.image.status'), 404);
        expect(span.attributes.getBool('fespalier.image.preload'), false);
        expect(span.spanEvents, isNull);
      },
    );

    test('an error object is never exported, its text holds the URL', () {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'imgix',
          imageWidth: 32,
        ),
      );
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          TelemetryOutcome.error,
          isAsync: true,
          error: const FormatException('https://img.example.com/Kx/photo.jpg'),
          stackTrace: StackTrace.current,
        ),
      );
      final span = only('image imgix');
      expect(span.status, SpanStatusCode.Error);
      expect(span.statusDescription, isNull);
      expect(span.spanEvents, isNull);
      expect(
        span.attributes.toList().map((e) => '${e.value}').join(' '),
        isNot(contains('example.com')),
      );
    });

    test('begun under a navigation, it is that navigation\'s child', () {
      final navigation = telemetryNavigationStart(Uri.parse('/items/1'));
      final token = FespalierTelemetry.begin(
        const TelemetryStart(
          TelemetryOp.image,
          imageCdn: 'emgr',
          imageWidth: 128,
        ),
        underNavigation: true,
      );
      FespalierTelemetry.finish(token, const TelemetryEnd(TelemetryOutcome.ok));
      telemetryNavigationEnd(
        navigation,
        const TelemetryEnd(TelemetryOutcome.ok),
      );
      expect(
        only('image emgr').parentSpanContext?.spanId,
        only('navigate').spanContext.spanId,
      );
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

  group('retries, saved copies, rollbacks and validation (since 0.18.0)', () {
    test('a data span has its attempt', () async {
      var calls = 0;
      final p = FutureProvider.autoDispose<int>(
        (ref) => traceDataCall(ref, 'd3', null, () async {
          calls++;
          if (calls == 1) throw StateError('try 1');
          return calls;
        }, telemetry: dataSite),
      );
      final c = ProviderContainer(
        retry: (n, _) => n == 0 ? Duration.zero : null,
      );
      addTearDown(c.dispose);
      c.listen(p, (_, _) {}, onError: (_, _) {});
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final spans = exporter.findSpansByName('data items/\$id/data.dart');
      expect(
        [for (final s in spans) s.attributes.getInt('fespalier.data.attempt')],
        [1, 2],
      );
    });

    test('a data span has its source when it is told one', () {
      final told = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: dataSite),
      );
      FespalierTelemetry.finish(
        told,
        const TelemetryEnd(
          TelemetryOutcome.data,
          isAsync: true,
          dataSource: TelemetryDataSource.cache,
        ),
      );
      final untold = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: dataSite),
      );
      FespalierTelemetry.finish(
        untold,
        const TelemetryEnd(TelemetryOutcome.data, isAsync: true),
      );
      final spans = exporter.findSpansByName('data items/\$id/data.dart');
      expect(spans, hasLength(2));
      expect(
        spans.first.attributes.getString('fespalier.data.source'),
        'cache',
      );
      expect(
        spans.last.attributes.keys,
        isNot(contains('fespalier.data.source')),
      );
    });

    test('an optimistic action that fails says rolled_back true, one that '
        'works false', () async {
      final data = FutureProvider.autoDispose<int>((ref) async => 1);
      final layer = optimisticLayer(data);
      final save = actionProvider<int, int>(
        (ref, input) async {
          if (input < 0) throw StateError('no');
          return input;
        },
        invalidates: () => const [],
        optimistic: () => layer.patch((int v, int input) => input),
        telemetry: actionSite,
      );
      final c = ProviderContainer(retry: (_, _) => null);
      addTearDown(c.dispose);
      c.listen(data, (_, _) {});
      c.listen(layer, (_, _) {});
      c.listen(save, (_, _) {});
      await expectLater(
        Future.value(c.read(save.notifier).call(-1)),
        throwsStateError,
      );
      await c.read(save.notifier).call(5);
      final spans = exporter.findSpansByName(
        'action items/\$id/action.dart#rename',
      );
      expect(spans, hasLength(2));
      expect(
        spans.first.attributes.getBool('fespalier.action.rolled_back'),
        true,
      );
      expect(
        spans.last.attributes.getBool('fespalier.action.rolled_back'),
        false,
      );
      expect(spans.last.attributes.getBool('fespalier.action.invalid'), isNull);
    });

    test('an action refused by validate() is invalid, a StateError is not, a '
        'success has neither', () async {
      final rename = actionProvider<String, String>(
        (ref, input) => input.toUpperCase(),
        invalidates: () => const [],
        validate: (input) =>
            input.isEmpty ? const FieldErrors({'name': 'Required'}) : null,
        telemetry: actionSite,
      );
      final boom = actionProvider<String, String>(
        (ref, input) => throw StateError('no'),
        invalidates: () => const [],
        telemetry: actionSite,
      );
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(rename, (_, _) {});
      c.listen(boom, (_, _) {});
      expect(
        () => c.read(rename.notifier).call(''),
        throwsA(isA<FieldErrors>()),
      );
      expect(() => c.read(boom.notifier).call('a'), throwsStateError);
      expect(c.read(rename.notifier).call('a'), 'A');
      final spans = exporter.findSpansByName(
        'action items/\$id/action.dart#rename',
      );
      expect(spans, hasLength(3));
      expect(spans[0].attributes.getBool('fespalier.action.invalid'), true);
      expect(spans[1].attributes.getBool('fespalier.action.invalid'), false);
      expect(spans[2].attributes.getBool('fespalier.action.invalid'), isNull);
      expect(spans[2].attributes.getString('fespalier.action.result'), 'ok');
    });
  });

  group('an HTTP request (OtelTransport, since 0.21.0)', () {
    test(
      'is a CLIENT span named by its method, and a re-send says so',
      () async {
        final transport = OtelTransport(
          FakeTransport((_, _) => fakeResponse(503)),
        );
        final request = TransportRequest(
          method: 'GET',
          uri: Uri.parse('https://api.example.com/items/5?q=1'),
        );
        await transport.send(request);
        await transport.send(
          request.copyWith(attributes: {transportReplayKey: true}),
        );
        final sent = exporter.findSpansByName('GET');
        expect(sent, hasLength(2));
        expect(a(sent[0], 'fespalier.operation'), 'http');
        expect(a(sent[0], 'url.path'), '/items/5');
        expect(sent[1].attributes.getInt('http.request.resend_count'), 1);
      },
    );
  });

  // The other half of the contract needs the whole file: every name of it was emitted by some test
  // (what the tests emit is checked one test at a time, in `tearDown`, against the lists above).
  // This one asks the file's tests together, so a run that filters them by name (`--name`,
  // `--plain-name`) reports it, because the tests that would emit the rest did not run; package:test
  // does not tell a test whether it was filtered, and CI runs the file whole. A name that is gone
  // was renamed or removed, which is version 2.
  tearDownAll(() {
    const reason =
        'a name of the contract was not emitted: it was renamed or removed (version 2 of the '
        'contract); this needs the whole file, so a filtered run reports it too';
    expect(seen.spans, containsAll(contractSpans), reason: reason);
    expect(seen.keys, containsAll(contractKeys), reason: reason);
    expect(seen.events, containsAll(contractEvents), reason: reason);
    expect(
      seen.eventKeys.where((k) => k.startsWith('fespalier.')),
      containsAll(contractEventKeys),
      reason: reason,
    );
  });
}
