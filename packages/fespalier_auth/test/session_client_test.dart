// SessionClient and the Authorizer under it: which requests carry the session, what is sent again
// and how often, and what a failed refresh does to a request.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart' as http_retry;
import 'package:http/testing.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final orders = Uri.parse('https://api.example.com/orders');

/// What the API saw, and what it answers: 401 to every token but [good].
final class Api {
  final List<http.Request> seen = [];
  String good = 'fake-access-1';

  /// Extra headers on a response (a nonce).
  Map<String, String> extra = {};

  late final MockClient client = MockClient((request) async {
    seen.add(request);
    final token = request.headers['Authorization'];
    final ok = token != null && token.endsWith(good);
    return http.Response(ok ? 'orders' : 'no', ok ? 200 : 401, headers: extra);
  });

  List<String?> get tokens => [
    for (final r in seen) r.headers['Authorization'],
  ];
}

void main() {
  late FakeAuthBackend backend;
  late Api server;
  late ProviderContainer container;

  void setUpClient({
    AuthUser? signedInAs = ada,
    FakeAuthBackend? use,
    List<Uri>? origins,
    Duration? tokenLifetime,
  }) {
    backend = use ?? FakeAuthBackend();
    server = Api();
    container = containerFor(
      signedInAs: signedInAs,
      backend: backend,
      apiOrigins: origins ?? [api],
      client: server.client,
      tokenLifetime: tokenLifetime,
    );
  }

  http.Client client() => container.read(authHttpClient);

  group('which requests carry the session', () {
    test('a request to an API origin carries a bearer token', () async {
      setUpClient();
      server.good = 'fake-access-0';
      final response = await client().get(orders);
      expect(response.statusCode, 200);
      expect(server.tokens, ['Bearer fake-access-0']);
    });

    test(
      'no other origin gets a token: another host, scheme, port or subdomain',
      () async {
        setUpClient();
        for (final url in [
          'https://other.example.org/orders',
          'http://api.example.com/orders',
          'https://api.example.com:8443/orders',
          'https://v2.api.example.com/orders',
          'https://api.example.com.evil.test/orders',
        ]) {
          await client().get(Uri.parse(url));
        }
        expect(server.tokens, everyElement(isNull));
        expect(server.seen, hasLength(5));
        expect(backend.refreshes, 0);
      },
    );

    test('the default port and the host case do not matter', () async {
      setUpClient();
      server.good = 'fake-access-0';
      await client().get(Uri.parse('https://API.example.com:443/orders'));
      expect(server.tokens, ['Bearer fake-access-0']);
    });

    test('an origin with a port is matched with it', () async {
      setUpClient(origins: [Uri.parse('http://localhost:8080')]);
      server.good = 'fake-access-0';
      await client().get(Uri.parse('http://localhost:8080/orders'));
      await client().get(Uri.parse('http://localhost:9090/orders'));
      expect(server.tokens, ['Bearer fake-access-0', null]);
    });

    test(
      'signed out: the request goes with no header, and nothing is refreshed',
      () async {
        setUpClient(signedInAs: null);
        final response = await client().get(orders);
        expect(response.statusCode, 401);
        expect(server.tokens, [null]);
        expect(
          server.seen,
          hasLength(1),
          reason: 'no token to refresh, so nothing to send again',
        );
        expect(backend.refreshes, 0);
      },
    );

    test(
      'a header the caller set is replaced for the API, and left alone elsewhere',
      () async {
        setUpClient();
        server.good = 'fake-access-0';
        await client().get(orders, headers: {'authorization': 'Bearer mine'});
        await client().get(
          Uri.parse('https://other.example.org/x'),
          headers: {'authorization': 'Bearer mine'},
        );
        expect(server.tokens, ['Bearer fake-access-0', 'Bearer mine']);
      },
    );

    test('the AuthConfig with no apiOrigins says so, with the text of M8', () {
      setUpClient(origins: const []);
      Object? thrown;
      try {
        container.read(authorizer);
      } catch (error) {
        thrown = error;
      }
      expect(
        '$thrown',
        contains(
          'fespalier_auth: AuthConfig.apiOrigins is empty, so no request would carry the session; '
          "list your API's origins, e.g. apiOrigins: [Uri.parse('https://api.example.com')]",
        ),
      );
    });

    test(
      'authHttpClient is the same client after a refresh: nothing watching it reloads',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpClient(
            use: FakeAuthBackend(tokenLifetime: const Duration(minutes: 5)),
            tokenLifetime: const Duration(minutes: 5),
          );
          final before = client();
          var rebuilt = 0;
          container.listen(authHttpClient, (_, _) => rebuilt++);
          time.elapse(const Duration(minutes: 6));
          await before.get(orders);
          expect(backend.refreshes, 1);
          expect(identical(client(), before), isTrue);
          expect(rebuilt, 0);
        });
      },
    );
  });

  group('a refresh', () {
    test('an expired token is refreshed before the request is sent', () async {
      final time = TestTime();
      await time.run(() async {
        setUpClient(
          use: FakeAuthBackend(tokenLifetime: const Duration(minutes: 5)),
          tokenLifetime: const Duration(minutes: 5),
        );
        time.elapse(const Duration(minutes: 6));
        final response = await client().get(orders);
        expect(response.statusCode, 200);
        expect(server.tokens, [
          'Bearer fake-access-1',
        ], reason: 'one send: no 401 round trip');
        expect(backend.refreshes, 1);
      });
    });

    test('a 401 refreshes once and sends the request again', () async {
      setUpClient();
      final response = await client().get(orders);
      expect(response.statusCode, 200);
      expect(response.body, 'orders');
      expect(server.tokens, ['Bearer fake-access-0', 'Bearer fake-access-1']);
      expect(backend.refreshes, 1);
    });

    test('a body is sent again, with its headers', () async {
      setUpClient();
      final response = await client().post(
        orders,
        headers: {'content-type': 'application/json'},
        body: '{"item":1}',
      );
      expect(response.statusCode, 200);
      expect(server.seen, hasLength(2));
      for (final request in server.seen) {
        expect(request.body, '{"item":1}');
        expect(request.headers['content-type'], startsWith('application/json'));
        expect(request.method, 'POST');
      }
    });

    test('two requests that get a 401 together share one refresh', () async {
      setUpClient();
      backend.gate = Completer<void>();
      final a = client().get(orders);
      final b = client().get(Uri.parse('https://api.example.com/orders/1'));
      await pumpEventQueue();
      expect(backend.refreshes, 1);
      backend.gate!.complete();
      final responses = await Future.wait([a, b]);
      expect(responses.map((r) => r.statusCode), [200, 200]);
      expect(backend.refreshes, 1);
      expect(server.seen, hasLength(4));
    });

    test('a second 401 is returned as it is: no loop', () async {
      setUpClient();
      server.good = 'never';
      final response = await client().get(orders);
      expect(response.statusCode, 401);
      expect(server.seen, hasLength(2));
      expect(backend.refreshes, 1);
    });

    test(
      'a request that cannot be sent again gets its 401 after the refresh',
      () async {
        setUpClient();
        final request = http.MultipartRequest('POST', orders)
          ..fields['note'] = 'x';
        final response = await http.Response.fromStream(
          await client().send(request),
        );
        expect(response.statusCode, 401);
        expect(server.seen, hasLength(1));
        expect(backend.refreshes, 1, reason: 'so that its next attempt works');
        final next = await client().get(orders);
        expect(next.statusCode, 200);
      },
    );

    test('a streamed request is not sent again either', () async {
      setUpClient();
      final request = http.StreamedRequest('PUT', orders)..sink.add([1, 2, 3]);
      unawaited(request.sink.close());
      final response = await client().send(request);
      expect(response.statusCode, 401);
      expect(server.seen, hasLength(1));
    });

    test(
      'a 401 when the refresh is refused: the 401 is returned and the user is signed out',
      () async {
        setUpClient();
        backend.refreshError = const AuthRejected();
        final response = await client().get(orders);
        expect(response.statusCode, 401);
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
        expect(server.seen, hasLength(1));
      },
    );

    test(
      'a 401 when the refresh cannot run: AuthUnavailable, and the user stays signed in',
      () async {
        setUpClient();
        backend.refreshError = Exception('offline');
        await expectLater(
          client().get(orders),
          throwsA(isA<AuthUnavailable>()),
        );
        expect(container.read(authSession), isA<SignedIn>());
        // It is a ClientException, so code that catches package:http's errors catches it.
        await expectLater(
          client().get(orders),
          throwsA(isA<http.ClientException>()),
        );
      },
    );

    test(
      'an expired token that cannot be refreshed: AuthRejected / AuthUnavailable, no request is sent',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpClient(
            use: FakeAuthBackend(tokenLifetime: const Duration(minutes: 5)),
            tokenLifetime: const Duration(minutes: 5),
          );
          time.elapse(const Duration(minutes: 6));
          backend.refreshError = Exception('offline');
          await expectLater(
            client().get(orders),
            throwsA(isA<AuthUnavailable>()),
          );
          backend.refreshError = const AuthRejected();
          await expectLater(client().get(orders), throwsA(isA<AuthRejected>()));
          expect(server.seen, isEmpty);
          expect(
            container.read(authSession),
            const SignedOut(reason: SignOutReason.expired),
          );
        });
      },
    );
  });

  group('DPoP', () {
    test(
      'a bound token goes with the DPoP scheme and a proof for the request',
      () async {
        final proof = FakeProof();
        setUpClient(use: FakeAuthBackend(proof: proof));
        server.good = 'fake-access-0';
        final response = await client().get(
          Uri.parse('https://api.example.com/orders?page=2#top'),
        );
        expect(response.statusCode, 200);
        final sent = server.seen.single;
        expect(sent.headers['Authorization'], 'DPoP fake-access-0');
        expect(
          sent.headers['DPoP'],
          'fake-proof-1 GET https://api.example.com/orders ath',
        );
        expect(proof.proofs, hasLength(1));
      },
    );

    test('a nonce challenge is answered once, with no refresh', () async {
      final proof = FakeProof()..challengeNext = true;
      setUpClient(use: FakeAuthBackend(proof: proof));
      server.good = 'fake-access-0';
      final response = await client().get(orders);
      expect(response.statusCode, 200);
      expect(server.seen, hasLength(2));
      expect(
        server.seen.first.headers['DPoP'],
        'fake-proof-1 GET https://api.example.com/orders ath',
      );
      expect(
        server.seen.last.headers['DPoP'],
        'fake-proof-2 GET https://api.example.com/orders ath nonce=nonce-1',
      );
      expect(backend.refreshes, 0);
    });

    test(
      'a request is sent at most three times: a challenge, a refresh, then it stands',
      () async {
        final proof = FakeProof()..challengeNext = true;
        setUpClient(use: FakeAuthBackend(proof: proof));
        server.good = 'never';
        final response = await client().get(orders);
        expect(response.statusCode, 401);
        expect(server.seen, hasLength(3));
        expect(backend.refreshes, 1);
        // Each send has a proof of its own, and the refreshed token's carries its own hash.
        expect(proof.proofs, hasLength(3));
        expect(server.seen.last.headers['Authorization'], 'DPoP fake-access-1');
      },
    );

    test(
      'a nonce sent on a success is remembered for the next request',
      () async {
        final proof = FakeProof();
        setUpClient(use: FakeAuthBackend(proof: proof));
        server.good = 'fake-access-0';
        server.extra = {'dpop-nonce': 'abc'};
        await client().get(orders);
        await client().get(orders);
        expect(server.seen.last.headers['DPoP'], endsWith('nonce=abc'));
      },
    );

    test('a DPoP token and a backend with no proof is the error of M3', () async {
      final noProof = FakeAuthBackend();
      server = Api();
      backend = noProof;
      container = ProviderContainer(
        overrides: fakeAuth(
          backend: noProof,
          apiOrigins: [api],
          client: server.client,
        ),
      );
      addTearDown(container.dispose);
      await container
          .read(authSession.notifier)
          .adopt(fakeSession(ada, binding: 'thumb'));
      await expectLater(
        client().get(orders),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'fespalier_auth: the access token is DPoP-bound (token_type DPoP), but the backend has '
                'no proof of possession: pass proof: DpopProof.device() '
                '(package:fespalier_sign_keypair) to the backend',
          ),
        ),
      );
      expect(server.seen, isEmpty);
    });

    test(
      'a bearer token on a backend with a proof gets no DPoP header',
      () async {
        // Keycloak's refresh-token-only binding: the access token is a plain bearer token.
        final proof = FakeProof();
        setUpClient(use: FakeAuthBackend(proof: proof));
        await container.read(authSession.notifier).adopt(fakeSession(ada));
        server.good = 'fake-access-0';
        await client().get(orders);
        expect(
          server.seen.single.headers['Authorization'],
          'Bearer fake-access-0',
        );
        expect(server.seen.single.headers.containsKey('DPoP'), isFalse);
        expect(proof.proofs, isEmpty);
      },
    );
  });

  group('a replay', () {
    test(
      'is marked: the first send is not, the replay after a 401 is',
      () async {
        final seen = <http.BaseRequest>[];
        setUpClient();
        final marked = SessionClient(
          container.read(authorizer),
          inner: _Spy(server.client, seen),
        );
        await marked.get(orders);
        expect(seen, hasLength(2));
        expect(isAuthReplay(seen[0]), isFalse);
        expect(isAuthReplay(seen[1]), isTrue);
        expect(isAuthReplay(http.Request('GET', orders)), isFalse);
      },
    );

    test('a DPoP nonce challenge is a replay too', () async {
      final seen = <http.BaseRequest>[];
      final proof = FakeProof()..challengeNext = true;
      setUpClient(use: FakeAuthBackend(proof: proof));
      server.good = 'fake-access-0';
      final marked = SessionClient(
        container.read(authorizer),
        inner: _Spy(server.client, seen),
      );
      await marked.get(orders);
      expect(seen.map(isAuthReplay), [false, true]);
    });

    test(
      'keeps the abort trigger: a replay can still be cancelled when its page goes away',
      () async {
        setUpClient();
        final abort = Completer<void>();
        final inner = _AbortAware(server.client);
        final client = SessionClient(container.read(authorizer), inner: inner);
        final request = http.AbortableRequest(
          'GET',
          orders,
          abortTrigger: abort.future,
        );
        final pending = client.send(request);
        final outcome = expectLater(
          pending,
          throwsA(isA<http.RequestAbortedException>()),
        );
        // The first send was answered 401 and the refresh ran: the replay is out, and held.
        await inner.replayStarted.future;
        expect(backend.refreshes, 1);
        final replay = inner.sent.last;
        expect(replay, isA<http.Abortable>());
        expect((replay as http.Abortable).abortTrigger, same(abort.future));
        expect(isAuthReplay(replay), isTrue);
        expect(
          replay,
          isNot(same(request)),
          reason: 'a copy: the original was finalized by the first send',
        );
        abort.complete();
        await outcome;
        expect(inner.aborted, isTrue, reason: 'the replay saw the trigger');
      },
    );

    test(
      'an abort before the replay is sent aborts the replay at once',
      () async {
        setUpClient();
        final abort = Completer<void>();
        final inner = _AbortAware(server.client, abortDuringFirst: abort);
        final client = SessionClient(container.read(authorizer), inner: inner);
        final request = http.AbortableRequest(
          'GET',
          orders,
          abortTrigger: abort.future,
        );
        await expectLater(
          client.send(request),
          throwsA(isA<http.RequestAbortedException>()),
        );
      },
    );

    test('a request that was not abortable stays a plain request', () async {
      final seen = <http.BaseRequest>[];
      setUpClient();
      final client = SessionClient(
        container.read(authorizer),
        inner: _Spy(server.client, seen),
      );
      await client.get(orders);
      expect(seen, everyElement(isNot(isA<http.Abortable>())));
    });
  });

  group('package:http\'s RetryClient and DPoP', () {
    // A retry under SessionClient re-sends the proof it was given: the same jti, which a server
    // refuses (Keycloak: "DPoP proof has already been used"). A retry over it asks for a new proof.
    test('under the SessionClient the retry re-sends the same proof', () async {
      var calls = 0;
      final seen = <http.Request>[];
      final flaky = MockClient((request) async {
        seen.add(request);
        return http.Response('', ++calls == 1 ? 503 : 200);
      });
      final proof = FakeProof();
      setUpClient(use: FakeAuthBackend(proof: proof));
      final retrying = http_retry.RetryClient(
        flaky,
        when: (r) => r.statusCode == 503,
        delay: (_) => Duration.zero,
      );
      final client = SessionClient(container.read(authorizer), inner: retrying);
      await client.get(orders);
      expect(seen, hasLength(2));
      expect(
        seen[0].headers['DPoP'],
        seen[1].headers['DPoP'],
        reason: 'the same proof twice',
      );
      expect(proof.proofs, hasLength(1));
    });

    test(
      'over the SessionClient every attempt has a proof of its own',
      () async {
        var calls = 0;
        final seen = <http.Request>[];
        final flaky = MockClient((request) async {
          seen.add(request);
          return http.Response('', ++calls == 1 ? 503 : 200);
        });
        final proof = FakeProof();
        setUpClient(use: FakeAuthBackend(proof: proof));
        final session = SessionClient(container.read(authorizer), inner: flaky);
        final retrying = http_retry.RetryClient(
          session,
          when: (r) => r.statusCode == 503,
          delay: (_) => Duration.zero,
        );
        await retrying.get(orders);
        expect(seen, hasLength(2));
        expect(seen[0].headers['DPoP'], isNot(seen[1].headers['DPoP']));
        expect(proof.proofs, hasLength(2));
      },
    );
  });
}

