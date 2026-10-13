// Regressions from review: each test is a case that was wrong once.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A transport that holds every send until [gate] completes.
final class GateTransport implements CrateStackTransport {
  GateTransport(this.inner);
  final FakeCrateStackTransport inner;
  Completer<void>? gate;

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) async {
    final g = gate;
    if (g != null) await g.future;
    return inner.send(call, idempotencyKey: idempotencyKey);
  }
}

/// A row server whose pull waits for [gate] and then answers [page].
final class GatedPull implements RowSync {
  GatedPull(this.page);
  final PullPage page;
  final gate = Completer<void>();

  @override
  Future<PushResult> push(List<OwnedRow> dirty) async => const PushResult();

  @override
  Future<PullPage> pull(String collection, String? cursor) async {
    await gate.future;
    return page;
  }
}

/// A row server whose push is refused.
final class RefusingPush implements RowSync {
  @override
  Future<PushResult> push(List<OwnedRow> dirty) => Future.error(
    const CrateStackRefused(status: 403, code: 'FORBIDDEN', message: 'no'),
  );

  @override
  Future<PullPage> pull(String collection, String? cursor) async =>
      const PullPage([]);
}

class Who extends Notifier<String?> {
  @override
  String? build() => 'A';
  void set(String? v) => state = v;
}

final who = NotifierProvider<Who, String?>(Who.new);

