import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show Override;

import 'adapter.dart';

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
}
