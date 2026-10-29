// A push from the server (since 0.25.0): SyncReason.push skips the minimum interval, and a push that
// arrives while a sync runs is not joined to it (the run may already have pulled past the change):
// the engine is marked dirty and runs once more after it, so a burst gives two runs, never more.
// autoSync follows syncPushSignal, here a change feed over a CrateStack subscription served by
// fespalier_stream's FakeEventServer. Nothing here leaves a timer behind.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A [RowSync] whose pulls can be held after the server answered, while the test changes the
/// server: what a sync that already pulled past a change looks like.
final class GatedSync implements RowSync {
  GatedSync(this.inner);

  final FakeRowServer inner;

  /// While set, each pull waits for it after its answer.
  Completer<void>? gate;

  /// While set, each push waits for it before it goes to the server.
  Completer<void>? pushGate;

  /// How many pulls started.
  var pulls = 0;

  @override
  Future<PushResult> push(List<OwnedRow> dirty) async {
    final held = pushGate;
    if (held != null) await held.future;
    return inner.push(dirty);
  }

  @override
  Future<PullPage> pull(String collection, String? cursor) async {
    pulls++;
    final page = await inner.pull(collection, cursor);
    final held = gate;
    if (held != null) await held.future;
    return page;
  }
}

OwnedRow note(String id, String title) => OwnedRow(
  collection: 'notes',
  id: id,
  fields: {'title': title},
  stamps: {'title': Hlc(1, 0, 'server-$id')},
);

typedef PushRig = ({
  ProviderContainer container,
  SyncEngine engine,
  GatedSync rows,
  FakeRowServer server,
});

PushRig pushRig({String? Function()? scope}) {
  final server = FakeRowServer();
  final rows = GatedSync(server);
  final container = containerFor(rowServer: rows, collections: const ['notes']);
  return (
    container: container,
    engine: SyncEngine(
      rows: container.read(ownedRows),
      rowSync: rows,
      intents: container.read(intentQueue),
      collections: const ['notes'],
      bump: container.read(crateStackBump),
      scope: scope,
    ),
    rows: rows,
    server: server,
  );
}

final base = Uri.parse('https://api.example.com/');

/// Runs what is due now: microtasks, and Riverpod's scheduler, which rebuilds on a zero-length
/// timer (Riverpod's, not this package's).
void settleFake(FakeAsync async) {
  for (var i = 0; i < 10; i++) {
    async.elapse(Duration.zero);
  }
}

/// The server's changes, as an app declares them: a live change feed over the subscription.
ChangeFeed<CrateStackModelEvent> serverChanges(FakeEventServer server) =>
    ChangeFeed<CrateStackModelEvent>.live(
      (ref, _) => crateStackEvents(server, base, 'model.Note.subscribe'),
      name: 'serverChanges',
    );

