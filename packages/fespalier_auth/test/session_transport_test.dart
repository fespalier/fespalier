// SessionTransport and the Authorizer under it: which requests carry the session, what is sent
// again and how often, and what a failed renewal does to a request.
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

const credentialHeader = 'x-fake-credential';

TransportRequest get(Uri uri) => TransportRequest(method: 'GET', uri: uri);

TransportRequest post(Uri uri, String body) => TransportRequest(
  method: 'POST',
  uri: uri,
  headers: const {'content-type': 'application/json'},
  body: Uint8List.fromList(utf8.encode(body)),
);

Future<String> text(TransportResponse response) async =>
    utf8.decode(await response.bytes());

/// What the API saw, and what it answers: 401 to every credential but [good].
final class Api {
  /// The credential id the API accepts.
  String good = 'fake-1';

  late final FakeTransport transport = FakeTransport((request, _) {
    final header = request.headers[credentialHeader];
    final ok = header != null && header.startsWith('$good#');
    return fakeResponse(ok ? 200 : 401, body: ok ? 'orders' : 'no');
  });

  /// The credential header of each request that arrived, in order.
  List<String?> get ids => [
    for (final r in transport.requests) r.lowerHeaders[credentialHeader],
  ];

  /// The requests that arrived.
  List<SentRequest> get seen => transport.requests;
}

