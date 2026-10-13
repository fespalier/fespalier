import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

import '../providers.dart';
import '../translator.dart';
import 'editor.dart';

/// The keys read since the last location change, for the panel. Debug only.
final class KeyRecorder {
  /// The keys, in the order first read.
  final keys = <String>{};

  /// Remembers that [key] was read.
  void record(String key) => keys.add(key);
}

/// A small handle over [child] that opens a panel of the keys read on this screen, with each
/// value and its origin, and a field to edit it. A save goes to the [translationEditor] and into
/// the edited layer at once, so it does not wait for the CDN. No timer, no frame callback.
class InContextHost extends ConsumerStatefulWidget {
  /// The panel for [translator]'s [locale], over [child].
  const InContextHost({
    super.key,
    required this.locale,
    required this.translator,
    required this.recorder,
    required this.child,
  });

  /// The locale tag shown.
  final String locale;

  /// What the keys are read from.
  final Translator translator;

  /// The keys read.
  final KeyRecorder recorder;

  /// The app.
  final Widget child;

  @override
  ConsumerState<InContextHost> createState() => _InContextHostState();
}

class _InContextHostState extends ConsumerState<InContextHost> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    return _HostScope(
      open: _open,
      locale: widget.locale,
      translator: widget.translator,
      keys: widget.recorder.keys.toList(),
      toggle: () => setState(() => _open = !_open),
      child: Stack(
        textDirection: TextDirection.ltr,
        children: [
          widget.child,
          Positioned.fill(
            child: Overlay(
              initialEntries: [
                // The entry's builder only runs again when what it depends on changes, so it
                // reads everything from _HostScope.
                OverlayEntry(builder: (context) => const _Handle()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostScope extends InheritedWidget {
  const _HostScope({
    required this.open,
    required this.locale,
    required this.translator,
    required this.keys,
    required this.toggle,
    required super.child,
  });

  final bool open;
  final String locale;
  final Translator translator;
  final List<String> keys;
  final VoidCallback toggle;

  static _HostScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HostScope>()!;

  @override
  bool updateShouldNotify(_HostScope oldWidget) => true;
}

class _Handle extends StatelessWidget {
  const _Handle();

  @override
  Widget build(BuildContext context) {
    final host = _HostScope.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (host.open)
              _Panel(
                locale: host.locale,
                translator: host.translator,
                keys: host.keys,
              ),
            IconButton.filled(
              key: const ValueKey('fespalier_tolgee.handle'),
              tooltip: 'Translations on this screen',
              icon: const Icon(Icons.translate),
              onPressed: host.toggle,
            ),
          ],
        ),
      ),
    );
  }
}

class _Panel extends ConsumerWidget {
  const _Panel({
    required this.locale,
    required this.translator,
    required this.keys,
  });

  final String locale;
  final Translator translator;
  final List<String> keys;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editor = ref.watch(translationEditor);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 360),
      child: Card(
        child: keys.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No translation key was read on this screen.'),
              )
            : ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(8),
                children: [
                  if (editor == null)
                    const Text('Read only: no Tolgee API key was defined.'),
                  for (final key in keys)
                    _KeyRow(
                      locale: locale,
                      translationKey: key,
                      translator: translator,
                      editor: editor,
                    ),
                ],
              ),
      ),
    );
  }
}

class _KeyRow extends ConsumerStatefulWidget {
  const _KeyRow({
    required this.locale,
    required this.translationKey,
    required this.translator,
    required this.editor,
  });

  final String locale;
  final String translationKey;
  final Translator translator;
  final TranslationEditor? editor;

  @override
  ConsumerState<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends ConsumerState<_KeyRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.translator.messageOf(widget.translationKey) ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final editor = widget.editor;
    if (editor == null) return;
    final text = _controller.text;
    try {
      await editor.save(widget.translationKey, widget.locale, text);
      if (!mounted) return;
      ref
          .read(translationEdits.notifier)
          .set(widget.locale, widget.translationKey, text);
      setState(() => _error = null);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final origin = widget.translator.originOf(widget.translationKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.translationKey} (${origin.name})',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey(
                    'fespalier_tolgee.field.${widget.translationKey}',
                  ),
                  controller: _controller,
                  enabled: widget.editor != null,
                ),
              ),
              IconButton(
                key: ValueKey('fespalier_tolgee.save.${widget.translationKey}'),
                tooltip: 'Save',
                icon: const Icon(Icons.check),
                onPressed: widget.editor == null ? null : _save,
              ),
            ],
          ),
          if (_error != null) Text(_error!),
        ],
      ),
    );
  }
}
