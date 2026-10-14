import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'message.dart';
import 'route.dart';
import 'source.dart';
import 'token.dart';

/// The message id that cold-started the app, so the same tap seen again on `taps` is dropped
/// once. Internal: `lib/src` is not exported.
String? pushColdStartId;

/// The message that cold-started the app, for a source that gives no id: a tap held during startup
/// with the same payload is that notification again. Internal, like [pushColdStartId].
PushMessage? pushColdStartMessage;

/// The taps that arrive while the app starts (since 0.16.0). `launch()` runs before `runApp` and
/// `attach` after the router is shown, and `taps` is a broadcast stream: a tap in between has no
/// listener. `launch()` listens to `taps` in a private container ([container]) and keeps the
/// latest one ([held], one and never a queue: the newest replaces the one before); `attach`
/// subscribes the app's container first, then ends the hold, which disposes the private container
/// and so its subscription, and opens what was kept. Internal: `lib/src` is not exported.
final class PushTapHold {
  /// The private container that holds the subscription; null when no hold is running.
  ProviderContainer? container;

  /// The latest tap seen since the hold started.
  PushMessage? held;

  /// Ends the hold: disposes its container (and with it the subscription to `taps`) and answers the
  /// latest tap it kept, or null.
  PushMessage? end() {
    final owned = container;
    container = null;
    final tap = held;
    held = null;
    owned?.dispose();
    return tap;
  }
}

/// The one hold of the process, started by `PushAdapter.launch` and ended by `attach`.
final PushTapHold pushTapHold = PushTapHold();

/// What `FespalierPush.configure` stored.
final class PushConfig {
  /// Made by [FespalierPush.configure].
  const PushConfig(this.source, this.route, this.onToken, this.onTokenRevoked);

  /// The push provider.
  final PushSource source;

  /// The payload-to-place mapping.
  final PushRoute route;

  /// The app's token callback; null when it reads `pushToken` itself.
  final void Function(PushToken token)? onToken;

  /// The app's revocation callback (since 0.14.0); null when it reads `pushTokenRevoked` itself.
  final void Function(PushTokenRevoked revoked)? onTokenRevoked;
}

/// Configures fespalier_push before the adapters run (since 0.13.0). The adapter in
/// `fespalier_adapter.dart` cannot be handed options by the pubspec, and `launch()` runs before
/// any `ProviderScope` exists, so the app's `main()` calls this first:
///
/// ```dart
/// Future<void> main() {
///   FespalierPush.configure(source: MyPushSource(), route: pushRoute, onToken: sendToBackend,
///     onTokenRevoked: dropFromBackend);
///   return AppMain.run();
/// }
/// ```
///
/// Calling it twice replaces (a hot restart runs `main()` again). The package never posts the
/// token anywhere: it has no HTTP code, and [onToken] and [onTokenRevoked] are the app's. The
/// callbacks take a [PushToken] and a [PushTokenRevoked] since 0.14.0 (they took a `String`).
abstract final class FespalierPush {
  /// Stores the push provider, the mapping and the optional token callback.
  static void configure({
    required PushSource source,
    required PushRoute route,
    void Function(PushToken token)? onToken,
    void Function(PushTokenRevoked revoked)? onTokenRevoked,
  }) {
    // A hold listens to the source it was started for: a new source starts over at launch().
    pushTapHold.end();
    _config = PushConfig(source, route, onToken, onTokenRevoked);
    _reported = false;
  }

  /// Forgets what [configure] stored, for a test that sets up its own.
  @visibleForTesting
  static void debugReset() {
    pushTapHold.end();
    _config = null;
    _reported = false;
    pushColdStartId = null;
    pushColdStartMessage = null;
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
