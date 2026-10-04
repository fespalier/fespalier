// Next to `fespalier_otel` (`FespalierTelemetry.combine`), each event carries the OpenTelemetry
// trace id and span id of the screen or the call it came from, so an error links to its trace.
// This package does not depend on OpenTelemetry: the other sink says which trace an operation is
// in (`traceOf`), the combine tells this one (`linkTrace`). The sink here is a stand-in that
// makes up ids the way a tracer does: a navigation starts a trace, what runs in it is a span of it.
import 'package:fespalier/fespalier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

/// A sink like `FespalierOtel`: a trace per navigation, and per action; a span per operation.
final class FakeTracer extends FespalierTelemetry {
  FakeTracer({this.silent = false});

  /// Whether it answers nothing (an SDK that is not up yet).
  bool silent;

  int _next = 0;
  final Map<int, TelemetryTrace> traces = {};

  static String hex(int n, int digits) =>
      n.toRadixString(16).padLeft(digits, '0');

  @override
  Object? start(TelemetryStart start) {
    final id = ++_next;
    final parent = start.parent;
    final traceId = parent is int ? traces[parent]!.traceId : hex(id, 32);
    traces[id] = TelemetryTrace(traceId, hex(id, 16));
    return id;
  }

  @override
  TelemetryTrace? traceOf(Object? token) => silent ? null : traces[token];
}

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
  });
  tearDown(() => FespalierTelemetry.install(null));

  /// A rig whose sink shares the slot with [tracer], in the order given.
  Rig combined(
    FakeTracer tracer, {
    bool tracerFirst = true,
    bool tracing = false,
  }) {
    final rig = Rig(tracing: tracing);
    FespalierTelemetry.install(
      FespalierTelemetry.combine(
        tracerFirst ? [tracer, rig.sink] : [rig.sink, tracer],
      ),
    );
    return rig;
  }

  testWidgets('an error carries the trace and the span of the call that failed', (
    tester,
  ) async {
    load = (_) => Future<String>.error(StateError('no such item'));
    final tracer = FakeTracer();
    final rig = combined(tracer);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final event = (await rig.sent(tester)).single;
    // The navigation to /items/7 is the third operation of the tracer (the first is the one of
    // /home), and the data load, its child, the fourth: the same trace, a span of its own.
    final navigation = tracer.traces[2]!;
    final data = tracer.traces[3]!;
    expect(data.traceId, navigation.traceId);
    expect(data.spanId, isNot(navigation.spanId));
    final tags = map(event['tags']);
    expect(tags['otel.trace_id'], data.traceId);
    expect(tags['otel.span_id'], data.spanId);
    expect(map(map(event['contexts'])['otel']), {
      'trace_id': data.traceId,
      'span_id': data.spanId,
    });
  });

  testWidgets('it does not matter which sink is listed first', (tester) async {
    load = (_) => Future<String>.error(StateError('no such item'));
    final tracer = FakeTracer();
    final rig = combined(tracer, tracerFirst: false);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final event = (await rig.sent(tester)).single;
    expect(map(event['tags'])['otel.trace_id'], tracer.traces[3]!.traceId);
  });

  testWidgets('a crash after a navigation carries the trace of that screen', (
    tester,
  ) async {
    final tracer = FakeTracer();
    final rig = combined(tracer);
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    await rig.sentry.hub.captureException(StateError('crash'));
    final event = (await rig.sent(tester)).single;
    final navigation = tracer.traces[2]!;
    expect(map(event['tags'])['otel.trace_id'], navigation.traceId);
    expect(map(event['tags'])['otel.span_id'], navigation.spanId);
    expect(rig.sentry.tags['otel.trace_id'], navigation.traceId);
  });

  testWidgets(
    'a navigation the other sink has no trace for takes the tags off, so '
    'no event links to the wrong screen',
    (tester) async {
      final tracer = FakeTracer();
      final rig = combined(tracer);
      final r = await rig.boot(tester);
      r.go('/other');
      await tester.pumpAndSettle();
      expect(rig.sentry.tags, contains('otel.trace_id'));
      tracer.silent = true;
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(rig.sentry.tags.containsKey('otel.trace_id'), isFalse);
      expect(rig.sentry.tags.containsKey('otel.span_id'), isFalse);
      expect(rig.sentry.tags['fespalier.route'], '/items/:id');
    },
  );

  testWidgets('alone, there is no trace to link to, and no tag says so', (
    tester,
  ) async {
    load = (_) => Future<String>.error(StateError('no such item'));
    final rig = Rig();
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final event = (await rig.sent(tester)).single;
    expect(
      map(event['tags']).keys.where((k) => k.startsWith('otel.')),
      isEmpty,
    );
    expect(map(event['contexts']).containsKey('otel'), isFalse);
    expect(rig.sentry.tags.keys.where((k) => k.startsWith('otel.')), isEmpty);
  });

  testWidgets('an action carries the trace of its own span', (tester) async {
    final tracer = FakeTracer();
    final rig = combined(tracer);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final fail = actionProvider<String, String>(
      (ref, input) async => throw StateError('rename refused'),
      invalidates: () => const [],
      telemetry: actionSite,
    );
    c.listen(fail, (_, _) {});
    // The container is the test's: its timers are not the widget tree's.
    await tester.runAsync(() async {
      await expectLater(c.read(fail.notifier).call('x'), throwsStateError);
      await Future<void>.delayed(Duration.zero);
    });
    final event = (await rig.sentry.sent()).single;
    expect(map(event['tags'])['otel.trace_id'], tracer.traces[1]!.traceId);
    expect(map(event['tags'])['otel.span_id'], tracer.traces[1]!.spanId);
  });

  testWidgets('with tracing: true the transaction carries it too', (
    tester,
  ) async {
    final tracer = FakeTracer();
    final rig = combined(tracer, tracing: true);
    final r = await rig.boot(tester);
    r.go('/other');
    await tester.pumpAndSettle();
    final tx = (await rig.sent(tester)).single;
    final navigation = tracer.traces[2]!;
    expect(map(tx['tags'])['otel.trace_id'], navigation.traceId);
    expect(map(tx['tags'])['otel.span_id'], navigation.spanId);
  });
}
