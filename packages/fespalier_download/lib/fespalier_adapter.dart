/// The adapter `fespalier: adapters: [fespalier_download]` lists (since 0.15.0). Configure the
/// package first: `FespalierDownload.configure(backend: ..., store: ...)` in `main()`.
library;

import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart'
    show FespalierAdapter, InboundLaunch, Override;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/configure.dart';
import 'src/providers.dart';
import 'src/tap.dart';
import 'src/telemetry.dart';

/// What the generated `AppAdapters` forwards to.
const adapter = DownloadAdapter();

final Expando<bool> _attached = Expando<bool>('fespalier_download');

/// Binds the configured engine to `downloadsEngine`; a notification tap that cold-starts the app
/// is the router's initial location (through [launch]), and one while the app runs or sits in
/// the background is a navigation (through [attach]).
///
/// The engine's one tap slot (`Downloads.observeTaps`) is the adapter's: it holds no Riverpod
/// listener, timer or stream of its own.
final class DownloadAdapter extends FespalierAdapter {
  /// Constant, like every adapter.
  const DownloadAdapter();

  @override
  List<Override> overrides() {
    final config = FespalierDownload.configured();
    return config == null
        ? const []
        : [downloadsEngine.overrideWithValue(config.engine)];
  }

  /// Opens the engine (the backend's replay of a tap the app was started by arrives while it
  /// opens) and answers that tap as the initial location. The first frame waits for the open,
  /// which is the registry file and the backend's own start. A backend that cannot open is
  /// reported and the app starts without a launch.
  @override
  FutureOr<InboundLaunch?> launch() {
    final config = FespalierDownload.configured();
    if (config == null) return null;
    config.engine.observeTaps(config.pending.add);
    return _open(config).then<InboundLaunch?>((_) => _cold(config));
  }

  @override
  void attach(GoRouter router, ProviderContainer container) {
    final config = FespalierDownload.configured();
    if (config == null) return;
    // One owner of the tap slot per container: a second router on the same container (a test, a
    // rebuilt router) does not open every tap twice. Taps go to the first router.
    if (_attached[container] != null) return;
    _attached[container] = true;
    config.engine.observeTaps((tap) => _warm(router, config, tap));
    // What arrived between `launch` and now (and a second cold tap), oldest first.
    final late = List.of(config.pending);
    config.pending.clear();
    for (final tap in late) {
      _warm(router, config, tap);
    }
    // An app that did not run `launch` (main: manual without it) opens here; open() is once.
    unawaited(_open(config));
  }

  /// Opens the engine and hands the backend its notification texts, once. Never throws.
  Future<void> _open(DownloadConfig config) async {
    try {
      await config.engine.open();
      final texts = config.notifications;
      if (texts != null && !config.notificationsSet) {
        config.notificationsSet = true;
        await config.backend.configureNotifications(texts);
      }
    } catch (error, stack) {
      _report(error, stack, 'opening the downloads');
    }
  }

  InboundLaunch? _cold(DownloadConfig config) {
    if (config.pending.isEmpty) return null;
    final tap = config.pending.removeAt(0);
    config.coldTap = (tap.id, tap.kind);
    final token = _begin();
    final target = _map(config, tap);
    _finish(token, routed: target != null);
    if (target == null) return null;
    return InboundLaunch(
      target.location,
      source: NavigationSource.notification,
      extra: target.extra,
    );
  }

  void _warm(GoRouter router, DownloadConfig config, DownloadTap tap) {
    if (config.coldTap == (tap.id, tap.kind)) {
      // The cold-start notification seen again once the engine is up: once.
      config.coldTap = null;
      return;
    }
    final token = _begin();
    final target = _map(config, tap);
    Object? failure;
    if (target != null) {
      try {
        navigateFrom<void>(NavigationSource.notification, () {
          switch (target.open) {
            case DownloadOpen.go:
              router.go(target.location, extra: target.extra);
            case DownloadOpen.push:
              unawaited(
                router
                    .push<Object?>(target.location, extra: target.extra)
                    .then<void>((_) {}, onError: (_) {}),
              );
          }
        });
      } catch (error, stack) {
        failure = StateError('fespalier_download: the navigation failed');
        _report(error, stack, 'opening the notification');
      }
    }
    _finish(token, routed: target != null && failure == null, error: failure);
  }

  DownloadTarget? _map(DownloadConfig config, DownloadTap tap) {
    final route = config.route;
    if (route == null) return null;
    try {
      return route(tap);
    } catch (error, stack) {
      _report(error, stack, 'mapping the notification to a route');
      return null;
    }
  }

  Object? _begin() => FespalierTelemetry.begin(
    const TelemetryStart(
      TelemetryOp.custom,
      name: FespalierDownloadConventions.open,
    ),
  );

  void _finish(Object? token, {required bool routed, Object? error}) =>
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          error == null ? TelemetryOutcome.ok : TelemetryOutcome.error,
          error: error,
          attributes: {FespalierDownloadConventions.routed: routed},
        ),
      );
}

void _report(Object error, StackTrace stack, String doing) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier_download',
      context: ErrorDescription(doing),
    ),
  );
}
