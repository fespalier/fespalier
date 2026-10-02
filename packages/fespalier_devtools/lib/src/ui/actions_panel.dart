/// The runs of the `action.dart` functions: what each was called with, whether it is still going,
/// and how it ended, newest first.
library;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';

/// How loud the chip of an action's [state] is.
ChipTone actionTone(String state) => switch (state) {
  ActionState.running => ChipTone.accent,
  ActionState.error => ChipTone.error,
  _ => ChipTone.neutral,
};

/// The sixth tab.
class ActionsPanel extends StatelessWidget {
  /// The panel for [controller]'s app.
  const ActionsPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.supports(DevToolsFeatures.actions)) {
        return const NotReported('actions');
      }
      final all = controller.snapshot?.actions ?? const <ActionRecord>[];
      if (all.isEmpty) {
        return const Center(child: Text('No action has run yet.'));
      }
      final tree = controller.tree;
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          for (final a in all.reversed)
            ActionRow(record: a, site: tree?.sites[a.site]),
        ],
      );
    },
  );
}

/// One run: when it started, which function, its key and input, and its end.
class ActionRow extends StatelessWidget {
  /// A row for [record], whose `action.dart` function is [site] in the tree (null when it is
  /// not there).
  const ActionRow({super.key, required this.record, this.site});

  /// The run.
  final ActionRecord record;

  /// The function's place in the tree.
  final Site? site;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final site = this.site;
    final name = site == null
        ? record.site
        : '${site.file}#${site.name ?? 'action'}';
    return Padding(
      key: Key('action-${record.seq}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            formatClock(record.started),
            style: style?.copyWith(fontFamily: 'monospace'),
          ),
          KindChip(record.state, tone: actionTone(record.state)),
          Mono(name, bold: true, selectable: false),
          if (record.key != null) Text('key ${record.key!.text}', style: style),
          Text(
            'input ${record.input.type}: ${record.input.text}',
            style: style,
          ),
          if (record.ms != null) Text('${record.ms} ms', style: style),
          if (record.result != null)
            Text(
              'result ${record.result!.type}: ${record.result!.text}',
              style: style,
            ),
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
