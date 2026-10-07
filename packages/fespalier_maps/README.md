# fespalier_maps

Maps for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0): a pin picker that returns a place. The pin is
fixed at the centre and the map moves under it, a search field sits at the bottom, a name for the point under the pin is
shown as a **guess**, and confirming pops a `PickedPlace` to the page that pushed the route. The map is
[MapLibre](https://maplibre.org) (`maplibre_gl`), the device position is `geolocator`, and the geocoder is an interface
you implement (the skill has recipes for Nominatim, Photon and your own backend). It also downloads offline MapLibre
region packs, with progress, pause, resume and a storage report.

fespalier itself has no map feature: no file kind, no `fespalier:` key, no `fsp` command, and the generated code is the
same bytes. The package cannot add a route (`fsp` scans your `lib/app/`): you write `lib/app/pick-place/page.dart`, and its
body is `PinPicker`.

The full guide is [docs/maps.md](https://github.com/fespalier/fespalier/blob/main/docs/maps.md). This page is the short
version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.12.0
  fespalier_maps:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_maps
      ref: v0.12.0
```

<!-- x-release-please-end -->

It depends on `maplibre_gl` (`>=0.26.0 <0.28.0`) and `geolocator` (`>=14.0.0 <15.0.0`), which resolve on Flutter 3.32 and
on the pinned Flutter. Their platform setup is theirs: the location permission strings in `Info.plist` and the manifest,
and a map style you may use. **Not checked by any CI job here:** that the map draws (a platform view needs a device), and
that your app's Android toolchain builds `maplibre_gl` (its 0.26.0 changelog lists a Gradle, Kotlin and Android Gradle
Plugin update).

## Use it

```dart
// lib/app/pick-place/page.dart  ->  PickPlaceRoute
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/geolocator.dart';
import 'package:fespalier_maps/maplibre.dart';

const _map = MapLibreSurface(styleString: 'https://tiles.example.com/style.json'); // configuration: share it

class PickPlacePage extends StatelessWidget {
  const PickPlacePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PinPicker(
      map: _map,
      geocoder: MyGeocoder(), // yours: a Geocoder
      position: const GeolocatorPositionSource(),
      guess: (context, g) => Text(g.guess == null ? '' : 'Best guess: ${g.guess!.label}'),
      searchField: (context, search) => MySearchField(search), // docked at the bottom by the picker
      confirm: (context, confirm) => FilledButton(onPressed: confirm, child: const Text('Use this place')),
    ),
  );
}

// the page that asked
final place = await PickPlaceRoute().push<PickedPlace>(context);
```

`place.point` is the truth; `place.guess` is a courtesy label. The picker opens no dialog, menu or sheet.

## Offline packs

`TilePacks` (the `tilePacks` provider) downloads MapLibre **region packs**: `start(RegionPackRequest(key:, bounds:,
styleUrl:, minZoom:, maxZoom:))`, `pause`, `resume`, `remove`, `refresh` and `storage`, with one `PackStatus` per key
(`Absent`, `Downloading`, `Paused`, `Complete`, `Interrupted`, `Failed`) that the app watches with
`ref.watch(tilePackStatus(key))`. `request.estimatedTiles` sizes a choice before anything is fetched. Override the database
once: `offlineTiles.overrideWithValue(const MapLibreOfflineTiles())` (from `maplibre.dart`; `FakeOfflineTiles` in tests).

**A MapLibre download does not resume across an app restart**: pause and resume work while the app stays alive; after a
restart the region is `Interrupted` and `resume` downloads it again. PMTiles file packs (a later release) are the
resumable kind. See [docs/maps.md](https://github.com/fespalier/fespalier/blob/main/docs/maps.md#offline-packs).

## Test it

```dart
final map = FakeMapSurface();
// ... pump a page whose body is PinPicker(map: map, geocoder: FakeGeocoder(...), ...)
map.idleAt(const GeoPoint(4.05, 9.7)); // what a real map reports when it comes to rest
```

`package:fespalier_maps/testing.dart` has `FakeMapSurface`, `FakeGeocoder` (tables, or held calls to order two answers)
and `FakePositionSource`. The picker's state is a plain class, `PinPickerModel`, testable with no widget.

## Rules

- **No timer, no polling, no microtask, no listener of its own**, and nothing that opens a dialog, a menu, a sheet or a
  snack bar: `test/no_timers_test.dart` greps `lib/`.
- **Telemetry carries kinds and results, never a place**: `fespalier.maps.geocode`, `fespalier.maps.locate` and
  `fespalier.maps.pick`, constants and a boolean only, pinned by `test/telemetry_test.dart`.
- `fespalier.maps.download` reports a pack's download as one operation (`region`, then `complete`, `failed` or `cancelled`),
  never its key or rectangle.
- Not built yet: PMTiles file packs (a later release), markers and overlays, search as you type.
