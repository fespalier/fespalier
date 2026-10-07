# Maps: fespalier_maps

`fespalier_maps` (since 0.12.0) gives an app a pin picker that returns a place: the pin is fixed at the centre, the map
moves under it, a search field sits at the bottom, and a name for the point under the pin is shown as a **guess**.
Confirming pops a `PickedPlace` to the page that asked for it. The map is [MapLibre](https://maplibre.org) through
`maplibre_gl`, the device position is `geolocator`, and the geocoder is yours.

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
[Where the device is](#where-the-device-is), [The map](#the-map), [Telemetry](#telemetry), [Testing](#testing),
[Rules and what it costs](#rules-and-what-it-costs), [Not built yet](#not-built-yet).

## Install

Add the package next to fespalier with the **same `url` and the same `ref`**: pub resolves the two to one package only
then. The tag must be a release that contains the package (0.12.0 or later). The install block, with the version
release-please keeps current, is in [the package's README](../packages/fespalier_maps/README.md#install).

The package depends on `maplibre_gl` (`>=0.26.0 <0.28.0`) and `geolocator` (`>=14.0.0 <15.0.0`), and so does every app
that lists it: each is imported by one library only (`maplibre.dart`, `geolocator.dart`), but a platform plugin is linked
whether or not it is imported. Both ranges resolve on Flutter 3.32, fespalier's floor, with the lowest versions they
allow (CI's `floor` job runs `flutter pub downgrade`, `flutter analyze` and `flutter test` on the package). Two things
are **not** checked by any CI job here and need a device or a build of your app: that the map draws, and that your
Android toolchain builds `maplibre_gl` (its 0.26.0 changelog lists a Gradle, Kotlin and Android Gradle Plugin update).

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
(a pan still going when the answer arrives is adopted at its rest). One thing needs a device check: the map's own movements
at load (a minimum-zoom clamp, say) are not told apart from a person's, except that only a movement followed by a rest
counts, so a camera that moves and rests by itself while the fix is awaited would be taken for a choice.

## The map

`MapSurface` is the map under the pin: `build(context, camera, onIdle:, onMove:)` and `moveTo(point, zoom:)`.
`MapLibreSurface` in `package:fespalier_maps/maplibre.dart` is the one that draws:

```dart
final _map = MapLibreSurface(styleString: 'https://tiles.example.com/style.json');
```

A surface serves one picker at a time and can be reused by the next (a top-level `final` is fine): it holds the map's
controller, which is how `moveTo` reaches the map, and forgets it when its map is disposed. `maplibre_gl` keeps the camera
callbacks of the first build, so the surface gives it forwarders that read the latest ones, and the picker keeps one model
across rebuilds (a new geocoder or locale is assigned to it). It rotates and tilts nothing by default (`rotateGesturesEnabled: false`, `tiltGesturesEnabled:
false`, no compass), and it listens to nothing: the camera events are the widget's own callbacks. The default style is
MapLibre's demo style, for trying things out; an app uses its own tiles and follows their attribution.

A map is a platform view: it **cannot render in a widget test**, and no CI job of this repository draws one. A page that
holds a `PinPicker` is tested with `FakeMapSurface` (below), and a device run is what shows that the map is right.

## Telemetry

With a sink installed, the picker reports three `TelemetryOp.custom` operations (since 0.12.0). Their names are this
package's own contract, pinned by `test/telemetry_test.dart`: a name is added, never renamed.

| Operation                | Attributes                                                              | Ends with                                                           |
| ------------------------ | ----------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `fespalier.maps.geocode` | `fespalier.maps.direction`: `search` or `reverse`                       | `fespalier.maps.result`: `found`, `empty`, `error`, `stale`         |
| `fespalier.maps.locate`  | none                                                                    | `fespalier.maps.result`: `fixed`, `off`, `denied`, `error`, `stale` |
| `fespalier.maps.pick`    | `fespalier.maps.guessed`: whether a guess came with the confirmed place | (starts and ends in the same call)                                  |

A dropped answer ends with outcome `superseded` and result `stale`. **A value is never a coordinate, a label, a query,
an address or an error's text**: the attributes are constants and a boolean, and the test asserts that none of the strings
it feeds the picker appears in what a sink hears. With no sink installed, nothing is started.

## Testing

`package:fespalier_maps/testing.dart` has a fake of each seam, so a test needs no map, no network and no platform
channel:

- `FakeMapSurface({idleOnMove})`: a box with `fakeMapKey`; `startMove()` and `idleAt(point)` are what a real map reports,
  `moves` is what the picker asked for, `shown` the camera it was built with.
- `FakeGeocoder({places, reverseAnswer, hold})`: answers from tables; with `hold: true` every call waits in `searchCalls` or
  `reverseCalls` until the test completes or fails it, which is how to order two answers and see the stale one dropped;
  `error` makes every call throw.
- `FakePositionSource(fix, {hold})`: answers with `answer`, counts `calls`, and with `hold` waits for `release()`.

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
- **No offline maps yet, no HTTP, no `path_provider`, no secret.** The package takes no API key; a style URL with a key in
  it is public once it is in a build.
- **It links two plugins into every app that depends on it**, and a MapLibre native library with them. An app that wants a
  map but not this picker can use `maplibre_gl` directly; an app that wants this picker's model on another map writes a
  `MapSurface`.

## Not built yet

Offline region packs (download, progress, pause, resume, storage) and PMTiles file packs (resumable over HTTP Range) are
planned as separate releases of this package; this one has only the seam they will use: the map is a `MapSurface` with a
style string, and `tileCount` sizes a region before anything is fetched. Also not built: markers, routes and other
overlays, clustering, search-as-you-type, a geocoder of the package's own, and a web-specific surface (`maplibre_gl`
has a web implementation, but nothing here has run on it).
