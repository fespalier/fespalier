/// The providers of the `data.dart` files: each one's state (loading, data, error), how often it
/// was built, when, and what it holds, with a button to build it again and, since 0.8.1, one that
/// lists who holds it.
library;

import 'dart:async';

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
      // The app's own providers, seen only once a page, a section or a preload watched them.
      final watched = {for (final d in all) d.site};
      final untraced = [
        for (final s in tree?.sites.values ?? const <Site>[])
          if (s.kind == 'data' && !s.traced && !watched.contains(s.id)) s,
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
                    loadHolders: _controller.supports(DevToolsFeatures.holders)
                        ? () => _controller.holders(d.id)
                        : null,
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

/// One provider: its file and route, state, builds (or, for the app's own provider, which one),
/// listeners, times and value; with a button that lists who holds it.
class DataRecordRow extends StatefulWidget {
  /// A row for [record], whose `data.dart` is [site] in the tree (null when it is not there).
  /// [refreshedAt] is what the age of the last change is counted to. [loadHolders] asks the app
  /// who holds the provider; without it (an app older than 0.8.1) there is no Holders button.
  const DataRecordRow({
    super.key,
    required this.record,
    this.site,
    this.refreshedAt,
    required this.onInvalidate,
    this.loadHolders,
  });

  /// The provider.
  final DataRecord record;

  /// The `data.dart`'s place in the tree.
  final Site? site;

  /// When the state was last fetched.
  final DateTime? refreshedAt;

  /// Builds the provider again.
  final VoidCallback onInvalidate;

  /// Asks who holds the provider now; null when the app cannot say.
  final Future<HoldersRecord?> Function()? loadHolders;

  @override
  State<DataRecordRow> createState() => _DataRecordRowState();
}

class _DataRecordRowState extends State<DataRecordRow> {
  var _open = false;
  HoldersRecord? _holders;
  var _asked = 0;

  Future<void> _fetch() async {
    final load = widget.loadHolders;
    if (load == null) return;
    final ask = ++_asked;
    final answer = await load();
    // A later question, or a row that is gone, makes this answer stale.
    if (!mounted || ask != _asked) return;
    setState(() => _holders = answer);
  }

  @override
  void didUpdateWidget(DataRecordRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list stays right while it is open: it is asked again at each refresh and each change.
    if (_open &&
        (oldWidget.refreshedAt != widget.refreshedAt ||
            oldWidget.record != widget.record)) {
      unawaited(_fetch());
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final style = Theme.of(context).textTheme.bodySmall;
    final site = widget.site;
    final updated = DateTime.fromMillisecondsSinceEpoch(record.updated);
    final age = widget.refreshedAt?.difference(updated);
    final label = site == null
        ? record.site
        : site.section != null
        ? '${site.file} (section ${site.section})'
        : site.file;
    final own = record.via == DataVia.watch;
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
              if (own)
                const KindChip('app provider')
              else
                Text('builds ${record.builds}', style: style),
              if (record.listeners != null)
                Text('listeners ${record.listeners}', style: style),
              DevToolsButton(
                key: Key('invalidate-${record.id}'),
                label: 'Invalidate',
                tooltip: own
                    ? "Invalidate this provider (the app's own)"
                    : 'Build this provider again',
                onPressed: record.state == DataState.disposed
                    ? null
                    : widget.onInvalidate,
              ),
              if (widget.loadHolders != null)
                DevToolsButton(
                  key: Key('holders-${record.id}'),
                  label: 'Holders',
                  tooltip: 'Who keeps this provider alive',
                  onPressed: () {
                    setState(() {
                      _open = !_open;
                      if (!_open) _holders = null;
                    });
                    if (_open) unawaited(_fetch());
                  },
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                if (own && record.provider != null)
                  Mono(record.provider!.text, selectable: false),
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
          if (_open && _holders != null)
            Padding(
              key: Key('holders-list-${record.id}'),
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in holderLines(record, _holders!))
                    Text(line, style: style),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The lines the Holders button lists for [record] and what the app answered.
List<String> holderLines(DataRecord record, HoldersRecord answer) {
  if (!answer.found) return const ['This provider is no longer tracked.'];
  String kept(int? keepFor) {
    if (keepFor == null) return 'kept until closed';
    final seconds = keepFor % 1000 == 0
        ? '${keepFor ~/ 1000}'
        : (keepFor / 1000).toStringAsFixed(1);
    return 'kept $seconds s';
  }

  return [
    for (final h in answer.holders)
      switch (h.kind) {
        HolderKind.view => 'page view (since ${formatClock(h.since)})',
        HolderKind.section => 'section view (since ${formatClock(h.since)})',
        HolderKind.prefetch => 'prefetch handle, ${kept(h.keepFor)}',
        HolderKind.link => 'RouteLink preload, ${kept(h.keepFor)}',
        _ => '${h.kind} (since ${formatClock(h.since)})',
      },
    if ((answer.others ?? 0) > 0)
      '${answer.others} other listener${answer.others == 1 ? '' : 's'}: '
          'ref.watch or listen in your code, or another provider',
    if (record.via == DataVia.watch)
      "Other listeners of an app provider are not visible here: see Riverpod's DevTools tab",
    if (answer.alive == false) 'disposed',
  ];
}

/// The `data.dart` files that return or select a provider of their own and that no page, section
/// or preload has watched yet: fespalier follows it from then on.
class _Untraced extends StatelessWidget {
  const _Untraced({required this.sites, required this.tree});

  final List<Site> sites;
  final RouteTree? tree;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('untraced'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionTitle('Not watched yet'),
      Text(
        'These data.dart files return or select a provider of their own. '
        'fespalier follows it once a page, a section or a preload watches it; '
        "until then, see Riverpod's DevTools tab.",
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
