import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

import 'adapter.dart';
import 'inbound.dart';

/// The adapters of `fespalier: adapters:`, in the pubspec's order, as one (since 0.11.0). What
/// the generated `AppAdapters` (in `lib/app.g.dart`) forwards to, whatever `fespalier: main:` says:
/// the generated `main()` calls it, and so does the `main()` of an app with `main: manual`.
///
/// The first adapter is the outermost: its zone and its wrapper go around the others'. Sync stays
/// sync: a [beforeRun] where no adapter has anything to wait for returns null, and creates no
/// `Future` and no microtask. No timer.
final class FespalierAdapters {
  /// The adapters, in the pubspec's order.
  FespalierAdapters(List<FespalierAdapter> adapters)
    : _adapters = List.unmodifiable(adapters);

  final List<FespalierAdapter> _adapters;

  /// Routers the adapters were attached to: each router once.
  final Expando<bool> _attached = Expando<bool>('FespalierAdapters.attach');

  /// Runs [body] inside every adapter's `zone`, the first one's outermost:
  /// `a0.zone(() => a1.zone(body))`.
  Future<void> zone(Future<void> Function() body) {
    var run = body;
    for (final adapter in _adapters.reversed) {
      final inner = run;
      run = () => adapter.zone(inner);
    }
    return run();
  }

  /// Each adapter's `beforeRun()`, one after the other (the next is called when the one before
  /// it completed). Null when none has anything to wait for.
  Future<void>? beforeRun() => _beforeRun(0);

  Future<void>? _beforeRun(int from) {
    for (var i = from; i < _adapters.length; i++) {
      final ready = _adapters[i].beforeRun();
      if (ready != null) {
        return ready.then<void>((_) => _beforeRun(i + 1));
      }
    }
    return null;
  }

  /// The `ProviderScope`'s overrides: each adapter's, in order.
  List<Override> overrides() => [for (final a in _adapters) ...a.overrides()];

  /// The `ProviderScope`'s observers: each adapter's, in order.
  List<ProviderObserver> providerObservers() => [
    for (final a in _adapters) ...a.providerObservers(),
  ];

  /// The router's observers: each adapter's, in order (new ones on each call).
  List<NavigatorObserver> routerObservers() => [
    for (final a in _adapters) ...a.routerObservers(),
  ];

  /// Wraps [root] in every adapter's `wrap`, the first one's outermost: `a0.wrap(a1.wrap(root))`.
  Widget wrap(Widget root) {
    var wrapped = root;
    for (final adapter in _adapters.reversed) {
      wrapped = adapter.wrap(wrapped);
    }
    return wrapped;
  }

