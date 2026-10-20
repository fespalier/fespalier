/// A hot reload swaps in a regenerated route table (since 0.19.0), in a debug build only.
///
/// The generated `AppRoutes.router()` gives `GoRouter.routingConfig` a [RoutesReload]: go_router
/// reads its routes, its `onEnter` and its redirects from it, and listens to it. A hot reload
/// keeps the first value of every top-level and static `final`, so a route closure made before the
/// reload still runs the old code. The generated subclass overrides its methods instead, and an
/// instance method runs the code that is current, so after a reload it builds the routes again.
/// [reloadRoutes], which `StartupGate` calls on reassemble, does it when the generated file's
/// version changed and nothing the table keeps (a provider, a deferred library, a router setting)
/// changed too. Nothing here starts a timer, makes a frame or listens to anything outside a debug
/// build: in profile and release the table is go_router's own, built once.
library;

import 'package:flutter/foundation.dart'
    show
        ValueListenable,
        VoidCallback,
        debugPrint,
        kDebugMode,
        visibleForTesting;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'guards.dart' show routerErrorPage;

/// What `debugPrint` shows, once per regenerated version, when a hot reload finds a provider, a
/// deferred library or a router setting that a hot reload keeps changed in the regenerated file
/// (since 0.19.0). The app keeps its old routes until a hot restart.
@visibleForTesting
const keptChangedMessage =
    'fespalier: the regenerated routes change a provider, a deferred library or a router setting that a hot reload keeps, so the app keeps its old routes: hot restart (R) to use the new ones';

/// The routing config of a generated app's router, which a hot reload in a debug build replaces
/// (since 0.19.0).
///
/// The generated `AppRoutes.router()` passes a subclass of this to `GoRouter.routingConfig`
/// (`_AppRoutesReload`), together with [follow]. [value] is the routing config go_router uses now;
/// a hot reload that swaps the routes sets a new one and notifies go_router, which then matches
/// the current location again, through `onEnter` and the redirects, as it does for `refresh()`.
///
/// Its subclass is generated: an app never writes one. Each of [version], [kept] and [rebuild] is
/// read from the code that is running, so the reloaded class answers after a hot reload.
abstract class RoutesReload extends ValueListenable<RoutingConfig> {
  /// Starts from [config], the routing config the router was built with. In a debug build it also
  /// records the [version] and the [kept] fields of the code it runs, to compare with after a
  /// hot reload.
  RoutesReload(RoutingConfig config) : _config = config {
    if (kDebugMode) {
      _version = version;
      _kept = kept;
    }
  }

  RoutingConfig _config;
  String? _version;
  Map<String, String> _kept = const {};
  final List<VoidCallback>? _listeners = kDebugMode ? <VoidCallback>[] : null;

  /// The version of the generated file that runs now (its `_version`, a hash of the whole file).
  /// A hot reload that finds the same version swaps nothing.
  @protected
  String get version;

  /// The fields the generated file's routes keep (its `_kept`): a hash of each top-level and
  /// static `final`, and of the router's settings. A reload is refused when a name in both maps
  /// has another hash.
  @protected
  Map<String, String> get kept;

  /// The routes again, built by the code that runs now, for [router]. Called only after a hot
  /// reload whose version changed and whose [kept] fields did not.
  @protected
  RoutingConfig rebuild(GoRouter router);

  /// The page for a location that matches no route: [errorPage] shows it for a location that
  /// matches no route, so a route removed by a hot reload shows the app's not-found page.
  Widget notFound(Uri uri);

  /// The page for go_router's error route (since 0.21.0): the generated `errorBuilder` calls it
  /// (`routing.errorPage(context, state)`), and the generated subclass answers with
  /// `AppRoutes.errorPage`, so a hot reload runs the code just reloaded. This default, which a
  /// subclass generated before 0.21.0 inherits (its `errorBuilder` calls [notFound] itself), is
  /// [routerErrorPage] with [notFound] alone.
  Widget errorPage(BuildContext context, GoRouterState state) =>
      routerErrorPage(context, state, notFound);

  /// Makes [router] follow this table: a hot reload swaps the routes of [router] when it is
  /// called from `reloadRoutes`. Called once, right after the router is made. In a profile or
  /// release build it does nothing.
  void follow(GoRouter router) {
    if (kDebugMode) _tables[router] = this;
  }

  @override
  RoutingConfig get value => _config;

  @override
  void addListener(VoidCallback listener) => _listeners?.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners?.remove(listener);

  void _reassembled(GoRouter router) {
    final now = version;
    if (now == _version) return;
    final next = kept;
    if (_kept.entries.any(
      (e) => next[e.key] != null && next[e.key] != e.value,
    )) {
      // A refusal is final for this version: it is said once, and the same version says nothing.
      _version = now;
      debugPrint(keptChangedMessage);
      return;
    }
    final RoutingConfig config;
    try {
      config = rebuild(router);
    } catch (error, stack) {
      // The version stays the one in use, so the next hot reload tries these routes again.
      _report(
        error,
        stack,
        'while building the routes again after a hot reload',
      );
      return;
    }
    _version = now;
    _config = config;
    _kept = next;
    for (final listener in List<VoidCallback>.of(_listeners ?? const [])) {
      try {
        listener();
      } catch (error, stack) {
        _report(
          error,
          stack,
          'while go_router took the routes of a hot reload',
        );
      }
    }
  }
}

/// The table each router [RoutesReload.follow] has been given (since 0.19.0), by router. Keyed by
/// the router, so a router that nothing follows is left alone.
final Expando<RoutesReload> _tables = Expando<RoutesReload>('fespalier routes');

/// Swaps in the regenerated routes of [router], when it follows a [RoutesReload] (since 0.19.0).
/// `StartupGate` calls it on every hot reload; a router that follows no table is left alone. Does
/// nothing outside a debug build.
void reloadRoutes(GoRouter router) {
  if (!kDebugMode) return;
  _tables[router]?._reassembled(router);
}

/// The keys of the layouts' navigators and shells of one `AppRoutes.mount()`, by restoration id
/// (since 0.19.0).
///
/// A layout made without a key gets a fresh one each time its route is made, and a fresh key
/// rebuilds the layout's navigator and everything in it. The generated routes take their keys from
/// one [ShellKeys] per mount, so a hot reload that makes the routes again reuses them: the pages
/// in a layout keep their state.
final class ShellKeys {
  final _navigators = <String, GlobalKey<NavigatorState>>{};
  final _shells = <String, GlobalKey<StatefulNavigationShellState>>{};

  /// The key of the navigator of the layout or branch with restoration id [id].
  GlobalKey<NavigatorState> navigator(String id) =>
      _navigators[id] ??= GlobalKey<NavigatorState>(debugLabel: id);

  /// The key of the stateful shell of the layout with restoration id [id].
  GlobalKey<StatefulNavigationShellState> shell(String id) =>
      _shells[id] ??= GlobalKey<StatefulNavigationShellState>(debugLabel: id);
}

void _report(Object error, StackTrace stack, String what) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'fespalier',
      context: ErrorDescription(what),
    ),
  );
}
