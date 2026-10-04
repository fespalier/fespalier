import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:sentry_flutter/sentry_flutter.dart';

/// What `tracing: true` needs to know about the Sentry SDK it runs on: read once from the hub's
/// options, at the first navigation.
final class HubReads {
  /// Describes the options.
  const HubReads({
    required this.stream,
    required this.tracingOn,
    required this.appStartOwnsFirstScreen,
  });

  /// `traceLifecycle` is `stream`: `startTransaction` does nothing in that mode, so this version
  /// makes no spans (errors and breadcrumbs are unaffected).
  final bool stream;

  /// Whether the SDK samples transactions at all (`tracesSampleRate` or `tracesSampler` is set).
  final bool tracingOn;

  /// Whether Sentry's own app-start transaction is the first screen's `ui.load` (Android and iOS,
  /// tracing on, `enableAutoPerformanceTracing` on, standalone app start off): a second one from
  /// fespalier for the same screen would be a duplicate.
  final bool appStartOwnsFirstScreen;
}

/// Reads [hub]'s options. A failure reading them costs the first-screen rule, never the sink: it
/// counts as "Sentry does not own the first screen".
///
/// `Hub.options` is `@internal`, and so is the alternative of asking the app for its options a
/// second time: Sentry's own `sentry_dio` reads it the same way.
HubReads readHub(Hub hub, {TargetPlatform? platform}) {
  try {
    platform ??= defaultTargetPlatform;
    // ignore: invalid_use_of_internal_member
    final options = hub.options;
    final stream = options.traceLifecycle == SentryTraceLifecycle.stream;
    final tracingOn = options.isTracingEnabled();
    var appStart = false;
    if (options is SentryFlutterOptions &&
        !kIsWeb &&
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS) &&
        tracingOn &&
        options.enableAutoPerformanceTracing) {
      // Read only, to avoid a second `ui.load` at a cold start.
      // ignore: experimental_member_use
      appStart = !options.enableStandaloneAppStartTracing;
    }
    return HubReads(
      stream: stream,
      tracingOn: tracingOn,
      appStartOwnsFirstScreen: appStart,
    );
  } catch (_) {
    return const HubReads(
      stream: false,
      tracingOn: true,
      appStartOwnsFirstScreen: false,
    );
  }
}