  /// Calls each adapter's `attach`, in order, once per [router]: a second call with the same
  /// router does nothing. An adapter that throws is reported (`FlutterError.reportError`) and
  /// the others still run.
  void attach(GoRouter router, ProviderContainer container) {
    if (_attached[router] ?? false) return;
    _attached[router] = true;
    for (final adapter in _adapters) {
      try {
        adapter.attach(router, container);
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'fespalier',
            context: ErrorDescription(
              'while attaching ${adapter.runtimeType} to the router',
            ),
          ),
        );
      }
    }
  }

  /// Where the app was opened from: every adapter's `launch()` is asked once, in order, and the
  /// first non-null answer wins (null when none has one, and always null on the web). Sync when
  /// every answer is, a `Future` from the first one that is. An adapter that throws is reported and
  /// the others still run.
  FutureOr<InboundLaunch?> launch() {
    if (inboundIsWeb) return null;
    return _launchFrom(0, null);
  }

  FutureOr<InboundLaunch?> _launchFrom(int from, InboundLaunch? found) {
    for (var i = from; i < _adapters.length; i++) {
      final adapter = _adapters[i];
      try {
        final answer = adapter.launch();
        if (answer is Future<InboundLaunch?>) {
          final next = i + 1;
          return answer.then<InboundLaunch?>(
            (launch) => _launchFrom(next, found ?? launch),
            onError: (Object error, StackTrace stackTrace) {
              _report(
                error,
                stackTrace,
                'while asking $adapter for the launch',
              );
              return _launchFrom(next, found);
            },
          );
        }
        found ??= answer;
      } catch (error, stackTrace) {
        _report(error, stackTrace, 'while asking $adapter for the launch');
      }
    }
    return found;
  }

  /// Routers `onEnter` has seen: the first navigation of each is the initial one.
  final Expando<bool> _entered = Expando<bool>('FespalierAdapters.onEnter');

  /// go_router's `onEnter` (`AppRoutes.onEnter`): each adapter's `onEnter`, in order. The first
  /// `Block` wins and is returned as it is (the `then`s of the `Allow`s before it are dropped: the
  /// navigation did not happen); otherwise the `Allow.then` callbacks are run in order as one
  /// `Allow(then:)`, and when no adapter has a say the answer is `Allow()`. Sync stays sync: a
  /// `Future` appears only if an adapter's answer is one. Blocking the initial navigation is
  /// refused (allowed, and reported in debug). An adapter that throws is reported and counts as
  /// no say.
  FutureOr<OnEnterResult> onEnter(
    BuildContext context,
    GoRouterState current,
    GoRouterState next,
    GoRouter router,
  ) {
    final initial = !(_entered[router] ?? false);
    _entered[router] = true;
    final navigation = InboundNavigation(
      context: context,
      current: current,
      next: next,
      router: router,
      initial: initial,
      source: takePlatformLink(next.uri),
    );
    return _enter(navigation, 0, const []);
  }

  FutureOr<OnEnterResult> _enter(
    InboundNavigation navigation,
    int from,
    List<OnEnterThenCallback> thens,
  ) {
    for (var i = from; i < _adapters.length; i++) {
      final adapter = _adapters[i];
      final FutureOr<OnEnterResult>? answer;
      try {
        answer = adapter.onEnter(navigation);
      } catch (error, stackTrace) {
        _report(error, stackTrace, 'in $adapter.onEnter');
        continue;
      }
      if (answer == null) continue;
      if (answer is Future<OnEnterResult>) {
        final next = i + 1;
        return answer.then<OnEnterResult>(
          (result) {
            final done = _take(navigation, result, thens);
            return done ?? _enter(navigation, next, [...thens, ?result.then]);
          },
          onError: (Object error, StackTrace stackTrace) {
            _report(error, stackTrace, 'in $adapter.onEnter');
            return _enter(navigation, next, thens);
          },
        );
      }
      final done = _take(navigation, answer, thens);
      if (done != null) return done;
      if (answer.then != null) thens = [...thens, answer.then!];
    }
    return thens.isEmpty ? const Allow() : Allow(then: _runAll(thens));
  }

  /// The block that ends the composition, or null to go on (an `Allow`, or a refused block of
  /// the initial navigation).
  OnEnterResult? _take(
    InboundNavigation navigation,
    OnEnterResult result,
    List<OnEnterThenCallback> thens,
  ) {
    if (result is! Block) return null;
    if (!navigation.initial) return result;
    assert(() {
      _report(
        StateError(
          'an adapter blocked the initial navigation, which go_router answers '
          "with its error page; fespalier allowed it. Answer the adapter's "
          'launch() instead',
        ),
        StackTrace.current,
        'in onEnter',
      );
      return true;
    }());
    return null;
  }

  /// One callback that runs [thens] in order, each reported (not thrown) when it fails: sync
  /// while they are, a `Future` from the first that is.
  static OnEnterThenCallback _runAll(List<OnEnterThenCallback> thens) {
    FutureOr<void> run(int from) {
      for (var i = from; i < thens.length; i++) {
        try {
          final result = thens[i]();
          if (result is Future<void>) {
            final next = i + 1;
            return result.then<void>(
              (_) => run(next),
              onError: (Object error, StackTrace stackTrace) {
                _report(error, stackTrace, 'in an onEnter callback');
                return run(next);
              },
            );
          }
        } catch (error, stackTrace) {
          _report(error, stackTrace, 'in an onEnter callback');
        }
      }
    }

    return () => run(0);
  }

  static void _report(Object error, StackTrace stackTrace, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'fespalier',
        context: ErrorDescription(context),
      ),
    );
  }
}
