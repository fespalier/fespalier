// What the session tests share: the real session (fespalier_auth's SessionTransport over its
// Authorizer, on the auth fakes) under a real Dio, with a FakeTransport standing for the API.
//
//   Dio(...) + interceptors (WriteGuard.install, RetryInterceptor)
//       -> TransportAdapter(SessionTransport(api, authorizer))
//
// A retry by Dio calls the adapter again, so the session authorizes (signs) every send with the
// final bytes of the body. Nothing waits for real time: the retrier has zero delays.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

final api = Uri.parse('https://api.example.com');
const orders = 'https://api.example.com/orders';
const other = 'https://other.example.org/orders';
const ada = AuthUser(id: 'ada-id');
const bob = AuthUser(id: 'bob-id');

/// The header `FakeAuthenticator` adds: `<credential id>#<n>`, `n` counting the sends it signed.
const signature = 'x-fake-credential';

/// A sign-in for the fake backend, which reads nothing from it.
final class AnySignIn extends SignInRequest {
  const AnySignIn();
}

/// A transport standing for the API: it answers [answers] in order. An `int` is a response with
/// that status, a `TransportResponse` is sent as it is, a `TransportFailure` is thrown. A send
/// past the end fails the test with a `StateError`.
FakeTransport scripted(List<Object> answers) => FakeTransport.script([
  for (final answer in answers)
    if (answer is int) fakeResponse(answer, body: 'x') else answer,
]);

/// A transport that answers every send with [status].
FakeTransport always(int status) =>
    FakeTransport((request, body) => fakeResponse(status, body: 'x'));

/// What `dio_smart_retry` retries by default: a retryable status, and any error but a cancel.
FutureOr<bool> Function(DioException error, int attempt) get defaultRetries =>
    DefaultRetryEvaluator(defaultRetryableStatuses).evaluate;

/// [defaultRetries], except that an `AuthRejected` (the session is over) is never retried: what an
/// app that uses the session under a retrier writes.
FutureOr<bool> Function(DioException error, int attempt) get skippingRejected =>
    (error, attempt) =>
        error.error is AuthRejected ? false : defaultRetries(error, attempt);

/// The session under test and the Dio over it.
final class SessionRig {
  /// A rig whose API is [api]. Signed in as [signedInAs] (null: signed out) on [backend]; a
  /// negative [credentialLifetime] makes the first credential expired.
  SessionRig(
    this.apiTransport, {
    AuthUser? signedInAs = ada,
    FakeAuthBackend? backend,
    Duration? credentialLifetime,
    List<Uri>? origins,
  }) : backend =
           backend ?? FakeAuthBackend(credentialLifetime: credentialLifetime) {
    container = ProviderContainer(
      overrides: fakeAuth(
        signedInAs: signedInAs,
        backend: this.backend,
        apiOrigins: origins ?? [api],
        transport: apiTransport,
        credentialLifetime: credentialLifetime,
      ),
    );
    addTearDown(container.dispose);
    session = SessionTransport(apiTransport, container.read(authorizer));
  }

  /// The API.
  final FakeTransport apiTransport;

  /// The backend the session renews on.
  final FakeAuthBackend backend;

  late final ProviderContainer container;

  /// The session over the API.
  late final SessionTransport session;

  /// The credentials the session attaches: for a stack of one's own over [apiTransport].
  Authorizer get credentials => container.read(authorizer);

  /// What signs every send.
  FakeAuthenticator get authenticator => backend.authenticator;

  /// The session notifier.
  AuthSessionNotifier get notifier => container.read(authSession.notifier);

  /// The requests the API was sent.
  List<SentRequest> get sent => apiTransport.requests;

  /// The signature header of each send the API saw (null: none).
  List<String?> get signatures => [
    for (final request in sent) request.lowerHeaders[signature],
  ];

  /// Whether each send the API saw was marked as the replay of a verdict.
  List<bool> get replays => [
    for (final request in sent)
      request.request.attributes[transportReplayKey] == true,
  ];

  /// A Dio sending through [transport] (the session by default).
  ///
  /// [retries] adds a zero-delay `RetryInterceptor` with [evaluator] ([skippingRejected] by
  /// default), wrapped in `WriteGuard.readsOnly` when [readsOnly] is true, so no write is retried
  /// (false: only `WriteGuard` stands between the retrier and a write). [guard] installs
  /// `WriteGuard` first. [beforeRetry] runs once, when the retrier has decided to retry and
  /// before the next send.
  Dio dio({
    HttpTransport? transport,
    bool retries = true,
    bool guard = true,
    bool readsOnly = true,
    FutureOr<bool> Function(DioException error, int attempt)? evaluator,
    void Function()? beforeRetry,
  }) {
    final dio = Dio()
      ..httpClientAdapter = TransportAdapter(transport ?? session);
    if (retries) {
      final base = evaluator ?? skippingRejected;
      var hook = beforeRetry;
      dio.interceptors.add(
        RetryInterceptor(
          dio: dio,
          retries: 3,
          retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
          // dio_smart_retry calls logPrint once per retry, after the retry is decided and before
          // the delay and the next fetch: a hook a test can change the session in.
          logPrint: (_) {
            final once = hook;
            hook = null;
            once?.call();
          },
          retryEvaluator: readsOnly ? WriteGuard.readsOnly(base) : base,
        ),
      );
    }
    if (guard) WriteGuard.install(dio);
    return dio;
  }

  /// Signs the current user out and signs [user] in.
  Future<void> switchTo(AuthUser user) async {
    await notifier.signOut();
    backend
      ..user = user
      ..credentialLifetime = null;
    await notifier.signIn(const AnySignIn());
  }
}

/// The `DioException` [future] fails with.
Future<DioException> dioFailure(Future<Object?> future) async {
  try {
    await future;
  } on DioException catch (error) {
    return error;
  }
  fail('the request should have failed');
}
