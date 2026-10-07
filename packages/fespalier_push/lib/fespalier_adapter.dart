/// The adapter `fespalier: adapters: [fespalier_push]` lists (since 0.13.0). Configure the
/// package first: `FespalierPush.configure(source: ..., route: ...)` in `main()`.
library;

import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart'
    show FespalierAdapter, InboundLaunch, Override;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/configure.dart';
import 'src/message.dart';
import 'src/providers.dart';
import 'src/route.dart';
import 'src/telemetry.dart';

/// What the generated `AppAdapters` forwards to.
const adapter = PushAdapter();

/// Cold start through [launch], warm taps and tokens through [attach].
final class PushAdapter extends FespalierAdapter {
  /// Constant, like every adapter.
  const PushAdapter();

  @override
  List<Override> overrides() {
    final config = FespalierPush.configured();
    return config == null
        ? const []
        : [pushSource.overrideWithValue(config.source)];
  }

  @override
  FutureOr<InboundLaunch?> launch() {
    final config = FespalierPush.configured();
    if (config == null) return null;
    try {
      final tap = config.source.initialTap();
      if (tap is Future<PushMessage?>) {
        return tap.then(
          (message) => _cold(config, message),
          onError: (Object error, StackTrace stack) {
            _report(
              error,
              stack,
              'reading the notification that opened the app',
            );
            return null;
          },
        );
      }
      return _cold(config, tap);
    } catch (error, stack) {
      _report(error, stack, 'reading the notification that opened the app');
      return null;
    }
  }

  InboundLaunch? _cold(PushConfig config, PushMessage? message) {
    if (message == null) return null;
    FespalierPush.coldStartId = message.id;
    final token = _begin(FespalierPushConventions.cold);
    final target = _map(config, message);
    _finish(token, routed: target != null);
    if (target == null) return null;
    return InboundLaunch(
      target.location,
      source: NavigationSource.notification,
      extra: target.extra,
    );
  }

  @override
  void attach(GoRouter router, ProviderContainer container) {
    final config = FespalierPush.configured();
    if (config == null) return;
    var last = FespalierPush.coldStartId;
    FespalierPush.coldStartId = null;
    container.listen<AsyncValue<_Tap>>(_taps, (previous, next) {
      final tap = next.value;
      if (tap == null) return;
      final id = tap.message.id;
      if (id != null && id == last) {
        // The same notification seen twice (a cold start also on `taps`): once.
        last = null;
        return;
      }
      last = id;
      _warm(router, config, tap.message);
    });
    final onToken = config.onToken;
    if (onToken != null) {
      container.listen<AsyncValue<String>>(pushToken, (previous, next) {
        final token = next.value;
        if (token == null) return;
        try {
          onToken(token);
        } catch (error, stack) {
          _report(error, stack, 'in the onToken callback');
        }
      }, fireImmediately: true);
    }
  }

  void _warm(GoRouter router, PushConfig config, PushMessage message) {
    final token = _begin(FespalierPushConventions.warm);
    final target = _map(config, message);
    Object? failure;
    if (target != null) {
      try {
        navigateFrom<void>(NavigationSource.notification, () {
          switch (target.open) {
            case PushOpen.go:
              router.go(target.location, extra: target.extra);
            case PushOpen.push:
              unawaited(
                router
                    .push<Object?>(target.location, extra: target.extra)
                    .then<void>((_) {}, onError: (_) {}),
              );
          }
        });
      } catch (error, stack) {
        failure = error;
        _report(error, stack, 'opening the notification');
      }
    }
    _finish(token, routed: target != null && failure == null, error: failure);
  }

  PushTarget? _map(PushConfig config, PushMessage message) {
    try {
      return config.route(message);
    } catch (error, stack) {
      _report(error, stack, 'mapping the notification to a route');
      return null;
    }
  }

  Object? _begin(String state) => FespalierTelemetry.begin(
    TelemetryStart(
      TelemetryOp.custom,
      name: FespalierPushConventions.open,
      attributes: {FespalierPushConventions.state: state},
    ),
  );

  void _finish(Object? token, {required bool routed, Object? error}) =>
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          error == null ? TelemetryOutcome.ok : TelemetryOutcome.error,
          error: error,
          attributes: {FespalierPushConventions.routed: routed},
        ),
      );
}

/// One tap, wrapped so that two taps of the same message object are two events.
final class _Tap {
  const _Tap(this.message);
  final PushMessage message;
}

final _taps = StreamProvider<_Tap>(
  (ref) => ref.watch(pushSource).taps.map(_Tap.new),
  retry: (_, _) => null,
);

void _report(Object error, StackTrace stack, String doing) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier_push',
      context: ErrorDescription(doing),
    ),
  );
}
