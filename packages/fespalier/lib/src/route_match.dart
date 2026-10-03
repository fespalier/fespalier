import 'package:go_router/go_router.dart' hide RouteMatch;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show ProviderListenable;

import 'lifecycle.dart' show RouteHooks;
import 'location.dart';
import 'route_info.dart';
import 'segments.dart';

/// The parts of [uri]'s path below the mount point [base], each decoded, without
/// empty ones; null when [uri] is not under [base]. With [caseSensitive] off (the
/// `case_sensitive: false` config), `/Shop/a` is under `/shop`.
List<String>? pathBelow(Uri uri, String base, {bool caseSensitive = true}) {
  bool same(String a, String b) =>
      caseSensitive ? a == b : a.toLowerCase() == b.toLowerCase();
  final under = [
    for (final s in uri.pathSegments)
      if (s.isNotEmpty) s,
  ];
  final mount = [
    for (final s in base.split('/'))
      if (s.isNotEmpty) s,
  ];
  if (under.length < mount.length) return null;
  for (var i = 0; i < mount.length; i++) {
    if (!same(under[i], mount[i])) return null;
  }
  return under.sublist(mount.length);
}

/// The [index]th part of [uri]'s path below the mount point [base], decoded, or an
/// empty string when there is none. A generated `not_found.dart` gets the segments
/// above its folder this way.
String pathPart(Uri uri, String base, int index) {
  final parts = pathBelow(uri, base) ?? const <String>[];
  return index < parts.length ? parts[index] : '';
}

/// What the generated code knows about a URL it matched: the typed route, the
/// parameters parsed from it and the providers of its data.
///
/// This is the half of [RouteMatch] that needs nothing but `app.g.dart`
/// (`AppRoutes.matchUrl`); the route manifest adds the [RouteInfo].
final class UrlMatch {
  /// Creates a match of [uri] against [route], with the parsed [params] and loaded [data].
  const UrlMatch(this.uri, this.route, this.params, this.data);

  /// The location that was matched, as given.
  final Uri uri;

  /// The typed route it is, built from the parsed parameters (`ProductRoute(id: 42)`).
  final TypedLocation route;

  /// Every segment and query parameter the route's files read, by name, parsed
  /// into its declared type (`{'id': 42, 'q': null}`).
  final Map<String, Object?> params;

  /// The providers of the route's data, outermost first: the `data.dart` of each
  /// section above it, then its own. Empty when there is none.
  final List<ProviderListenable<AsyncValue<Object?>>> data;

  /// The typed route's class: the key of `AppManifest.byType`.
  Type get type => route.runtimeType;
}

/// What `AppRoutes.match(uri)` found: a location matched to its route, without
/// running any guard or building any widget.
final class RouteMatch {
  /// Creates the match of [url] against the route described by [info].
  const RouteMatch(this.info, this.url);

  /// What `fsp gen` knows about the route: its path, folder, layouts, meta, ...
  final RouteInfo<Object?> info;

  /// The match itself.
  final UrlMatch url;

  /// The location that was matched, as given.
  Uri get uri => url.uri;

  /// The typed route, built from the parsed parameters: `match.route.location` is
  /// the location in its canonical spelling.
  TypedLocation get route => url.route;

  /// The parsed segments and query parameters, by name.
  Map<String, Object?> get params => url.params;

  /// The providers of the route's data, outermost first (each section's, then the
  /// route's own); empty when it has none. These are the very providers the page
  /// watches, so warming one warms the page.
  List<ProviderListenable<AsyncValue<Object?>>> get data => url.data;

  @override
  String toString() => 'RouteMatch(${info.path} <- $uri)';
}

/// One route as `AppRoutes.matchUrl` tries it: its path as parts (`['products', ':id']`;
/// `*rest` is a catch-all of one or more parts, `*rest?` of none or more; a localized folder
/// is all its spellings joined by `|`, `'products|produits'`) and how to
/// build what it matched, which throws [BadSegment] for a segment that doesn't parse.
///
/// [caseSensitive] is the route's own setting (its folder's `route.dart`, else the config).
final class RouteMatcher {
  /// Creates a matcher for [pattern] that [build]s a [UrlMatch].
  const RouteMatcher(
    this.pattern,
    this.build, {
    this.caseSensitive = true,
    this.observe,
  });

  /// The URL's path segments; `:name` ones are parameters.
  final List<String> pattern;

  /// Turns the matched go_router state into a [UrlMatch].
  final UrlMatch Function(GoRouterState state) build;

  /// Whether the pattern is compared case-sensitively.
  final bool caseSensitive;

  /// The observe.dart hooks of this route at a location, outermost first (since 0.8.0):
  /// generated only for routes that have some.
  final List<RouteHooks> Function(GoRouterState state, UrlMatch match)? observe;
}

