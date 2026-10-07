// Intents: mutations the server decides. The answer table, row by row.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_cratestack/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

typedef Rig = ({
  FakeCrateStackTransport transport,
  InMemoryLocalStore store,
  IntentQueue queue,
  int Function(String tag) revision,
});

Rig rig({String? scope = 'u1'}) {
  final transport = FakeCrateStackTransport()
    ..on('cancelOrder', (input) => {'cancelled': true})
    ..on('first', (_) => 'first')
    ..on('second', (_) => 'second')
    ..on('other', (_) => 'other');
  final store = InMemoryLocalStore();
  final container = containerFor(
    transport: transport,
    store: store,
    scope: scope,
  );
  return (
    transport: transport,
    store: store,
    queue: container.read(intentQueue),
    revision: (tag) => container.read(crateStackRevision(tag)),
  );
}

/// The key of the [n]th call.
String? keyOf(FakeCrateStackTransport t, int n) => t.calls[n].idempotencyKey;

Intent only(List<Intent> intents) {
  expect(intents, hasLength(1));
  return intents.single;
}

void main() {
  group('online', () {
    test(
      'accepted: nothing kept, revisions bumped, the answer decoded',
      () async {
        final r = rig();
        final out = await r.queue.submit<String>(
          const RpcCall('cancelOrder', {'id': 42}),
          subject: 'order:42',
          touches: const {'orders'},
          decode: (o) => (o! as Map<String, Object?>).keys.single,
        );
        expect(
          out,
          isA<Accepted<String>>().having((a) => a.value, 'value', 'cancelled'),
        );
        expect(await r.queue.list(), isEmpty);
        expect(r.revision('orders'), 1);
        expect(keyOf(r.transport, 0), matches(RegExp(r'^[0-9a-f]{32}#0$')));
      },
    );

    test(
      'the intent is saved before it is sent (a crash leaves it maybe-landed)',
      () async {
        final r = rig();
        // `list` is async: read the store directly, at the moment of the send.
        var seen = '';
        r.transport.on('cancelOrder', (_) {
          seen = r.store.keys('cs/u1/intent/').map(r.store.read).join();
          return null;
        });
        await submitCancel(r.queue);
        expect(jsonDecode(seen), containsPair('status', 'sent'));
      },
    );

    test(
      'a call that cannot be encoded throws before anything is sent',
      () async {
        final r = rig();
        await expectLater(
          r.queue.submit<Object?>(
            RpcCall('cancelOrder', {'when': DateTime(2026)}),
            decode: (o) => o,
          ),
          throwsA(isA<Object>()),
        );
        expect(r.transport.calls, isEmpty);
      },
    );
  });

  group('no answer: queued, same key', () {
    test('offline: queued; the next drain sends the same key', () async {
      final r = rig();
      r.transport.offline = true;
      final out = await submitCancel(r.queue);
      expect(out, isA<Queued<Object?>>());
      final intent = only(await r.queue.list());
      expect(intent.status, IntentStatus.pending);
      expect(r.revision('orders'), 0, reason: 'queued is not accepted');

      r.transport.offline = false;
      final report = await r.queue.drain();
      expect(report.accepted, 1);
      expect(await r.queue.list(), isEmpty);
      expect(keyOf(r.transport, 1), keyOf(r.transport, 0));
      expect(r.revision('orders'), 1);
    });

    test('a lost answer, then a replay: the server ran it once', () async {
      final r = rig();
      r.transport.loseAnswer('cancelOrder');
      final out = await submitCancel(r.queue);
      expect(out, isA<Queued<Object?>>());
      expect(r.transport.runs('cancelOrder'), 1);
      final report = await r.queue.drain();
      expect(report.accepted, 1);
      expect(
        r.transport.runs('cancelOrder'),
        1,
        reason: 'the replay is answered from the store',
      );
      expect(keyOf(r.transport, 1), keyOf(r.transport, 0));
    });

    test('409 with Retry-After keeps the key', () async {
      final r = rig();
      r.transport.refuse(
        'cancelOrder',
        409,
        'IN_FLIGHT',
        'wait',
        retryAfter: true,
        times: 1,
      );
      final out = await submitCancel(r.queue);
      final queued = (out as Queued<Object?>).intent;
      expect(queued.attempt, 0);
      expect(queued.status, IntentStatus.pending);
      await r.queue.drain();
      expect(keyOf(r.transport, 1), keyOf(r.transport, 0));
      expect(await r.queue.list(), isEmpty);
    });

    test('401 keeps the key', () async {
      final r = rig();
      r.transport.refuse(
        'cancelOrder',
        401,
        'UNAUTHENTICATED',
        'sign in',
        times: 1,
      );
      final out = await submitCancel(r.queue);
      expect((out as Queued<Object?>).intent.attempt, 0);
      await r.queue.drain();
      expect(keyOf(r.transport, 1), keyOf(r.transport, 0));
    });

    test(
      'a connection failure the readers classify as offline keeps the key',
      () async {
        final transport = FakeCrateStackTransport()
          ..on('cancelOrder', (_) => 1);
        transport.fail(
          'cancelOrder',
          const FormatException('<html>'),
          times: 1,
        );
        final container = containerFor(
          transport: transport,
          extra: [
            crateStackErrors.overrideWithValue(
              CrateStackErrors([
                (e) => e is FormatException ? CrateStackOffline(e) : null,
              ]),
            ),
          ],
        );
        final queue = container.read(intentQueue);
        expect(await submitCancel(queue), isA<Queued<Object?>>());
        await queue.drain();
        expect(keyOf(transport, 1), keyOf(transport, 0));
      },
    );
  });

  group('a stored failure moves to the next key', () {
    test('5xx: pending, attempt and failures up', () async {
      final r = rig();
      r.transport.refuse('cancelOrder', 500, 'INTERNAL', 'oops', times: 1);
      final out = await submitCancel(r.queue);
      final queued = (out as Queued<Object?>).intent;
      expect(queued.attempt, 1);
      expect(queued.failures, 1);
      expect(queued.idempotencyKey, endsWith('#1'));
      await r.queue.drain();
      expect(keyOf(r.transport, 0), endsWith('#0'));
      expect(keyOf(r.transport, 1), endsWith('#1'));
      expect(
        keyOf(r.transport, 1)!.split('#').first,
        keyOf(r.transport, 0)!.split('#').first,
      );
    });

    test('a bare 500 (no envelope) is unavailable too, not offline', () {
      expect(
        CrateStackFailure.fromResponse(status: 500),
        isA<CrateStackUnavailable>(),
      );
    });
  });

  group('refusals', () {
    test('on the spot: thrown, and nothing is kept', () async {
      final r = rig();
      r.transport.refuse(
        'cancelOrder',
        422,
        'VALIDATION_ERROR',
        "field 'id' is bad",
      );
      await expectLater(
        submitCancel(r.queue),
        throwsA(isA<CrateStackRefused>()),
      );
      expect(await r.queue.list(), isEmpty);
      expect(r.revision('orders'), 0);
    });

    test('on the spot, a conflict is thrown too', () async {
      final r = rig();
      r.transport.refuse('cancelOrder', 409, 'VERSION_CONFLICT', 'stale');
      await expectLater(
        submitCancel(r.queue),
        throwsA(isA<CrateStackConflict>()),
      );
      expect(await r.queue.list(), isEmpty);
    });

    test(
      'an error no reader knows may have landed: kept under its key, Queued (as a drain treats it)',
      () async {
        final r = rig();
        r.transport.fail('cancelOrder', StateError('boom'), times: 1);
        final out = await submitCancel(r.queue);
        final kept = (out as Queued<Object?>).intent;
        expect(kept.status, IntentStatus.pending);
        expect(kept.attempt, 0);
        expect(await r.queue.list(), hasLength(1));
        await r.queue.drain();
        expect(keyOf(r.transport, 1), keyOf(r.transport, 0));
        expect(await r.queue.list(), isEmpty);
      },
    );

    test('in a drain: kept failed, with the wire code only', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue);
      r.transport.offline = false;
      r.transport.refuse(
        'cancelOrder',
        403,
        'FORBIDDEN',
        'order 42 of jo@example.com is not yours',
      );
      final report = await r.queue.drain();
      expect(report.failed, 1);
      final intent = only(await r.queue.list());
      expect(intent.status, IntentStatus.failed);
      expect(intent.reason, 'FORBIDDEN');
      expect(
        r.store.keys('cs/u1/intent/').map(r.store.read).join(),
        isNot(contains('jo@example.com')),
        reason: 'the server\'s message is never stored',
      );
      // A failed intent is not sent again.
      r.transport.heal('cancelOrder');
      await r.queue.drain();
      expect(r.transport.calls, hasLength(2));
    });

    test('in a drain: a conflict is kept for the person to resolve', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue);
      r.transport.offline = false;
      r.transport.refuse('cancelOrder', 409, 'VERSION_CONFLICT', 'stale');
      final report = await r.queue.drain();
      expect(report.conflicts, 1);
      final intent = only(await r.queue.list());
      expect(intent.status, IntentStatus.conflict);
      expect(intent.reason, 'VERSION_CONFLICT');
    });

    test(
      'in a drain: idempotency_key_conflict is a failed bug, named as such',
      () async {
        final r = rig();
        r.transport.offline = true;
        await submitCancel(r.queue);
        r.transport.offline = false;
        r.transport.refuse(
          'cancelOrder',
          422,
          'VALIDATION_ERROR',
          'idempotency_key_conflict: the key was used with another body',
        );
        await r.queue.drain();
        final intent = only(await r.queue.list());
        expect(intent.status, IntentStatus.failed);
        expect(intent.reason, idempotencyKeyConflict);
      },
    );

    test('discard removes a failed intent', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue);
      r.transport.offline = false;
      r.transport.refuse('cancelOrder', 403, 'FORBIDDEN', 'no');
      await r.queue.drain();
      await r.queue.discard(only(await r.queue.list()).id);
      expect(await r.queue.list(), isEmpty);
    });
  });

  group('the drain', () {
    test('sends oldest first, one at a time', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue, op: 'first', id: 1);
      await submitCancel(r.queue, op: 'second', id: 2);
      await submitCancel(r.queue, op: 'other', id: 3);
      r.transport.offline = false;
      r.transport.calls.clear();
      await r.queue.drain();
      expect(
        [
          for (final c in r.transport.calls)
            FakeCrateStackTransport.nameOf(c.call),
        ],
        ['first', 'second', 'other'],
      );
    });

    test('a subject waits behind an undecided earlier intent for it', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue, op: 'first', id: 1, subject: 'order:1');
      await submitCancel(r.queue, op: 'second', id: 1, subject: 'order:1');
      await submitCancel(r.queue, op: 'other', id: 2, subject: 'order:2');
      r.transport.offline = false;
      r.transport.calls.clear();
      r.transport.refuse('first', 500, 'INTERNAL', 'oops', times: 1);

      var report = await r.queue.drain();
      expect(
        [
          for (final c in r.transport.calls)
            FakeCrateStackTransport.nameOf(c.call),
        ],
        ['first', 'other'],
        reason: 'second waits behind first; another subject does not',
      );
      expect(report.accepted, 1);
      expect(report.retained, 1);

      report = await r.queue.drain();
      expect(report.accepted, 2);
      expect(await r.queue.list(), isEmpty);
    });

    test('it stops at the first call with no answer', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue, op: 'first', id: 1);
      await submitCancel(r.queue, op: 'second', id: 2);
      await submitCancel(r.queue, op: 'other', id: 3);
      r.transport.offline = false;
      r.transport.calls.clear();
      r.transport.fail('second', const CrateStackOffline(), times: 1);
      final report = await r.queue.drain();
      expect(report.offline, isTrue);
      expect(report.accepted, 1);
      expect(
        [
          for (final c in r.transport.calls)
            FakeCrateStackTransport.nameOf(c.call),
        ],
        ['first', 'second'],
      );
      expect(await r.queue.list(), hasLength(2));
    });

    test('every attempt sends byte-identical bytes', () async {
      final r = rig();
      r.transport.refuse('cancelOrder', 500, 'INTERNAL', 'oops', times: 2);
      await submitCancel(
        r.queue,
        input: {
          'id': 42,
          'lines': [1, 2, 3],
          'note': {'a': 1, 'b': null},
        },
      );
      await r.queue.drain();
      await r.queue.drain();
      expect(r.transport.calls, hasLength(3));
      final bodies = {
        for (final c in r.transport.calls) jsonEncode(c.call.toJson()),
      };
      expect(bodies, hasLength(1));
    });

    test('a sent row after a crash reuses its key', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue);
      final key = r.store.keys('cs/u1/intent/').single;
      final json = jsonDecode(r.store.read(key)!) as Map<String, Object?>;
      json['status'] =
          'sent'; // the process died between the save and the answer
      r.store.write(key, jsonEncode(json));
      r.transport.offline = false;
      await r.queue.drain();
      expect(keyOf(r.transport, 1), keyOf(r.transport, 0));
      expect(await r.queue.list(), isEmpty);
    });

    test('an intent never expires on the device', () async {
      final r = rig();
      r.transport.offline = true;
      await withClock(Clock.fixed(epoch), () => submitCancel(r.queue));
      r.transport.offline = false;
      final later = Clock.fixed(epoch.add(const Duration(days: 365)));
      final report = await withClock(later, () => r.queue.drain());
      expect(report.accepted, 1);
    });

    test('accepted intents bump the revisions of their touches once', () async {
      final r = rig();
      r.transport.offline = true;
      await submitCancel(r.queue, id: 1, subject: 'order:1');
      await submitCancel(r.queue, id: 2, subject: 'order:2');
      r.transport.offline = false;
      await r.queue.drain();
      expect(r.revision('orders'), 1);
    });

    test('with nobody signed in a drain does nothing', () async {
      final r = rig(scope: null);
      final report = await r.queue.drain();
      expect(report.accepted, 0);
      expect(r.transport.calls, isEmpty);
    });

    test(
      'submit with nobody signed in is the app\'s mistake, said plainly',
      () {
        final r = rig(scope: null);
        expect(() => submitCancel(r.queue), throwsStateError);
      },
    );
  });

  group('the queue is per account', () {
    test(
      'clear() on sign-out: every intent of this account goes, the other\'s stay',
      () async {
        final store = InMemoryLocalStore();
        final transport = FakeCrateStackTransport()..offline = true;
        final a = containerFor(
          transport: transport,
          store: store,
          scope: 'a',
        ).read(intentQueue);
        final b = containerFor(
          transport: transport,
          store: store,
          scope: 'b',
        ).read(intentQueue);
        await submitCancel(a);
        await submitCancel(b, id: 7);
        await a.clear();
        expect(await a.list(), isEmpty);
        expect(await b.list(), hasLength(1));
      },
    );

    test('A\'s intent is never sent under B\'s session', () async {
      final store = InMemoryLocalStore();
      final transport = FakeCrateStackTransport()
        ..on('cancelOrder', (_) => 1)
        ..offline = true;
      final a = containerFor(
        transport: transport,
        store: store,
        scope: 'a',
      ).read(intentQueue);
      await submitCancel(a);
      transport.offline = false;
      final b = containerFor(
        transport: transport,
        store: store,
        scope: 'b',
      ).read(intentQueue);
      final report = await b.drain();
      expect(report.accepted, 0);
      expect(transport.calls, hasLength(1));
    });
  });

  test(
    'pendingIntents lists the undecided ones, per subject, and follows the queue',
    () async {
      final transport = FakeCrateStackTransport()..on('cancelOrder', (_) => 1);
      final container = containerFor(transport: transport);
      final queue = container.read(intentQueue);
      final all = container.listen(pendingIntents(null), (_, _) {});
      final one = container.listen(pendingIntents('order:1'), (_, _) {});
      addTearDown(all.close);
      addTearDown(one.close);
      expect(await container.read(pendingIntents(null).future), isEmpty);

      transport.offline = true;
      await submitCancel(queue, id: 1);
      await submitCancel(queue, id: 2);
      expect(await container.read(pendingIntents(null).future), hasLength(2));
      expect(
        await container.read(pendingIntents('order:1').future),
        hasLength(1),
      );

      transport.offline = false;
      await queue.drain();
      expect(await container.read(pendingIntents(null).future), isEmpty);
    },
  );
}
