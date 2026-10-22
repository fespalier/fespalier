// The two orders a WriteGuardTransport and a SessionTransport can be stacked in:
//
//   SessionTransport(WriteGuardTransport(inner), authorizer)
//   WriteGuardTransport(SessionTransport(inner, authorizer))
//
// A write that gets a 401 is replayed once by the session in both, marked as a replay, and never
// sent a third time; the guard still tells a write's response from a read's.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final orders = Uri.parse('https://api.example.com/orders');

typedef Stack = HttpTransport Function(HttpTransport inner, Authorizer a);

HttpTransport sessionOutside(HttpTransport inner, Authorizer a) =>
    SessionTransport(WriteGuardTransport(inner), a);

HttpTransport guardOutside(HttpTransport inner, Authorizer a) =>
    WriteGuardTransport(SessionTransport(inner, a));

TransportRequest request(String method) => TransportRequest(
  method: method,
  uri: orders,
  headers: const {'content-type': 'application/json'},
);

void main() {
  late ProviderContainer container;
  late FakeAuthBackend backend;

  /// Serves 401 to every credential but [good], and [status] to the good one.
  FakeTransport serve({String good = 'fake-1', int status = 200}) =>
      FakeTransport((request, _) {
        final header = request.headers['x-fake-credential'];
        final ok = header != null && header.startsWith('$good#');
        return fakeResponse(ok ? status : 401);
      });

  void signedIn() {
    backend = FakeAuthBackend(user: ada);
    container = containerFor(
      signedInAs: ada,
      backend: backend,
      apiOrigins: [api],
    );
  }

  final stacks = <String, Stack>{
    'the session outside the guard': sessionOutside,
    'the guard outside the session': guardOutside,
  };

  for (final MapEntry(key: name, value: stack) in stacks.entries) {
    group(name, () {
      setUp(signedIn);

      test(
        'a write that gets a 401 is replayed once, marked as a replay',
        () async {
          final inner = serve();
          final transport = stack(inner, container.read(authorizer));
          final response = await transport.send(request('POST'));
          expect(response.statusCode, 200);
          expect(inner.requests, hasLength(2));
          expect(
            inner.requests[0].request.attributes[transportReplayKey],
            isNull,
          );
          expect(
            inner.requests[1].request.attributes[transportReplayKey],
            isTrue,
          );
          expect(backend.renewals, 1);
          expect(WriteGuardTransport.isWriteResponse(response), isTrue);
        },
      );

      test('a write is never sent a third time', () async {
        final inner = serve(good: 'never');
        final transport = stack(inner, container.read(authorizer));
        final response = await transport.send(request('POST'));
        expect(response.statusCode, 401);
        expect(inner.requests, hasLength(2));
        expect(backend.renewals, 1);
        expect(WriteGuardTransport.isWriteResponse(response), isTrue);
      });

      test(
        'a read that gets a 401 is replayed once too, and is not a write',
        () async {
          final inner = serve();
          final transport = stack(inner, container.read(authorizer));
          final response = await transport.send(request('GET'));
          expect(response.statusCode, 200);
          expect(inner.requests, hasLength(2));
          expect(WriteGuardTransport.isWriteResponse(response), isFalse);
        },
      );

      test(
        'a 503 is marked as a write\'s or a read\'s, and is not replayed',
        () async {
          final inner = FakeTransport((_, _) => fakeResponse(503));
          final transport = stack(inner, container.read(authorizer));
          final write = await transport.send(request('POST'));
          final read = await transport.send(request('GET'));
          expect(WriteGuardTransport.isWriteResponse(write), isTrue);
          expect(WriteGuardTransport.isWriteResponse(read), isFalse);
          expect(
            inner.requests,
            hasLength(2),
            reason: 'the session replays 401s, not 503s',
          );
          expect(backend.renewals, 0);
        },
      );

      test('a write whose send fails is marked as a write\'s error', () async {
        final inner = FakeTransport.script([const TransportBroken()]);
        final transport = stack(inner, container.read(authorizer));
        Object? thrown;
        try {
          await transport.send(request('POST'));
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<TransportBroken>());
        expect(WriteGuardTransport.isWriteError(thrown!), isTrue);
      });
    });
  }
}
