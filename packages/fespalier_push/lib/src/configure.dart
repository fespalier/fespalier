import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'route.dart';
import 'source.dart';

/// The message id that cold-started the app, so the same tap seen again on `taps` is dropped
/// once. Internal: `lib/src` is not exported.
String? pushColdStartId;

/// What `FespalierPush.configure` stored.
final class PushConfig {
  /// Made by [FespalierPush.configure].
  const PushConfig(this.source, this.route, this.onToken);

  /// The push provider.
  final PushSource source;

  /// The payload-to-place mapping.
  final PushRoute route;

  /// The app's token callback; null when it reads `pushToken` itself.
  final void Function(String token)? onToken;
}

/// Configures fespalier_push before the adapters run (since 0.13.0). The adapter in
/// `fespalier_adapter.dart` cannot be handed options by the pubspec, and `launch()` runs before
/// any `ProviderScope` exists, so the app's `main()` calls this first:
///
/// ```dart
/// Future<void> main() {
///   FespalierPush.configure(source: MyPushSource(), route: pushRoute, onToken: sendToBackend);
///   return AppMain.run();
/// }
/// ```
///
/// Calling it twice replaces (a hot restart runs `main()` again). The package never posts the
/// token anywhere: it has no HTTP code, and [onToken] is the app's.
abstract final class FespalierPush {
  /// Stores the push provider, the mapping and the optional token callback.
  static void configure({
    required PushSource source,
    required PushRoute route,
    void Function(String token)? onToken,
  }) {
    _config = PushConfig(source, route, onToken);
    _reported = false;
  }

  /// Forgets what [configure] stored, for a test that sets up its own.
  @visibleForTesting
  static void debugReset() {
    _config = null;
    _reported = false;
    pushColdStartId = null;
  }

  static PushConfig? _config;
  static bool _reported = false;

  /// What [configure] stored. When there is none, reports it once (a `FlutterError`) and answers
  /// null: the adapter does nothing and never throws out of `launch` or `attach`.
  static PushConfig? configured() {
    final config = _config;
    if (config == null && !_reported) {
      _reported = true;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError(
            'fespalier_push is listed under `fespalier: adapters:` but was never configured: '
            'call FespalierPush.configure(source: ..., route: ...) in main() before '
            'AppMain.run()',
          ),
          library: 'fespalier_push',
        ),
      );
    }
    return config;
  }
}
