// The fakes' own contract: a test that trusts a fake needs the fake to be right.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  group('FakeCrateStackTransport', () {
    late FakeCrateStackTransport t;
    setUp(
      () => t = FakeCrateStackTransport()..on('op', (input) => {'echo': input}),
    );

    test('answers a scripted operation with the wire input', () async {
      expect(await t.send(const RpcCall('op', {'a': 1})), {
        'echo': {'a': 1},
      });
      expect(t.runs('op'), 1);
    });

    test(
      'an operation nobody scripted is the test\'s mistake, said plainly',
      () async {
        await expectLater(
          t.send(const RpcCall('nope', null)),
          throwsStateError,
        );
      },
    );

    test('REST calls are named by method and path', () async {
      t.on('POST /orders', (body) => body);
      expect(await t.send(const RestCall('POST', '/orders', body: {'a': 1})), {
        'a': 1,
      });
      expect(
        FakeCrateStackTransport.nameOf(const RestCall('GET', '/x')),
        'GET /x',
      );
    });

    test(
      'a replay under the same key returns the stored answer and does not run twice',
      () async {
        final first = await t.send(
          const RpcCall('op', {'a': 1}),
          idempotencyKey: 'k#0',
        );
        final second = await t.send(
          const RpcCall('op', {'a': 1}),
          idempotencyKey: 'k#0',
        );
        expect(second, first);
        expect(t.runs('op'), 1);
        expect(t.calls, hasLength(2));
      },
    );

    test('a different key runs it again', () async {
      await t.send(const RpcCall('op', {'a': 1}), idempotencyKey: 'k#0');
      await t.send(const RpcCall('op', {'a': 1}), idempotencyKey: 'k#1');
      expect(t.runs('op'), 2);
    });

    test(
      'a reused key with another body is 422 idempotency_key_conflict',
      () async {
        await t.send(const RpcCall('op', {'a': 1}), idempotencyKey: 'k#0');
        await expectLater(
          t.send(const RpcCall('op', {'a': 2}), idempotencyKey: 'k#0'),
          throwsA(
            isA<CrateStackRefused>()
                .having((e) => e.status, 'status', 422)
                .having((e) => e.code, 'code', 'VALIDATION_ERROR')
                .having(
                  (e) => e.message,
                  'message',
                  startsWith('idempotency_key_conflict'),
                ),
          ),
        );
        expect(t.runs('op'), 1);
      },
    );

    test(
      'loseAnswer: it runs, the client gets offline, the replay does not run it again',
      () async {
        t.loseAnswer('op');
        await expectLater(
          t.send(const RpcCall('op', {'a': 1}), idempotencyKey: 'k#0'),
          throwsA(isA<CrateStackOffline>()),
        );
        expect(t.runs('op'), 1);
        expect(
          await t.send(const RpcCall('op', {'a': 1}), idempotencyKey: 'k#0'),
          {
            'echo': {'a': 1},
          },
        );
        expect(t.runs('op'), 1);
      },
    );

    test(
      'offline: every send throws, nothing runs, and the calls are recorded',
      () async {
        t.offline = true;
        await expectLater(
          t.send(const RpcCall('op', null)),
          throwsA(isA<CrateStackOffline>()),
        );
        expect(t.runs('op'), 0);
        expect(t.calls, hasLength(1));
      },
    );

    test('refuse: the server decided, and the operation did not run', () async {
      t.refuse('op', 403, 'FORBIDDEN', 'no', times: 1);
      await expectLater(
        t.send(const RpcCall('op', null)),
        throwsA(
          isA<CrateStackRefused>().having((e) => e.code, 'code', 'FORBIDDEN'),
        ),
      );
      expect(t.runs('op'), 0);
      // Only once: the next send gets through.
      await t.send(const RpcCall('op', null));
      expect(t.runs('op'), 1);
    });

    test('refuse maps the status like the readers do', () async {
      t.refuse('op', 500, 'INTERNAL', 'x', times: 1);
      await expectLater(
        t.send(const RpcCall('op', null)),
        throwsA(isA<CrateStackUnavailable>()),
      );
      t.refuse('op', 401, 'U', 'x', times: 1);
      await expectLater(
        t.send(const RpcCall('op', null)),
        throwsA(isA<CrateStackUnauthenticated>()),
      );
      t.refuse('op', 409, 'C', 'x', retryAfter: true, times: 1);
      await expectLater(
        t.send(const RpcCall('op', null)),
        throwsA(isA<CrateStackInFlight>()),
      );
      t.refuse('op', 409, 'C', 'x', times: 1);
      await expectLater(
        t.send(const RpcCall('op', null)),
        throwsA(isA<CrateStackConflict>()),
      );
    });

    test('heal stops a scripted failure', () async {
      t.refuse('op', 403, 'FORBIDDEN', 'no');
      t.heal('op');
      await t.send(const RpcCall('op', null));
      expect(t.runs('op'), 1);
    });
  });

  group('FakeRowServer', () {
    OwnedRow row(
      String id,
      String title,
      int stamp, {
      Set<String> dirty = const {},
    }) => OwnedRow(
      collection: 'notes',
      id: id,
      fields: {'title': title},
      stamps: {'title': Hlc(stamp, 0, 'a')},
      dirty: {...dirty},
    );

    test(
      'push merges with LwwMerge and answers the merged truth, clean',
      () async {
        final server = FakeRowServer();
        server.put(row('n1', 'server', 9));
        final result = await server.push([
          row('n1', 'older', 5, dirty: {'title'}),
        ]);
        expect(result.accepted.single.fields['title'], 'server');
        expect(result.accepted.single.dirty, isEmpty);
        expect(server.pushes, hasLength(1));
      },
    );

    test('push can reject by id, with the server\'s version', () async {
      final server = FakeRowServer()..put(row('n1', 'server', 9));
      server.rejectIds.add('n1');
      final result = await server.push([
        row('n1', 'mine', 10, dirty: {'title'}),
      ]);
      expect(result.accepted, isEmpty);
      expect(result.rejected.single.code, 'FORBIDDEN');
      expect(result.rejected.single.server!.fields['title'], 'server');
    });

    test('pull pages by cursor', () async {
      final server = FakeRowServer(pageSize: 2);
      for (var i = 0; i < 3; i++) {
        server.put(row('n$i', '$i', i + 1));
      }
      final first = await server.pull('notes', null);
      expect(first.rows, hasLength(2));
      expect(first.hasMore, isTrue);
      final second = await server.pull('notes', first.nextCursor);
      expect(second.rows, hasLength(1));
      expect(second.hasMore, isFalse);
      final third = await server.pull('notes', second.nextCursor);
      expect(third.rows, isEmpty);
    });

    test('offline throws CrateStackOffline', () async {
      final server = FakeRowServer()..offline = true;
      await expectLater(
        server.pull('notes', null),
        throwsA(isA<CrateStackOffline>()),
      );
      await expectLater(server.push([]), throwsA(isA<CrateStackOffline>()));
    });
  });

  group('crateStackTestOverrides', () {
    test(
      'wires a fake transport, a synchronous store and a signed-in scope',
      () {
        final container = containerFor();
        expect(
          container.read(crateStackTransport),
          isA<FakeCrateStackTransport>(),
        );
        expect(container.read(localStore), isA<InMemoryLocalStore>());
        expect(container.read(crateStackScope), 'u1');
      },
    );

    test('a null scope is signed out', () {
      expect(containerFor(scope: null).read(crateStackScope), isNull);
    });

    test('the default scope is a signed-in test user', () {
      final container = ProviderContainer(overrides: crateStackTestOverrides());
      addTearDown(container.dispose);
      expect(container.read(crateStackScope), 'test-user');
    });

    test('a bare container can fire the resume signal without a binding', () {
      final container = containerFor();
      container.read(appResumeSignal.notifier).fire();
      expect(container.read(appResumeSignal), 1);
    });
  });

  test('ManualSyncTicker fires the signal', () {
    final container = containerFor(
      extra: [syncTicker.overrideWith(ManualSyncTicker.new)],
    );
    expect(container.read(syncTicker), 0);
    (container.read(syncTicker.notifier) as ManualSyncTicker).tick();
    expect(container.read(syncTicker), 1);
  });

  test(
    'crateStackAccount.clear wipes one account: intents, rows, cursors and cached reads',
    () async {
      final store = InMemoryLocalStore();
      final transport = FakeCrateStackTransport()..offline = true;
      final container = containerFor(store: store, transport: transport);
      await submitCancel(container.read(intentQueue));
      await container.read(ownedRows).edit('notes', 'n1', {'title': 't'});
      await container.read(readCache).write('u1', 'orders', '1', [1], epoch);
      await containerFor(
        store: store,
        scope: 'u2',
      ).read(ownedRows).edit('notes', 'n9', {'title': 'x'});
      expect(store.keys('cs/u1/'), isNotEmpty);

      await container.read(crateStackAccount).clear();

      expect(store.keys('cs/u1/'), isEmpty);
      expect(
        store.keys('cs/u2/'),
        isNotEmpty,
        reason: 'the other account is untouched',
      );
      expect(
        store.read('cs/node'),
        isNotNull,
        reason: 'the node id names the device',
      );
    },
  );

  test(
    'crateStackAccount.clear can name the account a sign-out is leaving',
    () async {
      final store = InMemoryLocalStore();
      final container = containerFor(store: store);
      await container.read(ownedRows).edit('notes', 'n1', {'title': 't'});
      final signedOut = containerFor(store: store, scope: null);
      await signedOut.read(crateStackAccount).clear();
      expect(
        store.keys('cs/u1/'),
        isNotEmpty,
        reason: 'no scope, nothing to wipe',
      );
      await signedOut.read(crateStackAccount).clear(scope: 'u1');
      expect(store.keys('cs/u1/'), isEmpty);
    },
  );

  test('the account wipe takes a Storage-backed read cache too', () async {
    final storage = MemoryDataStorage();
    final cache = ReadCache.storage(storage);
    await cache.write('u1', 'orders', '1', [1], epoch);
    final container = containerFor(extra: [readCache.overrideWithValue(cache)]);
    await container.read(crateStackAccount).clear();
    expect(await cache.read('u1', 'orders', '1'), isNull);
  });
}
