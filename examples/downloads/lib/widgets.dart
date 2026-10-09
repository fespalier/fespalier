import 'package:downloads/cases.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:flutter/material.dart';

/// A size as people read it: `3.5 MB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${units[unit]}';
}

/// Where a download stands, in words a tester can put in a report. The names are the package's
/// own (`Failed (hashMismatch)`), so a report and the docs agree.
String describe(DownloadStatus status) => switch (status) {
  Absent() => 'Not started',
  Queued() => 'Queued',
  Waiting(:final reason) => 'Waiting (${reason.name})',
  Running(:final received, :final total) =>
    total == null
        ? 'Running: ${formatBytes(received)}'
        : 'Running: ${formatBytes(received)} of ${formatBytes(total)} '
              '(${total == 0 ? 0 : (received * 100 ~/ total)}%)',
  Paused(:final received, :final total) =>
    total == null
        ? 'Paused: ${formatBytes(received)}'
        : 'Paused: ${formatBytes(received)} of ${formatBytes(total)}',
  Verifying() => 'Verifying size and SHA-256',
  Complete(:final bytes) => 'Complete: ${formatBytes(bytes)}, checked',
  Failed(:final failure) => 'Failed (${failure.name})',
  Cancelled() => 'Cancelled',
};

/// The progress of [status] from 0 to 1, null when it is not known or not running.
double? progressOf(DownloadStatus status) => switch (status) {
  Running(:final received, :final total) ||
  Paused(
    :final received,
    :final total,
  ) => total == null || total == 0 ? null : (received / total).clamp(0.0, 1.0),
  Complete() => 1,
  _ => null,
};

/// The buttons that make sense for [status], one per action of the engine: start, pause, resume,
/// retry, cancel and remove. Each has a key `<action>-<id>`.
class DownloadButtons extends ConsumerWidget {
  const DownloadButtons({super.key, required this.id, this.demo});

  /// The download.
  final String id;

  /// The case a Start button begins; null for a download the registry kept from another run.
  final DemoCase? demo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(downloadStatus(id));
    final engine = ref.read(downloadsEngine);
    final case_ = demo;

    Widget button(String action, String label, VoidCallback? onPressed) =>
        OutlinedButton(
          key: ValueKey('$action-$id'),
          onPressed: onPressed,
          child: Text(label),
        );

    final buttons = switch (status) {
      Absent() || Cancelled() => [
        button(
          'start',
          'Start',
          case_ == null ? null : () => engine.start(case_.request),
        ),
      ],
      Queued() || Waiting() || Running() => [
        button('pause', 'Pause', () => engine.pause(id)),
        button('cancel', 'Cancel', () => engine.cancel(id)),
      ],
      Paused() => [
        button('resume', 'Resume', () => engine.resume(id)),
        button('cancel', 'Cancel', () => engine.cancel(id)),
      ],
      Verifying() => <Widget>[],
      Complete() => [button('remove', 'Remove', () => engine.remove(id))],
      Failed() => [
        button('retry', 'Retry', () => engine.retry(id)),
        button('remove', 'Remove', () => engine.remove(id)),
      ],
    };
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}
