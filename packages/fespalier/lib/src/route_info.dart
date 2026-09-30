import 'package:go_router/go_router.dart';

import 'location.dart';

/// How a route is served.
enum RoutePresentation {
  /// A `page.dart`.
  page,

  /// A `redirect.dart`: no page, it only sends the visitor elsewhere.
  redirect,

  /// A `page.dart` on the root navigator, above every layout and tab bar
  /// (`navigator.dart` with `RouteNavigator.root`, in its folder or above).
  root,

  /// A `page.dart` whose `Page` the app builds itself (`present.dart`): fespalier
  /// can't know whether it is a sheet, a dialog or something else. It is on the
  /// root navigator, unless a `navigator.dart` beside it says otherwise.
  custom,
}

/// A segment (`$id`) or a query parameter a route reads, as the generated
/// route class takes it.
class RouteParam {
  /// Creates a parameter called [name] of Dart [type].
  const RouteParam(this.name, this.type, {this.catchAll = false});

  /// The parameter's name, as the route class and the URL (`:name`) spell it.
  final String name;

  /// A `$$rest` / `$$$rest` catch-all: the rest of the path, a `List<String>`
  /// (or a `List` of another type), always the last segment.
  final bool catchAll;

  /// The Dart type as the route class spells it: `int`, `String`, `int?`
  /// (an optional query parameter), `List<String>` (every `?x=` value). An enum
  /// is its name, `Category` or `Sort?`, without the prefix its file imported it under.
  final String type;

  @override
  String toString() => '$type $name';
}

/// A tab a route sits in: one branch of the tab layout in [layout].
class RouteTab {
  /// Creates the tab at [index] of the layout in [layout], named [branch].
  const RouteTab(this.layout, this.index, this.branch);

  /// The tab layout's folder, relative to the app folder (`(tabs)`).
  final String layout;

  /// The branch's position in the layout's tabs, as `navigationShell.currentIndex`.
  final int index;

  /// The branch as `tabs` and `tabOptions` in layout.dart name it: its folder
  /// (`search`), or `.` for the layout folder's own page.
  final String branch;

  @override
  String toString() => '$layout[$index: $branch]';
}

/// What `fsp gen` knows about one route: the generated `AppManifest.all` lists
/// one for every page and redirect.
///
/// [M] is the type of the route's `meta.dart`; `AppManifest` lists them as
/// `RouteInfo<Object?>`, so read [meta] with a check (`meta is PageMeta`) or
/// [metaAs].
class RouteInfo<M> {
  /// Creates the description of one route; the generated manifest fills it in.
  const RouteInfo({
    required this.type,
    required this.path,
    this.paths = const {},
    required this.folder,
    this.presentation = RoutePresentation.page,
    this.groups = const [],
    this.layouts = const [],
    this.segments = const [],
    this.query = const [],
    this.tabs = const [],
    this.dataKeys,
    this.meta,
  });

  /// The generated typed-route class: `ProductRoute`.
  final Type type;

  /// The path template, without the mount point: `/products/:id`.
  final String path;

  /// The path template in each locale the route's folders spell their segment in
  /// (`{'fr': '/produits/:id', 'de': '/produkte/:id'}`, from the `paths` of their
  /// `route.dart` files); a level with no spelling for a locale keeps its canonical
  /// one. Empty for a route with no localized segment. [path] is always the canonical
  /// spelling, and what [AppManifest.byPath] is keyed by.
  final Map<String, String> paths;

  /// The path template as [locale] spells it: its entry in [paths] (`fr-CA` falls back to
  /// `fr`), else [path].
  String pathFor(String? locale) {
    if (locale == null || paths.isEmpty) return path;
    final language = locale.split(RegExp('[-_]')).first;
    String? fallback;
    for (final MapEntry(:key, :value) in paths.entries) {
      if (sameLocale(key, locale)) return value;
      if (sameLocale(key, language)) fallback = value;
    }
    return fallback ?? path;
  }

  /// The route's folder relative to the app folder: `products/$id`; empty for
  /// the app folder itself.
  final String folder;

  /// How the route is shown: a page, a dialog, a sheet or something custom.
  final RoutePresentation presentation;

  /// The `(group)` folders above the route, outermost first, parentheses
  /// included: `['(buyer)']`.
  final List<String> groups;

  /// The folders of the layouts that wrap the route, outermost first (`''` is
  /// the app folder's own layout).
  final List<String> layouts;

  /// The path segments (`$id`), in path order.
  final List<RouteParam> segments;

  /// The query parameters any of the route's files read.
  final List<RouteParam> query;

  /// The tabs the route sits in, outermost first; empty outside tab layouts.
  final List<RouteTab> tabs;

  /// The parameters the route's `data.dart` is keyed by; null without one.
  final List<String>? dataKeys;

  /// The route's `meta.dart`, exactly as declared there; null without one.
  /// It is the route's own: nothing is inherited from the folders above.
  final M? meta;

  /// True for a `redirect.dart` route.
  bool get isRedirect => presentation == RoutePresentation.redirect;

  /// [meta] as a [T], or null when the route has none or it is another type.
  T? metaAs<T>() {
    final Object? m = meta;
    return m is T ? m : null;
  }

  @override
  String toString() => 'RouteInfo($type $path)';
}

/// The path template of the route [state] is at, with the mount point [base]
/// (`AppRoutes.base`) taken off, spelled as `AppManifest.byPath` does: go_router's
/// `:rest(.+)` is `*rest` and a localized folder is its canonical spelling. Null when
/// go_router has no path for it (an error page).
/// (An optional catch-all's route without the catch-all has no `?` here: use
/// [lookupRoute].)
String? routeTemplate(GoRouterState state, [String base = '/']) {
  var path = state.fullPath;
  if (path == null) return null;
  final prefix = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  if (prefix.isNotEmpty && (path == prefix || path.startsWith('$prefix/'))) {
    path = path.substring(prefix.length);
  }
  // A localized folder is a parameter of its own, `:_l0(products|produits)`: its first
  // alternative is the folder's name.
  path = path.replaceAllMapped(
    RegExp(r':_l\d+\(((?:\\.|[^|\\()])*)(?:\|(?:\\.|[^\\()])*)*\)'),
    (m) => m[1]!.replaceAll(r'\.', '.'),
  );
  path = path.replaceAllMapped(RegExp(r':(\w+)\(\.\+\)\??'), (m) => '*${m[1]}');
  return path.isEmpty ? '/' : path;
}

/// The route in [byPath] that [template] (from [routeTemplate]) is: its own
/// path, or the optional catch-all route (`/files/*path?`) it is the path
/// with or without the catch-all of.
RouteInfo<Object?>? lookupRoute(
  Map<String, RouteInfo<Object?>> byPath,
  String? template,
) {
  if (template == null) return null;
  final found = byPath[template] ?? byPath['$template?'];
  if (found != null) return found;
  final prefix = template == '/' ? '' : template;
  for (final info in byPath.values) {
    final rest = info.segments.isEmpty ? null : info.segments.last;
    if (rest != null &&
        rest.catchAll &&
        info.path.endsWith('?') &&
        info.path == '$prefix/*${rest.name}?') {
      return info;
    }
  }
  return null;
}
