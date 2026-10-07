# A pin picker, end to end

Since 0.12.0 (`package:fespalier_maps`). The page is yours, so the route is a folder you add; the three widgets in it
(the guess card, the search field, the confirm button) are yours, so the picker looks like the rest of the app. The model
behind them is `PinPickerModel`; the widget only lays the pieces out.

## The three widgets

A card that says what the pin is on, **as a guess**, and what to do when there is no position; a search field with its
results above it; both written against the snapshots the picker hands them.

```dart
// lib/places/place_widgets.dart
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';

class GuessCard extends StatelessWidget {
  const GuessCard(this.state, {super.key});

  final PinGuess state;

  @override
  Widget build(BuildContext context) {
    final String line;
    if (state.guessing) {
      line = 'Looking for a name...';
    } else if (state.guess case final guess?) {
      line = 'Best guess: ${guess.label}';
    } else if (state.failed) {
      line = 'No name found. The pin is still where you put it.';
    } else if (state.center == null) {
      line = switch (state.fix) {
        Denied(permanent: true) => 'Location is off for this app. Move the map or search.',
        Denied() || ServiceOff() || Unavailable() => 'No position yet. Move the map or search.',
        _ => 'Move the map to put the pin on the place.',
      };
    } else {
      line = 'The pin marks this point.';
    }
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(padding: const EdgeInsets.all(12), child: Text(line)),
    );
  }
}

class PlaceSearchField extends StatelessWidget {
  const PlaceSearchField(this.search, {super.key});

  final PinSearch search;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final place in search.results)
        ListTile(
          title: Text(place.label),
          subtitle: place.detail == null ? null : Text(place.detail!),
          onTap: () => search.pick(place),
        ),
      if (search.failed) const ListTile(title: Text('Search is not available right now.')),
      Padding(
        padding: const EdgeInsets.all(8),
        child: SearchBar(
          hintText: 'Search a place',
          onSubmitted: search.submit, // the keyboard's search action, never per keystroke
          trailing: [
            IconButton(
              icon: const Icon(Icons.my_location),
              tooltip: 'Use my location',
              onPressed: search.useMyLocation,
            ),
          ],
        ),
      ),
    ],
  );
}
```

## The page, and the page that asks

```dart
// lib/places/no_geocoder.dart
import 'package:fespalier_maps/fespalier_maps.dart';

/// A geocoder that knows nothing: the picker still works (a pin and a point). Replace it with a recipe from geocoders.md.
class NoGeocoder implements Geocoder {
  const NoGeocoder();

  @override
  Future<List<PlaceGuess>> search(String query, {GeoPoint? near, String? locale}) async => const [];

  @override
  Future<PlaceGuess?> reverse(GeoPoint point, {String? locale}) async => null;
}
```

```dart
// lib/app/pick-place/page.dart
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/geolocator.dart';
import 'package:fespalier_maps/maplibre.dart';
import 'package:flutter/material.dart';
import 'package:my_app/places/no_geocoder.dart';
import 'package:my_app/places/place_widgets.dart';

// Configuration only (a style): share it, it holds no state about a picker.
const _map = MapLibreSurface(styleString: 'https://tiles.example.com/style.json');

/// -> /pick-place, and PickPlaceRoute
class PickPlacePage extends StatelessWidget {
  const PickPlacePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    // The whole body: the keyboard lifts the search field with it.
    body: PinPicker(
      map: _map,
      geocoder: const NoGeocoder(),
      position: const GeolocatorPositionSource(),
      guess: (context, state) => GuessCard(state),
      searchField: (context, search) => PlaceSearchField(search),
      confirm: (context, confirm) => Padding(
        padding: const EdgeInsets.all(8),
        // `confirm` is null until the pin has a point and the map is at rest.
        child: FilledButton(onPressed: confirm, child: const Text('Use this place')),
      ),
    ),
  );
}
```

```dart
// lib/app/page.dart
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PickedPlace? _place;

  Future<void> _pick() async {
    // Completes with what the picker pops, or null when the person goes back.
    final place = await const PickPlaceRoute().push<PickedPlace>(context);
    if (!mounted || place == null) return;
    setState(() => _place = place);
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(onPressed: _pick, child: const Text('Pick a place')),
          // The point is the truth: store it. The guess is a courtesy label and may be null.
          if (_place case final place?) Text('${place.point.latitude}, ${place.point.longitude}  ${place.guess?.label ?? ''}'),
        ],
      ),
    ),
  );
}
```

