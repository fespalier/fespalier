// FespalierOtel tells the other sinks of a `combine` which trace an operation is in (since 0.9.0:
// `traceOf`), so that fespalier_sentry can tag an event with the OpenTelemetry trace of the screen
// or the call it came from. The ids are the ones the exporter receives.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/src/telemetry.dart'
    show telemetryNavigationEnd, telemetryNavigationStart;
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite dataSite = TelemetrySite(
  'items/\$id/data.dart',
  route: '/items/:id',
);

final InMemorySpanExporter exporter = InMemorySpanExporter();

/// What a sink that is told about traces keeps: the other side of `linkTrace`.
final class Linked extends FespalierTelemetry {
  final Map<Object?, TelemetryTrace> traces = {};
  int _n = 0;

  @override
  Object? start(TelemetryStart start) => 'linked:${++_n}:${start.op.name}';

  @override
  void linkTrace(Object? token, TelemetryTrace trace) => traces[token] = trace;
}

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
  setUp(exporter.clear);
  tearDown(() => FespalierTelemetry.install(null));

  test('traceOf is the trace and span id of the span made for the token', () {
    final otel = FespalierOtel();
    final token = otel.start(
      const TelemetryStart(TelemetryOp.data, site: dataSite),
    );
    final trace = otel.traceOf(token);
    otel.end(token, const TelemetryEnd(TelemetryOutcome.data));
    final span = only(r'data items/$id/data.dart');
    expect(trace, isNotNull);
    expect(trace!.traceId, span.spanContext.traceId.hexString);
    expect(trace.spanId, span.spanContext.spanId.hexString);
    expect(trace.traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(trace.spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('a token that is not ours, or none, has no trace', () {
    final otel = FespalierOtel();
    expect(otel.traceOf(null), isNull);
    expect(otel.traceOf('somebody else'), isNull);
  });

  test('no SDK, no token, no trace', () {
    final otel = FespalierOtel(isReady: () => false);
    final token = otel.start(
      const TelemetryStart(TelemetryOp.data, site: dataSite),
    );
    expect(token, isNull);
    expect(otel.traceOf(token), isNull);
  });

  test('in a combine, the other sink is told the span of each operation', () {
    final linked = Linked();
    FespalierTelemetry.install(
      FespalierTelemetry.combine([linked, FespalierOtel()]),
    );
    final navigation = telemetryNavigationStart(Uri.parse('/items/7'));
    final data = FespalierTelemetry.begin(
      TelemetryStart(TelemetryOp.data, site: dataSite, parent: navigation),
    );
    FespalierTelemetry.finish(data, const TelemetryEnd(TelemetryOutcome.data));
    telemetryNavigationEnd(
      navigation,
      const TelemetryEnd(TelemetryOutcome.ok, route: '/items/:id', kind: 'go'),
    );
    final nav = only('navigate /items/:id');
    final dataSpan = only(r'data items/$id/data.dart');
    expect(
      linked.traces['linked:1:navigate'],
      TelemetryTrace(
        nav.spanContext.traceId.hexString,
        nav.spanContext.spanId.hexString,
      ),
    );
    // A data span is a child of its navigation: the same trace, its own span.
    final seen = linked.traces['linked:2:data']!;
    expect(seen.traceId, nav.spanContext.traceId.hexString);
    expect(seen.spanId, dataSpan.spanContext.spanId.hexString);
    expect(seen.spanId, isNot(nav.spanContext.spanId.hexString));
  });
}
