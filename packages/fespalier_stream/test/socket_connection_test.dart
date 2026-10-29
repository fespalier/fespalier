// SocketConnection over FakeSocketConnector (since 0.25.0): a WebSocket follows ServerEvents'
// rules. It opens when listened to, asks its grantor once per attempt, runs onOpen on every open,
// waits after any close (a drop is a status, never an error), reconnects only when told, buffers
// while paused until the tick closes it, and starts no timer.
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

final url = Uri.parse('wss://api.example.com/chat?room=1');

/// A decorator's refusal, as `fespalier_auth`'s `AuthRejected` is.
final class SessionEnded implements Exception, DataRefusal {
  const SessionEnded();
}

/// A signal the test fires (core's `reconnectSignal` is one of these).
final networkBack = NotifierProvider.autoDispose<RefetchSignal, int>(
  RefetchSignal.new,
);

/// What a listener of a connection saw.
final class Seen {
  Seen(Stream<SocketMessage> events) {
    subscription = events.listen(
      (m) => messages.add(switch (m) {
        SocketText(:final text) => text,
        SocketBytes(:final bytes) => 'bytes:${bytes.join(',')}',
      }),
      onError: (Object e) => errors.add(e),
      onDone: () => done = true,
    );
  }

  late final StreamSubscription<SocketMessage> subscription;
  final List<String> messages = [];
  final List<Object> errors = [];
  bool done = false;
}

Future<void> settle() => pumpEventQueue();