void main() {
  late FakeAuthBackend backend;
  late Api server;
  late ProviderContainer container;

  void setUpTransport({
    AuthUser? signedInAs = ada,
    FakeAuthBackend? use,
    List<Uri>? origins,
    Duration? credentialLifetime,
  }) {
    backend =
        use ??
        FakeAuthBackend(user: ada, credentialLifetime: credentialLifetime);
    server = Api();
    container = containerFor(
      signedInAs: signedInAs,
      backend: backend,
      apiOrigins: origins ?? [api],
      transport: server.transport,
      credentialLifetime: credentialLifetime,
    );
  }

  SessionTransport sessionOver(HttpTransport inner) =>
      SessionTransport(inner, container.read(authorizer));

  SessionTransport transport() => sessionOver(server.transport);

  FakeAuthenticator authenticator() => backend.authenticator;

  group('which requests carry the session', () {
    test('a request to an API origin carries the credential', () async {
      setUpTransport();
      server.good = 'fake-0';
      final response = await transport().send(get(orders));
      expect(response.statusCode, 200);
      expect(server.ids, ['fake-0#1']);
    });

    test(
      'no other origin gets one: another host, scheme, port or subdomain; the request is untouched',
      () async {
        setUpTransport();
        final sent = <TransportRequest>[];
        for (final url in [
          'https://other.example.org/orders',
          'http://api.example.com/orders',
          'https://api.example.com:8443/orders',
          'https://v2.api.example.com/orders',
          'https://api.example.com.evil.test/orders',
        ]) {
          final request = get(Uri.parse(url));
          sent.add(request);
          await transport().send(request);
        }
        expect(server.ids, everyElement(isNull));
        expect(server.seen, hasLength(5));
        for (var i = 0; i < 5; i++) {
          expect(
            identical(server.seen[i].request, sent[i]),
            isTrue,
            reason: 'the very request, not a copy',
          );
        }
        expect(backend.renewals, 0);
        expect(authenticator().signed, isEmpty);
        expect(authenticator().judged, isEmpty);
      },
    );

    test('a 401 from another origin is not judged and not replayed', () async {
      setUpTransport();
      final response = await transport().send(
        get(Uri.parse('https://other.example.org/orders')),
      );
      expect(response.statusCode, 401);
      expect(server.seen, hasLength(1));
      expect(backend.renewals, 0);
    });

    test('the default port and the host case do not matter', () async {
      setUpTransport();
      server.good = 'fake-0';
      await transport().send(
        get(Uri.parse('https://API.example.com:443/orders')),
      );
      expect(server.ids, ['fake-0#1']);
    });

    test('an origin with a port is matched with it', () async {
      setUpTransport(origins: [Uri.parse('http://localhost:8080')]);
      server.good = 'fake-0';
      await transport().send(get(Uri.parse('http://localhost:8080/orders')));
      await transport().send(get(Uri.parse('http://localhost:9090/orders')));
      expect(server.ids, ['fake-0#1', null]);
    });

    test(
      'signed out: the request goes with no header, and nothing is renewed',
      () async {
        setUpTransport(signedInAs: null);
        final response = await transport().send(get(orders));
        expect(response.statusCode, 401);
        expect(server.ids, [null]);
        expect(
          server.seen,
          hasLength(1),
          reason: 'no credential to renew, so nothing to send again',
        );
        expect(backend.renewals, 0);
        expect(authenticator().judged, isEmpty);
      },
    );

    test(
      'a header the caller set is replaced for the API, and left alone elsewhere',
      () async {
        setUpTransport();
        server.good = 'fake-0';
        await transport().send(
          TransportRequest(
            method: 'GET',
            uri: orders,
            headers: const {credentialHeader: 'mine'},
          ),
        );
        await transport().send(
          TransportRequest(
            method: 'GET',
            uri: Uri.parse('https://other.example.org/x'),
            headers: const {credentialHeader: 'mine'},
          ),
        );
        expect(server.ids, ['fake-0#1', 'mine']);
      },
    );

    test('the caller\'s other headers and attributes are kept', () async {
      setUpTransport();
      server.good = 'fake-0';
      await transport().send(
        TransportRequest(
          method: 'GET',
          uri: orders,
          headers: const {'accept': 'application/json'},
          attributes: const {'app.key': 1},
        ),
      );
      final sent = server.seen.single;
      expect(sent.lowerHeaders['accept'], 'application/json');
      expect(sent.request.attributes, {'app.key': 1});
      expect(
        sent.request.attributes.containsKey(transportReplayKey),
        isFalse,
        reason: 'the first send is not a replay',
      );
    });

    test(
      'authTransport is a SessionTransport over the configured transport',
      () {
        setUpTransport();
        final built = container.read(authTransport);
        expect(built, isA<SessionTransport>());
        final session = built as SessionTransport;
        expect(session.inner, same(server.transport));
        expect(session.authorizer, same(container.read(authorizer)));
      },
    );

    test(
      'authTransport is the same transport after a renewal: nothing watching it reloads',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpTransport(
            use: FakeAuthBackend(
              user: ada,
              credentialLifetime: const Duration(minutes: 5),
            ),
            credentialLifetime: const Duration(minutes: 5),
          );
          final before = container.read(authTransport);
          var rebuilt = 0;
          container.listen(authTransport, (_, _) => rebuilt++);
          time.elapse(const Duration(minutes: 6));
          await before.send(get(orders));
          expect(backend.renewals, 1);
          expect(identical(container.read(authTransport), before), isTrue);
          expect(rebuilt, 0);
        });
      },
    );
  });

  group('a renewal', () {
    test(
      'an expired credential is renewed before the request is sent',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpTransport(
            use: FakeAuthBackend(
              user: ada,
              credentialLifetime: const Duration(minutes: 5),
            ),
            credentialLifetime: const Duration(minutes: 5),
          );
          time.elapse(const Duration(minutes: 6));
          final response = await transport().send(get(orders));
          expect(response.statusCode, 200);
          expect(server.ids, [
            'fake-1#1',
          ], reason: 'one send: no 401 round trip');
          expect(backend.renewals, 1);
        });
      },
    );

    test(
      'a credential inside renewAhead is renewed before the request too',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpTransport(
            use: FakeAuthBackend(
              user: ada,
              credentialLifetime: const Duration(minutes: 5),
              renewAhead: const Duration(minutes: 1),
            ),
            credentialLifetime: const Duration(minutes: 5),
          );
          time.elapse(const Duration(minutes: 4, seconds: 30));
          await transport().send(get(orders));
          expect(server.ids, ['fake-1#1']);
          expect(backend.renewals, 1);
        });
      },
    );

    test(
      'a 401 renews once and sends the request again, marked as a replay',
      () async {
        setUpTransport();
        final response = await transport().send(get(orders));
        expect(response.statusCode, 200);
        expect(await text(response), 'orders');
        expect(server.ids, [
          'fake-0#1',
          'fake-1#2',
        ], reason: 'the header id changes');
        expect(backend.renewals, 1);
        expect(
          server.seen[0].request.attributes[transportReplayKey],
          isNull,
          reason: 'the first send is not a replay',
        );
        expect(server.seen[1].request.attributes[transportReplayKey], isTrue);
      },
    );

    test(
      'every send is authorized again with the exact bytes of the body',
      () async {
        setUpTransport();
        final response = await transport().send(post(orders, '{"item":1}'));
        expect(response.statusCode, 200);
        expect(server.seen, hasLength(2));
        expect(authenticator().signed, hasLength(2));
        for (var i = 0; i < 2; i++) {
          expect(
            utf8.decode(authenticator().signed[i].body!),
            '{"item":1}',
            reason: 'signed send $i',
          );
          expect(server.seen[i].text, '{"item":1}');
          expect(server.seen[i].method, 'POST');
          expect(
            server.seen[i].lowerHeaders['content-type'],
            'application/json',
          );
        }
      },
    );

    test(
      'the abort trigger and the caller\'s attributes survive the replay',
      () async {
        setUpTransport();
        final abort = Completer<void>();
        await transport().send(
          TransportRequest(
            method: 'GET',
            uri: orders,
            abortTrigger: abort.future,
            attributes: const {'app.key': 'v'},
          ),
        );
        expect(server.seen, hasLength(2));
        for (final sent in server.seen) {
          expect(sent.request.abortTrigger, same(abort.future));
          expect(sent.request.attributes['app.key'], 'v');
        }
      },
    );

    test('two requests that get a 401 together share one renewal', () async {
      setUpTransport();
      backend.gate = Completer<void>();
      final a = transport().send(get(orders));
      final b = transport().send(
        get(Uri.parse('https://api.example.com/orders/1')),
      );
      await pumpEventQueue();
      expect(backend.renewals, 1);
      backend.gate!.complete();
      final responses = await Future.wait([a, b]);
      expect(responses.map((r) => r.statusCode), [200, 200]);
      expect(backend.renewals, 1);
      expect(server.seen, hasLength(4));
    });

    test('a second 401 is returned as it is: no loop', () async {
      setUpTransport();
      server.good = 'never';
      final response = await transport().send(get(orders));
      expect(response.statusCode, 401);
      expect(await text(response), 'no', reason: 'the body is whole');
      expect(server.seen, hasLength(2));
      expect(backend.renewals, 1);
    });

    test(
      'a verdict of Resend sends the request again, once, with no renewal',
      () async {
        setUpTransport();
        server.good = 'never';
        authenticator().verdict = (_, _, status, _, _, _) =>
            status == 401 ? const Resend() : const Accept();
        final response = await transport().send(get(orders));
        expect(response.statusCode, 401);
        expect(server.seen, hasLength(2));
        expect(server.ids, ['fake-0#1', 'fake-0#2']);
        expect(server.seen[1].request.attributes[transportReplayKey], isTrue);
        expect(backend.renewals, 0);
      },
    );

    test(
      'a request is sent at most three times: a resend, a renewal, then it stands',
      () async {
        setUpTransport();
        server.good = 'never';
        authenticator().verdict = (_, _, status, _, _, retried) {
          if (status != 401) return const Accept();
          return authenticator().judged.length == 1
              ? const Resend()
              : const Renew();
        };
        final response = await transport().send(get(orders));
        expect(response.statusCode, 401);
        expect(server.seen, hasLength(3));
        expect(backend.renewals, 1);
        expect(server.ids, ['fake-0#1', 'fake-0#2', 'fake-1#3']);
        expect(
          authenticator().signed,
          hasLength(3),
          reason: 'each send is signed afresh',
        );
        expect(server.seen[1].request.attributes[transportReplayKey], isTrue);
        expect(server.seen[2].request.attributes[transportReplayKey], isTrue);
      },
    );

    test('a Renew verdict for another status than 401 renews too', () async {
      setUpTransport();
      authenticator().verdict = (_, _, status, _, _, _) =>
          status == 401 || status == 419 ? const Renew() : const Accept();
      server.good = 'fake-1';
      final custom = FakeTransport.script([
        fakeResponse(419, body: 'expired'),
        fakeResponse(200, body: 'ok'),
      ]);
      final response = await sessionOver(custom).send(get(orders));
      expect(response.statusCode, 200);
      expect(backend.renewals, 1);
      expect(custom.requests, hasLength(2));
    });

    test('the hint of a Renew verdict reaches the backend', () async {
      setUpTransport();
      authenticator().verdict = (_, _, status, _, _, _) =>
          status == 401 ? const Renew(hint: 'wallet') : const Accept();
      await transport().send(get(orders));
      expect(backend.hints, ['wallet']);
    });

    test(
      'a renewal the server refuses: the 401 is returned and the user is signed out',
      () async {
        setUpTransport();
        backend.renewError = const AuthRejected();
        final response = await transport().send(get(orders));
        expect(response.statusCode, 401);
        expect(await text(response), 'no');
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
        expect(server.seen, hasLength(1));
        await pumpEventQueue();
        expect(backend.discards, 1);
      },
    );

    test(
      'a renewal that cannot run: AuthUnavailable, the user stays signed in, and the next send asks again',
      () async {
        setUpTransport();
        backend.renewError = Exception('offline');
        await expectLater(
          transport().send(get(orders)),
          throwsA(isA<AuthUnavailable>()),
        );
        expect(container.read(authSession), isA<SignedIn>());
        // It is a CredentialsUnavailable: a transfer reports a network failure, not a lost session.
        await expectLater(
          transport().send(get(orders)),
          throwsA(isA<CredentialsUnavailable>()),
        );
        expect(backend.renewals, 2);
        backend.renewError = null;
        final response = await transport().send(get(orders));
        expect(response.statusCode, 200);
      },
    );

    test(
      'an expired credential that cannot be renewed: AuthRejected / AuthUnavailable, no request is sent',
      () async {
        final time = TestTime();
        await time.run(() async {
          setUpTransport(
            use: FakeAuthBackend(
              user: ada,
              credentialLifetime: const Duration(minutes: 5),
            ),
            credentialLifetime: const Duration(minutes: 5),
          );
          time.elapse(const Duration(minutes: 6));
          backend.renewError = Exception('offline');
          await expectLater(
            transport().send(get(orders)),
            throwsA(isA<AuthUnavailable>()),
          );
          backend.renewError = const AuthRejected();
          await expectLater(
            transport().send(get(orders)),
            throwsA(isA<AuthRejected>()),
          );
          expect(server.seen, isEmpty);
          expect(
            container.read(authSession),
            const SignedOut(reason: SignOutReason.expired),
          );
        });
      },
    );

    test(
      'AuthEnded(revoked) from a renewal: SignedOut(revoked), and the 401 is returned',
      () async {
        setUpTransport();
        backend.renewError = const AuthEnded(SignOutReason.revoked);
        final response = await transport().send(get(orders));
        expect(response.statusCode, 401);
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
      },
    );
  });

  group('a session that ended', () {
    test(
      'a SessionEnded verdict signs out with its reason, discards, and fails the request with AuthRejected',
      () async {
        setUpTransport();
        authenticator().verdict = (_, _, status, _, _, _) => status == 403
            ? const SessionEnded(SignOutReason.revoked)
            : const Accept();
        final forbidden = FakeTransport.script([
          fakeResponse(403, body: 'revoked'),
        ]);
        await expectLater(
          sessionOver(forbidden).send(get(orders)),
          throwsA(isA<AuthRejected>()),
        );
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
        expect(backend.discards, 1);
        expect(backend.signOuts, 0, reason: 'the server said it is over');
        expect(forbidden.requests, hasLength(1));
        expect(authenticator().judged, [403]);
      },
    );

    test('after it ended, later requests go out unauthenticated', () async {
      setUpTransport();
      authenticator().verdict = (_, _, status, _, _, _) =>
          const SessionEnded(SignOutReason.keyLost);
      await expectLater(
        transport().send(get(orders)),
        throwsA(isA<AuthRejected>()),
      );
      authenticator().verdict = null;
      await transport().send(get(orders));
      expect(server.ids.last, isNull);
    });
  });

  group('a body that cannot be sent twice', () {
    test(
      'a streamed request is sent once, and its 401 comes back after the renewal',
      () async {
        setUpTransport();
        server.good = 'never';
        final request = TransportRequest(
          method: 'PUT',
          uri: orders,
          bodyStream: Stream<List<int>>.value([1, 2, 3]),
        );
        expect(request.replayable, isFalse);
        final response = await transport().send(request);
        expect(response.statusCode, 401);
        expect(server.seen, hasLength(1));
        expect(server.seen.single.body, [1, 2, 3]);
        expect(
          backend.renewals,
          1,
          reason: 'renewed, so that its next attempt works',
        );
        expect(authenticator().signed.single.body, isNull);
        server.good = 'fake-1';
        final next = await transport().send(get(orders));
        expect(next.statusCode, 200);
      },
    );

    test('a streamed request that is not refused is just sent', () async {
      setUpTransport();
      server.good = 'fake-0';
      final response = await transport().send(
        TransportRequest(
          method: 'PUT',
          uri: orders,
          bodyStream: Stream<List<int>>.value([9]),
        ),
      );
      expect(response.statusCode, 200);
      expect(server.seen, hasLength(1));
    });

    test(
      'an authenticator that needs the bytes refuses a stream: the ArgumentError propagates and nothing is sent',
      () async {
        final needsBytes = _NeedsBytesBackend();
        final inner = FakeTransport((_, _) => fakeResponse(200));
        final c = ProviderContainer(
          overrides: [
            authConfig.overrideWithValue(
              AuthConfig(
                backend: needsBytes,
                transport: inner,
                store: MemoryTokenStore(),
                apiOrigins: [api],
              ),
            ),
            authInitialState.overrideWithValue(SignedIn(fakeSession(ada))),
          ],
        );
        addTearDown(c.dispose);
        final session = SessionTransport(inner, c.read(authorizer));
        await expectLater(
          session.send(
            TransportRequest(
              method: 'PUT',
              uri: orders,
              bodyStream: Stream<List<int>>.value([1]),
            ),
          ),
          throwsArgumentError,
        );
        expect(inner.requests, isEmpty);
        // The same backend signs a request whose bytes are known.
        final response = await session.send(post(orders, '{}'));
        expect(response.statusCode, 200);
        expect(inner.requests.single.lowerHeaders['x-bytes'], '2');
      },
    );
  });

  group('the body of a refusal', () {
    test(
      'a 401 body is read and handed to the authenticator as text, and the caller still has it whole',
      () async {
        setUpTransport();
        final bodies = <String?>[];
        authenticator().verdict = (_, _, _, _, body, _) {
          bodies.add(body);
          return const Accept();
        };
        final inner = FakeTransport.script([
          fakeResponse(401, body: '{"error":"invalid_token"}'),
        ]);
        final response = await sessionOver(inner).send(get(orders));
        expect(bodies, ['{"error":"invalid_token"}']);
        expect(response.statusCode, 401);
        expect(await text(response), '{"error":"invalid_token"}');
        expect(response.isBuffered, isTrue);
      },
    );

    test('a 403 body is read too', () async {
      setUpTransport();
      final bodies = <String?>[];
      authenticator().verdict = (_, _, _, _, body, _) {
        bodies.add(body);
        return const Accept();
      };
      final inner = FakeTransport.script([
        fakeResponse(403, body: 'DPoP nonce needed'),
      ]);
      final response = await sessionOver(inner).send(get(orders));
      expect(bodies, ['DPoP nonce needed']);
      expect(await text(response), 'DPoP nonce needed');
    });

    test(
      'another status is not read for the authenticator: it streams to the caller',
      () async {
        setUpTransport();
        final bodies = <String?>[];
        authenticator().verdict = (_, _, _, _, body, _) {
          bodies.add(body);
          return const Accept();
        };
        for (final status in [200, 404, 500]) {
          final answer = fakeResponse(status, body: 'payload');
          final inner = FakeTransport.script([answer]);
          final response = await sessionOver(inner).send(get(orders));
          expect(identical(response, answer), isTrue, reason: '$status');
          expect(response.isBuffered, isFalse, reason: '$status');
          expect(await text(response), 'payload');
        }
        expect(bodies, [null, null, null]);
      },
    );

    test('a body of exactly 64 KiB is read; one byte more is not', () async {
      setUpTransport();
      final bodies = <int?>[];
      authenticator().verdict = (_, _, _, _, body, _) {
        bodies.add(body?.length);
        return const Accept();
      };
      for (final length in [64 * 1024, 64 * 1024 + 1]) {
        final inner = FakeTransport.script([
          fakeResponse(401, body: 'a' * length),
        ]);
        final response = await sessionOver(inner).send(get(orders));
        expect(
          (await response.bytes()).length,
          length,
          reason: 'whole: $length',
        );
      }
      expect(bodies, [64 * 1024, null]);
    });

    test(
      'a body that outgrows 64 KiB in chunks is not read for the authenticator but streams whole to the caller',
      () async {
        setUpTransport();
        final bodies = <String?>[];
        authenticator().verdict = (_, _, _, _, body, _) {
          bodies.add(body);
          return const Accept();
        };
        final chunks = [
          List<int>.filled(40000, 1),
          List<int>.filled(40000, 2),
          List<int>.filled(10, 3),
        ];
        final inner = FakeTransport.script([
          TransportResponse(
            statusCode: 401,
            headers: const {'x-keep': 'me'},
            body: Stream<List<int>>.fromIterable(chunks),
            reasonPhrase: 'Unauthorized',
          ),
        ]);
        final response = await sessionOver(inner).send(get(orders));
        expect(bodies, [null]);
        expect(response.statusCode, 401);
        expect(response.headers, {'x-keep': 'me'});
        expect(response.reasonPhrase, 'Unauthorized');
        expect(response.isBuffered, isFalse);
        final all = await response.bytes();
        expect(all, hasLength(80010));
        expect(all.sublist(0, 40000), everyElement(1));
        expect(all.sublist(40000, 80000), everyElement(2));
        expect(all.sublist(80000), everyElement(3));
      },
    );

    test(
      'a content-length over 64 KiB is not read at all: the very response goes back',
      () async {
        setUpTransport();
        final bodies = <String?>[];
        authenticator().verdict = (_, _, _, _, body, _) {
          bodies.add(body);
          return const Accept();
        };
        var listened = false;
        final controller = StreamController<List<int>>(
          onListen: () => listened = true,
        );
        final answer = TransportResponse(
          statusCode: 401,
          headers: const {'content-length': '70000'},
          body: controller.stream,
        );
        final inner = FakeTransport.script([answer]);
        final response = await sessionOver(inner).send(get(orders));
        expect(identical(response, answer), isTrue);
        expect(listened, isFalse, reason: 'not even started');
        expect(bodies, [null]);
        unawaited(controller.close());
      },
    );

    test(
      'a 401 that is replayed has its first body drained, so the connection is freed',
      () async {
        setUpTransport();
        var listened = false;
        final controller = StreamController<List<int>>(
          onListen: () => listened = true,
        );
        authenticator().verdict = (_, _, status, _, _, retried) =>
            status == 419 && !retried ? const Resend() : const Accept();
        final inner = FakeTransport.script([
          TransportResponse(
            statusCode: 419,
            headers: const {},
            body: controller.stream,
          ),
          fakeResponse(200, body: 'ok'),
        ]);
        final done = sessionOver(inner).send(get(orders));
        await pumpEventQueue();
        expect(listened, isTrue);
        unawaited(controller.close());
        final response = await done;
        expect(response.statusCode, 200);
      },
    );

    test(
      'a response thrown away by a failing verdict is drained too',
      () async {
        setUpTransport();
        authenticator().verdict = (_, _, _, _, _, _) =>
            const SessionEnded(SignOutReason.revoked);
        var listened = false;
        final controller = StreamController<List<int>>(
          onListen: () => listened = true,
        );
        final inner = FakeTransport.script([
          TransportResponse(
            statusCode: 418,
            headers: const {},
            body: controller.stream,
          ),
        ]);
        await expectLater(
          sessionOver(inner).send(get(orders)),
          throwsA(isA<AuthRejected>()),
        );
        await pumpEventQueue();
        expect(listened, isTrue);
        unawaited(controller.close());
      },
    );
  });

  group('the user changes while a request is out', () {
    test(
      'a sign-out while the 401 is read: the user is signed out, the 401 comes back and nothing is sent without the session',
      () async {
        setUpTransport();
        final notifier = container.read(authSession.notifier);
        final inner = FakeTransport((request, _) {
          return TransportResponse(
            statusCode: 401,
            headers: const {},
            body: Stream<List<int>>.fromFuture(
              Future(() async {
                await notifier.signOut();
                return <int>[1];
              }),
            ),
          );
        });
        final response = await sessionOver(inner).send(get(orders));
        expect(response.statusCode, 401);
        expect(inner.requests, hasLength(1));
        expect(
          container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
        expect(backend.renewals, 0);
      },
    );

    test(
      'a sign-out while a refused response is drained, after the verdict said to send again: the replay is not sent without the session',
      () async {
        setUpTransport();
        authenticator().verdict = (_, _, status, _, _, _) =>
            status == 419 ? const Renew() : const Accept();
        final notifier = container.read(authSession.notifier);
        final inner = FakeTransport((request, _) {
          return TransportResponse(
            statusCode: 419,
            headers: const {},
            body: Stream<List<int>>.fromFuture(
              Future(() async {
                await notifier.signOut();
                return <int>[1];
              }),
            ),
          );
        });
        await expectLater(
          sessionOver(inner).send(get(orders)),
          throwsA(isA<AuthRejected>()),
        );
        expect(
          inner.requests,
          hasLength(1),
          reason: 'the replay would have carried no credential',
        );
      },
    );

    test(
      'another user signing in while a refused response is drained: the replay is not sent as them',
      () async {
        setUpTransport();
        authenticator().verdict = (_, _, status, _, _, _) =>
            status == 419 ? const Resend() : const Accept();
        final notifier = container.read(authSession.notifier);
        final inner = FakeTransport((request, _) {
          return TransportResponse(
            statusCode: 419,
            headers: const {},
            body: Stream<List<int>>.fromFuture(
              Future(() async {
                await notifier.adopt(fakeSession(bob));
                return <int>[1];
              }),
            ),
          );
        });
        await expectLater(
          sessionOver(inner).send(get(orders)),
          throwsA(isA<AuthRejected>()),
        );
        expect(inner.requests, hasLength(1));
        expect(
          container.read(authUserId),
          'bob-id',
          reason: 'bob stays signed in',
        );
      },
    );
  });

  // What a retrier above the session relies on: the second send of one logical request (the same
  // TransportMemo) is the same request, not a fresh one.
  group('a request sent again with the same memo', () {
    TransportRequest again(TransportMemo memo) => get(
      orders,
    ).copyWith(attributes: <String, Object?>{TransportMemo.key: memo});

    test('whose renewal was refused is refused again with the same error, '
        'without a renewal or a send, even after a sign-in', () async {
      setUpTransport(credentialLifetime: const Duration(seconds: -1));
      backend.renewError = const AuthRejected();
      final memo = TransportMemo();
      final session = transport();
      final first = await session
          .send(again(memo))
          .then<Object>((_) => 'sent', onError: (Object e) => e);
      expect(first, isA<AuthRejected>());
      expect(backend.renewals, 1);
      final second = await session
          .send(again(memo))
          .then<Object>((_) => 'sent', onError: (Object e) => e);
      expect(second, same(first));
      // Another user signs in: the refused request stays refused.
      backend
        ..renewError = null
        ..credentialLifetime = null;
      await container.read(authSession.notifier).adopt(fakeSession(bob));
      await expectLater(session.send(again(memo)), throwsA(same(first)));
      expect(backend.renewals, 1);
      expect(server.seen, isEmpty);
      // A request with another memo is another request.
      await session.send(get(orders));
      expect(server.seen, isNotEmpty);
    });

    test('that had the session is not sent without it (a sign-out)', () async {
      setUpTransport();
      server.good = 'fake-0';
      final memo = TransportMemo();
      final session = transport();
      expect((await session.send(again(memo))).statusCode, 200);
      await container.read(authSession.notifier).signOut();
      await expectLater(
        session.send(again(memo)),
        throwsA(isA<AuthRejected>()),
      );
      expect(server.seen, hasLength(1));
      expect(backend.renewals, 0);
    });

    test('that was made for one user is not sent as another', () async {
      setUpTransport();
      server.good = 'fake-0';
      final memo = TransportMemo();
      final session = transport();
      expect((await session.send(again(memo))).statusCode, 200);
      final notifier = container.read(authSession.notifier);
      await notifier.signOut();
      await notifier.adopt(fakeSession(bob));
      await expectLater(
        session.send(again(memo)),
        throwsA(isA<AuthRejected>()),
      );
      expect(server.seen, hasLength(1));
      expect(container.read(authUserId), 'bob-id');
    });

    test('that could not get the session (AuthUnavailable) is not refused for '
        'good: the next send may work', () async {
      setUpTransport(credentialLifetime: const Duration(seconds: -1));
      backend.renewError = AuthUnavailable(StateError('offline'));
      final memo = TransportMemo();
      final session = transport();
      await expectLater(
        session.send(again(memo)),
        throwsA(isA<AuthUnavailable>()),
      );
      backend
        ..renewError = null
        ..credentialLifetime = null;
      server.good = 'fake-1';
      expect((await session.send(again(memo))).statusCode, 200);
    });

    test('that could not get the session (AuthUnavailable) is held to the user '
        'who wanted it: it is not sent as another', () async {
      setUpTransport(credentialLifetime: const Duration(seconds: -1));
      backend.renewError = AuthUnavailable(StateError('offline'));
      final memo = TransportMemo();
      final session = transport();
      await expectLater(
        session.send(again(memo)),
        throwsA(isA<AuthUnavailable>()),
      );
      final notifier = container.read(authSession.notifier);
      await notifier.signOut();
      await notifier.adopt(fakeSession(bob));
      await expectLater(
        session.send(again(memo)),
        throwsA(isA<AuthRejected>()),
      );
      expect(server.seen, isEmpty);
    });

    test('renews once: a second send of the request finds the renewal spent '
        'and gets the 401', () async {
      setUpTransport();
      server.good = 'nobody';
      final memo = TransportMemo();
      final session = transport();
      expect((await session.send(again(memo))).statusCode, 401);
      expect(backend.renewals, 1);
      expect(server.seen, hasLength(2), reason: 'the send and its replay');
      expect((await session.send(again(memo))).statusCode, 401);
      expect(backend.renewals, 1);
      expect(server.seen, hasLength(3), reason: 'no second replay');
      // Another request has a renewal of its own.
      expect((await session.send(get(orders))).statusCode, 401);
      expect(backend.renewals, 2);
    });

    test('with no memo at all, every send is a request seen once', () async {
      setUpTransport();
      server.good = 'fake-0';
      final session = transport();
      expect((await session.send(get(orders))).statusCode, 200);
      await container.read(authSession.notifier).signOut();
      expect((await session.send(get(orders))).statusCode, 401);
      expect(server.ids.last, isNull);
    });
  });

  group('the inner transport fails', () {
    test('a failure on the first send propagates as it is', () async {
      setUpTransport();
      final inner = FakeTransport.script([const TransportBroken('reset')]);
      await expectLater(
        sessionOver(inner).send(get(orders)),
        throwsA(
          isA<TransportBroken>().having((e) => e.cause, 'cause', 'reset'),
        ),
      );
      expect(container.read(authSession), isA<SignedIn>());
      expect(
        authenticator().judged,
        isEmpty,
        reason: 'there was no response to judge',
      );
    });

    test('every kind of failure propagates', () async {
      setUpTransport();
      for (final failure in <TransportFailure>[
        const TransportUnsent(),
        const TransportTimedOut(),
        const TransportAborted(),
        const TransportBroken(),
      ]) {
        final inner = FakeTransport.script([failure]);
        await expectLater(
          sessionOver(inner).send(get(orders)),
          throwsA(same(failure)),
        );
      }
    });

    test(
      'a failure on the replay propagates, and the renewal stands',
      () async {
        setUpTransport();
        final inner = FakeTransport.script([
          fakeResponse(401),
          const TransportUnsent(),
        ]);
        await expectLater(
          sessionOver(inner).send(get(orders)),
          throwsA(isA<TransportUnsent>()),
        );
        expect(backend.renewals, 1);
        expect(container.read(authSession), isA<SignedIn>());
        expect(inner.requests, hasLength(2));
      },
    );
  });
}

/// An authenticator that signs only requests whose bytes it knows: `x-bytes` is their length.
final class _NeedsBytes implements RequestAuthenticator {
  @override
  Future<Map<String, String>> headers(
    AuthSession session,
    TransportRequest request,
  ) async {
    final body = request.body;
    if (body == null && request.bodyStream != null) {
      throw ArgumentError('this scheme signs the bytes of the body');
    }
    return {'x-bytes': '${body?.length ?? 0}'};
  }

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

final class _NeedsBytesBackend extends StubBackend {
  _NeedsBytesBackend();

  @override
  RequestAuthenticator get authenticator => _NeedsBytes();
}
