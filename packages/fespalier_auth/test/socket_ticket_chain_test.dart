// A WebSocket's ticket through the real session (since 0.25.0): fespalier_stream's ticketGrantor
// over SessionTransport over WriteGuardTransport, the chain an app builds. The ticket POST carries
// the session, a 401 renews and is sent again (the server did not process it), every connect asks a
// fresh ticket, a renewal the server refuses ends the socket with a refusal, and the ticket reaches
// no toString. fespalier_stream is a dev dependency of this package only (no cycle).
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final ticketEndpoint = Uri.parse('https://api.example.com/ws-ticket');
final chat = Uri.parse('wss://api.example.com/chat');

const credentialHeader = 'x-fake-credential';

/// The ticket endpoint: a 401 to every credential but [good], else a new ticket.
final class TicketDesk implements HttpTransport {
  String good = 'fake-1';
  final List<String?> credentials = [];
  final List<TransportRequest> requests = [];
  int minted = 0;

  @override
  Future<TransportResponse> send(TransportRequest request) {
    requests.add(request);
    final credential = request.headers[credentialHeader];
    credentials.add(credential);
    if (credential == null || !credential.startsWith('$good#')) {
      return Future.value(fakeResponse(401, body: 'no'));
    }
    return Future.value(
      fakeResponse(
        200,
        body: jsonEncode({'ticket': 'tk-secret-${++minted}'}),
        headers: {'content-type': 'application/json'},
      ),
    );
  }
}

void main() {
  late FakeAuthBackend backend;
  late TicketDesk desk;
  late HttpTransport chain;
  late FakeSocketConnector connector;

  setUp(() {
    backend = FakeAuthBackend(user: ada);
    desk = TicketDesk();
    connector = FakeSocketConnector();
    final container = containerFor(
      signedInAs: ada,
      backend: backend,
      apiOrigins: [api],
      transport: desk,
    );
    chain = SessionTransport(
      WriteGuardTransport(desk),
      container.read(authorizer),
    );
  });

  SocketConnection connection() => SocketConnection(
    connector,
    chat,
    grantor: ticketGrantor(chain, ticketEndpoint),
    name: 'chat',
  );

  test('a 401 renews the session and the ticket POST is sent again', () async {
    final socket = connection();
    final sub = socket.events.listen((_) {});
    await pumpEventQueue();
    expect(backend.renewals, 1);
    expect(desk.credentials, hasLength(2));
    expect(desk.credentials.last, startsWith('fake-1#'));
    expect(desk.requests.every((r) => r.method == 'POST'), isTrue);
    expect(desk.requests.last.attributes[transportReplayKey], isTrue);
    expect(socket.status, const LiveOpen());
    expect(connector.current.url.queryParameters['ticket'], 'tk-secret-1');
    expect(
      connector.current.headers,
      isEmpty,
      reason: 'the credential goes to the ticket POST, never the handshake',
    );
    await sub.cancel();
  });

  test('every connect is a new ticket, from a new logical request', () async {
    desk.good = 'fake-0';
    final socket = connection();
    final sub = socket.events.listen((_) {});
    await pumpEventQueue();
    connector.current.closeFromPeer(1001);
    await pumpEventQueue();
    expect(socket.reconnect(), isTrue);
    await pumpEventQueue();
    expect(connector.sockets, hasLength(2));
    expect(connector.current.url.queryParameters['ticket'], 'tk-secret-2');
    expect(
      identical(desk.requests.first.memo, desk.requests.last.memo),
      isFalse,
    );
    await sub.cancel();
  });

  test('a renewal the server refuses ends the socket with a refusal', () async {
    backend.renewError = const AuthRejected();
    final socket = connection();
    final errors = <Object>[];
    final sub = socket.events.listen((_) {}, onError: errors.add);
    await pumpEventQueue();
    expect(socket.status, const LiveDone(LiveEnd.refused));
    expect(errors.single, isA<DataRefusal>());
    expect(connector.connectCount, 0);
    expect('${errors.single}', isNot(contains('tk-secret')));
    await sub.cancel();
  });

  test('the write guard marks the ticket POST as a write', () async {
    final socket = connection();
    final sub = socket.events.listen((_) {});
    await pumpEventQueue();
    expect(WriteGuardTransport.isWrite(desk.requests.last), isTrue);
    expect('$socket', isNot(contains('tk-secret')));
    await sub.cancel();
  });
}
