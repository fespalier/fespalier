// The fakes in testing.dart keep their word, since every other test leans on them.
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const home = GeoPoint(4.05, 9.7);

void main() {
  test(
    'GeoPoint, GeoBounds, MapCamera, PlaceGuess and PickedPlace are values',
    () {
      expect(const GeoPoint(1, 2), const GeoPoint(1, 2));
      expect(const GeoPoint(1, 2).hashCode, const GeoPoint(1, 2).hashCode);
      expect(const GeoPoint(1, 2), isNot(const GeoPoint(2, 1)));
      expect(
        const GeoBounds(GeoPoint(0, 0), GeoPoint(1, 1)),
        const GeoBounds(GeoPoint(0, 0), GeoPoint(1, 1)),
      );
      expect(const MapCamera(home), const MapCamera(home, zoom: 15));
      expect(const MapCamera(home), isNot(const MapCamera(home, zoom: 3)));
      expect(
        PlaceGuess(home, 'a', detail: 'b'),
        PlaceGuess(home, 'a', detail: 'b'),
      );
      expect(PlaceGuess(home, 'a'), isNot(PlaceGuess(home, 'b')));
      expect(PickedPlace(home), PickedPlace(home));
      expect(
        PickedPlace(home, guess: PlaceGuess(home, 'a')),
        isNot(PickedPlace(home)),
      );
    },
  );

  test('a point out of range is refused in debug', () {
    expect(() => GeoPoint(91, 0), throwsA(isA<AssertionError>()));
    expect(() => GeoPoint(0, 181), throwsA(isA<AssertionError>()));
    expect(() => GeoPoint(double.nan, 0), throwsA(isA<AssertionError>()));
  });

  testWidgets('FakeMapSurface builds a box, records moves and plays the map', (
    tester,
  ) async {
    final map = FakeMapSurface(idleOnMove: true);
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => map.build(
            context,
            const MapCamera(home, zoom: 9),
            onIdle: (c) => events.add('idle'),
            onMove: () => events.add('move'),
          ),
        ),
      ),
    );
    expect(find.byKey(fakeMapKey), findsOneWidget);
    expect(map.shown, const MapCamera(home, zoom: 9));
    map.startMove();
    await map.moveTo(home, zoom: 12);
    expect(events, ['move', 'idle']);
    expect(map.moves, [(center: home, zoom: 12.0)]);
  });

  test('FakeGeocoder answers from its tables, or holds, or throws', () async {
    final geocoder = FakeGeocoder(
      places: {
        'a': [PlaceGuess(home, 'A')],
      },
      reverseAnswer: (p) => PlaceGuess(p, 'here'),
    );
    expect(await geocoder.search('a'), [PlaceGuess(home, 'A')]);
    expect(await geocoder.search('b'), isEmpty);
    expect((await geocoder.reverse(home))?.label, 'here');
    geocoder.error = StateError('x');
    await expectLater(geocoder.search('a'), throwsStateError);
    await expectLater(geocoder.reverse(home), throwsStateError);

    final held = FakeGeocoder(hold: true);
    final answer = held.reverse(home);
    expect(held.reverseCalls.single.isCompleted, isFalse);
    held.reverseCalls.single.complete(PlaceGuess(home, 'late'));
    expect((await answer)?.label, 'late');
  });

  test('FakePositionSource answers, counts and can hold', () async {
    final source = FakePositionSource(const Fixed(home));
    expect(await source.current(), isA<Fixed>());
    expect(source.calls, 1);
    final held = FakePositionSource(const ServiceOff(), hold: true);
    final answer = held.current();
    held.release(const Denied(permanent: true));
    expect(await answer, isA<Denied>());
  });
}
