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
import 'src/token.dart';
import 'src/telemetry.dart';

/// What the generated `AppAdapters` forwards to.
const adapter = PushAdapter();

final Expando<bool> _attached = Expando<bool>('fespalier_push');

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
    pushColdStartId = message.id;
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
    // One subscription per container: a second router on the same container (a test, a rebuilt
    // router) does not open every tap twice. Taps go to the first router.
    if (_attached[container] != null) return;
    _attached[container] = true;
    var cold = pushColdStartId;
    pushColdStartId = null;
    container.listen<AsyncValue<_Tap>>(_taps, (previous, next) {
      switch (next) {
        case AsyncError(:final error, :final stackTrace):
          // Not `next.value`: it keeps the previous tap, and an error would open it again.
          _report(error, stackTrace, 'in the stream of notification taps');
        case AsyncData(:final value):
          if (identical(previous?.value, value)) return;
          final id = value.message.id;
          if (id != null && id == cold) {
            // The cold-start notification seen again on `taps`: once.
            cold = null;
            return;
          }
          _warm(router, config, value.message);
        case AsyncLoading():
          break;
      }
    });
    // The callbacks hear events, not state: the public providers hold the last value and Riverpod
    // drops a state equal to the previous one, so they are fed from private providers that wrap
    // each event in a fresh object. A token is told once per kind until that kind is revoked.
    final onToken = config.onToken;
    final onRevoked = config.onTokenRevoked;
    final last = <String, PushToken>{};
    if (onToken != null) {
      container.listen<AsyncValue<_TokenEvent>>(_tokenEvents, (previous, next) {
        switch (next) {
          case AsyncError(:final error, :final stackTrace):
            _report(error, stackTrace, 'in the stream of push tokens');
          case AsyncData(:final value):
            if (identical(previous?.value, value)) return;
            final token = value.token;
            if (last[token.kind] == token) return;
            last[token.kind] = token;
            try {
              onToken(token);
            } catch (error, stack) {
              _report(error, stack, 'in the onToken callback');
            }
          case AsyncLoading():
            break;
        }
      }, fireImmediately: true);
    }
    if (onRevoked != null || onToken != null) {
      // No fireImmediately: a revocation read before attach is stale, never replayed.
      container.listen<AsyncValue<_RevocationEvent>>(_revocationEvents, (
        previous,
        next,
      ) {
        switch (next) {
          case AsyncError(:final error, :final stackTrace):
            _report(
              error,
              stackTrace,
              'in the stream of push token revocations',
            );
          case AsyncData(:final value):
            if (identical(previous?.value, value)) return;
            last.remove(value.revoked.kind);
            if (onRevoked == null) return;
            try {
              onRevoked(value.revoked);
            } catch (error, stack) {
              _report(error, stack, 'in the onTokenRevoked callback');
            }
          case AsyncLoading():
            break;
        }
      });
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
        failure = StateError('fespalier_push: the navigation failed');
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

/// One token, wrapped so that an equal token delivered again is a new event.
final class _TokenEvent {
  const _TokenEvent(this.token);
  final PushToken token;
}

/// One revocation, wrapped like [_TokenEvent].
final class _RevocationEvent {
  const _RevocationEvent(this.revoked);
  final PushTokenRevoked revoked;
}

final _tokenEvents = StreamProvider<_TokenEvent>(
  (ref) => ref.watch(pushSource).tokens.map(_TokenEvent.new),
  retry: (_, _) => null,
);

final _revocationEvents = StreamProvider<_RevocationEvent>(
  (ref) => ref.watch(pushSource).revocations.map(_RevocationEvent.new),
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
