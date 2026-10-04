import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'platform_page.dart';
import 'transitions.dart';

/// When a page gets a fresh state because its URL changed.
///
/// go_router keys a page by its path template, so `/c/1` to `/c/2` is the same
/// page: its widgets are rebuilt with the new parameters but keep their state
/// (a scroll position, a text field, a hook's `useState`). Set `remount` in the
/// pubspec's `fespalier:` section for the whole app, or `const remount =
/// Remount.onSegments;` in a folder's `route.dart` for the routes in it and
/// below (the nearest one wins).
///
/// A new key is a new page to go_router, so the `Navigator` replaces the old
/// page with the new one: the page's transition may play, and the old page
/// leaves the way a page does. A layout is not a page of the route and keeps
/// its state either way.
enum Remount {
  /// A change of the URL keeps the page and its state. The default.
  never,

  /// A change of the value of a segment (`/c/1` to `/c/2`) is a new page, with
  /// a fresh state. A change of the query (`?page=2`) keeps the page, which is
  /// what a page that keeps its state in the URL
  /// (`XRoute.of(context).copyWith(page: 2)`) needs.
  onSegments,

  /// Any change of the location is a new page, the query included. The
  /// fragment is not part of the location here.
  onLocation,
}

/// The key of the page of the route [state] is for, under [remount].
///
/// [Remount.never] gives go_router's own `state.pageKey`. [Remount.onSegments]
/// adds the values of the path parameters named in [segments] (the ones in the
/// route's path, which the generated router lists), and [Remount.onLocation]
/// the path matched so far and the query. A page whose key changes is a new
/// page: its state starts again.
///
/// The key is a `ValueKey<String>`, because go_router uses its value as the
/// page's restoration id.
ValueKey<String> remountKey(
  GoRouterState state,
  Remount remount, [
  List<String> segments = const [],
]) {
  final key = state.pageKey;
  return switch (remount) {
    Remount.never => key,
    Remount.onSegments => ValueKey<String>(
      '${key.value}#${[for (final n in segments) Uri.encodeComponent(state.pathParameters[n] ?? '')].join('/')}',
    ),
    // `matchedLocation` is the path down to this route's own segment, so the
    // page below which another is pushed (`/c/1` under `/c/1/edit`) keeps its
    // key, where `state.uri` is the whole location.
    Remount.onLocation => ValueKey<String>(
      '${key.value}#${state.matchedLocation}?${state.uri.query}',
    ),
  };
}

/// The page the generated router builds for a route that remounts and has no
/// `transition.dart`, the way go_router builds one for a bare `builder`, but
/// under [key] (see [remountKey]) instead of `state.pageKey`.
///
/// A Material page, or a Cupertino one inside a `CupertinoApp`.
///
/// Named by the route's pattern (`Transitions.pageName`, set by the generated `namedPage`, since
/// 0.9.0), `/c/:id` where go_router's own name was `:id`; outside `namedPage` it keeps that name.
Page<void> remountPage(
  BuildContext context,
  GoRouterState state,
  ValueKey<String> key,
  Widget child,
) => platformPage(
  context,
  key: key,
  name: Transitions.pageName ?? state.name ?? state.path,
  arguments: <String, String>{
    ...state.pathParameters,
    ...state.uri.queryParameters,
  },
  restorationId: key.value,
  child: child,
);
