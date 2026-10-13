import 'package:fespalier/fespalier.dart';

import 'backend.dart';
import 'sink.dart';

/// The consent for a settings screen: `ref.watch(analyticsConsent)` reads it, and
/// `ref.read(analyticsConsent.notifier).set(AnalyticsConsent.granted)` changes it, which tells
/// the configured sink (and so the backend). It starts at the sink's own decision; a change made
/// on the sink directly afterwards is not seen here, so use one or the other after the first
/// frame.
final analyticsConsent =
    NotifierProvider<AnalyticsConsentNotifier, AnalyticsConsent>(
      AnalyticsConsentNotifier.new,
    );

/// The state behind [analyticsConsent].
class AnalyticsConsentNotifier extends Notifier<AnalyticsConsent> {
  @override
  AnalyticsConsent build() =>
      FespalierAnalytics.sink?.consent ?? AnalyticsConsent.undecided;

  /// Records the person's decision. Without a configured sink it is reported once and only the
  /// state changes.
  void set(AnalyticsConsent value) {
    final sink = FespalierAnalytics.sink;
    if (sink == null) {
      FespalierAnalytics.reportMissing();
    } else {
      sink.consent = value;
    }
    state = value;
  }
}
