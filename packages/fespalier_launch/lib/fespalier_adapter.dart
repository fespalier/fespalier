/// The adapter `fespalier: adapters: [fespalier_launch]` lists (since 0.18.0). Configure the
/// package first: `FespalierLaunch.configure(sources: ..., route: ...)` in `main()`.
library;

import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show FespalierAdapter, InboundLaunch;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'src/action.dart';
import 'src/configure.dart';
import 'src/route.dart';
import 'src/source.dart';
import 'src/telemetry.dart';

/// What the generated `AppAdapters` forwards to.
const adapter = LaunchAdapter();

final Expando<bool> _attached = Expando<bool>('fespalier_launch');

/// Cold start through [launch], warm actions through [attach].
final class LaunchAdapter extends FespalierAdapter {
  /// Constant, like every adapter.
  const LaunchAdapter();

  @override
  FutureOr<InboundLaunch?> launch() {
    final config = FespalierLaunch.configured();
    if (config == null) return null;
    // Before the reads: an action the stream says while one of them is awaited is kept too.
    _holdActions(config);
    final answers = <FutureOr<LaunchAction?>>[
      for (final source in config.sources) _initial(source),
    ];
    if (answers.any((answer) => answer is Future<LaunchAction?>)) {
      return Future.wait<LaunchAction?>([
        for (final answer in answers) Future<LaunchAction?>.value(answer),
      ]).then((actions) => _cold(config, _first(actions)));
    }
    return _cold(config, _first(answers.cast<LaunchAction?>()));
  }

  /// The first source's answer, asked of each source (a source that throws is reported and counts
  /// as null). Sync when the sources are.
  FutureOr<LaunchAction?> _initial(LaunchSource source) {
    try {
      final answer = source.initialAction();
      if (answer is Future<LaunchAction?>) {
        return answer.then<LaunchAction?>(
          (action) => action,
          onError: (Object error, StackTrace stack) {
            _report(error, stack, 'reading the action that opened the app');
            return null;
          },
        );
      }
      return answer;
    } catch (error, stack) {
      _report(error, stack, 'reading the action that opened the app');
      return null;
    }
  }

  InboundLaunch? _cold(LaunchConfig config, LaunchAction? action) {
    if (action == null) return null;
    launchColdAction = action;
    final token = _begin(FespalierLaunchConventions.cold, action);
    final target = _map(config, action);
    _finish(token, routed: target != null);
    if (target == null) return null;
    return InboundLaunch(
      target.location,
      source: action.source,
      extra: target.extra,
    );
  }

  @override
  void attach(GoRouter router, ProviderContainer container) {
    final config = FespalierLaunch.configured();
    if (config == null) return;
    // One subscription per container, as fespalier_push: a second router on the same container
    // (a test, a rebuilt router) does not open every action twice. Actions go to the first router.
    if (_attached[container] != null) return;
    _attached[container] = true;
    var cold = launchColdAction;
    launchColdAction = null;
    void open(LaunchAction action, {required bool held}) {
      if (held && cold != null && action == cold) {
        // The cold-start action said again during startup: once.
        cold = null;
        return;
      }
      _warm(router, config, action);
    }

    for (final source in config.sources) {
      container.listen<AsyncValue<_Event>>(_events(source), (previous, next) {
        switch (next) {
          case AsyncError(:final error, :final stackTrace):
            // Not `next.value`: it keeps the previous action, and an error would open it again.
            _report(error, stackTrace, 'in the stream of launch actions');
          case AsyncData(:final value):
            if (identical(previous?.value, value)) return;
            open(value.action, held: false);
          case AsyncLoading():
            break;
        }
      });
    }
    // The subscriptions are made: the hold (since launch()) can end without a gap, and what it kept
    // is opened now, once the rest of the adapter is attached.
    final kept = launchHold.end();
    if (kept != null) open(kept, held: true);
  }

  void _warm(GoRouter router, LaunchConfig config, LaunchAction action) {
    final token = _begin(FespalierLaunchConventions.warm, action);
    final target = _map(config, action);
    Object? failure;
    if (target != null) {
      try {
        navigateFrom<void>(action.source, () {
          switch (target.open) {
            case LaunchOpen.go:
              router.go(target.location, extra: target.extra);
            case LaunchOpen.push:
              unawaited(
                router
                    .push<Object?>(target.location, extra: target.extra)
                    .then<void>((_) {}, onError: (_) {}),
              );
          }
        });
      } catch (error, stack) {
        failure = StateError('fespalier_launch: the navigation failed');
        _report(error, stack, 'opening the action');
      }
    }
    _finish(token, routed: target != null && failure == null, error: failure);
  }

  LaunchTarget? _map(LaunchConfig config, LaunchAction action) {
    try {
      return config.route(action);
    } catch (error, stack) {
      _report(error, stack, 'mapping the action to a route');
      return null;
    }
  }

  Object? _begin(String state, LaunchAction action) => FespalierTelemetry.begin(
    TelemetryStart(
      TelemetryOp.custom,
      name: FespalierLaunchConventions.open,
      attributes: {
        FespalierLaunchConventions.state: state,
        FespalierLaunchConventions.kind: action.source,
      },
    ),
  );

  void _finish(Object? token, {required bool routed, Object? error}) =>
      FespalierTelemetry.finish(
        token,
        TelemetryEnd(
          error == null ? TelemetryOutcome.ok : TelemetryOutcome.error,
          error: error,
          attributes: {FespalierLaunchConventions.routed: routed},
        ),
      );
}

/// One action, wrapped so that two actions of the same object are two events.
final class _Event {
  const _Event(this.action);
  final LaunchAction action;
}

/// One stream per source, as a provider keyed by the source object (identity). A source that
/// fails is an `AsyncError` and is never retried: Riverpod's retry would be a `Timer`.
final _events = StreamProvider.family<_Event, LaunchSource>(
  (ref, source) => source.actions.map(_Event.new),
  retry: (_, _) => null,
);

/// Listens to every source's `actions` from `launch()` on, in a container of its own, and keeps the
/// latest action across them (since 0.18.0): `attach` ends it. The subscriptions are a provider
/// container's, so they go when it is disposed, which `attach`, a new `configure` and `debugReset`
/// all do.
void _holdActions(LaunchConfig config) {
  launchHold.end();
  try {
    final container = ProviderContainer();
    launchHold.container = container;
    for (final source in config.sources) {
      container.listen<AsyncValue<_Event>>(_events(source), (previous, next) {
        switch (next) {
          case AsyncError(:final error, :final stackTrace):
            _report(error, stackTrace, 'in the stream of launch actions');
          case AsyncData(:final value):
            if (!identical(previous?.value, value)) {
              launchHold.held = value.action;
            }
          case AsyncLoading():
            break;
        }
      }, fireImmediately: true);
    }
  } catch (error, stack) {
    _report(error, stack, 'in the stream of launch actions');
    launchHold.end();
  }
}

/// The first non-null answer, in the sources' order.
LaunchAction? _first(Iterable<LaunchAction?> actions) {
  for (final action in actions) {
    if (action != null) return action;
  }
  return null;
}

void _report(Object error, StackTrace stack, String doing) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier_launch',
      context: ErrorDescription(doing),
    ),
  );
}
