/// The names fespalier_analytics reports (since 0.13.0). The package's own contract, pinned by
/// `test/telemetry_test.dart`: add a key, never rename one. A screen name, a pattern, a URL and
/// anything a backend was given are never reported: only that the consent changed, and to what.
abstract final class FespalierAnalyticsConventions {
  /// The consent was changed: a span from the call to the backend's answer.
  static const String consent = 'fespalier.analytics.consent';

  /// Start attribute of [consent]: the new state, an `AnalyticsConsent` name (`undecided`,
  /// `granted` or `denied`).
  static const String state = 'fespalier.analytics.state';
}