void main() {
  late FakeSocketConnector connector;
  late List<Uri> granted;
  late List<Future<void>?> grantTriggers;
  late List<String> opened;
  late SocketConnection connection;

  /// A grantor that hands out ticket-1, ticket-2..., unless [failWith] is set.
  Object? failWith;
  Future<SocketGrant> grantor(Uri asked) async {
    granted.add(asked);
    grantTriggers.add(TransportZone.current());
    final error = failWith;
    if (error != null) throw error;
    return SocketGrant(
      asked.replace(
        queryParameters: {
          ...asked.queryParameters,
          'ticket': 'ticket-${granted.length}',
        },
      ),
      protocols: const ['v2'],
      headers: const {'X-Grant': 'g'},
    );
  }

  SocketConnection make({
    SocketGrantor? grant,
    FutureOr<void> Function(SocketSender socket)? onOpen,
  }) => SocketConnection(
    connector,
    url,
    grantor: grant ?? grantor,
    protocols: const ['v1'],
    headers: const {'X-App': 'a'},
    onOpen:
        onOpen ??
        (socket) {
          opened.add('open');
          socket.sendText('subscribe');
        },
    name: 'chat',
  );

  setUp(() {
    connector = FakeSocketConnector();
    granted = [];
    grantTriggers = [];
    opened = [];
    failWith = null;
    connection = make();
  });

  test(
    'it opens when listened to, with one grant, and onOpen before it says open',
    () async {
      expect(connection.status, const LiveConnecting(1));
      final statuses = <LiveStatus>[];
      final watch = connection.statusChanges.listen(statuses.add);
      final seen = Seen(connection.events);
      expect(granted, isEmpty, reason: 'never inside the listen call');
      await settle();
      expect(granted, [url]);
      final socket = connector.current;
      expect(socket.url.queryParameters, {'room': '1', 'ticket': 'ticket-1'});
      expect(socket.protocols, ['v1', 'v2']);
      expect(socket.headers, {'X-App': 'a', 'X-Grant': 'g'});
      expect(socket.sentTexts, ['subscribe'], reason: 'onOpen sent it');
      expect(connection.status, const LiveOpen());
      expect(statuses, [
        const LiveConnecting(1),
        const LiveOpen(),
      ], reason: 'onOpen ran while it was still connecting');
      expect(connection.lastSeen, isNotNull);
      expect(connection.lastEventId, isNull);

      socket
        ..text('one')
        ..bytes([1, 2])
        ..text('one');
      await settle();
      expect(seen.messages, ['one', 'bytes:1,2', 'one']);
      expect(seen.errors, isEmpty);
      await seen.subscription.cancel();
      await watch.cancel();
      expect(socket.closedByClient, isTrue);
      expect(socket.clientCloseCode, 1000);
      expect(connection.status, const LiveDone(LiveEnd.closed));
    },
  );

  test('send is refused unless a socket is open', () async {
    expect(() => connection.send(const SocketText('early')), throwsStateError);
    final seen = Seen(connection.events);
    await settle();
    connection.send(const SocketText('hello'));
    connection.send(SocketBytes(Uint8List.fromList([7])));
    expect(connector.current.sent, hasLength(3));
    expect(connector.current.sentTexts, ['subscribe', 'hello']);

    seen.subscription.pause();
    expect(connection.status, const LivePaused(connected: true));
    connection.send(const SocketText('while paused'));
    expect(connector.current.sentTexts.last, 'while paused');
    seen.subscription.resume();

    connector.current.closeFromPeer();
    await settle();
    expect(connection.status, isA<LiveWaiting>());
    expect(() => connection.send(const SocketText('late')), throwsStateError);
    await seen.subscription.cancel();
    expect(() => connection.send(const SocketText('done')), throwsStateError);
  });

  test(
    'a socket that closed before the connection read it refuses a send',
    () async {
      final seen = Seen(connection.events);
      await settle();
      seen.subscription.pause();
      connector.current.closeFromPeer();
      expect(
        () => connection.send(const SocketText('x')),
        throwsA(isA<StateError>()),
      );
      await seen.subscription.cancel();
    },
  );

  test(
    'a close waits for reconnect, which asks a new grant and replays onOpen',
    () async {
      final seen = Seen(connection.events);
      await settle();
      connector.current
        ..text('a')
        ..closeFromPeer(1000);
      await settle();
      final waiting = connection.status as LiveWaiting;
      expect(waiting.drop, LiveDrop.ended);
      expect(waiting.failures, 0, reason: 'it delivered a message');
      expect(waiting.retryHint, isNull);
      expect(connection.lastCloseCode, 1000);
      expect(connector.sockets, hasLength(1), reason: 'never by itself');
      expect(seen.errors, isEmpty);
      expect(seen.done, isFalse);

      expect(connection.reconnect(), isTrue);
      expect(connection.reconnect(), isFalse, reason: 'already connecting');
      await settle();
      expect(granted, hasLength(2));
      expect(connector.current.url.queryParameters['ticket'], 'ticket-2');
      expect(opened, ['open', 'open']);
      expect(connector.current.sentTexts, ['subscribe']);
      connector.current.text('b');
      await settle();
      expect(seen.messages, ['a', 'b']);
      await seen.subscription.cancel();
    },
  );

  final drops = <int?, LiveDrop>{
    1000: LiveDrop.ended,
    1001: LiveDrop.ended,
    1005: LiveDrop.ended,
    1012: LiveDrop.unavailable,
    1013: LiveDrop.unavailable,
    1014: LiveDrop.unavailable,
    1006: LiveDrop.failed,
    1008: LiveDrop.failed,
    1011: LiveDrop.failed,
    4001: LiveDrop.failed,
  };
  for (final MapEntry(key: code, value: drop) in drops.entries) {
    test('a close with $code waits, ${drop.name}', () async {
      final seen = Seen(connection.events);
      await settle();
      connector.current.closeFromPeer(code);
      await settle();
      final waiting = connection.status as LiveWaiting;
      expect(waiting.drop, drop);
      expect(waiting.failures, 1);
      expect(connection.lastCloseCode, code);
      expect(seen.errors, isEmpty);
      await seen.subscription.cancel();
    });
  }

  test('a socket that breaks, or fails, waits as failed (1006)', () async {
    final seen = Seen(connection.events);
    await settle();
    connector.current.drop();
    await settle();
    expect((connection.status as LiveWaiting).drop, LiveDrop.failed);
    expect(connection.lastCloseCode, 1006);
    connection.reconnect();
    await settle();
    connector.current.drop(const FormatException('secret'));
    await settle();
    final waiting = connection.status as LiveWaiting;
    expect(waiting.drop, LiveDrop.failed);
    expect(waiting.failures, 2);
    expect(connection.lastCloseCode, 1006);
    expect(seen.errors, isEmpty);
    await seen.subscription.cancel();
  });

  test('a grant that fails waits, and is no error', () async {
    failWith = const TransportUnsent();
    final seen = Seen(connection.events);
    await settle();
    expect(connector.connectCount, 0);
    expect((connection.status as LiveWaiting).drop, LiveDrop.failed);
    failWith = null;
    connection.reconnect();
    await settle();
    expect(connection.status, const LiveOpen());
    expect(seen.errors, isEmpty);
    await seen.subscription.cancel();
  });

  test(
    'a grant answered 503 waits as unavailable, with its Retry-After',
    () async {
      failWith = TransportStatusError(
        statusCode: 503,
        headers: const {'retry-after': '20'},
        body: Uint8List(0),
      );
      final seen = Seen(connection.events);
      await settle();
      final waiting = connection.status as LiveWaiting;
      expect(waiting.drop, LiveDrop.unavailable);
      expect(waiting.retryHint, const Duration(seconds: 20));
      await seen.subscription.cancel();
    },
  );

  test('a refused grant ends the stream with the refusal', () async {
    failWith = const SessionEnded();
    final seen = Seen(connection.events);
    await settle();
    expect(connection.status, const LiveDone(LiveEnd.refused));
    expect(seen.errors.single, isA<SessionEnded>());
    expect(seen.done, isTrue);
    expect(connection.reconnect(), isFalse);
  });

  test("a connector's Error ends the stream with it", () async {
    connector.fail(ArgumentError('headers in a browser'));
    final seen = Seen(connection.events);
    await settle();
    expect(connection.status, const LiveDone(LiveEnd.failed));
    expect(seen.errors.single, isA<ArgumentError>());
  });

  test('a handshake that fails waits, and counts its failures', () async {
    connector
      ..fail(const SocketClosed(1006))
      ..fail(Exception('no'));
    final seen = Seen(connection.events);
    await settle();
    expect((connection.status as LiveWaiting).failures, 1);
    connection.reconnect();
    await settle();
    expect((connection.status as LiveWaiting).failures, 2);
    connection.reconnect();
    await settle();
    expect(connection.status, const LiveOpen());
    expect(granted, hasLength(3), reason: 'one grant per attempt');
    connector.current.text('x');
    await settle();
    connector.current.closeFromPeer();
    await settle();
    expect((connection.status as LiveWaiting).failures, 0);
    await seen.subscription.cancel();
  });

  test('an onOpen that throws closes the socket and waits', () async {
    connection = make(onOpen: (_) => throw Exception('subscribe failed'));
    final seen = Seen(connection.events);
    await settle();
    expect(connector.current.closedByClient, isTrue);
    expect((connection.status as LiveWaiting).drop, LiveDrop.failed);
    expect(seen.errors, isEmpty);
    await seen.subscription.cancel();
  });

  test('without a grantor it connects to its own URL', () async {
    connection = SocketConnection(connector, url);
    final seen = Seen(connection.events);
    await settle();
    expect(connector.current.url, url);
    expect(connector.current.protocols, isEmpty);
    expect(connector.current.headers, isEmpty);
    await seen.subscription.cancel();
  });

  test(
    'a pause buffers, a resume delivers in order, and the tick closes it',
    () async {
      final seen = Seen(connection.events);
      await settle();
      final first = connector.current;
      seen.subscription.pause();
      await settle();
      expect(connection.status, const LivePaused(connected: true));
      first
        ..text('1')
        ..text('2');
      await settle();
      expect(seen.messages, isEmpty);
      seen.subscription.resume();
      await settle();
      expect(seen.messages, ['1', '2']);

      seen.subscription.pause();
      first.text('3');
      await settle();
      expect(connection.closeIfPaused(), isFalse, reason: 'one whole tick');
      expect(connection.closeIfPaused(), isTrue);
      expect(first.closedByClient, isTrue);
      expect(connection.status, const LivePaused(connected: false));
      expect(connection.reconnect(), isFalse);
      seen.subscription.resume();
      await settle();
      expect(connector.sockets, hasLength(2));
      expect(granted, hasLength(2));
      expect(opened, hasLength(2));
      expect(connection.status, const LiveOpen());
      expect(
        seen.messages,
        anyOf(equals(['1', '2']), equals(['1', '2', '3'])),
        reason: 'what the socket buffered went with it, at most one read',
      );
      await seen.subscription.cancel();
    },
  );

  test('a drop while paused is seen at the resume', () async {
    final seen = Seen(connection.events);
    await settle();
    seen.subscription.pause();
    connector.current.closeFromPeer();
    await settle();
    // The read that was waiting when the pause came takes the close: no socket is held now.
    expect(connection.status, const LivePaused(connected: false));
    seen.subscription.resume();
    await settle();
    expect(connection.status, isA<LiveWaiting>());
    await seen.subscription.cancel();
  });

  test("an attempt given up aborts its grant's requests", () async {
    final hold = Completer<SocketGrant>();
    connection = make(
      grant: (asked) {
        grantTriggers.add(TransportZone.current());
        return hold.future;
      },
    );
    final seen = Seen(connection.events);
    await settle();
    var aborted = false;
    unawaited(grantTriggers.single!.then((_) => aborted = true));
    await seen.subscription.cancel();
    await settle();
    expect(aborted, isTrue);
    hold.complete(SocketGrant(url));
    await settle();
    expect(connector.connectCount, 0);
  });

  test('a handshake answered after a close is closed at once', () async {
    connector.hang();
    final seen = Seen(connection.events);
    await settle();
    await seen.subscription.cancel();
    final socket = connector.handshakes.single.open();
    await settle();
    expect(socket.closedByClient, isTrue);
  });

  test(
    'closeIfIdle gives up a hung handshake and a silent socket, with no timer',
    () {
      fakeAsync((async) {
        connector.hang();
        final seen = Seen(connection.events);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 29));
        expect(connection.closeIfIdle(const Duration(seconds: 30)), isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(connection.closeIfIdle(const Duration(seconds: 30)), isTrue);
        expect((connection.status as LiveWaiting).drop, LiveDrop.failed);
        expect(connection.reconnect(), isTrue);
        async.flushMicrotasks();
        expect(connection.status, const LiveOpen());
        async.elapse(const Duration(seconds: 20));
        connector.current.text('alive');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 29));
        expect(connection.closeIfIdle(const Duration(seconds: 30)), isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(connection.closeIfIdle(const Duration(seconds: 30)), isTrue);
        expect(connector.current.closedByClient, isTrue);
        expect((connection.status as LiveWaiting).drop, LiveDrop.idle);
        expect(seen.errors, isEmpty);
        expect(async.pendingTimers, isEmpty);
        unawaited(seen.subscription.cancel());
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('close ends it for good', () async {
    final seen = Seen(connection.events);
    await settle();
    await connection.close();
    await settle();
    expect(seen.done, isTrue);
    expect(seen.errors, isEmpty);
    expect(connector.current.closedByClient, isTrue);
    expect(connection.status, const LiveDone(LiveEnd.closed));
    expect(connection.reconnect(), isFalse);
  });

  test('toString says nothing of the URL, the ticket or a message', () async {
    final seen = Seen(connection.events);
    await settle();
    connector.current.text('secret');
    await settle();
    final grant = await grantor(url);
    for (final text in [
      '$connection',
      '$grant',
      '${const SocketText('secret')}',
      '${SocketBytes(Uint8List(3))}',
      '${const SocketClosed(4001)}',
    ]) {
      expect(text, isNot(contains('secret')));
      expect(text, isNot(contains('ticket')));
      expect(text, isNot(contains('example.com')));
    }
    expect('$grant', 'SocketGrant');
    expect('${const SocketClosed(4001)}', 'SocketClosed(4001)');
    await seen.subscription.cancel();
  });

  group('in a LiveFeed', () {
    late ProviderContainer container;
    late LiveFeed<SocketMessage> feed;

    ManualStreamTicker ticker() =>
        container.read(streamTicker.notifier) as ManualStreamTicker;

    setUp(() {
      container = ProviderContainer(overrides: streamTestOverrides());
      addTearDown(container.dispose);
      feed = LiveFeed<SocketMessage>((ref, lastEventId) {
        expect(lastEventId, isNull, reason: 'a socket keeps no resume point');
        return make();
      }, rules: LiveRules(reconnectOn: [networkBack]));
    });

    test(
      'the tick and a signal reconnect it, and onOpen runs each time',
      () async {
        final latest = container.listen(feed.latest, (_, _) {});
        final status = container.listen(feed.status, (_, _) {});
        await settle();
        connector.current.text('a');
        await settle();
        expect(latest.read().value, isA<SocketText>());
        connector.current.closeFromPeer(1001);
        await settle();
        expect(status.read().value, isA<LiveWaiting>());
        ticker().tick();
        await settle();
        expect(status.read().value, const LiveOpen());
        expect(opened, hasLength(2));
        connector.current.drop();
        await settle();
        container.read(networkBack.notifier).fire();
        await settle();
        expect(status.read().value, const LiveOpen());
        expect(opened, hasLength(3));
        expect(latest.read().hasError, isFalse);
        latest.close();
        status.close();
        await settle();
        expect(connector.current.closedByClient, isTrue);
      },
    );

    test(
      'a page hidden for a whole tick closes the socket, and showing it reopens',
      () async {
        final latest = container.listen(feed.latest, (_, _) {});
        await settle();
        final first = connector.current;
        latest.pause();
        ticker().tick();
        ticker().tick();
        await settle();
        expect(first.closedByClient, isTrue);
        latest.resume();
        await settle();
        expect(connector.sockets, hasLength(2));
        expect(connector.current.isOpen, isTrue);
        latest.close();
        await settle();
      },
    );
  });

  test(
    'a live change feed over a socket moves every key at a reopen',
    () async {
      final container = ProviderContainer(overrides: streamTestOverrides());
      addTearDown(container.dispose);
      final changes = ChangeFeed<String>.live(
        (ref, _) =>
            make().map((message) => message is SocketText ? message.text : ''),
      );
      final topic = changes.topic<String>((event, key) => event == key);
      final moves = <int>[];
      final sub = container.listen(topic('a'), (_, next) => moves.add(next));
      await settle();
      connector.current.text('a');
      await settle();
      expect(moves, hasLength(1));
      connector.current.closeFromPeer();
      await settle();
      (container.read(streamTicker.notifier) as ManualStreamTicker).tick();
      await settle();
      expect(moves, hasLength(2), reason: 'a reopen is a gap: nothing resumes');
      sub.close();
    },
  );

  test(
    'a close frame with no code is 1005 and an orderly close, as dart:io reports it',
    () async {
      final seen = Seen(connection.events);
      await settle();
      connector.current.closeFromPeer(null);
      await settle();
      final waiting = connection.status as LiveWaiting;
      expect(waiting.drop, LiveDrop.ended);
      expect(connection.lastCloseCode, 1005);
      expect(seen.errors, isEmpty);
      await seen.subscription.cancel();
    },
  );

  test('a SocketClosed with a null code is read as 1005 too', () async {
    final seen = Seen(connection.events);
    await settle();
    connector.current.drop(const SocketClosed(null));
    await settle();
    expect((connection.status as LiveWaiting).drop, LiveDrop.ended);
    expect(connection.lastCloseCode, 1005);
    await seen.subscription.cancel();
  });

  test('onOpen is given a view that sends and cannot listen', () async {
    SocketSender? given;
    connection = make(
      onOpen: (socket) {
        given = socket;
        socket.sendText('hello');
        socket.sendBytes(Uint8List.fromList([1]));
      },
    );
    final seen = Seen(connection.events);
    await settle();
    expect(given, isNotNull);
    expect(given, isNot(isA<StreamSocket>()));
    expect(given!.protocol, '');
    expect(connector.current.sentTexts, ['hello']);
    // The connection kept the messages: it reads them, and sees the close.
    connector.current.text('a');
    await settle();
    expect(seen.messages, ['a']);
    connector.current.closeFromPeer(1001);
    await settle();
    expect((connection.status as LiveWaiting).drop, LiveDrop.ended);
    await seen.subscription.cancel();
  });

  test(
    'an onOpen that sends after the peer closed waits, it does not end',
    () async {
      final gate = Completer<void>();
      connection = make(
        onOpen: (socket) async {
          await gate.future;
          socket.sendText('join');
        },
      );
      final seen = Seen(connection.events);
      await settle();
      connector.current.closeFromPeer(1001);
      gate.complete();
      await settle();
      expect(connection.status, isA<LiveWaiting>());
      expect((connection.status as LiveWaiting).drop, LiveDrop.failed);
      expect(seen.errors, isEmpty);
      expect(seen.done, isFalse);
      await seen.subscription.cancel();
    },
  );

  test(
    'the fake socket throws the Exception a real one throws once closed',
    () async {
      final seen = Seen(connection.events);
      await settle();
      final socket = connector.current..closeFromPeer(1000);
      expect(
        () => socket.sendText('x'),
        throwsA(isA<WebSocketConnectionClosed>()),
      );
      expect(() => socket.sendBytes(Uint8List(1)), throwsA(isA<Exception>()));
      expect(
        () => connection.send(const SocketText('x')),
        throwsStateError,
        reason: 'the connection says it once, whatever the socket threw',
      );
      await seen.subscription.cancel();
    },
  );

  test('the protocols offered are deduplicated, in order', () async {
    connection = SocketConnection(
      connector,
      url,
      grantor: (asked) async =>
          SocketGrant(asked, protocols: const ['v2', 'v1', 'v3', 'v2']),
      protocols: const ['v1', 'v1', 'v0'],
    );
    final seen = Seen(connection.events);
    await settle();
    expect(connector.current.protocols, ['v1', 'v0', 'v2', 'v3']);
    await seen.subscription.cancel();
  });

  test('a grant header replaces the connection header of any case', () async {
    connection = SocketConnection(
      connector,
      url,
      grantor: (asked) async =>
          SocketGrant(asked, headers: const {'x-app': 'grant', 'X-Other': 'o'}),
      headers: const {'X-App': 'connection', 'X-Keep': 'k'},
    );
    final seen = Seen(connection.events);
    await settle();
    expect(connector.current.headers, {
      'X-Keep': 'k',
      'x-app': 'grant',
      'X-Other': 'o',
    });
    await seen.subscription.cancel();
  });

  group('a connection is single-use', () {
    test('events after a listen is a StateError that says so', () async {
      final seen = Seen(connection.events);
      await settle();
      expect(
        () => connection.events,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('single-use'), contains("feed's builder")),
          ),
        ),
      );
      await seen.subscription.cancel();
    });

    test('events after a close is one too', () async {
      await connection.close();
      expect(() => connection.events, throwsStateError);
    });

    test(
      'closed by the listener leaving, it cannot be listened to again',
      () async {
        final seen = Seen(connection.events);
        await settle();
        await seen.subscription.cancel();
        expect(connection.status, const LiveDone(LiveEnd.closed));
        expect(() => connection.events, throwsStateError);
      },
    );
  });

  group('a SocketHandle', () {
    test(
      'reaches the connection that is current, and forgets a closed one',
      () async {
        final handle = SocketHandle();
        expect(handle.connection, isNull);
        expect(handle.isOpen, isFalse);
        expect(
          () => handle.send(const SocketText('x')),
          throwsA(isA<StateError>()),
        );
        final first = connection;
        final forgetFirst = handle.attach(first);
        final seen = Seen(first.events);
        await settle();
        expect(handle.connection, same(first));
        expect(handle.isOpen, isTrue);
        handle.send(const SocketText('one'));
        expect(connector.current.sentTexts, ['subscribe', 'one']);

        // A rebuild: the second connection is attached before the first is forgotten.
        final second = make();
        handle.attach(second);
        forgetFirst();
        expect(
          handle.connection,
          same(second),
          reason: 'the late forget is a no-op',
        );
        expect(handle.isOpen, isFalse, reason: 'it is not open yet');
        expect(
          () => handle.send(const SocketText('two')),
          throwsA(isA<StateError>()),
        );
        await seen.subscription.cancel();
      },
    );
  });
}
