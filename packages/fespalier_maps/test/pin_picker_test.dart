// The picker as a widget, on fakes: the pin at the centre, the three builders the app writes, a
// confirmation that comes back through a real `push<PickedPlace>`, and nothing that opens over
// the page.

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const home = GeoPoint(4.05, 9.7);
const there = GeoPoint(4.06, 9.71);
final douala = PlaceGuess(const GeoPoint(4.0511, 9.7679), 'Douala');

/// What an app writes: a card, a field with its results, a button.
class Fixture {
  Fixture({
    FakeGeocoder? geocoder,
    this.position,
    this.initial,
    this.onPicked,
    FakeMapSurface? map,
  }) : map = map ?? FakeMapSurface(),
       geocoder = geocoder ?? FakeGeocoder();

  final FakeMapSurface map;
  final FakeGeocoder geocoder;
  final FakePositionSource? position;
  final MapCamera? initial;
  final ValueChanged<PickedPlace>? onPicked;

  late final PinSearch lastSearch;
  PinGuess? lastGuess;

  Widget picker() => PinPicker(
    map: map,
    geocoder: geocoder,
    position: position,
    initial: initial,
    locale: 'en',
    onPicked: onPicked,
    guess: (context, guess) {
      lastGuess = guess;
      return Text(
        guess.guessing
            ? 'asking'
            : guess.guess == null
            ? 'no guess'
            : 'Best guess: ${guess.guess!.label}',
        key: const Key('card'),
      );
    },
    searchField: (context, search) => Column(
      children: [
        TextField(key: const Key('field'), onSubmitted: search.submit),
        for (final result in search.results)
          ListTile(
            key: Key('result:${result.label}'),
            title: Text(result.label),
            onTap: () => search.pick(result),
          ),
        TextButton(
          key: const Key('locate'),
          onPressed: search.useMyLocation,
          child: const Text('here'),
        ),
      ],
    ),
    confirm: (context, confirm) => ElevatedButton(
      key: const Key('confirm'),
      onPressed: confirm,
      child: const Text('Use this place'),
    ),
  );
}

Widget host(Widget body) => MaterialApp(home: Scaffold(body: body));

bool confirmEnabled(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.byKey(const Key('confirm'))).onPressed !=
    null;

