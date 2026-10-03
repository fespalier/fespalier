import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart' hide RouteMatch;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'location.dart';
import 'route_match.dart';
import 'segments.dart';

/// How a folder shows in the menus `fsp` generates (`AppMenu`): what its `nav.dart`
/// declares (since 0.8.1).
///
/// ```dart
/// // lib/app/products/nav.dart
/// const nav = Nav(label: 'Products', icon: Icons.storefront_outlined, order: 1);
/// ```
final class Nav {
  /// Declares the folder's entry.
  const Nav({
    required this.label,
    this.icon,
    this.selectedIcon,
    this.order = 0,
    this.inMenu = true,
    this.whenRefused = NavRefused.hide,
  });

  /// The label without a `BuildContext` (`fsp routes`, tests), and the fallback when
  /// nav.dart has no `label()`.
  final String label;

  /// The icon of the entry.
  final IconData? icon;

  /// The icon while the entry is selected; [icon] when null.
  final IconData? selectedIcon;

  /// Where it sorts among its siblings (then by the tab it is, then by folder name). It
  /// must be a whole-number literal: `fsp` reads it from the source.
  final int order;

  /// False: in breadcrumbs, but not in `AppMenu.watch` (nor the entries below it).
  final bool inMenu;

  /// What a menu does with the entry while its guards would refuse a navigation to it.
  final NavRefused whenRefused;
}

/// What a menu does with an entry whose guards would refuse it now.
enum NavRefused {
  /// Leave it (and the entries below it) out. The default.
  hide,

  /// List it with `enabled == false`.
  disable,

  /// List it, and don't ask its guards at all.
  show,
}

/// What an entry's guards answer for its location, as of now.
enum NavAccess {
  /// Every guard let it through (or it has none).
  allowed,

  /// A guard answered with a location to redirect to.
  refused,

  /// A guard answered with a `Future` that hasn't completed, or threw: the entry is
  /// listed, and enabled.
  pending,
}

/// One folder with a `nav.dart`, as `fsp gen` wrote it into `AppMenu.tree`. Generated: not
/// for apps to build.
final class NavNode {
  /// Creates the node of a folder.
  const NavNode({
    required this.folder,
    required this.nav,
    this.route,
    this.within,
    this.label,
    this.guard,
    this.flat = false,
    this.tabs = const {},
    this.children = const [],
  });

  /// Relative to the app folder: `products/$id`; empty for the app folder itself.
  final String folder;

  /// What the folder's nav.dart declares.
  final Nav nav;

  /// Builds its typed route from the parsed parameters of the current location; null for a
  /// folder without a page.dart or redirect.dart (a heading).
  final TypedLocation Function(Map<String, Object?> params)? route;

  /// When the entry needs segments: the routes whose location has them (every route at or
  /// below the folder that declares its last segment). Anywhere else the entry is left out.
  /// Null: it needs none.
  final List<Type>? within;

  /// nav.dart's `label()`, bound to the parameters.
  final String Function(BuildContext context, Map<String, Object?> params)?
  label;

  /// Its guards, and those above it, outermost first, as a menu asks them.
  final GuardResult Function(Ref ref, TypedLocation route)? guard;

  /// The app folder's own entry, or a tab layout's own page: it sits beside the entries
  /// below it instead of holding them, and is selected only on its own route.
  final bool flat;

  /// The index of the tab it is, by the folder of the tab layout: `{'(tabs)': 2}`.
  final Map<String, int> tabs;

  /// The entries nested below it.
  final List<NavNode> children;
}

/// One entry of a menu at the current location (since 0.8.1).
final class NavItem {
  /// Creates an entry. `AppMenu.watch` and `AppMenu.breadcrumbs` build them.
  const NavItem({
    required this.node,
    required this.route,
    required this.params,
    required this.selected,
    required this.access,
    required this.tab,
    required this.children,
  });

  /// The folder's node, as generated.
  final NavNode node;

  /// Where the entry goes; null for a heading.
  final TypedLocation? route;

  /// The segments the entry was built with (a subset of the current location's parameters).
  final Map<String, Object?> params;

  /// The current location is its route, or below its folder (a flat entry: its own route
  /// only).
  final bool selected;

  /// What its guards answer now.
  final NavAccess access;

  /// The index of its tab in the tab layout `AppMenu.watch(under:)` named; null otherwise.
  final int? tab;

  /// The entries nested below it, as they show.
  final List<NavItem> children;

  /// What the folder's nav.dart declares.
  Nav get nav => node.nav;

  /// The folder, relative to the app folder.
  String get folder => node.folder;

  /// Has a route and its guards don't refuse it now.
  bool get enabled => route != null && access != NavAccess.refused;

  /// [Nav.selectedIcon] while selected (else [Nav.icon]).
  IconData? get icon => selected ? (nav.selectedIcon ?? nav.icon) : nav.icon;

  /// nav.dart's `label(context, ...)`, else [Nav.label].
  String label(BuildContext context) =>
      node.label?.call(context, params) ?? nav.label;

  /// Goes to [route] (nothing for a heading); [locale] picks a localized spelling.
  void go(BuildContext context, {String? locale}) =>
      route?.go(context, locale: locale);
}

