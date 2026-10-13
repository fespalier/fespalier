import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';
import 'package:maps/region.dart';

/// One offline region pack: download it, watch its progress, pause, resume, delete.
///
/// A region pack (MapLibre's own database) rather than a PMTiles file pack, because it needs no
/// server of ours, no file path and no `http` client: the style the map already uses says where
/// the tiles come from. The price: a download does not continue after the app is closed (a
/// file pack's does), which the status says as `Interrupted`.
class OfflinePage extends HookConsumerWidget {
  const OfflinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.read(tilePacks.notifier);
    final status = ref.watch(tilePackStatus(doualaPack.key));
    useEffect(() {
      // Once, when the page opens: what an earlier session left in the database.
      unawaited(packs.refresh());
      return null;
    }, const []);

    final (line, actions) = switch (status) {
      Absent() => (
        'Not on this device (about ${doualaPack.estimatedTiles} tiles)',
        [_button('Download', () => packs.start(doualaPack))],
      ),
      Downloading(:final progress) => (
        'Downloading ${(progress * 100).round()}%',
        [_button('Pause', () => packs.pause(doualaPack.key))],
      ),
      Paused(:final progress) => (
        'Paused at ${(progress * 100).round()}%',
        [_button('Resume', () => packs.resume(doualaPack.key))],
      ),
      Complete(:final bytes) => (
        'On this device (${bytes ~/ 1024} KB)',
        [_button('Delete', () => packs.remove(doualaPack.key))],
      ),
      // The app was closed while it downloaded: this starts the download again.
      Interrupted() => (
        'Interrupted',
        [
          _button('Download again', () => packs.resume(doualaPack.key)),
          _button('Delete', () => packs.remove(doualaPack.key)),
        ],
      ),
      Failed(:final reason) => (
        'Failed: ${reason.name}',
        [_button('Try again', () => packs.resume(doualaPack.key))],
      ),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Offline map')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Douala'),
          if (status
              case Downloading(:final progress) || Paused(:final progress))
            LinearProgressIndicator(value: progress),
          Text(line),
          ...actions,
        ],
      ),
    );
  }

  Widget _button(String label, Future<void> Function() onPressed) =>
      TextButton(onPressed: () => unawaited(onPressed()), child: Text(label));
}
