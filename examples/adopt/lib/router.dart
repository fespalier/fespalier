import 'package:adopt/app.g.dart';
import 'package:adopt/boot_log.dart';
import 'package:adopt/legacy_routes.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// The router while the app is half moved: the routes nobody has moved, redirects from the URLs
/// that moved, and fespalier's tree under `/shop`.
///
/// lib/app/app.dart's `router()` returns this, so the generated main() builds it once, after
/// startup.dart's `ready()`. Tests ask for a router at a location.
GoRouter buildRouter({String initialLocation = '/'}) {
  bootLog.add('router');
  // mount() wants the host router's own navigator key (routes on the root navigator name it).
  final rootKey = GlobalKey<NavigatorState>();
  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: initialLocation,
    routes: [
      ...legacyRoutes(),
      ..._movedUrls(),
      ...AppRoutes.mount(at: '/shop', navigatorKey: rootKey),
    ],
    // Anything no route matches gets fespalier's nearest not_found.dart.
    errorBuilder: (context, state) => AppRoutes.notFound(state.uri),
  );
}

/// The URLs the old app had, forwarded to the typed routes that replace them, so links that
/// are out in the world (and legacy code that navigates by string) keep working.
List<RouteBase> _movedUrls() => [
  GoRoute(
    path: '/products',
    redirect: (context, state) => const ProductsRoute().location,
  ),
  GoRoute(
    path: '/products/:id',
    // `/products/abc` has no product to go to: no redirect, so it falls through to not-found,
    // as it did before the move.
    redirect: (context, state) {
      final id = int.tryParse(state.pathParameters['id']!);
      return id == null ? null : ProductRoute(id: id).location;
    },
    builder: (context, state) => AppRoutes.notFound(state.uri),
  ),
];
