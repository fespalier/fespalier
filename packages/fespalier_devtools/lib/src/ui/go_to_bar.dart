/// The bar under the header: a location to go to, how to go, and which route it is.
library;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';

import '../controller.dart';
import '../protocol.dart';
import '../tree.dart';
import 'chips.dart';

/// A text field for a location, a `go | push | replace` choice, buttons to go, pop and match, and
/// the answer to the last match. Nothing is debounced: matching runs on the button.
class GoToBar extends StatefulWidget {
  /// A bar that acts on [controller]'s app.
  const GoToBar({super.key, required this.controller});

  /// The app it navigates.
  final FespalierController controller;

  @override
  State<GoToBar> createState() => _GoToBarState();
}

class _GoToBarState extends State<GoToBar> {
  final _text = TextEditingController();
  String _mode = NavigateMode.go;

  FespalierController get _controller => widget.controller;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _go() {
    final location = _text.text.trim();
    if (location.isEmpty) return;
    _controller.navigate(_mode, location);
  }

  void _match() {
    final location = _text.text.trim();
    if (location.isEmpty) return;
    _controller.matchLocation(location);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final error = _controller.actionError;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('goto-location'),
              controller: _text,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '/products/2?tab=info',
                labelText: 'Location',
              ),
              style: const TextStyle(fontFamily: 'monospace'),
              onSubmitted: (_) => _go(),
            ),
            const SizedBox(height: 4),
            // A Wrap, not a Row: the panel can be narrow, and a button that does not fit goes
            // to the next line.
            Wrap(
              spacing: denseSpacing,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  key: const Key('goto-mode'),
                  value: _mode,
                  isDense: true,
                  items: const [
                    DropdownMenuItem(
                      value: NavigateMode.go,
                      child: Text(NavigateMode.go),
                    ),
                    DropdownMenuItem(
                      value: NavigateMode.push,
                      child: Text(NavigateMode.push),
                    ),
                    DropdownMenuItem(
                      value: NavigateMode.replace,
                      child: Text(NavigateMode.replace),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _mode = value ?? NavigateMode.go),
                ),
                DevToolsButton(
                  key: const Key('goto-go'),
                  label: 'Go',
                  onPressed: _go,
                  elevated: true,
                ),
                DevToolsButton(
                  key: const Key('goto-pop'),
                  label: 'Pop',
                  onPressed: () => _controller.navigate(NavigateMode.pop),
                ),
                DevToolsButton(
                  key: const Key('goto-match'),
                  label: 'Match',
                  onPressed: _match,
                ),
              ],
            ),
            if (_controller.match != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  key: const Key('goto-match-result'),
                  children: [Flexible(child: _MatchResult(_controller))],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  error,
                  key: const Key('goto-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// `ProductRoute · products/$id/page.dart · id: 2 (int)`, or `no route matches (not found)`.
class _MatchResult extends StatelessWidget {
  const _MatchResult(this.controller);

  final FespalierController controller;

  @override
  Widget build(BuildContext context) {
    final match = controller.match!;
    return Mono(describeMatch(controller, match), selectable: true);
  }
}

/// What [match] says about its route in one line.
String describeMatch(FespalierController controller, MatchRecord match) {
  final route = match.route;
  if (route == null) return 'no route matches (not found)';
  final node = controller.tree?.routeByClass(route);
  final types = {
    for (final p in node?.params ?? const <TreeParam>[]) p.name: p.type,
  };
  final params = [
    for (final e in match.params.entries)
      '${e.key}: ${e.value.text} (${types[e.key] ?? e.value.type})',
  ];
  return [
    route,
    ?node?.file,
    if (params.isNotEmpty) params.join(', '),
  ].join(' · ');
}