/// A container whose account is [who], which a test changes.
ProviderContainer scoped({
  CrateStackTransport? transport,
  LocalStore? store,
  RowSync? rowServer,
  List<String> collections = const [],
  List<Override> extra = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      crateStackTransport.overrideWithValue(
        transport ?? FakeCrateStackTransport(),
      ),
      localStore.overrideWithValue(store ?? InMemoryLocalStore()),
      crateStackScope.overrideWith((ref) => ref.watch(who)),
      if (rowServer != null) rowSync.overrideWithValue(rowServer),
      if (collections.isNotEmpty)
        syncCollections.overrideWithValue(collections),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

Iterable<String> intentKeys(InMemoryLocalStore store) =>
    store.keys('cs/').where((k) => k.contains('/intent/'));

void main() {
  group('B1: a subject is ordered, also for submit', () {
    test(
      'a submit behind an undecided intent of the same subject is queued, not sent',
      () async {
        final t = FakeCrateStackTransport()
          ..on('a', (_) => 'a')
          ..on('b', (_) => 'b')
          ..on('c', (_) => 'c');
        final queue = containerFor(transport: t).read(intentQueue);
        t.offline = true;
        await queue.submit<Object?>(
          const RpcCall('a', 1),
          subject: 's',
          decode: (o) => o,
        );
        t.offline = false;
        t.calls.clear();

        final second = await queue.submit<Object?>(
          const RpcCall('b', 2),
          subject: 's',
          decode: (o) => o,
        );
        expect(second, isA<Queued<Object?>>());
        expect(t.calls, isEmpty, reason: 'b waits behind a');

        // Another subject does not wait.
        final other = await queue.submit<Object?>(
          const RpcCall('c', 3),
          subject: 'x',
          decode: (o) => o,
        );
        expect(other, isA<Accepted<Object?>>());

        await queue.drain();
        expect(
          [for (final c in t.calls) FakeCrateStackTransport.nameOf(c.call)],
          ['c', 'a', 'b'],
        );
      },
    );

    test(
      'two submits at once for one subject: the second waits for the first',
      () async {
        final fake = FakeCrateStackTransport()
          ..on('a', (_) => 'a')
          ..on('b', (_) => 'b');
        final gate = GateTransport(fake)..gate = Completer<void>();
        final queue = containerFor(transport: gate).read(intentQueue);
        final first = queue.submit<Object?>(
          const RpcCall('a', 1),
          subject: 's',
          decode: (o) => o,
        );
        final second = queue.submit<Object?>(
          const RpcCall('b', 2),
          subject: 's',
          decode: (o) => o,
        );
        await settle();
        gate.gate!.complete();
        expect(await first, isA<Accepted<Object?>>());
        expect(await second, isA<Queued<Object?>>());
        expect(fake.runs('b'), 0);
      },
    );
  });

  group('B2: an answer belongs to the account that asked', () {
    test(
      'a submit whose call outlives a sign-out and a sign-in does not write into the new account',
      () async {
        final fake = FakeCrateStackTransport()..on('a', (_) => 'a');
        final gate = GateTransport(fake)..gate = Completer<void>();
        final store = InMemoryLocalStore();
        final c = scoped(transport: gate, store: store);
        final pending = c
            .read(intentQueue)
            .submit<Object?>(
              const RpcCall('a', 1),
              subject: 's',
              decode: (o) => o,
            );
        await settle();
        await c.read(crateStackAccount).clear();
        c.read(who.notifier).set('B');
        fake.offline = true;
        gate.gate!.complete();

        expect(await pending, isA<Queued<Object?>>());
        expect(
          intentKeys(store),
          isEmpty,
          reason: 'not resurrected for A, not written for B',
        );
        expect(await c.read(intentQueue).list(), isEmpty);
      },
    );

    test(
      'a drain stops when the account changes, and never sends A\'s intent under B',
      () async {
        final fake = FakeCrateStackTransport()
          ..on('a', (_) => 'a')
          ..on('b', (_) => 'b');
        final gate = GateTransport(fake);
        final store = InMemoryLocalStore();
        final c = scoped(transport: gate, store: store);
        fake.offline = true;
        final queue = c.read(intentQueue);
        await queue.submit<Object?>(const RpcCall('a', 1), decode: (o) => o);
        await queue.submit<Object?>(const RpcCall('b', 2), decode: (o) => o);
        fake.offline = false;
        gate.gate = Completer<void>();

        final drain = queue.drain();
        await settle();
        c.read(who.notifier).set('B');
        c.read(intentQueue); // B gets its own queue; A's is disposed
        gate.gate!.complete();
        await drain;

        expect(
          fake.runs('a'),
          1,
          reason: 'the call that was in the air finished',
        );
        expect(fake.runs('b'), 0, reason: 'the next one was not sent under B');
      },
    );

    test(
      'a sync that outlives a sign-out does not pull A\'s rows into B',
      () async {
        final store = InMemoryLocalStore();
        final server = GatedPull(
          PullPage([
            OwnedRow(
              collection: 'notes',
              id: 'n1',
              fields: {'title': 'A\'s'},
              stamps: {'title': const Hlc(5, 0, 'srv')},
            ),
          ], nextCursor: '1'),
        );
        final c = scoped(
          store: store,
          rowServer: server,
          collections: const ['notes'],
        );
        final run = c.read(syncEngine).sync(SyncReason.manual);
        await settle();
        c.read(who.notifier).set('B');
        c.read(syncEngine); // B's engine; A's is disposed
        server.gate.complete();
        final report = await run;

        expect(report.pulled, 0);
        expect(store.keys('cs/B/'), isEmpty);
        expect(store.keys('cs/A/').where((k) => k.contains('/row/')), isEmpty);
      },
    );

    test(
      'an edit that finishes after the account changed stays with the account that made it',
      () async {
        final inner = InMemoryLocalStore();
        final c = scoped(store: AsyncStore(inner));
        final rows = c.read(ownedRows);
        final edit = rows.edit('notes', 'n1', {'title': 't'});
        c.read(who.notifier).set('B');
        await edit;
        expect(inner.keys('cs/B/'), isEmpty);
        expect(inner.keys('cs/A/'), isNotEmpty);
      },
    );
  });

  group('B2 (wipe): nothing is written back into an account after its wipe', () {
    test(
      'a send in the air when the account is wiped (the scope stays) writes nothing',
      () async {
        final fake = FakeCrateStackTransport()..on('a', (_) => 'a');
        final gate = GateTransport(fake)..gate = Completer<void>();
        final store = InMemoryLocalStore();
        final c = containerFor(transport: gate, store: store);
        final pending = c
            .read(intentQueue)
            .submit<Object?>(
              const RpcCall('a', 1),
              subject: 's',
              decode: (o) => o,
            );
        await settle();
        expect(store.keys('cs/u1/intent/'), hasLength(1));
        await c.read(crateStackAccount).clear();
        fake.offline = true;
        gate.gate!.complete();
        await pending;
        expect(store.keys('cs/u1/'), isEmpty);
      },
    );

    test('and when the scope goes null', () async {
      final fake = FakeCrateStackTransport()..on('a', (_) => 'a');
      final gate = GateTransport(fake)..gate = Completer<void>();
      final store = InMemoryLocalStore();
      final c = scoped(transport: gate, store: store);
      final pending = c
          .read(intentQueue)
          .submit<Object?>(const RpcCall('a', 1), decode: (o) => o);
      await settle();
      await c.read(crateStackAccount).clear();
      c.read(who.notifier).set(null);
      fake.offline = true;
      gate.gate!.complete();
      await pending;
      expect(store.keys('cs/A/'), isEmpty);
    });

    test(
      'a drain in the air when the account is wiped writes nothing and sends no more',
      () async {
        final fake = FakeCrateStackTransport()
          ..on('a', (_) => 'a')
          ..on('b', (_) => 'b');
        final gate = GateTransport(fake);
        final store = InMemoryLocalStore();
        final c = containerFor(transport: gate, store: store);
        fake.offline = true;
        final queue = c.read(intentQueue);
        await queue.submit<Object?>(const RpcCall('a', 1), decode: (o) => o);
        await queue.submit<Object?>(const RpcCall('b', 2), decode: (o) => o);
        fake.offline = false;
        gate.gate = Completer<void>();
        final drain = queue.drain();
        await settle();
        fake.offline = true;
        await c.read(crateStackAccount).clear();
        gate.gate!.complete();
        await drain;
        expect(fake.runs('b'), 0);
        expect(store.keys('cs/u1/'), isEmpty);
      },
    );

    test(
      'serve does not save the answer of a wiped account, the scope staying',
      () async {
        final store = InMemoryLocalStore();
        final c = containerFor(store: store);
        final gate = Completer<String>();
        final read = FutureProvider<Served<String>>(
          (ref) async => ref.serve<String>(
            key: 'me',
            codec: ServedCodec(toJson: (v) => v, fromJson: (j) => j! as String),
            fetch: () => gate.future,
          ),
        );
        final sub = c.listen(read, (_, _) {});
        addTearDown(sub.close);
        await settle();
        await c.read(crateStackAccount).clear();
        gate.complete('secret');
        await settle();
        await settle();
        expect(store.keys('cs/u1/'), isEmpty);
      },
    );

    test(
      'an edit in the air when the account is wiped is not written back',
      () async {
        final inner = InMemoryLocalStore();
        final c = containerFor(store: AsyncStore(inner));
        final edit = c.read(ownedRows).edit('notes', 'n1', {'title': 't'});
        await c.read(crateStackAccount).clear();
        await edit;
        expect(inner.keys('cs/u1/'), isEmpty);
      },
    );

    test(
      'a sync in the air when the account is wiped adopts nothing',
      () async {
        final store = InMemoryLocalStore();
        final server = GatedPull(
          PullPage([
            OwnedRow(
              collection: 'notes',
              id: 'n1',
              fields: {'title': 'x'},
              stamps: {'title': const Hlc(5, 0, 'srv')},
            ),
          ], nextCursor: '1'),
        );
        final c = containerFor(
          store: store,
          rowServer: server,
          collections: const ['notes'],
        );
        final run = c.read(syncEngine).sync(SyncReason.manual);
        await settle();
        await c.read(crateStackAccount).clear();
        server.gate.complete();
        final report = await run;
        expect(report.pulled, 0);
        expect(store.keys('cs/u1/'), isEmpty);
      },
    );
  });

  group('H1: a read does not write after its account left', () {
    test(
      'serve does not save the answer of an account that signed out meanwhile',
      () async {
        final store = InMemoryLocalStore();
        final c = scoped(store: store);
        final gate = Completer<String>();
        final read = FutureProvider<Served<String>>(
          (ref) async => ref.serve<String>(
            key: 'me',
            codec: ServedCodec(toJson: (v) => v, fromJson: (j) => j! as String),
            fetch: () => gate.future,
          ),
        );
        final sub = c.listen(read, (_, _) {});
        addTearDown(sub.close);
        await settle();
        await c.read(crateStackAccount).clear(scope: 'A');
        c.read(who.notifier).set(null);
        gate.complete('secret of A');
        await settle();
        await settle();
        expect(store.keys('cs/'), isEmpty);
      },
    );
  });

  group('H3: TRANSACTION_ABORTED is not a conflict', () {
    test('it is the same key, try later', () {
      expect(
        CrateStackFailure.fromEnvelope(
          status: 409,
          code: 'TRANSACTION_ABORTED',
          message: 'x',
        ),
        isA<CrateStackInFlight>(),
      );
      expect(
        CrateStackFailure.fromEnvelope(
          status: 409,
          code: 'VERSION_CONFLICT',
          message: 'x',
        ),
        isA<CrateStackConflict>(),
      );
    });

    test('an intent answered so stays pending under its key', () async {
      final t = FakeCrateStackTransport()..on('a', (_) => 'a');
      final queue = containerFor(transport: t).read(intentQueue);
      t.refuse('a', 409, 'TRANSACTION_ABORTED', 'retry', times: 1);
      final out = await queue.submit<Object?>(
        const RpcCall('a', 1),
        decode: (o) => o,
      );
      expect((out as Queued<Object?>).intent.attempt, 0);
      await queue.drain();
      expect(t.calls[1].idempotencyKey, t.calls[0].idempotencyKey);
      expect(await queue.list(), isEmpty);
    });
  });

  group('M4: concurrent submits are numbered apart', () {
    test('two first submits get different seqs, in call order', () async {
      final t = FakeCrateStackTransport()..offline = true;
      final queue = containerFor(transport: t).read(intentQueue);
      await Future.wait([
        queue.submit<Object?>(const RpcCall('a', 1), decode: (o) => o),
        queue.submit<Object?>(const RpcCall('b', 2), decode: (o) => o),
      ]);
      final intents = await queue.list();
      expect([for (final i in intents) i.seq], [1, 2]);
      expect([for (final i in intents) (i.call as RpcCall).opId], ['a', 'b']);
    });
  });

  group('M6: the minimum interval does not hold back work that is waiting', () {
    Future<void> inClock(
      DateTime Function() now,
      Future<void> Function() body,
    ) => withClock(Clock(now), body);

    test(
      'a reconnect inside the interval runs when an intent was queued since',
      () async {
        var now = epoch;
        final t = FakeCrateStackTransport()..on('a', (_) => 'a');
        final c = containerFor(
          transport: t,
          rowServer: FakeRowServer(),
          collections: const ['notes'],
        );
        final engine = c.read(syncEngine);
        final queue = c.read(intentQueue);
        await inClock(() => now, () async {
          await engine.sync(
            SyncReason.start,
          ); // reached the server (nothing to do)
          now = now.add(const Duration(seconds: 3));
          t.offline = true;
          await queue.submit<Object?>(const RpcCall('a', 1), decode: (o) => o);
          t.offline = false;
          now = now.add(const Duration(seconds: 3));
          final report = await engine.sync(SyncReason.reconnect);
          expect(report.skipped, isFalse);
          expect(report.intents.accepted, 1);
        });
      },
    );

    test('and when the last sync found no network', () async {
      var now = epoch;
      final t = FakeCrateStackTransport()..on('a', (_) => 'a');
      final c = containerFor(
        transport: t,
        rowServer: FakeRowServer(),
        collections: const ['notes'],
      );
      final engine = c.read(syncEngine);
      await inClock(() => now, () async {
        await engine.sync(SyncReason.start);
        now = now.add(const Duration(seconds: 1));
        t.offline = true;
        await queueOne(c, t);
        final offline = await engine.sync(SyncReason.manual);
        expect(offline.failure, isA<CrateStackOffline>());
        t.offline = false;
        now = now.add(const Duration(seconds: 1));
        expect((await engine.sync(SyncReason.reconnect)).skipped, isFalse);
      });
    });

    test('with nothing new it is still skipped', () async {
      var now = epoch;
      final c = containerFor(
        rowServer: FakeRowServer(),
        collections: const ['notes'],
      );
      final engine = c.read(syncEngine);
      await inClock(() => now, () async {
        await engine.sync(SyncReason.start);
        now = now.add(const Duration(seconds: 3));
        expect((await engine.sync(SyncReason.tick)).skipped, isTrue);
      });
    });
  });

  group('L2: a refusal is an answer', () {
    test('a refused push counts as reaching the server', () async {
      final c = containerFor(
        rowServer: RefusingPush(),
        collections: const ['notes'],
      );
      await c.read(ownedRows).edit('notes', 'n1', {'title': 't'});
      final report = await c.read(syncEngine).sync(SyncReason.manual);
      expect(report.failure, isA<CrateStackRefused>());
      expect(report.reachedServer, isTrue);
    });
  });
}

Future<void> queueOne(ProviderContainer c, FakeCrateStackTransport t) => c
    .read(intentQueue)
    .submit<Object?>(const RpcCall('a', 9), decode: (o) => o);
