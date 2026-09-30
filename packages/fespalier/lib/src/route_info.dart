import 'package:go_router/go_router.dart';

/// How a route is served.
enum RoutePresentation {
  /// A `page.dart`.
  page,

  /// A `redirect.dart`: no page, it only sends the visitor elsewhere.
  redirect,
}

/// A segment (`$id`) or a query parameter a route reads, as the generated
/// route class takes it.
class RouteParam {
  const RouteParam(this.name, this.type);

  final String name;

  /// The Dart type as the route class spells it: `int`, `String`, `int?`
  /// (an optional query parameter), `List<String>` (every `?x=` value).
  final String type;

  @override
  String toString() => '$type $name';
}

/// A tab a route sits in: one branch of the tab layout in [layout].
class RouteTab {
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
  const RouteInfo({
    required this.type,
    required this.path,
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

  /// The route's folder relative to the app folder: `products/$id`; empty for
  /// the app folder itself.
  final String folder;

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
/// (`AppRoutes.base`) taken off: the key `AppManifest.byPath` uses. Null when
/// go_router has no path for it (an error page).
String? routeTemplate(GoRouterState state, [String base = '/']) {
  var path = state.fullPath;
  if (path == null) return null;
  final prefix = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  if (prefix.isNotEmpty && (path == prefix || path.startsWith('$prefix/'))) {
    path = path.substring(prefix.length);
  }
  return path.isEmpty ? '/' : path;
}
