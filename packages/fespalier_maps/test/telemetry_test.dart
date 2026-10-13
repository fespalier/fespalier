// The package's telemetry contract: three custom operations, their attribute names and values
// pinned, and no coordinate, label, query or error text anywhere in what a sink hears.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const home = GeoPoint(4.0511, 9.7679);

void main() {
  late RecordingTelemetry rec;

  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
  });

  test('the names are the contract', () {
    expect(MapsTelemetry.geocode, 'fespalier.maps.geocode');
    expect(MapsTelemetry.locate, 'fespalier.maps.locate');
    expect(MapsTelemetry.pick, 'fespalier.maps.pick');
    expect(MapsTelemetry.direction, 'fespalier.maps.direction');
    expect(MapsTelemetry.result, 'fespalier.maps.result');
    expect(MapsTelemetry.guessed, 'fespalier.maps.guessed');
    expect(
      [
        MapsTelemetry.directionSearch,
        MapsTelemetry.directionReverse,
        MapsTelemetry.resultFound,
        MapsTelemetry.resultEmpty,
        MapsTelemetry.resultError,
        MapsTelemetry.resultStale,
        MapsTelemetry.resultFixed,
        MapsTelemetry.resultOff,
        MapsTelemetry.resultDenied,
      ],
      [
        'search',
        'reverse',
        'found',
        'empty',
        'error',
        'stale',
        'fixed',
        'off',
        'denied',
      ],
    );
  });

  PinPickerModel model({FakeGeocoder? geocoder, FakePositionSource? position}) {
    final m = PinPickerModel(
      geocoder: geocoder ?? FakeGeocoder(),
      position: position,
    );
    FakeMapSurface().mount(m.binding);
    addTearDown(m.dispose);
    return m;
  }

  test(
    'a fix, a reverse, a search and a confirmation are each reported',
    () async {
      final m = model(
        geocoder: FakeGeocoder(
          reverseAnswer: (p) => PlaceGuess(p, 'Rue Secrète 12'),
          places: {
            'rue secrète': [PlaceGuess(home, 'Rue Secrète 12')],
          },
        ),
        position: FakePositionSource(const Fixed(home, accuracyMeters: 5)),
      );
      await m.seed();
      m.onIdle(home);
      await pumpEventQueue();
      await m.submit('rue secrète');
      m.confirm();
      expect(rec.log, [
        '#1 start custom fespalier.maps.locate',
        '#1 end custom ok async fespalier.maps.result=fixed',
        '#2 start custom fespalier.maps.geocode fespalier.maps.direction=reverse',
        '#2 end custom ok async fespalier.maps.result=found',
        '#3 start custom fespalier.maps.geocode fespalier.maps.direction=search',
        '#3 end custom ok async fespalier.maps.result=found',
        '#4 start custom fespalier.maps.pick fespalier.maps.guessed=true',
        '#4 end custom ok',
      ]);
    },
  );

  test('each way an operation ends has its own result', () async {
    final failing = model(
      geocoder: FakeGeocoder()..error = 'Rue Secrète 12 refused you',
      position: FakePositionSource(const Denied()),
    );
    await failing.seed();
    failing.onMove();
    failing.onIdle(home);
    await failing.submit('rue secrète');
    await pumpEventQueue();
    final empty = model();
    empty.onMove();
    empty.onIdle(home);
    await empty.submit('nothing');
    await pumpEventQueue();
    final off = model(position: FakePositionSource(const ServiceOff()));
    await off.seed();
    final unavailable = model(
      position: FakePositionSource(const Unavailable()),
    );
    await unavailable.seed();
    final results = rec.log
        .where((l) => l.contains(' end '))
        .map(
          (l) => RegExp(r'#\d+ end custom (\w+) .*result=(\w+)').firstMatch(l)!,
        )
        .map((m) => '${m[1]}:${m[2]}')
        .toList();
    expect(results, [
      'ok:denied',
      'error:error',
      'error:error',
      'ok:empty',
      'ok:empty',
      'ok:off',
      'error:error',
    ]);
  });

  test(
    'an answer that was dropped is reported as superseded and stale',
    () async {
      final geocoder = FakeGeocoder(hold: true);
      final m = model(geocoder: geocoder);
      m.onMove();
      m.onIdle(home);
      m.onMove();
      m.onIdle(const GeoPoint(4.06, 9.77));
      geocoder.reverseCalls[0].complete(null);
      await pumpEventQueue();
      geocoder.reverseCalls[1].complete(null);
      await pumpEventQueue();
      expect(
        rec.log,
        contains('#1 end custom superseded async fespalier.maps.result=stale'),
      );
      expect(
        rec.log,
        contains('#2 end custom ok async fespalier.maps.result=empty'),
      );
    },
  );

  test('no coordinate, label, query or error text is ever reported', () async {
    final secrets = [
      '4.05',
      '9.76',
      'Secrète',
      'refused you',
      'rue secrète',
      'near',
    ];
    final m = model(
      geocoder: FakeGeocoder(
        reverseAnswer: (p) => PlaceGuess(p, 'Rue Secrète 12', detail: 'Douala'),
        places: {
          'rue secrète': [PlaceGuess(home, 'Rue Secrète 12')],
        },
      ),
      position: FakePositionSource(const Fixed(home, accuracyMeters: 5)),
    );
    await m.seed();
    m.onIdle(home);
    await pumpEventQueue();
    await m.submit('rue secrète');
    m.confirm();
    final failing = model(
      geocoder: FakeGeocoder()..error = 'Rue Secrète 12 refused you',
    );
    failing.onMove();
    failing.onIdle(home);
    await failing.submit('rue secrète');
    await pumpEventQueue();
    expect(rec.log, isNotEmpty);
    final heard = rec.log.join('\n');
    for (final secret in secrets) {
      expect(heard, isNot(contains(secret)), reason: secret);
    }
  });

  test('with no sink installed nothing is started', () async {
    FespalierTelemetry.install(null);
    final m = model(position: FakePositionSource(const Fixed(home)));
    await m.seed();
    m.onIdle(home);
    await pumpEventQueue();
    m.confirm();
    expect(rec.log, isEmpty);
  });

  test('a sink that throws costs the span, never the picker', () async {
    FespalierTelemetry.install(_ThrowingSink());
    final m = model(position: FakePositionSource(const Fixed(home)));
    await m.seed();
    expect(m.center, home);
    expect(m.confirm(), PickedPlace(home));
  });
}

class _ThrowingSink extends FespalierTelemetry {
  @override
  Object? start(TelemetryStart start) => throw StateError('sink broke');
}