/// A client that records what was sent through it, then delegates.
final class _Spy extends http.BaseClient {
  _Spy(this.inner, this.seen);

  final http.Client inner;
  final List<http.BaseRequest> seen;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seen.add(request);
    return inner.send(request);
  }
}

/// A client that honours `Abortable`: its second request is held until the abort trigger fires,
/// and then fails with `RequestAbortedException`, as the real clients do.
final class _AbortAware extends http.BaseClient {
  _AbortAware(this.inner, {this.abortDuringFirst});

  final http.Client inner;

  /// Completed while the first request is being answered: the abort comes before the replay.
  final Completer<void>? abortDuringFirst;

  final List<http.BaseRequest> sent = [];
  final Completer<void> replayStarted = Completer<void>();
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    final Object asObject = request;
    final trigger = asObject is http.Abortable ? asObject.abortTrigger : null;
    if (sent.length == 1) {
      final response = await inner.send(request);
      abortDuringFirst?.complete();
      return response;
    }
    if (!replayStarted.isCompleted) replayStarted.complete();
    if (trigger == null) return inner.send(request);
    final held = Completer<http.StreamedResponse>();
    unawaited(
      trigger.then((_) {
        aborted = true;
        if (!held.isCompleted) {
          held.completeError(http.RequestAbortedException(request.url));
        }
      }),
    );
    return held.future;
  }
}
