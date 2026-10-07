// The sync engine: push, then pull, then drain; single flight; the minimum interval.
import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A [RowSync] that notes what it was asked, in order, in the shared [log].
final class LoggingSync implements RowSync {
  LoggingSync(this.inner, this.log);
  final RowSync inner;
  final List<String> log;

  @override
  Future<PushResult> push(List<OwnedRow> dirty) {
    log.add('push');
    return inner.push(dirty);
  }

  @override
  Future<PullPage> pull(String collection, String? cursor) {
    log.add('pull:$collection');
    return inner.pull(collection, cursor);
  }
}

typedef Rig = ({
  ProviderContainer container,
  SyncEngine engine,
  OwnedRows rows,
  IntentQueue queue,
  FakeRowServer server,
  FakeCrateStackTransport transport,
  List<String> log,
});

Rig rig({Duration minInterval = const Duration(seconds: 10)}) {
  final log = <String>[];
  final server = FakeRowServer();
  final transport = FakeCrateStackTransport()
    ..on('cancelOrder', (_) {
      log.add('drain');
      return 1;
    });
  final container = containerFor(
    transport: transport,
    rowServer: LoggingSync(server, log),
    collections: const ['notes'],
  );
  return (
    container: container,
    engine: SyncEngine(
      rows: container.read(ownedRows),
      rowSync: LoggingSync(server, log),
      intents: container.read(intentQueue),
      collections: const ['notes'],
      bump: container.read(crateStackBump),
      minInterval: minInterval,
    ),
    rows: container.read(ownedRows),
    queue: container.read(intentQueue),
    server: server,
    transport: transport,
    log: log,
  );
}

