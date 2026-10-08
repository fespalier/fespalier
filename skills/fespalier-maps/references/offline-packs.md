# Offline region packs, end to end

Since 0.13.0 (`package:fespalier_maps`). A pack is a MapLibre **region**: a rectangle, a style and a zoom range, downloaded
into MapLibre's offline database and drawn from it when the network is gone. `TilePacks` (the Riverpod notifier
`tilePacks`) holds one `PackStatus` per key; `RegionPackRequest` says what to download; `OfflineTiles` is the port over
the database, `MapLibreOfflineTiles` the real one and `FakeOfflineTiles` the test one.

**A MapLibre download does not resume across an app restart.** Pause and resume work while the app stays alive. After a
restart a half-done region is `Interrupted`; `resume` then downloads the same definition again (MapLibre replaces the
old region when that download begins; resources it already stored may or may not be reused: not verified on a
device). PMTiles file packs, resumable over HTTP Range, are the later release that fixes this.

## Choose a region and size it

`RegionPackRequest.estimatedTiles` counts the Web Mercator tiles under the rectangle on the whole zoom levels
(`tileCount`), so a screen can show the size of a choice before anything is fetched. It counts tiles only, not glyphs,
sprites or bytes. `isValid` is false for an empty key or style, a zoom range out of order or above 22, a south edge
north of the north edge, and a rectangle that crosses the antimeridian (split it in two packs).

```dart
// lib/offline/douala.dart
import 'package:fespalier_maps/fespalier_maps.dart';

/// The pack the app offers. The key is yours, and is stored with the region: it never reaches telemetry.
const doualaPack = RegionPackRequest(
  key: 'douala',
  bounds: GeoBounds(GeoPoint(3.98, 9.62), GeoPoint(4.14, 9.85)),
  styleUrl: 'https://tiles.example.com/style.json',
  minZoom: 10,
  maxZoom: 14,
);
```

## Wire the database

`offlineTiles` has no default: override it with the MapLibre one, once, in the `ProviderScope`. The size of the database
file is read through `getOfflineDatabasePath` (the file only; null on the web), so there is nothing to pass.
`MapLibreOfflineTiles` is `const` and takes no arguments.

```dart
// lib/offline/overrides.dart
import 'package:fespalier_maps/maplibre.dart';

/// The app's offline database: `offlineTiles.overrideWithValue(offlineDatabase)` in its ProviderScope.
const offlineDatabase = MapLibreOfflineTiles();
```

## The page

`ref.watch(tilePackStatus(key))` is one pack's status (`Absent` while there is none) and rebuilds when it changes. Call
`refresh()` once when the page opens (or at startup) to learn what an earlier session stored: nothing is read before. Every
call on `tilePacks.notifier` is safe to fire from a button: `pause` and `resume` never throw, `start` reports a failure as
`Failed(reason)`, and `remove` throws only if the database refuses (and marks the pack `Failed`).

```dart
// lib/app/offline-maps/page.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';
import 'package:my_app/offline/douala.dart';

/// -> /offline-maps
class OfflineMapsPage extends HookConsumerWidget {
  const OfflineMapsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.read(tilePacks.notifier);
    final status = ref.watch(tilePackStatus(doualaPack.key));
    useEffect(() {
      unawaited(packs.refresh());
      return null;
    }, const []);

    final (line, actions) = switch (status) {
      Absent() => (
        'Not on this device (about ${doualaPack.estimatedTiles} tiles)',
        [TextButton(onPressed: () => packs.start(doualaPack), child: const Text('Download'))],
      ),
      Downloading(:final progress) => (
        'Downloading ${(progress * 100).round()}%',
        [TextButton(onPressed: () => packs.pause(doualaPack.key), child: const Text('Pause'))],
      ),
      Paused(:final progress) => (
        'Paused at ${(progress * 100).round()}%',
        [TextButton(onPressed: () => packs.resume(doualaPack.key), child: const Text('Resume'))],
      ),
      Complete(:final bytes) => (
        'On this device (${bytes ~/ 1024} KB)',
        [TextButton(onPressed: () => packs.remove(doualaPack.key), child: const Text('Delete'))],
      ),
      // The app was closed while it downloaded: this starts it again, it does not continue it.
      Interrupted() => (
        'Interrupted',
        [
          TextButton(onPressed: () => packs.resume(doualaPack.key), child: const Text('Download again')),
          TextButton(onPressed: () => packs.remove(doualaPack.key), child: const Text('Delete')),
        ],
      ),
      Failed(:final reason) => (
        'Failed: ${reason.name}',
        [TextButton(onPressed: () => packs.resume(doualaPack.key), child: const Text('Try again'))],
      ),
    };
    return Scaffold(
      body: SafeArea(
        child: Column(children: [Text(line), ...actions]),
      ),
    );
  }
}
```

