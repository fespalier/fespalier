/// The route tree `fsp` writes into `app.g.dart` (`fsp routes --graph json`), parsed: what the
/// panels name files, parameters and markers from.
library;

/// A parameter of a route, a path segment or a query parameter.
final class TreeParam {
  /// A parameter called [name] of Dart type [type].
  const TreeParam(this.name, this.type, {required this.inQuery});

  /// Reads one of a route's `params`.
  factory TreeParam.fromJson(Map<String, Object?> json) => TreeParam(
    json['name']! as String,
    json['type']! as String,
    inQuery: json['in'] == 'query',
  );

  /// The segment or query parameter's name.
  final String name;

  /// Its Dart type, as the app spells it (`int`, `String?`, `List<Category>`).
  final String type;

  /// A query parameter, not a path segment.
  final bool inQuery;
}

/// Something in the tree: a route, a layout, or a tab layout.
sealed class TreeItem {
  const TreeItem({
    required this.file,
    required this.folder,
    required this.markers,
  });

  /// Reads an item, by its `type`.
  factory TreeItem.fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'route' => RouteNode._fromJson(json),
        'shell' => ShellNode._fromJson(json),
        'tabs' => TabsNode._fromJson(json),
        final other => throw FormatException('unknown tree item `$other`'),
      };

  /// The file that makes it, relative to the app folder (`products/$id/page.dart`).
  final String file;

  /// Its folder, relative to the app folder; empty for the app folder itself.
  final String folder;

  /// What `fsp routes --graph` marks it with: `data`, `guard`, `action`, `redirect`, `present`,
  /// `root`, `sibling`.
  final List<String> markers;

  /// The items directly inside it, with each box's own items for a tab layout.
  Iterable<TreeItem> get inside;
}

/// A route: a `GoRoute` for a page or a `redirect.dart`.
final class RouteNode extends TreeItem {
  /// A route.
  const RouteNode({
    required super.file,
    required super.folder,
    required super.markers,
    required this.pattern,
    required this.route,
    required this.params,
    required this.spellings,
    required this.redirect,
    required this.children,
  });

  factory RouteNode._fromJson(Map<String, Object?> json) => RouteNode(
    file: json['file']! as String,
    folder: json['folder']! as String,
    markers: _strings(json['markers']),
    pattern: json['pattern']! as String,
    route: json['route']! as String,
    params: [
      for (final p in (json['params'] as List<Object?>? ?? const []))
        TreeParam.fromJson(p! as Map<String, Object?>),
    ],
    spellings: {
      for (final e
          in (json['spellings'] as Map<String, Object?>? ?? const {}).entries)
        e.key: e.value! as String,
    },
    redirect: json['redirect'] == true,
    children: [
      for (final c in (json['children'] as List<Object?>? ?? const []))
        TreeItem.fromJson(c! as Map<String, Object?>),
    ],
  );

  /// The URL pattern (`/products/:id`).
  final String pattern;

  /// The typed route class (`ProductRoute`).
  final String route;

  /// The segments, then the query parameters.
  final List<TreeParam> params;

  /// The pattern in each locale it has a spelling for.
  final Map<String, String> spellings;

  /// A `redirect.dart` in place of a page.
  final bool redirect;

  /// What nests in it.
  final List<TreeItem> children;

  /// Whether the pattern has a path parameter, so a location for it needs a value.
  bool get hasPathParams => params.any((p) => !p.inQuery);

  @override
  Iterable<TreeItem> get inside => children;
}

/// A layout: a shell that wraps the routes inside it.
final class ShellNode extends TreeItem {
  /// A layout.
  const ShellNode({
    required super.file,
    required super.folder,
    required super.markers,
    required this.items,
  });

  factory ShellNode._fromJson(Map<String, Object?> json) => ShellNode(
    file: json['file']! as String,
    folder: json['folder']! as String,
    markers: _strings(json['markers']),
    items: [
      for (final c in (json['items'] as List<Object?>? ?? const []))
        TreeItem.fromJson(c! as Map<String, Object?>),
    ],
  );

  /// What the layout shows.
  final List<TreeItem> items;

  @override
  Iterable<TreeItem> get inside => items;
}

/// One tab of a tab layout.
final class TabBranch {
  /// Tab [index], named [name] as `tabs` names it.
  const TabBranch(this.index, this.name, this.items);

  /// The tab's position.
  final int index;

  /// Its folder, or `.` for the layout's own page.
  final String name;

  /// What the tab shows.
  final List<TreeItem> items;
}

/// A tab layout: a shell with one navigator per tab.
final class TabsNode extends TreeItem {
  /// A tab layout.
  const TabsNode({
    required super.file,
    required super.folder,
    required super.markers,
    required this.branches,
  });

