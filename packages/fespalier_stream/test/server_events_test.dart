// ServerEvents over FakeEventServer: what each answer does, resuming, pausing and the abort trigger
// that every way of giving a request up completes.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart' show DataRefusal;
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final url = Uri.parse('https://api.example.com/orders/live');

/// A decorator's refusal, as `fespalier_auth`'s `AuthRejected` is.
final class SessionEnded implements Exception, DataRefusal {
  const SessionEnded();
}

/// What a listener of a connection saw.
final class Seen {
  Seen(Stream<ServerEvent> events) {
    subscription = events.listen(
      (e) => data.add(e.data),
      onError: (Object e) => errors.add(e),
      onDone: () => done = true,
    );
  }

  late final StreamSubscription<ServerEvent> subscription;
  final List<String> data = [];
  final List<Object> errors = [];
  bool done = false;
}

Future<void> settle() => pumpEventQueue();

void main() {
  late FakeEventServer server;
  late ServerEvents events;

  setUp(() {
    server = FakeEventServer();
    events = ServerEvents(server, url, name: 'orders');
  });

  test('it opens when listened to, with the event stream headers', () async {
    expect(events.status, const LiveConnecting(1));
    expect(server.requests, isEmpty);
    final seen = Seen(events.events);
    expect(server.requests, isEmpty, reason: 'never inside the listen call');
    await settle();
    final request = server.requests.single;
    expect(request.method, 'GET');
    expect(request.uri, url);
    expect(request.headers['Accept'], 'text/event-stream');
    expect(request.headers['Cache-Control'], 'no-cache');
    expect(request.headers.containsKey('Last-Event-ID'), isFalse);
    expect(request.abortTrigger, isNotNull);
    expect(request.memo, isNotNull);
    expect(events.status, const LiveOpen());
    expect(events.lastSeen, isNotNull);

    server.current.event('one', id: 'e1');
    server.current.comment();
    server.current.event('two');
    await settle();
    expect(seen.data, ['one', 'two']);
    expect(events.lastEventId, 'e1');
    await seen.subscription.cancel();
  });

  test(
    'every request is a new logical request, with a memo of its own',
    () async {
      final seen = Seen(events.events);
      await settle();
      server.current
        ..event('a')
        ..end();
      await settle();
      expect(server.requests, hasLength(2));
      expect(
        identical(server.requests[0].memo, server.requests[1].memo),
        isFalse,
      );
      await seen.subscription.cancel();
    },
  );

  test(
    'an orderly end after an event opens again at once, from the last event ID',
    () async {
      final seen = Seen(events.events);
      await settle();
      server.current
        ..event('a', id: '7')
        ..end();
      await settle();
      expect(server.connections, hasLength(2));
      expect(server.current.lastEventId, '7');
      expect(events.status, const LiveOpen(resumed: true));
      server.current.event('b');
      await settle();
      expect(seen.data, ['a', 'b']);
      expect(seen.errors, isEmpty);
      await seen.subscription.cancel();
    },
  );

  test('an orderly end without an event waits for reconnect', () async {
    final seen = Seen(events.events);
    await settle();
    server.current.end();
    await settle();
    expect(server.connections, hasLength(1));
    final status = events.status as LiveWaiting;
    expect(status.drop, LiveDrop.ended);
    expect(status.failures, 1);
    expect(events.reconnect(), isTrue);
    expect(events.reconnect(), isFalse, reason: 'already connecting');
    expect(events.status, const LiveConnecting(2));
    await settle();
    expect(server.connections, hasLength(2));
    expect(seen.errors, isEmpty);
    expect(seen.done, isFalse);
    await seen.subscription.cancel();
  });

  test(
    'a resume point given by the app is sent, and kept until an event',
    () async {
      events = ServerEvents(server, url, lastEventId: '41');
      final seen = Seen(events.events);
      await settle();
      expect(server.current.lastEventId, '41');
      expect(events.status, const LiveOpen(resumed: true));
      server.current.end();
      await settle();
      expect(events.reconnect(), isTrue);
      await settle();
      expect(server.current.lastEventId, '41');
      await seen.subscription.cancel();
    },
  );

  test('204 ends the stream for good, without an error', () async {
    server.respond(204);
    final seen = Seen(events.events);
    await settle();
    expect(events.status, const LiveDone(LiveEnd.done));
    expect(seen.done, isTrue);
    expect(seen.errors, isEmpty);
    expect(events.reconnect(), isFalse);
    expect(server.abortCount, 1, reason: 'the client lets the connection go');
  });

  for (final status in [400, 401, 403, 404, 410]) {
    test(
      '$status ends the stream with ServerEventsRefused, a DataRefusal',
      () async {
        server.respond(status);
        final seen = Seen(events.events);
        await settle();
        expect(events.status, const LiveDone(LiveEnd.refused));
        expect(seen.done, isTrue);
        final error = seen.errors.single as ServerEventsRefused;
        expect(error.statusCode, status);
        expect(error, isA<DataRefusal>());
        expect(error.toString(), 'ServerEventsRefused: HTTP $status');
      },
    );
  }

  test('a pause after the end leaves the status done', () async {
    final seen = Seen(events.events);
    await settle();
    unawaited(events.close());
    // The done event is still on its way: the listener can pause and resume before it lands.
    seen.subscription.pause();
    expect(events.status, const LiveDone(LiveEnd.closed));
    seen.subscription.resume();
    expect(events.status, const LiveDone(LiveEnd.closed));
    await settle();
    expect(seen.done, isTrue);
    expect(server.requests, hasLength(1));
  });

  test("a decorator's refusal ends the stream with that refusal", () async {
    server.fail(const SessionEnded());
    final seen = Seen(events.events);
    await settle();
    expect(events.status, const LiveDone(LiveEnd.refused));
    expect(seen.errors.single, isA<SessionEnded>());
  });

  for (final status in [408, 429, 500, 502, 503]) {
    test('$status waits, with the Retry-After as its hint', () async {
      server.respond(status, headers: {'Retry-After': '30'});
      final seen = Seen(events.events);
      await settle();
      final waiting = events.status as LiveWaiting;
      expect(waiting.drop, LiveDrop.unavailable);
      expect(waiting.retryHint, const Duration(seconds: 30));
      expect(seen.errors, isEmpty);
      expect(seen.done, isFalse);
      expect(events.reconnect(), isTrue);
      await settle();
      expect(events.status, const LiveOpen());
      await seen.subscription.cancel();
    });
  }

  test('the server\'s retry field is the hint of a later wait', () async {
    final seen = Seen(events.events);
    await settle();
    server.current
      ..retry(const Duration(milliseconds: 2500))
      ..event('a')
      ..drop();
    await settle();
    final waiting = events.status as LiveWaiting;
    expect(waiting.drop, LiveDrop.failed);
    expect(waiting.retryHint, const Duration(milliseconds: 2500));
    expect(waiting.failures, 0, reason: 'this connection delivered an event');
    await seen.subscription.cancel();
  });

  for (final (status, type) in [
    (200, 'text/html; charset=utf-8'),
    (200, null),
    (206, 'text/event-stream'),
    (302, 'text/event-stream'),
  ]) {
    test('$status $type ends the stream with ServerEventsRejected', () async {
      server.respond(
        status,
        headers: {'Content-Type': ?type},
        body: '<html>log in</html>',
      );
      final seen = Seen(events.events);
      await settle();
      expect(events.status, const LiveDone(LiveEnd.rejected));
      final error = seen.errors.single as ServerEventsRejected;
      expect(error.statusCode, status);
      expect(error.contentType, type);
      expect(seen.done, isTrue);
    });
  }

  test(
    'a content type with parameters and another case is an event stream',
    () async {
      server.respond(
        200,
        headers: {'Content-Type': 'Text/Event-Stream; charset=utf-8'},
        body: 'data: hi\n\n',
      );
      final seen = Seen(events.events);
      await settle();
      expect(seen.data, ['hi']);
      await seen.subscription.cancel();
    },
  );

  test('a transport failure waits, counting the failures in a row', () async {
    server
      ..fail(const TransportUnsent())
      ..fail(const TransportTimedOut());
    final seen = Seen(events.events);
    await settle();
    var waiting = events.status as LiveWaiting;
    expect(waiting.drop, LiveDrop.failed);
    expect(waiting.failures, 1);
    events.reconnect();
    await settle();
    waiting = events.status as LiveWaiting;
    expect(waiting.failures, 2);
    events.reconnect();
    await settle();
    expect(events.status, const LiveOpen());
    server.current.event('a');
    await settle();
    expect(seen.data, ['a']);
    expect(seen.errors, isEmpty);
    await seen.subscription.cancel();
  });

  test('an error that is no Exception ends the stream with it', () async {
    server.fail(StateError('a bug'));
    final seen = Seen(events.events);
    await settle();
    expect(events.status, const LiveDone(LiveEnd.failed));
    expect(seen.errors.single, isStateError);
  });

  test(
    'a body that breaks is a drop, not an error, and a reconnect resumes',
    () async {
      final seen = Seen(events.events);
      await settle();
      server.current
        ..event('a', id: '1')
        ..drop();
      await settle();
      expect((events.status as LiveWaiting).drop, LiveDrop.failed);
      expect(seen.errors, isEmpty);
      expect(events.reconnect(), isTrue);
      await settle();
      expect(server.current.lastEventId, '1');
      await seen.subscription.cancel();
    },
  );

  test('an event over maxEventBytes is a drop', () async {
    events = ServerEvents(server, url, maxEventBytes: 16);
    final seen = Seen(events.events);
    await settle();
    server.current.event('x' * 64);
    await settle();
    expect((events.status as LiveWaiting).drop, LiveDrop.failed);
    expect(server.current.aborted, isTrue);
    expect(seen.errors, isEmpty);
    await seen.subscription.cancel();
  });

  test('cancelling the subscription completes the abort trigger', () async {
    final seen = Seen(events.events);
    await settle();
    await seen.subscription.cancel();
    await settle();
    expect(server.current.aborted, isTrue);
    expect(server.current.cancelled, isTrue);
    expect(server.abortCount, 1);
    expect(events.status, const LiveDone(LiveEnd.closed));
    expect(events.reconnect(), isFalse);
  });

  test('close completes the abort trigger and ends the stream', () async {
    final seen = Seen(events.events);
    await settle();
    await events.close();
    await settle();
    expect(server.current.aborted, isTrue);
    expect(seen.done, isTrue);
    expect(seen.errors, isEmpty);
    expect(events.status, const LiveDone(LiveEnd.closed));
  });

  test(
    'closing while the request is in flight aborts it, and nothing is reported as a drop',
    () async {
      server.hang();
      final seen = Seen(events.events);
      await settle();
      expect(events.status, const LiveConnecting(1));
      await seen.subscription.cancel();
      await settle();
      expect(server.abortCount, 1);
      expect(events.status, const LiveDone(LiveEnd.closed));
    },
  );

  test(
    'lastEventId is that of the last event handed over, not of one held while paused',
    () async {
      final seen = Seen(events.events);
      await settle();
      server.current.event('a', id: '1');
      await settle();
      expect(events.lastEventId, '1');
      seen.subscription.pause();
      server.current.event('b', id: '2');
      await settle();
      expect(events.lastEventId, '1', reason: 'read, held, not handed over');
      seen.subscription.resume();
      await settle();
      expect(seen.data, ['a', 'b']);
      expect(events.lastEventId, '2');
      await seen.subscription.cancel();
    },
  );

  test('a pause stops reading; a resume reads on', () async {
    final seen = Seen(events.events);
    await settle();
    seen.subscription.pause();
    await settle();
    expect(events.status, const LivePaused(connected: true));
    server.current.event('while paused');
    await settle();
    expect(seen.data, isEmpty);
    expect(server.current.isPaused, isTrue, reason: 'the body is not read');
    expect(
      server.current.aborted,
      isFalse,
      reason: 'a pause alone never closes',
    );
    seen.subscription.resume();
    await settle();
    expect(seen.data, ['while paused']);
    expect(events.status, const LiveOpen());
    await seen.subscription.cancel();
  });

  test(
    'closeIfPaused closes a pause that outlasted one call; a resume reopens from the last ID',
    () async {
      final seen = Seen(events.events);
      await settle();
      server.current.event('a', id: '3');
      await settle();
      expect(events.closeIfPaused(), isFalse, reason: 'not paused');
      seen.subscription.pause();
      await settle();
      expect(
        events.closeIfPaused(),
        isFalse,
        reason: 'the first tick only sees the pause',
      );
      expect(events.closeIfPaused(), isTrue);
      await settle();
      expect(server.current.aborted, isTrue);
      expect(events.status, const LivePaused(connected: false));
      expect(server.connections, hasLength(1));
      seen.subscription.resume();
      await settle();
      expect(server.connections, hasLength(2));
      expect(server.current.lastEventId, '3');
      expect(events.status, const LiveOpen(resumed: true));
      await seen.subscription.cancel();
    },
  );

  test('a brief pause between two calls is never closed', () async {
    final seen = Seen(events.events);
    await settle();
    seen.subscription.pause();
    expect(events.closeIfPaused(), isFalse);
    seen.subscription.resume();
    seen.subscription.pause();
    expect(
      events.closeIfPaused(),
      isFalse,
      reason: 'a new pause starts unseen',
    );
    seen.subscription.resume();
    await settle();
    expect(server.current.aborted, isFalse);
    await seen.subscription.cancel();
  });

  test('a reconnect while paused and waiting opens on resume', () async {
    server.fail(const TransportUnsent());
    final seen = Seen(events.events);
    await settle();
    seen.subscription.pause();
    await settle();
    expect(events.status, const LivePaused(connected: false));
    expect(events.reconnect(), isFalse);
    expect(server.requests, hasLength(1));
    seen.subscription.resume();
    await settle();
    expect(server.requests, hasLength(2));
    expect(events.status, const LiveOpen());
    await seen.subscription.cancel();
  });

  test(
    'a waiting connection paused and resumed without a reconnect still waits',
    () async {
      server.fail(const TransportUnsent());
      final seen = Seen(events.events);
      await settle();
      seen.subscription.pause();
      seen.subscription.resume();
      await settle();
      expect((events.status as LiveWaiting).drop, LiveDrop.failed);
      expect(server.requests, hasLength(1));
      await seen.subscription.cancel();
    },
  );

  test('closeIfIdle drops a connection its server stopped talking on', () {
    fakeAsync((async) {
      final seen = Seen(events.events);
      async.flushMicrotasks();
      expect(events.status, const LiveOpen());
      async.elapse(const Duration(seconds: 20));
      server.current.comment();
      async.flushMicrotasks();
      expect(events.closeIfIdle(const Duration(seconds: 30)), isFalse);
      async.elapse(const Duration(seconds: 29));
      expect(events.closeIfIdle(const Duration(seconds: 30)), isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(events.closeIfIdle(const Duration(seconds: 30)), isTrue);
      async.flushMicrotasks();
      expect(server.current.aborted, isTrue);
      expect((events.status as LiveWaiting).drop, LiveDrop.idle);
      expect(seen.errors, isEmpty);
      expect(async.pendingTimers, isEmpty);
      unawaited(seen.subscription.cancel());
      async.flushMicrotasks();
    });
  });

  test('an unanswered request is given up by closeIfIdle and tried again', () {
    // D4: a request that hangs before its headers was never recovered, because only an open
    // connection could be idle.
    fakeAsync((async) {
      server.hang();
      final seen = Seen(events.events);
      async.flushMicrotasks();
      expect(events.status, const LiveConnecting(1));
      async.elapse(const Duration(seconds: 29));
      expect(events.closeIfIdle(const Duration(seconds: 30)), isFalse);
      async.elapse(const Duration(seconds: 1));
      expect(events.closeIfIdle(const Duration(seconds: 30)), isTrue);
      async.flushMicrotasks();
      expect(server.abortCount, 1, reason: 'the hung request was aborted');
      final waiting = events.status as LiveWaiting;
      expect(waiting.drop, LiveDrop.failed);
      expect(waiting.failures, 1);
      expect(seen.errors, isEmpty);
      expect(events.reconnect(), isTrue);
      async.flushMicrotasks();
      expect(server.requests, hasLength(2));
      expect(events.status, const LiveOpen());
      expect(async.pendingTimers, isEmpty);
      unawaited(seen.subscription.cancel());
      async.flushMicrotasks();
    });
  });

  test('an id-only block sets the last event ID (WHATWG dispatch)', () async {
    // D1
    final seen = Seen(events.events);
    await settle();
    server.current.event('a', id: '5');
    await settle();
    expect(events.lastEventId, '5');
    server.current.write('id: 9\n\n');
    await settle();
    expect(
      events.lastEventId,
      '9',
      reason: 'nothing is held: the listener is up to date',
    );
    server.current.end();
    await settle();
    expect(server.current.lastEventId, '9');
    // An empty id clears it.
    server.current.write('id\n\n');
    await settle();
    expect(events.lastEventId, isNull);
    expect(seen.data, ['a']);
    await seen.subscription.cancel();
  });

  test(
    'an id-only block does not move the delivered ID past a held event',
    () async {
      final seen = Seen(events.events);
      await settle();
      seen.subscription.pause();
      server.current
        ..event('a', id: '5')
        ..write('id: 9\n\n');
      await settle();
      // Both are read (a chunk at a time) or held: the listener was handed neither.
      expect(events.lastEventId, isNull);
      seen.subscription.resume();
      await settle();
      expect(seen.data, ['a']);
      expect(events.lastEventId, '9');
      await seen.subscription.cancel();
    },
  );

  test('a server that sends retry: is waited for after an orderly end', () async {
    // D2: the classic endpoint answers retry:, one event and an end, every time.
    final seen = Seen(events.events);
    await settle();
    server.current
      ..write('retry: 5000\n')
      ..event('a', id: '1')
      ..end();
    await settle();
    expect(server.connections, hasLength(1), reason: 'not at once');
    final waiting = events.status as LiveWaiting;
    expect(waiting.drop, LiveDrop.ended);
    expect(waiting.retryHint, const Duration(seconds: 5));
    expect(events.reconnect(), isTrue);
    await settle();
    expect(server.current.lastEventId, '1');
    await seen.subscription.cancel();
  });

  test(
    'without retry:, an orderly end reopens at once only once in a row',
    () async {
      // D2: nothing may loop on microtasks against a server that ends every body at once.
      final seen = Seen(events.events);
      await settle();
      server.current
        ..event('a', id: '1')
        ..end();
      await settle();
      expect(server.connections, hasLength(2));
      server.current
        ..event('b', id: '2')
        ..end();
      await pumpEventQueue(times: 50);
      expect(
        server.connections,
        hasLength(2),
        reason: 'the second quick end waits',
      );
      final waiting = events.status as LiveWaiting;
      expect(waiting.drop, LiveDrop.ended);
      expect(waiting.retryHint, isNull);
      expect(events.reconnect(), isTrue);
      await settle();
      expect(server.connections, hasLength(3));
      expect(server.current.lastEventId, '2');
      await seen.subscription.cancel();
    },
  );

  test(
    'a connection that lasted reopens at once again after an orderly end',
    () {
      fakeAsync((async) {
        final seen = Seen(events.events);
        async.flushMicrotasks();
        server.current
          ..event('a', id: '1')
          ..end();
        async.flushMicrotasks();
        expect(server.connections, hasLength(2));
        async.elapse(const Duration(seconds: 30));
        server.current
          ..event('b', id: '2')
          ..end();
        async.flushMicrotasks();
        expect(
          server.connections,
          hasLength(3),
          reason: 'it was open for a while',
        );
        unawaited(seen.subscription.cancel());
        async.flushMicrotasks();
      });
    },
  );

  test('a retry: too large for a Duration is clamped to a day', () async {
    final seen = Seen(events.events);
    await settle();
    server.current.write('retry: 99999999999999999999999\n');
    server.current.end();
    await settle();
    expect((events.status as LiveWaiting).retryHint, const Duration(hours: 24));
    await seen.subscription.cancel();
  });

  test(
    'listening after close() sends nothing and gets a done stream',
    () async {
      // D5
      await events.close();
      final errors = <Object>[];
      var done = false;
      events.events.listen(
        (_) {},
        onError: errors.add,
        onDone: () => done = true,
      );
      await settle();
      expect(server.requests, isEmpty);
      expect(done, isTrue);
      expect(errors, isEmpty);
    },
  );

  test(
    'the user-given headers go along; Last-Event-ID is the connection\'s own',
    () async {
      events = ServerEvents(
        server,
        url,
        headers: {
          'accept': 'text/event-stream, */*',
          'Last-Event-ID': 'x',
          'X-App': '1',
        },
      );
      final seen = Seen(events.events);
      await settle();
      final headers = server.requests.single.headers;
      expect(headers['accept'], 'text/event-stream, */*');
      expect(headers.containsKey('Accept'), isFalse);
      expect(headers['X-App'], '1');
      expect(
        headers.keys.where((k) => k.toLowerCase() == 'last-event-id'),
        isEmpty,
      );
      await seen.subscription.cancel();
    },
  );

  test(
    'statusChanges starts with the current status and follows every change',
    () async {
      final statuses = <LiveStatus>[];
      final watch = events.statusChanges.listen(statuses.add);
      final seen = Seen(events.events);
      await settle();
      server.current.end();
      await settle();
      await events.close();
      await settle();
      expect(statuses.map((s) => s.runtimeType.toString()), [
        'LiveConnecting',
        'LiveOpen',
        'LiveWaiting',
        'LiveDone',
      ]);
      await watch.cancel();
      expect(seen.done, isTrue);
    },
  );

  test('toString names no URL, no data and no id', () async {
    final seen = Seen(events.events);
    await settle();
    server.current.event('secret', id: 'u-42');
    await settle();
    expect(events.toString(), 'ServerEvents(LiveOpen(resumed: false))');
    expect(events.toString(), isNot(contains('example')));
    await seen.subscription.cancel();
  });

  group('the simple form', () {
    test('streams the events and resumes after an orderly end', () async {
      final seen = Seen(server.serverEvents(url));
      await settle();
      server.current
        ..event('a', id: '1')
        ..end();
      await settle();
      expect(server.current.lastEventId, '1');
      server.current.event('b');
      await settle();
      expect(seen.data, ['a', 'b']);
      await seen.subscription.cancel();
      await settle();
      expect(server.current.aborted, isTrue);
    });

    test('a failure before the first event is the error', () async {
      server.fail(const TransportUnsent());
      final seen = Seen(server.serverEvents(url));
      await settle();
      expect(seen.errors.single, isA<TransportUnsent>());
      expect(seen.done, isTrue);
    });

    test('a drop later ends it with TransportBroken', () async {
      final seen = Seen(server.serverEvents(url));
      await settle();
      server.current
        ..event('a')
        ..drop();
      await settle();
      expect(seen.data, ['a']);
      final error = seen.errors.single as TransportBroken;
      expect(error.cause, isA<FakeConnectionReset>());
      expect(seen.done, isTrue);
    });

    test('a 503 ends it with ServerEventsUnavailable', () async {
      server.respond(503, headers: {'Retry-After': '5'});
      final seen = Seen(server.serverEvents(url));
      await settle();
      final error = seen.errors.single as ServerEventsUnavailable;
      expect(error.statusCode, 503);
      expect(error.retryAfter, const Duration(seconds: 5));
    });

    test('an end with no event, or a 204, ends it without an error', () async {
      final seen = Seen(server.serverEvents(url));
      await settle();
      server.current.end();
      await settle();
      expect(seen.done, isTrue);
      expect(seen.errors, isEmpty);
      server.respond(204);
      final again = Seen(server.serverEvents(url));
      await settle();
      expect(again.done, isTrue);
      expect(again.errors, isEmpty);
    });
  });
}
