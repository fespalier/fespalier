/// The providers of the `data.dart` files: each one's state (loading, data, error), how often it
/// was built, when, and what it holds, with a button to build it again.
library;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';

/// How loud the chip of a data record's [state] is.
ChipTone dataTone(String state) => switch (state) {
  DataState.loading => ChipTone.accent,
  DataState.error => ChipTone.error,
  DataState.disposed => ChipTone.warning,
  _ => ChipTone.neutral,
};

/// The fifth tab.
class DataPanel extends StatefulWidget {
  /// The panel for [controller]'s app.
  const DataPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  State<DataPanel> createState() => _DataPanelState();
}

class _DataPanelState extends State<DataPanel> {
  var _showDisposed = false;

  FespalierController get _controller => widget.controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      if (!_controller.supports(DevToolsFeatures.data)) {
        return const NotReported('data');
      }
      final tree = _controller.tree;
      final all = _controller.snapshot?.data ?? const <DataRecord>[];
      final shown = [
        for (final d in all.reversed)
          if (_showDisposed || d.state != DataState.disposed) d,
      ];
      final untraced = [
        for (final s in tree?.sites.values ?? const <Site>[])
          if (s.kind == 'data' && !s.traced) s,
      ];
      final disposed = all.where((d) => d.state == DataState.disposed).length;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Switch(
                  key: const Key('show-disposed'),
                  value: _showDisposed,
                  onChanged: (v) => setState(() => _showDisposed = v),
                ),
                const SizedBox(width: 4),
                Flexible(child: Text('Show disposed ($disposed)')),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        all.isEmpty
                            ? 'No data.dart provider was built yet.'
                            : 'Every provider shown here was disposed: turn on '
                                  '"Show disposed".',
                      ),
                    ),
                  ),
                for (final d in shown)
                  DataRecordRow(
                    record: d,
                    site: tree?.sites[d.site],
                    refreshedAt: _controller.refreshedAt,
                    onInvalidate: () => _controller.invalidate(d.id),
                  ),
                if (untraced.isNotEmpty) _Untraced(sites: untraced, tree: tree),
              ],
            ),
          ),
        ],
      );
    },
  );
}

/// One provider: its file and route, state, builds, times and value.
class DataRecordRow extends StatelessWidget {
  /// A row for [record], whose `data.dart` is [site] in the tree (null when it is not there).
  /// [refreshedAt] is what the age of the last change is counted to.
  const DataRecordRow({
    super.key,
    required this.record,
    this.site,
    this.refreshedAt,
    required this.onInvalidate,
  });

  /// The provider.
  final DataRecord record;

  /// The `data.dart`'s place in the tree.
  final Site? site;

  /// When the state was last fetched.
  final DateTime? refreshedAt;

  /// Builds the provider again.
  final VoidCallback onInvalidate;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final site = this.site;
    final updated = DateTime.fromMillisecondsSinceEpoch(record.updated);
    final age = refreshedAt?.difference(updated);
    final label = site == null
        ? record.site
        : site.section != null
        ? '${site.file} (section ${site.section})'
        : site.file;
    return Padding(
      key: Key('data-${record.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Mono(label, bold: true, selectable: false),
              if (site?.route != null) Text(site!.route!),
              KindChip(record.state, tone: dataTone(record.state)),
              Text('builds ${record.builds}', style: style),
              DevToolsButton(
                key: Key('invalidate-${record.id}'),
                label: 'Invalidate',
                tooltip: 'Build this provider again',
                onPressed: record.state == DataState.disposed
                    ? null
                    : onInvalidate,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                if (record.key != null)
                  Text('key ${record.key!.text}', style: style),
                Text('container ${record.container}', style: style),
                Text('created ${formatClock(record.created)}', style: style),
                Text(
                  'updated ${formatClock(record.updated)}'
                  '${age == null ? '' : ' (${formatAge(age)} before the last refresh)'}',
                  style: style,
                ),
                if (record.value != null)
                  Text(
                    '${record.value!.type}: ${record.value!.text}',
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
          ),
        ],
      ),
    );
  }
}

/// The `data.dart` files fespalier cannot follow: they return or select a provider of their own.
class _Untraced extends StatelessWidget {
  const _Untraced({required this.sites, required this.tree});

  final List<Site> sites;
  final RouteTree? tree;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('untraced'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionTitle('Not traced'),
      Text(
        'These data.dart files return or select a provider of their own, so '
        'fespalier cannot see it: use the Riverpod DevTools tab for them.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      for (final s in sites)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Wrap(
            spacing: 8,
            children: [
              Mono('${tree?.appDir ?? ''}/${s.file}', selectable: false),
              if (s.route != null) Text(s.route!),
              if (s.section != null) Text('section ${s.section}'),
            ],
          ),
        ),
    ],
  );
}
