// The adapter seam without a generated app: a hand-made router and container. The generated
// wiring (AppAdapters, telemetry: true) is proved end to end by examples/plugins.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_analytics/fespalier_adapter.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_analytics/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

GoRouter _router({required bool telemetry}) {
  final r = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const Text('home'))],
  );
  if (telemetry) telemetryAttach(r, base: () => '/');
  return r;
}

void main() {
  late List<FlutterErrorDetails> reported;

  // flutter_test installs its own handler when a test body starts, so take it over there.
  void captureReports() {
    final original = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = original);
  }

  setUp(() {
    FespalierAnalytics.debugReset();
    reported = [];
  });
  tearDown(() {
    FespalierTelemetry.install(null);
    FespalierAnalytics.debugReset();
  });

  group('unconfigured', () {
    test('reports once, names the missing call, and does nothing', () {
      captureReports();
      expect(adapter.beforeRun(), isNull);
      expect(adapter.beforeRun(), isNull);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(telemetry: false), container);
      expect(FespalierTelemetry.current, isNull);
      expect(reported, hasLength(1));
      expect(
        '${reported.single.exception}',
        allOf(contains('FespalierAnalytics.configure'), contains('before')),
      );
    });

    test('the consent provider says so once and keeps its state', () {
      captureReports();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(analyticsConsent), AnalyticsConsent.undecided);
      container.read(analyticsConsent.notifier).set(AnalyticsConsent.granted);
      container.read(analyticsConsent.notifier).set(AnalyticsConsent.denied);
      expect(container.read(analyticsConsent), AnalyticsConsent.denied);
      expect(reported, hasLength(1));
    });
  });

  group('beforeRun', () {
    test('adds the sink next to the installed one, synchronously, once', () {
      final other = RecordingTelemetry();
      FespalierTelemetry.install(other);
      FespalierAnalytics.configure(RecordingAnalytics());
      expect(adapter.beforeRun(), isNull);
      final first = FespalierTelemetry.current;
      expect(first, isNot(same(other)));
      adapter.beforeRun();
      expect(FespalierTelemetry.current, same(first));
    });

    test('alone, the sink is the installed one', () {
      FespalierAnalytics.configure(RecordingAnalytics());
      adapter.beforeRun();
      expect(FespalierTelemetry.current, same(FespalierAnalytics.sink));
    });

    test('configure again replaces the sink in the slot', () {
      final first = RecordingAnalytics();
      FespalierAnalytics.configure(first, consent: AnalyticsConsent.granted);
      adapter.beforeRun();
      final old = FespalierAnalytics.sink!;
      final second = RecordingAnalytics();
      FespalierAnalytics.configure(second, consent: AnalyticsConsent.granted);
      final fresh = FespalierAnalytics.sink!;
      expect(fresh, isNot(same(old)));
      // The old one is retired: it ignores a page event, and a consent change.
      old.page(null, const TelemetryPage(TelemetryPageKind.enter, '/a'));
      expect(first.views, isEmpty);
      expect(old.start(const TelemetryStart(TelemetryOp.navigate)), isNull);
      old.consent = AnalyticsConsent.denied;
      expect(first.consents, isEmpty);
      fresh.page(null, const TelemetryPage(TelemetryPageKind.enter, '/a'));
      expect(second.views, hasLength(1));
    });
  });

  group('attach', () {
    test('reports once when the router does not follow telemetry', () {
      captureReports();
      FespalierAnalytics.configure(RecordingAnalytics());
      adapter.beforeRun();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(telemetry: false), container);
      adapter.attach(_router(telemetry: false), container);
      expect(reported, hasLength(1));
      expect(
        '${reported.single.exception}',
        allOf(contains('telemetry: true'), contains('fsp gen')),
      );
    });

    test('says nothing when the router follows telemetry', () {
      captureReports();
      FespalierAnalytics.configure(RecordingAnalytics());
      adapter.beforeRun();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(telemetry: true), container);
      expect(reported, isEmpty);
    });

    test('reports once when a later install dropped the sink', () {
      captureReports();
      FespalierAnalytics.configure(RecordingAnalytics());
      adapter.beforeRun();
      FespalierTelemetry.install(RecordingTelemetry());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(telemetry: true), container);
      adapter.attach(_router(telemetry: true), container);
      expect(reported, hasLength(1));
      expect(
        '${reported.single.exception}',
        allOf(contains('FespalierTelemetry.add'), contains('not installed')),
      );
    });

    test('a sink added with add survives next to another', () {
      captureReports();
      FespalierAnalytics.configure(RecordingAnalytics());
      adapter.beforeRun();
      FespalierTelemetry.add(RecordingTelemetry());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      adapter.attach(_router(telemetry: true), container);
      expect(reported, isEmpty);
    });
  });

  group('the consent provider', () {
    test('starts at the sink\'s decision and sets it, telling the backend', () {
      final backend = RecordingAnalytics();
      FespalierAnalytics.configure(backend, consent: AnalyticsConsent.denied);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(analyticsConsent), AnalyticsConsent.denied);
      container.read(analyticsConsent.notifier).set(AnalyticsConsent.granted);
      expect(container.read(analyticsConsent), AnalyticsConsent.granted);
      expect(FespalierAnalytics.sink!.consent, AnalyticsConsent.granted);
      expect(backend.consents, [AnalyticsConsent.granted]);
    });
  });
}
