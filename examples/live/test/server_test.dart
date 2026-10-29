// tool/server.dart, the server a tester runs, over real sockets on the VM: an order's event stream
// resumes from Last-Event-ID, a dropped stream is a body that broke (not an orderly end), a ticket opens
// the chat once, and "refuse" closes the chat with 4401 and answers the next ticket 401. Then the app's
// own feeds against it, through the transports LIVE_ORIGIN picks (Dio, and package:http) and
// WebSocketConnector, as on a desktop or a phone.
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

  for (final (name, transport) in <(String, HttpTransport Function())>[
    ('Dio', () => DioTransport(Dio())),
    ('package:http', () => HttpClientTransport(http.Client())),
  ]) {
    test('the app\'s feeds against it, through $name', () async {
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
