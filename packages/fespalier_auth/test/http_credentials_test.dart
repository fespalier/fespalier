// The Authorizer used as the fespalier_http HttpCredentials it implements (since 0.15.0): a
// transfer that is not an http.Client drives a refresh and a proof's nonce retry through the
// interface alone.
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final orders = Uri.parse('https://api.example.com/orders');

/// What a transfer of your own does with an [HttpCredentials]: ask before each send, ask after
/// each response, at most three sends.
Future<http.Response> transfer(
  HttpCredentials credentials,
  http.Client client,
  Uri url,
) async {
  HttpAuthorization? previous;
  for (var send = 1; ; send++) {
    final attempt = await credentials.authorize('GET', url, previous: previous);
    final response = await client.get(url, headers: attempt.headers);
    if (send == 3 ||
        !await credentials.retry(
          attempt,
          statusCode: response.statusCode,
          headers: response.headers,
        )) {
      return response;
    }
    previous = attempt;
  }
}

void main() {
  late FakeHttpClient server;
  late String good;

  FakeHttpClient serverThatAccepts() => FakeHttpClient((request, _) {
    final token = request.headers['Authorization'];
    final ok = token != null && token.endsWith(good);
    return http.Response(ok ? 'orders' : 'no', ok ? 200 : 401);
  });

  ProviderContainer containerWith({FakeAuthBackend? backend}) =>
      containerFor(signedInAs: ada, backend: backend, apiOrigins: [api]);

  setUp(() {
    good = 'fake-access-0';
    server = serverThatAccepts();
  });

  test(
    'an Authorizer is an HttpCredentials, and its attempt an HttpAuthorization',
    () async {
      final container = containerWith();
      final HttpCredentials credentials = container.read(authorizer);
      expect(credentials.covers(orders), isTrue);
      expect(
        credentials.covers(Uri.parse('https://other.example.org/x')),
        isFalse,
      );
      final HttpAuthorization attempt = await credentials.authorize(
        'GET',
        orders,
      );
      expect(attempt, isA<AuthAttempt>());
      expect(attempt.method, 'GET');
      expect(attempt.uri, orders);
      expect(attempt.headers, {'Authorization': 'Bearer fake-access-0'});
      expect(attempt.isReplay, isFalse);
    },
  );

  test(
    'a 401 drives one shared refresh and a second send with the new token',
    () async {
      final backend = FakeAuthBackend();
      final container = containerWith(backend: backend);
      good = 'fake-access-1';
      final response = await transfer(
        container.read(authorizer),
        server,
        orders,
      );
      expect(response.statusCode, 200);
      expect(backend.refreshes, 1);
      expect(server.requests.map((r) => r.headers['Authorization']), [
        'Bearer fake-access-0',
        'Bearer fake-access-1',
      ]);
    },
  );

  test('a proof nonce challenge is answered once, with no refresh', () async {
    final proof = FakeProof()..challengeNext = true;
    final backend = FakeAuthBackend(proof: proof);
    final container = containerWith(backend: backend);
    final response = await transfer(container.read(authorizer), server, orders);
    expect(response.statusCode, 200);
    expect(backend.refreshes, 0);
    expect(server.requests, hasLength(2));
    expect(
      server.requests.first.headers['DPoP'],
      'fake-proof-1 GET https://api.example.com/orders ath',
    );
    expect(
      server.requests.last.headers['DPoP'],
      'fake-proof-2 GET https://api.example.com/orders ath nonce=nonce-1',
    );
  });

  test(
    'a send after a challenge is a replay, and a request is sent at most three times',
    () async {
      final proof = FakeProof()..challengeNext = true;
      final backend = FakeAuthBackend(proof: proof);
      final container = containerWith(backend: backend);
      final credentials = container.read(authorizer);
      good = 'never';
      final first = await credentials.authorize('GET', orders);
      expect(
        await credentials.retry(first, statusCode: 401, headers: const {}),
        isTrue,
      );
      final second = await credentials.authorize(
        'GET',
        orders,
        previous: first,
      );
      expect(second.isReplay, isTrue);
      final response = await transfer(credentials, serverThatAccepts(), orders);
      expect(response.statusCode, 401);
    },
  );

  test('an attempt the Authorizer did not make is an ArgumentError', () async {
    final container = containerWith();
    final HttpCredentials credentials = container.read(authorizer);
    final foreign = await FakeHttpCredentials(
      origins: [api],
    ).authorize('GET', orders);
    expect(
      credentials.authorize('GET', orders, previous: foreign),
      throwsArgumentError,
    );
  });
}