void main() {
  test('push, then pull, then drain, in that order', () async {
    final r = rig();
    await r.rows.edit('notes', 'n1', {'title': 'made offline'});
    r.transport.offline = true;
    await submitCancel(r.queue);
    r.transport.offline = false;

    final report = await r.engine.sync(SyncReason.manual);

    expect(r.log, ['push', 'pull:notes', 'drain']);
    expect(report.reachedServer, isTrue);
    expect(report.pushed, 1);
    expect(report.intents.accepted, 1);
    expect(report.failure, isNull);
    expect(r.server.row('notes', 'n1')!.fields['title'], 'made offline');
    final local = (await r.rows.get('notes', 'n1'))!;
    expect(local.dirty, isEmpty, reason: 'acknowledged by the push');
  });

  test(
    'the drain still runs after a failed push, and the report says what failed',
    () async {
      final r = rig();
      await r.rows.edit('notes', 'n1', {'title': 't'});
      r.transport.offline = true;
      await submitCancel(r.queue);
      r.transport.offline = false;
      r.server.offline = true;

      final report = await r.engine.sync(SyncReason.manual);

      expect(report.failure, isA<CrateStackOffline>());
      expect(report.pushed, 0);
      expect(report.intents.accepted, 1);
      expect(r.log, [
        'push',
        'drain',
      ], reason: 'no pull while the push found no network');
      expect(
        (await r.rows.get('notes', 'n1'))!.dirty,
        isNotEmpty,
        reason: 'still to push',
      );
    },
  );

  test('nothing reachable: the report says so and nothing throws', () async {
    final r = rig();
    await r.rows.edit('notes', 'n1', {'title': 't'});
    r.server.offline = true;
    r.transport.offline = true;
    await submitCancel(r.queue);
    final report = await r.engine.sync(SyncReason.start);
    expect(report.reachedServer, isFalse);
    expect(report.failure, isA<CrateStackOffline>());
    expect(report.intents.offline, isTrue);
  });

  test('single flight: two calls share one run', () async {
    final r = rig();
    await r.rows.edit('notes', 'n1', {'title': 't'});
    final first = r.engine.sync(SyncReason.manual);
    final second = r.engine.sync(SyncReason.resume);
    expect(second, same(first));
    await first;
    expect(r.server.pushes, hasLength(1));
    // Once it is done, the next call is a run of its own.
    final third = r.engine.sync(SyncReason.manual);
    expect(third, isNot(same(first)));
    await third;
  });

  group('the minimum interval', () {
    test(
      'applies to signals only, and only after a sync that reached the server',
      () async {
        var now = epoch;
        final r = rig();
        await withClock(Clock(() => now), () async {
          final first = await r.engine.sync(SyncReason.start);
          expect(first.reachedServer, isTrue);

          now = now.add(const Duration(seconds: 5));
          for (final reason in [
            SyncReason.resume,
            SyncReason.reconnect,
            SyncReason.tick,
          ]) {
            final skipped = await r.engine.sync(reason);
            expect(skipped.skipped, isTrue, reason: '$reason');
            expect(skipped.reachedServer, isFalse);
          }
          expect((await r.engine.sync(SyncReason.manual)).skipped, isFalse);
          expect((await r.engine.sync(SyncReason.start)).skipped, isFalse);

          now = now.add(const Duration(seconds: 11));
          expect((await r.engine.sync(SyncReason.tick)).skipped, isFalse);
        });
      },
    );

    test(
      'a sync that reached nothing does not hold the next one off',
      () async {
        var now = epoch;
        final r = rig();
        r.server.offline = true;
        r.transport.offline = true;
        await withClock(Clock(() => now), () async {
          await r.engine.sync(SyncReason.start);
          r.server.offline = false;
          r.transport.offline = false;
          now = now.add(const Duration(seconds: 1));
          expect((await r.engine.sync(SyncReason.reconnect)).skipped, isFalse);
        });
      },
    );
  });

  group('a row the server refuses', () {
    test(
      'a new row is dropped, and the rollback is reported with the code only',
      () async {
        final r = rig();
        await r.rows.edit('notes', 'n1', {'title': 'secret text'});
        r.server.rejectIds.add('n1');
        final report = await r.engine.sync(SyncReason.manual);
        expect(report.rolledBack, hasLength(1));
        expect(report.rolledBack.single.code, 'FORBIDDEN');
        expect(report.rolledBack.single.id, 'n1');
        expect(await r.rows.get('notes', 'n1'), isNull);
      },
    );

    test("an existing row goes back to the server's version", () async {
      final r = rig();
      r.server.put(
        OwnedRow(
          collection: 'notes',
          id: 'n1',
          fields: {'title': 'server'},
          stamps: {'title': const Hlc(1, 0, 'srv')},
        ),
      );
      await r.engine.sync(SyncReason.manual);
      await r.rows.edit('notes', 'n1', {'title': 'rejected edit'});
      r.server.rejectIds.add('n1');
      final report = await r.engine.sync(SyncReason.manual);
      expect(report.rolledBack, hasLength(1));
      final local = (await r.rows.get('notes', 'n1'))!;
      expect(local.fields['title'], 'server');
      expect(local.dirty, isEmpty);
    });
  });

  group('pull', () {
    test(
      "another device's rows arrive, once, and the cursor moves on",
      () async {
        final r = rig();
        r.server.put(
          OwnedRow(
            collection: 'notes',
            id: 'n9',
            fields: {'title': 'theirs'},
            stamps: {'title': const Hlc(5, 0, 'srv')},
          ),
        );
        final first = await r.engine.sync(SyncReason.manual);
        expect(first.pulled, 1);
        expect((await r.rows.get('notes', 'n9'))!.fields['title'], 'theirs');
        final second = await r.engine.sync(SyncReason.manual);
        expect(second.pulled, 0);
      },
    );

    test('every page is pulled', () async {
      final r = rig();
      r.server.pageSize = 2;
      for (var i = 0; i < 5; i++) {
        r.server.put(
          OwnedRow(
            collection: 'notes',
            id: 'n$i',
            fields: {'title': '$i'},
            stamps: {'title': Hlc(i + 1, 0, 'srv')},
          ),
        );
      }
      final report = await r.engine.sync(SyncReason.manual);
      expect(report.pulled, 5);
      expect(await r.rows.list('notes'), hasLength(5));
      expect(r.server.pulls, 3, reason: 'two rows a page, and hasMore ends it');
    });
  });

  group('revision tags', () {
    test(
      'a pull that brought rows bumps the collection, an empty one does not',
      () async {
        final r = rig();
        r.server.put(
          OwnedRow(
            collection: 'notes',
            id: 'n9',
            fields: {'title': 'theirs'},
            stamps: {'title': const Hlc(5, 0, 'srv')},
          ),
        );
        await r.engine.sync(SyncReason.manual);
        expect(r.container.read(crateStackRevision('notes')), 1);
        await r.engine.sync(SyncReason.manual);
        expect(r.container.read(crateStackRevision('notes')), 1);
      },
    );

    test('the intents of a drain bump what they touch', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue);
      r.transport.offline = false;
      await r.engine.sync(SyncReason.manual);
      expect(r.container.read(crateStackRevision('orders')), 1);
    });
  });

  group('push()', () {
    test('sends the dirty rows and awaits them', () async {
      final r = rig();
      await r.rows.edit('notes', 'n1', {'title': 't'});
      final result = await r.engine.push();
      expect(result.accepted, hasLength(1));
      expect(r.server.row('notes', 'n1'), isNotNull);
      expect(r.log, ['push'], reason: 'no pull and no drain');
    });

    test('offline it throws: that is the honest answer', () async {
      final r = rig();
      await r.rows.edit('notes', 'n1', {'title': 't'});
      r.server.offline = true;
      await expectLater(r.engine.push(), throwsA(isA<CrateStackOffline>()));
    });

    test('with nothing dirty it asks nobody', () async {
      final r = rig();
      await r.engine.push();
      expect(r.log, isEmpty);
    });
  });

  test('syncEngine and syncRunner are the providers an app reads', () async {
    final server = FakeRowServer();
    final container = containerFor(
      rowServer: server,
      collections: const ['notes'],
    );
    expect(container.read(syncRunner), same(container.read(syncEngine)));
    await container.read(ownedRows).edit('notes', 'n1', {'title': 't'});
    final report = await container.read(syncRunner).sync(SyncReason.manual);
    expect(report.pushed, 1);
  });
}
