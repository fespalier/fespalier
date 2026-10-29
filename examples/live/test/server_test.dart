// tool/server.dart, the server a tester runs, over real sockets on the VM: an order's event stream
// resumes from Last-Event-ID, a dropped stream is a body that broke (not an orderly end), a ticket opens
// the chat once, and "refuse" closes the chat with 4401 and answers the next ticket 401. Then the app's
// own feeds against it, through the transports LIVE_ORIGIN picks (Dio, and package:http) and
// WebSocketConnector, as on a desktop or a phone. And the server's own manners: a client that resets an
// event stream, a paused feed that a tick closed with bytes unread, a bad request, a bad WebSocket message
// leave it serving and leave no socket open.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_stream/testing.dart' hide WebSocketException;
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:live/chat.dart';
import 'package:live/orders.dart';
import 'package:live/wiring.dart';

import '../tool/server.dart';

void main() {
  late LiveToolServer server;
  late List<String> log;
  late HttpClient client;

  setUp(() async {
    log = [];
    server = await LiveToolServer.start(
      host: '127.0.0.1',
      port: 0,
      log: log.add,
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}/$path');

  /// Waits (in real time) until [test] holds.
  Future<void> until(bool Function() test) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!test()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out; log: $log');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<String> ticket() async {
    final answer = await (await client.postUrl(url('ws-ticket'))).close();
    return (jsonDecode(await utf8.decoder.bind(answer).join())
            as Map<String, Object?>)['ticket']!
        as String;
  }

  Future<int> post(String path) async {
    final response = await (await client.postUrl(url(path))).close();
    await response.drain<void>();
    return response.statusCode;
  }

  /// The `data:` of each event of an order's stream, as they come.
  Future<StreamIterator<String>> events(
    String path, {
    String? lastEventId,
  }) async {
    final request = await client.getUrl(url(path));
    if (lastEventId != null) request.headers.set('last-event-id', lastEventId);
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'text/event-stream');
    return StreamIterator(
      response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.startsWith('data: '))
          .map((line) => line.substring('data: '.length)),
    );
  }

  test('an order: now, each change, and a resume from Last-Event-ID', () async {
    final first = await events('orders/1/events');
    expect(await first.moveNext(), isTrue);
    expect(jsonDecode(first.current), containsPair('status', 'placed'));
    expect(await post('orders/1/advance'), 204);
    expect(await first.moveNext(), isTrue);
    expect(jsonDecode(first.current), containsPair('seq', 2));
    await first.cancel();

    expect(await post('orders/1/advance'), 204);
    final resumed = await events('orders/1/events', lastEventId: '2');
    expect(await resumed.moveNext(), isTrue);
    expect(jsonDecode(resumed.current), containsPair('status', 'shipped'));
    await resumed.cancel();
    expect(log, contains('sse-open #2 order-1 last-event-id=2'));
  });

  test('a dropped stream breaks, it does not end', () async {
    final stream = await events('inbox/changes');
    expect(await post('inbox/drop'), 204);
    await expectLater(stream.moveNext(), throwsA(isA<HttpException>()));
  });

  test('a ticket opens the chat once, and refused tickets are a 401', () async {
    final answer = await (await client.postUrl(url('ws-ticket'))).close();
    final ticket =
        (jsonDecode(await utf8.decoder.bind(answer).join())
            as Map<String, Object?>)['ticket'];
    expect(ticket, 'tk-1');

    final chat = url('chat?ticket=$ticket').replace(scheme: 'ws');
    final socket = await WebSocket.connect(chat.toString());
    final messages = StreamIterator(socket);
    socket.add(jsonEncode({'join': 'lobby'}));
    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current as String), {
      'type': 'joined',
      'room': 'lobby',
      'as': 'guest-1',
    });
    expect(log, contains('ws-open #1 ticket=tk-1'));

    // Single-use: the same ticket again is refused at the handshake.
    await expectLater(
      WebSocket.connect(chat.toString()),
      throwsA(isA<WebSocketException>()),
    );

    server.command('refuse');
    expect(await messages.moveNext(), isFalse);
    expect(socket.closeCode, 4401);
    expect(await post('ws-ticket'), 401);
    expect(log, contains('ticket-refused'));

    server.command('accept');
    expect(await post('ws-ticket'), 200);
  });

  test('a client that opens an event stream and leaves without reading', () async {
    // Closing a socket with bytes unread (the server's headers and first comment) resets the
    // connection: the server writes to it, reads an error and must neither stop nor keep the socket.
    for (var i = 0; i < 20; i++) {
      final socket = await Socket.connect('127.0.0.1', server.port);
      socket.write(
        'GET /inbox/changes HTTP/1.1\r\nhost: localhost\r\naccept: text/event-stream\r\n\r\n',
      );
      await socket.flush();
      await until(() => log.where((l) => l.startsWith('sse-open')).length > i);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      socket.destroy();
      expect(await post('inbox/t1/post'), 204);
    }

    await until(
      () => log.where((l) => l.startsWith('sse-closed')).length == 20,
    );
    await until(() => server.openSockets == 0);
    expect(await post('inbox/t1/post'), 204);
    expect(
      await (await client.getUrl(
        url('inbox'),
      )).close().then((r) => r.statusCode),
      200,
    );
  });

  test('an answer the client leaves is let go too', () async {
    final socket = await Socket.connect('127.0.0.1', server.port);
    const question = 'hello';
    socket.write(
      'POST /ask HTTP/1.1\r\nhost: localhost\r\ncontent-length: ${question.length}\r\n'
      '\r\n$question',
    );
    await socket.flush();
    await until(() => log.any((l) => l.startsWith('ask-open')));
    socket.destroy();
    await until(() => log.any((l) => l.startsWith('ask-closed')));
    await until(() => server.openSockets == 0);
  });

  test('a bad Last-Event-ID is no resume point', () async {
    for (final bad in ['-5', 'soon', '-99999999999']) {
      final stream = await events('orders/2/events', lastEventId: bad);
      expect(await stream.moveNext(), isTrue, reason: bad);
      expect(jsonDecode(stream.current), containsPair('seq', 1));
      await stream.cancel();
    }
    expect(await post('orders/2/advance'), 204);
    await until(() => server.openSockets == 0);
    expect(log.where((l) => l.startsWith('error')), isEmpty);
  });

  test('/ask refuses what is not UTF-8 or too large, and answers on', () async {
    final bad = await client.postUrl(url('ask'));
    bad.add([0xff, 0xfe, 0xfd]);
    final refused = await bad.close();
    expect(refused.statusCode, 400);
    await refused.drain<void>();

    final large = await client.postUrl(url('ask'));
    large.add(List.filled(100 * 1024, 0x61));
    try {
      final tooLarge = await large.close();
      expect(tooLarge.statusCode, 413);
      await tooLarge.drain<void>();
    } on SocketException catch (_) {
      // The server answered and closed before it read it all: the same refusal.
    } on HttpException catch (_) {}
    await until(
      () => log.where((l) => l.startsWith('ask-refused')).length == 2,
    );

    final fine = await client.postUrl(url('ask'));
    fine.write('ok?');
    // The first word, then the client leaves.
    final word = await utf8.decoder.bind(await fine.close()).first;
    expect(word, 'You');
    await until(() => server.openSockets == 0);
  });

  test('the tickets it keeps are bounded', () async {
    final first = await ticket();
    for (var i = 0; i < 300; i++) {
      await ticket();
    }
    final chat = url('chat?ticket=$first').replace(scheme: 'ws');
    await expectLater(
      WebSocket.connect(chat.toString()),
      throwsA(isA<WebSocketException>()),
    );
    final last = await ticket();
    final socket = await WebSocket.connect(
      url('chat?ticket=$last').replace(scheme: 'ws').toString(),
    );
    await socket.close();
  });

  test('a message that is not JSON closes the socket with 1003', () async {
    final socket = await WebSocket.connect(
      url('chat?ticket=${await ticket()}').replace(scheme: 'ws').toString(),
    );
    final messages = StreamIterator(socket);
    socket.add('this is not JSON');
    expect(await messages.moveNext(), isFalse);
    expect(socket.closeCode, 1003);
    await until(() => log.any((l) => l.startsWith('ws-closed')));
    expect(log, contains('ws-bad-message #1 (not JSON)'));
    expect(log, contains('ws-closed #1 code=1003 (server)'));
  });

  for (final (name, transport) in <(String, HttpTransport Function())>[
    ('Dio', () => DioTransport(Dio())),
    ('package:http', () => HttpClientTransport(http.Client())),
  ]) {
    ProviderContainer app() {
      final container = ProviderContainer(
        overrides: [
          liveOrigin.overrideWithValue(
            originOf('http://127.0.0.1:${server.port}'),
          ),
          liveTransport.overrideWithValue(transport()),
          liveConnector.overrideWithValue(const WebSocketConnector()),
          // A bare container has no WidgetsBinding to hear the app come back.
          appShowSignal.overrideWith(RefetchSignal.new),
          ...streamTestOverrides(),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a paused feed that a tick closes does not stop the server, '
        'through $name', () async {
      final container = app();
      final seen = Completer<void>();
      final subscription = container.listen(orderLive(1), (_, next) {
        if (next.hasValue && !seen.isCompleted) seen.complete();
      }, fireImmediately: true);
      await seen.future.timeout(const Duration(seconds: 10));

      // Nobody reads the feed, the server writes to it, and the tick closes it with bytes unread.
      subscription.pause();
      for (var i = 0; i < 3; i++) {
        expect(await post('orders/1/advance'), 204);
      }
      final ticker =
          container.read(streamTicker.notifier) as ManualStreamTicker;
      ticker.tick();
      ticker.tick();

      await until(() => log.any((l) => l.startsWith('sse-closed')));
      await until(() => server.openSockets == 0);
      expect(await post('orders/1/advance'), 204);
      expect(log.where((l) => l.startsWith('error')), isEmpty);
    });

    test('the app\'s feeds against it, through $name', () async {
      final container = app();

      Future<T> first<T>(
        ProviderListenable<AsyncValue<T>> provider,
        bool Function(T value) test,
      ) {
        final found = Completer<T>();
        container.listen(provider, (_, next) {
          final value = next.value;
          if (value != null && test(value) && !found.isCompleted) {
            found.complete(value);
          }
        }, fireImmediately: true);
        return found.future.timeout(const Duration(seconds: 10));
      }

      final order = await first(orderLive(1), (_) => true);
      expect(order.status, 'placed');
      await post('orders/1/advance');
      expect((await first(orderLive(1), (o) => o.seq == 2)).status, 'packed');

      await first(
        chat.latest,
        (log) =>
            log.lines.any((line) => line.text == 'Joined lobby as guest-1'),
      );
      container.read(chatSocket).send(SocketText(jsonEncode({'say': 'hi'})));
      await first(
        chat.latest,
        (log) => log.lines.any((l) => l.from == 'you' && l.text == 'hi'),
      );
      expect(log, contains('ws-open #1 ticket=tk-1'));
    });
  }
}
