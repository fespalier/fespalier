// `FespalierSentry(tracing: true)` on an SDK whose `traceLifecycle` is `stream`: the same tree as
// the static tests in mapping_test.dart, made with the streaming API, on a real hub that records
// each span in `beforeSendSpan`.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'support.dart';

/// A rig whose SDK streams.
Rig streamRig({
  TargetPlatform platform = TargetPlatform.linux,
  bool tracing = true,
  bool configured = true,
  void Function(SentryFlutterOptions options)? configure,
  SentryDisplay? Function(Hub hub)? currentDisplay,
}) => Rig(
  tracing: tracing,
  platform: platform,
  configured: configured,
  currentDisplay: currentDisplay,
  configure: (o) {
    o.traceLifecycle = SentryTraceLifecycle.stream;
    configure?.call(o);
  },
);

/// The attribute [key] of [span], as the plain value.
Object? attr(SentrySpanV2 span, String key) => span.attributes[key]?.value;

String op(SentrySpanV2 span) => '${attr(span, 'sentry.op')}';

/// Every span that ended so far (the first screen's too), once the SDK has handed them over.
Future<List<SentrySpanV2>> spansOf(Rig rig, WidgetTester tester) async {
  await tester.pump();
  return rig.sentry.spans;
}

/// The segments (root spans) of [spans], in the order they ended.
List<SentrySpanV2> segments(List<SentrySpanV2> spans) =>
    spans.where((s) => s.parentSpan == null).toList();

SentrySpanV2 segmentNamed(List<SentrySpanV2> spans, String name) =>
    segments(spans).lastWhere((s) => s.name == name);

/// The children of [segment] whose operation is [op].
List<SentrySpanV2> childrenOf(
  List<SentrySpanV2> spans,
  SentrySpanV2 segment, [
  String? kind,
]) => spans
    .where(
      (s) =>
          s.parentSpan != null &&
          s.parentSpan!.spanId == segment.spanId &&
          (kind == null || op(s) == kind),
    )
    .toList();

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

/// What [body] printed with `debugPrint`.
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

