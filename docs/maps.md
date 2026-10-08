# Maps: fespalier_maps

`fespalier_maps` (since 0.13.0) gives an app a pin picker that returns a place: the pin is fixed at the centre, the map
moves under it, a search field sits at the bottom, and a name for the point under the pin is shown as a **guess**.
Confirming pops a `PickedPlace` to the page that asked for it. The map is [MapLibre](https://maplibre.org) through
`maplibre_gl`, the device position is `geolocator`, and the geocoder is yours. The same package downloads **offline
region packs** (a rectangle, a style and a zoom range stored in MapLibre's database) with progress, pause, resume,
deletion and a storage report, and **file packs**: one PMTiles file per pack, downloaded over HTTP with `Range`
requests so that a download **resumes after the app was closed**.

fespalier itself has no map feature: no file kind, no `fespalier:` key, no `fsp` command, and `app.g.dart` is the same
bytes. The package is a companion, installed like `fespalier_flags`. It cannot add a route (`fsp` scans your `lib/app/`):
you write the page, and the page's body is `PinPicker`.

A taste first, then the details.

```dart
// lib/app/orders/new/page.dart: ask for a place, get it back
final place = await PickPlaceRoute().push<PickedPlace>(context);
if (place != null) {
  save(place.point, label: place.guess?.label); // the point is the truth, the label a courtesy
}
```

Contents: [Install](#install), [Picking a place](#picking-a-place), [Search and guesses](#search-and-guesses),
[Where the device is](#where-the-device-is), [The map](#the-map), [Offline packs](#offline-packs),
[Downloading a region](#downloading-a-region), [File packs](#file-packs), [Storage](#storage),
[Telemetry](#telemetry), [Testing](#testing),
[Rules and what it costs](#rules-and-what-it-costs), [Not built yet](#not-built-yet).

## Install

Add the package next to fespalier with the **same `url` and the same `ref`**: pub resolves the two to one package only
then. The tag must be a release that contains the package (0.13.0 or later). The install block, with the version
release-please keeps current, is in [the package's README](../packages/fespalier_maps/README.md#install).

The package depends on `maplibre_gl` (`>=0.27.1 <0.28.0`), `geolocator` (`>=14.0.0 <15.0.0`) and, for the file packs,
`http` (`>=1.5.0 <2.0.0`, the first release with abortable requests) and `crypto` (`>=3.0.6 <4.0.0`), two pure Dart packages with no platform side. An app
that lists the package links the two plugins: each is imported by one library only (`maplibre.dart`, `geolocator.dart`), but a platform plugin is linked
whether or not it is imported. Both ranges resolve on Flutter 3.32, fespalier's floor, with the lowest versions they
allow (CI's `floor` job runs `flutter pub downgrade`, `flutter analyze` and `flutter test` on the package). Two things
are **not** checked by any CI job here and need a device or a build of your app: that the map draws, and that your
Android toolchain builds `maplibre_gl` (its 0.26.0 changelog lists a Gradle, Kotlin and Android Gradle Plugin update, and 0.27.1 needs Flutter 3.29, which the 3.32 floor satisfies).

The platform setup is the plugins' own: `geolocator` needs the location permission strings in `Info.plist`
(`NSLocationWhenInUseUsageDescription`) and the manifest (`ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`), and
MapLibre needs a style (a URL or its JSON) that you are allowed to use. See each plugin's README.

## Picking a place

Three parts: a route you write, a body that is `PinPicker`, and three small widgets that are yours (the guess card, the
search field, the confirm button), so the picker looks like the rest of your app.

```dart
// lib/app/pick-place/page.dart  ->  /pick-place, and PickPlaceRoute
class PickPlacePage extends StatelessWidget {
  const PickPlacePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PinPicker(
      map: _map,
      geocoder: _geocoder,
      position: const GeolocatorPositionSource(),
      guess: (context, g) => GuessCard(g),
      searchField: (context, search) => PlaceSearchField(search),
      confirm: (context, confirm) => FilledButton(onPressed: confirm, child: const Text('Use this place')),
    ),
  );
}
```

How it behaves, each point pinned by a test:

- **The pin is fixed and the map moves under it.** The tip of the default marker is the point, at the map's centre. A custom
  `pin:` widget is placed with its bottom centre there. The pin never moves while the map does.
- **Seeded once.** Without an `initial:` camera, the picker asks the `PositionSource` once and moves the map to the fix
  (zoom 16 by default, `focusZoom`). With an `initial:` (editing a saved place) it starts there and does not ask until
  the person taps "use my location". The map's first rest, on the whole world, is not a choice: the pin has no point
  (`PinGuess.center` is null, and `confirm` is null) until a fix lands, a result is picked, or the person moves the map.
  A pan that comes to rest while the fix is still awaited is the person's choice: it is adopted at once and the fix, when
  it arrives, is dropped. Picking a result does the same.
- **Reverse geocoding runs when the map comes to rest**, on the map's idle event, never while it moves, and there is no
  debounce timer. **At most one reverse request is in flight**: the newest rest waits (replacing an older one that was
  waiting) until the answer on its way returns, and that answer, made for a point the pin has left, is dropped. A rest at
  the point already being asked about sends nothing, and a point that already has a name (a picked result) is not asked
  again. So a person who pans a lot costs the geocoder one request at a time, not one per rest.
- **Confirming** returns `PickedPlace(point, guess:)` through `GoRouter.pop`, so `await ...push<PickedPlace>(context)`
  completes with it. The `confirm` callback is null until the pin has a point and the map is at rest. The guess comes
  with the place only when it was made for exactly that point, never a stale one. `onPicked:` replaces the pop. A page
  opened with `go` (or by a link) has nothing to pop to: the picker does not throw, and does nothing unless you pass
  `onPicked:`.
- **Nothing opens over the page**: no dialog, no menu, no sheet, no snack bar. `test/no_timers_test.dart` greps `lib/` for
  them. The location permission prompt is the platform's own.

`PinPicker` is a body, not a page: put it where the thumb is. The three builders are laid out at its bottom edge
(guess, search field with its results, confirm), so a `Scaffold` body that resizes for the keyboard puts the search
field on the keyboard.

## Search and guesses

A **place name is a guess**. A geocoder answers with the nearest address or place it knows; a person standing at one
point can be told another street, and a typed "Douala" can match the wrong town. So the picker keeps two things apart:
the point is the truth, and a `PlaceGuess` is a courtesy label. `PinGuess.guess` is where you show it, with its caveat
(the sample card says "Best guess"). Store the point; keep the label only to show.

`PinSearch` is what the search field is told: `query`, `results`, `busy`, `failed`, and the actions `submit(query)`,
`pick(place)`, `useMyLocation()` and `clear()`. `submit` is for the keyboard's search action, not for every keystroke
(a public geocoder's terms usually forbid search-as-you-type, and the package has no debounce timer to make it polite).
The query is biased towards the pin (`near:`) and sent with the `locale:` you give the picker. `pick` moves the map to
the result and shows the result's label as the guess for it.

The geocoder is an interface, and **the network and its terms of use are yours**:

```dart
abstract interface class Geocoder {
  Future<List<PlaceGuess>> search(String query, {GeoPoint? near, String? locale});
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale});
}
```

Throw on failure: the picker shows "no answer" (`PinSearch.failed`, `PinGuess.failed`) and never keeps or shows the
error's text. The skill's `geocoders.md` has compiled recipes for Nominatim, Photon and your own backend. The Nominatim one
implements its public server's policy that you must not skip: requests at least a second apart, an LRU cache of answers,
an identifying `User-Agent` or `Referer`, and no autocomplete. The picker itself sends one reverse request at a time but
does no spacing or caching: that is the geocoder's.

## Where the device is

`PositionSource.current()` completes with a `PositionFix`, never an exception, so you render each case: `Fixed(point,
accuracyMeters)`, `ServiceOff`, `Denied(permanent)` and `Unavailable`. `package:fespalier_maps/geolocator.dart` has
`GeolocatorPositionSource`, which checks that the service is on, asks for the permission with the platform's own prompt
when it is `denied`, and takes one fix (`LocationAccuracy.high`, a 15 second limit that is geolocator's own). The picker
keeps the last answer in `PinGuess.fix`: a refusal leaves the map where it is and lets you show a hint with a button to
`useMyLocation` again, or to open the system settings when it is `Denied(permanent: true)`.

The fix moves the map once, when it arrives. If the person has panned in the meantime it does not: their rest was adopted
(a pan still going when the answer arrives is adopted at its rest). A rest counts as a choice only when it is away from where
the map started (about a kilometre, 0.01 degree): iOS reports a camera move for any region change and `maplibre_gl` does not
say whether a gesture caused it, so a move and a rest at the start are the map's own and the fix still lands. What needs a
device check is a map's own movement that ends somewhere else (a minimum-zoom clamp that recentres, say), which would be
taken for a choice. "Use my location" is explicit and always moves the map: a pan made after tapping it, before the answer,
is overridden by the fix.

## The map

`MapSurface` is the map under the pin: `build(context, camera, binding)`. The `MapBinding` is the picker's own link to the
map built for it: the map reports its camera to the binding (`move()`, `idle(center)`), and the picker moves the map
through it (`binding.moveTo`), so **a move can only reach the map it was made for**. `MapLibreSurface` in
`package:fespalier_maps/maplibre.dart` is the one that draws:

```dart
const _map = MapLibreSurface(styleString: 'https://tiles.example.com/style.json');
```

A surface is configuration, with value equality, and holds no state about a picker: share it freely (a `const`, a top-level
`final`, or one built inside `build`), among pickers one after the other or stacked, a pickup picker that pushes a drop-off
picker. Each map it builds has its own controller and receives only the moves of its own picker's binding. A move made before
the platform view exists is parked and applied without animation when it does; when the map is disposed the binding is
detached. `maplibre_gl` keeps the camera callbacks of the build that created the platform view, which is why they call the
binding, and why the picker keeps one model, and one binding, for its whole life: a new geocoder, locale or `map:` never
makes a new picker. A surface that differs only in its options (a theme switch changes the style) is applied to the same map
in place, so the pin, the guess, the search and the position survive; a surface of another type replaces the map, which opens
where the pin is, and the old map detaching afterwards does not detach the new one. It rotates and tilts nothing by default (`rotateGesturesEnabled: false`, `tiltGesturesEnabled:
false`, no compass), and it listens to nothing: the camera events are the widget's own callbacks. The default style is
MapLibre's demo style, for trying things out; an app uses its own tiles and follows their attribution.

A map is a platform view: it **cannot render in a widget test**, and no CI job of this repository draws one. A page that
holds a `PinPicker` is tested with `FakeMapSurface` (below), and a device run is what shows that the map is right.

## Offline packs

A pack is a MapLibre **region**: the tiles, glyphs and sprites a style needs for a rectangle and a zoom range, stored in
MapLibre's offline database so the map draws with no network (since 0.13.0). Three pieces, and only the last imports
MapLibre:

- `RegionPackRequest`: the `key` you name the pack by, the `GeoBounds`, the `styleUrl`, `minZoom` and `maxZoom`.
  `estimatedTiles` is the number of Web Mercator tiles under it (`tileCount`), to show the size of a choice before
  anything is fetched; `isValid` is false for an empty key or style, a zoom range out of order or above 22, an inverted
  rectangle and one that crosses the antimeridian (split it in two).
- `TilePacks`, the notifier behind the `tilePacks` provider: `start`, `pause`, `resume`, `remove`, `refresh`, `storage`.
  Its state is a `Map<String, PackStatus>`; `tilePackStatus(key)` is one pack's, `Absent` while there is none.
- `OfflineTiles`, the port over the database. `offlineTiles` is the provider that holds it and has **no default**: the app
  overrides it with `MapLibreOfflineTiles()` from `package:fespalier_maps/maplibre.dart`, and a test with
  `FakeOfflineTiles`.

```dart
// the app's ProviderScope
ProviderScope(
  overrides: [offlineTiles.overrideWithValue(const MapLibreOfflineTiles())],
  child: const MyApp(),
)
```

The `PackStatus` values are `Absent`, `Downloading` (`progress` 0 to 1, resource counts, `bytes`), `Paused`, `Complete`
(`bytes`), `Interrupted` and `Failed` (a `PackFailure`: `unsupported`, `invalidRegion`, `limitExceeded`, `duplicateRegion`, `replaced`, `other`; never the
platform's text). MapLibre counts **resources** (tiles, glyph ranges, sprites, the style), not tiles, and the numbers here
are its own. Offline downloads exist on Android and iOS only: on the web a download ends in `Failed(unsupported)`.

**A MapLibre download does not resume across an app restart.** While the app stays alive, `pause` and `resume` continue
the same download. If the app is closed while a region downloads, MapLibre keeps what it stored but the download is gone:
the next session finds the region in the database, and `refresh()` reports it as `Interrupted`. `resume` of an
`Interrupted` (or `Failed`) pack **starts the same definition again**; whether MapLibre reuses the resources already
stored or fetches them again was not checked on a device. On iOS the plugin's sources suggest an unfinished pack can go on
by itself after a restart, silently, since there is no event channel to Dart for it: `refresh()` then shows it
`Interrupted` or `Complete` depending on when you ask, and a `resume` of an `Interrupted` one restarts a download that may
already be running (also not verified on a device).
Android's native side also answers "Region is no longer actively tracked" to a `resume` it has lost, which `TilePacks`
turns into `Interrupted` as well. A download that resumes from a byte offset needs a file the package controls: the PMTiles
[file packs](#file-packs) are that (HTTP Range).

## Downloading a region

```dart
final packs = ref.read(tilePacks.notifier);
await packs.refresh();         // once, when the page opens: learns the packs of earlier sessions
await packs.start(doualaPack); // returns when MapLibre has the region; the end is Complete or Failed in the state
final status = ref.watch(tilePackStatus('douala'));
```

- **Nothing is read at startup.** `refresh()` lists the database: a complete region becomes `Complete`, an unfinished one
  `Interrupted`, one deleted behind your back leaves the state, and a region another tool made (without this package's
  key in its metadata) is ignored. A pack that downloads in this session is never overwritten by it.
- **Progress is the state.** MapLibre reports a download through a callback that `TilePacks` hands the port, and the app
  watches the provider: no stream, no subscription and no timer in the package. `start` of a key that is `Downloading` or
  `Paused` does nothing; of a `Complete` one downloads it again (see the next point).
- **`pause`, `resume` and `remove` never leave the state lying.** A `pause` that MapLibre refuses leaves `Downloading`;
  `resume` of a `Paused` pack whose download was lost makes it `Interrupted`; `remove` stops a running download (its late
  events are dropped), frees what only that pack needed, and, if the database refuses, marks the pack `Failed` and throws.
- **The key is yours and stays in the database.** It is stored in the region's metadata under `fespalier_maps.key`, and
  never sent to telemetry.
- **MapLibre treats two regions with the same style, rectangle and zoom range as one** (`maplibre_gl` 0.27). Downloading
  a definition deletes the region that already has it, **at the start of the download**, and on iOS the new region takes the
  old one's id. So a re-download of a `Complete` pack (or a `resume` of an `Interrupted` or `Failed` one) replaces the old
  region at once, and **a re-download that then fails has lost the pack**; `TilePacks` shows it as `Failed`, not as a stale
  `Complete`. It also never deletes the region a download just made, whatever the id. And two keys cannot share a
  definition: starting the second ends in `Failed(duplicateRegion)` and reaches nothing (starting it would delete the
  first's region). Give each pack its own rectangle, zoom range or style.
- **`refresh()` keeps the complete region** of a key whatever the ids (iOS ids are not ordered) and deletes its other
  regions; with none complete it keeps the highest id, and a `resume` replaces them.

## File packs

A file pack is **one file**, a [PMTiles](https://docs.protomaps.com/pmtiles/) archive (any single file works), fetched over
HTTP into a directory your app owns (since 0.13.0). Where a MapLibre region cannot continue after a restart, **a file pack
does**: the bytes arrive in `<destination>.part`, a transfer that stops leaves them, and the next attempt asks the server
for the rest with `Range: bytes=<size of the partial file>-`. Pieces:

- `FilePackRequest(key:, url:, destination:, sha256:, bytes:, headers:)`. `destination` is a **path** (a `String`, so the library
  compiles for the web) in a directory the app got itself, typically its application-support directory: the package
  depends on no `path_provider`. `bytes` and `sha256` are the integrity checks; give them whenever the server's release notes or a
  manifest say them. `headers` carries an `Authorization` header if the server wants one. `isValid` is false for an empty key,
  a URL that is not `http` or `https`, a size of zero or less and a hash that is not 64 hexadecimal digits.
- `FilePacks`, the notifier behind the `filePacks` provider: `start`, `pause`, `resume`, `remove`, `refresh(requests)`, `storage`.
  Its state is the same `Map<String, PackStatus>` as region packs, with `filePackStatus(key)` for one pack, so a page
  that shows both kinds reads one vocabulary. The `PackFailure`s a file pack ends in are `network`, `rejected`, `sizeMismatch`,
  `hashMismatch`, `storage`, `invalidRequest` and `unsupported`.
- `packHttpClient`, the provider of the `http.Client` the download uses. It has **no default**: override it with the app's
  client (its timeouts, proxy and certificates then apply), and a test with `package:http/testing.dart`'s `MockClient`.
  The package never closes it. `packFileStore` is the provider of the files (`dart:io`; `FakePackFiles` in tests).

```dart
ProviderScope(
  overrides: [packHttpClient.overrideWithValue(http.Client())],
  child: const MyApp(),
)

final pack = FilePackRequest(
  key: 'douala',
  url: Uri.parse('https://tiles.example.com/douala-2026-10.pmtiles'),
  destination: '${supportDirectory.path}/packs/douala.pmtiles',
  bytes: 48213377,
  sha256: 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12',
);
final packs = ref.read(filePacks.notifier);
await packs.refresh([pack]);      // once, when the page opens: disk tells what an earlier session left
unawaited(packs.start(pack));     // returns when the transfer stops; the state is Complete, Failed or Paused
final status = ref.watch(filePackStatus('douala'));
```

How a download goes:

- **The file at the destination is always whole and checked.** The bytes are written to `<destination>.part`; when the transfer
  ends, the size is compared with `bytes`, the SHA-256 with `sha256` (computed from the file, after the last byte, in a background
  isolate: a large file takes a moment, not frames), and only then is the file renamed into place. A size or a hash that does not match **deletes the partial
  file** (`Failed(sizeMismatch)` or `Failed(hashMismatch)`): it is not the file the app expects, and appending to it would
  not help. Without `bytes` and `sha256` the pack is trusted as the server sent it.
- **Resuming is a new request with `Range`.** `pause` aborts the request (so a connection that sends nothing cannot hold it; this needs a `packHttpClient` that honours `http.Abortable`: `IOClient` in `http` 1.5 does, a wrapper such as `RetryClient` must forward the request's `abortTrigger`) and keeps the partial file
  (`Paused`); `resume` asks for the bytes from its size on. The same call after an error (`Failed(network)`), and after a restart
  (`refresh` found the `.part` file and reports `Interrupted(bytes:, progress:)`), continues from the last byte on disk, so
  the label is "Resume", unlike a region pack's "Download again".
- **The server may not cooperate, and the package copes.** One that ignores `Range` answers 200 with the whole body: the transfer
  starts again from the first byte (the partial file is emptied, never appended to). The package sends `If-Range` with the
  `ETag` (or else `Last-Modified`) the first response had, kept in `<destination>.part.etag`, so a file replaced on the
  server is fetched whole instead of being glued onto old bytes. A CDN may ignore `If-Range`, so a 206 whose validator is not
  the stored one is dropped and the transfer restarts from zero; and a partial file with **no stored validator** (and no `sha256`
  to catch a splice at the end) is not continued blindly: the transfer starts from the first byte. A 416 to a partial file the server's copy is shorter than gets
  one restart from zero (a 416 that says the partial file is the whole file finishes it); a 206 that starts at another offset
  than asked does the same; a second failure is `Failed(rejected)`. Any other status (a 404, a 403, a 5xx) is
  `Failed(rejected)` and the partial file stays. The package asks for `Accept-Encoding: identity`, because offsets count the
  bytes on the wire (a client built on the platform's own stack, such as `cupertino_http` or `cronet_http`, may decompress
  anyway: use the default `dart:io` client, or a server that does not compress archives). Bodies the transfer does not
  read (an error page, a restart) are cancelled.
- **`start` and `resume` return when the transfer stops**, not when it begins (unlike `TilePacks.start`): `unawaited(...)` them in
  a handler, or `await` them in a test. They never throw for a failure of the transfer, only the `ProviderException` (Riverpod wraps the `StateError` that
  explains it) when `packHttpClient` is not overridden. `start` of a key that is `Downloading` or `Paused` does nothing; of one whose file is already at the
  destination (with the size the request names) makes it `Complete` with no request (a file of another size stays until the new
  one is whole, and the move replaces it), so to publish a newer archive give it
  another URL **and** destination, or `remove` the pack first.
- **`remove` aborts the request and waits for the transfer to close its file**, then deletes the finished file, the partial file and the validator.
  If a file cannot be deleted the pack becomes `Failed(other)`, as a region pack does, and the error is thrown. A `start` of the same key while a remove runs takes the key over. A pack of an earlier session is known to `remove` and
  `resume` only after `refresh` has been given its request: the registry of which packs exist is the app's.
- **Nothing is read at startup, and disk is the state of record.** `refresh(requests)` reads each destination and `.part`
  file: `Complete`, `Interrupted` or nothing. A pack that is downloading in this session is left alone.
- **On the web a file pack ends in `Failed(unsupported)`** before any request (there are no files); the `dart:io` part is behind
  a conditional import.
- **No timer, no listener, no microtask.** The response body is read with `await for`, which ends when the transfer does; a
  pause, a removal and the end of the provider abort the request (`http` 1.5's `abortTrigger`, which the app's client must honour), and the transfer closes its file.

**Drawing from the file.** A finished PMTiles archive is read directly by MapLibre: a style's vector source whose `url` is
`pmtilesSourceUrl(path)` (`pmtiles://file:///data/.../douala.pmtiles`). In the style JSON you pass to
`MapLibreSurface(styleString: ...)`:

```json
{
  "version": 8,
  "sources": {
    "basemap": {
      "type": "vector",
      "url": "pmtiles://file:///data/user/0/app/files/packs/douala.pmtiles"
    }
  },
  "layers": [
    {
      "id": "water",
      "type": "fill",
      "source": "basemap",
      "source-layer": "water"
    }
  ]
}
```

`maplibre_gl` 0.27.1 lists "GeoJSON, vector, raster & PMTiles sources" for Android, iOS and the web, and bundles MapLibre
Native Android 13.5 and iOS 6.28 (its changelog says PMTiles support came in with Native Android 11.9 and iOS 6.14). What was **not** checked here is that a `pmtiles://file://` source draws on a device: no CI job renders a
map. Two caveats are certain: an archive holds tiles only, so the style's `glyphs` and `sprite` must be reachable offline too
(bundled with the app, or inside a region pack) or labels do not draw; and the web has no local files, so on the web the
archive stays a remote `pmtiles://https://...` source, which is not a pack.

## Storage

`await ref.read(tilePacks.notifier).storage()` answers a `StorageUse`: `perPack` (the bytes each pack's resources take,
from the statuses), `packSum`, and `onDisk` (the size of the database file). **The per-pack bytes overlap**: a glyph range
or an edge tile that two packs share is counted in each, so `packSum` can be more than the file, and the file also holds
MapLibre's ambient cache (the tiles the map cached while it was browsed). Show each row's bytes and `onDisk` as the total;
do not add the rows up as if they were the file.

`onDisk` is the size of the file `getOfflineDatabasePath` names (the file only, not the journal beside it); it is null on
the web and wherever the plugin does not know the path. For [file packs](#file-packs) `FilePacks.storage()` answers the same
`StorageUse`, but **the rows add up**: `perPack` is each pack's bytes (finished or partial) and `onDisk` the sum of the files on
disk of the packs this session knows; null where there are no files. The `dart:io` part sits behind a conditional import, so a web build
does not compile it.

## Telemetry

With a sink installed, the picker and the packs report four `TelemetryOp.custom` operations (since 0.13.0). Their names are this
package's own contract, pinned by `test/telemetry_test.dart`: a name is added, never renamed.

| Operation                 | Attributes                                                              | Ends with                                                           |
| ------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `fespalier.maps.geocode`  | `fespalier.maps.direction`: `search` or `reverse`                       | `fespalier.maps.result`: `found`, `empty`, `error`, `stale`         |
| `fespalier.maps.locate`   | none                                                                    | `fespalier.maps.result`: `fixed`, `off`, `denied`, `error`, `stale` |
| `fespalier.maps.pick`     | `fespalier.maps.guessed`: whether a guess came with the confirmed place | (starts and ends in the same call)                                  |
| `fespalier.maps.download` | `fespalier.maps.kind`: `region` or `file`                               | `fespalier.maps.result`: `complete`, `failed`, `cancelled`          |

A dropped answer ends with outcome `superseded` and result `stale`. A download is one operation from `start` (or the restart
that `resume` makes) to its end: a pause leaves it open, `remove` or the end of the provider's life ends it as `cancelled`
(outcome `superseded`), and a failure ends it with outcome `error`. A file pack's operation stays open across `pause` and `resume`. It never carries the pack's key, bounds, style, URL, path, hash or progress. **A value is never a coordinate, a label, a query,
an address or an error's text**: the attributes are constants and a boolean, and the test asserts that none of the strings
it feeds the picker appears in what a sink hears. With no sink installed, nothing is started.

## Testing

`package:fespalier_maps/testing.dart` has a fake of each seam, so a test needs no map, no network and no platform
channel:

- `FakeMapSurface({idleOnMove})`: a box with `fakeMapKey`; `startMove()` and `idleAt(point)` are what a real map reports,
  `moves` is what the pickers asked for, `shown` the camera it was built with. Each mounted map is a `FakeMapMount` in
  `mounts` (its own `moves`, and `startMove()` and `idleAt` for that picker), so a test can stack two pickers on one surface
  and see that a move reaches only its own map.
- `FakeGeocoder({places, reverseAnswer, hold})`: answers from tables; with `hold: true` every call waits in `searchCalls` or
  `reverseCalls` until the test completes or fails it, which is how to order two answers and see the stale one dropped;
  `error` makes every call throw.
- `FakePositionSource(fix, {hold})`: answers with `answer`, counts `calls`, and with `hold` waits for `release()`.
- `FakePackFiles({files, texts})`: the files of a file pack in memory (override `packFileStore` with it), with `bytesOf`, `textOf`,
  `putBytes` and `putText` to seed what an earlier session left and read what a transfer wrote, `failWrites`, `failRename`
  and `failDelete`, `unsupported` (the web) and `renames`. The server is `package:http/testing.dart`'s `MockClient.streaming`
  behind `packHttpClient`: answer `Range` with a 206 and a `Content-Range`, or ignore it with a 200, to play both servers.
- `FakeOfflineTiles({holdDownloads, databaseSize})`: the offline database in memory; override `offlineTiles` with it. The
  test plays MapLibre with `progress(key, fraction, ...)`, `finish(key)` and `fail(key, reason)`; `seed(request, complete:)`
  puts a region there as an earlier session left it, `restart()` plays the app being reopened (old downloads are no longer
  tracked, so `resume` of one throws as MapLibre's does), `holdDownloads` with `releaseDownloads()` puts events before the
  download call's answer, and `pauseError`, `resumeError`, `deleteError`, `downloadError` and `regionsError` make a call
  throw. `pauses`, `resumes`, `deleted` and `downloads` say what the packs asked for.

```dart
// the page that asked: a real push<PickedPlace> on pumpRouter, the map played by the test
final result = router.push<PickedPlace>('/pick-place');
await tester.pumpAndSettle();
map.idleAt(const GeoPoint(4.05, 9.7));
await tester.pump();
await tester.tap(find.text('Use this place'));
await tester.pumpAndSettle();
expect((await result)?.point, const GeoPoint(4.05, 9.7));
```

The picker's state is also a plain class, `PinPickerModel`, which a test (or an app that writes its own widget) can drive
without a widget at all: `seed()`, `onMove()`, `onIdle(point)`, `search.submit`, `pick`, `confirm()`. The pure tile
arithmetic, `tileCount(bounds, minZoom:, maxZoom:)`, is tested against values worked out by hand.

## Rules and what it costs

- **No timer, no polling, no microtask, no listener of its own.** The map reports through callbacks the widget hands it,
  the model is a `ChangeNotifier` that `useListenable` watches, and a request's staleness is a number. `test/no_timers_test.dart`
  greps `lib/` for timers, delays, `.listen(`, `addListener(`, frame callbacks and `DateTime.now()`.
- **A geocoder error, a query, a label and a coordinate never leave the picker** through telemetry, and an error's text is
  never kept.
- **Downloads add no timer, no listener and no stream of their own** (a file pack reads its response with `await for`). MapLibre's download callback is the only source of
  progress, `TilePacks` writes it into provider state, and a stale event (of a pack removed or started again) is dropped by
  a generation number.
- **HTTP only in file packs, and only through the client you provide; no `path_provider`, no secret.** The package takes no
  API key and no CDN secret: a style or archive URL with a key in it is public once it is in a build, and the URL, the
  paths and the headers of a file pack never reach telemetry.
- **It links two plugins into every app that depends on it**, and a MapLibre native library with them. An app that wants a
  map but not this picker can use `maplibre_gl` directly; an app that wants this picker's model on another map writes a
  `MapSurface`.

## Not built yet

Markers, routes and other overlays, clustering, search-as-you-type, a geocoder of the package's own, a download that
continues in the background when the app is closed (a file pack resumes when the app is opened and starts it again), a
retry policy with backoff (it would need a timer: the app decides when to call `resume`), several files for one pack, and
a web-specific surface (`maplibre_gl` has a web implementation, but nothing here has run on it, and it has no offline
regions and no local files).
