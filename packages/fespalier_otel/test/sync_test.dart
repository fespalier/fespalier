// With the real adapter installed, fespalier's pass-through wrappers still return the very
// object (a sync guard stays sync, a Future is the same Future), and an adapter that is not
// ready, or whose SDK was never started, emits nothing and throws nothing.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry/testing.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_otel/fespalier_otel.dart';
import 'package:flutter_test/flutter_test.dart';

const TelemetrySite site = TelemetrySite(
  'a/guard.dart',
  route: '/a',
  name: 'act',
);

/// The state a guard is given; telemetry reads its `uri` and nothing else.
final class FakeState implements GoRouterState {
  FakeState(String location) : uri = Uri.parse(location);

  @override
  final Uri uri;

  @override
  String? get fullPath => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

final InMemorySpanExporter exporter = InMemorySpanExporter();

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  group('before the SDK is up', () {
    // This group runs first in the file: nothing initialised OTel yet.
    test('an adapter that is not ready emits nothing and throws nothing', () {
      FespalierTelemetry.install(FespalierOtel(isReady: () => false));
      expect(
        traceGuard(FakeState('/a'), 'g1@1', '/login', telemetry: site),
        '/login',
      );
      expect(exporter.spans, isEmpty);
    });

    test('an adapter with no isReady survives an SDK that never started', () {
      FespalierTelemetry.install(FespalierOtel());
      expect(
        traceGuard(FakeState('/a'), 'g1@1', null, telemetry: site),
        isNull,
      );
      final later = Future<String?>.value('/x');
      expect(
        identical(
          traceGuard(FakeState('/a'), 'g1@1', later, telemetry: site),
          later,
        ),
        isTrue,
      );
    });
  });

  group('within, before the SDK is up (since 0.9.0)', () {
    // Still before any OTel.initialize in this file.
    test('with no SDK, within is the call, and the very result comes back', () {
      FespalierTelemetry.install(FespalierOtel());
      var runs = 0;
      FespalierOtel().within('not one of ours', () => ++runs);
      FespalierOtel().within(null, () => ++runs);
      expect(runs, 2);
      // No span was made, so there is no token, and run() is the call.
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data),
      );
      expect(token, isNull);
      final value = Object();
      expect(
        identical(FespalierTelemetry.run(token, () => value), value),
        isTrue,
      );
    });

    test('sync data through traceDataCall stays a value', () {
      FespalierTelemetry.install(FespalierOtel());
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final value = Object();
      final p = Provider<Object>(
        (ref) => traceDataCall(ref, 'd1', null, () => value, telemetry: site),
      );
      expect(identical(c.read(p), value), isTrue);
      expect(exporter.spans, isEmpty);
    });
  });

  group('with the SDK up', () {
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
    });

    test('a sync guard stays sync and returns the same answer', () {
      final answer = traceGuard(
        FakeState('/a'),
        'g1@1',
        '/login',
        telemetry: site,
      );
      expect(answer, '/login');
      expect(answer is Future, isFalse);
      expect(exporter.spanNames, [
        'guard a/guard.dart',
      ], reason: 'exported synchronously, when the span ended');
    });

    test('a Future guard is the very same Future', () async {
      final later = Future<String?>.value('/x');
      expect(
        identical(
          traceGuard(FakeState('/a'), 'g1@1', later, telemetry: site),
          later,
        ),
        isTrue,
      );
      await later;
    });

    test('sync data stays a value', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final value = Object();
      final p = Provider<Object>(
        (ref) => traceData(ref, 'd1', null, value, telemetry: site),
      );
      expect(identical(c.read(p), value), isTrue);
      expect(exporter.spanNames, ['data a/guard.dart']);
    });

    test('sync data through traceDataCall stays a value, in its span', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final value = Object();
      var runs = 0;
      final p = Provider<Object>(
        (ref) => traceDataCall(ref, 'd1', null, () {
          runs++;
          return value;
        }, telemetry: site),
      );
      expect(identical(c.read(p), value), isTrue);
      expect(runs, 1);
      expect(exporter.spanNames, ['data a/guard.dart']);
    });

    test('a Future through traceDataCall is the very Future', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final later = Future<int>.value(1);
      final p = Provider<Future<int>>(
        (ref) => traceDataCall(ref, 'd1', null, () => later, telemetry: site),
      );
      expect(identical(c.read(p), later), isTrue);
      await later;
    });

    test('within makes the span current for the body, once, and no longer', () {
      final token = FespalierTelemetry.begin(
        const TelemetryStart(TelemetryOp.data, site: site),
      );
      var runs = 0;
      String? inside;
      FespalierTelemetry.run(token, () {
        runs++;
        inside = Context.current.spanContext?.spanId.toString();
      });
      expect(runs, 1);
      expect(Context.current.spanContext?.spanId.isValid ?? false, isFalse);
      FespalierTelemetry.finish(token, const TelemetryEnd('data'));
      expect(
        inside,
        exporter
            .findSpansByName('data a/guard.dart')
            .single
            .spanContext
            .spanId
            .toString(),
      );
    });

    test(
      'a body that throws comes back as it was, and the span is current',
      () {
        final token = FespalierTelemetry.begin(
          const TelemetryStart(TelemetryOp.data, site: site),
        );
        final error = StateError('data failed');
        expect(
          () => FespalierTelemetry.run<void>(token, () => throw error),
          throwsA(same(error)),
        );
        FespalierTelemetry.finish(
          token,
          TelemetryEnd(TelemetryOutcome.error, error: error),
        );
        expect(exporter.spanNames, ['data a/guard.dart']);
      },
    );

    test('an adapter that is not ready emits nothing', () {
      FespalierTelemetry.install(FespalierOtel(isReady: () => false));
      traceGuard(FakeState('/a'), 'g1@1', null, telemetry: site);
      expect(exporter.spans, isEmpty);
    });

    test('an adapter that becomes ready starts emitting', () {
      var ready = false;
      FespalierTelemetry.install(FespalierOtel(isReady: () => ready));
      traceGuard(FakeState('/a'), 'g1@1', null, telemetry: site);
      expect(exporter.spans, isEmpty);
      ready = true;
      traceGuard(FakeState('/a'), 'g1@1', null, telemetry: site);
      expect(exporter.spanNames, ['guard a/guard.dart']);
    });
  });
}
