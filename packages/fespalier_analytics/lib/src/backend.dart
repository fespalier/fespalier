/// A screen the person is looking at. Never a URL: `name` comes from the route pattern (or from
/// the app's `screenName`), so no segment value, query value or fragment can be in it.
final class ScreenView {
  /// A view of the screen [name], whose route pattern is [pattern].
  const ScreenView({
    required this.name,
    required this.pattern,
    this.source,
    this.returning = false,
  });

  /// The screen's name: `screenName(pattern)`, which is the pattern itself by default.
  final String name;

  /// The route pattern, `/products/:id`: the segment's name, never its value.
  final String pattern;

  /// A `NavigationSource` value (`notification`, `shortcut`, `widget`, `link`) when the
  /// navigation that showed the screen was not the app's own; null otherwise.
  final String? source;

  /// A screen that is the visible one again (back to a tab, a pop), not a first entry.
  final bool returning;

  @override
  bool operator ==(Object other) =>
      other is ScreenView &&
      other.name == name &&
      other.pattern == pattern &&
      other.source == source &&
      other.returning == returning;

  @override
  int get hashCode => Object.hash(name, pattern, source, returning);

  @override
  String toString() =>
      'ScreenView($name, pattern: $pattern'
      '${source == null ? '' : ', source: $source'}'
      '${returning ? ', returning' : ''})';
}

/// How long a screen was open, reported when it is left.
final class ScreenTime {
  /// [duration] on the screen [name], whose route pattern is [pattern].
  const ScreenTime({
    required this.name,
    required this.pattern,
    required this.duration,
  });

  /// The screen's name, as in [ScreenView.name].
  final String name;

  /// The route pattern, as in [ScreenView.pattern].
  final String pattern;

  /// From the screen's entry to its leaving; the time another page covered it is included.
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      other is ScreenTime &&
      other.name == name &&
      other.pattern == pattern &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(name, pattern, duration);

  @override
  String toString() => 'ScreenTime($name, pattern: $pattern, $duration)';
}

/// What the person decided about analytics.
enum AnalyticsConsent {
  /// Not asked yet, or not answered: nothing is sent and nothing is kept.
  undecided,

  /// Agreed: screen views and times are sent.
  granted,

  /// Refused: nothing is sent and nothing is kept.
  denied,
}

/// What an analytics service gives `fespalier_analytics`: three methods, called synchronously
/// from the router's telemetry. The vendor SDK is the app's: Firebase Analytics, PostHog,
/// Mixpanel and Amplitude are recipes in the `fespalier-observability` skill, not dependencies.
///
/// A method must return at once and send nothing the backend was not given: a vendor call that
/// returns a `Future` is ignored with its own `onError` (`unawaited(call().catchError(...))`),
/// never awaited.
abstract class AnalyticsBackend {
  /// Constant, so a backend with no state can be `const`.
  const AnalyticsBackend();

  /// A screen came up. Only called while consent is [AnalyticsConsent.granted].
  void screenView(ScreenView view);

  /// A screen was left. Only called while consent is [AnalyticsConsent.granted], and only for a
  /// screen whose view was sent. Nothing by default.
  void screenTime(ScreenTime time) {}

  /// The consent changed: map it to the vendor's own switch (Firebase `setConsent` and
  /// `setAnalyticsCollectionEnabled`, PostHog `optIn` and `optOut`). Nothing by default.
  void consentChanged(AnalyticsConsent consent) {}
}
