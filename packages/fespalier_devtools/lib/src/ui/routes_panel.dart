/// The route tree `fsp` wrote, as an outline: navigators as section headers, routes nested under
/// their parents, and the route the router is at highlighted.
library;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';

/// The third tab.
class RoutesPanel extends StatefulWidget {
  /// The panel for [controller]'s app.
  const RoutesPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  State<RoutesPanel> createState() => _RoutesPanelState();
}

class _RoutesPanelState extends State<RoutesPanel> {
  final _filter = TextEditingController();

  /// The routes whose children are shown. A layout or a tab layout is always open: it is a
  /// section header.
  final _open = <RouteNode>{};
  RouteNode? _selected;

  /// The route the ancestors were last opened for.
  RouteNode? _seededFor;

  FespalierController get _controller => widget.controller;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// Whether [item] has to show for the filter: it matches, or something inside it does.
  bool _shown(TreeItem item, String filter) {
    if (filter.isEmpty) return true;
    final own = switch (item) {
      RouteNode() =>
        item.pattern.toLowerCase().contains(filter) ||
            item.route.toLowerCase().contains(filter) ||
            item.file.toLowerCase().contains(filter),
      _ => item.file.toLowerCase().contains(filter),
    };
    return own || item.inside.any((i) => _shown(i, filter));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([_controller, _filter]),
    builder: (context, _) {
      final tree = _controller.tree;
      if (tree == null) {
        return const Center(
          child: Text('The app has not registered its routes.'),
        );
      }
      final current = _controller.currentRoute;
      if (current != _seededFor) {
        _seededFor = current;
        if (current != null) {
          _open.addAll(tree.ancestorsOf(current).whereType<RouteNode>());
        }
      }
      final filter = _filter.text.trim().toLowerCase();
      final rows = <Widget>[];
      _level(context, tree.items, 0, current, filter, rows);
      final selected = _selected;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('routes-filter'),
              controller: _filter,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search, size: 18),
                labelText: 'Filter by pattern, route or file',
              ),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('No route matches the filter.'))
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: rows,
                  ),
          ),
          if (selected != null) ...[
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: _Details(
                  controller: _controller,
                  tree: tree,
                  route: selected,
                ),
              ),
            ),
          ],
        ],
      );
    },
  );

  void _level(
    BuildContext context,
    List<TreeItem> items,
    int depth,
    RouteNode? current,
    String filter,
    List<Widget> out,
  ) {
    for (final item in items) {
      if (!_shown(item, filter)) continue;
      switch (item) {
        case RouteNode():
          final open = filter.isNotEmpty || _open.contains(item);
          out.add(_routeRow(context, item, depth, item == current, open));
          if (open) {
            _level(context, item.children, depth + 1, current, filter, out);
          }
        case ShellNode():
          out.add(_header(context, 'layout ${item.file}', item, depth));
          _level(context, item.items, depth + 1, current, filter, out);
        case TabsNode():
          out.add(_header(context, 'tabs ${item.file}', item, depth));
          for (final b in item.branches) {
            if (!b.items.any((i) => _shown(i, filter))) continue;
            out.add(
              Padding(
                padding: EdgeInsets.only(left: (depth + 1) * 20.0, top: 4),
                child: Text(
                  b.name == '.'
                      ? 'tab ${b.index}: its own page'
                      : 'tab ${b.index}: ${b.name}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            );
            _level(context, b.items, depth + 2, current, filter, out);
          }
      }
    }
  }

  Widget _header(
    BuildContext context,
    String title,
    TreeItem item,
    int depth,
  ) => Padding(
    padding: EdgeInsets.only(left: depth * 20.0, top: 8, bottom: 2),
    child: Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        for (final m in item.markers) KindChip(m),
      ],
    ),
  );

  Widget _routeRow(
    BuildContext context,
    RouteNode node,
    int depth,
    bool isCurrent,
    bool open,
  ) {
    final colors = Theme.of(context).colorScheme;
    final selected = identical(node, _selected);
    return Material(
      key: isCurrent
          ? const Key('current-route')
          : Key('route-${node.route}-${node.pattern}'),
      color: isCurrent
          ? colors.primaryContainer.withValues(alpha: 0.5)
          : selected
          ? colors.surfaceContainerHighest
          : Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selected = node),
        child: Padding(
          padding: EdgeInsets.only(left: depth * 20.0, top: 2, bottom: 2),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: node.children.isEmpty
                    ? null
                    : InkWell(
                        key: Key('toggle-${node.route}-${node.pattern}'),
                        onTap: () => setState(() {
                          if (!_open.remove(node)) _open.add(node);
                        }),
                        child: Icon(
                          open ? Icons.expand_more : Icons.chevron_right,
                          size: 18,
                        ),
                      ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Mono(node.pattern, bold: true, selectable: false),
                    Text(node.route),
                    Mono(node.file, selectable: false),
                    for (final m in node.markers) KindChip(m),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the tree says about one route, and a button to go there.
class _Details extends StatelessWidget {
  const _Details({
    required this.controller,
    required this.tree,
    required this.route,
  });

  final FespalierController controller;
  final RouteTree tree;
  final RouteNode route;

  @override
  Widget build(BuildContext context) {
    final sites = tree.sitesOf(route);
    return Column(
      key: const Key('route-details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Mono(route.pattern, bold: true)),
            if (!route.hasPathParams)
              DevToolsButton(
                key: const Key('route-go'),
                label: 'Go',
                onPressed: () =>
                    controller.navigate(NavigateMode.go, route.pattern),
              ),
          ],
        ),
        LabeledRow('route', Mono(route.route)),
        LabeledRow('file', Mono('${tree.appDir}/${route.file}')),
        LabeledRow(
          'folder',
          Mono(route.folder.isEmpty ? '(the app folder)' : route.folder),
        ),
        for (final e in route.spellings.entries)
          LabeledRow(e.key, Mono(e.value)),
        for (final p in route.params)
          LabeledRow(
            p.inQuery ? 'query' : 'segment',
            Mono('${p.name}: ${p.type}'),
          ),
        for (final s in sites)
          LabeledRow(
            s.kind,
            Mono(
              [
                '${tree.appDir}/${s.file}',
                if (s.kind == 'guard') '(${s.id})',
                if (s.kind == 'action') '${s.name}()',
                if (s.kind == 'data' && !s.traced)
                  '(returns or selects a provider)',
              ].join(' '),
            ),
          ),
      ],
    );
  }
}
