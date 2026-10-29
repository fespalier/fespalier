// WebSocketConnector on the VM (since 0.25.0), against a dart:io server upgraded with
// WebSocketTransformer: the handshake carries the headers natively, text and bytes go both ways, a
// close code arrives, and a refused handshake says nothing of the URL. The browser side is
// packages/fespalier_dio/test/browser/harness.dart (`just fetch-adapter`).
//
// It is test code: a real socket, a real server.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fespalier_stream/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the server saw of one connection.
final class Peer {
  Peer(this.request, this.socket);

  final HttpRequest request;
  final WebSocket socket;
  final List<Object> received = [];

  /// The close code the client sent, once its close arrived.
  final Completer<int?> closed = Completer<int?>();

  /// Completes once [count] messages arrived.
  Future<void> receivedAtLeast(int count) async {
    while (received.length < count) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
}

void main() {
  late HttpServer server;
  late StreamController<Peer> peers;
  const connector = WebSocketConnector();

  setUp(() async {
    peers = StreamController<Peer>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/refuse') {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: (offered) => offered.contains('v2') ? 'v2' : null,
      );
      final peer = Peer(request, socket);
      socket.listen(
        (Object? data) => peer.received.add(data!),
        onDone: () {
          peer.closed.complete(socket.closeCode);
          unawaited(socket.close());
        },
      );
      peers.add(peer);
    });
  });

  tearDown(() async {
    await server.close(force: true);
    // A stream nobody listened to never delivers its done: not awaited.
    unawaited(peers.close());
  });

  Uri at(String path, [Map<String, String>? query]) => Uri(
    scheme: 'ws',
    host: '127.0.0.1',
    port: server.port,
    path: path,
    queryParameters: query,
  );

  test(
    'the handshake carries the headers, the query and the protocol',
    () async {
      final socket = await connector.connect(
        at('/chat', {'ticket': 'tk-1'}),
        protocols: const ['v1', 'v2'],
        headers: const {'X-Device': 'phone-1'},
      );
      final peer = await peers.stream.first;
      expect(peer.request.headers.value('x-device'), 'phone-1');
      expect(peer.request.uri.queryParameters['ticket'], 'tk-1');
      expect(socket.protocol, 'v2');
      await socket.close(1000);
    },
  );

  test('text and bytes go both ways, and a close code arrives', () async {
    final socket = await connector.connect(at('/chat'));
    final peer = await peers.stream.first;
    expect(socket.protocol, '');
    final iterator = StreamIterator<SocketMessage>(socket.messages);

    socket
      ..sendText('hello')
      ..sendBytes(Uint8List.fromList([1, 2, 3]));
    peer.socket
      ..add('from server')
      ..add(<int>[9, 8]);
    expect(await iterator.moveNext(), isTrue);
    expect((iterator.current as SocketText).text, 'from server');
    expect(await iterator.moveNext(), isTrue);
    expect((iterator.current as SocketBytes).bytes, [9, 8]);
    await peer.receivedAtLeast(2);
    expect(peer.received, [
      'hello',
      [1, 2, 3],
    ]);

    await peer.socket.close(4001, 'secret reason');
    await expectLater(
      iterator.moveNext(),
      throwsA(
        isA<SocketClosed>()
            .having((e) => e.code, 'code', 4001)
            .having((e) => '$e', 'toString', isNot(contains('secret'))),
      ),
    );
    await iterator.cancel();
    await socket.close();
  });

  test('a client close reaches the server with its code', () async {
    final socket = await connector.connect(at('/chat'));
    final peer = await peers.stream.first;
    await socket.close(1000);
    expect(await peer.closed.future, 1000);
    await socket.close(1000);
  });

  test('a refused handshake is an Exception that names no URL', () async {
    await expectLater(
      connector.connect(at('/refuse', {'ticket': 'tk-secret'})),
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'toString',
          allOf(isNot(contains('tk-secret')), isNot(contains('127.0.0.1'))),
        ),
      ),
    );
  });

  test(
    'a URL that is not ws: or wss: is an ArgumentError without it',
    () async {
      await expectLater(
        connector.connect(
          Uri.parse('https://api.example.com/ws?ticket=tk-secret'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'toString',
            isNot(contains('tk-secret')),
          ),
        ),
      );
    },
  );

  test('a SocketConnection over it, end to end', () async {
    final connection = SocketConnection(
      connector,
      at('/chat'),
      grantor: (url) async => SocketGrant(
        url.replace(queryParameters: {'ticket': 'tk-9'}),
        headers: const {'X-Device': 'phone-1'},
      ),
      onOpen: (socket) => socket.sendText(jsonEncode({'subscribe': 'room'})),
      name: 'chat',
    );
    final seen = <String>[];
    final done = Completer<void>();
    final sub = connection.events.listen((message) {
      seen.add((message as SocketText).text);
      if (seen.length == 2 && !done.isCompleted) done.complete();
    });
    final peer = await peers.stream.first;
    expect(peer.request.uri.queryParameters['ticket'], 'tk-9');
    expect(peer.request.headers.value('x-device'), 'phone-1');
    peer.socket
      ..add('a')
      ..add('b');
    await done.future;
    expect(seen, ['a', 'b']);
    connection.send(const SocketText('ping'));
    await peer.receivedAtLeast(2);
    await peer.socket.close(1001);
    await connection.statusChanges.firstWhere((s) => s is LiveWaiting);
    expect((connection.status as LiveWaiting).drop, LiveDrop.ended);
    expect(connection.lastCloseCode, 1001);
    expect(peer.received.first, '{"subscribe":"room"}');
    expect(peer.received, contains('ping'));
    await sub.cancel();
  });
}
