import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'backend.dart';
import 'telemetry.dart';

/// The navigation a screen event belongs to: what its `start` kept.
final class _Navigation {
  const _Navigation(this.source);
  final String? source;
}

/// The telemetry sink that turns page events into screen views (since 0.13.0). It sits next to
/// `fespalier_otel` or `fespalier_sentry` in `FespalierTelemetry.combine`, is called
/// synchronously by the router and returns at once.
///
/// **Consent decides everything.** While [consent] is not [AnalyticsConsent.granted] a page
/// event is dropped on the spot: nothing reaches the backend and nothing is kept (no buffer, no
/// "last screen"). Granting does not replay what was dropped: the next screen is the first one
/// reported.
final class AnalyticsSink extends FespalierTelemetry {
  /// Reports to [backend]. [screenName] maps a route pattern to the screen's name (null skips
  /// that screen; the default is the pattern itself). [returningViews] reports a screen that
  /// becomes the visible one again; [screenTime] reports how long a screen was open when it is
  /// left. [consent] is the decision the sink starts with.
  AnalyticsSink(
    this.backend, {
    String? Function(String pattern)? screenName,
    this.returningViews = true,
    this.screenTime = true,
    AnalyticsConsent consent = AnalyticsConsent.undecided,
  }) : _screenName = screenName,
       _consent = consent;

  /// Where the views go.
  final AnalyticsBackend backend;

  /// Whether a screen that is the visible one again is reported (`ScreenView.returning`).
  final bool returningViews;

  /// Whether the time on a screen is reported when it is left.
  final bool screenTime;

  final String? Function(String pattern)? _screenName;
  AnalyticsConsent _consent;
  bool _retired = false;

  /// How many instances of each pattern were entered while consent was granted and whose view
  /// was sent: the patterns of screens already reported, so a leave is timed only for those.
  /// Empty whenever consent is not granted.
  final Map<String, int> _open = {};

  /// The decision now.
  AnalyticsConsent get consent => _consent;

  /// Changes the decision and tells the backend ([AnalyticsBackend.consentChanged]); the same
  /// value again does nothing. Leaving [AnalyticsConsent.granted] forgets which screens are
  /// open, and nothing that was dropped is ever sent afterwards. A backend that throws is
  /// reported (`FlutterError.reportError`), not rethrown: the decision stands.
  set consent(AnalyticsConsent value) {
    if (_retired || value == _consent) return;
    _consent = value;
    if (value != AnalyticsConsent.granted) _open.clear();
    final token = FespalierTelemetry.begin(
      TelemetryStart(
        TelemetryOp.custom,
        name: FespalierAnalyticsConventions.consent,
        attributes: {FespalierAnalyticsConventions.state: value.name},
      ),
    );
    Object? failure;
    try {
      backend.consentChanged(value);
    } catch (error, stack) {
      failure = StateError('fespalier_analytics: consentChanged failed');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'fespalier_analytics',
          context: ErrorDescription('telling the backend the consent changed'),
        ),
      );
    }
    FespalierTelemetry.finish(
      token,
      TelemetryEnd(
        failure == null ? TelemetryOutcome.ok : TelemetryOutcome.error,
        error: failure,
      ),
    );
  }

  /// Stops this sink for good: `configure` replaced it.
  void _retire() {
    _retired = true;
    _open.clear();
  }

  @override
  Object? start(TelemetryStart start) =>
      start.op == TelemetryOp.navigate ? _Navigation(start.source) : null;

  @override
  void page(Object? navigation, TelemetryPage page) {
    if (_retired || _consent != AnalyticsConsent.granted) return;
    final pattern = page.route;
    if (pattern == null) return;
    final name = _screenName == null ? pattern : _screenName(pattern);
    if (name == null || name.isEmpty) return;
    final source = navigation is _Navigation ? navigation.source : null;
    switch (page.kind) {
      case TelemetryPageKind.enter:
        _open[pattern] = (_open[pattern] ?? 0) + 1;
        backend.screenView(
          ScreenView(name: name, pattern: pattern, source: source),
        );
      case TelemetryPageKind.focus:
        if (!returningViews) return;
        backend.screenView(
          ScreenView(
            name: name,
            pattern: pattern,
            source: source,
            returning: true,
          ),
        );
      case TelemetryPageKind.leave:
        final open = _open[pattern] ?? 0;
        if (open == 0) return;
        if (open == 1) {
          _open.remove(pattern);
        } else {
          _open[pattern] = open - 1;
        }
        final duration = page.duration;
        if (!screenTime || duration == null) return;
        backend.screenTime(
          ScreenTime(name: name, pattern: pattern, duration: duration),
        );
    }
  }
}

