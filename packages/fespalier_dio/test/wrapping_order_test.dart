// The wrapping order, proved with the real layers. Under Dio the session is a transport below the
// adapter, and the retrier is Dio's own, above it:
//
//   Dio + WriteGuard (first) + RetryInterceptor
//       -> TransportAdapter(SessionTransport(WriteGuardTransport(api)))      session outside
//       -> TransportAdapter(WriteGuardTransport(SessionTransport(api)))      guard outside
//
// A retry by Dio sends through the adapter again, so the session signs every send afresh in both;
// the order of the two transports only decides where the write mark of a response is read.
// The order the old SessionInterceptor offered (session outside the retrier, a proof reused) is
// the last group: a retrier inside a DioTransport under the session. Plain test(): Dio starts its
// chain with Timer.run.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_support.dart';

/// A transport that keeps what the one below it answered and threw, to read the write marks.
final class Spy implements HttpTransport {
  Spy(this.inner);

  final HttpTransport inner;
  final List<TransportResponse> responses = [];
  final List<Object> errors = [];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    try {
      final response = await inner.send(request);
      responses.add(response);
      return response;
    } on Object catch (error) {
      errors.add(error);
      rethrow;
    }
  }
}

HttpTransport sessionOutside(SessionRig rig) =>
    SessionTransport(WriteGuardTransport(rig.apiTransport), rig.credentials);

HttpTransport guardOutside(SessionRig rig) =>
    WriteGuardTransport(SessionTransport(rig.apiTransport, rig.credentials));