void main() {
  testWidgets('the pin is fixed at the centre of the map, its tip on it', (
    tester,
  ) async {
    final f = Fixture();
    await tester.pumpWidget(host(f.picker()));
    final map = tester.getCenter(find.byKey(fakeMapKey));
    // The glyph's tip is 2/24 of its 48 px box above the bottom edge: that is the point.
    final tip = tester.getRect(find.byIcon(Icons.location_on)).bottomCenter;
    expect(tip.dx, closeTo(map.dx, 0.01));
    expect(tip.dy - 4, closeTo(map.dy, 0.01));
    expect(f.map.shown, MapCamera.world);
    // The map moving under it does not move the pin.
    f.map.startMove();
    await tester.pump();
    expect(
      tester.getRect(find.byIcon(Icons.location_on)).bottomCenter.dy - 4,
      closeTo(map.dy, 0.01),
    );
  });

  testWidgets('a custom pin sits with its bottom centre on the point', (
    tester,
  ) async {
    final f = Fixture();
    await tester.pumpWidget(
      host(
        PinPicker(
          map: f.map,
          geocoder: f.geocoder,
          pin: const SizedBox(key: Key('pin'), width: 20, height: 60),
          guess: (c, g) => const SizedBox.shrink(),
          searchField: (c, s) => const SizedBox.shrink(),
          confirm: (c, confirm) => const SizedBox.shrink(),
        ),
      ),
    );
    final map = tester.getCenter(find.byKey(fakeMapKey));
    expect(
      tester.getRect(find.byKey(const Key('pin'))).bottomCenter.dy,
      map.dy,
    );
  });

  testWidgets(
    'seeds once from the fix and keeps the map where the person put it',
    (tester) async {
      final position = FakePositionSource(const Fixed(home));
      final f = Fixture(
        position: position,
        geocoder: FakeGeocoder(reverseAnswer: (p) => PlaceGuess(p, 'Rue A')),
        map: FakeMapSurface(idleOnMove: true),
      );
      await tester.pumpWidget(host(f.picker()));
      await tester.pump();
      expect(position.calls, 1);
      expect(f.map.moves, [(center: home, zoom: 16.0)]);
      expect(find.text('Best guess: Rue A'), findsOneWidget);
      expect(confirmEnabled(tester), isTrue);
      // A rebuild of the parent with the same objects asks nothing again.
      await tester.pumpWidget(host(f.picker()));
      await tester.pump();
      expect(position.calls, 1);
    },
  );

  testWidgets('a refused permission leaves the map and shows the value', (
    tester,
  ) async {
    final f = Fixture(position: FakePositionSource(const Denied()));
    await tester.pumpWidget(host(f.picker()));
    await tester.pump();
    expect(f.map.moves, isEmpty);
    expect(f.lastGuess!.fix, isA<Denied>());
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets(
    'idle asks for a name and shows it as a guess; a late one is dropped',
    (tester) async {
      final f = Fixture(geocoder: FakeGeocoder(hold: true));
      await tester.pumpWidget(host(f.picker()));
      f.map.startMove();
      f.map.idleAt(home);
      await tester.pump();
      expect(find.text('asking'), findsOneWidget);
      f.map.startMove();
      f.map.idleAt(there);
      await tester.pump();
      expect(f.geocoder.reverseCalls, hasLength(1), reason: 'one at a time');
      f.geocoder.reverseCalls[0].complete(PlaceGuess(home, 'Old'));
      await tester.pump();
      expect(find.text('Best guess: Old'), findsNothing);
      f.geocoder.reverseCalls[1].complete(PlaceGuess(there, 'New'));
      await tester.pump();
      expect(find.text('Best guess: New'), findsOneWidget);
      expect(find.text('Best guess: Old'), findsNothing);
      expect(f.geocoder.reverseLocales, ['en', 'en']);
    },
  );

  testWidgets('submitting a search lists results; picking one moves the map', (
    tester,
  ) async {
    final f = Fixture(
      geocoder: FakeGeocoder(
        places: {
          'dou': [douala],
        },
      ),
    );
    await tester.pumpWidget(host(f.picker()));
    await tester.enterText(find.byKey(const Key('field')), 'dou');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.byKey(const Key('result:Douala')), findsOneWidget);
    await tester.tap(find.byKey(const Key('result:Douala')));
    await tester.pump();
    expect(f.map.moves.single.center, douala.point);
    expect(find.byKey(const Key('result:Douala')), findsNothing);
    expect(find.text('Best guess: Douala'), findsOneWidget);
  });

  testWidgets('"use my location" asks the source again', (tester) async {
    final position = FakePositionSource(const ServiceOff());
    final f = Fixture(position: position);
    await tester.pumpWidget(host(f.picker()));
    await tester.pump();
    position.answer = const Fixed(home);
    await tester.tap(find.byKey(const Key('locate')));
    await tester.pump();
    expect(position.calls, 2);
    expect(f.map.moves.single.center, home);
  });

  testWidgets('confirm hands the place to onPicked instead of popping', (
    tester,
  ) async {
    PickedPlace? picked;
    final f = Fixture(
      initial: const MapCamera(home),
      onPicked: (place) => picked = place,
      geocoder: FakeGeocoder(reverseAnswer: (p) => PlaceGuess(p, 'Rue A')),
    );
    await tester.pumpWidget(host(f.picker()));
    f.map.idleAt(home);
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm')));
    expect(picked, PickedPlace(home, guess: PlaceGuess(home, 'Rue A')));
  });

  testWidgets('confirm returns the place to the page that pushed it', (
    tester,
  ) async {
    final f = Fixture(
      initial: const MapCamera(home),
      geocoder: FakeGeocoder(reverseAnswer: (p) => PlaceGuess(p, 'Rue A')),
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('form')),
        ),
        GoRoute(
          path: '/pick',
          builder: (context, state) => Scaffold(body: f.picker()),
        ),
      ],
    );
    await pumpRouter(tester, router);
    final result = router.push<PickedPlace>('/pick');
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/pick');
    f.map.idleAt(there);
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm')));
    await tester.pumpAndSettle();
    expect(currentLocation(tester), '/');
    expect(await result, PickedPlace(there, guess: PlaceGuess(there, 'Rue A')));
  });

  testWidgets(
    'a parent that rebuilds with a new geocoder and locale keeps the map talking to the picker',
    (tester) async {
      final map = FakeMapSurface();
      final first = FakeGeocoder(reverseAnswer: (p) => PlaceGuess(p, 'First'));
      final second = FakeGeocoder(
        reverseAnswer: (p) => PlaceGuess(p, 'Second'),
      );
      Widget app(FakeGeocoder geocoder, String locale) => host(
        PinPicker(
          map: map,
          geocoder: geocoder,
          locale: locale,
          guess: (context, g) =>
              Text(g.guess?.label ?? 'none', key: const Key('card')),
          searchField: (context, s) => const SizedBox.shrink(),
          confirm: (context, confirm) => ElevatedButton(
            key: const Key('confirm'),
            onPressed: confirm,
            child: const Text('ok'),
          ),
        ),
      );
      await tester.pumpWidget(app(first, 'en'));
      map.startMove();
      map.idleAt(home);
      await tester.pump();
      expect(find.text('First'), findsOneWidget);
      // The map captured the callbacks of the first build; the picker must still hear it.
      await tester.pumpWidget(app(second, 'fr'));
      map.startMove();
      map.idleAt(there);
      await tester.pump();
      expect(find.text('Second'), findsOneWidget);
      expect(second.reverseLocales, ['fr']);
      expect(confirmEnabled(tester), isTrue);
    },
  );

  testWidgets(
    'confirm on a page opened with go (nothing to pop) does not throw',
    (tester) async {
      final f = Fixture(initial: const MapCamera(home));
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => Scaffold(body: f.picker()),
          ),
        ],
      );
      await pumpRouter(tester, router);
      f.map.idleAt(home);
      await tester.pump();
      await tester.tap(find.byKey(const Key('confirm')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(currentLocation(tester), '/');
    },
  );

  testWidgets('nothing opens over the page, whatever the person does', (
    tester,
  ) async {
    final f = Fixture(
      position: FakePositionSource(const Denied(permanent: true)),
      geocoder: FakeGeocoder()..error = 'boom',
    );
    await tester.pumpWidget(host(f.picker()));
    await tester.pump();
    f.map.startMove();
    f.map.idleAt(home);
    await tester.enterText(find.byKey(const Key('field')), 'x');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.byKey(const Key('locate')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(PopupMenuButton<Object?>), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.byType(ModalBarrier),
      findsOneWidget,
      reason: 'only the route\'s own',
    );
  });
}
