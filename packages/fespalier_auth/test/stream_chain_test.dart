// An event stream through the real session (since 0.25.0): fespalier_stream's ServerEvents over
// SessionTransport over WriteGuardTransport, the chain an app builds. The stream's GET carries the
// session, a 401 renews and is sent again, a reconnect is a new logical request (what the session
// settled for the last one does not stand for it), and a renewal the server refuses ends the stream
// with a refusal. fespalier_stream is a dev dependency of this package only: it depends on
// fespalier and fespalier_transport, never on fespalier_auth, so there is no cycle.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_stream/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final live = Uri.parse('https://api.example.com/orders/live');

const credentialHeader = 'x-fake-credential';

/// The API: a 401 to every credential but [good], else the event stream of [streams].
final class Gate implements HttpTransport {
  Gate(this.streams);

  final FakeEventServer streams;
  String good = 'fake-1';
  final List<String?> credentials = [];

  @override
  Future<TransportResponse> send(TransportRequest request) {
    final credential = request.headers[credentialHeader];
    credentials.add(credential);
    if (credential == null || !credential.startsWith('$good#')) {
      return Future.value(fakeResponse(401, body: 'no'));
    }
    return streams.send(request);
  }
}

void main() {
  late FakeAuthBackend backend;
  late FakeEventServer streams;
  late Gate gate;
  late HttpTransport chain;
  late ProviderContainer container;

  setUp(() {
    backend = FakeAuthBackend(user: ada);
    streams = FakeEventServer();
    gate = Gate(streams);
    container = containerFor(
      signedInAs: ada,
      backend: backend,
      apiOrigins: [api],
      transport: gate,
    );
    chain = SessionTransport(
      WriteGuardTransport(gate),
      container.read(authorizer),
    );
  });

  test('a 401 renews the session and the stream opens on the resend', () async {
    final events = ServerEvents(chain, live);
    final seen = <String>[];
    final sub = events.events.listen((e) => seen.add(e.data));
    await pumpEventQueue();
    expect(backend.renewals, 1);
    expect(gate.credentials, hasLength(2));
    expect(gate.credentials.last, startsWith('fake-1#'));
    expect(events.status, const LiveOpen());
    streams.current.event('a', id: '1');
    await pumpEventQueue();
    expect(seen, ['a']);
    expect(streams.current.header('Accept'), 'text/event-stream');
    await sub.cancel();
    await pumpEventQueue();
    expect(streams.current.aborted, isTrue);
  });

  test(
    'a reconnect is a new request, authorized afresh, with the last event ID',
    () async {
      gate.good = 'fake-0';
      final events = ServerEvents(chain, live);
      final sub = events.events.listen((_) {});
      await pumpEventQueue();
      streams.current
        ..event('a', id: '7')
        ..drop();
      await pumpEventQueue();
      expect(events.status, isA<LiveWaiting>());
      // The credential the server takes changed meanwhile: the reconnect renews once and opens.
      gate.good = 'fake-1';
      expect(events.reconnect(), isTrue);
      await pumpEventQueue();
      expect(backend.renewals, 1);
      expect(events.status, const LiveOpen(resumed: true));
      expect(streams.current.lastEventId, '7');
      expect(streams.requests, hasLength(2));
      expect(
        identical(streams.requests[0].memo, streams.requests[1].memo),
        isFalse,
      );
      await sub.cancel();
    },
  );

  test('a renewal the server refuses ends the stream with a refusal', () async {
    backend.renewError = const AuthRejected();
    final events = ServerEvents(chain, live);
    final errors = <Object>[];
    final sub = events.events.listen((_) {}, onError: errors.add);
    await pumpEventQueue();
    expect(events.status, const LiveDone(LiveEnd.refused));
    expect(errors.single, isA<ServerEventsRefused>());
    expect(errors.single, isA<DataRefusal>());
    expect(streams.connections, isEmpty);
    await sub.cancel();
  });

  test('the write guard lets the stream GET through, and its resend', () async {
    final events = ServerEvents(chain, live);
    final sub = events.events.listen((_) {});
    await pumpEventQueue();
    expect(events.status, const LiveOpen());
    expect(streams.requests.single.attributes[transportReplayKey], isTrue);
    await sub.cancel();
  });
}
