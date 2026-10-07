// The decisions of a pin picker, with fakes and no widget: what seeds the map, when the geocoder
// is asked, which answers are dropped, what a confirmation holds.
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const home = GeoPoint(4.05, 9.7);
const there = GeoPoint(4.06, 9.71);

PlaceGuess named(String label, GeoPoint at) => PlaceGuess(at, label);

class Rig {
  Rig({
    FakeGeocoder? geocoder,
    this.position,
    MapCamera? initial,
    String? locale,
    FakeMapSurface? map,
  }) : map = map ?? FakeMapSurface(),
       geocoder = geocoder ?? FakeGeocoder() {
    model = PinPickerModel(
      map: this.map,
      geocoder: this.geocoder,
      position: position,
      initial: initial,
      locale: locale,
    );
    addTearDown(model.dispose);
  }

  final FakeMapSurface map;
  final FakeGeocoder geocoder;
  final FakePositionSource? position;
  late final PinPickerModel model;

  /// A chosen, settled pin at [at] (the person moved the map there).
  void settleAt(GeoPoint at) {
    model.onMove();
    model.onIdle(at);
  }
}

void main() {
  group('seeding from the device position', () {
    test('a fix moves the map once and the pin takes its point', () async {
      final position = FakePositionSource(const Fixed(home, accuracyMeters: 8));
      final rig = Rig(position: position);
      expect(rig.model.center, isNull);
      expect(rig.model.canConfirm, isFalse);
      await rig.model.seed();
      await rig.model.seed();
      expect(position.calls, 1, reason: 'seeded once');
      expect(rig.map.moves, [(center: home, zoom: 16.0)]);
      expect(rig.model.center, home);
      expect(rig.model.guessState.fix, isA<Fixed>());
    });

    for (final (name, fix) in <(String, PositionFix)>[
      ('a switched-off service', const ServiceOff()),
      ('a refusal', const Denied(permanent: true)),
      ('no position', const Unavailable()),
    ]) {
      test('$name does not move the map and is a value for the app', () async {
        final rig = Rig(position: FakePositionSource(fix));
        await rig.model.seed();
        expect(rig.map.moves, isEmpty);
        expect(rig.model.center, isNull);
        expect(rig.model.guessState.fix, same(fix));
        // The map's own first rest, on the world, is not a choice.
        rig.model.onIdle(const GeoPoint(0, 0));
        expect(rig.model.center, isNull);
        expect(rig.model.canConfirm, isFalse);
        expect(rig.model.confirm(), isNull);
        expect(rig.geocoder.reverseCalls, isEmpty);
        // The person moves the map: that is.
        rig.settleAt(there);
        expect(rig.model.center, there);
        expect(rig.model.canConfirm, isTrue);
      });
    }

    test('a move while the fix is awaited is ignored: the fix lands', () async {
      final position = FakePositionSource(const Fixed(home), hold: true);
      final rig = Rig(position: position);
      final seeding = rig.model.seed();
      rig.model.onMove();
      rig.model.onIdle(there);
      expect(rig.model.center, isNull);
      position.release();
      await seeding;
      expect(rig.model.center, home);
    });

    test(
      'an initial camera is the start and the position is not asked',
      () async {
        final position = FakePositionSource(const Fixed(home));
        final rig = Rig(
          position: position,
          initial: const MapCamera(there, zoom: 12),
        );
        await rig.model.seed();
        expect(position.calls, 0);
        expect(rig.map.moves, isEmpty);
        expect(rig.model.initialCamera, const MapCamera(there, zoom: 12));
        expect(rig.model.center, there);
        expect(rig.model.canConfirm, isTrue);
      },
    );

    test(
      'no initial camera and no position: the world, and nothing chosen',
      () {
        final rig = Rig();
        expect(rig.model.initialCamera, MapCamera.world);
        expect(rig.model.center, isNull);
      },
    );

    test('"use my location" asks again and moves to the answer', () async {
      final position = FakePositionSource(const Denied());
      final rig = Rig(position: position);
      await rig.model.seed();
      expect(rig.map.moves, isEmpty);
      position.answer = const Fixed(home);
      await rig.model.useMyLocation();
      expect(position.calls, 2);
      expect(rig.map.moves.single.center, home);
      expect(rig.model.guessState.fix, isA<Fixed>());
      position.answer = const Denied();
      await rig.model.useMyLocation();
      expect(rig.map.moves, hasLength(1), reason: 'a refusal does not move it');
      expect(rig.model.guessState.fix, isA<Denied>());
    });

    test('without a position source "use my location" does nothing', () async {
      final rig = Rig();
      await rig.model.useMyLocation();
      expect(rig.map.moves, isEmpty);
      expect(rig.model.guessState.fix, isNull);
    });

    test('an answer after dispose is ignored', () async {
      final position = FakePositionSource(const Fixed(home), hold: true);
      final rig = Rig(position: position);
      final seeding = rig.model.seed();
      rig.model.dispose();
      position.release();
      await seeding;
      expect(rig.map.moves, isEmpty);
    });
  });

  group('reverse geocoding', () {
    test('runs when the map comes to rest, not while it moves', () async {
      final rig = Rig(
        geocoder: FakeGeocoder(reverseAnswer: (p) => named('Rue A', p)),
        locale: 'fr',
      );
      rig.model.onMove();
      expect(rig.model.guessState.moving, isTrue);
      expect(rig.model.canConfirm, isFalse);
      expect(rig.geocoder.reverseCalls, isEmpty);
      rig.model.onIdle(home);
      expect(rig.model.guessState.guessing, isTrue);
      expect(rig.model.guessState.guess, isNull);
      await pumpEventQueue();
      expect(rig.geocoder.reverseCalls.single.argument, home);
      expect(rig.geocoder.reverseLocales, ['fr']);
      final state = rig.model.guessState;
      expect(state.guessing, isFalse);
      expect(state.moving, isFalse);
      expect(state.guess, named('Rue A', home));
      expect(state.center, home);
    });

    test(
      'an answer that a newer idle overtook is dropped, either order',
      () async {
        for (final newestFirst in [true, false]) {
          final rig = Rig(geocoder: FakeGeocoder(hold: true));
          rig.settleAt(home);
          rig.model.onMove();
          rig.model.onIdle(there);
          final calls = rig.geocoder.reverseCalls;
          expect(calls, hasLength(2));
          if (newestFirst) {
            calls[1].complete(named('there', there));
            calls[0].complete(named('home', home));
          } else {
            calls[0].complete(named('home', home));
            calls[1].complete(named('there', there));
          }
          await pumpEventQueue();
          expect(rig.model.guessState.guess, named('there', there));
          expect(rig.model.guessState.guessing, isFalse);
          expect(rig.model.confirm()?.guess, named('there', there));
        }
      },
    );

    test(
      'a failure is a flag, never text, and the next idle asks again',
      () async {
        final rig = Rig(
          geocoder: FakeGeocoder()..error = 'secret failure text',
        );
        rig.settleAt(home);
        await pumpEventQueue();
        var state = rig.model.guessState;
        expect(state.failed, isTrue);
        expect(state.guess, isNull);
        expect(state.guessing, isFalse);
        rig.geocoder.error = null;
        rig.geocoder.reverseAnswer = (p) => named('ok', p);
        rig.model.onIdle(home);
        await pumpEventQueue();
        state = rig.model.guessState;
        expect(state.failed, isFalse);
        expect(state.guess?.label, 'ok');
        expect(rig.geocoder.reverseCalls, hasLength(2));
      },
    );

    test(
      'nothing there is an answer: the same point is not asked twice',
      () async {
        final rig = Rig();
        rig.settleAt(home);
        await pumpEventQueue();
        expect(rig.model.guessState.guess, isNull);
        expect(rig.model.guessState.failed, isFalse);
        rig.model.onMove();
        rig.model.onIdle(home);
        await pumpEventQueue();
        expect(rig.geocoder.reverseCalls, hasLength(1));
      },
    );

    test('an answer after dispose is ignored', () async {
      final rig = Rig(geocoder: FakeGeocoder(hold: true));
      rig.settleAt(home);
      rig.model.dispose();
      rig.geocoder.reverseCalls.single.complete(named('late', home));
      await pumpEventQueue();
    });
  });

  group('forward search', () {
    final douala = named('Douala', const GeoPoint(4.0511, 9.7679));
    final doual = named('Doual', const GeoPoint(50.37, 3.08));

    test(
      'submit lists the results, biased to the pin, in the locale',
      () async {
        final rig = Rig(
          geocoder: FakeGeocoder(
            places: {
              'dou': [douala, doual],
            },
          ),
          locale: 'en',
        );
        rig.settleAt(home);
        rig.model.search.submit(' dou ');
        expect(rig.model.search.busy, isTrue);
        await pumpEventQueue();
        final search = rig.model.search;
        expect(search.busy, isFalse);
        expect(search.failed, isFalse);
        expect(search.query, 'dou');
        expect(search.results, [douala, doual]);
        expect(rig.geocoder.searchCalls.single.argument, 'dou');
        expect(rig.geocoder.searchContext.single, (near: home, locale: 'en'));
      },
    );

    test('an empty query clears and asks nothing', () async {
      final rig = Rig(
        geocoder: FakeGeocoder(
          places: {
            'dou': [douala],
          },
        ),
      );
      rig.model.search.submit('dou');
      await pumpEventQueue();
      expect(rig.model.search.results, isNotEmpty);
      rig.model.search.submit('   ');
      expect(rig.model.search.results, isEmpty);
      expect(rig.geocoder.searchCalls, hasLength(1));
    });

    test('a failure is a flag; an older answer is dropped', () async {
      final rig = Rig(geocoder: FakeGeocoder(hold: true));
      rig.model.search.submit('one');
      rig.model.search.submit('two');
      final calls = rig.geocoder.searchCalls;
      calls[1].complete([douala]);
      calls[0].complete([doual]);
      await pumpEventQueue();
      expect(rig.model.search.results, [douala]);
      expect(rig.model.search.query, 'two');
      rig.model.search.submit('three');
      rig.geocoder.searchCalls.last.fail('the query leaked into this');
      await pumpEventQueue();
      expect(rig.model.search.failed, isTrue);
      expect(rig.model.search.results, isEmpty);
      expect(rig.model.search.busy, isFalse);
    });

    test(
      'picking a result moves the map and shows its label as the guess',
      () async {
        final rig = Rig(
          geocoder: FakeGeocoder(
            places: {
              'dou': [douala],
            },
          ),
        );
        rig.model.search.submit('dou');
        await pumpEventQueue();
        rig.model.search.pick(douala);
        await pumpEventQueue();
        expect(rig.map.moves, [(center: douala.point, zoom: 16.0)]);
        expect(rig.model.search.results, isEmpty);
        expect(rig.model.center, douala.point);
        expect(rig.model.guessState.guess, douala);
        expect(rig.model.canConfirm, isTrue);
        // The map's rest at (nearly) that point does not ask the geocoder to disagree.
        rig.model.onMove();
        rig.model.onIdle(
          GeoPoint(douala.point.latitude + 1e-7, douala.point.longitude),
        );
        await pumpEventQueue();
        expect(rig.geocoder.reverseCalls, isEmpty);
        expect(rig.model.guessState.guess, douala);
        expect(rig.model.confirm()?.guess, douala);
      },
    );

    test('picking drops a reverse answer that was on its way', () async {
      final rig = Rig(geocoder: FakeGeocoder(hold: true));
      rig.settleAt(home);
      rig.model.search.pick(douala);
      rig.geocoder.reverseCalls.single.complete(named('old', home));
      await pumpEventQueue();
      expect(rig.model.guessState.guess, douala);
    });

    test('clear drops the query and the results', () async {
      final rig = Rig(
        geocoder: FakeGeocoder(
          places: {
            'dou': [douala],
          },
        ),
      );
      rig.model.search.submit('dou');
      await pumpEventQueue();
      rig.model.search.clear();
      expect(rig.model.search.query, isEmpty);
      expect(rig.model.search.results, isEmpty);
    });
  });

  group('confirming', () {
    test(
      'returns the point, and the guess only if it was made for it',
      () async {
        final rig = Rig(
          geocoder: FakeGeocoder(reverseAnswer: (p) => named('A', p)),
        );
        expect(rig.model.confirm(), isNull, reason: 'no point yet');
        rig.settleAt(home);
        expect(rig.model.confirm(), PickedPlace(home), reason: 'still asking');
        await pumpEventQueue();
        expect(rig.model.confirm(), PickedPlace(home, guess: named('A', home)));
        rig.model.onMove();
        expect(rig.model.confirm(), isNull, reason: 'the map is moving');
      },
    );

    test('a guess for another point is not returned', () async {
      final rig = Rig(geocoder: FakeGeocoder(hold: true));
      rig.settleAt(home);
      rig.model.onMove();
      rig.model.onIdle(there);
      rig.geocoder.reverseCalls[0].complete(named('home', home));
      await pumpEventQueue();
      expect(rig.model.confirm(), PickedPlace(there));
    });
  });

  test('a listener hears each change, and none after dispose', () async {
    final rig = Rig();
    var heard = 0;
    rig.model.addListener(() => heard++);
    rig.settleAt(home);
    await pumpEventQueue();
    expect(heard, greaterThan(0));
    rig.model.dispose();
    // A late call must not throw a "used after dispose" error.
    rig.model.onMove();
  });
}