/// Configures fespalier_analytics before the adapters run (since 0.13.0). The adapter in
/// `fespalier_adapter.dart` cannot be handed options by the pubspec, and `beforeRun()` runs
/// before any `ProviderScope` exists, so the app's `main()` calls this first:
///
/// ```dart
/// Future<void> main() {
///   FespalierAnalytics.configure(MyBackend(), screenName: screenName);
///   return AppMain.run();
/// }
/// ```
///
/// Calling it twice replaces (a hot restart runs `main()` again): the earlier sink stops
/// reporting and the new one takes its place. Load the stored decision in `startup()`, which
/// runs before the router, so the first screen is not lost: `FespalierAnalytics.sink?.consent =
/// stored`.
abstract final class FespalierAnalytics {
  /// Makes the sink that reports to [backend]. See [AnalyticsSink] for [screenName],
  /// [returningViews], [screenTime] and [consent]. The backend is not told the initial
  /// [consent]: that is the SDK's own start-up.
  static void configure(
    AnalyticsBackend backend, {
    String? Function(String pattern)? screenName,
    bool returningViews = true,
    bool screenTime = true,
    AnalyticsConsent consent = AnalyticsConsent.undecided,
  }) {
    _sink?._retire();
    final next = AnalyticsSink(
      backend,
      screenName: screenName,
      returningViews: returningViews,
      screenTime: screenTime,
      consent: consent,
    );
    _sink = next;
    _reportedMissing = false;
    _reportedNoTelemetry = false;
    // The earlier sink is in the telemetry slot: the new one takes its place there.
    if (_installed != null) {
      _installed = next;
      FespalierTelemetry.add(next);
    }
  }

  /// The configured sink, or null before [configure].
  static AnalyticsSink? get sink => _sink;

  /// Adds the configured sink to the telemetry (`FespalierTelemetry.add`), once: what the
  /// adapter's `beforeRun` does. Reports (a `FlutterError`, once) and does nothing when
  /// [configure] was not called. Returns whether a sink is installed.
  static bool install() {
    final sink = _sink;
    if (sink == null) {
      reportMissing();
      return false;
    }
    if (!identical(_installed, sink)) {
      _installed = sink;
      FespalierTelemetry.add(sink);
    }
    return true;
  }

  /// Reports, once, that the app's router does not report its page events to telemetry: the app
  /// was generated without `telemetry: true`, so no screen is ever recorded. What the adapter's
  /// `attach` calls, with the router it was given.
  static void verifyTelemetry(GoRouter router) {
    if (_sink == null || _reportedNoTelemetry || telemetryFollows(router)) {
      return;
    }
    _reportedNoTelemetry = true;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError(
          "fespalier_analytics records no screen: this app's router does not report page "
          'events to telemetry. Set `telemetry: true` under `fespalier:` in pubspec.yaml and '
          'run `fsp gen`.',
        ),
        library: 'fespalier_analytics',
      ),
    );
  }

  /// Reports, once, that the package is used without [configure]. The adapter, the consent
  /// provider and [install] call it.
  static void reportMissing() {
    if (_reportedMissing) return;
    _reportedMissing = true;
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError(
          'fespalier_analytics is listed under `fespalier: adapters:` but was never '
          'configured: call FespalierAnalytics.configure(backend) in main() before '
          'AppMain.run()',
        ),
        library: 'fespalier_analytics',
      ),
    );
  }

  /// Forgets what [configure] stored and stops its sink, for a test that sets up its own. It
  /// does not take the sink out of `FespalierTelemetry` (a test installs its own around it).
  @visibleForTesting
  static void debugReset() {
    _sink?._retire();
    _sink = null;
    _installed = null;
    _reportedMissing = false;
    _reportedNoTelemetry = false;
  }

  static AnalyticsSink? _sink;
  static AnalyticsSink? _installed;
  static bool _reportedMissing = false;
  static bool _reportedNoTelemetry = false;
}