  factory TabsNode._fromJson(Map<String, Object?> json) => TabsNode(
    file: json['file']! as String,
    folder: json['folder']! as String,
    markers: _strings(json['markers']),
    branches: [
      for (final b in (json['branches'] as List<Object?>? ?? const []))
        TabBranch(
          (b! as Map<String, Object?>)['index']! as int,
          b['name']! as String,
          [
            for (final c in (b['items'] as List<Object?>? ?? const []))
              TreeItem.fromJson(c! as Map<String, Object?>),
          ],
        ),
    ],
  );

  /// The tabs, in order.
  final List<TabBranch> branches;

  @override
  Iterable<TreeItem> get inside => [for (final b in branches) ...b.items];
}

/// A place in the generated code that has a guard, a redirect, a `data.dart` or an action.
final class Site {
  /// A site with id [id].
  const Site({
    required this.id,
    required this.kind,
    required this.file,
    this.route,
    this.pattern,
    this.section,
    this.name,
    this.traced = true,
  });

  /// Reads one of the tree's `sites`.
  factory Site.fromJson(String id, Map<String, Object?> json) => Site(
    id: id,
    kind: json['kind']! as String,
    file: json['file']! as String,
    route: json['route'] as String?,
    pattern: json['pattern'] as String?,
    section: json['section'] as String?,
    name: json['name'] as String?,
    traced: json['traced'] != false,
  );

  /// `g5@6`, `r32`, `d37`, `a37_0`: the string the generated code uses.
  final String id;

  /// `guard`, `redirect`, `data` or `action`.
  final String kind;

  /// The file, relative to the app folder.
  final String file;

  /// The route it is on (for a guard, the route it protects), when it is on one.
  final String? route;

  /// That route's pattern, for a guard or a redirect.
  final String? pattern;

  /// The section's folder, for the `data.dart` of a layout that has no page.
  final String? section;

  /// The action's function name.
  final String? name;

  /// For a `data.dart`: whether its provider is the one fespalier makes, which is what a later
  /// protocol can follow; false when the file returns or selects a provider of its own.
  final bool traced;
}

/// The whole tree.
final class RouteTree {
  /// A tree.
  RouteTree({
    required this.protocol,
    required this.package,
    required this.appDir,
    required this.items,
    required this.sites,
  });

  /// Reads the tree JSON.
  factory RouteTree.fromJson(Map<String, Object?> json) => RouteTree(
    protocol: json['protocol']! as int,
    package: json['package'] as String?,
    appDir: json['appDir']! as String,
    items: [
      for (final i in (json['items'] as List<Object?>? ?? const []))
        TreeItem.fromJson(i! as Map<String, Object?>),
    ],
    sites: {
      for (final e
          in (json['sites'] as Map<String, Object?>? ?? const {}).entries)
        e.key: Site.fromJson(e.key, e.value! as Map<String, Object?>),
    },
  );

  /// The protocol the tree is written for.
  final int protocol;

  /// The app's package name, when its pubspec has one.
  final String? package;

  /// The app folder (`lib/app`).
  final String appDir;

  /// What the root navigator holds.
  final List<TreeItem> items;

  /// Every site, by id.
  final Map<String, Site> sites;

  /// Every route, in the order the tree lists them.
  late final List<RouteNode> routes = [
    for (final item in _walk(items))
      if (item is RouteNode) item,
  ];

  /// The route whose typed route class is [name], or null.
  RouteNode? routeByClass(String? name) {
    if (name == null) return null;
    for (final r in routes) {
      if (r.route == name) return r;
    }
    return null;
  }

  /// The first route whose pattern is [pattern], or null.
  RouteNode? routeByPattern(String pattern) {
    for (final r in routes) {
      if (r.pattern == pattern) return r;
    }
    return null;
  }

  /// The sites that are on [route]: its guards, its redirect, its data and its actions.
  List<Site> sitesOf(RouteNode route) => [
    for (final s in sites.values)
      if (s.route == route.route) s,
  ];

  /// The items from the root down to [target], not counting it: the routes it nests in and the
  /// layouts and tab layouts around it. Empty when [target] is not in the tree.
  List<TreeItem> ancestorsOf(TreeItem target) {
    final path = <TreeItem>[];
    bool visit(List<TreeItem> level) {
      for (final item in level) {
        if (identical(item, target)) return true;
        path.add(item);
        final found = switch (item) {
          RouteNode() => visit(item.children),
          ShellNode() => visit(item.items),
          TabsNode() => item.branches.any((b) => visit(b.items)),
        };
        if (found) return true;
        path.removeLast();
      }
      return false;
    }

    return visit(items) ? path : const [];
  }

  /// The tab of [tabs] that holds [target], or null.
  int? tabOf(TabsNode tabs, TreeItem target) {
    for (final b in tabs.branches) {
      if (_walk(b.items).any((i) => identical(i, target))) return b.index;
    }
    return null;
  }

  static Iterable<TreeItem> _walk(List<TreeItem> level) sync* {
    for (final item in level) {
      yield item;
      yield* _walk(item.inside.toList());
    }
  }
}

List<String> _strings(Object? list) => [
  for (final v in (list as List<Object?>? ?? const [])) '$v',
];
