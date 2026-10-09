import 'package:clock/clock.dart' show Clock;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'engine.dart';
import 'grant.dart';
import 'ports.dart';
import 'tap.dart';

/// What `FespalierDownload.configure` stored. Internal state of the adapter lives here too, so
/// a second `configure` (a hot restart) starts clean.
final class DownloadConfig {
  /// Made by [FespalierDownload.configure].
  DownloadConfig(this.engine, this.backend, this.notifications, this.route);

  /// The engine the adapter binds to `downloadsEngine`.
  final Downloads engine;

  /// The backend under [engine], told the [notifications] once the engine is open.
  final DownloadBackend backend;

  /// The notification texts, or null to leave notifications as the backend has them.
  final DownloadNotifications? notifications;

  /// The tap-to-place mapping; null: a tap opens the app and goes nowhere.
  final DownloadRoute? route;

  /// Taps heard before `attach` took the slot, oldest first. Internal.
  final List<DownloadTap> pending = [];

  /// The tap that cold-started the app (`id` and kind), so the same tap seen again as a warm tap
  /// is dropped once. Internal.
  (String, DownloadTapKind)? coldTap;

  /// Whether the notification texts were handed to the backend. Internal.
  bool notificationsSet = false;
}

/// Configures fespalier_download before the adapters run (since 0.15.0). The adapter in
/// `fespalier_adapter.dart` cannot be handed options by the pubspec, and `launch()` runs before
/// any `ProviderScope` exists, so the app's `main()` calls this first:
///
/// ```dart
/// Future<void> main() {
///   FespalierDownload.configure(
///     backend: BackgroundDownloaderBackend(),
///     store: FileDownloadStore(bases: bases),
///     notifications: const DownloadNotifications(running: 'Downloading'),
///     route: (tap) => switch (tap.request?.id) {
///       final id? when id.startsWith('manual-') => DownloadTarget.to(ManualRoute(id: id)),
///       _ => null,
///     },
///   );
///   return AppMain.run();
/// }
/// ```
///
/// It builds the `Downloads` engine and the adapter binds it to `downloadsEngine`, so the app's
/// `startup()` does not override that provider. Calling it twice replaces (a hot restart runs
/// `main()` again). The package never asks for the notification permission: the app does.
abstract final class FespalierDownload {
  /// Builds the engine over [backend] and [store] and stores the mapping from a notification tap
  /// to a place. [notifications] are handed to the backend once the engine is open; [files],
  /// [grantor] and [clock] go to the engine as `Downloads` takes them.
  static void configure({
    required DownloadBackend backend,
    required DownloadStore store,
    DownloadNotifications? notifications,
    DownloadRoute? route,
    DownloadFiles? files,
    DownloadGrantor? grantor,
    Clock? clock,
  }) {
    _config = DownloadConfig(
      Downloads(
        backend: backend,
        store: store,
        files: files,
        clock: clock,
        grantor: grantor,
      ),
      backend,
      notifications,
      route,
    );
    _reported = false;
  }

  /// Forgets what [configure] stored, for a test that sets up its own.
  @visibleForTesting
  static void debugReset() {
    _config = null;
    _reported = false;
  }

  static DownloadConfig? _config;
  static bool _reported = false;

  /// What [configure] stored. When there is none, reports it once (a `FlutterError`) and answers
  /// null: the adapter does nothing and never throws out of `launch` or `attach`.
  static DownloadConfig? configured() {
    final config = _config;
    if (config == null && !_reported) {
      _reported = true;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError(
            'fespalier_download is listed under `fespalier: adapters:` but was never configured: '
            'call FespalierDownload.configure(backend: ..., store: ...) in main() before '
            'AppMain.run()',
          ),
          library: 'fespalier_download',
        ),
      );
    }
    return config;
  }
}
