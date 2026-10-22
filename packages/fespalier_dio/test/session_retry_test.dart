// The real session (fespalier_auth's SessionTransport) under dio_smart_retry, behind WriteGuard:
// every send is signed afresh, and a write is never sent twice but for the one replay a 401 earns.
//
//   Dio + WriteGuard + RetryInterceptor -> TransportAdapter(SessionTransport(api, authorizer))
//
// A retry by Dio calls the adapter again, which sends through the session again: each send is
// authorized with the final bytes of its body. Plain test(): Dio starts its chain with Timer.run.
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
  group('every send is signed afresh', () {
    test(
      'a 503 then a 200: two sends, two signatures, the same credential, no renewal',
      () async {
        final rig = SessionRig(scripted([503, 200]));
        final response = await rig.dio().get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
        expect(rig.replays, [false, false]);
        expect(rig.backend.renewals, 0);
        expect(rig.authenticator.signed, hasLength(2));
      },
    );

    test(
      'three 503s and a 200: four sends, four signatures, none marked a replay',
      () async {
        final rig = SessionRig(scripted([503, 503, 503, 200]));
        final response = await rig.dio().get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, [
          'fake-0#1',
          'fake-0#2',
          'fake-0#3',
          'fake-0#4',
        ]);
        expect(rig.replays, [false, false, false, false]);
        expect(rig.backend.renewals, 0);
      },
    );

    test(
      'a 401: one renewal, one replay with the new credential and a new signature',
      () async {
        final rig = SessionRig(scripted([401, 200]));
        final response = await rig.dio().get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-1#2']);
        expect(rig.replays, [false, true]);
        expect(rig.backend.renewals, 1);
      },
    );

    test(
      'a 401, a 503 on the replay, then a 200: the retry keeps the renewed credential',
      () async {
        final rig = SessionRig(scripted([401, 503, 200]));
        final response = await rig.dio().get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-1#2', 'fake-1#3']);
        // The retrier's send is a new request for the session: it is no replay.
        expect(rig.replays, [false, true, false]);
        expect(rig.backend.renewals, 1);
      },
    );

    test(
      'a 503, then a 401, then a 200: the replay follows the retry',
      () async {
        final rig = SessionRig(scripted([503, 401, 200]));
        final response = await rig.dio().get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2', 'fake-1#3']);
        expect(rig.replays, [false, false, true]);
        expect(rig.backend.renewals, 1);
      },
    );

    test(
      'a 401 then a 401: one renewal, and the second 401 is the answer',
      () async {
        final rig = SessionRig(scripted([401, 401]));
        final error = await dioFailure(rig.dio().get<String>(orders));
        expect(error.response?.statusCode, 401);
        expect(rig.sent, hasLength(2));
        expect(rig.backend.renewals, 1);
      },
    );

    test('a 401, a 503 on the replay, then a 401 on its retry: one renewal for the '
        'whole request, and that 401 is the answer', () async {
      // The renewal is the logical request's, not the send's (TransportMemo): the retrier's
      // second send finds it spent, so its 401 stands and is not replayed. Before the memo,
      // this renewed twice.
      final rig = SessionRig(scripted([401, 503, 401]));
      final error = await dioFailure(rig.dio().get<String>(orders));
      expect(error.response?.statusCode, 401);
      expect(rig.sent, hasLength(3));
      expect(rig.replays, [false, true, false]);
      expect(rig.signatures, ['fake-0#1', 'fake-1#2', 'fake-1#3']);
      expect(rig.backend.renewals, 1);
    });

    test(
      'a GET that fails with a broken exchange is retried with a new signature, '
      'and so is a timeout',
      () async {
        final rig = SessionRig(
          scripted([const TransportBroken(), const TransportTimedOut(), 200]),
        );
        final response = await rig.dio().get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2', 'fake-0#3']);
        expect(rig.backend.renewals, 0);
      },
    );

    test(
      'two reads that both get a 401 share one renewal, and each is replayed '
      'once',
      () async {
        final rig = SessionRig(
          FakeTransport(
            (request, body) => fakeResponse(
              request.headers[signature]!.startsWith('fake-1') ? 200 : 401,
              body: 'x',
            ),
          ),
        );
        rig.backend.gate = Completer<void>();
        final dio = rig.dio();
        final a = dio.get<String>(orders);
        final b = dio.get<String>('$orders/2');
        await pumpEventQueue();
        rig.backend.gate!.complete();
        final both = await Future.wait([a, b]);
        expect(both.map((r) => r.statusCode), [200, 200]);
        expect(rig.sent, hasLength(4));
        expect(
          rig.signatures.toSet(),
          hasLength(4),
          reason: 'all four signed afresh',
        );
        expect(rig.replays.where((r) => r), hasLength(2));
        expect(rig.backend.renewals, 1);
      },
    );
  });

  group('a write is never sent twice, but for the replay of a 401', () {
    for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
      test('$method: a 503 is the answer, sent once', () async {
        final rig = SessionRig(scripted([503, 200]));
        final error = await dioFailure(
          rig.dio().request<String>(
            orders,
            data: 'x',
            options: Options(method: method),
          ),
        );
        expect(error.response?.statusCode, 503);
        expect(rig.sent, hasLength(1));
        expect(rig.backend.renewals, 0);
      });
    }

    test(
      'a POST that fails with a broken exchange is not sent again',
      () async {
        final rig = SessionRig(scripted([const TransportBroken(), 200]));
        final error = await dioFailure(
          rig.dio().post<String>(orders, data: 'x'),
        );
        expect(error.error, isA<TransportBroken>());
        expect(rig.sent, hasLength(1));
      },
    );

    test(
      'a POST that is refused with a 401 is renewed and replayed once, marked '
      'as a replay',
      () async {
        final rig = SessionRig(scripted([401, 200]));
        final response = await rig.dio().post<String>(orders, data: 'x');
        expect(response.statusCode, 200);
        expect(rig.sent, hasLength(2));
        expect(rig.signatures, ['fake-0#1', 'fake-1#2']);
        expect(rig.replays, [false, true]);
        expect(rig.sent[1].request.attributes[transportReplayKey], isTrue);
        expect(rig.backend.renewals, 1);
      },
    );

    test('a write: a 401 is replayed once and a 503 on the replay is not '
        'retried', () async {
      final rig = SessionRig(scripted([401, 503, 200]));
      final error = await dioFailure(rig.dio().put<String>(orders, data: 'x'));
      expect(error.response?.statusCode, 503);
      expect(rig.sent, hasLength(2));
      expect(rig.replays, [false, true]);
      expect(rig.backend.renewals, 1);
    });

    test('WriteGuard alone stops a PUT after the session replayed it: a plain '
        'evaluator would retry the 503', () async {
      final rig = SessionRig(scripted([401, 503, 200]));
      final error = await dioFailure(
        rig
            .dio(readsOnly: false, evaluator: defaultRetries)
            .put<String>(orders, data: 'x'),
      );
      expect(
        error.response?.statusCode,
        503,
        reason: 'the first error is handed back',
      );
      expect(rig.sent, hasLength(2));
      expect(rig.backend.renewals, 1);
    });

    test(
      'without WriteGuard, a plain evaluator would send the PUT a third time '
      '(what the guard is for)',
      () async {
        final rig = SessionRig(scripted([401, 503, 200]));
        final response = await rig
            .dio(readsOnly: false, guard: false, evaluator: defaultRetries)
            .put<String>(orders, data: 'x');
        expect(response.statusCode, 200);
        expect(rig.sent, hasLength(3));
      },
    );

    test('a write with an Idempotency-Key is retried after a 503, with a new '
        'signature', () async {
      final rig = SessionRig(scripted([503, 200]));
      final response = await rig.dio().put<String>(
        orders,
        data: 'x',
        options: Options(headers: {'Idempotency-Key': 'k1'}),
      );
      expect(response.statusCode, 200);
      expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
      expect(rig.sent.map((s) => s.lowerHeaders['idempotency-key']), [
        'k1',
        'k1',
      ]);
    });
  });

  group('a body reaches the API as the same bytes on every send, and is signed '
      'as those bytes', () {
    final jsonBody = utf8.encode(jsonEncode({'item': 1, 'note': 'é'}));
    final cases = <String, ({Object data, List<int> bytes})>{
      'a JSON map': (data: {'item': 1, 'note': 'é'}, bytes: jsonBody),
      'a String': (data: 'hello é', bytes: utf8.encode('hello é')),
      'a Uint8List': (
        data: Uint8List.fromList([0, 1, 2, 250, 255]),
        bytes: [0, 1, 2, 250, 255],
      ),
    };

    for (final entry in cases.entries) {
      test('${entry.key}: replayed after a 401', () async {
        final rig = SessionRig(scripted([401, 200]));
        final response = await rig.dio().post<String>(
          orders,
          data: entry.value.data,
          options: entry.key == 'a Uint8List'
              ? Options(contentType: 'application/octet-stream')
              : null,
        );
        expect(response.statusCode, 200);
        expect(rig.sent.map((s) => s.body), [
          entry.value.bytes,
          entry.value.bytes,
        ]);
        expect(rig.authenticator.signed.map((r) => r.body), [
          entry.value.bytes,
          entry.value.bytes,
        ]);
        expect(rig.signatures, ['fake-0#1', 'fake-1#2']);
      });

      test(
        '${entry.key}: re-sent by the retrier (an Idempotency-Key write)',
        () async {
          final rig = SessionRig(scripted([503, 200]));
          final response = await rig.dio().post<String>(
            orders,
            data: entry.value.data,
            options: Options(
              headers: {'Idempotency-Key': 'k1'},
              contentType: entry.key == 'a Uint8List'
                  ? 'application/octet-stream'
                  : null,
            ),
          );
          expect(response.statusCode, 200);
          expect(rig.sent.map((s) => s.body), [
            entry.value.bytes,
            entry.value.bytes,
          ]);
          expect(rig.authenticator.signed.map((r) => r.body), [
            entry.value.bytes,
            entry.value.bytes,
          ]);
          expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
        },
      );
    }

    FormData form() => FormData.fromMap({
      'note': 'hello',
      'file': MultipartFile.fromBytes(
        utf8.encode('file-content'),
        filename: 'a.txt',
      ),
    });

    String boundaryOf(SentRequest sent) {
      final type = sent.lowerHeaders['content-type']!;
      expect(type, startsWith('multipart/form-data; boundary='));
      return type.substring(type.indexOf('boundary=') + 'boundary='.length);
    }

    test(
      'FormData with a field and a file: the same bytes after a 401',
      () async {
        final rig = SessionRig(scripted([401, 200]));
        final response = await rig.dio().post<String>(orders, data: form());
        expect(response.statusCode, 200);
        expect(rig.sent, hasLength(2));
        final first = rig.sent[0].body;
        expect(first, isNotEmpty);
        expect(rig.sent[1].body, first, reason: 'the replay is the same bytes');
        expect(rig.authenticator.signed.map((r) => r.body), [first, first]);
        final text = rig.sent[0].text;
        expect(text, contains('name="note"'));
        expect(text, contains('hello'));
        expect(text, contains('filename="a.txt"'));
        expect(text, contains('file-content'));
        expect(text, startsWith('--${boundaryOf(rig.sent[0])}'));
        expect(boundaryOf(rig.sent[1]), boundaryOf(rig.sent[0]));
      },
    );

    test(
      'FormData re-sent by the retrier (an Idempotency-Key write): each send is '
      'signed as the bytes it carries, under the boundary it declares',
      () async {
        // dio_smart_retry clones a FormData before it sends it again, which gives it a new
        // boundary: the bytes differ between the two sends, and each one is consistent.
        final rig = SessionRig(scripted([503, 200]));
        final response = await rig.dio().post<String>(
          orders,
          data: form(),
          options: Options(headers: {'Idempotency-Key': 'k1'}),
        );
        expect(response.statusCode, 200);
        expect(rig.sent, hasLength(2));
        for (var i = 0; i < 2; i++) {
          final sent = rig.sent[i];
          expect(rig.authenticator.signed[i].body, sent.body);
          expect(sent.text, startsWith('--${boundaryOf(sent)}'));
          expect(sent.text, contains('hello'));
          expect(sent.text, contains('file-content'));
        }
        expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
      },
    );

    test('a streamed body is sent once: the caller gets the 401, after the '
        'renewal, and signed as no bytes', () async {
      final rig = SessionRig(scripted([401, 200, 200]));
      final dio = rig.dio();
      final error = await dioFailure(
        dio.post<String>(
          orders,
          data: Stream<Uint8List>.value(
            Uint8List.fromList(utf8.encode('item')),
          ),
          options: Options(headers: {Headers.contentLengthHeader: '4'}),
        ),
      );
      expect(error.response?.statusCode, 401);
      expect(rig.sent, hasLength(1));
      expect(rig.sent.single.body, utf8.encode('item'));
      expect(rig.sent.single.request.contentLength, 4);
      expect(rig.authenticator.signed.single.body, isNull);
      expect(rig.backend.renewals, 1, reason: 'so that its next attempt works');
      expect((await dio.get<String>(orders)).statusCode, 200);
      expect(rig.signatures.last, 'fake-1#2');
    });

    test('a streamed body is sent once with a client that takes a 401 as an '
        'answer', () async {
      final rig = SessionRig(scripted([401, 200]));
      final response = await rig.dio().post<String>(
        orders,
        data: Stream<Uint8List>.value(Uint8List.fromList(utf8.encode('item'))),
        options: Options(
          headers: {Headers.contentLengthHeader: '4'},
          validateStatus: (_) => true,
        ),
      );
      expect(response.statusCode, 401);
      expect(rig.sent, hasLength(1));
      expect(rig.backend.renewals, 1);
    });
  });

  group('when the session cannot answer', () {
    test('a renewal refused before the send: the call fails with AuthRejected, '
        'nothing reaches the API', () async {
      final rig = SessionRig(
        scripted([200]),
        credentialLifetime: const Duration(seconds: -1),
      );
      rig.backend.renewError = const AuthRejected();
      final error = await dioFailure(rig.dio().get<String>(orders));
      expect(error.error, isA<AuthRejected>());
      expect(rig.sent, isEmpty);
      expect(
        rig.backend.renewals,
        1,
        reason: 'a retrier that skips AuthRejected asks once',
      );
      expect(
        rig.container.read(authSession),
        const SignedOut(reason: SignOutReason.expired),
      );
    });

    test(
      'a retrier that retries an AuthRejected (the default evaluator does) gets the '
      'same refusal each time: no renewal, no send, never unauthenticated',
      () async {
        // The session remembers in the request's memo that it refused it. Without that the retry
        // would find nobody signed in and go out with no credential at all.
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = const AuthRejected();
        final error = await dioFailure(
          rig.dio(evaluator: defaultRetries).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(rig.sent, isEmpty);
        expect(rig.backend.renewals, 1);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
      },
    );

    test(
      'a renewal refused after a 401: the 401 stands, and the user is signed '
      'out',
      () async {
        final rig = SessionRig(scripted([401]));
        rig.backend.renewError = const AuthRejected();
        final error = await dioFailure(rig.dio().get<String>(orders));
        expect(error.response?.statusCode, 401);
        expect(rig.sent, hasLength(1));
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.expired),
        );
      },
    );

    test(
      'a session the server ended (SessionEnded): SignedOut with the reason, '
      'the backend forgets it, AuthRejected is the error',
      () async {
        final rig = SessionRig(scripted([401, 200]));
        rig.authenticator.verdict =
            (session, request, status, headers, body, retried) => status == 401
            ? const SessionEnded(SignOutReason.revoked)
            : const Accept();
        final error = await dioFailure(rig.dio().get<String>(orders));
        expect(error.error, isA<AuthRejected>());
        expect(rig.sent, hasLength(1));
        expect(rig.backend.renewals, 0);
        expect(rig.backend.discards, 1);
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.revoked),
        );
      },
    );

    test(
      'a renewal that cannot run before the send is retried, and no send goes '
      'without the session',
      () async {
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final error = await dioFailure(rig.dio().get<String>(orders));
        expect(error.error, isA<AuthUnavailable>());
        expect(rig.sent, isEmpty);
        expect(
          rig.backend.renewals,
          4,
          reason: 'the first attempt and three retries',
        );
        expect(rig.container.read(authSession), isA<SignedIn>());
      },
    );

    test(
      'a renewal that cannot run after a 401 is retried too, and the session '
      'stays',
      () async {
        final rig = SessionRig(always(401));
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final error = await dioFailure(rig.dio().get<String>(orders));
        expect(error.error, isA<AuthUnavailable>());
        expect(rig.sent, hasLength(4));
        expect(rig.backend.renewals, 4);
        expect(rig.container.read(authSession), isA<SignedIn>());
      },
    );

    test('a write whose renewal cannot run is not retried', () async {
      final rig = SessionRig(always(401));
      rig.backend.renewError = AuthUnavailable(StateError('offline'));
      final error = await dioFailure(rig.dio().post<String>(orders, data: 'x'));
      expect(error.error, isA<AuthUnavailable>());
      expect(rig.sent, hasLength(1));
      expect(rig.backend.renewals, 1);
    });

    test(
      'the user signs out between a 503 and its retry: the retry is refused, '
      'not sent without the session',
      () async {
        late final SessionRig rig;
        rig = SessionRig(
          FakeTransport((request, body) {
            // The first answer arrives while the user signs out.
            if (rig.sent.length == 1) unawaited(rig.notifier.signOut());
            return fakeResponse(rig.sent.length == 1 ? 503 : 200, body: 'x');
          }),
        );
        final error = await dioFailure(
          rig.dio(evaluator: defaultRetries).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(rig.signatures, ['fake-0#1']);
        expect(rig.authenticator.signed, hasLength(1));
        expect(
          rig.container.read(authSession),
          const SignedOut(reason: SignOutReason.user),
        );
      },
    );

    test(
      'the user signs out and another signs in between a 503 and its retry: the '
      'retry is refused, not sent as the new user',
      () async {
        late final SessionRig rig;
        rig = SessionRig(
          FakeTransport((request, body) {
            if (rig.sent.length == 1) unawaited(rig.switchTo(bob));
            return fakeResponse(rig.sent.length == 1 ? 503 : 200, body: 'x');
          }),
        );
        final error = await dioFailure(
          rig.dio(evaluator: defaultRetries).get<String>(orders),
        );
        expect(error.error, isA<AuthRejected>());
        expect(rig.signatures, ['fake-0#1']);
        expect(rig.authenticator.signed, hasLength(1));
        expect(rig.container.read(authUserId), bob.id);
      },
    );
  });

  // The same RequestOptions fetched twice is what a retrier does (dio_smart_retry calls
  // dio.fetch(requestOptions)): the second send is the same logical request, not a fresh one.
  group('a request sent again with the same options', () {
    RequestOptions options() => RequestOptions(path: orders);

    Matcher failsWithRejection() => throwsA(
      isA<DioException>().having((e) => e.error, 'error', isA<AuthRejected>()),
    );

    test('whose renewal was refused is refused again, without a renewal or a '
        'send, even after a sign-in', () async {
      final rig = SessionRig(
        scripted([200]),
        credentialLifetime: const Duration(seconds: -1),
      );
      rig.backend.renewError = const AuthRejected();
      final dio = rig.dio(retries: false);
      final request = options();
      for (var i = 0; i < 2; i++) {
        await expectLater(dio.fetch<String>(request), failsWithRejection());
      }
      expect(rig.sent, isEmpty);
      expect(rig.backend.renewals, 1);
      // Signing in again does not undo it for this request: it is not sent as whoever signed in.
      rig.backend.renewError = null;
      await rig.switchTo(ada);
      await expectLater(dio.fetch<String>(request), failsWithRejection());
      expect(rig.sent, isEmpty);
      // A new request is a new logical request: it goes out.
      expect((await dio.get<String>(orders)).statusCode, 200);
      expect(rig.sent, hasLength(1));
    });

    test('is not sent without the session it had (a sign-out)', () async {
      final rig = SessionRig(scripted([200, 200]));
      final dio = rig.dio(retries: false);
      final request = options();
      expect((await dio.fetch<String>(request)).statusCode, 200);
      await rig.notifier.signOut();
      await expectLater(dio.fetch<String>(request), failsWithRejection());
      expect(rig.sent, hasLength(1));
    });

    test(
      'is not sent as another user (a sign-out, then bob signs in)',
      () async {
        final rig = SessionRig(scripted([200, 200]));
        final dio = rig.dio(retries: false);
        final request = options();
        expect((await dio.fetch<String>(request)).statusCode, 200);
        await rig.switchTo(bob);
        await expectLater(dio.fetch<String>(request), failsWithRejection());
        expect(rig.sent, hasLength(1));
        expect(rig.signatures, ['fake-0#1']);
      },
    );

    test(
      'whose renewal could not run, then a sign-out and another user, is not '
      'sent as the new user',
      () async {
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final dio = rig.dio(retries: false);
        final request = options();
        await expectLater(
          dio.fetch<String>(request),
          throwsA(isA<DioException>()),
        );
        rig.backend.renewError = null;
        await rig.switchTo(bob);
        await expectLater(dio.fetch<String>(request), failsWithRejection());
        expect(rig.sent, isEmpty);
      },
    );

    test(
      'whose renewal could not run is not refused: the next send may work',
      () async {
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final dio = rig.dio(retries: false);
        final request = options();
        await expectLater(
          dio.fetch<String>(request),
          throwsA(isA<DioException>()),
        );
        rig.backend.renewError = null;
        expect((await dio.fetch<String>(request)).statusCode, 200);
        expect(rig.sent, hasLength(1));
      },
    );

    test('has spent its renewal: a 401, then the same options and another 401 '
        'renew once', () async {
      final rig = SessionRig(scripted([401, 401, 401]));
      final dio = rig.dio(retries: false);
      final request = options();
      final first = await dioFailure(dio.fetch<String>(request));
      expect(first.response?.statusCode, 401);
      // 401 -> renew -> replay -> 401: the first fetch spent the renewal.
      expect(rig.backend.renewals, 1);
      expect(rig.sent, hasLength(2));
      final second = await dioFailure(dio.fetch<String>(request));
      expect(second.response?.statusCode, 401);
      expect(rig.sent, hasLength(3));
      expect(rig.backend.renewals, 1);
    });
  });

  group('requests the session does not cover', () {
    test(
      'an origin that is not an API origin goes untouched, and is retried as is',
      () async {
        final rig = SessionRig(scripted([503, 200]));
        final response = await rig.dio().get<String>(other);
        expect(response.statusCode, 200);
        expect(rig.signatures, [null, null]);
        expect(rig.authenticator.signed, isEmpty);
        expect(rig.backend.renewals, 0);
      },
    );

    test('signed out: no signature, no renewal, and a 401 stands', () async {
      final rig = SessionRig(always(401), signedInAs: null);
      final error = await dioFailure(rig.dio().get<String>(orders));
      expect(error.response?.statusCode, 401);
      expect(rig.signatures, [null]);
      expect(rig.backend.renewals, 0);
    });
  });

  group('abort', () {
    test(
      'a CancelToken reaches the API transport as an abort trigger, and the call '
      'fails as a cancel',
      () async {
        final rig = SessionRig(
          FakeTransport(
            (request, body) => Completer<TransportResponse>().future,
          ),
        );
        final token = CancelToken();
        final done = dioFailure(
          rig.dio().get<String>(orders, cancelToken: token),
        );
        await pumpEventQueue();
        expect(rig.sent, hasLength(1));
        expect(rig.sent.single.abortable, isTrue);
        token.cancel('page closed');
        final error = await done;
        expect(error.type, DioExceptionType.cancel);
        expect(rig.apiTransport.abortCount, 1);
      },
    );

    test(
      'the abort reaches the retry that follows a 503, and the call fails as a cancel',
      () async {
        final waiting = Completer<TransportResponse>();
        var calls = 0;
        final rig = SessionRig(
          FakeTransport(
            (request, body) =>
                ++calls == 1 ? fakeResponse(503, body: 'x') : waiting.future,
          ),
        );
        final token = CancelToken();
        final done = dioFailure(
          rig.dio().get<String>(orders, cancelToken: token),
        );
        while (rig.sent.length < 2) {
          await pumpEventQueue();
        }
        token.cancel();
        final error = await done;
        expect(error.type, DioExceptionType.cancel);
        expect(
          rig.sent.every((s) => s.abortable),
          isTrue,
          reason: 'every send carries the trigger',
        );
        expect(rig.apiTransport.abortCount, 1);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
      },
    );

    test('the abort reaches the replay that follows a 401', () async {
      final waiting = Completer<TransportResponse>();
      var calls = 0;
      final rig = SessionRig(
        FakeTransport(
          (request, body) =>
              ++calls == 1 ? fakeResponse(401, body: 'x') : waiting.future,
        ),
      );
      final token = CancelToken();
      final done = dioFailure(
        rig.dio().get<String>(orders, cancelToken: token),
      );
      while (rig.sent.length < 2) {
        await pumpEventQueue();
      }
      token.cancel();
      final error = await done;
      expect(error.type, DioExceptionType.cancel);
      expect(rig.sent.every((s) => s.abortable), isTrue);
      expect(rig.replays, [false, true]);
      // At least the replay in flight: the fake also counts an answered send whose trigger fires.
      expect(rig.apiTransport.abortCount, greaterThanOrEqualTo(1));
    });

    test('a call cancelled before it starts never reaches the API', () async {
      final rig = SessionRig(scripted([200]));
      final token = CancelToken()..cancel();
      final error = await dioFailure(
        rig.dio().get<String>(orders, cancelToken: token),
      );
      expect(error.type, DioExceptionType.cancel);
      expect(rig.sent, isEmpty);
    });
  });
}