void main() {
  group('SyncEngine', () {
    test(
      'a push runs inside the minimum interval, where a tick does not',
      () async {
        var now = epoch;
        final r = pushRig();
        await withClock(Clock(() => now), () async {
          expect((await r.engine.sync(SyncReason.start)).reachedServer, isTrue);
          now = now.add(const Duration(seconds: 2));
          expect((await r.engine.sync(SyncReason.tick)).skipped, isTrue);

          r.server.put(note('n2', 'from the server'));
          final pushed = await r.engine.sync(SyncReason.push);
          expect(pushed.skipped, isFalse);
          expect(pushed.reason, SyncReason.push);
          expect(pushed.pulled, 1);
          expect(
            (await r.container.read(ownedRows).get('notes', 'n2'))?.fields,
            {'title': 'from the server'},
          );
        });
      },
    );

    test(
      'a push during a run is not joined to it: one more run follows, and gets the change',
      () async {
        final r = pushRig();
        r.rows.gate = Completer<void>();
        final first = r.engine.sync(SyncReason.manual);
        await pumpEventQueue();
        expect(r.rows.pulls, 1, reason: 'the first run pulled, and is held');

        // The server changes after the running sync's pull answered: that run will not see it.
        r.server.put(note('n2', 'changed meanwhile'));
        final pushed = r.engine.sync(SyncReason.push);
        expect(pushed, isNot(same(first)));

        r.rows.gate!.complete();
        r.rows.gate = null;
        expect((await first).pulled, 0);
        final report = await pushed;
        expect(report.reason, SyncReason.push);
        expect(report.pulled, 1);
        expect(r.rows.pulls, 2, reason: 'exactly one more run');
        expect((await r.container.read(ownedRows).get('notes', 'n2'))?.fields, {
          'title': 'changed meanwhile',
        });
      },
    );

    test('a burst of pushes during a run gives two runs, never more', () async {
      final r = pushRig();
      r.rows.gate = Completer<void>();
      final first = r.engine.sync(SyncReason.push);
      await pumpEventQueue();
      final burst = [
        for (var i = 0; i < 5; i++) r.engine.sync(SyncReason.push),
      ];
      for (final next in burst) {
        expect(
          next,
          same(burst.first),
          reason: 'every push joins the one queued',
        );
      }
      // Other reasons still join the running sync, as before.
      expect(r.engine.sync(SyncReason.tick), same(first));

      r.rows.gate!.complete();
      r.rows.gate = null;
      await first;
      await burst.first;
      expect(r.rows.pulls, 2);

      // Once the queued run is the one running, a push marks the engine dirty again.
      r.rows.gate = Completer<void>();
      final third = r.engine.sync(SyncReason.push);
      await pumpEventQueue();
      final fourth = r.engine.sync(SyncReason.push);
      r.rows.gate!.complete();
      r.rows.gate = null;
      await third;
      await fourth;
      expect(r.rows.pulls, 4);
    });

    test(
      'a push queued behind a run does nothing when the account changed meanwhile',
      () async {
        String? account = 'ada';
        final r = pushRig(scope: () => account);
        r.rows.gate = Completer<void>();
        final first = r.engine.sync(SyncReason.manual);
        await pumpEventQueue();
        final pushed = r.engine.sync(SyncReason.push);
        account = 'grace';
        r.rows.gate!.complete();
        r.rows.gate = null;
        await first;
        final report = await pushed;
        expect(report.reachedServer, isFalse);
        expect(
          report.skipped,
          isTrue,
          reason: 'not run: a banner keeps the last real report',
        );
        expect(r.rows.pulls, 1, reason: 'the old account is not synced again');
      },
    );

    test(
      'awaited push() and the push run queued behind a sync never push together',
      () async {
        final r = pushRig();
        r.rows.gate = Completer<void>();
        final first = r.engine.sync(SyncReason.manual);
        await pumpEventQueue();
        // A row edited after the running sync's push step: it is dirty for the next run.
        await r.container.read(ownedRows).edit('notes', 'n1', {
          'title': 'mine',
        });
        // An action awaits its rows (push()), and a server push queues one more run. Either order.
        final awaited = r.engine.push();
        final queued = r.engine.sync(SyncReason.push);
        final awaitedAfter = r.engine.push();

        r.rows.gate!.complete();
        r.rows.gate = null;
        await first;
        await queued;
        await awaited;
        await awaitedAfter;
        expect(
          r.server.pushes,
          hasLength(1),
          reason: 'the row went to the server once',
        );
        expect(r.server.pushes.single.single.id, 'n1');
      },
    );

    test(
      'while push() pushes it is the running operation: a signal joins it, a push waits for it',
      () async {
        final r = pushRig();
        await r.container.read(ownedRows).edit('notes', 'n1', {
          'title': 'mine',
        });
        r.rows.pushGate = Completer<void>();
        final awaited = r.engine.push();
        await pumpEventQueue();

        final tick = r.engine.sync(SyncReason.tick);
        final pushed = r.engine.sync(SyncReason.push);
        expect(pushed, isNot(same(tick)));
        r.rows.pushGate!.complete();
        r.rows.pushGate = null;
        expect((await awaited).accepted, hasLength(1));
        expect((await tick).pushed, 1, reason: 'the report says what push did');
        expect((await pushed).reason, SyncReason.push);
        expect(r.server.pushes, hasLength(1));
        expect(r.rows.pulls, 1, reason: 'only the queued run pulled');
      },
    );

    test('a failed awaited push() leaves the engine free', () async {
      final r = pushRig();
      await r.container.read(ownedRows).edit('notes', 'n1', {'title': 'mine'});
      r.server.offline = true;
      await expectLater(r.engine.push(), throwsA(isA<CrateStackOffline>()));
      r.server.offline = false;
      final rep = await r.engine.sync(SyncReason.manual);
      expect(
        rep.pushed,
        1,
        reason: 'the failed push() is not the running operation',
      );
    });
  });

  group('autoSync', () {
    test(
      'a subscription event syncs by push, a lag (a gap) syncs again, and no timer is left',
      () {
        fakeAsync((async) {
          final server = FakeEventServer();
          final changes = serverChanges(server);
          final rows = GatedSync(FakeRowServer());
          final container = ProviderContainer(
            overrides: [
              ...crateStackTestOverrides(
                rowServer: rows,
                collections: const ['notes'],
              ),
              ...streamTestOverrides(),
              syncPushSignal.overrideWith((ref) => ref.watch(changes.any)),
            ],
          );
          final reports = <SyncReason>[];
          final sub = container.listen(autoSync, (_, next) {
            final last = next.last;
            if (!next.isSyncing && last != null) reports.add(last.reason);
          });
          settleFake(async);
          expect(reports, [SyncReason.start]);
          expect(server.requests, hasLength(1));
          expect(server.current.header('accept'), 'text/event-stream');

          // Inside the minimum interval: a push is not held off.
          server.current.modelEvent('Note', 'Updated', data: {'id': 1});
          settleFake(async);
          expect(reports, [SyncReason.start, SyncReason.push]);

          // The server drops a subscriber that lagged and ends the response: it reopens, with no
          // ID to resume from, so the reopen is a gap and the app syncs once more.
          server.current.lagged(sequence: 2);
          settleFake(async);
          expect(server.requests, hasLength(2));
          expect(server.current.lastEventId, isNull);
          expect(reports, [SyncReason.start, SyncReason.push, SyncReason.push]);

          async.elapse(const Duration(minutes: 5));
          expect(async.pendingTimers, isEmpty);
          sub.close();
          container.dispose();
          settleFake(async);
        });
      },
    );

    test('a burst of events during a sync gives two syncs, never more', () {
      fakeAsync((async) {
        final server = FakeEventServer();
        final changes = serverChanges(server);
        final rows = GatedSync(FakeRowServer());
        final container = ProviderContainer(
          overrides: [
            ...crateStackTestOverrides(
              rowServer: rows,
              collections: const ['notes'],
            ),
            ...streamTestOverrides(),
            syncPushSignal.overrideWith((ref) => ref.watch(changes.any)),
          ],
        );
        final sub = container.listen(autoSync, (_, _) {});
        settleFake(async);
        expect(rows.pulls, 1, reason: 'the start sync');

        rows.gate = Completer<void>();
        server.current.modelEvent('Note', 'Created');
        settleFake(async);
        expect(rows.pulls, 2, reason: 'the push sync started, and is held');
        for (var i = 2; i <= 6; i++) {
          server.current.modelEvent('Note', 'Updated', sequence: i);
          settleFake(async);
        }
        expect(container.read(autoSync).isSyncing, isTrue);
        rows.gate!.complete();
        rows.gate = null;
        settleFake(async);
        expect(
          rows.pulls,
          3,
          reason: 'one more after the held one, for the whole burst',
        );
        expect(container.read(autoSync).isSyncing, isFalse);

        async.elapse(const Duration(minutes: 5));
        expect(async.pendingTimers, isEmpty);
        sub.close();
        container.dispose();
        settleFake(async);
      });
    });

    test(
      'a push queued behind a run of an engine that is replaced is run again by the new one',
      () {
        fakeAsync((async) {
          final rows = GatedSync(FakeRowServer());
          final container = ProviderContainer(
            overrides: [
              ...crateStackTestOverrides(
                rowServer: rows,
                collections: const ['notes'],
                scope: 'ada',
              ),
              syncPushSignal.overrideWith((ref) => ref.watch(countProvider)),
            ],
          );
          final reports = <SyncReport>[];
          final sub = container.listen(autoSync, (_, next) {
            final last = next.last;
            if (!next.isSyncing && last != null) reports.add(last);
          });
          rows.gate = Completer<void>();
          settleFake(async);
          expect(rows.pulls, 1, reason: 'the start sync, held');

          // A push queues behind it; then the engine is rebuilt (a provider it reads changed), the
          // account being the same.
          container.read(countProvider.notifier).bump();
          settleFake(async);
          final first = container.read(syncEngine);
          container.invalidate(syncEngine);
          settleFake(async);
          expect(container.read(syncEngine), isNot(same(first)));

          rows.gate!.complete();
          rows.gate = null;
          settleFake(async);
          expect(
            rows.pulls,
            2,
            reason: 'the new engine ran the push once; the old one ran nothing',
          );
          expect(container.read(autoSync).isSyncing, isFalse);
          final last = container.read(autoSync).last!;
          expect(last.reason, SyncReason.push);
          expect(last.skipped, isFalse);
          expect(last.reachedServer, isTrue);
          expect(reports.every((r) => !r.skipped), isTrue);

          async.elapse(const Duration(minutes: 5));
          expect(async.pendingTimers, isEmpty);
          sub.close();
          container.dispose();
          settleFake(async);
        });
      },
    );

    test('a feed that was refused signed out opens again after sign-in, and '
        'follows the next account', () {
      fakeAsync((async) {
        final server = FakeEventServer()..respond(401);
        final changes = ChangeFeed<CrateStackModelEvent>.live((ref, _) {
          // The account: sign-in and sign-out replace the connection.
          ref.watch(crateStackScope);
          return crateStackEvents(server, base, 'model.Note.subscribe');
        }, name: 'serverChanges');
        final rows = GatedSync(FakeRowServer());
        final container = ProviderContainer(
          overrides: [
            // crateStackTestOverrides fixes the scope, and this test moves it.
            localStore.overrideWithValue(InMemoryLocalStore()),
            appResumeSignal.overrideWith(RefetchSignal.new),
            rowSync.overrideWithValue(rows),
            syncCollections.overrideWithValue(const ['notes']),
            crateStackScope.overrideWith((ref) => ref.watch(accountProvider)),
            ...streamTestOverrides(),
            syncPushSignal.overrideWith((ref) => ref.watch(changes.any)),
          ],
        );
        final sub = container.listen(autoSync, (_, _) {});
        final latest = container.listen(changes.latest, (_, _) {});
        settleFake(async);
        expect(server.requests, hasLength(1));
        expect(
          container.read(changes.latest).hasError,
          isTrue,
          reason: 'a 401 at a signed-out start ends the feed with its refusal',
        );

        // Nothing but the account reopens it.
        async.elapse(const Duration(minutes: 5));
        expect(server.requests, hasLength(1));

        container.read(accountProvider.notifier).set('ada');
        settleFake(async);
        expect(server.requests, hasLength(2), reason: 'opened as ada');
        final pulls = rows.pulls;
        server.current.modelEvent('Note', 'Created');
        settleFake(async);
        expect(rows.pulls, greaterThan(pulls), reason: 'and now it syncs');
        expect(container.read(changes.latest).value?.event.model, 'Note');
        expect(container.read(changes.latest).hasError, isFalse);

        // Signing out as ada closes her connection; the next account gets one of its own.
        final adas = server.current;
        container.read(accountProvider.notifier).set('grace');
        settleFake(async);
        expect(server.requests, hasLength(3));
        expect(server.connections.last, isNot(same(adas)));
        expect(server.abortCount, greaterThan(0));

        latest.close();
        sub.close();
        container.dispose();
        settleFake(async);
      });
    });

    test('a feed whose connect watches appShowSignal opens a new connection at each show, '
        'and the gap syncs', () {
      fakeAsync((async) {
        final server = FakeEventServer();
        // How a silently dead connection is replaced: a show of the app is a rebuild of the feed,
        // not a reconnect (which acts only on a connection that is waiting).
        final changes = ChangeFeed<CrateStackModelEvent>.live((ref, _) {
          ref.watch(appShowSignal);
          return crateStackEvents(server, base, 'model.Note.subscribe');
        }, rules: LiveRules(reconnectOn: [appShowSignal]));
        final rows = GatedSync(FakeRowServer());
        final container = ProviderContainer(
          overrides: [
            ...crateStackTestOverrides(
              rowServer: rows,
              collections: const ['notes'],
            ),
            ...streamTestOverrides(),
            appShowSignal.overrideWith(RefetchSignal.new),
            syncPushSignal.overrideWith((ref) => ref.watch(changes.any)),
          ],
        );
        final sub = container.listen(autoSync, (_, _) {});
        settleFake(async);
        expect(server.requests, hasLength(1));
        final pulls = rows.pulls;

        // The connection looks open and is dead: nothing arrives. The app is shown again.
        container.read(appShowSignal.notifier).fire();
        settleFake(async);
        expect(server.requests, hasLength(2));
        expect(server.current.lastEventId, isNull);
        expect(
          rows.pulls,
          pulls + 1,
          reason: 'the new connection is a gap: one sync',
        );

        async.elapse(const Duration(minutes: 5));
        sub.close();
        container.dispose();
        settleFake(async);
      });
    });

    test(
      'a push signal that throws an Exception is not tried again by a timer',
      () {
        fakeAsync((async) {
          final container = ProviderContainer(
            overrides: [
              ...crateStackTestOverrides(),
              syncRunner.overrideWithValue(Recorder()),
              syncPushSignal.overrideWith(
                (ref) => throw Exception('connect failed'),
              ),
            ],
          );
          // Something that watches the signal itself (a banner, a debug screen) sees the error:
          // without `retry:` on the provider, Riverpod 3 would try it again after 200 ms, doubling.
          final signal = container.listen(
            syncPushSignal,
            (_, _) {},
            onError: (_, _) {},
          );
          final sub = container.listen(autoSync, (_, _) {});
          settleFake(async);
          // Asked before time passes: the retries run out in a few seconds.
          expect(
            async.pendingTimers,
            isEmpty,
            reason: 'no retry timer of Riverpod',
          );
          signal.close();
          sub.close();
          container.dispose();
          settleFake(async);
        });
      },
    );

    test(
      'off, a push signal is not followed; a signal that throws stops nothing',
      () async {
        final runner = Recorder();
        final container = containerFor(
          triggers: const SyncTriggers(onPush: false),
          extra: [
            syncRunner.overrideWithValue(runner),

            syncPushSignal.overrideWith((ref) => ref.watch(countProvider)),
          ],
        );
        final sub = container.listen(autoSync, (_, _) {});
        await pumpEventQueue();
        container.read(countProvider.notifier).bump();
        await pumpEventQueue();
        expect(runner.reasons, [SyncReason.start]);
        sub.close();

        final failing = Recorder();
        final other = containerFor(
          extra: [
            syncRunner.overrideWithValue(failing),
            syncPushSignal.overrideWith((ref) => throw StateError('refused')),
          ],
        );
        final kept = other.listen(autoSync, (_, _) {});
        await pumpEventQueue();
        other.read(syncTicker.notifier).fire();
        await pumpEventQueue();
        expect(failing.reasons, [SyncReason.start, SyncReason.tick]);
        kept.close();
      },
    );
  });
}

/// A count a test moves by hand.
final countProvider = NotifierProvider<StateCount, int>(StateCount.new);

class StateCount extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

/// The signed-in account a test changes by hand.
final accountProvider = NotifierProvider<Account, String?>(Account.new);

/// The state of [accountProvider]: null while signed out.
class Account extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? account) => state = account;
}

/// A [SyncRunner] that records why it ran.
final class Recorder implements SyncRunner {
  final reasons = <SyncReason>[];

  @override
  Future<SyncReport> sync(SyncReason reason) {
    reasons.add(reason);
    return Future.value(SyncReport(reason: reason, reachedServer: true));
  }
}
