/// The router's stack: the pages that are in it, the layouts around them and the pages that
/// were pushed on top, each with the route and file it comes from.
library;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';

/// The second tab.
class StackPanel extends StatelessWidget {
  /// The panel for [controller]'s app.
  const StackPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final stack = controller.snapshot?.stack ?? const [];
      if (stack.isEmpty) {
        return const Center(child: Text('The stack is empty.'));
      }
      final rows = <Widget>[];
      _rows(context, controller.tree, stack, 0, 0, rows);
      return ListView(padding: const EdgeInsets.all(8), children: rows);
    },
  );

  void _rows(
    BuildContext context,
    RouteTree? tree,
    List<FrameRecord> frames,
    int depth,
    int shells,
    List<Widget> out,
  ) {
    for (final frame in frames) {
      final isShell = frame.type == FrameType.shell;
      out.add(
        _FrameRow(
          frame: frame,
          depth: depth,
          label: isShell ? shellLabel(tree, frame, shells) : null,
          route: isShell ? null : tree?.routeByPattern(frame.path),
        ),
      );
      _rows(context, tree, frame.children, depth + 1, switch (frame.type) {
        FrameType.shell => shells + 1,
        // What was pushed has layouts of its own, counted from the root again.
        FrameType.pushed => 0,
        _ => shells,
      }, out);
    }
  }
}

/// What a shell frame is: `layout (account)/layout.dart`, or `tabs (tabs)/layout.dart · tab 1`.
///
/// The frame has no file of its own, so it is found through the page inside it: the tree box
/// around that page that is the [shells]th layout from the root, as the stack has it.
String shellLabel(RouteTree? tree, FrameRecord shell, int shells) {
  if (tree == null) return 'layout';
  final page = _firstPage(shell);
  final node = page == null ? null : tree.routeByPattern(page.path);
  if (node == null) return 'layout';
  final boxes = [
    for (final a in tree.ancestorsOf(node))
      if (a is ShellNode || a is TabsNode) a,
  ];
  if (shells >= boxes.length) return 'layout';
  return switch (boxes[shells]) {
    final TabsNode tabs =>
      'tabs ${tabs.file}'
          '${tree.tabOf(tabs, node) == null ? '' : ' · tab ${tree.tabOf(tabs, node)}'}',
    final box => 'layout ${box.file}',
  };
}

FrameRecord? _firstPage(FrameRecord frame) {
  for (final c in frame.children) {
    if (c.type == FrameType.page) return c;
    final found = _firstPage(c);
    if (found != null) return found;
  }
  return null;
}

class _FrameRow extends StatelessWidget {
  const _FrameRow({
    required this.frame,
    required this.depth,
    required this.label,
    required this.route,
  });

  final FrameRecord frame;
  final int depth;

  /// For a shell: what it is.
  final String? label;

  /// For a page: the route in the tree.
  final RouteNode? route;

  @override
  Widget build(BuildContext context) {
    final tone = switch (frame.type) {
      FrameType.pushed => ChipTone.warning,
      FrameType.shell => ChipTone.neutral,
      _ => ChipTone.accent,
    };
    return Padding(
      padding: EdgeInsets.only(left: depth * 20.0, top: 3, bottom: 3),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          KindChip(frame.type, tone: tone),
          if (label != null)
            Mono(label!, bold: true)
          else ...[
            Mono(frame.path, bold: true),
            if (frame.location != frame.path) Mono(frame.location),
            if (route != null) Text(route!.route),
            if (route != null) Mono(route!.file),
          ],
        ],
      ),
    );
  }
}
