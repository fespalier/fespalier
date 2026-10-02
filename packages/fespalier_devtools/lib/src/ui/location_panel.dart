/// Where the router is: the location, its route and parameters, and the history of the locations
/// it committed.
library;

import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';
import 'guards_panel.dart' show GuardRow;

/// The first tab.
class LocationPanel extends StatelessWidget {
  /// The panel for [controller]'s app.
  const LocationPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      final location = snapshot?.location;
      if (location == null) {
        return const Center(
          child: Text('The router has not shown a location yet.'),
        );
      }
      final route = controller.currentRoute;
      final history = snapshot!.history.reversed.toList();
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          LabeledRow('location', Mono(location.uri, bold: true)),
          if (location.route != null)
            LabeledRow('route', Mono(location.route!)),
          if (location.fullPath.isNotEmpty)
            LabeledRow('path', Mono(location.fullPath)),
          if (route != null) LabeledRow('file', Mono(route.file)),
          if (location.error != null)
            LabeledRow(
              'error',
              Text(
                location.error!,
                key: const Key('location-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ..._params(context, location, route),
          ..._query(location),
          if (location.extra != null)
            LabeledRow(
              'extra',
              Row(
                children: [
                  KindChip(location.extra!.type),
                  const SizedBox(width: 6),
                  Flexible(child: Mono(location.extra!.text)),
                ],
              ),
            ),
          const SectionTitle('History'),
          if (history.isEmpty) const Text('Nothing committed yet.'),
          for (final h in history)
            _HistoryRow(record: h, controller: controller),
        ],
      );
    },
  );

  /// The typed parameters (name, type, value), or the router's own path parameters when the
  /// app's matcher knows no route for the location.
  List<Widget> _params(
    BuildContext context,
    LocationRecord location,
    RouteNode? route,
  ) {
    final typed = location.params;
    final rows = <TableRow>[];
    if (typed != null && typed.isNotEmpty) {
      final types = {
        for (final p in route?.params ?? const <TreeParam>[]) p.name: p.type,
      };
      for (final e in typed.entries) {
        rows.add(_row(e.key, types[e.key] ?? e.value.type, e.value.text));
      }
    } else {
      for (final e in location.pathParameters.entries) {
        rows.add(_row(e.key, 'String', e.value));
      }
    }
    if (rows.isEmpty) return const [];
    return [
      const SectionTitle('Parameters'),
      Table(
        key: const Key('location-params'),
        columnWidths: const {
          0: IntrinsicColumnWidth(),
          1: IntrinsicColumnWidth(),
          2: FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: rows,
      ),
    ];
  }

  TableRow _row(String name, String type, String value) => TableRow(
    children: [
      Padding(
        padding: const EdgeInsets.only(right: 12, bottom: 2),
        child: Mono(name, bold: true),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 12, bottom: 2),
        child: Mono(type, selectable: false),
      ),
      Mono(value),
    ],
  );

  List<Widget> _query(LocationRecord location) {
    if (location.query.isEmpty) return const [];
    return [
      const SectionTitle('Query'),
      for (final e in location.query.entries)
        LabeledRow(e.key, Mono(e.value.join(', '))),
    ];
  }
}

/// One committed location. With guards behind it, a badge opens what each of them answered.
class _HistoryRow extends StatefulWidget {
  const _HistoryRow({required this.record, required this.controller});

  final NavigationRecord record;
  final FespalierController controller;

  @override
  State<_HistoryRow> createState() => _HistoryRowState();
}

class _HistoryRowState extends State<_HistoryRow> {
  var _open = false;

  NavigationRecord get record => widget.record;
  FespalierController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final tone = switch (record.kind) {
      NavigationKind.replace || NavigationKind.refresh => ChipTone.warning,
      NavigationKind.initial => ChipTone.accent,
      _ => ChipTone.neutral,
    };
    final guards = [
      for (final seq in record.guards)
        controller.snapshot?.guards.where((g) => g.seq == seq).firstOrNull,
    ];
    return Padding(
      key: Key('history-${record.seq}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                formatClock(record.at),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
              SizedBox(
                width: 72,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: KindChip(record.kind, tone: tone),
                ),
              ),
              Mono(record.uri),
              if (record.guards.isNotEmpty)
                InkWell(
                  key: Key('history-guards-${record.seq}'),
                  onTap: () => setState(() => _open = !_open),
                  child: KindChip(
                    '${record.guards.length} '
                    '${record.guards.length == 1 ? 'guard' : 'guards'}'
                    '${_open ? ' ▾' : ' ▸'}',
                  ),
                ),
              if (record.error != null)
                const KindChip('not found', tone: ChipTone.error),
            ],
          ),
          if (_open)
            Padding(
              key: Key('history-guards-list-${record.seq}'),
              padding: const EdgeInsets.only(left: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < guards.length; i++)
                    guards[i] == null
                        ? Text('guard #${record.guards[i]} is no longer kept')
                        : GuardRow(
                            record: guards[i]!,
                            site: controller.tree?.sites[guards[i]!.site],
                          ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