`PickPlaceRoute().push<PickedPlace>(context)` is `TypedLocation.push`, so the result type is the one `GoRouter.pop` is given:
the picker pops `PickedPlace` itself (`onPicked:` replaces that, for a picker that is not a route).

## What a person sees, in order

1. The map opens on the whole world (or on `initial:`), the pin at its centre, the card saying "Move the map...". The
   position source is asked once; on a platform with a prompt, **the prompt is the platform's own** and the map waits behind it.
2. A fix moves the map to street level and the pin takes that point; `confirm` is now enabled. A refusal leaves the map and
   shows the hint; the person can still move the map or search.
3. When the map comes to rest the card shows "Looking for a name...", then "Best guess: ...". Moving it again disables
   `confirm` until the next rest.
4. A submitted search lists places above the field; tapping one moves the map and shows its label as the guess.
5. `Use this place` pops the `PickedPlace`.

## Testing the page and the round trip

The generated page holds a `MapLibreSurface`, which is a platform view and cannot render in a test. Test the widgets you wrote
and the round trip with the fakes: a page with the same `PinPicker` and `FakeMapSurface`, pushed on a real router. The test
plays the map (`startMove`, `idleAt`) and the geocoder (`FakeGeocoder`'s tables, or `hold: true` to order two answers).

```dart
// test/pick_place_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/places/place_widgets.dart';

void main() {
  testWidgets('the place comes back to the page that asked', (tester) async {
    final map = FakeMapSurface();
    final geocoder = FakeGeocoder(reverseAnswer: (point) => PlaceGuess(point, 'Rue Foch'));
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => const Scaffold(body: Text('home'))),
        GoRoute(
          path: '/pick-place',
          builder: (context, state) => Scaffold(
            body: PinPicker(
              map: map,
              geocoder: geocoder,
              guess: (context, guess) => GuessCard(guess),
              searchField: (context, search) => PlaceSearchField(search),
              confirm: (context, confirm) => FilledButton(onPressed: confirm, child: const Text('Use this place')),
            ),
          ),
        ),
      ],
    );
    await pumpRouter(tester, router);
    final result = router.push<PickedPlace>('/pick-place');
    await tester.pumpAndSettle();

    // Nothing chosen yet: the map's first rest on the world is not a choice.
    FilledButton button() => tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);

    map.startMove();
    map.idleAt(const GeoPoint(4.05, 9.7));
    await tester.pump();
    expect(find.text('Best guess: Rue Foch'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(find.text('Use this place'));
    await tester.pumpAndSettle();
    final place = await result;
    expect(place?.point, const GeoPoint(4.05, 9.7));
    expect(place?.guess?.label, 'Rue Foch');
  });

  testWidgets('a refused position leaves the pin without a point and says so', (tester) async {
    final map = FakeMapSurface();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinPicker(
            map: map,
            geocoder: FakeGeocoder(),
            position: FakePositionSource(const Denied(permanent: true)),
            guess: (context, guess) => GuessCard(guess),
            searchField: (context, search) => PlaceSearchField(search),
            confirm: (context, confirm) => FilledButton(onPressed: confirm, child: const Text('Use this place')),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Location is off for this app'), findsOneWidget);
    expect(map.moves, isEmpty);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });
}
```

`pumpRouter` boots a plain `MaterialApp.router`; `FakeMapSurface` is a box (`fakeMapKey`). To prove an ordering, build the
geocoder with `hold: true` and complete `reverseCalls[i]` in the order under test: a stale answer is dropped by sequence
number, and a test that completes them out of order shows it.

## Driving the model without a widget

`PinPickerModel` is a `ChangeNotifier` with no widget in it: `seed()`, `onMove()`, `onIdle(point)`, `search.submit(...)`,
`pick(place)`, `confirm()`. Use it to test a decision (what seeds the map, when the geocoder is asked) or to write a picker
with another layout; `PinPicker` is a short widget over it. Telemetry (`fespalier.maps.*`) is reported by the model, so
it is the same either way, and never carries a coordinate, a label or a query.
