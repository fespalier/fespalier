// The real SessionInterceptor (fespalier_auth) under dio_smart_retry, behind WriteGuard: a new DPoP
// proof for every send, and one replay per 401, whichever of the two interceptors comes first.
// docs/http.md ("The wrapping order") says the Dio order is nothing to choose by hand; this is the
// test that says it is true. Plain test(): Dio starts its chain with Timer.run.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/dio.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_dio/client.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final api = Uri.parse('https://api.example.com');
const orders = 'https://api.example.com/orders';
const ada = AuthUser(id: 'ada-id');

/// One scripted answer; [onSend] runs when the request arrives, before the answer.
final class Step {
  const Step(this.status, {this.headers = const {}, this.onSend});

  final int status;
  final Map<String, List<String>> headers;
  final FutureOr<void> Function()? onSend;
}

/// What the API saw of one send.
final class Sent {
  Sent(RequestOptions options, this.body)
    : method = options.method,
      authorization = _header(options, 'Authorization'),
      dpop = _header(options, 'DPoP'),
      replay = options.extra[authReplayKey] == true;

  final String method;
  final String? authorization;
  final String? dpop;
  final bool replay;
  final List<int> body;

  static String? _header(RequestOptions options, String name) {
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) {
        return '${entry.value}';
      }
    }
    return null;
  }
}

/// A server that answers from a queue, one [Step] per send, and records every send. A send with
/// no step left throws, which Dio turns into a retryable error, so a surplus send is caught by each
/// case's send-count or header-list assertion.
final class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter(Iterable<Step> steps) : _steps = [...steps];

  final List<Step> _steps;
  final List<Sent> sent = [];
  bool closed = false;

  List<String?> get authorizations => [for (final s in sent) s.authorization];
  List<String?> get proofs => [for (final s in sent) s.dpop];
  List<bool> get replays => [for (final s in sent) s.replay];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    sent.add(Sent(options, body));
    if (_steps.isEmpty) {
      throw StateError('ScriptedAdapter: send ${sent.length} has no step');
    }
    final step = _steps.removeAt(0);
    await step.onSend?.call();
    return ResponseBody.fromString(
      step.status < 300 ? 'ok' : 'no',
      step.status,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
        ...step.headers,
      },
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}

enum Order { retryFirst, sessionFirst }

/// The stack under test, built in [order].
final class Rig {
  Rig(
    Order order,
    List<Step> steps, {
    bool signedIn = true,
    Duration? tokenLifetime,
    bool guardNeeded = false,
    void Function()? beforeRetry,
  }) : proof = FakeProof() {
    backend = FakeAuthBackend(proof: proof, tokenLifetime: tokenLifetime);
    container = ProviderContainer(
      overrides: fakeAuth(
        signedInAs: signedIn ? ada : null,
        backend: backend,
        apiOrigins: [api],
        tokenLifetime: tokenLifetime,
      ),
    );
    addTearDown(container.dispose);
    adapter = ScriptedAdapter(steps);
    addTearDown(() => adapter.close(force: true));
    dio = Dio()..httpClientAdapter = adapter;
    final retry = RetryInterceptor(
      dio: dio,
      retries: 3,
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      // dio_smart_retry 7.0.1 calls logPrint once per retry, after the retry is decided and before
      // the delay and the dio.fetch (retry_interceptor.dart:119): that is what makes it a hook a
      // test can change the session in, between two sends of one request.
      logPrint: (_) {
        final once = beforeRetry;
        beforeRetry = null;
        once?.call();
      },
      // guardNeeded: the plain evaluator also retries a write, so only WriteGuard stops it.
      retryEvaluator: guardNeeded
          ? DefaultRetryEvaluator(defaultRetryableStatuses).evaluate
          : WriteGuard.readsOnly(
              DefaultRetryEvaluator(defaultRetryableStatuses).evaluate,
            ),
    );
    final session = SessionInterceptor(container.read(authorizer), dio);
    dio.interceptors.addAll(switch (order) {
      Order.retryFirst => [retry, session],
      Order.sessionFirst => [session, retry],
    });
    WriteGuard.install(dio);
  }

