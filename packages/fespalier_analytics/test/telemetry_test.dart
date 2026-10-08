import 'package:flutter/foundation.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_analytics/fespalier_analytics.dart';
import 'package:fespalier_analytics/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(FespalierAnalytics.debugReset);

  test('the names are the package contract', () {
    expect(
      FespalierAnalyticsConventions.consent,
      'fespalier.analytics.consent',
    );
    expect(FespalierAnalyticsConventions.state, 'fespalier.analytics.state');
  });

  test('a consent change is a span that names the state and nothing else', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    FespalierAnalytics.configure(RecordingAnalytics());
    FespalierAnalytics.sink!.consent = AnalyticsConsent.granted;
    FespalierAnalytics.sink!.consent = AnalyticsConsent.denied;
    expect(rec.log, [
      '#1 start custom fespalier.analytics.consent fespalier.analytics.state=granted',
      '#1 end custom ok',
      '#2 start custom fespalier.analytics.consent fespalier.analytics.state=denied',
      '#2 end custom ok',
    ]);
  });

  test('a failing backend ends the span with an error', () {
    final rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    final original = FlutterError.onError;
    FlutterError.onError = (_) {};
    addTearDown(() => FlutterError.onError = original);
    FespalierAnalytics.configure(RecordingAnalytics(throwing: true));
    FespalierAnalytics.sink!.consent = AnalyticsConsent.granted;
    expect(rec.log.last, startsWith('#1 end custom error'));
    // The error reported is a fixed one: what the SDK said is not.
    expect(rec.log.last, isNot(contains('SDK failed')));
  });
}
