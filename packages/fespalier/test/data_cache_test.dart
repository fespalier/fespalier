// The data cache (since 0.8.0): `cachedData` saves a data() value through Riverpod's
// experimental `persist`, behind a guard. This file is the tripwire for that API: a
// Riverpod minor that changes it fails here, and `lib/src/data_cache.dart` is the one file to fix.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/misc.dart'
    show AsyncNotifierProviderFamily, Override;

const key = 'fespalier:items';

DataCache<int> intCache({String? version, Duration? maxAge}) =>
    DataCache<int>.json(
      toJson: (v) => v,
      fromJson: (j) => j! as int,
      version: version,
      maxAge: maxAge ?? const Duration(days: 2),
    );

/// What a data() function is: the Nth load yields N, or throws while [offline].
class Server {
  var loads = 0;
  var offline = false;

  /// While set, a load waits for it.
  Completer<void>? gate;

  Future<int> call() async {
    loads++;
    await gate?.future;
    if (offline) throw Exception('offline');
    return loads;
  }
}

AsyncNotifierProvider<CachedData<int>, int> items(
  Server server, {
  DataCache<int>? cache,
  Freshness? freshness,
}) => cachedData<int>(
  (ref) => server(),
  cache: cache ?? intCache(),
  name: 'items',
  freshness: freshness,
);

