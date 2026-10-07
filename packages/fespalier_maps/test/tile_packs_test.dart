// Region packs against a fake offline database: progress to statuses, pause and resume within
// the session, the restart path, removal, refresh, storage and the way a download that ends
// while another call is in flight is settled.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const style = 'https://tiles.example.com/style.json';

// A different rectangle per key: MapLibre treats two regions with one definition as one.
RegionPackRequest pack(String key, {double maxZoom = 12}) {
  final shift = key.codeUnits.fold<int>(0, (a, b) => a + b) / 1000;
  return RegionPackRequest(
    key: key,
    bounds: GeoBounds(GeoPoint(4.0 + shift, 9.65), GeoPoint(4.12 + shift, 9.8)),
    styleUrl: style,
    minZoom: 10,
    maxZoom: maxZoom,
  );
}

void main() {
  late FakeOfflineTiles tiles;
  late ProviderContainer container;

  ProviderContainer make(FakeOfflineTiles fake) {
    final c = ProviderContainer(
      overrides: [offlineTiles.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    tiles = FakeOfflineTiles();
    container = make(tiles);
  });

  TilePacks packs() => container.read(tilePacks.notifier);
  PackStatus status(String key) => container.read(tilePackStatus(key));

  test('a request is validated before anything reaches the database', () {
    expect(pack('a').isValid, isTrue);
    expect(pack('').isValid, isFalse);
    expect(pack('a', maxZoom: 9).isValid, isFalse);
    expect(pack('a', maxZoom: 23).isValid, isFalse);
    expect(
      const RegionPackRequest(
        key: 'a',
        bounds: GeoBounds(GeoPoint(0, 170), GeoPoint(1, -170)),
        styleUrl: style,
        minZoom: 1,
        maxZoom: 2,
      ).isValid,
      isFalse,
      reason: 'crosses the antimeridian',
    );
    expect(
      pack('a').estimatedTiles,
      tileCount(pack('a').bounds, minZoom: 10, maxZoom: 12),
    );
  });

  test(
    'an invalid request ends in Failed(invalidRegion) and starts nothing',
    () async {
      await packs().start(pack('a', maxZoom: 9));
      expect(status('a'), const Failed(PackFailure.invalidRegion));
      expect(tiles.downloads, isEmpty);
    },
  );

  test(
    'progress events become Downloading, and the end becomes Complete',
    () async {
      await packs().start(pack('a'));
      expect(status('a'), const Downloading());
      tiles.progress(
        'a',
        0.25,
        completedResources: 5,
        requiredResources: 20,
        bytes: 900,
      );
      expect(
        status('a'),
        const Downloading(
          progress: 0.25,
          completedResources: 5,
          requiredResources: 20,
          bytes: 900,
        ),
      );
      tiles.finish('a', bytes: 4000);
      await pumpEventQueue();
      expect(status('a'), const Complete(bytes: 4000));
      expect(container.read(tilePacks).keys, ['a']);
    },
  );

  test('events heard before the download call returns are kept', () async {
    tiles = FakeOfflineTiles(holdDownloads: true);
    container = make(tiles);
    final started = packs().start(pack('a'));
    await pumpEventQueue();
    tiles.progress('a', 0.5, bytes: 10);
    expect(status('a'), const Downloading(progress: 0.5, bytes: 10));
    tiles.finish('a', bytes: 77);
    expect(status('a'), const Complete(bytes: 10));
    tiles.releaseDownloads();
    await started;
    await pumpEventQueue();
    expect(
      status('a'),
      const Complete(bytes: 77),
      reason: 'the final size is read once the id is known',
    );
  });

  test('a second start of a running pack does nothing', () async {
    await packs().start(pack('a'));
    await packs().start(pack('a'));
    expect(tiles.downloads, hasLength(1));
  });

  test('pause and resume go to the region and show in the status', () async {
    await packs().start(pack('a'));
    tiles.progress('a', 0.4, bytes: 300);
    await packs().pause('a');
    expect(status('a'), const Paused(progress: 0.4, bytes: 300));
    expect(tiles.pauses, [tiles.regionOf('a')!.id]);
    // Events that trail the pause do not move a paused pack.
    tiles.progress('a', 0.5, bytes: 400);
    expect(status('a'), const Paused(progress: 0.4, bytes: 300));
    await packs().resume('a');
    expect(status('a'), const Downloading(progress: 0.4, bytes: 300));
    tiles.progress('a', 0.9, bytes: 800);
    expect(status('a'), const Downloading(progress: 0.9, bytes: 800));
  });

  test('a pause MapLibre refuses leaves the download running', () async {
    await packs().start(pack('a'));
    tiles.pauseError = PlatformException(code: 'x');
    await packs().pause('a');
    expect(status('a'), isA<Downloading>());
  });

  test(
    'pause and resume of a pack that is not in that state do nothing',
    () async {
      await packs().pause('a');
      await packs().resume('a');
      expect(tiles.pauses, isEmpty);
      expect(tiles.resumes, isEmpty);
      expect(status('a'), const Absent());
    },
  );

  test('a download that ends while paused is complete', () async {
    await packs().start(pack('a'));
    await packs().pause('a');
    tiles.finish('a');
    await pumpEventQueue();
    expect(status('a'), isA<Complete>());
  });

  test('a failure event ends in Failed with the reason, as a value', () async {
    await packs().start(pack('a'));
    tiles.fail('a', PackFailure.limitExceeded);
    expect(status('a'), const Failed(PackFailure.limitExceeded));
  });

  test(
    'a download call that throws maps the error and keeps no text',
    () async {
      tiles.downloadError = UnsupportedError('web');
      await packs().start(pack('a'));
      expect(status('a'), const Failed(PackFailure.unsupported));
      tiles.downloadError = PlatformException(
        code: 'invalidRegionDefinition',
        message: 'https://secret',
      );
      await packs().start(pack('a'));
      expect(status('a'), const Failed(PackFailure.invalidRegion));
      tiles.downloadError = StateError('boom');
      await packs().start(pack('a'));
      expect(status('a'), const Failed(PackFailure.other));
    },
  );

  test('resume of a failed pack starts it again', () async {
    tiles.downloadError = StateError('offline');
    await packs().start(pack('a'));
    tiles.downloadError = null;
    await packs().resume('a');
    expect(status('a'), isA<Downloading>());
    expect(tiles.downloads, hasLength(2));
  });

  test(
    'a restart leaves a downloading region Interrupted; resume starts it again and removes the old one',
    () async {
      final old = tiles.seed(
        pack('a'),
        complete: false,
        progress: 0.3,
        bytes: 500,
      );
      await packs().refresh();
      expect(status('a'), const Interrupted(progress: 0.3, bytes: 500));

      await packs().resume('a');
      expect(status('a'), isA<Downloading>());
      expect(tiles.downloads, hasLength(1));
      expect(
        tiles.resumes,
        isEmpty,
        reason: 'the old download cannot be resumed',
      );
      expect(tiles.all.map((r) => r.id), [
        tiles.regionOf('a')!.id,
      ], reason: 'the plugin replaced the old region when the download began');

      tiles.progress('a', 0.6, bytes: 900);
      tiles.finish('a', bytes: 2000);
      await pumpEventQueue();
      expect(status('a'), const Complete(bytes: 2000));
      expect(tiles.all.map((r) => r.id), [tiles.regionOf('a')!.id]);
      expect(tiles.regionOf('a')!.id, isNot(old.id));
    },
  );

  test(
    'a paused pack whose download was lost becomes Interrupted, and a second resume restarts it',
    () async {
      await packs().start(pack('a'));
      tiles.progress('a', 0.2, bytes: 100);
      await packs().pause('a');
      tiles.restart();
      await packs().resume('a');
      expect(status('a'), const Interrupted(progress: 0.2, bytes: 100));
      await packs().resume('a');
      expect(status('a'), isA<Downloading>());
      expect(tiles.downloads, hasLength(2));
    },
  );

  test(
    'remove deletes the region, stops events and forgets the pack',
    () async {
      await packs().start(pack('a'));
      final id = tiles.regionOf('a')!.id;
      await packs().remove('a');
      expect(tiles.deleted, [id]);
      expect(container.read(tilePacks), isEmpty);
      expect(status('a'), const Absent());
      // A late event of the removed download changes nothing.
      tiles.progress('a', 0.9);
      expect(container.read(tilePacks), isEmpty);
    },
  );

  test(
    'remove while the download call is still pending frees the region it makes',
    () async {
      tiles = FakeOfflineTiles(holdDownloads: true);
      container = make(tiles);
      final started = packs().start(pack('a'));
      await pumpEventQueue();
      await packs().remove('a');
      tiles.releaseDownloads();
      await started;
      await pumpEventQueue();
      expect(tiles.all, isEmpty);
      expect(container.read(tilePacks), isEmpty);
    },
  );

  test('a delete that fails marks the pack Failed and throws', () async {
    await packs().start(pack('a'));
    tiles.deleteError = StateError('busy');
    await expectLater(packs().remove('a'), throwsStateError);
    expect(status('a'), const Failed(PackFailure.other));
    tiles.deleteError = null;
    await packs().remove('a');
    expect(container.read(tilePacks), isEmpty);
  });

  test(
    'refresh reads complete and unfinished regions, drops gone packs',
    () async {
      tiles.seed(pack('done'), bytes: 1234);
      tiles.seed(pack('half'), complete: false, progress: 0.5, bytes: 10);
      await packs().refresh();
      expect(status('done'), const Complete(bytes: 1234));
      expect(status('half'), const Interrupted(progress: 0.5, bytes: 10));

      // A region deleted behind our back leaves the state at the next refresh.
      await tiles.delete(tiles.regionOf('done')!.id);
      await packs().refresh();
      expect(status('done'), const Absent());
      expect(status('half'), isA<Interrupted>());
    },
  );

  test(
    'refresh does not touch a pack that is downloading in this session',
    () async {
      await packs().start(pack('a'));
      tiles.progress('a', 0.3, bytes: 5);
      await packs().refresh();
      expect(status('a'), const Downloading(progress: 0.3, bytes: 5));
    },
  );

  test('refresh keeps the state when the database cannot be read', () async {
    tiles.seed(pack('a'));
    await packs().refresh();
    tiles.regionsError = StateError('no');
    await packs().refresh();
    expect(status('a'), isA<Complete>());
  });

  test('storage sums per pack and reports the file', () async {
    tiles = FakeOfflineTiles(databaseSize: 9000);
    container = make(tiles);
    tiles.seed(pack('a'), bytes: 100);
    tiles.seed(pack('b'), bytes: 250);
    await packs().refresh();
    final use = await packs().storage();
    expect(use.perPack, {'a': 100, 'b': 250});
    expect(use.packSum, 350);
    expect(use.onDisk, 9000);
    tiles.databaseSize = null;
    expect((await packs().storage()).onDisk, isNull);
  });

  test('two packs are independent', () async {
    await packs().start(pack('a'));
    await packs().start(pack('b'));
    tiles.progress('a', 0.1);
    tiles.progress('b', 0.8);
    await packs().pause('a');
    expect(status('a'), isA<Paused>());
    expect(status('b'), const Downloading(progress: 0.8));
  });

  test('the offline database has no default', () {
    final bare = ProviderContainer();
    addTearDown(bare.dispose);
    expect(() => bare.read(offlineTiles), throwsA(anything));
  });

  test('PackFailure maps what the platform throws', () {
    expect(PackFailure.of(UnsupportedError('x')), PackFailure.unsupported);
    expect(PackFailure.of(MissingPluginException()), PackFailure.unsupported);
    expect(
      PackFailure.of(PlatformException(code: 'tileCountLimitExceeded')),
      PackFailure.limitExceeded,
    );
    expect(PackFailure.of(ArgumentError('x')), PackFailure.invalidRegion);
    expect(PackFailure.of('anything'), PackFailure.other);
  });

  group(
    'the way maplibre_gl 0.27 treats a definition that already has a region',
    () {
      test(
        'iOS: the new region takes the old id, and the finished pack is kept',
        () async {
          tiles = FakeOfflineTiles(duplicates: FakeDuplicates.reuseId);
          container = make(tiles);
          final old = tiles.seed(pack('a'), complete: false, progress: 0.3);
          await packs().refresh();
          await packs().resume('a');
          expect(tiles.regionOf('a')!.id, old.id, reason: 'same id');
          tiles.finish('a', bytes: 500);
          await pumpEventQueue();
          expect(status('a'), const Complete(bytes: 500));
          expect(tiles.all.map((r) => r.id), [
            old.id,
          ], reason: 'the pack is still there');
          expect(tiles.deleted, isEmpty);
        },
      );

      test(
        'Android: the old region is gone at the start and the pack completes',
        () async {
          final old = tiles.seed(pack('a'));
          await packs().refresh();
          await packs().start(pack('a'));
          expect(tiles.all.map((r) => r.id), isNot(contains(old.id)));
          tiles.finish('a', bytes: 900);
          await pumpEventQueue();
          expect(status('a'), const Complete(bytes: 900));
          expect(tiles.all, hasLength(1));
          expect(tiles.all.single.isComplete, isTrue);
        },
      );

      test('a failed re-download of a complete pack is Failed', () async {
        tiles.seed(pack('a'));
        await packs().refresh();
        await packs().start(pack('a'));
        tiles.fail('a', PackFailure.other);
        expect(status('a'), const Failed(PackFailure.other));
      });

      test(
        'the error of a region that was deleted does not come back',
        () async {
          await packs().start(pack('a'));
          tiles.progress('a', 0.5);
          expect(status('a'), isA<Downloading>());
          await packs().remove('a');
          expect(container.read(tilePacks), isEmpty);
        },
      );

      test('the replaced error of a running download is a failure', () async {
        await packs().start(pack('a'));
        await tiles.delete(tiles.regionOf('a')!.id);
        expect(status('a'), const Failed(PackFailure.replaced));
      });

      test(
        'two keys with one definition: the second is refused, the first stays',
        () async {
          await packs().start(pack('a'));
          final same = RegionPackRequest(
            key: 'b',
            bounds: pack('a').bounds,
            styleUrl: style,
            minZoom: 10,
            maxZoom: 12,
          );
          await packs().start(same);
          expect(status('b'), const Failed(PackFailure.duplicateRegion));
          expect(tiles.downloads, hasLength(1));
          tiles.progress('a', 0.4);
          expect(status('a'), const Downloading(progress: 0.4));
          await packs().remove('a');
          await packs().start(same);
          expect(
            status('b'),
            isA<Downloading>(),
            reason: 'free once a is gone',
          );
        },
      );
    },
  );

  group('refresh picks the complete region of a key, whatever the ids', () {
    for (final completeFirst in [true, false]) {
      test(
        'complete ${completeFirst ? 'has the lower' : 'has the higher'} id',
        () async {
          FakeRegion seedComplete() => tiles.seed(pack('a'), bytes: 700);
          FakeRegion seedPartial() =>
              tiles.seed(pack('a'), complete: false, progress: 0.2);
          final FakeRegion complete;
          final FakeRegion partial;
          if (completeFirst) {
            complete = seedComplete();
            partial = seedPartial();
          } else {
            partial = seedPartial();
            complete = seedComplete();
          }
          await packs().refresh();
          expect(status('a'), const Complete(bytes: 700));
          expect(tiles.all.map((r) => r.id), [complete.id]);
          expect(tiles.deleted, [partial.id]);
        },
      );
    }

    test(
      'with none complete the highest id is kept and the others go at the restart',
      () async {
        final low = tiles.seed(pack('a'), complete: false, progress: 0.1);
        final high = tiles.seed(pack('a'), complete: false, progress: 0.6);
        await packs().refresh();
        expect(status('a'), const Interrupted(progress: 0.6, bytes: 1000));
        expect(tiles.deleted, isEmpty);
        await packs().resume('a');
        tiles.finish('a');
        await pumpEventQueue();
        final ids = tiles.all.map((r) => r.id).toList();
        expect(ids, [tiles.regionOf('a')!.id]);
        expect(ids, isNot(contains(low.id)));
        expect(ids, isNot(contains(high.id)));
      },
    );
  });

  group('remove and start overlap', () {
    test('a start during remove keeps its download', () async {
      tiles.seed(pack('a'), complete: false);
      await packs().refresh();
      final removing = packs().remove('a');
      await packs().start(pack('a'));
      await removing;
      expect(status('a'), isA<Downloading>());
      tiles.finish('a', bytes: 5);
      await pumpEventQueue();
      expect(status('a'), const Complete(bytes: 5));
    });

    test('a region made after a remove began is deleted', () async {
      tiles = FakeOfflineTiles(holdDownloads: true);
      container = make(tiles);
      final started = packs().start(pack('a'));
      await pumpEventQueue();
      await packs().remove('a');
      tiles.releaseDownloads();
      await started;
      await pumpEventQueue();
      expect(tiles.all, isEmpty);
    });
  });
}