void main() {
  final stacks = <String, HttpTransport Function(SessionRig)>{
    'the session outside the write guard': sessionOutside,
    'the write guard outside the session': guardOutside,
  };

  for (final entry in stacks.entries) {
    group(entry.key, () {
      SessionRig rigFor(FakeTransport api) => SessionRig(api);
      Dio dioOf(SessionRig rig) => rig.dio(transport: entry.value(rig));

      test('a read is retried on a 503, signed afresh each time', () async {
        final rig = rigFor(scripted([503, 200]));
        final response = await dioOf(rig).get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
        expect(rig.backend.renewals, 0);
      });

      test('a write is not retried on a 503', () async {
        final rig = rigFor(scripted([503, 200]));
        final error = await dioFailure(
          dioOf(rig).post<String>(orders, data: 'a'),
        );
        expect(error.response?.statusCode, 503);
        expect(rig.sent, hasLength(1));
      });

      test('a write with an Idempotency-Key is retried', () async {
        final rig = rigFor(scripted([503, 200]));
        final response = await dioOf(rig).post<String>(
          orders,
          data: 'a',
          options: Options(headers: {'Idempotency-Key': 'k1'}),
        );
        expect(response.statusCode, 200);
        expect(rig.signatures, ['fake-0#1', 'fake-0#2']);
      });

      test('a read refused with a 401 is renewed and sent again', () async {
        final rig = rigFor(scripted([401, 200]));
        final response = await dioOf(rig).get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.backend.renewals, 1);
        expect(rig.signatures, ['fake-0#1', 'fake-1#2']);
        expect(rig.replays, [false, true]);
      });

      test('a 401 is renewed and replayed under the retrier, with the whole '
          'body: nothing turns the request into a stream', () async {
        final rig = rigFor(scripted([401, 200]));
        final response = await dioOf(rig).post<String>(orders, data: 'abc');
        expect(response.statusCode, 200);
        expect(rig.sent.map((s) => s.text), ['abc', 'abc']);
        expect(rig.backend.renewals, 1);
      });

      test('a write refused with a 401 is replayed once, and a 503 after it is '
          'not retried', () async {
        final rig = rigFor(scripted([401, 503, 200]));
        final error = await dioFailure(
          dioOf(rig).post<String>(orders, data: 'a'),
        );
        expect(error.response?.statusCode, 503);
        expect(rig.sent, hasLength(2), reason: 'one replay, no retry');
        expect(rig.replays, [false, true]);
      });

      test('the abort reaches the retry that follows a 503', () async {
        final waiting = Completer<TransportResponse>();
        var calls = 0;
        final rig = rigFor(
          FakeTransport(
            (request, body) =>
                ++calls == 1 ? fakeResponse(503, body: 'x') : waiting.future,
          ),
        );
        final token = CancelToken();
        final done = dioFailure(
          dioOf(rig).get<String>(orders, cancelToken: token),
        );
        while (rig.sent.length < 2) {
          await pumpEventQueue();
        }
        token.cancel();
        expect((await done).type, DioExceptionType.cancel);
        expect(rig.sent.every((s) => s.abortable), isTrue);
      });

      test('the abort reaches the replay that follows a 401', () async {
        final waiting = Completer<TransportResponse>();
        var calls = 0;
        final rig = rigFor(
          FakeTransport(
            (request, body) =>
                ++calls == 1 ? fakeResponse(401, body: 'x') : waiting.future,
          ),
        );
        final token = CancelToken();
        final done = dioFailure(
          dioOf(rig).get<String>(orders, cancelToken: token),
        );
        while (rig.sent.length < 2) {
          await pumpEventQueue();
        }
        token.cancel();
        expect((await done).type, DioExceptionType.cancel);
        expect(rig.sent.every((s) => s.abortable), isTrue);
      });

      test(
        'a retrier that retries network errors only: a refused renewal is not '
        'retried and nothing is sent',
        () async {
          final rig = SessionRig(
            scripted([200]),
            credentialLifetime: const Duration(seconds: -1),
          );
          rig.backend.renewError = const AuthRejected();
          final dio = rig.dio(
            transport: entry.value(rig),
            evaluator: (error, attempt) => error.error is TransportFailure,
          );
          final error = await dioFailure(dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          expect(rig.sent, isEmpty);
          expect(rig.backend.renewals, 1);
        },
      );

      test('an unavailable renewal is retried, and nothing is sent without the '
          'session', () async {
        final rig = SessionRig(
          scripted([200]),
          credentialLifetime: const Duration(seconds: -1),
        );
        rig.backend.renewError = AuthUnavailable(StateError('offline'));
        final error = await dioFailure(
          rig.dio(transport: entry.value(rig)).get<String>(orders),
        );
        expect(error.error, isA<AuthUnavailable>());
        expect(rig.sent, isEmpty);
        expect(
          rig.backend.renewals,
          4,
          reason: 'the first attempt and three retries',
        );
      });
    });
  }

  group('the write marks of the guard transport', () {
    // A retrier above a transport chain asks WriteGuardTransport.isWriteResponse / isWriteError.
    // The session returns the response it was given, except a 401 or a 403, which it reads and
    // hands on as a copy: that one is not a response the guard saw, so it reads as a write (the
    // safe answer to "might this be a write?").
    Future<Spy> sendThrough(
      HttpTransport Function(SessionRig) stack,
      List<Object> answers,
      TransportRequest request,
    ) async {
      final rig = SessionRig(scripted(answers));
      final spy = Spy(stack(rig));
      try {
        await spy.send(request);
      } on Object {
        // The marks are read below.
      }
      return spy;
    }

    TransportRequest get(String method) =>
        TransportRequest(method: method, uri: Uri.parse(orders));

    for (final entry in stacks.entries) {
      test(
        '${entry.key}: a 503 to a read is not a write, to a write it is',
        () async {
          final read = await sendThrough(entry.value, [503], get('GET'));
          final write = await sendThrough(entry.value, [503], get('POST'));
          expect(
            WriteGuardTransport.isWriteResponse(read.responses.single),
            isFalse,
          );
          expect(
            WriteGuardTransport.isWriteResponse(write.responses.single),
            isTrue,
          );
        },
      );

      test(
        '${entry.key}: the error a write threw is a write error, a read\'s is not',
        () async {
          // Not const: a canonical instance would be one object for both, marked by the write.
          final read = await sendThrough(entry.value, [
            TransportBroken(StateError('dropped')),
          ], get('GET'));
          final write = await sendThrough(entry.value, [
            TransportBroken(StateError('dropped')),
          ], get('POST'));
          expect(WriteGuardTransport.isWriteError(read.errors.single), isFalse);
          expect(WriteGuardTransport.isWriteError(write.errors.single), isTrue);
        },
      );
    }

    test(
      'the session outside the guard: the 401 it hands on is a copy and reads '
      'as a write, even for a read',
      () async {
        final spy = await sendThrough(sessionOutside, [401, 401], get('GET'));
        expect(
          WriteGuardTransport.isWriteResponse(spy.responses.single),
          isTrue,
        );
      },
    );

    test(
      'the guard outside the session: the 401 of a read is still known to be one',
      () async {
        final spy = await sendThrough(guardOutside, [401, 401], get('GET'));
        expect(
          WriteGuardTransport.isWriteResponse(spy.responses.single),
          isFalse,
        );
      },
    );
  });

  group("WriteGuard, Dio's interceptor, is first", () {
    test(
      'a write retried by a plain evaluator gets its first error back',
      () async {
        final rig = SessionRig(scripted([503, 200]));
        final error = await dioFailure(
          rig
              .dio(readsOnly: false, evaluator: defaultRetries)
              .post<String>(orders, data: 'a'),
        );
        expect(error.response?.statusCode, 503);
        expect(rig.sent, hasLength(1));
      },
    );

    test(
      'not first: the retried write is refused with WriteNotRetried, and still '
      'sent once',
      () async {
        final rig = SessionRig(scripted([503, 200]));
        final dio = rig.dio(
          guard: false,
          readsOnly: false,
          evaluator: defaultRetries,
        )..interceptors.add(const WriteGuard());
        final error = await dioFailure(dio.post<String>(orders, data: 'a'));
        expect(error.error, isA<WriteNotRetried>());
        expect(rig.sent, hasLength(1));
      },
    );

    test('install moves the guard back to the front, once', () {
      final rig = SessionRig(scripted([]));
      final dio = rig.dio();
      WriteGuard.install(dio);
      WriteGuard.install(dio);
      expect(dio.interceptors.whereType<WriteGuard>(), hasLength(1));
      expect(dio.interceptors.first, isA<WriteGuard>());
      expect(dio.interceptors.whereType<RetryInterceptor>(), hasLength(1));
    });
  });

  group('the retrier inside, the session outside (a DioTransport under the '
      'session)', () {
    // The order SessionInterceptor documented as the default: the retrier is below the session,
    // which is asked once and signs once, so a retry sends the same signature again. A Dio under
    // a DioTransport sees every status as an answer, so it retries failures, not statuses.
    SessionTransport sessionOverRetryingDio(SessionRig rig) => SessionTransport(
      DioTransport(rig.dio(transport: rig.apiTransport)),
      rig.credentials,
    );

    TransportRequest request(String method) =>
        TransportRequest(method: method, uri: Uri.parse(orders));

    test(
      'a retry re-sends the signature it was given: one signature, two sends',
      () async {
        final rig = SessionRig(scripted([const TransportBroken(), 200]));
        final response = await sessionOverRetryingDio(rig).send(request('GET'));
        expect(response.statusCode, 200);
        expect(rig.sent, hasLength(2));
        expect(rig.authenticator.signed, hasLength(1));
        expect(rig.signatures, ['fake-0#1', 'fake-0#1']);
      },
    );

    test('a 401 is judged by the session, renewed and replayed through the Dio '
        'below, signed afresh', () async {
      final rig = SessionRig(scripted([401, 200]));
      final response = await sessionOverRetryingDio(rig).send(request('GET'));
      expect(response.statusCode, 200);
      expect(rig.signatures, ['fake-0#1', 'fake-1#2']);
      expect(rig.replays, [false, true]);
      expect(rig.backend.renewals, 1);
    });

    test(
      'a write that failed is sent once: the Dio below does not retry it',
      () async {
        final rig = SessionRig(scripted([const TransportBroken(), 200]));
        await expectLater(
          sessionOverRetryingDio(rig).send(request('POST')),
          throwsA(isA<TransportBroken>()),
        );
        expect(rig.sent, hasLength(1));
      },
    );
  });
}
