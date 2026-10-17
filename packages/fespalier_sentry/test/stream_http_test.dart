// The HTTP spans Sentry's own integrations make inside a `data()` or an action, with
// `traceLifecycle: stream`: children of the sink's data or action span, which the sink makes around
// the code it runs (`within`). `SentryHttpClient` over a `MockClient`, on a real hub.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'support.dart';

Rig streamRig({
  void Function(SentryFlutterOptions options)? configure,
  bool stream = true,
}) => Rig(
  tracing: true,
  configure: (o) {
    if (stream) o.traceLifecycle = SentryTraceLifecycle.stream;
    configure?.call(o);
  },
);

/// An HTTP client whose calls Sentry measures, on the rig's hub. Build it after the rig: the
/// client reads the SDK's span factory when it is made.
SentryHttpClient client(Rig rig) => SentryHttpClient(
  client: MockClient((_) async => http.Response('ok', 200)),
  hub: rig.sentry.hub,
);

Uri url(Object id) => Uri.parse('https://api.example.com/items/$id?token=abc');

Object? attr(SentrySpanV2 span, String key) => span.attributes[key]?.value;

String op(SentrySpanV2 span) => '${attr(span, 'sentry.op')}';

List<SentrySpanV2> ofOp(List<SentrySpanV2> spans, String kind) =>
    spans.where((s) => op(s) == kind).toList();

/// The spans that ended so far, once the SDK has handed them over.
Future<List<SentrySpanV2>> spansOf(Rig rig, WidgetTester tester) async {
  await tester.pump();
  return rig.sentry.spans;
}

Widget watching(List<int> ids) => Consumer(
  builder: (context, ref, _) {
    for (final id in ids) {
      ref.watch(item(id));
    }
    return page('items');
  },
);

GoRouter itemsRouter(Widget Function() two) {
  final r = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, _) => page('home')),
      GoRoute(path: '/two', builder: (_, _) => two()),
      GoRoute(path: '/other', builder: (_, _) => page('other')),
    ],
  );
  telemetryAttach(r, base: () => '/');
  return r;
}

Future<List<String?>> printing(Future<void> Function() body) async {
  final printed = <String?>[];
  final original = debugPrint;
  debugPrint = (message, {wrapWidth}) => printed.add(message);
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return printed;
}

/// A sink that runs the body in a zone of its own, with zone values only (what `fespalier_otel`
/// does), and counts the calls.
final class ZoneSink extends FespalierTelemetry {
  static const key = #zoneSink;
  int calls = 0;

  @override
  Object? start(TelemetryStart start) =>
      start.op == TelemetryOp.data ? 1 : null;

  @override
  void within(Object? token, Object? Function() body) {
    calls++;
    runZoned(body, zoneValues: {key: true});
  }
}

