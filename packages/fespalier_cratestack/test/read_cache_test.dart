// The read cache: the same behaviour on a Riverpod Storage and on a LocalStore.
import 'package:fespalier/fespalier.dart' show MemoryDataStorage;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

typedef Make = ReadCache Function();

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
}
