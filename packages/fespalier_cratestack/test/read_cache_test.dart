// The read cache: the same behaviour on a Riverpod Storage and on a LocalStore.
import 'package:fespalier/fespalier.dart' show MemoryDataStorage;
import 'package:fespalier/persist.dart'
    show PersistedData, Storage, StorageOptions;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

typedef Make = ReadCache Function();

/// A Storage whose every answer is a Future that takes a few turns, like one on a plugin.
final class SlowStorage extends Storage<String, String> {
  final inner = MemoryDataStorage();
  final writes = <String>[];

  @override
  Future<PersistedData<String>?> read(String key) async {
    await Future<void>.value();
    await Future<void>.value();
    return inner.read(key);
  }

  @override
  Future<void> write(String key, String value, StorageOptions options) async {
    await Future<void>.value();
    await Future<void>.value();
    writes.add(key);
    inner.write(key, value, options);
  }

  @override
  Future<void> delete(String key) async {
    await Future<void>.value();
    inner.delete(key);
  }

  @override
  void deleteOutOfDate() {}
}

void main() {
  final backends = <String, Make>{
    'on a Storage (MemoryDataStorage)': () =>
        ReadCache.storage(MemoryDataStorage()),
    'on a LocalStore': () => ReadCache.local(InMemoryLocalStore()),
  };

  for (final entry in backends.entries) {
    group(entry.key, () {
      late ReadCache cache;
      setUp(() => cache = entry.value());

      test('saves and reads an answer with its time', () async {
        await cache.write('u1', 'orders', '1', [1, 2], epoch);
        final hit = (await cache.read('u1', 'orders', '1'))!;
        expect(hit.json, [1, 2]);
        expect(hit.fetchedAt.isAtSameMomentAs(epoch), isTrue);
      });

      test('nothing saved is null', () async {
        expect(await cache.read('u1', 'orders', '1'), isNull);
      });

      test('a version mismatch is dropped, and stays dropped', () async {
        await cache.write('u1', 'orders', '1', [1], epoch);
        expect(await cache.read('u1', 'orders', '2'), isNull);
        expect(await cache.read('u1', 'orders', '1'), isNull);
      });

      test('scopes do not see each other', () async {
        await cache.write('a', 'orders', '1', [1], epoch);
        expect(await cache.read('b', 'orders', '1'), isNull);
        expect(await cache.read('a/b', 'orders', '1'), isNull);
      });

      test('clear takes one scope\'s answers and no others', () async {
        await cache.write('a', 'orders', '1', [1], epoch);
        await cache.write('a', 'products', '1', [2], epoch);
        await cache.write('b', 'orders', '1', [3], epoch);
        await cache.clear('a');
        expect(await cache.read('a', 'orders', '1'), isNull);
        expect(await cache.read('a', 'products', '1'), isNull);
        expect((await cache.read('b', 'orders', '1'))!.json, [3]);
      });

      test('a value saved twice is read as the last', () async {
        await cache.write('u1', 'orders', '1', [1], epoch);
        await cache.write('u1', 'orders', '1', [
          9,
        ], epoch.add(const Duration(hours: 1)));
        expect((await cache.read('u1', 'orders', '1'))!.json, [9]);
      });
    });
  }

  test('both answer synchronously on a synchronous backend', () {
    for (final make in backends.values) {
      final cache = make();
      final written = cache.write('u1', 'k', '1', [1], epoch);
      expect(written, isNot(isA<Future<void>>()));
      expect(cache.read('u1', 'k', '1'), isA<CachedAnswer>());
    }
  });

  group('on a slow Storage', () {
    test(
      'writes in flight at once all land in the index, so a sign-out takes them all',
      () async {
        final storage = SlowStorage();
        final cache = ReadCache.storage(storage);
        await Future.wait([
          for (var i = 0; i < 5; i++)
            Future<void>.value(cache.write('a', 'k$i', '1', [i], epoch)),
        ]);
        for (var i = 0; i < 5; i++) {
          expect((await cache.read('a', 'k$i', '1'))!.json, [i]);
        }
        await cache.clear('a');
        for (var i = 0; i < 5; i++) {
          expect(await cache.read('a', 'k$i', '1'), isNull, reason: 'k$i');
        }
      },
    );

    test(
      'the index can live in a LocalStore, where nothing evicts it',
      () async {
        final storage = SlowStorage();
        final index = InMemoryLocalStore();
        final cache = ReadCache.storage(storage, index: index);
        await cache.write('a', 'k1', '1', [1], epoch);
        await cache.write('a', 'k2', '1', [2], epoch);
        expect(index.keys('cs/a/'), ['cs/a/read-index']);
        expect(storage.inner.read('cs/a/read-index'), isNull);
        // The keys are listed in the LocalStore's index, so the wipe finds them.
        await cache.clear('a');
        expect(await cache.read('a', 'k1', '1'), isNull);
        expect(index.keys('cs/a/'), isEmpty);
      },
    );

    test('the index is written before the value', () async {
      final storage = SlowStorage();
      final cache = ReadCache.storage(storage);
      await cache.write('a', 'k1', '1', [1], epoch);
      expect(
        storage.writes.indexOf('cs/a/read-index'),
        lessThan(storage.writes.indexOf('cs/a/read/k1')),
      );
    });
  });
}