  final FakeProof proof;
  late final FakeAuthBackend backend;
  late final ProviderContainer container;
  late final ScriptedAdapter adapter;
  late final Dio dio;

  AuthSessionNotifier get notifier => container.read(authSession.notifier);

  /// Every send made its own proof, and the adapter saw exactly the proofs the fake made.
  void expectNewProofPerSend() {
    final seen = adapter.proofs;
    expect(seen, proof.proofs);
    expect(seen.toSet(), hasLength(seen.length));
  }
}

Future<DioException> failure(Future<Object?> future) async {
  try {
    await future;
  } on DioException catch (error) {
    return error;
  }
  fail('the request should have failed');
}

void main() {
  for (final order in Order.values) {
    group('with ${order.name}', () {
      test(
        'a 503 then a 200: two sends, two proofs, the same token, no refresh',
        () async {
          final rig = Rig(order, [const Step(503), const Step(200)]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.authorizations, [
            'DPoP fake-access-0',
            'DPoP fake-access-0',
          ]);
          expect(rig.adapter.replays, [false, false]);
          rig.expectNewProofPerSend();
          expect(rig.backend.refreshes, 0);
        },
      );

      test(
        'a 401: one refresh, one replay with the new token and a new proof',
        () async {
          final rig = Rig(order, [const Step(401), const Step(200)]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.authorizations, [
            'DPoP fake-access-0',
            'DPoP fake-access-1',
          ]);
          expect(rig.adapter.replays, [false, true]);
          rig.expectNewProofPerSend();
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a 401 then a 401: one refresh, and the second 401 is the answer',
        () async {
          final rig = Rig(order, [const Step(401), const Step(401)]);
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.response?.statusCode, 401);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a 401, a 503 on the replay, then a 200: the retry keeps the refreshed token',
        () async {
          final rig = Rig(order, [
            const Step(401),
            const Step(503),
            const Step(200),
          ]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.authorizations, [
            'DPoP fake-access-0',
            'DPoP fake-access-1',
            'DPoP fake-access-1',
          ]);
          rig.expectNewProofPerSend();
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a 401, a 503 on the replay, a 401 on its retry: no second refresh',
        () async {
          final rig = Rig(order, [
            const Step(401),
            const Step(503),
            const Step(401),
          ]);
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.response?.statusCode, 401);
          expect(rig.adapter.sent, hasLength(3));
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a 503, then a 401, then a 200: the replay follows the retry',
        () async {
          final rig = Rig(order, [
            const Step(503),
            const Step(401),
            const Step(200),
          ]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.authorizations, [
            'DPoP fake-access-0',
            'DPoP fake-access-0',
            'DPoP fake-access-1',
          ]);
          expect(rig.adapter.replays, [false, false, true]);
          expect(rig.backend.refreshes, 1);
          rig.expectNewProofPerSend();
        },
      );

      test(
        'a DPoP-Nonce header on a 200 is remembered: the next proof carries it',
        () async {
          final rig = Rig(order, [
            const Step(
              200,
              headers: {
                'DPoP-Nonce': ['srv-1'],
              },
            ),
            const Step(200),
          ]);
          await rig.dio.get<String>(orders);
          await rig.dio.get<String>(orders);
          expect(rig.proof.proofs[0], isNot(contains('nonce=')));
          expect(rig.proof.proofs[1], contains('nonce=srv-1'));
          rig.expectNewProofPerSend();
        },
      );

      test(
        'a DPoP nonce challenge: one replay whose proof carries the nonce, no refresh',
        () async {
          final rig = Rig(order, [const Step(401), const Step(200)]);
          rig.proof.challengeNext = true;
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.proof.proofs[0], isNot(contains('nonce=')));
          expect(rig.proof.proofs[1], contains('nonce=nonce-1'));
          expect(rig.adapter.authorizations, [
            'DPoP fake-access-0',
            'DPoP fake-access-0',
          ]);
          expect(rig.backend.refreshes, 0);
          rig.expectNewProofPerSend();
        },
      );

      test('a nonce challenge then a 401: each answered once', () async {
        final rig = Rig(order, [
          const Step(401),
          const Step(401),
          const Step(200),
        ]);
        rig.proof.challengeNext = true;
        final response = await rig.dio.get<String>(orders);
        expect(response.statusCode, 200);
        expect(rig.adapter.sent, hasLength(3));
        expect(rig.proof.challenges, 1);
        expect(rig.backend.refreshes, 1);
        rig.expectNewProofPerSend();
      });

      test(
        'three 503s and a 200: four sends, four proofs, none marked a replay',
        () async {
          final rig = Rig(order, [
            const Step(503),
            const Step(503),
            const Step(503),
            const Step(200),
          ]);
          final response = await rig.dio.get<String>(orders);
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(4));
          expect(rig.adapter.replays, [false, false, false, false]);
          rig.expectNewProofPerSend();
          expect(rig.backend.refreshes, 0);
        },
      );

      test(
        'a write: a 401 is replayed once and a 503 on the replay is not retried',
        () async {
          final rig = Rig(order, [
            const Step(401),
            const Step(503),
            const Step(200),
          ]);
          final error = await failure(rig.dio.put<String>(orders, data: 'x'));
          expect(error.response?.statusCode, 503);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.adapter.replays, [false, true]);
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a write with an Idempotency-Key is retried after a 503, with a new proof',
        () async {
          final rig = Rig(order, [const Step(503), const Step(200)]);
          final response = await rig.dio.put<String>(
            orders,
            data: 'x',
            options: Options(headers: {'Idempotency-Key': 'k1'}),
          );
          expect(response.statusCode, 200);
          expect(rig.adapter.sent, hasLength(2));
          rig.expectNewProofPerSend();
        },
      );

      test(
        'two reads that both get a 401 share one refresh, and each is replayed once',
        () async {
          final rig = Rig(order, [
            const Step(401),
            const Step(401),
            const Step(200),
            const Step(200),
          ]);
          final both = await Future.wait([
            rig.dio.get<String>(orders),
            rig.dio.get<String>('$orders/2'),
          ]);
          expect(both.map((r) => r.statusCode), [200, 200]);
          expect(rig.adapter.sent, hasLength(4));
          expect(rig.adapter.authorizations.toList()..sort(), [
            'DPoP fake-access-0',
            'DPoP fake-access-0',
            'DPoP fake-access-1',
            'DPoP fake-access-1',
          ]);
          expect(rig.adapter.replays.where((r) => r), hasLength(2));
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a refresh that cannot run before the send is retried, and no send goes without the session',
        () async {
          final rig = Rig(
            order,
            const [],
            tokenLifetime: const Duration(seconds: -1),
          );
          rig.backend.refreshError = AuthUnavailable(StateError('offline'));
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthUnavailable>());
          // Every send that reaches the API carries the session; with the refresh failing every
          // time, none reaches it.
          expect(rig.adapter.sent, isEmpty);
          // The first attempt and the three retries each ask for a refresh.
          expect(rig.backend.refreshes, 4);
        },
      );

      test(
        'WriteGuard is what stops a PUT after the session replayed it: a plain evaluator would retry the 503',
        () async {
          final rig = Rig(order, [
            const Step(401),
            const Step(503),
            const Step(200),
          ], guardNeeded: true);
          final error = await failure(rig.dio.put<String>(orders, data: 'x'));
          expect(error.response?.statusCode, 503);
          expect(rig.adapter.sent, hasLength(2));
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a refresh refused before the send: nothing reaches the API, and the retry is refused too',
        () async {
          final rig = Rig(
            order,
            const [],
            tokenLifetime: const Duration(seconds: -1),
          );
          rig.backend.refreshError = const AuthRejected();
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          // The wanted mark alone stops the retry (nobody is signed in, and the request had
          // wanted the session); the refused mark is pinned by fespalier_auth's dio_test.dart
          // ("still refused after a sign-in").
          expect(rig.adapter.sent, isEmpty);
          expect(rig.backend.refreshes, 1);
          expect(
            rig.container.read(authSession),
            const SignedOut(reason: SignOutReason.expired),
          );
        },
      );

      test(
        'a refresh that could not run, then a sign-out: the retry is not sent without the session',
        () async {
          late final Rig rig;
          rig = Rig(
            order,
            const [],
            tokenLifetime: const Duration(seconds: -1),
            beforeRetry: () => rig.notifier.signOut(),
          );
          rig.backend.refreshError = AuthUnavailable(StateError('offline'));
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          expect(rig.adapter.sent, isEmpty);
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'a refresh that could not run, a sign-out, another user signs in: the retry is not sent as the new user',
        () async {
          late final Rig rig;
          rig = Rig(
            order,
            const [],
            tokenLifetime: const Duration(seconds: -1),
            beforeRetry: () async {
              await rig.notifier.signOut();
              rig.backend
                ..user = const AuthUser(id: 'bob-id')
                ..tokenLifetime = null;
              await rig.notifier.signIn(
                const PasswordSignIn(username: 'bob', password: 'bob'),
              );
            },
          );
          rig.backend.refreshError = AuthUnavailable(StateError('offline'));
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          expect(rig.adapter.sent, isEmpty);
          expect(rig.container.read(authUserId), 'bob-id');
        },
      );

      test(
        'a sign-out between a 503 and its retry: the retry is not sent with the stale token and proof',
        () async {
          late final Rig rig;
          rig = Rig(order, [
            Step(503, onSend: () => rig.notifier.signOut()),
            const Step(200),
          ]);
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          expect(rig.adapter.sent, hasLength(1));
          expect(rig.adapter.authorizations, ['DPoP fake-access-0']);
        },
      );

      test(
        'a sign-out and a sign-in as another user between a 503 and its retry: not sent as the new user',
        () async {
          late final Rig rig;
          rig = Rig(order, [
            Step(
              503,
              onSend: () async {
                await rig.notifier.signOut();
                rig.backend.user = const AuthUser(id: 'bob-id');
                await rig.notifier.signIn(
                  const PasswordSignIn(username: 'bob', password: 'bob'),
                );
              },
            ),
            const Step(200),
          ]);
          final error = await failure(rig.dio.get<String>(orders));
          expect(error.error, isA<AuthRejected>());
          expect(rig.adapter.sent, hasLength(1));
          expect(rig.container.read(authUserId), 'bob-id');
        },
      );

      test(
        'through DioHttpClient, a POST body is sent again whole after a 401, under the retrier',
        () async {
          final rig = Rig(order, [const Step(401), const Step(200)]);
          final response = await DioHttpClient(
            rig.dio,
          ).post(Uri.parse(orders), body: 'hello');
          expect(response.statusCode, 200);
          expect(rig.adapter.sent.map((s) => s.body), [
            utf8.encode('hello'),
            utf8.encode('hello'),
          ]);
          expect(rig.backend.refreshes, 1);
        },
      );

      test(
        'through DioHttpClient, a streamed body is not sent again: the 401 after the refresh',
        () async {
          final rig = Rig(order, [const Step(401), const Step(200)]);
          final request = http.StreamedRequest('POST', Uri.parse(orders))
            ..sink.add(utf8.encode('streamed'));
          unawaited(request.sink.close());
          final response = await http.Response.fromStream(
            await DioHttpClient(rig.dio).send(request),
          );
          expect(response.statusCode, 401);
          expect(rig.adapter.sent, hasLength(1));
          expect(rig.backend.refreshes, 1);
        },
      );
    });
  }
}
