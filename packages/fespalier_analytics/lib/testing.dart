/// A recording backend for a test of an app that uses fespalier_analytics (since 0.13.0). No
/// SDK, no channel and no timer.
///
/// ```dart
/// final analytics = RecordingAnalytics();
/// FespalierAnalytics.configure(analytics, consent: AnalyticsConsent.granted);
/// await AppAdapters.beforeRun(); // what main() does before runApp
/// await tester.pumpWidget(AppMain.root());
/// expect(analytics.views.single.pattern, '/');
/// ```
library;

import 'fespalier_analytics.dart';

/// An [AnalyticsBackend] that writes down what it was told.
class RecordingAnalytics extends AnalyticsBackend {
  /// Creates a recorder; [throwing] makes every call throw, for the test of an app whose SDK
  /// fails.
  RecordingAnalytics({this.throwing = false});

  /// Whether every call throws a [StateError] after recording.
  final bool throwing;

  /// Every [AnalyticsBackend.screenView], in order.
  final List<ScreenView> views = [];

  /// Every [AnalyticsBackend.screenTime], in order.
  final List<ScreenTime> times = [];

  /// Every [AnalyticsBackend.consentChanged], in order.
  final List<AnalyticsConsent> consents = [];

  /// What happened, in order, one line each: `view <name>`, with ` source=<source>` and
  /// ` returning` when they apply (`view Order source=notification`), `time <name> <n>ms` and
  /// `consent <state>`.
  final List<String> log = [];

  /// Everything the backend was given, as strings: for a test that asserts no URL, query or
  /// segment value ever reached it.
  Iterable<String> get strings => [
    for (final v in views) ...[v.name, v.pattern, ?v.source],
    for (final t in times) ...[t.name, t.pattern],
  ];

  @override
  void screenView(ScreenView view) {
    views.add(view);
    log.add(
      'view ${view.name}'
      '${view.source == null ? '' : ' source=${view.source}'}'
      '${view.returning ? ' returning' : ''}',
    );
    _maybeThrow();
  }

  @override
  void screenTime(ScreenTime time) {
    times.add(time);
    log.add('time ${time.name} ${time.duration.inMilliseconds}ms');
    _maybeThrow();
  }

  @override
  void consentChanged(AnalyticsConsent consent) {
    consents.add(consent);
    log.add('consent ${consent.name}');
    _maybeThrow();
  }

  /// Forgets what was recorded.
  void clear() {
    views.clear();
    times.clear();
    consents.clear();
    log.clear();
  }

  void _maybeThrow() {
    if (throwing) throw StateError('RecordingAnalytics: the SDK failed');
  }
}
