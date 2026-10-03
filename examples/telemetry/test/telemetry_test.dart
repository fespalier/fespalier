// The app on the real OpenTelemetry SDK with an in-memory exporter: what its navigations, guard,
// data, action and deferred page become, as the span tree a collector would receive.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry/app.g.dart';

final InMemorySpanExporter exporter = InMemorySpanExporter();

Span only(String name) {
  final found = exporter.findSpansByName(name);
  expect(found, hasLength(1), reason: '$name in ${exporter.spanNames}');
  return found.single;
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
  setUp(() {
    exporter.clear();
    FespalierTelemetry.install(FespalierOtel());
  });
  tearDown(() => FespalierTelemetry.install(null));

  // First: the deferred library stays loaded for the rest of the file once any test loads it.
  test('the code of the settings page loads once, as a span', () async {
    // The deferred import of /settings, as the generated file builds it.
    final lib = AppRoutes.deferred.single;
    await lib.load();
    final span = only('deferred (tabs)/settings/page.dart');
    expect(span.attributes.getString('fespalier.route'), '/settings');
    expect(span.attributes.getString('fespalier.deferred.result'), 'ok');
    exporter.clear();
    await lib.load();
    expect(exporter.spans, isEmpty, reason: 'loaded for good: no more spans');
  });

  testWidgets('the first navigation is a span from the router being attached', (
    tester,
  ) async {
    await pumpRouter(tester, AppRoutes.router());
    final nav = only('navigate /');
    expect(nav.attributes.getString('fespalier.navigation.kind'), 'initial');
    expect(nav.spanEvents?.map((e) => e.name), ['fespalier.page.enter']);
  });

  testWidgets('an order: its data load is a child of the navigation to it', (
    tester,
  ) async {
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    exporter.clear();
    router.go('/orders/1');
    await tester.pumpAndSettle();
    final nav = only('navigate /orders/:id');
    final data = only(r'data (tabs)/orders/$id/data.dart');
    expect(data.parentSpanContext?.spanId, nav.spanContext.spanId);
    expect(data.attributes.getString('fespalier.route'), '/orders/:id');
    expect(data.attributes.getString('fespalier.data.state'), 'data');
    expect(data.attributes.getBool('fespalier.data.keyed'), true);
  });

  testWidgets('the refund button runs an action: a span of its own', (
    tester,
  ) async {
    final router = AppRoutes.router(initialLocation: '/orders/1');
    await pumpRouter(tester, router);
    exporter.clear();
    await tester.tap(find.text('Refund'));
    await tester.pumpAndSettle();
    final action = only(r'action (tabs)/orders/$id/action.dart#action');
    expect(action.attributes.getString('fespalier.action.name'), 'action');
    expect(action.attributes.getString('fespalier.action.result'), 'ok');
    expect(action.parentSpanContext?.spanId.isValid ?? false, isFalse);
  });

  testWidgets(
    'the guarded, deferred settings page: a guard span, a deferred span',
    (tester) async {
      final router = AppRoutes.router();
      await pumpRouter(tester, router);
      exporter.clear();
      router.go('/settings');
      await tester.pumpAndSettle();
      final nav = only('navigate /settings');
      final guard = only('guard (tabs)/settings/guard.dart');
      expect(guard.parentSpanContext?.spanId, nav.spanContext.spanId);
      expect(guard.attributes.getString('fespalier.guard.decision'), 'pass');
      // pumpRouter loaded the code before the first frame, so there is nothing to load now.
      expect(exporter.findSpansStartingWith('deferred '), isEmpty);
    },
  );

  testWidgets('a location that is no page is not_found, not an error', (
    tester,
  ) async {
    final router = AppRoutes.router();
    await pumpRouter(tester, router);
    exporter.clear();
    router.go('/nowhere');
    await tester.pumpAndSettle();
    final nav = only('navigate (not found)');
    expect(
      nav.attributes.getString('fespalier.navigation.outcome'),
      'not_found',
    );
    expect(nav.status, SpanStatusCode.Unset);
  });
}