void main() {
  setUp(() {
    checkout = () => null;
    load = (id) async => 'item $id';
    // A deferred library loads once: every test starts with a fresh one.
    shopLibrary = DeferredLibrary(
      () async {},
      'shop/page.dart',
      loadsInFakeAsync: true,
      route: '/shop',
    );
  });
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets(
    'each navigation is a ui.load segment named by the route pattern',
    (tester) async {
      final rig = streamRig();
      final r = await rig.boot(tester);
      r.go('/items/7?tab=2');
      await tester.pumpAndSettle();
      r.go('/other');
      await tester.pumpAndSettle();
      final all = segments(await spansOf(rig, tester));
      expect(all.map((s) => s.name), ['/home', '/items/:id', '/other']);
      for (final segment in all) {
        expect(op(segment), 'ui.load');
        expect(attr(segment, 'sentry.origin'), 'auto.navigation.fespalier');
        expect(attr(segment, 'sentry.segment.name.source'), 'route');
        expect(segment.status, SentrySpanStatusV2.ok);
      }
      final items = all[1];
      expect(attr(items, 'fespalier.navigation.outcome'), 'ok');
      expect(attr(items, 'fespalier.navigation.kind'), 'go');
      expect(attr(items, 'fespalier.navigation.from'), '/home');
      expect(attr(items, 'fespalier.navigation.redirected'), false);
      expect(attr(items, 'fespalier.navigation.depth'), 0);
    },
  );

  testWidgets(
    'guards, redirects, data and deferred loads are children of their screen\'s '
    'segment',
    (tester) async {
      final rig = streamRig();
      final r = await rig.boot(tester);
      r.go('/shop');
      await tester.pumpAndSettle();
      r.go('/old');
      await tester.pumpAndSettle();
      final spans = await spansOf(rig, tester);
      final shop = segmentNamed(spans, '/shop');
      expect(childrenOf(spans, shop).map(op).toSet(), {
        'fespalier.deferred',
        'fespalier.guard',
        'fespalier.data',
        'ui.load.initial_display',
        'ui.load.full_display',
      });
      final guard = childrenOf(spans, shop, 'fespalier.guard').single;
      expect(guard.name, 'guard shop/guard.dart');
      expect(attr(guard, 'fespalier.guard.decision'), 'pass');
      final other = segmentNamed(spans, '/other');
      final redirect = childrenOf(spans, other, 'fespalier.redirect').single;
      expect(redirect.name, 'redirect old/redirect.dart');
      expect(attr(redirect, 'fespalier.guard.decision'), 'redirect');
      expect(guard.parentSpan, same(shop));
    },
  );

  testWidgets('lines() reads a streamed screen like a transaction', (
    tester,
  ) async {
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/shop');
    await tester.pumpAndSettle();
    final lines = await rig.lines(tester);
    expect(lines.skipWhile((l) => !l.contains('/shop status')).toList(), [
      'segment ui.load /shop status=ok ttid ttfd',
      '  span fespalier.deferred deferred shop/page.dart status=ok',
      '  span fespalier.guard guard shop/guard.dart status=ok',
      '  span ui.load.initial_display /shop initial display status=ok',
      r'  span fespalier.data data items/$id/data.dart status=ok',
      '  span ui.load.full_display /shop full display status=ok',
    ]);
  });

  testWidgets('a span that ended before the route was known carries the '
      'segment\'s name', (tester) async {
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/shop');
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    final shop = segmentNamed(spans, '/shop');
    for (final span in [shop, ...childrenOf(spans, shop)]) {
      expect(attr(span, 'sentry.segment.name'), '/shop', reason: span.name);
    }
  });

  testWidgets('a screen ends when its data arrives, with initial and full '
      'display spans and their values', (tester) async {
    final answer = Completer<String>();
    load = (_) => answer.future;
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/items/5');
    await tester.pumpAndSettle();
    var spans = await spansOf(rig, tester);
    // The initial display is in; the screen waits for its data.
    expect(segments(spans).map((s) => s.name), ['/home']);
    answer.complete('x');
    await tester.pumpAndSettle();
    spans = await spansOf(rig, tester);
    final items = segmentNamed(spans, '/items/:id');
    final ttid = childrenOf(spans, items, 'ui.load.initial_display').single;
    final ttfd = childrenOf(spans, items, 'ui.load.full_display').single;
    expect(ttid.name, '/items/:id initial display');
    expect(ttfd.name, '/items/:id full display');
    expect(attr(ttid, 'app.vitals.ttid.value'), isA<double>());
    expect(attr(ttfd, 'app.vitals.ttfd.value'), isA<double>());
    expect(ttid.status, SentrySpanStatusV2.ok);
    expect(ttfd.status, SentrySpanStatusV2.ok);
    expect(
      await rig.sentry.lines(),
      contains('segment ui.load /items/:id status=ok ttid ttfd'),
    );
    // Every span ended, with no idle timer behind any of them.
    expect(spans.every((s) => s.isEnded), isTrue);
  });

  testWidgets('the next navigation ends a screen still waiting: its full '
      'display is an error with no value, its data span an error', (
    tester,
  ) async {
    load = (_) => Completer<String>().future;
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/items/5');
    await tester.pumpAndSettle();
    r.go('/other');
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    final items = segmentNamed(spans, '/items/:id');
    expect(items.status, SentrySpanStatusV2.ok);
    final ttfd = childrenOf(spans, items, 'ui.load.full_display').single;
    expect(ttfd.status, SentrySpanStatusV2.error);
    expect(ttfd.attributes.containsKey('app.vitals.ttfd.value'), isFalse);
    final ttid = childrenOf(spans, items, 'ui.load.initial_display').single;
    expect(ttid.status, SentrySpanStatusV2.ok);
    final data = childrenOf(spans, items, 'fespalier.data').single;
    expect(data.status, SentrySpanStatusV2.error);
    expect(
      await rig.sentry.lines(),
      contains('segment ui.load /items/:id status=ok ttid'),
    );
  });

  testWidgets('a superseded navigation is sent, marked superseded', (
    tester,
  ) async {
    final answer = Completer<String?>();
    checkout = () => answer.future;
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/checkout');
    await tester.pump();
    r.go('/items/2');
    await tester.pumpAndSettle();
    answer.complete(null);
    await tester.pumpAndSettle();
    final spans = await spansOf(rig, tester);
    // Sentry cannot discard a streamed span, so the one that never committed is sent: marked.
    final superseded = segments(spans).singleWhere(
      (s) => attr(s, 'fespalier.navigation.outcome') == 'superseded',
    );
    expect(superseded.name, 'navigate');
    expect(superseded.status, SentrySpanStatusV2.ok);
    expect(superseded.isEnded, isTrue);
    // Its guard ended too, under the same name, as a child of it.
    final guard = childrenOf(spans, superseded, 'fespalier.guard').single;
    expect(attr(guard, 'sentry.segment.name'), 'navigate');
    expect(segmentNamed(spans, '/items/:id').status, SentrySpanStatusV2.ok);
  });

  testWidgets('an action with no screen open is a segment of its own', (
    tester,
  ) async {
    final rig = streamRig();
    await rig.boot(tester);
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final rename = actionProvider<String, String>(
      (ref, input) async => input,
      invalidates: () => const [],
      telemetry: actionSite,
    );
    c.listen(rename, (_, _) {});
    await c.read(rename.notifier).call('a');
    await tester.pump();
    final action = segments(rig.sentry.spans).last;
    expect(op(action), 'fespalier.action');
    expect(action.name, r'action items/$id/action.dart#rename');
    expect(attr(action, 'sentry.segment.name.source'), 'component');
    expect(attr(action, 'fespalier.action.result'), 'ok');
    expect(action.status, SentrySpanStatusV2.ok);
  });

  group('an auth step', () {
    const start = TelemetryStart(
      TelemetryOp.auth,
      authStep: 'refresh',
      authBackend: 'oidc',
    );
    const end = TelemetryEnd(TelemetryOutcome.ok, isAsync: true);

    testWidgets('outside any span makes no span', (tester) async {
      final rig = streamRig();
      await rig.boot(tester);
      await tester.pump();
      final before = rig.sentry.spans.length;
      FespalierTelemetry.finish(FespalierTelemetry.begin(start), end);
      await tester.pump();
      expect(rig.sentry.spans, hasLength(before));
    });

    testWidgets('inside an action is the action\'s child', (tester) async {
      final rig = streamRig();
      await rig.boot(tester);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final refresh = actionProvider<String, String>(
        (ref, input) async {
          FespalierTelemetry.finish(FespalierTelemetry.begin(start), end);
          return input;
        },
        invalidates: () => const [],
        telemetry: actionSite,
      );
      c.listen(refresh, (_, _) {});
      await c.read(refresh.notifier).call('a');
      await tester.pump();
      final spans = rig.sentry.spans;
      final action = segments(spans).last;
      final auth = childrenOf(spans, action, 'fespalier.auth').single;
      expect(auth.name, 'auth refresh');
      expect(attr(auth, 'fespalier.auth.backend'), 'oidc');
      expect(auth.status, SentrySpanStatusV2.ok);
    });
  });

  testWidgets('no attribute holds a segment value, a query value, a family '
      'key, an input, a result or a data value', (tester) async {
    load = (id) async => 'secret-data-$id';
    final rig = streamRig(configure: (o) => o.sendDefaultPii = false);
    final r = await rig.boot(tester);
    r.go('/items/90210?q=secret-query');
    await tester.pumpAndSettle();
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final echo = actionProvider<String, String>(
      (ref, input) async => 'secret-result-$input',
      invalidates: () => const [],
      telemetry: actionSite,
    );
    c.listen(echo, (_, _) {});
    await c.read(echo.notifier).call('secret-input');
    final invalid = actionProvider<String, String>(
      (ref, input) async =>
          throw const FieldErrors(<String, String>{'name': 'secret-typed'}),
      invalidates: () => const [],
      telemetry: actionSite,
    );
    c.listen(invalid, (_, _) {});
    await expectLater(
      c.read(invalid.notifier).call('secret-input'),
      throwsA(isA<FieldErrors>()),
    );
    await tester.pump();
    final spans = rig.sentry.spans;
    expect(spans, isNotEmpty);
    final everything = [
      for (final s in spans) ...[
        s.name,
        for (final e in s.attributes.entries) '${e.key}=${e.value.value}',
      ],
    ].join('\n');
    for (final value in [
      '90210',
      'secret-query',
      'secret-data',
      'secret-result',
      'secret-input',
      'secret-typed',
    ]) {
      expect(everything, isNot(contains(value)));
    }
    // A validation answer is no failure.
    final action = segments(spans).last;
    expect(action.status, SentrySpanStatusV2.ok);
    expect(attr(action, 'fespalier.action.result'), 'error');
  });

  group('a sync call stays sync', () {
    test('data() is a value, in the same call', () {
      streamRig();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(syncData), 'sync');
    });

    testWidgets('a sync guard redirects in the same call', (tester) async {
      checkout = () => '/login';
      final rig = streamRig();
      final r = await rig.boot(tester);
      r.go('/checkout');
      await tester.pumpAndSettle();
      expect(find.text('login'), findsOneWidget);
    });
  });

  testWidgets('an error in a streamed data load is an event linked to its '
      'span', (tester) async {
    load = (_) => Future<String>.error(StateError('no such item'));
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    final sent = await rig.sent(tester);
    final event = sent.singleWhere((e) => e['type'] != 'transaction');
    final data = rig.sentry.spans.singleWhere((s) => op(s) == 'fespalier.data');
    expect(data.status, SentrySpanStatusV2.error);
    expect(attr(data, 'fespalier.data.state'), 'error');
    final trace = map(map(event['contexts'])['trace']);
    expect(trace['span_id'], data.spanId.toString());
    expect(trace['trace_id'], data.traceId.toString());
    expect(trace['parent_span_id'], data.parentSpan!.spanId.toString());
    expect(trace['op'], 'fespalier.data');
  });

  testWidgets('on Android the first screen is Sentry\'s app start in stream '
      'mode too', (tester) async {
    final display = FakeDisplay();
    final rig = streamRig(
      platform: TargetPlatform.android,
      currentDisplay: (_) => display,
    );
    final r = await rig.boot(tester);
    await tester.pump();
    expect(rig.sentry.spans, isEmpty);
    r.go('/other');
    await tester.pumpAndSettle();
    expect(segments(await spansOf(rig, tester)).map((s) => s.name), ['/other']);
    expect(display.reported, 1);
  });

  group('with tracing off', () {
    testWidgets('nothing is streamed, and M-S3 is still printed once', (
      tester,
    ) async {
      final rig = streamRig(
        configured: false,
        configure: (o) => o.tracesSampleRate = null,
      );
      final printed = await printing(() async {
        final r = await rig.boot(tester);
        r.go('/items/7');
        await tester.pumpAndSettle();
        r.go('/other');
        await tester.pumpAndSettle();
      });
      expect(printed, hasLength(1));
      expect(
        printed.single,
        startsWith('fespalier_sentry: tracing: true needs'),
      );
      expect(await spansOf(rig, tester), isEmpty);
      expect(rig.sentry.tags['fespalier.route'], '/other');
    });

    testWidgets('and without tracing: true at all', (tester) async {
      final rig = streamRig(tracing: false);
      final r = await rig.boot(tester);
      r.go('/items/7');
      await tester.pumpAndSettle();
      expect(await spansOf(rig, tester), isEmpty);
    });
  });

  testWidgets('what is true of the trace: every segment of a session is in '
      'the same trace', (tester) async {
    // As with `static`, a root span's trace is the scope's propagation context's, which only
    // `enableNewTraceOnNavigation` of Sentry's observer (or a stay in the background) renews.
    final rig = streamRig();
    final r = await rig.boot(tester);
    r.go('/other');
    await tester.pumpAndSettle();
    final all = segments(await spansOf(rig, tester));
    expect(all, hasLength(2));
    expect(all.first.traceId, all.last.traceId);
  });

  testWidgets('transactions: false makes no segment of its own, and no span '
      'when no other span is active', (tester) async {
    final rig = Rig(
      tracing: true,
      transactions: false,
      configure: (o) => o.traceLifecycle = SentryTraceLifecycle.stream,
    );
    final r = await rig.boot(tester);
    r.go('/items/7');
    await tester.pumpAndSettle();
    expect(await spansOf(rig, tester), isEmpty);
    expect(rig.sentry.tags['fespalier.route'], '/items/:id');
  });
}
