// ticketGrantor (since 0.25.0): a POST through the app's transport chain, its single-use ticket in
// the socket URL's query, and a refusal, an outage or a strange answer each told apart. The ticket
// never reaches a toString, an error's text or telemetry. The chain through fespalier_auth's real
// SessionTransport is fespalier_auth's test/socket_ticket_chain_test.dart.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

final endpoint = Uri.parse('https://api.example.com/ws-ticket');
final socketUrl = Uri.parse('wss://api.example.com/chat?room=1&room=2');

Future<void> settle() => pumpEventQueue();

void main() {
  test(
    'it POSTs through the transport and puts the ticket in the query',
    () async {
      final transport = FakeTransport(
        (request, body) => fakeResponse(
          200,
          body: '{"ticket":"tk-secret-1"}',
          headers: {'Content-Type': 'application/json; charset=utf-8'},
        ),
      );
      final grant = await ticketGrantor(transport, endpoint)(socketUrl);
      final sent = transport.requests.single;
      expect(sent.method, 'POST');
      expect(sent.url, endpoint);
      expect(sent.body, isEmpty);
      expect(sent.lowerHeaders['accept'], 'application/json, text/plain');
      expect(
        sent.request.memo,
        isNotNull,
        reason: 'a logical request of its own',
      );
      expect(
        HttpWrites.isWriteRequest(sent.request),
        isTrue,
        reason: 'a ticket is minted once: no retrier sends it again',
      );
      expect(grant.url.scheme, 'wss');
      expect(grant.url.path, '/chat');
      expect(grant.url.queryParametersAll, {
        'room': ['1', '2'],
        'ticket': ['tk-secret-1'],
      });
      expect(grant.protocols, isEmpty);
      expect(grant.headers, isEmpty);
      expect('$grant', 'SocketGrant');
    },
  );

  test('a text/plain ticket, another field and another parameter', () async {
    final plain = FakeTransport(
      (request, body) => fakeResponse(
        201,
        body: '  tk-2\n',
        headers: {'content-type': 'text/plain'},
      ),
    );
    final grant = await ticketGrantor(
      plain,
      endpoint,
      param: 'access',
      headers: {'X-Purpose': 'socket'},
    )(Uri.parse('ws://localhost:9/ws'));
    expect(grant.url.toString(), 'ws://localhost:9/ws?access=tk-2');
    expect(plain.requests.single.headers['X-Purpose'], 'socket');

    final json = FakeTransport(
      (request, body) => fakeResponse(
        200,
        body: '{"token":"tk-3"}',
        headers: {'content-type': 'application/json'},
      ),
    );
    final other = await ticketGrantor(json, endpoint, field: 'token')(
      Uri.parse('wss://a.example/ws'),
    );
    expect(other.url.queryParameters['ticket'], 'tk-3');
  });

  for (final status in [400, 401, 403, 404]) {
    test('$status is SocketTicketRefused, a DataRefusal', () async {
      final transport = FakeTransport(
        (request, body) => fakeResponse(status, body: 'secret detail'),
      );
      await expectLater(
        ticketGrantor(transport, endpoint)(socketUrl),
        throwsA(
          isA<SocketTicketRefused>()
              .having((e) => e.statusCode, 'statusCode', status)
              .having((e) => e, 'refusal', isA<DataRefusal>())
              .having(
                (e) => e.toString(),
                'toString',
                'SocketTicketRefused: HTTP $status',
              ),
        ),
      );
    });
  }

  for (final status in [408, 429, 500, 503]) {
    test('$status is a TransportStatusError with its headers', () async {
      final transport = FakeTransport(
        (request, body) => fakeResponse(status, headers: {'Retry-After': '9'}),
      );
      await expectLater(
        ticketGrantor(transport, endpoint)(socketUrl),
        throwsA(
          isA<TransportStatusError>()
              .having((e) => e.statusCode, 'statusCode', status)
              .having((e) => e.headers['retry-after'], 'retry-after', '9'),
        ),
      );
    });
  }

  for (final (type, body) in [
    ('text/html', '<html>captive portal tk</html>'),
    ('application/json', '{"ticket":""}'),
    ('application/json', '{"ticket":42}'),
    ('application/json', 'not json tk'),
    ('text/plain', '   '),
    (null, 'tk-secret'),
  ]) {
    test('$type "$body" is a FormatException that quotes nothing', () async {
      final transport = FakeTransport(
        (request, body0) =>
            fakeResponse(200, body: body, headers: {'content-type': ?type}),
      );
      await expectLater(
        ticketGrantor(transport, endpoint)(socketUrl),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'toString',
            allOf(isNot(contains('tk')), isNot(contains('example.com'))),
          ),
        ),
      );
    });
  }

  test('a redirect is not a ticket either', () async {
    final transport = FakeTransport(
      (request, body) => fakeResponse(302, headers: {'location': '/login'}),
    );
    await expectLater(
      ticketGrantor(transport, endpoint)(socketUrl),
      throwsA(isA<FormatException>()),
    );
  });

  group('in a SocketConnection', () {
    late FakeSocketConnector connector;
    late RecordingTelemetry sink;

    setUp(() {
      connector = FakeSocketConnector();
      sink = RecordingTelemetry();
      FespalierTelemetry.install(sink);
    });
    tearDown(() => FespalierTelemetry.install(null));

    test(
      'each connect asks a fresh ticket, and none reaches telemetry',
      () async {
        var n = 0;
        final transport = FakeTransport(
          (request, body) => fakeResponse(
            200,
            body: 'tk-secret-${++n}',
            headers: {'content-type': 'text/plain'},
          ),
        );
        final connection = SocketConnection(
          connector,
          socketUrl,
          grantor: ticketGrantor(transport, endpoint),
          name: 'chat',
        );
        final sub = connection.events.listen((_) {});
        await settle();
        expect(connector.current.url.queryParameters['ticket'], 'tk-secret-1');
        connector.current.closeFromPeer(1001);
        await settle();
        connection.reconnect();
        await settle();
        expect(transport.requests, hasLength(2));
        expect(connector.current.url.queryParameters['ticket'], 'tk-secret-2');
        expect(
          transport.requests.every((r) => r.abortable),
          isTrue,
          reason: "the attempt's abort trigger, through TransportZone",
        );
        await sub.cancel();
        final all = [...sink.log, '$connection'].join('\n');
        for (final secret in ['tk-secret', 'example.com', 'room', 'ticket']) {
          expect(all, isNot(contains(secret)));
        }
      },
    );

    test('a refused ticket ends the connection with the refusal', () async {
      final transport = FakeTransport((request, body) => fakeResponse(403));
      final connection = SocketConnection(
        connector,
        socketUrl,
        grantor: ticketGrantor(transport, endpoint),
      );
      final errors = <Object>[];
      final sub = connection.events.listen((_) {}, onError: errors.add);
      await settle();
      expect(connection.status, const LiveDone(LiveEnd.refused));
      expect(errors.single, isA<SocketTicketRefused>());
      expect(connector.connectCount, 0);
      await sub.cancel();
    });

    test(
      'a ticket request in flight is aborted when the connection closes',
      () async {
        final pending = Completer<TransportResponse>();
        final transport = FakeTransport((request, body) => pending.future);
        final connection = SocketConnection(
          connector,
          socketUrl,
          grantor: ticketGrantor(transport, endpoint),
        );
        final sub = connection.events.listen((_) {});
        await settle();
        await connection.close();
        await settle();
        expect(transport.abortCount, 1);
        expect(connector.connectCount, 0);
        await sub.cancel();
      },
    );
  });
}
