/// What the adapter packages show (since 0.16.0): one card for each package that called
/// `DevToolsAdapters.show`, with its values, and a field and a button for the ones the package lets
/// a developer set (the local override of a flag, a notification to simulate).
library;

import 'dart:async';

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import 'chips.dart';

/// What the panel says when no adapter has shown anything.
const String noAdaptersText =
    'No adapter has shown anything yet. An adapter can list its state here '
    'with DevToolsAdapters.show (since 0.16.0); none of the packages in this '
    'repository does yet.';

/// The seventh tab.
class AdaptersPanel extends StatelessWidget {
  /// The panel for [controller]'s app.
  const AdaptersPanel({super.key, required this.controller});

  /// The app.
  final FespalierController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.supports(DevToolsFeatures.adapters)) {
        return const NotReported('adapters');
      }
      final all = controller.snapshot?.adapters ?? const <AdapterRecord>[];
      if (all.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              noAdaptersText,
              key: Key('no-adapters'),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          for (final a in all)
            AdapterCard(
              key: Key('adapter-${a.adapter}'),
              record: a,
              refreshedAt: controller.refreshedAt,
              onSet: (key, text) =>
                  controller.adapterEdit(a.adapter, key, text),
            ),
        ],
      );
    },
  );
}

/// One adapter: its name, when it last showed, and its values.
class AdapterCard extends StatelessWidget {
  /// A card for [record]. [onSet] sets one of its editable keys, answering why it could not (null
  /// when it could). [refreshedAt] is what the age of the record is counted to.
  const AdapterCard({
    super.key,
    required this.record,
    required this.onSet,
    this.refreshedAt,
  });

  /// What the adapter shows.
  final AdapterRecord record;

  /// Sets an editable key to a text; the answer is the reason it failed, or null.
  final Future<String?> Function(String key, String text) onSet;

  /// When the state was last fetched.
  final DateTime? refreshedAt;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final shown = DateTime.fromMillisecondsSinceEpoch(record.at);
    final age = refreshedAt?.difference(shown);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  record.title ?? record.adapter,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (record.title != null)
                  Mono(record.adapter, selectable: false),
                Text(
                  'updated ${formatClock(record.at)}'
                  '${age == null ? '' : ' (${formatAge(age)} before the last refresh)'}',
                  style: style,
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (record.values.isEmpty) Text('No values.', style: style),
            for (final v in record.values)
              _ValueRow(
                key: Key('value-${record.adapter}-${v.key}'),
                adapter: record.adapter,
                value: v,
                onSet: onSet,
              ),
            if (record.truncated)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'The adapter gave more values than the app keeps: only the '
                  'first ${record.values.length} are shown.',
                  key: Key('truncated-${record.adapter}'),
                  style: style,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One key: its name, its value and type, and for an editable key a field and a **Set** button.
class _ValueRow extends StatefulWidget {
  const _ValueRow({
    super.key,
    required this.adapter,
    required this.value,
    required this.onSet,
  });

  final String adapter;
  final AdapterValueRecord value;
  final Future<String?> Function(String key, String text) onSet;

  @override
  State<_ValueRow> createState() => _ValueRowState();
}

class _ValueRowState extends State<_ValueRow> {
  late final TextEditingController _text = TextEditingController(
    text: _startText(widget.value),
  );
  var _setting = false;

  /// What the field starts with: the value's text, unless it was cut (the whole is not known) or
  /// is the text of a `null`.
  static String _startText(AdapterValueRecord v) {
    final shown = v.value;
    if (shown.type == 'Null') return '';
    if (shown.text.length > shownTextLimit) return '';
    return shown.text;
  }

  @override
  void didUpdateWidget(_ValueRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The app shows another value: the field follows it, unless the developer is typing.
    if (oldWidget.value.value != widget.value.value &&
        _text.text == _startText(oldWidget.value)) {
      _text.text = _startText(widget.value);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _set() async {
    setState(() => _setting = true);
    final reason = await widget.onSet(widget.value.key, _text.text);
    if (!mounted) return;
    setState(() => _setting = false);
    if (reason != null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(reason)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Mono(v.key, bold: true, selectable: false),
          KindChip(v.value.type),
          SelectableText(
            v.value.text,
            key: Key('text-${widget.adapter}-${v.key}'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (v.editable) ...[
            SizedBox(
              width: 180,
              child: TextField(
                key: Key('edit-${widget.adapter}-${v.key}'),
                controller: _text,
                style: Theme.of(context).textTheme.bodySmall,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'new value',
                ),
                onSubmitted: (_) {
                  if (!_setting) unawaited(_set());
                },
              ),
            ),
            DevToolsButton(
              key: Key('set-${widget.adapter}-${v.key}'),
              label: 'Set',
              tooltip: "Calls the adapter's onEdit with this text",
              onPressed: _setting ? null : () => unawaited(_set()),
            ),
          ],
        ],
      ),
    );
  }
}
