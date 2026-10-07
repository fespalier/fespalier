// ref.serve: where a read's answer comes from, and how current it is.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final _codec = ServedCodec<List<int>>(
  toJson: (v) => v,
  fromJson: (j) => (j! as List<Object?>).cast<int>(),
);

final _single = ServedCodec<int>(toJson: (v) => v, fromJson: (j) => j! as int);

Provider<FutureOr<Served<List<int>>>> _read({
  Future<List<int>> Function()? fetch,
  ReadPolicy policy = ReadPolicy.networkFirst,
  Duration? maxAge,
  String key = 'orders',
  bool withEmpty = true,
}) => Provider<FutureOr<Served<List<int>>>>(
  (ref) => ref.serve(
    key: key,
    codec: _codec,
    fetch: fetch,
    policy: policy,
    maxAge: maxAge,
    empty: withEmpty ? () => const [] : null,
  ),
);

Future<List<int>> Function() _offline() =>
    () => throw const CrateStackOffline();

void main() {
  test(
    'online: the network answer is saved with the fake clock as fetchedAt',
    () async {
      final store = InMemoryLocalStore();
      final container = containerFor(store: store);
      final served = await withClock(Clock.fixed(epoch), () async {
        final read = _read(fetch: () async => [1, 2]);
        return container.read(read);
      });
      expect(served.source, ServedFrom.network);
      expect(served.value, [1, 2]);
      expect(served.fetchedAt, epoch);
      expect(served.stale, isFalse);
      expect(store.keys('cs/u1/read/'), hasLength(1));
    },
  );

  test(
    'offline: the saved value is served as local with that fetchedAt',
    () async {
      final store = InMemoryLocalStore();
      await withClock(Clock.fixed(epoch), () async {
        await container1(store).read(_read(fetch: () async => [7]));
      });
      final later = Clock.fixed(epoch.add(const Duration(hours: 3)));
      final served = await withClock(later, () async {
        return container1(store).read(_read(fetch: _offline()));
      });
      expect(served.source, ServedFrom.local);
      expect(served.value, [7]);
      expect(served.fetchedAt!.isAtSameMomentAs(epoch), isTrue);
      expect(served.neverFetched, isFalse);
    },
  );

  test('an empty list offline is an answer: [] and never fetched', () async {
    final container = containerFor();
    final served = await container.read(_read(fetch: _offline()));
    expect(served.value, isEmpty);
    expect(served.source, ServedFrom.local);
    expect(served.neverFetched, isTrue);
  });

  test('a single row with nothing stored is CrateStackNoLocalData', () async {
    final container = containerFor();
    final read = _read(fetch: _offline(), withEmpty: false, key: 'order:1');
    await expectLater(
      Future.sync(() => container.read(read)),
      throwsA(
        isA<CrateStackNoLocalData>().having((e) => e.key, 'key', 'order:1'),
      ),
    );
  });

  test('a refusal is the answer: rethrown, never the cache', () async {
    final store = InMemoryLocalStore();
    await container1(store).read(_read(fetch: () async => [1]));
    const refusal = CrateStackRefused(
      status: 403,
      code: 'FORBIDDEN',
      message: 'no',
    );
    final read = _read(fetch: () => throw refusal);
    await expectLater(
      Future.sync(() => container1(store).read(read)),
      throwsA(same(refusal)),
    );
  });

  test('an error no reader knows is rethrown as it was', () async {
    final boom = StateError('boom');
    final read = _read(fetch: () => throw boom);
    await expectLater(
      Future.sync(() => containerFor().read(read)),
      throwsA(same(boom)),
    );
  });

  test('the readers of crateStackErrors decide what is offline', () async {
    final container = containerFor(
      extra: [
        crateStackErrors.overrideWithValue(
          CrateStackErrors([
            (e) => e is FormatException ? CrateStackOffline(e) : null,
          ]),
        ),
      ],
    );
    final served = await container.read(
      _read(fetch: () => throw const FormatException('<html>')),
    );
    expect(served.source, ServedFrom.local);
  });

  test("another account's entry is never served", () async {
    final store = InMemoryLocalStore();
    await containerFor(
      store: store,
      scope: 'a',
    ).read(_read(fetch: () async => [1]));
    final served = await containerFor(
      store: store,
      scope: 'b',
    ).read(_read(fetch: _offline()));
    expect(served.value, isEmpty);
    expect(served.neverFetched, isTrue);
    final again = await containerFor(
      store: store,
      scope: 'a',
    ).read(_read(fetch: _offline()));
    expect(again.value, [1]);
  });

  test('signed out (no scope): nothing is saved and nothing is read', () async {
    final store = InMemoryLocalStore();
    final container = containerFor(store: store, scope: null);
    await container.read(_read(fetch: () async => [1]));
    expect(store.keys(''), isEmpty);
  });

  test('stale follows maxAge', () async {
    final store = InMemoryLocalStore();
    await withClock(Clock.fixed(epoch), () async {
      await container1(store).read(_read(fetch: () async => [1]));
    });
    Future<bool> staleAfter(Duration age) =>
        withClock(Clock.fixed(epoch.add(age)), () async {
          final served = await container1(
            store,
          ).read(_read(fetch: _offline(), maxAge: const Duration(hours: 1)));
          return served.stale;
        });
    expect(await staleAfter(const Duration(minutes: 30)), isFalse);
    expect(await staleAfter(const Duration(hours: 2)), isTrue);
  });

  test('a version change drops the saved answer', () async {
    final store = InMemoryLocalStore();
    await container1(store).read(_read(fetch: () async => [1]));
    final v2 = Provider<FutureOr<Served<List<int>>>>(
      (ref) => ref.serve(
        key: 'orders',
        codec: ServedCodec<List<int>>(
          toJson: (v) => v,
          fromJson: (j) => (j! as List<Object?>).cast<int>(),
          version: '2',
        ),
        fetch: _offline(),
        empty: () => const [],
      ),
    );
    final served = await container1(store).read(v2);
    expect(served.neverFetched, isTrue);
  });

  group('policies', () {
    test('cacheFirst: a hit does not touch the network, a miss does', () async {
      final store = InMemoryLocalStore();
      var fetches = 0;
      Future<List<int>> fetch() async {
        fetches++;
        return [fetches];
      }

      final miss = await container1(
        store,
      ).read(_read(fetch: fetch, policy: ReadPolicy.cacheFirst));
      expect(miss.source, ServedFrom.network);
      expect(fetches, 1);
      final hit = await container1(
        store,
      ).read(_read(fetch: fetch, policy: ReadPolicy.cacheFirst));
      expect(hit.source, ServedFrom.local);
      expect(hit.value, [1]);
      expect(fetches, 1);
    });

    test('serverOnly: offline is CrateStackOffline, never the cache', () async {
      final store = InMemoryLocalStore();
      await container1(store).read(_read(fetch: () async => [1]));
      await expectLater(
        Future.sync(
          () => container1(
            store,
          ).read(_read(fetch: _offline(), policy: ReadPolicy.serverOnly)),
        ),
        throwsA(isA<CrateStackOffline>()),
      );
    });

    test('localOnly on a synchronous store returns a Served, not a Future', () {
      final store = InMemoryLocalStore();
      final container = containerFor(store: store);
      final cache = container.read(readCache);
      final at = epoch;
      final saved = cache.write('u1', 'orders', '1', [4, 5], at);
      expect(saved, isNot(isA<Future<void>>()));
      final result = container.read(_read(policy: ReadPolicy.localOnly));
      expect(result, isNot(isA<Future<Object?>>()));
      final served = result as Served<List<int>>;
      expect(served.value, [4, 5]);
      expect(served.fetchedAt!.isAtSameMomentAs(at), isTrue);
    });

    test(
      'localOnly with nothing saved and no empty is NoLocalData, synchronously',
      () {
        final container = containerFor();
        final read = _read(policy: ReadPolicy.localOnly, withEmpty: false);
        expect(
          () => container.read(read),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'text',
              contains('CrateStackNoLocalData'),
            ),
          ),
        );
      },
    );

    test('a fetch is required unless the policy is localOnly', () {
      final container = containerFor();
      final read = _read();
      expect(() => container.read(read), throwsA(isA<Object>()));
    });
  });

  group('rebuilds', () {
    test(
      'an accepted intent or a sync that bumps the tag runs the read again',
      () async {
        final container = containerFor();
        var fetches = 0;
        final read = _read(fetch: () async => [++fetches]);
        expect((await container.read(read)).value, [1]);
        container.read(crateStackRevision('orders').notifier).bump();
        expect((await container.read(read)).value, [2]);
      },
    );

    test("the tag defaults to the key's prefix before the colon", () async {
      final container = containerFor();
      var fetches = 0;
      final read = _read(fetch: () async => [++fetches], key: 'orders:open');
      await container.read(read);
      container.read(crateStackRevision('orders').notifier).bump();
      expect((await container.read(read)).value, [2]);
    });

    test(
      'a change of scope runs the read again, for the new account',
      () async {
        final scope = NotifierProvider<_Scope, String?>(_Scope.new);
        final store = InMemoryLocalStore();
        final container = ProviderContainer(
          overrides: [
            localStore.overrideWithValue(store),
            crateStackScope.overrideWith((ref) => ref.watch(scope)),
          ],
        );
        addTearDown(container.dispose);
        final read = _read(fetch: () async => [1]);
        await container.read(read);
        expect(store.keys('cs/u1/'), isNotEmpty);
        container.read(scope.notifier).set('u2');
        await container.read(read);
        expect(store.keys('cs/u2/'), isNotEmpty);
      },
    );
  });

  test('a single-row codec round-trips', () async {
    final store = InMemoryLocalStore();
    Provider<FutureOr<Served<int>>> one(Future<int> Function() fetch) =>
        Provider(
          (ref) => ref.serve(key: 'order:1', codec: _single, fetch: fetch),
        );
    await container1(store).read(one(() async => 5));
    final served = await container1(
      store,
    ).read(one(() => throw const CrateStackOffline()));
    expect(served.value, 5);
    expect(served.source, ServedFrom.local);
  });
}

/// A fresh container over [store], for the account `u1`.
ProviderContainer container1(InMemoryLocalStore store) =>
    containerFor(store: store);

class _Scope extends Notifier<String?> {
  @override
  String? build() => 'u1';

  void set(String? value) => state = value;
}
