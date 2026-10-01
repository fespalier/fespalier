import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart' hide RouteMatch;

import 'location.dart';
import 'route_match.dart';

/// The location of the route [state] belongs to, as `XRoute.of(context)` reads it.
///
/// For a page (a `GoRoute`, pushed or not) it is the part of the URL its route
/// matched, with the URL's query: the products page under `/products/42?ref=mail`
/// is at `/products?ref=mail`, so a page further down the stack still reads its
/// own route. For a layout (a shell route) it is the whole location, the route
/// it shows. The mount point and a localized spelling are left as they are: the
/// generated matchers take them off.
Uri routeLocation(GoRouterState state) {
  // A shell's state (and the error page's) has no path of its own.
  if (state.path == null) return state.uri;
  // The common case: the route matched the whole path, so there is nothing to cut.
  if (state.matchedLocation == state.uri.path) return state.uri;
  return state.uri.replace(path: state.matchedLocation);
}

/// What a generated `XRoute.maybeOf(context)` calls: the typed route at the
/// location of the route around [context] (see [routeLocation]), parsed by
/// [match] (`AppRoutes.matchUrl`), when it is a [T]. Null when it is another
/// route, when the location matches none, or when [context] is under no
/// go_router route at all.
///
/// The widget that calls it rebuilds when that location changes, as with
/// `GoRouterState.of(context)`.
T? maybeRouteOf<T extends TypedLocation>(
  BuildContext context,
  UrlMatch? Function(Uri uri) match,
) {
  final GoRouterState state;
  try {
    state = GoRouterState.of(context);
  } on GoError {
    return null;
  }
  final route = match(routeLocation(state))?.route;
  return route is T ? route : null;
}

/// What a generated `XRoute.of(context)` calls: [maybeRouteOf], which throws a
/// [StateError] naming the location when the route around [context] is not a
/// [T] (and go_router's `GoError` when [context] is under no route at all).
T routeOf<T extends TypedLocation>(
  BuildContext context,
  UrlMatch? Function(Uri uri) match,
) {
  final at = routeLocation(GoRouterState.of(context));
  final route = match(at)?.route;
  if (route is T) return route;
  final what = route == null ? 'no route' : 'a ${route.runtimeType}';
  throw StateError(
    '$T.of(context): the route around this context is at $at, which is $what. '
    'Use $T.maybeOf(context) in a widget that can be shown elsewhere.',
  );
}
