# File packs (PMTiles), end to end

Since 0.13.0 (`package:fespalier_maps`). A file pack is **one file** (a PMTiles archive) downloaded over HTTP into a
directory the app owns. Unlike a MapLibre region, **it resumes after the app was closed**: the bytes arrive in
`<destination>.part`, a transfer that stops leaves them, and the next attempt asks the server for the rest with
`Range: bytes=<size>-`. The file is moved to its destination only when it has the size and the SHA-256 the request names.
`FilePacks` (the notifier `filePacks`) holds one `PackStatus` per key, the same values as region packs.

Three seams, all provided by the app: an `http.Client` (`packHttpClient`, **no default**), the directory (you pass a path in
the request: the package depends on no `path_provider`), and, only in tests, the files (`packFileStore`, default `dart:io`,
`FakePackFiles` in `testing.dart`). On the web there are no files: a download ends `Failed(unsupported)` before any request.

## The request

`FilePackRequest(key:, url:, destination:, sha256:, bytes:, headers:)`. `destination` is a full path in a directory your app
owns (its application-support directory); it is a `String`, not a `File`, so the library compiles for the web. Give `bytes`
and `sha256` whenever the server's release notes or a manifest say them: `bytes` makes progress start at the first byte and
catches a wrong file before the transfer ends, `sha256` is the integrity check (hex, either case; a large file is hashed after
its last byte, which takes a moment). Two packs must not share a destination (`Failed(invalidRequest)`).

```dart
// lib/offline/douala_file.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';

/// The directory the app got at startup (`getApplicationSupportDirectory` from `path_provider`, or your own channel),
/// provided once in `startup()` or the `ProviderScope`: `supportDirectory.overrideWithValue(dir.path)`.
final supportDirectory = Provider<String>(
  (ref) => throw StateError('override supportDirectory with the app support directory'),
);

/// The pack the app offers. The key is yours; it never reaches telemetry.
FilePackRequest doualaFilePack(String supportDirectory) => FilePackRequest(
  key: 'douala',
  url: Uri.parse('https://tiles.example.com/douala-2026-10.pmtiles'),
  destination: '$supportDirectory/packs/douala.pmtiles',
  bytes: 48213377,
  sha256: 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12',
);
```

## Wire the client

`packHttpClient` has no default: override it once with the client the app already has (its timeouts, proxy and
certificates apply to the download). The package never closes it. `start` without the override throws a
`StateError` that says so.

```yaml
# pubspec.yaml dependencies
  http: ">=1.2.0 <2.0.0"
  crypto: ">=3.0.6 <4.0.0"
```

(`crypto` is only for the test below, which hashes its fake body; the package brings its own.)

```dart
// lib/offline/file_scope.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:my_app/offline/douala_file.dart';

/// The app's `ProviderScope`: its own client for the downloads, and the directory it chose for the files.
Widget fileScope({required http.Client client, required String directory, required Widget child}) => ProviderScope(
  overrides: [
    packHttpClient.overrideWithValue(client),
    supportDirectory.overrideWithValue(directory),
  ],
  child: child,
);
```

## Draw from the file

The finished file is an archive MapLibre reads directly: a vector source whose `url` is `pmtilesSourceUrl(path)`
(`pmtiles://file:///.../douala.pmtiles`). `maplibre_gl` 0.27.1 lists PMTiles sources on Android, iOS and the web, and
bundles MapLibre Native Android 13.5 and iOS 6.28 (PMTiles support came with 11.7 and 6.10); the app's own style JSON names
the source, the layers and the archive's `source-layer`s. An archive holds **tiles only**: the style's `glyphs` and
`sprite` must also be reachable offline (bundled with the app, or in a region pack) or labels do not draw. Whether a
`pmtiles://file://` source draws on a given device was not checked by any CI job here: a device run is the check.

```dart
// lib/offline/pack_style.dart
import 'dart:convert';

import 'package:fespalier_maps/fespalier_maps.dart';

/// The style JSON for `MapLibreSurface(styleString: ...)`, drawing from the local archive. The layers are the app's.
String packStyle(String archivePath) => jsonEncode({
  'version': 8,
  'sources': {
    'basemap': {'type': 'vector', 'url': pmtilesSourceUrl(archivePath)},
  },
  'layers': [
    {'id': 'background', 'type': 'background', 'paint': {'background-color': '#f2efe9'}},
    {
      'id': 'water',
      'type': 'fill',
      'source': 'basemap',
      'source-layer': 'water',
      'paint': {'fill-color': '#a0c8f0'},
    },
  ],
});
```

## The page