/// What the generated `AppMenu.watch` calls: the entries of [tree] at the location around
/// [ref]'s widget, or those at or below the folder [under]. Generated code only.
List<NavItem> watchNav(
  WidgetRef ref,
  List<NavNode> tree,
  UrlMatch? Function(Uri uri) matchUrl,
  Map<Type, List<NavNode>> trails, {
  String? under,
}) {
  // Asking for the router's state makes the widget rebuild on navigation.
  final uri = GoRouterState.of(ref.context).uri;
  final at = matchUrl(uri);
  final trail = at == null ? const <NavNode>[] : trails[at.type] ?? const [];
  final roots = under == null || under.isEmpty ? tree : _under(tree, under);
  assert(roots.isNotEmpty, 'no nav.dart is in or below the folder `$under`');
  return _items(ref, roots, at, trail, under);
}

/// What the generated `AppMenu.breadcrumbs` calls: the entries from the top of the tree down
/// to the page at the current location. Generated code only.
List<NavItem> watchNavTrail(
  WidgetRef ref,
  UrlMatch? Function(Uri uri) matchUrl,
  Map<Type, List<NavNode>> trails,
) {
  final uri = GoRouterState.of(ref.context).uri;
  final at = matchUrl(uri);
  if (at == null) return const [];
  return [
    for (final node in trails[at.type] ?? const <NavNode>[])
      NavItem(
        node: node,
        route: node.route?.call(_paramsOf(node, at)),
        params: _paramsOf(node, at),
        selected: true,
        access: NavAccess.allowed,
        tab: null,
        children: const [],
      ),
  ];
}

/// The topmost nodes in or below the folder [under].
List<NavNode> _under(List<NavNode> nodes, String under) {
  final out = <NavNode>[];
  for (final node in nodes) {
    if (node.folder == under || node.folder.startsWith('$under/')) {
      out.add(node);
    } else {
      out.addAll(_under(node.children, under));
    }
  }
  return out;
}

Map<String, Object?> _paramsOf(NavNode node, UrlMatch at) =>
    node.within == null ? const {} : at.params;

List<NavItem> _items(
  WidgetRef ref,
  List<NavNode> nodes,
  UrlMatch? at,
  List<NavNode> trail,
  String? under,
) {
  final out = <NavItem>[];
  for (final node in nodes) {
    if (!node.nav.inMenu) continue;
    final within = node.within;
    if (within != null && (at == null || !within.contains(at.type))) continue;
    final params = at == null ? const <String, Object?>{} : _paramsOf(node, at);
    final route = node.route?.call(params);
    final guard = node.guard;
    final access =
        route == null ||
            guard == null ||
            node.nav.whenRefused == NavRefused.show
        ? NavAccess.allowed
        : ref.watch(_access(_AccessKey(guard, route)));
    if (access == NavAccess.refused &&
        node.nav.whenRefused == NavRefused.hide) {
      continue;
    }
    final children = _items(ref, node.children, at, trail, under);
    if (route == null && children.isEmpty) continue;
    out.add(
      NavItem(
        node: node,
        route: route,
        params: params,
        selected:
            trail.contains(node) && (!node.flat || identical(trail.last, node)),
        access: access,
        tab: under == null ? null : node.tabs[under],
        children: children,
      ),
    );
  }
  return out;
}

/// What an entry's guards are asked about: the guard chain and the location. Two keys are
/// the same when they have the same chain and the same location, so a menu that builds
/// again asks the same provider.
final class _AccessKey {
  const _AccessKey(this.guard, this.route);

  final GuardResult Function(Ref ref, TypedLocation route) guard;
  final TypedLocation route;

  @override
  bool operator ==(Object other) =>
      other is _AccessKey &&
      identical(other.guard, guard) &&
      other.route.location == route.location;

  @override
  int get hashCode => Object.hash(identityHashCode(guard), route.location);
}

Duration? _noRetry(int retryCount, Object error) => null;

/// What an entry's guards answer, as a provider of its own: a `ref.watch` in a guard is
/// tracked (the entry follows it, in the next frame), a guard that answers at once gives
/// its answer in the first one, and a `Future` is followed with `then` (no timer): the
/// answer is [NavAccess.pending] until it completes. `autoDispose`: a menu that leaves
/// the screen lets go of everything its guards watch.
final _access = NotifierProvider.autoDispose
    .family<_Access, NavAccess, _AccessKey>(_Access.new, retry: _noRetry);

final class _Access extends Notifier<NavAccess> {
  _Access(this.key);

  final _AccessKey key;
  var _run = 0;

  @override
  NavAccess build() {
    final run = ++_run;
    final GuardResult answer;
    try {
      answer = key.guard(ref, key.route);
    } catch (e, st) {
      _report(e, st);
      return NavAccess.pending;
    }
    if (answer is! Future<String?>) return _of(answer);
    answer.then<void>((to) {
      if (ref.mounted && run == _run) state = _of(to);
    }, onError: _report);
    return NavAccess.pending;
  }

  NavAccess _of(String? to) =>
      to == null ? NavAccess.allowed : NavAccess.refused;

  void _report(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'fespalier',
        context: ErrorDescription(
          'while asking the guards of the menu entry ${key.route.location}',
        ),
      ),
    );
  }
}
