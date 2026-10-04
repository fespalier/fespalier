// fespalier_sentry in the app, next to fespalier_otel, on a real Sentry hub whose transport keeps
// what it would send (RecordingSentry): errors first. A failing action is an event tagged with its
// route, its file and its name, and with the OpenTelemetry trace of the span the same call made, so
// the error links to its trace; a crash after a navigation says which screen it happened on; a
// page change is a breadcrumb. Screen-load transactions are the opt-in.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:fespalier_sentry/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/app.g.dart';

final InMemorySpanExporter exporter = InMemorySpanExporter();

const String dsn = 'https://key@sentry.invalid/1';

Map<String, Object?> map(Object? value) =>
    Map<String, Object?>.from(value! as Map);

/// A Sentry whose options are fespalier's, and both sinks installed in the one slot, as
/// `main.dart` does.
RecordingSentry install({bool tracing = false}) {
  final sentry = RecordingSentry(
    configure: (options) =>
        FespalierSentry.configure(options, dsn: dsn, tracing: tracing),
  );
  FespalierTelemetry.install(
    FespalierTelemetry.combine([
      FespalierSentry(hub: sentry.hub, tracing: tracing),
      FespalierOtel(),
    ]),
  );
  return sentry;
}

void main() {
  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'telemetry-example',
      serviceVersion: '1.0.0',
      resourceAttributes: OTel.attributesFromMap(
        FespalierOtel.resourceAttributes,
      ),
      enableLogs: false,
      enableMetrics: false,
      detectPlatformResources: false,
      spanProcessor: SimpleSpanProcessor(exporter),
    );
  });
  setUp(exporter.clear);
  tearDown(() => FespalierTelemetry.install(null));

  testWidgets('a refused refund is an event with its route, file and action, '
      'linked to its OpenTelemetry trace', (tester) async {
    final sentry = install();
    await pumpRouter(tester, AppRoutes.router(initialLocation: '/orders/1'));
    await tester.tap(find.text('Refuse'));
    await tester.pumpAndSettle();
    await tester.pump();
    final events = await sentry.sent();
    expect(events, hasLength(1));
    final event = events.single;
    final tags = map(event['tags']);
    expect(tags['fespalier.operation'], 'action');
    expect(tags['fespalier.route'], '/orders/:id');
    expect(tags['fespalier.file'], r'(tabs)/orders/$id/action.dart');
    expect(tags['fespalier.action'], 'action');
    // The span the same call made in the OpenTelemetry SDK: the trace to open.
    final span = exporter.findSpansByName(
      r'action (tabs)/orders/$id/action.dart#action',
    );
    expect(span, hasLength(1));
    expect(tags['otel.trace_id'], span.single.spanContext.traceId.hexString);
    expect(tags['otel.span_id'], span.single.spanContext.spanId.hexString);
    expect(await sentry.lines(), [
      r'event StateError operation=action route=/orders/:id file=(tabs)/orders/$id/action.dart action=action',
    ]);
  });

  testWidgets('a crash after opening an order says which screen it happened '
      'on, and links to the trace that opened it', (tester) async {
    final sentry = install();
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    router.go('/orders/1');
    await tester.pumpAndSettle();
    // What Sentry's own integrations do with an uncaught error.
    await sentry.hub.captureException(StateError('crash'));
    await tester.pump();
    final event = (await sentry.sent()).single;
    expect(event['transaction'], '/orders/:id');
    final navigation = exporter.findSpansByName('navigate /orders/:id').single;
    expect(
      map(event['tags']),
      containsPair('otel.trace_id', navigation.spanContext.traceId.hexString),
    );
    expect(map(event['tags']), containsPair('fespalier.route', '/orders/:id'));
  });

  testWidgets('a page change is a breadcrumb, and no transaction is sent', (
    tester,
  ) async {
    final sentry = install();
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    router.go('/orders');
    await tester.pumpAndSettle();
    router.go('/orders/1');
    await tester.pumpAndSettle();
    await tester.pump();
    expect(sentry.breadcrumbs, [
      'navigation enter /',
      'navigation enter /orders',
      'navigation enter /orders/:id',
    ]);
    expect(await sentry.lines(), isEmpty);
  });

  testWidgets('with tracing: true opening an order is a transaction with its '
      'data load', (tester) async {
    final sentry = install(tracing: true);
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    await tester.pump();
    sentry.transport.envelopes.clear();
    router.go('/orders/1');
    await tester.pumpAndSettle();
    await tester.pump();
    expect(await sentry.lines(), [
      'transaction ui.load /orders/:id status=ok ttid ttfd',
      r'  span fespalier.data data (tabs)/orders/$id/data.dart status=ok',
      '  span ui.load.initial_display /orders/:id initial display status=ok',
      '  span ui.load.full_display /orders/:id full display status=ok',
    ]);
  });
}