A `PackFailure` is a value, never platform text: `unsupported` (the web, or no plugin), `invalidRegion`, `limitExceeded`, `duplicateRegion` (another key has the same style, rectangle and zoom range: MapLibre would delete its region), `replaced`
(MapLibre's tile limit; on Android it also deletes the region) and `other`.

## Storage

`ref.read(tilePacks.notifier).storage()` answers a `StorageUse`: `perPack` (bytes by key, from the statuses, which
`refresh` fills for packs of earlier sessions), `packSum`, and `onDisk` (the database file). **The per-pack
bytes overlap**: a glyph range or an edge tile two packs share is counted in each, so `packSum` can exceed `onDisk`, and
`onDisk` also holds MapLibre's ambient cache. Show `perPack` per row and `onDisk` as the total; do not add the rows up as
if they were the file.

## Test it

`FakeOfflineTiles` is the database in memory, and the test plays MapLibre: `progress(key, fraction, ...)`, `finish(key)`,
`fail(key, reason)`. `seed(request, complete: ...)` puts a region there as an earlier session left it, `restart()` plays the
app being reopened (old downloads are no longer tracked, so `resume` of one throws, as MapLibre's does), and
`holdDownloads` / `releaseDownloads()` order a download's events before its future. `pauses`, `resumes`, `deleted` and
`downloads` say what the packs asked for.

```dart
// test/offline_packs_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app/offline-maps/page.dart';
import 'package:my_app/offline/douala.dart';

void main() {
  testWidgets('download, pause, resume and finish show in the page', (tester) async {
    final tiles = FakeOfflineTiles();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [offlineTiles.overrideWithValue(tiles)],
        child: const MaterialApp(home: OfflineMapsPage()),
      ),
    );
    expect(find.textContaining('Not on this device'), findsOneWidget);

    await tester.tap(find.text('Download'));
    await tester.pump();
    tiles.progress(doualaPack.key, 0.4, completedResources: 40, requiredResources: 100, bytes: 2048);
    await tester.pump();
    expect(find.text('Downloading 40%'), findsOneWidget);

    await tester.tap(find.text('Pause'));
    await tester.pump();
    expect(find.text('Paused at 40%'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pump();

    tiles.finish(doualaPack.key, bytes: 4096);
    await tester.pump();
    await tester.pump();
    expect(find.text('On this device (4 KB)'), findsOneWidget);
  });

  test('a pack from an earlier session is interrupted, and resume downloads it again', () async {
    final tiles = FakeOfflineTiles(databaseSize: 10000);
    final old = tiles.seed(doualaPack, complete: false, progress: 0.3, bytes: 500);
    final container = ProviderContainer(overrides: [offlineTiles.overrideWithValue(tiles)]);
    addTearDown(container.dispose);
    final packs = container.read(tilePacks.notifier);

    await packs.refresh();
    expect(container.read(tilePackStatus(doualaPack.key)), const Interrupted(progress: 0.3, bytes: 500));

    await packs.resume(doualaPack.key);
    tiles.finish(doualaPack.key, bytes: 900);
    await pumpEventQueue();
    expect(container.read(tilePackStatus(doualaPack.key)), const Complete(bytes: 900));
    expect(tiles.deleted, [old.id]);
    expect((await packs.storage()).onDisk, 10000);
  });
}
```