/// What the generated `AppRoutes.matchUrl` calls: the first of [routes] whose pattern
/// fits [uri] (below the mount point [base]), built from the path and query
/// parameters of [uri].
///
/// [routes] are ordered most specific first (static parts before `:param`s before
/// catch-alls), the order go_router tries them in. Null when nothing fits, or when the
/// route that does has a segment that doesn't parse: the same rule that sends it to
/// `not_found.dart`. Nothing else runs: no guard, no widget.
UrlMatch? matchRoutes(
  Uri uri,
  String base,
  List<RouteMatcher> routes, {
  bool caseSensitive = true,
}) {
  final path = pathBelow(uri, base, caseSensitive: caseSensitive);
  if (path == null) return null;
  for (final route in routes) {
    final params = _capture(route.pattern, path, route.caseSensitive);
    if (params == null) continue;
    final state = _UrlState(uri, params, _fullPath(base, route.pattern));
    try {
      return route.build(state);
    } on BadSegment {
      return null;
    }
  }
  return null;
}

/// The observe.dart hooks of the route at [uri], outermost first (since 0.8.0): what the
/// generated `_observeAt` calls. Empty when no route fits, a segment does not parse (the
/// not-found rule), or the route has none. Like [matchRoutes], it runs no guard and builds no
/// widget.
List<RouteHooks> observeRoutes(
  Uri uri,
  String base,
  List<RouteMatcher> routes, {
  bool caseSensitive = true,
}) {
  final path = pathBelow(uri, base, caseSensitive: caseSensitive);
  if (path == null) return const [];
  for (final route in routes) {
    final params = _capture(route.pattern, path, route.caseSensitive);
    if (params == null) continue;
    final state = _UrlState(uri, params, _fullPath(base, route.pattern));
    try {
      final match = route.build(state);
      return route.observe?.call(state, match) ?? const [];
    } on BadSegment {
      return const [];
    }
  }
  return const [];
}

/// Whether [segment] is the static pattern part [part]: a part is one spelling
/// (`products`), or, for a localized folder, all of them joined by `|`
/// (`products|produits|produkte`). No segment can hold a `|`, so this can't be mistaken
/// for a spelling.
bool partMatches(String part, String segment, bool caseSensitive) {
  bool same(String a, String b) =>
      caseSensitive ? a == b : a.toLowerCase() == b.toLowerCase();
  return part.contains('|')
      ? part.split('|').any((spelling) => same(spelling, segment))
      : same(part, segment);
}

/// The path parameters [pattern] takes out of [path]; null when it doesn't fit.
Map<String, String>? _capture(
  List<String> pattern,
  List<String> path,
  bool caseSensitive,
) {
  final params = <String, String>{};
  for (var i = 0; i < pattern.length; i++) {
    final part = pattern[i];
    if (part.startsWith('*')) {
      final optional = part.endsWith('?');
      final rest = path.sublist(i < path.length ? i : path.length);
      if (rest.isEmpty && !optional) return null;
      if (rest.isNotEmpty) {
        final name = part.substring(1, optional ? part.length - 1 : null);
        params[name] = rest.join('/');
      }
      return params;
    }
    if (i >= path.length) return null;
    if (part.startsWith(':')) {
      params[part.substring(1)] = path[i];
    } else if (!partMatches(part, path[i], caseSensitive)) {
      return null;
    }
  }
  return path.length == pattern.length ? params : null;
}

/// go_router's spelling of the route's path, mount point included
/// (`/shop/docs/:rest(.+)`, `/:_l0(products|produits)/:id`), which `Segment.asRest` reads to count the parts before
/// a catch-all.
String _fullPath(String base, List<String> pattern) {
  final parts = [
    for (final (i, p) in pattern.indexed)
      if (p.startsWith('*'))
        ':${p.substring(1, p.endsWith('?') ? p.length - 1 : null)}(.+)'
      else if (p.contains('|'))
        // A localized folder is a parameter that matches each spelling.
        ':_l$i(${p.replaceAll('.', r'\.')})'
      else
        p,
  ];
  return joinLocation(base, '/${parts.join('/')}');
}

/// The `GoRouterState` the generated parsers (`_params3(state)`) read a matched URL
/// through: its `uri`, `pathParameters` and `fullPath`. There is no router here, so
/// there is nothing else; asking for anything else is an error.
final class _UrlState implements GoRouterState {
  const _UrlState(this.uri, this.pathParameters, this.fullPath);

  @override
  final Uri uri;

  @override
  final Map<String, String> pathParameters;

  @override
  final String? fullPath;

  @override
  String get matchedLocation => uri.path;

  @override
  Object? get extra => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'a location matched without a router has no ${invocation.memberName}',
  );
}