Future<ProviderContainer> boot(WidgetTester tester, {Object? storage}) async {
  final container = ProviderContainer(
    retry: (_, _) => null,
    overrides: <Override>[
      if (storage != null)
        dataCacheStorage.overrideWithValue(
          storage as FutureOr<Storage<String, String>>,
        ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      // A new element, so Riverpod refreshes on this container's frames, not on timers.
      key: UniqueKey(),
      container: container,
      child: const SizedBox.shrink(),
    ),
  );
  return container;
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

/// A restart: the first container loads and saves, then goes away.
Future<void> firstRun(
  WidgetTester tester,
  MemoryDataStorage storage,
  Server server, {
  DataCache<int>? cache,
}) async {
  final container = await boot(tester, storage: storage);
  final p = items(server, cache: cache);
  final subscription = container.listen(p, (_, _) {});
  await frames(tester);
  expect(container.read(p).requireValue, server.loads);
  subscription.close();
  await frames(tester);
  container.dispose();
}

void main() {
  group('without a dataCacheStorage', () {
    testWidgets('it is a plain provider, and nothing is saved', (tester) async {
      final server = Server();
      final container = await boot(tester);
      final p = items(server);
      final subscription = container.listen(p, (_, _) {});
      await frames(tester);
      final value = container.read(p);
      expect(value.requireValue, 1);
      expect(value.isFromCache, isFalse);
      expect(container.read(dataCacheStorage), isNull);
      subscription.close();
      await frames(tester);
    });
  });

  group('a restart', () {
    testWidgets('the first read is the saved value, synchronously, then the '
        'fresh one, which is saved', (tester) async {
      final storage = MemoryDataStorage();
      final server = Server();
      await firstRun(tester, storage, server);
      expect(storage.read(key)?.data, '1');

      final container = await boot(tester, storage: storage);
      final p = items(server);
      final subscription = container.listen(p, (_, _) {});
      final first = container.read(p);
      expect(first.isLoading, isTrue);
      expect(first.isFromCache, isTrue);
      expect(first.value, 1);
      await frames(tester);
      final second = container.read(p);
      expect(second.requireValue, 2);
      expect(second.isFromCache, isFalse);
      expect(storage.read(key)?.data, '2');
      subscription.close();
      await frames(tester);
    });

    testWidgets('a failed load keeps the saved value in the state and in the '
        'storage', (tester) async {
      final storage = MemoryDataStorage();
      final server = Server();
      await firstRun(tester, storage, server);

      server.offline = true;
      final container = await boot(tester, storage: storage);
      final p = items(server);
      final subscription = container.listen(p, (_, _) {});
      await frames(tester);
      final value = container.read(p);
      expect(value.hasError, isTrue);
      expect(value.value, 1);
      expect(storage.read(key)?.data, '1');
      subscription.close();
      await frames(tester);

      // And the next start, still offline, shows it again.
      final again = await boot(tester, storage: storage);
      final listening = again.listen(p, (_, _) {});
      expect(again.read(p).value, 1);
      await frames(tester);
      expect(again.read(p).value, 1);
      expect(storage.read(key)?.data, '1');
      listening.close();
      await frames(tester);
    });

    testWidgets('a value that does not decode is dropped, not reported', (
      tester,
    ) async {
      final storage = MemoryDataStorage()
        ..write(key, 'not json', const StorageOptions());
      final server = Server();
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      final container = await boot(tester, storage: storage);
      final p = items(server);
      final subscription = container.listen(p, (_, _) {});
      final first = container.read(p);
      expect(first.isFromCache, isFalse);
      expect(first.hasValue, isFalse);
      // The entry is gone before the load ends, and the load goes on.
      await frames(tester);
      expect(container.read(p).requireValue, 1);
      expect(storage.read(key)?.data, '1');
      debugPrint = original;
      expect(
        printed.single,
        startsWith(
          'fespalier: dataCache of items could not read a saved value, '
          'dropped it: ',
        ),
      );
      subscription.close();
      await frames(tester);
    });

    testWidgets('a value of another version is dropped, not decoded', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final server = Server();
      await firstRun(tester, storage, server, cache: intCache(version: 'a'));

      final container = await boot(tester, storage: storage);
      final p = items(server, cache: intCache(version: 'b'));
      final subscription = container.listen(p, (_, _) {});
      expect(container.read(p).isFromCache, isFalse);
      expect(container.read(p).hasValue, isFalse);
      await frames(tester);
      expect(container.read(p).requireValue, 2);
      expect(storage.read(key)?.destroyKey, 'b');
      subscription.close();
      await frames(tester);
    });

    testWidgets(
      'a value older than maxAge is dropped (the fake clock ages it)',
      (tester) async {
        final storage = MemoryDataStorage();
        final server = Server();
        await firstRun(tester, storage, server);
        await tester.pump(const Duration(days: 3));

        final container = await boot(tester, storage: storage);
        final p = items(server);
        final subscription = container.listen(p, (_, _) {});
        expect(container.read(p).isFromCache, isFalse);
        await frames(tester);
        expect(container.read(p).requireValue, 2);
        subscription.close();
        await frames(tester);
      },
    );

    testWidgets('within maxAge a shorter one still shows it', (tester) async {
      final storage = MemoryDataStorage();
      final server = Server();
      await firstRun(
        tester,
        storage,
        server,
        cache: intCache(maxAge: const Duration(hours: 1)),
      );
      await tester.pump(const Duration(minutes: 30));
      final container = await boot(tester, storage: storage);
      final p = items(
        server,
        cache: intCache(maxAge: const Duration(hours: 1)),
      );
      final subscription = container.listen(p, (_, _) {});
      expect(container.read(p).isFromCache, isTrue);
      await frames(tester);
      subscription.close();
      await frames(tester);
    });
  });

  group('a storage that is a Future', () {
    testWidgets('loading first, then the saved value, then the fresh one', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final server = Server();
      await firstRun(tester, storage, server);

      server.gate = Completer<void>();
      final opened = Completer<MemoryDataStorage>();
      final container = await boot(tester, storage: opened.future);
      final p = items(server);
      final states = <AsyncValue<int>>[];
      final subscription = container.listen(
        p,
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      // The storage opens only now, so the first state has nothing to show.
      expect(states.single.isLoading, isTrue);
      expect(states.single.hasValue, isFalse);
      opened.complete(storage);
      await frames(tester);
      expect(container.read(p).isFromCache, isTrue);
      expect(container.read(p).value, 1);
      server.gate!.complete();
      await frames(tester);
      expect(container.read(p).requireValue, 2);
      expect(container.read(p).isFromCache, isFalse);
      subscription.close();
      await frames(tester);
    });

    testWidgets('a storage slower than the load never replaces the fresh '
        'value with the saved one', (tester) async {
      final storage = MemoryDataStorage();
      final server = Server();
      await firstRun(tester, storage, server);

      final opened = Completer<MemoryDataStorage>();
      final container = await boot(tester, storage: opened.future);
      final p = items(server);
      final subscription = container.listen(p, (_, _) {});
      await frames(tester);
      expect(container.read(p).requireValue, 2);
      opened.complete(storage);
      await frames(tester);
      expect(container.read(p).requireValue, 2);
      expect(container.read(p).isFromCache, isFalse);
      subscription.close();
      await frames(tester);
    });
  });

  group('freshness on a cached provider', () {
    testWidgets('a stale value loads again, and what arrives is saved', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final server = Server();
      final container = await boot(tester, storage: storage);
      final p = items(
        server,
        freshness: const Freshness(staleTime: Duration(minutes: 1)),
      );
      final keep = container.listen(p, (_, _) {});
      await frames(tester);
      await tester.pump(const Duration(minutes: 2));
      container.listen(p, (_, _) {}).close();
      await frames(tester);
      expect(container.read(p).requireValue, 2);
      expect(storage.read(key)?.data, '2');
      keep.close();
      await frames(tester);
    });
  });

  group('the key', () {
    testWidgets('is fespalier:<name><json of the parts>', (tester) async {
      final storage = MemoryDataStorage();
      final container = await boot(tester, storage: storage);
      final p = cachedDataFamily<String, int>(
        (ref, id) async => 'item $id',
        cache: DataCache<String>(encode: (v) => v, decode: (s) => s),
        name: r'products/$id',
        keyParts: (id) => [id],
      );
      final subscription = container.listen(p(42), (_, _) {});
      await frames(tester);
      expect(storage.read(r'fespalier:products/$id[42]')?.data, 'item 42');
      subscription.close();
      await frames(tester);
    });

    testWidgets('lists a record in path order, enums by name, lists as lists', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final container = await boot(tester, storage: storage);
      final p = cachedDataFamily<String, ({String shop, int id})>(
        (ref, k) async => '${k.shop}/${k.id}',
        cache: DataCache<String>(encode: (v) => v, decode: (s) => s),
        name: r'shops/$shop/items/$id',
        keyParts: (k) => [k.shop, k.id],
      );
      final q = cachedDataFamily<String, (Axis, DateTime, List<String>)>(
        (ref, k) async => 'x',
        cache: DataCache<String>(encode: (v) => v, decode: (s) => s),
        name: 'q',
        keyParts: (k) => [k.$1, k.$2, k.$3],
      );
      final s1 = container.listen(p((shop: 'a', id: 3)), (_, _) {});
      final s2 = container.listen(
        q((Axis.vertical, DateTime.utc(2026, 1, 2), ['x', 'y'])),
        (_, _) {},
      );
      await frames(tester);
      expect(
        storage.read(r'fespalier:shops/$shop/items/$id["a",3]')?.data,
        'a/3',
      );
      expect(
        storage
            .read(
              'fespalier:q["vertical","2026-01-02T00:00:00.000Z",["x","y"]]',
            )
            ?.data,
        'x',
      );
      s1.close();
      s2.close();
      await frames(tester);
    });
  });

  group('a storage that fails', () {
    for (final throws in [true, false]) {
      testWidgets(
        'never becomes the route error (${throws ? 'throws' : 'a Future'})',
        (tester) async {
          final server = Server();
          final printed = <String>[];
          final original = debugPrint;
          debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
          final container = await boot(
            tester,
            storage: _BrokenStorage(throws: throws),
          );
          final p = items(server);
          final subscription = container.listen(p, (_, _) {});
          await frames(tester);
          expect(container.read(p).requireValue, 1);
          debugPrint = original;
          expect(
            printed,
            contains(
              startsWith('fespalier: dataCache of items could not save: '),
            ),
          );
          subscription.close();
          await frames(tester);
        },
      );
    }

    testWidgets('an encode that throws saves nothing and fails nothing', (
      tester,
    ) async {
      final storage = MemoryDataStorage();
      final server = Server();
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      final container = await boot(tester, storage: storage);
      final p = items(
        server,
        cache: DataCache<int>(
          encode: (v) => throw StateError('no'),
          decode: int.parse,
        ),
      );
      final subscription = container.listen(p, (_, _) {});
      await frames(tester);
      expect(container.read(p).requireValue, 1);
      expect(storage.read(key), isNull);
      debugPrint = original;
      expect(
        printed.single,
        startsWith('fespalier: dataCache of items could not save: '),
      );
      subscription.close();
      await frames(tester);
    });
  });

  group('types', () {
    test('cachedDataFamily infers T and K from the fetch', () {
      final AsyncNotifierProviderFamily<CachedData<String>, String, int>
      provider = cachedDataFamily(
        (Ref ref, int id) async => 'x',
        cache: DataCache<String>(encode: (v) => v, decode: (s) => s),
        name: 'x',
        keyParts: (id) => [id],
      );
      expect(provider, isNotNull);
      final AsyncNotifierProvider<CachedData<String>, String> plain =
          cachedData(
            (Ref ref) => 'sync',
            cache: DataCache<String>(encode: (v) => v, decode: (s) => s),
            name: 'x',
          );
      expect(plain, isNotNull);
    });
  });
}

/// A storage whose every write fails, with a `Future` and with a throw.
final class _BrokenStorage extends Storage<String, String> {
  _BrokenStorage({required this.throws});

  final bool throws;

  @override
  PersistedData<String>? read(String key) => null;

  @override
  FutureOr<void> write(String key, String value, StorageOptions options) {
    if (throws) throw StateError('disk full');
    return Future<void>.error(StateError('disk full'));
  }

  @override
  void delete(String key) {}

  @override
  void deleteOutOfDate() {}
}