`ref.watch(filePackStatus(key))` is one pack's status. Call `refresh([request])` once when the page opens: **disk is the
state of record**, and the notifier cannot find a pack without its request, so you pass the requests you offer. A file at
the destination is `Complete`; a `.part` file is `Interrupted` with its bytes and (when the request names a size) its
progress; `resume` then **continues from the byte** (say "Resume", unlike a region pack's "Download again"). `start` and
`resume` return when the transfer **stops** (complete, failed, paused or removed), so do not `await` them in a handler that
must stay responsive; the state is what the page watches.

```dart
// lib/app/offline-files/page.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';
import 'package:my_app/offline/douala_file.dart';

/// -> /offline-files
class OfflineFilesPage extends HookConsumerWidget {
  const OfflineFilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = doualaFilePack(ref.watch(supportDirectory));
    final packs = ref.read(filePacks.notifier);
    final status = ref.watch(filePackStatus(request.key));
    useEffect(() {
      unawaited(packs.refresh([request]));
      return null;
    }, const []);

    final (line, actions) = switch (status) {
      Absent() => (
        'Not on this device',
        [TextButton(onPressed: () => unawaited(packs.start(request)), child: const Text('Download'))],
      ),
      Downloading(:final progress) => (
        'Downloading ${(progress * 100).round()}%',
        [TextButton(onPressed: () => unawaited(packs.pause(request.key)), child: const Text('Pause'))],
      ),
      Paused(:final progress) => (
        'Paused at ${(progress * 100).round()}%',
        [TextButton(onPressed: () => unawaited(packs.resume(request.key)), child: const Text('Resume'))],
      ),
      Complete(:final bytes) => (
        'On this device (${bytes ~/ 1024} KB)',
        [TextButton(onPressed: () => unawaited(packs.remove(request.key)), child: const Text('Delete'))],
      ),
      // The app was closed during the transfer: the file is on disk, and this goes on from its last byte.
      Interrupted(:final bytes) => (
        'Stopped at ${bytes ~/ 1024} KB',
        [
          TextButton(onPressed: () => unawaited(packs.resume(request.key)), child: const Text('Resume')),
          TextButton(onPressed: () => unawaited(packs.remove(request.key)), child: const Text('Delete')),
        ],
      ),
      Failed(:final reason) => (
        'Failed: ${reason.name}',
        [TextButton(onPressed: () => unawaited(packs.resume(request.key)), child: const Text('Try again'))],
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

A `PackFailure` is a value, never text from the server or the device. The ones a file pack ends in: `network` (no connection,
a dropped connection, a short body: the partial file stays and `resume` continues), `rejected` (any status but 200 or 206: a
404, a 403, a 5xx, a 416 that a restart from the first byte did not cure), `sizeMismatch` and `hashMismatch` (the partial
file is **deleted**: it is not the file the app expects), `storage` (the device refused to write), `invalidRequest`
(an empty key, a URL that is not `http` or `https`, a hash that is not 64 hex digits, a destination another key uses) and
`unsupported` (the web).

## What the server must do

Resuming needs a server that honours `Range` (static hosting and CDNs do; most object stores do). One that does not is not
an error: it answers 200 with the whole body and the transfer **starts again from the first byte**. The package sends
`If-Range` with the `ETag` (or `Last-Modified`) it saw, so a file replaced on the server is fetched whole instead of being
glued onto the old bytes, and `Accept-Encoding: identity`, because a byte offset counts the bytes on the wire. A 416 to a
partial file that is longer than the server's file gets one restart from zero. To publish a newer archive, change its
URL and the pack's `destination`, or `remove` the pack first: a file already at the destination is taken as `Complete`
without a request.

## Storage

`storage()` answers a `StorageUse`: `perPack` (the bytes of each pack, from the state) and `onDisk`, the sum of the finished
and partial files of the packs this session knows. File packs do not overlap, so unlike region packs **the rows add up to
`onDisk`**. `remove(key)` stops a running transfer, waits until it has closed its file, then deletes the finished file, the
partial file and the validator.

## Test it

`FakePackFiles` is the files in memory and `MockClient.streaming` (`package:http/testing.dart`) the server. Seed a partial
file with `putBytes('<destination>.part', ...)` (and its validator with `putText('<destination>.part.etag', '"v1"')`) to
play a pack that an earlier session left; read what a transfer wrote with `bytesOf`. `failWrites`, `failRename` and
`failDelete` make that call throw, `unsupported` plays the web, and `renames` says what was moved into place.

```dart
// test/file_packs_test.dart
import 'package:crypto/crypto.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_app/offline/douala_file.dart';

void main() {
  test('a partial file from an earlier session is continued with Range', () async {
    final body = [for (var i = 0; i < 300; i++) i % 251];
    final ranges = <String?>[];
    final client = MockClient.streaming((request, _) async {
      ranges.add(request.headers['range']);
      final from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(request.headers['range']!)!.group(1)!);
      return http.StreamedResponse(
        Stream.value(body.sublist(from)),
        206,
        contentLength: body.length - from,
        headers: {'content-range': 'bytes $from-${body.length - 1}/${body.length}'},
      );
    });

    const dir = '/support';
    final request = FilePackRequest(
      key: doualaFilePack(dir).key,
      url: doualaFilePack(dir).url,
      destination: doualaFilePack(dir).destination,
      bytes: body.length,
      sha256: sha256.convert(body).toString(),
    );
    // The app was closed after 100 bytes.
    final files = FakePackFiles(files: {request.partial: body.sublist(0, 100)});
    final container = ProviderContainer(
      overrides: [packHttpClient.overrideWithValue(client), packFileStore.overrideWithValue(files)],
    );
    addTearDown(container.dispose);
    final packs = container.read(filePacks.notifier);

    await packs.refresh([request]);
    expect(
      container.read(filePackStatus(request.key)),
      Interrupted(progress: 100 / 300, bytes: 100),
    );

    await packs.resume(request.key); // returns when the transfer stops
    expect(ranges, ['bytes=100-']);
    expect(container.read(filePackStatus(request.key)), const Complete(bytes: 300));
    expect(files.bytesOf(request.destination), body);
    expect(files.bytesOf(request.partial), isNull);
  });
}
```
