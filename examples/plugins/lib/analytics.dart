import 'package:fespalier_analytics/testing.dart';

/// The analytics service of this demo: a recorder the tests read. A real app writes an
/// `AnalyticsBackend` over its vendor SDK (the fespalier-observability skill has the Firebase
/// Analytics, PostHog, Mixpanel and Amplitude recipes) and hands that to
/// `FespalierAnalytics.configure` instead.
final RecordingAnalytics demoAnalytics = RecordingAnalytics();

/// The name of each screen, from its route pattern: a person-readable one for the two pages an
/// analyst asks about, the pattern itself for the rest, and none for the login page, which says
/// nothing the funnel needs. A pattern holds the segment's name (`/orders/:id`), never its value.
String? screenName(String pattern) => switch (pattern) {
  '/' => 'Home',
  '/orders/:id' => 'Order',
  '/login' => null,
  _ => pattern,
};
