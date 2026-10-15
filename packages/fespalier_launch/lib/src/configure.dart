import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'action.dart';
import 'route.dart';
import 'source.dart';

/// The action that cold-started the app, so the same action seen again on `actions` during startup
/// is dropped once. Internal: `lib/src` is not exported.
LaunchAction? launchColdAction;

/// The actions that arrive while the app starts (since 0.18.0). `launch()` runs before `runApp` and
/// `attach` after the router is shown, and a source's `actions` is a broadcast stream: an action in
/// between has no listener. `launch()` listens to every source in a private container
/// ([container]) and keeps the latest action across them ([held], one and never a queue: the newest
/// replaces the one before); `attach` subscribes the app's container first, then ends the hold,
/// which disposes the private container and so its subscriptions, and opens what was kept.
/// Internal: `lib/src` is not exported.
final class LaunchHold {
  /// The private container that holds the subscriptions; null when no hold is running.
  ProviderContainer? container;

  /// The latest action seen since the hold started, from any source.
  LaunchAction? held;

  /// Ends the hold: disposes its container (and with it the subscriptions) and answers the latest
  /// action it kept, or null.
  LaunchAction? end() {
    final owned = container;
    container = null;
    final action = held;
    held = null;
    owned?.dispose();
    return action;
  }
}

/// The one hold of the process, started by `LaunchAdapter.launch` and ended by `attach`.
final LaunchHold launchHold = LaunchHold();

/// What `FespalierLaunch.configure` stored.
final class LaunchConfig {
  /// Made by [FespalierLaunch.configure].
  const LaunchConfig(this.sources, this.route);

  /// The sources, de-duplicated by identity, in the order the app listed them.
  final List<LaunchSource> sources;

  /// The action-to-place mapping.
  final LaunchRoute route;
}

/// Configures fespalier_launch before the adapters run (since 0.18.0). The adapter in
/// `fespalier_adapter.dart` cannot be handed options by the pubspec, and `launch()` runs before any
/// `ProviderScope` exists, so the app's `main()` calls this first:
///
/// ```dart
/// Future<void> main() {
///   FespalierLaunch.configure(sources: [quickActions, homeWidget], route: launchRoute);
///   return AppMain.run();
/// }
/// ```
///
/// Calling it twice replaces (a hot restart runs `main()` again). An empty list is allowed: nothing
/// opens. The package never calls the vendor plugins: what the home screen shows is the app's.
abstract final class FespalierLaunch {
  /// Stores the sources and the mapping. Two equal sources are one.
  static void configure({
    required List<LaunchSource> sources,
    required LaunchRoute route,
  }) {
    // A hold listens to the sources it was started for: a new configuration starts over at launch().
    launchHold.end();
    _config = LaunchConfig(
      List.unmodifiable(<LaunchSource>{...sources}),
      route,
    );
    _reported = false;
  }

  /// Forgets what [configure] stored, for a test that sets up its own.
  @visibleForTesting
  static void debugReset() {
    launchHold.end();
    _config = null;
    _reported = false;
    launchColdAction = null;
  }

  static LaunchConfig? _config;
  static bool _reported = false;

  /// What [configure] stored. When there is none, reports it once (a `FlutterError`) and answers
  /// null: the adapter does nothing and never throws out of `launch` or `attach`.
  static LaunchConfig? configured() {
    final config = _config;
    if (config == null && !_reported) {
      _reported = true;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError(
            'fespalier_launch is listed under `fespalier: adapters:` but was never configured: '
            'call FespalierLaunch.configure(sources: [...], route: ...) in main() before '
            'AppMain.run()',
          ),
          library: 'fespalier_launch',
        ),
      );
    }
    return config;
  }
}
