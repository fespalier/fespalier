/// Small pieces the panels share: chips, monospace text, a section heading, a key and value row.
library;

import 'package:flutter/material.dart';

/// How loud a [KindChip] is.
enum ChipTone {
  /// Plain: a marker, a kind.
  neutral,

  /// What is current, or what moved.
  accent,

  /// Something to look at: a replace, a refresh.
  warning,

  /// Something went wrong.
  error,
}

/// A small rounded label: a navigation's kind, a route's marker, a frame's type.
class KindChip extends StatelessWidget {
  /// A chip that reads [label].
  const KindChip(this.label, {super.key, this.tone = ChipTone.neutral});

  /// What it says.
  final String label;

  /// How loud it is.
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      ChipTone.neutral => (colors.surfaceContainerHighest, colors.onSurface),
      ChipTone.accent => (colors.primaryContainer, colors.onPrimaryContainer),
      ChipTone.warning => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      ChipTone.error => (colors.errorContainer, colors.onErrorContainer),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: foreground),
        ),
      ),
    );
  }
}

/// Text in the monospace face: paths, files, locations.
class Mono extends StatelessWidget {
  /// Monospace [text], selectable unless [selectable] is off.
  const Mono(this.text, {super.key, this.bold = false, this.selectable = true});

  /// What it says.
  final String text;

  /// Heavier weight.
  final bool bold;

  /// Whether it can be selected and copied.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
      fontWeight: bold ? FontWeight.w600 : null,
    );
    return selectable
        ? SelectableText(text, style: style)
        : Text(text, style: style);
  }
}

/// A heading above a block of a panel.
class SectionTitle extends StatelessWidget {
  /// A heading that reads [text].
  const SectionTitle(this.text, {super.key});

  /// What it says.
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// A label and what it says, in a row: `file  products/$id/page.dart`.
class LabeledRow extends StatelessWidget {
  /// A row of [label] and [child].
  const LabeledRow(this.label, this.child, {super.key});

  /// The label, in the margin.
  final String label;

  /// What it says.
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

/// `hh:mm:ss.mmm`, in local time, for a time in milliseconds since the epoch.
String formatClock(int millisecondsSinceEpoch) {
  final t = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}