void main() {
  setUp(() {
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('an HTTP span made inside data() is a child of the data span', (
    tester,
  ) async {
    final rig = streamRig();
    final c = client(rig);
    load = (id) async {
      await c.get(url(id));
      return 'item $id';
    };
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    final data = ofOp(spans, 'fespalier.data').single;
    final request = ofOp(spans, 'http.client').single;
    expect(request.parentSpan!.spanId, data.spanId);
    expect(request.name, 'GET https://api.example.com/items/7');
    expect(data.parentSpan, isNotNull);
    expect(data.status, SentrySpanStatusV2.ok);
    expect(attr(data, 'fespalier.data.state'), 'data');
    // Sentry's own privacy rule still holds on the HTTP span: no query.
    expect(attr(request, 'http.query'), isNull);
    expect(attr(request, 'url'), 'https://api.example.com/items/7');
  });

  testWidgets('after an await too', (tester) async {
    final rig = streamRig();
    final c = client(rig);
    load = (id) async {
      await Future<void>.value();
      await Future<void>.value();
      await c.get(url(id));
      return 'item $id';
    };
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    final data = ofOp(spans, 'fespalier.data').single;
    expect(ofOp(spans, 'http.client').single.parentSpan!.spanId, data.spanId);
  });

  testWidgets('two loads at once each get their own HTTP children', (
    tester,
  ) async {
    final rig = streamRig();
    final c = client(rig);
    final gates = {1: Completer<void>(), 2: Completer<void>()};
    load = (id) async {
      await gates[id]!.future;
      await c.get(url(id));
      return 'item $id';
    };
    final r = itemsRouter(() => watching([1, 2]));
    await pumpRouter(tester, r);
    r.go('/two');
    await tester.pump();
    await tester.pump();
    // The second load answers first, so it is the first data span to end.
    gates[2]!.complete();
    await tester.pump();
    await tester.pump();
    gates[1]!.complete();
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    final data = ofOp(spans, 'fespalier.data');
    final requests = ofOp(spans, 'http.client');
    expect(data, hasLength(2));
    expect(requests.map((s) => s.name), [
      'GET https://api.example.com/items/2',
      'GET https://api.example.com/items/1',
    ]);
    expect(requests[0].parentSpan!.spanId, data[0].spanId);
    expect(requests[1].parentSpan!.spanId, data[1].spanId);
    expect(data[0].spanId, isNot(data[1].spanId));
  });

  group('an action', () {
    final act = actionProvider<String, String>(
      (ref, input) async {
        await _actionClient!.get(url(input));
        return input;
      },
      invalidates: () => const [],
      telemetry: actionSite,
    );

    testWidgets('makes its HTTP span a child of its own, with a screen open', (
      tester,
    ) async {
      final rig = streamRig();
      _actionClient = client(rig);
      load = (_) => Completer<String>().future;
      final r = await rig.boot(tester);
      r.go('/items/5');
      await tester.pump();
      await tester.pump();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(act, (_, _) {});
      await c.read(act.notifier).call('a');
      r.go('/other');
      await tester.pumpAndSettle();
      final spans = await spansOf(rig, tester);
      final action = ofOp(spans, 'fespalier.action').single;
      final request = ofOp(spans, 'http.client').single;
      expect(request.parentSpan!.spanId, action.spanId);
      // The screen was open: the action is a child of its segment.
      expect(action.parentSpan!.name, '/items/:id');
      expect(attr(action, 'fespalier.action.result'), 'ok');
    });

    testWidgets('is a segment of its own with no screen open, and holds the '
        'HTTP span', (tester) async {
      final rig = streamRig();
      _actionClient = client(rig);
      await rig.boot(tester);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(act, (_, _) {});
      await c.read(act.notifier).call('a');
      final spans = await spansOf(rig, tester);
      final action = ofOp(spans, 'fespalier.action').single;
      expect(action.parentSpan, isNull);
      expect(action.name, r'action items/$id/action.dart#rename');
      expect(
        ofOp(spans, 'http.client').single.parentSpan!.spanId,
        action.spanId,
      );
    });
  });

  testWidgets('the data span ends with fespalier\'s outcome, not when '
      'Sentry\'s callback returns', (tester) async {
    var now = DateTime.utc(2026, 1, 1);
    final rig = streamRig(
      // `SentryOptions.clock` is `@internal`: it is the one way to read the time a span ends at.
      // ignore: invalid_use_of_internal_member
      configure: (o) => o.clock = () => now,
    );
    final c = client(rig);
    final answer = Completer<void>();
    load = (id) async {
      await answer.future;
      await c.get(url(id));
      return 'item $id';
    };
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pump();
    await tester.pump();
    // Sentry's callback has returned its Future, and nothing ended the span.
    expect(ofOp(await spansOf(rig, tester), 'fespalier.data'), isEmpty);
    now = now.add(const Duration(seconds: 5));
    answer.complete();
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    final data = ofOp(spans, 'fespalier.data').single;
    expect(attr(data, 'fespalier.data.state'), 'data');
    expect(attr(data, 'fespalier.async'), true);
    expect(data.endTimestamp, now);
    expect(data.status, SentrySpanStatusV2.ok);
  });

  testWidgets('a data span whose end is held still gets fespalier\'s status '
      'and attributes when it is released', (tester) async {
    final rig = streamRig();
    await rig.boot(tester);
    // A load that fails before the navigation commits: its end waits for the route's name.
    final nav = FespalierTelemetry.begin(
      TelemetryStart(TelemetryOp.navigate, uri: Uri.parse('/items/1')),
    );
    final token = FespalierTelemetry.begin(
      TelemetryStart(TelemetryOp.data, site: dataSite, parent: nav),
    );
    FespalierTelemetry.run(token, () => null);
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(TelemetryOutcome.error, error: StateError('boom')),
    );
    expect(ofOp(await spansOf(rig, tester), 'fespalier.data'), isEmpty);
    FespalierTelemetry.finish(
      nav,
      const TelemetryEnd(TelemetryOutcome.ok, route: '/items/:id'),
    );
    final spans = await spansOf(rig, tester);
    final data = ofOp(spans, 'fespalier.data').single;
    // Not Sentry's default: the sink's outcome, and the segment's name.
    expect(data.status, SentrySpanStatusV2.error);
    expect(attr(data, 'fespalier.data.state'), 'error');
    expect(attr(data, 'sentry.segment.name'), '/items/:id');
    expect(data.parentSpan!.name, '/items/:id');
  });

  testWidgets('a sync data() that throws reaches the caller unchanged, and '
      'its span is an error', (tester) async {
    final rig = streamRig();
    final boom = StateError('boom');
    Object? caught;
    final fails = Provider.autoDispose<String>((ref) {
      try {
        return traceDataCall<String>(
          ref,
          'd6',
          null,
          () => throw boom,
          telemetry: dataSite,
        );
      } catch (e) {
        // The very object, thrown synchronously from the call: no Future in between.
        caught = e;
        return 'caught';
      }
    });
    final r = itemsRouter(
      () => Consumer(builder: (_, ref, _) => page(ref.watch(fails))),
    );
    await pumpRouter(tester, r);
    r.go('/two');
    await tester.pumpAndSettle();
    expect(caught, same(boom));
    final data = ofOp(await spansOf(rig, tester), 'fespalier.data').single;
    expect(data.status, SentrySpanStatusV2.error);
    expect(attr(data, 'fespalier.data.state'), 'error');
  });

  testWidgets('a load disposed before it settles ends its span once, ok, '
      'state=disposed', (tester) async {
    final rig = streamRig();
    final c = client(rig);
    final never = Completer<void>();
    load = (id) async {
      await never.future;
      await c.get(url(id));
      return 'item $id';
    };
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    final r = itemsRouter(
      () => ValueListenableBuilder<bool>(
        valueListenable: shown,
        builder: (_, on, _) => on ? watching([1]) : page('hidden'),
      ),
    );
    await pumpRouter(tester, r);
    r.go('/two');
    await tester.pump();
    await tester.pump();
    shown.value = false;
    await tester.pumpAndSettle();
    var spans = await spansOf(rig, tester);
    final data = ofOp(spans, 'fespalier.data').single;
    expect(data.status, SentrySpanStatusV2.ok);
    expect(attr(data, 'fespalier.data.state'), 'disposed');
    // Nothing is left open or ended twice: the load never settles, and the count holds.
    final count = spans.length;
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    spans = await spansOf(rig, tester);
    expect(spans, hasLength(count));
    expect(ofOp(spans, 'fespalier.data'), hasLength(1));
    expect(ofOp(spans, 'http.client'), isEmpty);
  });

  group('within', () {
    testWidgets('runs the body once, synchronously, in the caller\'s error '
        'zone, and a sync data() stays sync', (tester) async {
      final rig = streamRig();
      var calls = 0;
      Zone? inside;
      late final Zone caller;
      var sameErrorZone = false;
      final sync = Provider.autoDispose<String>((ref) {
        caller = Zone.current;
        final value = traceDataCall(ref, 'd5', null, () {
          calls++;
          inside = Zone.current;
          sameErrorZone = Zone.current.inSameErrorZone(caller);
          return 'sync';
        }, telemetry: dataSite);
        // The very value came back, not a Future: nothing was awaited.
        expect(value, isA<String>());
        return value;
      });
      final r = itemsRouter(
        () => Consumer(builder: (_, ref, _) => page(ref.watch(sync))),
      );
      await pumpRouter(tester, r);
      final printed = await printing(() async {
        r.go('/two');
        await tester.pumpAndSettle();
      });
      expect(calls, 1);
      expect(sameErrorZone, isTrue);
      // The sink's zone, which is not the caller's: the body ran inside it.
      expect(identical(inside, caller), isFalse);
      expect(
        printed.where((m) => m!.contains('changed the error zone')),
        isEmpty,
      );
      final data = ofOp(await spansOf(rig, tester), 'fespalier.data').single;
      expect(attr(data, 'fespalier.data.state'), 'data');
      expect(attr(data, 'fespalier.async'), false);
    });

    for (final sentryFirst in [true, false]) {
      testWidgets('behind combine, a sink that runs the body in a zone of its '
          'own still sees the Sentry data span active '
          '(${sentryFirst ? 'outer' : 'inner'})', (tester) async {
        final rig = streamRig();
        final c = client(rig);
        final zone = ZoneSink();
        FespalierTelemetry.install(
          FespalierTelemetry.combine(
            sentryFirst ? [rig.sink, zone] : [zone, rig.sink],
          ),
        );
        var sawZone = false;
        load = (id) async {
          sawZone = Zone.current[ZoneSink.key] == true;
          await c.get(url(id));
          return 'item $id';
        };
        final r = await rig.boot(tester);
        r.go('/items/7');
        await tester.pumpAndSettle();
        expect(zone.calls, 1);
        expect(sawZone, isTrue);
        final spans = await spansOf(rig, tester);
        final data = ofOp(spans, 'fespalier.data').single;
        expect(
          ofOp(spans, 'http.client').single.parentSpan!.spanId,
          data.spanId,
        );
      });
    }
  });

  testWidgets('static lifecycle: HTTP spans stay under the screen\'s '
      'transaction', (tester) async {
    final rig = streamRig(stream: false);
    final c = client(rig);
    load = (id) async {
      await c.get(url(id));
      return 'item $id';
    };
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final sent = await rig.sent(tester);
    final tx = sent.singleWhere(
      (e) => e['type'] == 'transaction' && e['transaction'] == '/items/:id',
    );
    final trace = Map<String, Object?>.from(
      (tx['contexts']! as Map)['trace']! as Map,
    );
    final spans = [
      for (final s in tx['spans']! as List<Object?>)
        Map<String, Object?>.from(s! as Map),
    ];
    final request = spans.singleWhere((s) => s['op'] == 'http.client');
    expect(request['parent_span_id'], trace['span_id']);
    // The data span is a sibling, not the parent: nothing binds it to the global scope.
    final data = spans.singleWhere((s) => s['op'] == 'fespalier.data');
    expect(request['parent_span_id'], isNot(data['span_id']));
  });
}

/// The client the action providers use: set per test, since a provider is built once.
SentryHttpClient? _actionClient;
