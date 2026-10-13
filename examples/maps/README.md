# maps

A pin picker that returns a place, and one offline map pack, with [`fespalier_maps`](../../packages/fespalier_maps).
The skill is [`fespalier-maps`](../../skills/fespalier-maps/SKILL.md) and the guide is
[Maps](../../docs/maps.md).

## What it shows

Three routes, two screens of interest.

| Route         | File                                                           | What it is                                                                                                                                                                                                                                                    |
| ------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/`           | [`lib/app/page.dart`](lib/app/page.dart)                       | "Where should we deliver?" It does `await PickPlaceRoute().push<PickedPlace>(context)` and shows the point it got back, and the name as a **best guess**. The point is what an app stores; the name is a courtesy.                                            |
| `/pick-place` | [`lib/app/pick-place/page.dart`](lib/app/pick-place/page.dart) | `PinPicker` as the whole body: the pin is fixed at the centre and the map moves under it. A guess card, a search field docked at the bottom and a confirm button (all in [`lib/place_widgets.dart`](lib/place_widgets.dart)) are laid out at its bottom edge. |
| `/offline`    | [`lib/app/offline/page.dart`](lib/app/offline/page.dart)       | One offline region pack (Douala): download, progress, pause, resume, delete, and what a pack left by an earlier session looks like (`Interrupted`).                                                                                                           |

The seams are providers in [`lib/places.dart`](lib/places.dart), so a test swaps each one:

- `mapSurface` is a `MapLibreSurface` in the app and a `FakeMapSurface` in tests.
- `positionSource` is `GeolocatorPositionSource` in the app and a `FakePositionSource` in tests.
- `geocoder` is the app's own `Gazetteer`, a fixed list of six cities in Cameroon. **There is no geocoding
  service and no network call**, in the app or in tests: reverse names the nearest city within 60 km (and
  nothing farther, because no name is better than a wrong one), search matches the start of a name. A real app
  writes a `Geocoder` over a service it may use; [`geocoders.md`](../../skills/fespalier-maps/references/geocoders.md)
  has recipes and the usage policy of a public one.
- `offlineTiles`, the one provider the package leaves without a default, is overridden in
  [`lib/app/startup.dart`](lib/app/startup.dart) with `MapLibreOfflineTiles`, and with a `FakeOfflineTiles` in tests.

### Why a region pack and not a PMTiles file pack

The package has both. This example uses a MapLibre **region pack** (`tilePacks`) because it needs nothing of its own:
the style the map already uses says where the tiles come from, MapLibre's database holds them, and there is no server
to host an archive, no destination path (so no `path_provider`) and no `http` client to provide. The price is
that a download **does not continue after the app is closed**: the next session finds the region `Interrupted` and
"Download again" starts it over. If a download must resume after a restart, use a
[file pack](../../skills/fespalier-maps/references/file-packs.md), which downloads one PMTiles file with HTTP `Range`.

## The map style

The default is MapLibre's demo style, `https://demotiles.maplibre.org/style.json`: a world map with country borders and
no street detail, **for trying things out, not for production**. For your own tiles, run with
`--dart-define=MAP_STYLE_URL=https://your.tiles/style.json` and show the attribution your tiles ask for. The offline
pack downloads the same style, so with the demo style it holds little.

## Run it

Maps are platform views and **do not draw in `flutter test`** (nothing in this repository's CI draws one), so a
device or a simulator is the only way to see the map. Like the other examples, this one commits no platform folders:

```sh
cd examples/maps
flutter create . --platforms=android,ios   # adds platform folders only
flutter pub get
flutter run                                  # a device or a simulator
```

Add the platform setup `geolocator` asks for (see [Install](../../docs/maps.md#install)):

- iOS, in `ios/Runner/Info.plist`: a `NSLocationWhenInUseUsageDescription` string.
- Android, in `android/app/src/main/AndroidManifest.xml`: `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION`. A
  release build also needs `INTERNET`, which `flutter create` adds to the debug manifest only.

Things to try: open "Pick a place" and allow the location (the map moves to you; pan before the answer and it stays
where you panned), search "Dou" and tap the result, confirm, and read the point back on the home page. On
"Offline map", download, pause, resume and delete the pack; close the app mid-download and reopen the page to see
`Interrupted`.

## Test it

```sh
flutter analyze
dart format --set-exit-if-changed .
flutter test
```

None of the tests touches the network or a platform channel.

- [`test/pick_place_test.dart`](test/pick_place_test.dart) boots the generated router with a `FakeMapSurface` and plays
  the map (`startMove`, `idleAt`): pan, a guess, confirm returns the point and the guess; a point far from every city
  returns no name; a refused position is a hint, not an error; a fix moves the map; **a late fix does not override a pan**;
  a search is submitted (not sent per keystroke) and a result moves the map.
- [`test/offline_test.dart`](test/offline_test.dart) plays MapLibre with a `FakeOfflineTiles`: progress to complete and
  delete, pause and resume, and a pack an earlier session left unfinished.
- [`test/gazetteer_test.dart`](test/gazetteer_test.dart) is the app's geocoder alone.

`lib/app.g.dart` and `lib/app.main.g.dart` are generated by `fsp gen` and committed; a test in the generator fails when
one is stale. See [Testing](../../docs/maps.md#testing) for the fakes.
