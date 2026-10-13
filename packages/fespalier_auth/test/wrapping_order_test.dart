// The wrapping order docs/http.md documents, proved with the real layers:
//
//   ref.abortable(SessionClient(authorizer, inner: RetryClient(WriteGuardClient(client), ...)))
//
// and, for a DPoP proof of its own on every attempt, the retrier outside the session:
//
//   ref.abortable(RetryClient(WriteGuardClient(SessionClient(authorizer, inner: client)), ...))
//
// `RetryClient` sends a copy of every request as a `StreamedRequest`, and `SessionClient` sends a
// request again after a 401 only when it is a plain `Request`. That one fact is why the first
// order is the default: under a retrier that sits outside the session, a 401 is refreshed but
// not replayed.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart' as http_retry;

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final orders = Uri.parse('https://api.example.com/orders');

void main() {
  late ProviderContainer container;
  late FakeHttpClient server;
  late FakeAuthBackend backend;
  late Provider<http.Client> composed;

  http_retry.RetryClient retrier(http.Client inner) => http_retry.RetryClient(
    WriteGuardClient(inner),
    when: WriteGuardClient.readsOnly(),
    whenError: WriteGuardClient.readErrorsOnly((e, s) => false),
    delay: (_) => Duration.zero,
  );

  /// The default order: the session outside the retrier. [answer] gets the number of the request
  /// (1-based) and the request.
  void serve(
    FutureOr<http.Response> Function(int n, http.BaseRequest request) answer, {
    bool retrierOutside = false,
    FakeAuthBackend? use,
  }) {
    var n = 0;
    server = FakeHttpClient((request, body) => answer(++n, request));
    backend = use ?? FakeAuthBackend();
    container = containerFor(
      signedInAs: ada,
      apiOrigins: [api],
      backend: backend,
    );
    composed = Provider<http.Client>((ref) {
      final authorizerOf = ref.watch(authorizer);
      return ref.abortable(
        retrierOutside
            ? retrier(SessionClient(authorizerOf, inner: server))
            : SessionClient(authorizerOf, inner: retrier(server)),
      );
    });
  }

  http.Client client() => container.read(composed);

  group('the session outside the retrier', () {
    test('a read is retried on a 503 and carries the session', () async {
      serve((n, _) => http.Response('x', n == 1 ? 503 : 200));
      final response = await client().get(orders);
      expect(response.statusCode, 200);
      expect(server.requests, hasLength(2));
      for (final sent in server.requests) {
        expect(sent.headers['Authorization'], startsWith('Bearer '));
      }
    });

    test('a write is not retried on a 503', () async {
      serve((_, _) => http.Response('x', 503));
      final response = await client().post(orders, body: 'a');
      expect(response.statusCode, 503);
      expect(server.requests, hasLength(1));
    });

    test('a write with an Idempotency-Key is retried', () async {
      serve((n, _) => http.Response('x', n == 1 ? 503 : 200));
      final response = await client().post(
        orders,
        headers: {'Idempotency-Key': 'k1'},
        body: 'a',
      );
      expect(response.statusCode, 200);
      expect(server.requests, hasLength(2));
    });

    test('a read refused with a 401 is refreshed and sent again', () async {
      serve((n, _) => http.Response('x', n == 1 ? 401 : 200));
      final response = await client().get(orders);
      expect(response.statusCode, 200);
      expect(backend.refreshes, 1);
      expect(server.requests, hasLength(2));
      expect(
        server.requests[0].headers['Authorization'],
        isNot(server.requests[1].headers['Authorization']),
        reason: 'the replay carries the refreshed token',
      );
    });

    test('a write refused with a 401 is replayed once, and a 503 after it '
        'is not retried', () async {
      serve((n, _) => http.Response('x', n == 1 ? 401 : 503));
      final response = await client().post(orders, body: 'a');
      expect(response.statusCode, 503);
      expect(server.requests, hasLength(2), reason: 'one replay, no retry');
    });

    test('the abort reaches the retry that follows a 503', () async {
      final gate = Completer<http.Response>();
      serve((n, _) => n == 1 ? http.Response('x', 503) : gate.future);
      final pending = client().get(orders);
      final done = expectLater(
        pending,
        throwsA(isA<http.RequestAbortedException>()),
      );
      while (server.requests.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      container.refresh(composed);
      await done;
      expect(
        server.requests.every((r) => r.abortable),
        isTrue,
        reason: 'every send carries the trigger',
      );
    });

    test('the abort reaches the replay that follows a 401', () async {
      final gate = Completer<http.Response>();
      serve((n, _) => n == 1 ? http.Response('x', 401) : gate.future);
      final pending = client().get(orders);
      final done = expectLater(
        pending,
        throwsA(isA<http.RequestAbortedException>()),
      );
      while (server.requests.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      container.refresh(composed);
      await done;
      expect(server.requests.every((r) => r.abortable), isTrue);
    });

    test('a retry re-sends the proof it was given', () async {
      final proof = FakeProof();
      serve(
        (n, _) => http.Response('x', n == 1 ? 503 : 200),
        use: FakeAuthBackend(proof: proof),
      );
      await client().get(orders);
      expect(server.requests, hasLength(2));
      expect(proof.proofs, hasLength(1), reason: 'one proof, sent twice');
    });
  });

  group('the retrier outside the session, for a proof on every attempt', () {
    test('every attempt has a proof of its own', () async {
      final proof = FakeProof();
      serve(
        (n, _) => http.Response('x', n == 1 ? 503 : 200),
        retrierOutside: true,
        use: FakeAuthBackend(proof: proof),
      );
      await client().get(orders);
      expect(server.requests, hasLength(2));
      expect(proof.proofs, hasLength(2));
    });

    test('a 401 is refreshed but not sent again: the retrier hands the '
        'session a streamed copy', () async {
      serve(
        (n, _) => http.Response('x', n == 1 ? 401 : 200),
        retrierOutside: true,
      );
      final response = await client().get(orders);
      expect(response.statusCode, 401);
      expect(server.requests, hasLength(1));
      expect(backend.refreshes, 1, reason: 'so that the next request works');
      expect((await client().get(orders)).statusCode, 200);
    });
  });
}
