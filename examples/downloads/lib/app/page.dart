import 'package:downloads/app.g.dart';
import 'package:downloads/cases.dart';
import 'package:downloads/widgets.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:flutter/material.dart';

/// The downloads: one card per case a device tester tries, each with the buttons that make sense
/// for where it stands, and the sign-out that wipes them all.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watching `downloads` opens the engine (what a restart left is settled) and rebuilds on
    // every change.
    final all = ref.watch(downloads);
    final known = {for (final c in demoCases) c.id};
    final others = [
      for (final id in all.keys)
        if (!known.contains(id)) id,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final c in demoCases) _Card(id: c.id, demo: c),
          for (final id in others) _Card(id: id),
          const SizedBox(height: 16),
          const Text(
            'Sign-out wipes every download of the account, files included '
            '(Downloads.clearAccount).',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const ValueKey('sign-out'),
              onPressed: () => ref.read(downloadsEngine).clearAccount(),
              child: const Text('Sign out (clear all)'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card({required this.id, this.demo});

  final String id;
  final DemoCase? demo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(downloadStatus(id));
    final progress = progressOf(status);
    final running = status is Running || status is Paused;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              demo?.title ?? id,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (demo != null) Text(demo!.help),
            const SizedBox(height: 8),
            Text(describe(status), key: ValueKey('status-$id')),
            if (running) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
            ],
            const SizedBox(height: 8),
            DownloadButtons(id: id, demo: demo),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: ValueKey('details-$id'),
                onPressed: () => FileRoute(id: id).push<void>(context),
                child: const Text('Details'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
