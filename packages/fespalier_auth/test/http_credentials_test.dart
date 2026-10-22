// The Authorizer used as the HttpCredentials it implements: a transfer that is not a transport
// drives a renewal and a resend through the interface alone.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final api = Uri.parse('https://api.example.com');
final orders = Uri.parse('https://api.example.com/orders');

TransportRequest get(Uri uri, {Map<String, String>? headers}) =>
    TransportRequest(
      method: 'GET',
      uri: uri,
      headers: headers ?? const <String, String>{},
    );

/// A response whose body is already read: what a transport layer hands `retry` for a 401.
TransportResponse buffered(int status, [String body = '']) =>
    TransportResponse.fromBytes(
      statusCode: status,
      headers: const <String, String>{},
      bytes: Uint8List.fromList(utf8.encode(body)),
    );

void main() {
  late FakeAuthBackend backend;
  late ProviderContainer container;
  late Authorizer credentials;

  void setUpAuthorizer({
    AuthUser? signedInAs = ada,
    FakeAuthBackend? use,
    List<Uri>? origins,
    Duration? credentialLifetime,
  }) {
    backend =
        use ??
        FakeAuthBackend(user: ada, credentialLifetime: credentialLifetime);
    container = containerFor(
      signedInAs: signedInAs,
      backend: backend,
      apiOrigins: origins ?? [api],
      credentialLifetime: credentialLifetime,
    );
    if (origins == null || origins.isNotEmpty) {
      credentials = container.read(authorizer);
    }
  }

  FakeAuthenticator authenticator() => backend.authenticator;

  group('covers', () {
    setUp(setUpAuthorizer);

    test(
      'an Authorizer is an HttpCredentials, and its attempt an HttpAuthorization',
      () async {
        final HttpCredentials asInterface = credentials;
        expect(asInterface.covers(orders), isTrue);
        final HttpAuthorization attempt = await asInterface.authorize(
          get(orders),
        );
        expect(attempt, isA<AuthAttempt>());
      },
    );

    test(
      'only the API origin: not another host, scheme, port or subdomain',
      () {
        for (final url in [
          'https://other.example.org/orders',
          'http://api.example.com/orders',
          'https://api.example.com:8443/orders',
          'https://v2.api.example.com/orders',
          'https://api.example.com.evil.test/orders',
        ]) {
          expect(credentials.covers(Uri.parse(url)), isFalse, reason: url);
        }
        expect(credentials.covers(orders), isTrue);
      },
    );

    test('the default port and the host case do not matter', () {
      expect(
        credentials.covers(Uri.parse('https://API.example.com:443/orders')),
        isTrue,
      );
    });

    test('a relative URL has no host: not covered', () {
      expect(credentials.covers(Uri.parse('/orders')), isFalse);
    });

    test('an origin with a port is matched with it', () {
      setUpAuthorizer(origins: [Uri.parse('http://localhost:8080')]);
      expect(credentials.covers(Uri.parse('http://localhost:8080/x')), isTrue);
      expect(credentials.covers(Uri.parse('http://localhost:9090/x')), isFalse);
    });

    test('several origins are each covered', () {
      setUpAuthorizer(origins: [api, Uri.parse('https://files.example.com')]);
      expect(
        credentials.covers(Uri.parse('https://files.example.com/a')),
        isTrue,
      );
      expect(credentials.covers(orders), isTrue);
    });
  });

  group('authorize', () {
    test(
      'adds what the authenticator adds, for the exact request it was given',
      () async {
        setUpAuthorizer();
        final body = Uint8List.fromList(utf8.encode('{"item":1}'));
        final request = TransportRequest(
          method: 'POST',
          uri: orders,
          headers: const {'content-type': 'application/json'},
          body: body,
        );
        final attempt = await credentials.authorize(request);
        expect(attempt.headers, {'x-fake-credential': 'fake-0#1'});
        expect(attempt.request, same(request));
        expect(authenticator().signed.single, same(request));
        expect(authenticator().signed.single.body, equals(body));
        expect(attempt.session, container.read(authSession.notifier).session);
        expect(attempt.credential, isA<FakeCredential>());
        expect(attempt.isReplay, isFalse);
        expect(attempt.resent, isFalse);
        expect(attempt.renewed, isFalse);
        expect(backend.renewals, 0);
      },
    );

    test('the headers it returns cannot be changed', () async {
      setUpAuthorizer();
      final attempt = await credentials.authorize(get(orders));
      expect(() => attempt.headers['x'] = 'y', throwsUnsupportedError);
    });

    test('every authorize is signed afresh', () async {
      setUpAuthorizer();
      final request = get(orders);
      final a = await credentials.authorize(request);
      final b = await credentials.authorize(request);
      expect(a.headers['x-fake-credential'], 'fake-0#1');
      expect(b.headers['x-fake-credential'], 'fake-0#2');
    });

    test('a streamed body reaches the authenticator as null bytes', () async {
      setUpAuthorizer();
      final request = TransportRequest(
        method: 'PUT',
        uri: orders,
        bodyStream: Stream<List<int>>.value([1, 2]),
      );
      await credentials.authorize(request);
      expect(authenticator().signed.single.body, isNull);
      expect(authenticator().signed.single.bodyStream, isNotNull);
    });

    test(
      'an authenticator that refuses the send makes authorize throw',
      () async {
        final c = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(
                backend: _RefusingBackend(),
                transport: FakeTransport((_, _) => fakeResponse(200)),
                store: MemoryTokenStore(),
                apiOrigins: [api],
              ),
            ),
            authInitialState.overrideWithValue(SignedIn(fakeSession(ada))),
          ],
        );
        addTearDown(c.dispose);
        await expectLater(
          c.read(authorizer).authorize(get(orders)),
          throwsArgumentError,
        );
      },
    );

    test(
      'a URL that is not covered gets nothing, and the authenticator is not asked',
      () async {
        setUpAuthorizer();
        final attempt = await credentials.authorize(
          get(Uri.parse('https://other.example.org/x')),
        );
        expect(attempt.headers, isEmpty);
        expect(attempt.request, isNull);
        expect(attempt.session, isNull);
        expect(attempt.credential, isNull);
        expect(authenticator().signed, isEmpty);
      },
    );

    test('signed out: nothing is attached and nothing is renewed', () async {
      setUpAuthorizer(signedInAs: null);
      final attempt = await credentials.authorize(get(orders));
      expect(attempt.headers, isEmpty);
      expect(attempt.request, isNull);
      expect(authenticator().signed, isEmpty);
      expect(backend.renewals, 0);
    });

    test(
      'an attempt the Authorizer did not make is an ArgumentError',
      () async {
        setUpAuthorizer();
        final foreign = await FakeHttpCredentials(
          origins: [api],
        ).authorize(get(orders));
        await expectLater(
          credentials.authorize(get(orders), previous: foreign),
          throwsArgumentError,
        );
      },
    );

    test(
      'an expired credential is renewed first, shared by every request that finds it so',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpAuthorizer(credentialLifetime: const Duration(minutes: 5));
          time.elapse(const Duration(minutes: 6));
          final gate = backend.gate = Completer<void>();
          final a = credentials.authorize(get(orders));
          final b = credentials.authorize(get(orders));
          await pumpEventQueue();
          expect(backend.renewals, 1);
          gate.complete();
          final attempts = await Future.wait([a, b]);
          expect(backend.renewals, 1);
          for (final attempt in attempts) {
            expect(attempt.headers['x-fake-credential'], startsWith('fake-1#'));
          }
        });
      },
    );

    test(
      'a renewal the server refused: AuthRejected, and the user is signed out',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpAuthorizer(credentialLifetime: const Duration(minutes: 5));
          time.elapse(const Duration(minutes: 6));
          backend.renewError = const AuthRejected();
          await expectLater(
            credentials.authorize(get(orders)),
            throwsA(isA<AuthRejected>()),
          );
          expect(
            container.read(authSession),
            const SignedOut(reason: SignOutReason.expired),
          );
          expect(authenticator().signed, isEmpty);
        });
      },
    );

    test(
      'a renewal that could not run: AuthUnavailable, and the session stays',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpAuthorizer(credentialLifetime: const Duration(minutes: 5));
          time.elapse(const Duration(minutes: 6));
          backend.renewError = Exception('offline');
          await expectLater(
            credentials.authorize(get(orders)),
            throwsA(isA<AuthUnavailable>()),
          );
          expect(container.read(authSession), isA<SignedIn>());
        });
      },
    );

    test(
      'a request made for one user is never sent again as another',
      () async {
        setUpAuthorizer();
        final request = get(orders);
        final first = await credentials.authorize(request);
        await container.read(authSession.notifier).adopt(fakeSession(bob));
        await expectLater(
          credentials.authorize(request, previous: first),
          throwsA(isA<AuthRejected>()),
        );
      },
    );

    test('the same user signing in again is the same user', () async {
      setUpAuthorizer();
      final request = get(orders);
      final first = await credentials.authorize(request);
      await container.read(authSession.notifier).signIn(const TestSignIn());
      final second = await credentials.authorize(request, previous: first);
      expect(second.headers, isNotEmpty);
    });

    test('signed out between two sends: the resend gets nothing', () async {
      setUpAuthorizer();
      backend.authenticator.verdict = (_, _, _, _, _, _) => const Resend();
      final request = get(orders);
      final first = await credentials.authorize(request);
      expect(await credentials.retry(first, buffered(401)), isTrue);
      await container.read(authSession.notifier).signOut();
      final second = await credentials.authorize(request, previous: first);
      expect(second.request, isNull);
      expect(second.headers, isEmpty);
      expect(second.isReplay, isTrue, reason: 'it still follows a verdict');
    });
  });

  group('retry', () {
    setUp(setUpAuthorizer);

    test('Accept: the response stands', () async {
      final attempt = await credentials.authorize(get(orders));
      expect(await credentials.retry(attempt, buffered(200)), isFalse);
      expect(await credentials.retry(attempt, buffered(500)), isFalse);
      expect(backend.renewals, 0);
    });

    test(
      'an attempt that carried nothing is never retried, nor judged',
      () async {
        final attempt = await credentials.authorize(
          get(Uri.parse('https://other.example.org/x')),
        );
        expect(await credentials.retry(attempt, buffered(401)), isFalse);
        expect(authenticator().judged, isEmpty);
        expect(backend.renewals, 0);
      },
    );

    test('Resend: once, then the response stands', () async {
      authenticator().verdict = (_, _, _, _, _, _) => const Resend();
      final request = get(orders);
      final first = await credentials.authorize(request);
      expect(await credentials.retry(first, buffered(401)), isTrue);
      final second = await credentials.authorize(request, previous: first);
      expect(second.isReplay, isTrue);
      expect(second.resent, isTrue);
      expect(second.renewed, isFalse);
      expect(await credentials.retry(second, buffered(401)), isFalse);
      expect(backend.renewals, 0, reason: 'a nonce is not a renewal');
    });

    test('Renew: one shared renewal, then true, once', () async {
      final request = get(orders);
      final first = await credentials.authorize(request);
      expect(first.headers['x-fake-credential'], startsWith('fake-0#'));
      expect(await credentials.retry(first, buffered(401)), isTrue);
      expect(backend.renewals, 1);
      final second = await credentials.authorize(request, previous: first);
      expect(second.headers['x-fake-credential'], startsWith('fake-1#'));
      expect(second.isReplay, isTrue);
      expect(second.renewed, isTrue);
      expect(second.resent, isFalse);
      // A second 401 stands: no loop.
      expect(await credentials.retry(second, buffered(401)), isFalse);
      expect(backend.renewals, 1);
    });

    test('Renew: the renewal is shared by requests refused together', () async {
      final a = await credentials.authorize(get(orders));
      final b = await credentials.authorize(get(orders));
      backend.gate = Completer<void>();
      final one = credentials.retry(a, buffered(401));
      final two = credentials.retry(b, buffered(401));
      await pumpEventQueue();
      expect(backend.renewals, 1);
      backend.gate!.complete();
      expect(await Future.wait([one, two]), [true, true]);
      expect(backend.renewals, 1);
    });

    test('Renew carries the verdict\'s hint to the backend', () async {
      authenticator().verdict = (_, _, _, _, _, _) =>
          const Renew(hint: 'role-b');
      final attempt = await credentials.authorize(get(orders));
      expect(await credentials.retry(attempt, buffered(401)), isTrue);
      expect(backend.hints, ['role-b']);
    });

    test(
      'Renew when the server refuses the renewal: false, and the user is signed out',
      () async {
        backend.renewError = const AuthRejected();
        final attempt = await credentials.authorize(get(orders));
        expect(await credentials.retry(attempt, buffered(401)), isFalse);
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
      },
    );

    test('Renew when the user signed out meanwhile: false', () async {
      final attempt = await credentials.authorize(get(orders));
      await container.read(authSession.notifier).signOut();
      expect(await credentials.retry(attempt, buffered(401)), isFalse);
      expect(backend.renewals, 0);
    });

    test(
      'Renew when the renewal could not run: AuthUnavailable, session kept',
      () async {
        backend.renewError = Exception('offline');
        final attempt = await credentials.authorize(get(orders));
        await expectLater(
          credentials.retry(attempt, buffered(401)),
          throwsA(isA<AuthUnavailable>()),
        );
        expect(container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'SessionEnded: signs out with its reason, discards what was bound to the session, and throws AuthRejected',
      () async {
        authenticator().verdict = (_, _, _, _, _, _) =>
            const SessionEnded(SignOutReason.revoked);
        final attempt = await credentials.authorize(get(orders));
        await expectLater(
          credentials.retry(attempt, buffered(403)),
          throwsA(isA<AuthRejected>()),
        );
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
        expect(backend.discards, 1);
        expect(backend.signOuts, 0);
        expect(backend.renewals, 0);
      },
    );

    test('SessionEnded does not end another user\'s session', () async {
      authenticator().verdict = (_, _, _, _, _, _) =>
          const SessionEnded(SignOutReason.revoked);
      final attempt = await credentials.authorize(get(orders));
      // The answer to a request made for Ada arrives after Bob signed in.
      await container.read(authSession.notifier).adopt(fakeSession(bob));
      await expectLater(
        credentials.retry(attempt, buffered(403)),
        throwsA(isA<AuthRejected>()),
      );
      expect(container.read(authSession), isA<SignedIn>());
      expect(container.read(authUserId), 'bob-id');
      expect(backend.discards, 0);
    });

    test(
      'the status, the headers and "retried" are what the authenticator judges',
      () async {
        final seen = <(int, Map<String, String>, bool)>[];
        authenticator().verdict = (_, _, status, headers, _, retried) {
          seen.add((status, headers, retried));
          return status == 401 ? const Renew() : const Accept();
        };
        final request = get(orders);
        final first = await credentials.authorize(request);
        final response = TransportResponse.fromBytes(
          statusCode: 401,
          headers: const {'www-authenticate': 'Bearer error="invalid_token"'},
          bytes: Uint8List(0),
        );
        await credentials.retry(first, response);
        final second = await credentials.authorize(request, previous: first);
        await credentials.retry(second, buffered(200));
        expect(seen[0].$1, 401);
        expect(seen[0].$2, {
          'www-authenticate': 'Bearer error="invalid_token"',
        });
        expect(seen[0].$3, isFalse);
        expect(seen[1].$1, 200);
        expect(seen[1].$3, isTrue, reason: 'this send followed a Renew');
      },
    );

    test('the authenticator is judged with the request it signed', () async {
      TransportRequest? judged;
      authenticator().verdict = (_, request, _, _, _, _) {
        judged = request;
        return const Accept();
      };
      final request = get(orders);
      final attempt = await credentials.authorize(request);
      await credentials.retry(attempt, buffered(200));
      expect(judged, same(request));
    });

    test('a buffered response\'s body is handed to judge as text', () async {
      String? body = 'unset';
      authenticator().verdict = (_, _, _, _, text, _) {
        body = text;
        return const Accept();
      };
      final attempt = await credentials.authorize(get(orders));
      await credentials.retry(
        attempt,
        buffered(401, '{"error":"invalid_token"}'),
      );
      expect(body, '{"error":"invalid_token"}');
    });

    test('a streamed response\'s body is not read: judge gets null', () async {
      String? body = 'unset';
      authenticator().verdict = (_, _, _, _, text, _) {
        body = text;
        return const Accept();
      };
      final attempt = await credentials.authorize(get(orders));
      final response = fakeResponse(401, body: 'not read');
      await credentials.retry(attempt, response);
      expect(body, isNull);
      expect(response.isBuffered, isFalse);
      expect(
        utf8.decode(await response.bytes()),
        'not read',
        reason: 'still whole',
      );
    });

    test('a body that is not UTF-8 does not throw', () async {
      String? body;
      authenticator().verdict = (_, _, _, _, text, _) {
        body = text;
        return const Accept();
      };
      final attempt = await credentials.authorize(get(orders));
      await credentials.retry(
        attempt,
        TransportResponse.fromBytes(
          statusCode: 401,
          headers: const {},
          bytes: Uint8List.fromList([0xff, 0xfe, 0x41]),
        ),
      );
      expect(body, endsWith('A'));
    });
  });

  group('the authorizer provider', () {
    test('with no apiOrigins it says so, with the text of M8', () {
      setUpAuthorizer(origins: const []);
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
      'is the same Authorizer after a renewal: nothing watching it reloads',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpAuthorizer(credentialLifetime: const Duration(minutes: 5));
          var rebuilt = 0;
          container.listen(authorizer, (_, _) => rebuilt++);
          time.elapse(const Duration(minutes: 6));
          await credentials.authorize(get(orders));
          expect(backend.renewals, 1);
          expect(identical(container.read(authorizer), credentials), isTrue);
          expect(rebuilt, 0);
        });
      },
    );

    test('is the same Authorizer after a sign-out and a sign-in', () async {
      setUpAuthorizer();
      await container.read(authSession.notifier).signOut();
      await container.read(authSession.notifier).signIn(const TestSignIn());
      expect(identical(container.read(authorizer), credentials), isTrue);
    });
  });
}

/// An authenticator that refuses every send, as one that needs the bytes of a streamed body does.
final class _Refuses implements RequestAuthenticator {
  @override
  Future<Map<String, String>> headers(
    AuthSession session,
    TransportRequest request,
  ) async => throw ArgumentError('this scheme signs bytes, not streams');

  @override
  AuthVerdict judge(
    AuthSession session,
    TransportRequest request, {
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  }) => const Accept();
}

final class _RefusingBackend extends StubBackend {
  _RefusingBackend();

  @override
  RequestAuthenticator get authenticator => _Refuses();
}
