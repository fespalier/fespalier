/// The adapter `fespalier: adapters: [fespalier_analytics]` lists (since 0.13.0). Configure the
/// package first: `FespalierAnalytics.configure(backend)` in `main()`. The app must be generated
/// with `telemetry: true`, or no page event reaches the sink.
library;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show FespalierAdapter;

import 'src/sink.dart';

/// What the generated `AppAdapters` forwards to.
const adapter = AnalyticsAdapter();

/// Installs the sink in `beforeRun` (so the first navigation is reported) and checks in `attach`
/// that the router reports page events.
final class AnalyticsAdapter extends FespalierAdapter {
  /// Constant, like every adapter.
  const AnalyticsAdapter();

  @override
  Future<void>? beforeRun() {
    FespalierAnalytics.install();
    return null;
  }

  @override
  void attach(GoRouter router, ProviderContainer container) =>
      FespalierAnalytics.verifyTelemetry(router);
}
