/// The scope of one page instance (since 0.11.0): what an `observe.dart` `onEnter` can tie to
/// the page's life on a navigator, with [RouteScope.hold] and [RouteScope.onLeave].
///
/// Nothing here starts a timer, a microtask or a listener of its own: a scope is made when the
/// lifecycle watch sees the page enter, and ended by the same post-frame diff that runs the
/// `onLeave` hooks.
library;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter/widgets.dart' show ErrorDescription;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show ProviderListenable;

/// One page instance on a navigator, from the end of the frame that first shows it to the end
/// of the frame it is gone from every navigator (since 0.11.0).
///
/// An `observe.dart` `onEnter` takes it as `{required RouteScope scope}`. A page parked in a
/// tab is still on a navigator, so its scope stays; `/c/1` to `/c/2` is a new instance, a query
/// change is not. A page pushed twice is two instances.
///
/// ```dart
/// void onEnter(Ref ref, {required int id, required RouteScope scope}) {
///   scope.hold(OrderRoute.data(id));
///   final sub = ref.read(orderSocket).subscribe(id);
///   scope.onLeave(sub.cancel);
/// }
/// ```
abstract final class RouteScope {
  /// The page instance's identity, as [pageInstanceId] spells it.
  String get id;

  /// Where the page entered, query included.
  Uri get uri;

  /// Whether the page is still on a navigator: false once it left.
  bool get isActive;

  /// Keeps [provider] listened in the app's container until the page leaves, so an
  /// `autoDispose` provider (a route's `data`) is not disposed while the page is on a
  /// navigator, a parked tab included.
  ///
  /// Throws a [StateError] once the page has left.
  void hold(ProviderListenable<Object?> provider);

  /// Runs [callback] when the page leaves; callbacks run newest first, after the
  /// `observe.dart` `onLeave` hooks and before the held providers are released. A callback
  /// that throws is reported and the others still run.
  ///
  /// Throws a [StateError] once the page has left.
  void onLeave(void Function() callback);
}

/// The identity of the page instance [state] builds, the one [RouteScope.id] reports and the
/// route lifecycle diffs on: `'<pageKey>#<matchedLocation>'` for a page of the route tree, and
/// `'<pageKey>@<path>'` for a page pushed with `push` (go_router gives it a random page key,
/// where a tree page's key is its path template).
///
/// Query-only changes keep it; a different segment value changes it.
String pageInstanceId(GoRouterState state) =>
    instanceId(state.pageKey.value, state.matchedLocation, state.uri.path);

/// [pageInstanceId] from its parts: [pageKey], the [matchedLocation] of the page's own match
/// and the [path] it shows.
String instanceId(String pageKey, String matchedLocation, String path) =>
    pageKey.startsWith('/') ? '$pageKey#$matchedLocation' : '$pageKey@$path';

/// The [RouteScope] the lifecycle watch makes for a page that entered.
final class RouteScopeImpl implements RouteScope {
  /// A scope for the page [id] at [uri], whose providers live in [_container].
  RouteScopeImpl(this.id, this.uri, this._container);

  @override
  final String id;

  @override
  final Uri uri;

  final ProviderContainer _container;
  List<ProviderSubscription<Object?>>? _subscriptions;
  List<void Function()>? _callbacks;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void hold(ProviderListenable<Object?> provider) {
    _checkActive('hold');
    final sub = _container.listen<Object?>(
      provider,
      (_, _) {},
      onError: (_, _) {},
    );
    (_subscriptions ??= []).add(sub);
  }

  @override
  void onLeave(void Function() callback) {
    _checkActive('onLeave');
    (_callbacks ??= []).add(callback);
  }

  void _checkActive(String what) {
    if (_active) return;
    throw StateError(
      'RouteScope.$what() called after the page left: $id. Register in onEnter, while the '
      'page is on a navigator.',
    );
  }

  /// The page left: runs the `onLeave` callbacks newest first, then closes the held
  /// subscriptions. A callback that throws is reported; the rest still run.
  void end() {
    if (!_active) return;
    _active = false;
    final callbacks = _callbacks;
    final subscriptions = _subscriptions;
    _callbacks = null;
    _subscriptions = null;
    try {
      if (callbacks != null) {
        for (final callback in callbacks.reversed) {
          try {
            callback();
          } catch (e, st) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: e,
                stack: st,
                library: 'fespalier',
                context: ErrorDescription(
                  'while running a RouteScope.onLeave callback of $id',
                ),
              ),
            );
          }
        }
      }
    } finally {
      if (subscriptions != null) {
        for (final sub in subscriptions) {
          sub.close();
        }
      }
    }
  }
}
