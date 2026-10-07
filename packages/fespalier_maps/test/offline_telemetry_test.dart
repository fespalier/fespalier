// The offline pack's telemetry contract: one operation per download, constants only, and nothing
// of the pack (its key, its rectangle, its style) in what a sink hears.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';

const secretKey = 'secret-shop-douala';

const request = RegionPackRequest(
  key: secretKey,
  bounds: GeoBounds(GeoPoint(4.0511, 9.7679), GeoPoint(4.1, 9.8)),
  styleUrl: 'https://tiles.example.com/secret-style.json',
  minZoom: 10,
  maxZoom: 12,
);

void main() {
  late RecordingTelemetry rec;
  late FakeOfflineTiles tiles;
  late ProviderContainer container;

  setUp(() {
    rec = RecordingTelemetry();
    FespalierTelemetry.install(rec);
    addTearDown(() => FespalierTelemetry.install(null));
    tiles = FakeOfflineTiles();
    container = ProviderContainer(
      overrides: [offlineTiles.overrideWithValue(tiles)],
    );
    addTearDown(container.dispose);
  });

  test('the names are the contract', () {
    expect(MapsTelemetry.download, 'fespalier.maps.download');
    expect(MapsTelemetry.kind, 'fespalier.maps.kind');
    expect(
      [
        MapsTelemetry.kindRegion,
        MapsTelemetry.resultComplete,
        MapsTelemetry.resultFailed,
        MapsTelemetry.resultCancelled,
      ],
      ['region', 'complete', 'failed', 'cancelled'],
    );
  });

  test('a download is one operation, from start to its end', () async {
    final packs = container.read(tilePacks.notifier);
    await packs.start(request);
    tiles.progress(secretKey, 0.5, bytes: 10);
    tiles.finish(secretKey);
    await pumpEventQueue();
    expect(rec.log, [
      '#1 start custom fespalier.maps.download fespalier.maps.kind=region',
      '#1 end custom ok async fespalier.maps.result=complete',
    ]);
  });

  test('a failure, a removal and a restart each end the operation', () async {
    final packs = container.read(tilePacks.notifier);
    await packs.start(request);
    tiles.fail(secretKey, PackFailure.limitExceeded);
    await packs.remove(secretKey);
    await packs.start(request);
    await packs.remove(secretKey);
    final ends = rec.log.where((l) => l.contains(' end ')).toList();
    expect(ends, [
      '#1 end custom error async fespalier.maps.result=failed',
      '#2 end custom superseded async fespalier.maps.result=cancelled',
    ]);
  });

  test('a pause keeps the operation open, a dispose ends it', () async {
    final packs = container.read(tilePacks.notifier);
    await packs.start(request);
    await packs.pause(secretKey);
    expect(rec.log.where((l) => l.contains(' end ')), isEmpty);
    container.dispose();
    expect(
      rec.log.last,
      '#1 end custom superseded async fespalier.maps.result=cancelled',
    );
  });

  test('nothing of the pack reaches a sink', () async {
    final packs = container.read(tilePacks.notifier);
    await packs.start(request);
    tiles.progress(secretKey, 0.5, bytes: 10);
    tiles.fail(secretKey, PackFailure.other);
    await packs.resume(secretKey);
    tiles.finish(secretKey);
    await pumpEventQueue();
    final heard = rec.log.join('\n');
    for (final secret in [
      secretKey,
      'secret-style',
      'tiles.example.com',
      '4.0511',
      '9.7679',
    ]) {
      expect(heard, isNot(contains(secret)));
    }
  });

  test('with no sink, nothing is started', () async {
    FespalierTelemetry.install(null);
    final packs = container.read(tilePacks.notifier);
    await packs.start(request);
    tiles.finish(secretKey);
    await pumpEventQueue();
    expect(rec.log, isEmpty);
  });
}
