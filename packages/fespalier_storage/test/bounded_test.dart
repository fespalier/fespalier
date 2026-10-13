// BoundedDataStorage over a map: the index, the budgets, the eviction order, the sweep, the failures.
import 'dart:async';

import 'package:fespalier/persist.dart';
import 'package:fespalier_storage/fespalier_storage.dart';
import 'package:fespalier_storage/src/bounded.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const options = StorageOptions();

final t0 = DateTime.utc(2026, 10, 3, 12);

DateTime minute(int n) => t0.add(Duration(minutes: n));

/// Writes [key] at minute [n].
Future<void> save(
  TestStorage storage,
  String key,
  String value,
  int n, [
  StorageOptions o = options,
]) => at(minute(n), () => storage.write(key, value, o));

void main() {
  group('eviction', () {
    test('by maxEntries: the entry written longest ago goes first', () async {
      final store = MapStore();
      final storage = TestStorage(store, maxEntries: 3);
      await save(storage, 'a', '1', 1);
      await save(storage, 'b', '2', 2);
      await save(storage, 'c', '3', 3);
      expect(storage.length, 3);
      await save(storage, 'd', '4', 4);
      expect(storage.length, 3);
      expect(store.ours, ['b', 'c', 'd']);
      expect(storage.read('a'), isNull);
      expect(storage.read('d')!.data, '4');
    });

    test(
      'what is read is rewritten, so what is written longest ago is not what is read least',
      () async {
        final store = MapStore();
        final storage = TestStorage(store, maxEntries: 2);
        await save(storage, 'a', '1', 1);
        await save(storage, 'b', '2', 2);
        await save(storage, 'a', '1 again', 3); // a route fetched fresh again
        await save(storage, 'c', '3', 4);
        expect(store.ours, ['a', 'c']);
      },
    );

    test('by maxSize', () async {
      final store = MapStore();
      final probe = TestStorage(MapStore());
      await save(probe, 'k1', 'x' * 100, 0);
      final each = probe.size;
      final storage = TestStorage(store, maxSize: each * 2 + each ~/ 2);
      await save(storage, 'k1', 'x' * 100, 1);
      await save(storage, 'k2', 'x' * 100, 2);
      expect(storage.size, each * 2);
      await save(storage, 'k3', 'x' * 100, 3);
      expect(store.ours, ['k2', 'k3']);
      expect(storage.size, each * 2);
      expect(storage.size <= storage.maxSize, isTrue);
    });

    test('one write can evict several entries', () async {
      final store = MapStore();
      final probe = TestStorage(MapStore());
      await save(probe, 'k1', 'x' * 10, 0);
      final small = probe.size;
      final storage = TestStorage(store, maxSize: small * 4);
      for (var i = 1; i <= 4; i++) {
        await save(storage, 'k$i', 'x' * 10, i);
      }
      await save(storage, 'big', 'y' * 10 * 3, 5);
      // big takes about 1.5 entries' room: the two written longest ago go, in order.
      expect(store.ours, ['big', 'k3', 'k4']);
      expect(storage.size <= storage.maxSize, isTrue);
    });

    test('a tie in the write time goes by key', () async {
      final store = MapStore();
      final storage = TestStorage(store, maxEntries: 2);
      await save(storage, 'b', '1', 1);
      await save(storage, 'a', '1', 1);
      await save(storage, 'c', '1', 1);
      // a, b and c were written in the same instant: the smallest key goes first, and c stays (just written).
      expect(store.ours, ['b', 'c']);
    });

    test(
      'the entry just written is never evicted, even when it looks the oldest',
      () async {
        final store = MapStore();
        final storage = TestStorage(store, maxEntries: 1);
        await save(storage, 'new', '1', 10);
        await save(storage, 'back-in-time', '2', 5);
        expect(store.ours, ['back-in-time']);
        expect(storage.read('back-in-time')!.data, '2');
      },
    );

    test('an entry written again takes its size once', () async {
      final storage = TestStorage(MapStore());
      await save(storage, 'k', 'x' * 50, 1);
      final once = storage.size;
      await save(storage, 'k', 'x' * 50, 2);
      expect(storage.size, once);
      expect(storage.length, 1);
      await save(storage, 'k', 'x' * 10, 3);
      expect(storage.size < once, isTrue);
    });

    test(
      'is a function of the store: the same writes evict the same entries',
      () async {
        Future<List<String>> run() async {
          final store = MapStore();
          final storage = TestStorage(store, maxEntries: 3);
          for (final (i, key) in ['e', 'c', 'a', 'd', 'b', 'f'].indexed) {
            await save(storage, key, 'v', i ~/ 2); // pairs share an instant
          }
          return store.ours;
        }

        expect(await run(), await run());
      },
    );
  });

  group('a value too large', () {
    test(
      'fails with DataEntryTooLarge, as a failed Future, and says so exactly',
      () async {
        final store = MapStore();
        final storage = TestStorage(store, maxSize: 200);
        late Future<void> result;
        expect(
          () => result = save(
            storage,
            'fespalier:products/\$id[42]',
            'x' * 300,
            1,
          ),
          returnsNormally,
        );
        await expectLater(
          result,
          throwsA(
            isA<DataEntryTooLarge>()
                .having((e) => e.key, 'key', 'fespalier:products/\$id[42]')
                .having((e) => e.maxSize, 'maxSize', 200)
                .having((e) => e.size > 300, 'size', isTrue)
                .having(
                  (e) => e.toString(),
                  'toString',
                  'fespalier_storage: the value saved under fespalier:products/\$id[42] is ${storedSize('x' * 300, 'fespalier:products/\$id[42]')} characters, more than maxSize (200), so it was not saved',
                ),
          ),
        );
        expect(store.ours, isEmpty);
      },
    );

    test('and the older copy of that key is removed', () async {
      final store = MapStore();
      final storage = TestStorage(store, maxSize: 200);
      await save(storage, 'k', 'small', 1);
      expect(store.ours, ['k']);
      await expectLater(
        save(storage, 'k', 'x' * 500, 2),
        throwsA(isA<DataEntryTooLarge>()),
      );
      expect(
        store.ours,
        isEmpty,
        reason:
            'a value that cannot be saved must not leave the stale one behind',
      );
      expect(storage.length, 0);
      expect(storage.size, 0);
      expect(storage.read('k'), isNull);
    });

    test('an entry exactly at the budget is kept', () async {
      final probe = TestStorage(MapStore());
      await save(probe, 'k', 'x' * 20, 1);
      final storage = TestStorage(MapStore(), maxSize: probe.size);
      await save(storage, 'k', 'x' * 20, 1);
      expect(storage.length, 1);
    });
  });

  group('a put that fails', () {
    test('drops its index entry and removes the key, then fails', () async {
      final store = MapStore()..putError = StateError('quota');
      final storage = TestStorage(store);
      await expectLater(save(storage, 'k', 'v', 1), throwsA(isA<StateError>()));
      expect(storage.length, 0);
      expect(storage.size, 0);
      expect(store.removes, ['${storedKeyPrefix}k']);
    });

    test('unless a newer write replaced it by then', () async {
      final store = MapStore();
      final storage = TestStorage(store);
      final first = Completer<void>();
      store.gates.add(first);
      final firstWrite = save(storage, 'k', 'one', 1);
      final secondWrite = save(storage, 'k', 'two', 2);
      await secondWrite;
      first.completeError(StateError('quota'));
      await expectLater(firstWrite, throwsA(isA<StateError>()));
      expect(storage.length, 1);
      expect(
        store.removes,
        isEmpty,
        reason: 'the newer entry is not this write\'s to remove',
      );
      expect(storage.read('k')!.data, 'two');
    });
  });

  group('read, write and delete', () {
    test('a saved entry reads back with its destroyKey and expiry', () async {
      final storage = TestStorage(MapStore());
      await save(
        storage,
        'k',
        '{"a":1}',
        1,
        const StorageOptions(
          destroyKey: '2',
          cacheTime: StorageCacheTime(Duration(hours: 3)),
        ),
      );
      final saved = storage.read('k')!;
      expect(saved.data, '{"a":1}');
      expect(saved.destroyKey, '2');
      expect(saved.expireAt, minute(1).add(const Duration(hours: 3)));
      expect(storage.read('other'), isNull);
    });

    test('unsafe_forever has no expiry and is never swept', () async {
      final store = MapStore();
      final storage = TestStorage(store);
      await save(
        storage,
        'k',
        'v',
        1,
        const StorageOptions(cacheTime: StorageCacheTime.unsafe_forever),
      );
      expect(storage.read('k')!.expireAt, isNull);
      final later = at(
        t0.add(const Duration(days: 4000)),
        () => TestStorage(store),
      );
      expect(later.read('k'), isNotNull);
    });

    test(
      'expired data is returned as it is: Riverpod checks the expiry',
      () async {
        final storage = TestStorage(MapStore());
        await save(
          storage,
          'k',
          'v',
          1,
          const StorageOptions(
            cacheTime: StorageCacheTime(Duration(minutes: 1)),
          ),
        );
        final saved = at(minute(500), () => storage.read('k'));
        expect(saved!.data, 'v');
        expect(saved.expireAt!.isBefore(minute(500)), isTrue);
      },
    );

    test(
      'delete forgets the entry, and a key that is not there is fine',
      () async {
        final store = MapStore();
        final storage = TestStorage(store);
        await save(storage, 'k', 'v', 1);
        await storage.delete('k');
        expect(storage.read('k'), isNull);
        expect(storage.length, 0);
        expect(storage.size, 0);
        await storage.delete('never-there');
        expect(store.ours, isEmpty);
      },
    );

    test('an entry it cannot read is the S2 FormatException', () {
      final store = MapStore();
      final storage = TestStorage(store);
      // Planted after the storage was made: the sweep at construction would have dropped them.
      store.values['${storedKeyPrefix}bad'] = 'not an entry';
      store.values['${storedKeyPrefix}typed'] = 42;
      for (final key in ['bad', 'typed']) {
        expect(
          () => storage.read(key),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'toString',
              'FormatException: fespalier_storage: a saved entry is not one this storage wrote (format fsc1)',
            ),
          ),
        );
      }
    });
  });

  group('clear', () {
    test(
      'removes every entry of the storage, indexed or not, and nothing else',
      () async {
        final store = MapStore({
          'app.setting': 'keep',
          'other/prefix': 'keep',
          '${storedKeyPrefix}stray': 'garbage',
        });
        final storage = TestStorage(store);
        await save(storage, 'a', '1', 1);
        await save(storage, 'b', '2', 2);
        await storage.clear();
        expect(
          store.values.keys,
          unorderedEquals(['app.setting', 'other/prefix']),
        );
        expect(storage.length, 0);
        expect(storage.size, 0);
        await save(storage, 'c', '3', 3);
        expect(storage.read('c')!.data, '3');
      },
    );
  });

  group('the sweep, once, when it is made', () {
    test('deletes the expired entries and keeps the others', () async {
      final store = MapStore();
      final writer = TestStorage(store);
      await save(
        writer,
        'short',
        'v',
        0,
        const StorageOptions(
          cacheTime: StorageCacheTime(Duration(minutes: 10)),
        ),
      );
      await save(
        writer,
        'long',
        'v',
        0,
        const StorageOptions(cacheTime: StorageCacheTime(Duration(hours: 5))),
      );
      final restarted = at(minute(60), () => TestStorage(store));
      await restarted.sweepDone();
      expect(store.ours, ['long']);
      expect(restarted.length, 1);
      expect(restarted.read('long'), isNotNull);
    });

    test('an entry that expires exactly now is expired', () async {
      final store = MapStore();
      final writer = TestStorage(store);
      await save(
        writer,
        'k',
        'v',
        0,
        const StorageOptions(
          cacheTime: StorageCacheTime(Duration(minutes: 10)),
        ),
      );
      final restarted = at(minute(10), () => TestStorage(store));
      await restarted.sweepDone();
      expect(store.ours, isEmpty);
    });

    test('drops the unreadable ones and says so once (S3)', () async {
      final store = MapStore({
        '${storedKeyPrefix}garbage': 'not an entry',
        '${storedKeyPrefix}other-format': 'fsc2\n\n1\nnull\n\nd',
        '${storedKeyPrefix}typed': 7,
        'app.setting': 'keep',
      });
      late TestStorage storage;
      final lines = await printed(() async {
        storage = TestStorage(store);
        await storage.sweepDone();
      });
      expect(lines, [
        'fespalier_storage: dropped 3 saved entries that could not be read',
      ]);
      expect(store.values.keys, ['app.setting']);
      expect(storage.length, 0);
    });

    test('is silent when nothing is unreadable', () async {
      final store = MapStore();
      await save(TestStorage(store), 'k', 'v', 1);
      final lines = await printed(
        () async => at(minute(2), () => TestStorage(store)),
      );
      expect(lines, isEmpty);
    });

    test(
      'indexes what the store holds: sizes, and the order of writing',
      () async {
        final store = MapStore();
        final writer = TestStorage(store);
        await save(writer, 'b', 'v', 2);
        await save(writer, 'a', 'v', 1);
        final restarted = at(
          minute(3),
          () => TestStorage(store, maxEntries: 1),
        );
        await restarted.sweepDone();
        expect(store.ours, ['b'], reason: 'a was written first: evicted');
      },
    );

    test('budgets that were lowered evict at once', () async {
      final store = MapStore();
      final writer = TestStorage(store, maxEntries: 5);
      for (var i = 1; i <= 5; i++) {
        await save(writer, 'k$i', 'v', i);
      }
      final restarted = at(minute(6), () => TestStorage(store, maxEntries: 2));
      expect(restarted.length, 2);
      await restarted.sweepDone();
      expect(store.ours, ['k4', 'k5']);
      final smaller = at(
        minute(7),
        () => TestStorage(store, maxSize: restarted.size - 1),
      );
      expect(smaller.length, 1);
      await smaller.sweepDone();
      expect(store.ours, ['k5']);
    });

    test(
      'a store that fails to remove is not an error: the next start sweeps again',
      () async {
        final store = MapStore({'${storedKeyPrefix}garbage': 'x'})
          ..removeError = StateError('read-only');
        final storage = TestStorage(store);
        await storage.sweepDone();
        expect(storage.length, 0);
      },
    );

    test('never touches a key outside its prefix', () async {
      final store = MapStore({
        'app.setting': 'keep',
        'fespalier.dataCache': 'no slash',
        'fespalier:products': 'keep',
      });
      final storage = TestStorage(store, maxEntries: 1);
      await storage.sweepDone();
      await storage.clear();
      expect(
        store.values.keys,
        unorderedEquals([
          'app.setting',
          'fespalier.dataCache',
          'fespalier:products',
        ]),
      );
      expect(store.removes, isEmpty);
    });
  });

  group('the budgets', () {
    test('must be more than 0 (S7)', () {
      for (final (build, text) in <(void Function(), String)>[
        (
          () => TestStorage(MapStore(), maxSize: 0),
          'Invalid argument (maxSize): must be more than 0: 0',
        ),
        (
          () => TestStorage(MapStore(), maxSize: -5),
          'Invalid argument (maxSize): must be more than 0: -5',
        ),
        (
          () => TestStorage(MapStore(), maxEntries: 0),
          'Invalid argument (maxEntries): must be more than 0: 0',
        ),
      ]) {
        expect(
          build,
          throwsA(
            isA<ArgumentError>().having((e) => e.toString(), 'toString', text),
          ),
        );
      }
    });

    test('are checked before the sweep builds the index with them', () {
      final store = MapStore({'${storedKeyPrefix}k': 'garbage'});
      expect(() => TestStorage(store, maxEntries: 0), throwsArgumentError);
      expect(
        store.removes,
        isEmpty,
        reason: 'the constructor stopped before sweeping',
      );
    });
  });

  test(
    'size counts the stored key and the stored text, in String.length units',
    () async {
      final store = MapStore();
      final storage = TestStorage(store);
      await save(storage, 'k', 'v', 1);
      final stored = store.values['${storedKeyPrefix}k']! as String;
      expect(storage.size, '${storedKeyPrefix}k'.length + stored.length);
    },
  );
}

/// What an entry of [data] under [key] takes in a storage with room for it.
int storedSize(String data, String key) {
  final storage = TestStorage(MapStore(), maxSize: 1000000);
  unawaited(at(t0, () => storage.write(key, data, options)));
  return storage.size;
}
