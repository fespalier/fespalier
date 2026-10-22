// The session on a Dio: TransportAdapter(SessionTransport(api, authorizer)), with the API a
// FakeTransport. The policy the old SessionInterceptor had, on the types of the new stack: what
// is signed, what is replayed, what happens to a body, who may be sent as whom. Plain test(): Dio
// starts its chain with Timer.run.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_support.dart';

void main() {
  test(
    'a request to an API origin carries the session, any other goes untouched',
    () async {
      final rig = SessionRig(scripted([200, 200]));
      final dio = rig.dio(retries: false);
      expect((await dio.get<String>(orders)).data, 'x');
      expect((await dio.get<String>(other)).data, 'x');
      expect(rig.signatures, ['fake-0#1', null]);
      expect(rig.authenticator.signed, hasLength(1));
      expect(rig.backend.renewals, 0);
    },
  );

  test('only the origin counts: scheme, host and port', () async {
    final rig = SessionRig(scripted([200, 200, 200]));
    final dio = rig.dio(retries: false);
    await dio.get<String>('http://api.example.com/orders');
    await dio.get<String>('https://api.example.com:8443/orders');
    await dio.get<String>('https://api.example.com/orders?page=2#top');
    expect(rig.signatures, [null, null, 'fake-0#1']);
  });

  test(
    'signed out: no signature, nothing is renewed, a 401 is the answer',
    () async {
      final rig = SessionRig(always(401), signedInAs: null);
      final error = await dioFailure(
        rig.dio(retries: false).get<String>(orders),
      );
      expect(error.response?.statusCode, 401);
      expect(rig.signatures, [null]);
      expect(rig.sent, hasLength(1));
      expect(rig.backend.renewals, 0);
      expect(rig.authenticator.judged, isEmpty);
    },
  );

  test(
    'the signature is added to the send, not to the options: a request sent again '
    'with the same options is signed again, and keeps none of the first',
    () async {
      final rig = SessionRig(scripted([200, 200]));
      final dio = rig.dio(retries: false);
      final options = RequestOptions(path: orders);
      expect((await dio.fetch<String>(options)).statusCode, 200);
      expect((await dio.fetch<String>(options)).statusCode, 200);
      expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
      expect(
        options.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains(signature)),
      );
      expect(options.extra, isNot(contains(transportReplayKey)));
    },
  );

  group('a 401', () {
    test(
      'renews once and sends the request again, marked as a replay',
      () async {
        final rig = SessionRig(scripted([401, 200]));
        final response = await rig.dio(retries: false).get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-1#2']);
        expect(rig.replays, [false, true]);
        expect(rig.backend.renewals, 1);
        expect(rig.authenticator.judged, [401, 200]);
      },
    );

    test('a second 401 is returned as it is: no loop', () async {
      final rig = SessionRig(always(401));
      final error = await dioFailure(
        rig.dio(retries: false).get<String>(orders),
      );
      expect(error.response?.statusCode, 401);
      expect(rig.sent, hasLength(2));
      expect(rig.backend.renewals, 1);
    });

    test(
      'the 401 body is handed on whole to the caller that gets it',
      () async {
        final rig = SessionRig(
          FakeTransport((request, body) => fakeResponse(401, body: 'go away')),
        );
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.response?.data, 'go away');
      },
    );

    test(
      'the authenticator reads the body of a 401 it judges, and of nothing else',
      () async {
        final seen = <String?>[];
        final rig = SessionRig(scripted([401, 200]));
        rig.authenticator.verdict =
            (session, request, status, headers, body, retried) {
              seen.add(body);
              return status == 401 ? const Renew() : const Accept();
            };
        await rig.dio(retries: false).get<String>(orders);
        // Only a 401 or a 403 is read before the authenticator is asked.
        expect(seen, ['x', null]);
      },
    );

    test(
      'a 403 is judged too, and stands unless the authenticator says otherwise',
      () async {
        final rig = SessionRig(always(403));
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.response?.statusCode, 403);
        expect(rig.sent, hasLength(1));
        expect(rig.authenticator.judged, [403]);
        expect(rig.backend.renewals, 0);
      },
    );

    test(
      'with validateStatus accepting it, the 401 after the replay is the answer',
      () async {
        final rig = SessionRig(always(401));
        final response = await rig
            .dio(retries: false)
            .get<String>(orders, options: Options(validateStatus: (_) => true));
        expect(response.statusCode, 401);
        expect(rig.sent, hasLength(2));
        expect(rig.backend.renewals, 1);
      },
    );

    test(
      'where the renewal is refused: the 401, and the user is signed out',
      () async {
        final rig = SessionRig(always(401));
        rig.backend.renewError = const AuthRejected();
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.response?.statusCode, 401);
        expect(rig.sent, hasLength(1));
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
      },
    );

    test(
      'where the renewal ends the session for another reason (AuthEnded): that '
      'reason is the state',
      () async {
        final rig = SessionRig(always(401));
        rig.backend.renewError = const AuthEnded(SignOutReason.revoked);
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.response?.statusCode, 401);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
      },
    );

    test(
      'where the renewal cannot run: the error is AuthUnavailable, the session stays',
      () async {
        final rig = SessionRig(always(401));
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.error, isA<AuthUnavailable>());
        expect(rig.container.read(authSession), isA<SignedIn>());
        expect(rig.sent, hasLength(1));
      },
    );

    test('two requests that get a 401 together share one renewal', () async {
      final rig = SessionRig(
        FakeTransport(
          (request, body) => fakeResponse(
            request.headers[signature]!.startsWith('fake-1') ? 200 : 401,
          ),
        ),
      );
      rig.backend.gate = Completer<void>();
      final dio = rig.dio(retries: false);
      final a = dio.get<String>(orders);
      final b = dio.get<String>('$orders/1');
      await pumpEventQueue();
      rig.backend.gate!.complete();
      final responses = await Future.wait([a, b]);
      expect(responses.map((r) => r.statusCode), [200, 200]);
      expect(rig.backend.renewals, 1);
    });

    test(
      'the user signs out while the 401 is read: it stands, and nothing is replayed',
      () async {
        late final SessionRig rig;
        rig = SessionRig(
          FakeTransport((request, body) {
            unawaited(rig.notifier.signOut());
            return fakeResponse(401);
          }),
        );
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.response?.statusCode, 401);
        expect(rig.sent, hasLength(1));
        expect(rig.backend.renewals, 0);
      },
    );
  });

  group('the verdict of the authenticator', () {
    AuthVerdict nonceThenRenew(
      AuthSession session,
      TransportRequest request,
      int status,
      Map<String, String> headers,
      String? body,
      bool retried,
    ) {
      if (status != 401) return const Accept();
      return headers.containsKey('x-nonce') ? const Resend() : const Renew();
    }

    TransportResponse challenge() =>
        fakeResponse(401, headers: {'X-Nonce': 'n1'});

    test(
      'a Resend sends the request again once, with no renewal, marked as a replay',
      () async {
        final rig = SessionRig(scripted([challenge(), 200]));
        rig.authenticator.verdict = nonceThenRenew;
        final response = await rig.dio(retries: false).get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
        expect(rig.replays, [false, true]);
        expect(rig.backend.renewals, 0);
      },
    );

    test('a second Resend is not followed: the answer stands', () async {
      final rig = SessionRig(scripted([challenge(), challenge()]));
      rig.authenticator.verdict = nonceThenRenew;
      final error = await dioFailure(
        rig.dio(retries: false).get<String>(orders),
      );
      expect(error.response?.statusCode, 401);
      expect(rig.sent, hasLength(2));
      expect(rig.backend.renewals, 0);
    });

    test('a nonce challenge then a 401: each answered once', () async {
      final rig = SessionRig(scripted([challenge(), 401, 200]));
      rig.authenticator.verdict = nonceThenRenew;
      final response = await rig.dio(retries: false).get<String>(orders);
      expect(response.statusCode, 200);
      expect(rig.signatures, ['fake-0#1', 'fake-0#2', 'fake-1#3']);
      expect(rig.replays, [false, true, true]);
      expect(rig.backend.renewals, 1);
    });

    test('a 401 then a challenge: each answered once', () async {
      final rig = SessionRig(scripted([401, challenge(), 200]));
      rig.authenticator.verdict = nonceThenRenew;
      final response = await rig.dio(retries: false).get<String>(orders);
      expect(response.statusCode, 200);
      expect(rig.signatures, ['fake-0#1', 'fake-1#2', 'fake-1#3']);
      expect(rig.backend.renewals, 1);
    });

    test(
      'a verdict on a status that is not 401 or 403 is asked for too',
      () async {
        final rig = SessionRig(scripted([428, 200]));
        rig.authenticator.verdict =
            (session, request, status, headers, body, retried) =>
                status == 428 ? const Resend() : const Accept();
        final response = await rig.dio(retries: false).get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.authenticator.judged, [428, 200]);
        expect(rig.sent, hasLength(2));
      },
    );

    test(
      'the authenticator is told when a send already followed a verdict',
      () async {
        final retried = <bool>[];
        final rig = SessionRig(scripted([401, 401]));
        rig.authenticator.verdict =
            (session, request, status, headers, body, wasRetried) {
              retried.add(wasRetried);
              return status == 401 ? const Renew() : const Accept();
            };
        await dioFailure(rig.dio(retries: false).get<String>(orders));
        expect(retried, [false, true]);
      },
    );

    test(
      'SessionEnded: signed out with the reason, the backend forgets the session, '
      'AuthRejected is the error',
      () async {
        final rig = SessionRig(always(401));
        rig.authenticator.verdict =
            (session, request, status, headers, body, retried) =>
                const SessionEnded(SignOutReason.revoked);
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(rig.sent, hasLength(1));
        expect(rig.backend.discards, 1);
        expect(rig.backend.renewals, 0);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
      },
    );

    test(
      'SessionEnded for a user who has been replaced does not end the new session',
      () async {
        late final SessionRig rig;
        rig = SessionRig(
          FakeTransport((request, body) async {
            // The answer to ada's request arrives after bob signed in.
            await rig.switchTo(bob);
            return fakeResponse(401);
          }),
        );
        rig.authenticator.verdict =
            (session, request, status, headers, body, retried) =>
                const SessionEnded(SignOutReason.revoked);
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(rig.container.read(authUserId), 'bob-id');
        expect(rig.container.read(authSession), isA<SignedIn>());
      },
    );

    test('a session that ended is simply not attached on a later send', () async {
      // What authRefusedKey and authWantedKey (SessionInterceptor) tracked per request is gone:
      // the session attaches what is signed in at the time of each send, and nothing when nobody is.
      final rig = SessionRig(scripted([200]));
      final dio = rig.dio(retries: false);
      final options = RequestOptions(path: orders);
      await rig.notifier.endSession(SignOutReason.revoked);
      expect((await dio.fetch<String>(options)).statusCode, 200);
      expect(rig.signatures, [null]);
      expect(rig.authenticator.signed, isEmpty);
    });
  });

  group('a body', () {
    test('a JSON map is sent again whole', () async {
      final rig = SessionRig(scripted([401, 200]));
      final response = await rig
          .dio(retries: false)
          .post<String>(orders, data: {'item': 1});
      expect(response.statusCode, 200);
      final expected = utf8.encode('{"item":1}');
      expect(rig.sent.map((s) => s.body), [expected, expected]);
      expect(rig.authenticator.signed.map((r) => r.body), [expected, expected]);
      expect(rig.sent.map((s) => s.lowerHeaders['content-type']), [
        startsWith('application/json'),
        startsWith('application/json'),
      ]);
    });

    test('a body of bytes is sent again whole', () async {
      final rig = SessionRig(scripted([401, 200]));
      final response = await rig
          .dio(retries: false)
          .post<String>(orders, data: Uint8List.fromList(utf8.encode('item')));
      expect(response.statusCode, 200);
      expect(rig.sent.map((s) => s.body), [
        utf8.encode('item'),
        utf8.encode('item'),
      ]);
      expect(rig.backend.renewals, 1);
    });

    test(
      'FormData is sent again whole too: Dio finalizes it into bytes the session can '
      'replay (SessionInterceptor could not)',
      () async {
        final rig = SessionRig(scripted([401, 200]));
        final form = FormData.fromMap({
          'note': 'x',
          'file': MultipartFile.fromBytes(
            utf8.encode('payload'),
            filename: 'p.txt',
          ),
        });
        final response = await rig
            .dio(retries: false)
            .post<String>(orders, data: form);
        expect(response.statusCode, 200);
        expect(rig.sent, hasLength(2));
        expect(rig.sent[1].body, rig.sent[0].body);
        expect(rig.sent[0].text, contains('payload'));
        expect(rig.authenticator.signed.map((r) => r.body), [
          rig.sent[0].body,
          rig.sent[0].body,
        ]);
        expect(rig.backend.renewals, 1);
      },
    );

    test('a request without a body has none, on every send', () async {
      final rig = SessionRig(scripted([401, 200]));
      await rig.dio(retries: false).get<String>(orders);
      expect(rig.sent.map((s) => s.request.body), [isNull, isNull]);
      expect(rig.sent.map((s) => s.request.bodyStream), [isNull, isNull]);
      expect(rig.authenticator.signed.map((r) => r.body), [isNull, isNull]);
    });

    group('that is a stream', () {
      Stream<Uint8List> body() =>
          Stream<Uint8List>.value(Uint8List.fromList(utf8.encode('item')));

      test(
        'is not sent again: the caller gets the 401, after the renewal',
        () async {
          final rig = SessionRig(scripted([401, 200]));
          final dio = rig.dio(retries: false);
          final error = await dioFailure(
            dio.post<String>(orders, data: body()),
          );
          expect(error.response?.statusCode, 401);
          expect(
            error.error,
            isNull,
            reason: 'a status, not a failure of its own',
          );
          expect(rig.sent, hasLength(1));
          expect(rig.sent.single.body, utf8.encode('item'));
          expect(
            rig.backend.renewals,
            1,
            reason: 'so that its next attempt works',
          );
          expect((await dio.get<String>(orders)).statusCode, 200);
          expect(rig.signatures.last, 'fake-1#2');
        },
      );

      test(
        'with a client that takes a 401 as an answer, it is the answer',
        () async {
          final rig = SessionRig(scripted([401, 200]));
          final response = await rig
              .dio(retries: false)
              .post<String>(
                orders,
                data: body(),
                options: Options(validateStatus: (_) => true),
              );
          expect(response.statusCode, 401);
          expect(rig.sent, hasLength(1));
          expect(rig.backend.renewals, 1);
        },
      );

      test(
        'is signed as no bytes: the authenticator is asked without them',
        () async {
          final rig = SessionRig(scripted([200]));
          await rig.dio(retries: false).post<String>(orders, data: body());
          expect(rig.authenticator.signed.single.body, isNull);
          expect(rig.authenticator.signed.single.bodyStream, isNotNull);
          expect(rig.authenticator.signed.single.replayable, isFalse);
        },
      );
    });
  });

  group('who a request is sent as', () {
    test(
      'a request replayed after the user switched is refused, not sent as the new user',
      () async {
        late final SessionRig rig;
        rig = SessionRig(
          FakeTransport((request, body) async {
            // The 401 to ada's request arrives after ada signed out and bob signed in.
            await rig.switchTo(bob);
            return fakeResponse(401);
          }),
        );
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(rig.sent, hasLength(1));
        await pumpEventQueue();
        expect(rig.container.read(authUserId), 'bob-id');
      },
    );

    test('a replay is not sent without the session it had (the user signed out '
        'while the answer was read)', () async {
      late final SessionRig rig;
      rig = SessionRig(scripted([challengeBody(), 200]));
      rig.authenticator.verdict =
          (session, request, status, headers, body, retried) {
            unawaited(rig.notifier.signOut());
            return status == 401 ? const Resend() : const Accept();
          };
      final error = await dioFailure(
        rig.dio(retries: false).get<String>(orders),
      );
      expect(error.error, isA<AuthRejected>());
      expect(rig.sent, hasLength(1));
    });

    test(
      'a credential that expired is renewed before the send, once for the requests that '
      'find it expired together',
      () async {
        final rig = SessionRig(
          scripted([200, 200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend
          ..credentialLifetime = null
          ..gate = Completer<void>();
        final dio = rig.dio(retries: false);
        final a = dio.get<String>(orders);
        final b = dio.get<String>('$orders/2');
        await pumpEventQueue();
        expect(rig.sent, isEmpty, reason: 'nothing is sent before the renewal');
        rig.backend.gate!.complete();
        await Future.wait([a, b]);
        expect(rig.backend.renewals, 1);
        expect(rig.signatures.map((s) => s!.split('#').first), [
          'fake-1',
          'fake-1',
        ]);
      },
    );

    test(
      'a renewal refused before the send: AuthRejected, nothing reaches the API',
      () async {
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = const AuthRejected();
        final error = await dioFailure(
          rig.dio(retries: false).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(error.type, DioExceptionType.unknown);
        expect(rig.sent, isEmpty);
        expect(rig.backend.renewals, 1);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
      },
    );

    test(
      'a renewal that cannot run before the send: AuthUnavailable, the session stays, '
      'and the next send asks again',
      () async {
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final dio = rig.dio(retries: false);
        final error = await dioFailure(dio.get<String>(orders));
        expect(error.error, isA<AuthUnavailable>());
        expect(rig.sent, isEmpty);
        expect(rig.container.read(authSession), isA<SignedIn>());
        rig.backend
          ..renewError = null
          ..credentialLifetime = null;
        expect((await dio.get<String>(orders)).statusCode, 200);
        expect(rig.signatures, ['fake-1#1']);
      },
    );
  });

  test('the replay mark is a constant a write guard can read', () {
    expect(transportReplayKey, 'fespalier.auth.replay');
  });
}

/// A 401 with a body, to tell the authenticator apart from the plain ones.
TransportResponse challengeBody() => fakeResponse(401, body: 'challenge');
