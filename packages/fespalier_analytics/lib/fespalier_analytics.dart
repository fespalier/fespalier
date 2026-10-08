/// Screen views for fespalier, with consent (since 0.13.0): the route pattern of each page the
/// person opens, never the URL, sent to a backend of your own only while they have agreed.
/// Through the adapter in `package:fespalier_analytics/fespalier_adapter.dart`, which needs an
/// app generated with `telemetry: true`. The analytics SDK is the app's: Firebase Analytics,
/// PostHog, Mixpanel and Amplitude are recipes in the fespalier-observability skill.
library;

export 'src/backend.dart'
    show AnalyticsBackend, AnalyticsConsent, ScreenTime, ScreenView;
export 'src/consent.dart' show AnalyticsConsentNotifier, analyticsConsent;
export 'src/sink.dart' show AnalyticsSink, FespalierAnalytics;
export 'src/telemetry.dart' show FespalierAnalyticsConventions;
