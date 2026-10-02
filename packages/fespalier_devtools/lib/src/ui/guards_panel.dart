/// The guards and redirects that ran: what each one answered for the location it was asked about,
/// newest first.
library;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';

/// How loud the chip of a guard's [result] is.
ChipTone guardTone(String result) => switch (result) {
  GuardOutcome.redirect => ChipTone.warning,
  GuardOutcome.pending => ChipTone.accent,
  GuardOutcome.error => ChipTone.error,
  _ => ChipTone.neutral,
};

/// The fourth tab.
class GuardsPanel extends StatefulWidget {
  /// The panel for [controller]'s app.
  const GuardsPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  State<GuardsPanel> createState() => _GuardsPanelState();
}

class _GuardsPanelState extends State<GuardsPanel> {
  /// The results that are not shown.
  final _hidden = <String>{};

  FespalierController get _controller => widget.controller;

  static const _results = [
    GuardOutcome.pass,
    GuardOutcome.redirect,
    GuardOutcome.pending,
    GuardOutcome.error,
    GuardOutcome.skipped,
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      if (!_controller.supports(DevToolsFeatures.guards)) {
        return const NotReported('guards');
      }
      final all = _controller.snapshot?.guards ?? const <GuardRecord>[];
      final tree = _controller.tree;
      final shown = [
        for (final g in all.reversed)
          if (!_hidden.contains(g.result)) g,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final r in _results)
                  FilterChip(
                    key: Key('guard-filter-$r'),
                    label: Text('$r ${all.where((g) => g.result == r).length}'),
                    selected: !_hidden.contains(r),
                    visualDensity: VisualDensity.compact,
                    onSelected: (on) => setState(() {
                      if (on) {
                        _hidden.remove(r);
                      } else {
                        _hidden.add(r);
                      }
                    }),
                  ),
              ],
            ),
          ),
          Expanded(
            child: all.isEmpty
                ? const Center(child: Text('No guard has answered yet.'))
                : shown.isEmpty
                ? const Center(child: Text('Every result is filtered out.'))
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final g in shown)
                        GuardRow(record: g, site: tree?.sites[g.site]),
                    ],
                  ),
          ),
        ],
      );
    },
  );
}

/// One guard decision: when, which guard, what it was asked, what it answered.
class GuardRow extends StatelessWidget {
  /// A row for [record], whose guard is [site] in the tree (null when the tree does not have it).
  const GuardRow({super.key, required this.record, this.site});

  /// The decision.
  final GuardRecord record;

  /// The guard's place in the tree, for its file and route.
  final Site? site;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final site = this.site;
    return Padding(
      key: Key('guard-${record.seq}'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            formatClock(record.at),
            style: style?.copyWith(fontFamily: 'monospace'),
          ),
          KindChip(record.result, tone: guardTone(record.result)),
          Mono(record.uri, bold: true, selectable: false),
          if (record.result == GuardOutcome.redirect &&
              record.location != null) ...[
            const Text('→'),
            Mono(record.location!, selectable: false),
          ],
          if (record.result == GuardOutcome.skipped)
            Text('segments did not parse', style: style),
          Mono(site?.file ?? record.site, selectable: false),
          if (site?.route != null) Text(site!.route!, style: style),
          if (record.isAsync) const KindChip('async'),
          if (record.isAsync && record.result != GuardOutcome.pending)
            Text('${record.ms} ms', style: style),
          if (record.error != null)
            Text(
              record.error!,
              style: style?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
