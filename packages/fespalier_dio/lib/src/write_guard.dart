import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// M-D1: what a debug build prints, once per request, when [WriteGuard] refuses to send a write
/// again. Only the method and the path: never the host, the query or a body.
String writeAboutToBeRetriedMessage(String method, String path) =>
    'fespalier_dio: $method $path failed and was about to be sent again. A write is never '
    'retried, so its first error is returned. Give the retry interceptor '
    'WriteGuard.readsOnly(...) as its evaluator, or add an Idempotency-Key header to a write that '
    'is safe to repeat.';

/// Refuses to send a write a second time (since 0.9.0): fespalier never retries a write, and
/// neither may a retry interceptor. A write is any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`,
/// unless it carries an `Idempotency-Key` header or `extra[WriteGuard.idempotent]`;
/// `extra[WriteGuard.write]` makes any request one. A second send after a 401 is allowed (the
/// server refused it before running it: an auth refresh replays it).
///
/// Install it **first**, with [install] as the last call: an interceptor records the error of a
/// write's first send, and a retrier that sees the error afterwards finds the second send refused,
/// with the first error handed back to the caller. A retrier that is already asked "is this
/// retryable?" can be told that no write is, so it does not even wait out its delay:
/// `RetryInterceptor(dio: dio, retryEvaluator: WriteGuard.readsOnly(...))`.
///
/// It keeps its state in the `extra` of the request (`fespalier.sends`, `fespalier.error`,
/// `fespalier.refused`), which is never sent to a server, so it works with any retrier that sends
/// the same `RequestOptions`, or a `copyWith` of them, again. It starts no timer, retries nothing
/// itself and does no I/O: a backoff would need a timer, and fespalier has none.
final class WriteGuard extends Interceptor {
  /// A guard. Use [install]: it is only useful first in the list.
  const WriteGuard();

  /// `Options(extra: {WriteGuard.idempotent: true})`: this write may be sent again.
  static const String idempotent = 'fespalier.idempotent';

  /// `Options(extra: {WriteGuard.write: true})`: this request is a write, whatever its method.
  static const String write = 'fespalier.write';

  static const String _sends = 'fespalier.sends';
  static const String _error = 'fespalier.error';
  static const String _refused = 'fespalier.refused';
  static const String _warned = 'fespalier.warned';

  static const Set<String> _safeMethods = {'GET', 'HEAD', 'OPTIONS', 'TRACE'};

  /// Puts a WriteGuard first in [dio]'s interceptors, once. Call it after adding the others.
  ///
  /// Calling it again moves the guard back to the front: there is never more than one.
  static void install(Dio dio) {
    dio.interceptors
      ..removeWhere((interceptor) => interceptor is WriteGuard)
      ..insert(0, const WriteGuard());
  }

  /// Whether [options] is a write by the rule above.
  ///
  /// `extra[write]` makes a request one, and an `Idempotency-Key` header or `extra[idempotent]`
  /// makes a write repeatable (so it is not one).
  static bool isWrite(RequestOptions options) {
    final extra = options.extra;
    if (extra[idempotent] == true) return false;
    if (options.headers.keys.any((k) => k.toLowerCase() == 'idempotency-key')) {
      return false;
    }
    return extra[write] == true ||
        !_safeMethods.contains(options.method.toUpperCase());
  }

  /// [evaluator], except that a write is never retried: for `RetryInterceptor(retryEvaluator:)`.
  ///
  /// It answers `false` for a write without asking [evaluator] (so the retrier does not wait out a
  /// delay for nothing), and has the shape of `dio_smart_retry`'s `RetryEvaluator`, with no
  /// dependency on it.
  static FutureOr<bool> Function(DioException error, int attempt) readsOnly(
    FutureOr<bool> Function(DioException error, int attempt) evaluator,
  ) =>
      (error, attempt) =>
          isWrite(error.requestOptions) ? false : evaluator(error, attempt);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (!isWrite(options)) return handler.next(options);
    final extra = options.extra;
    final sends = extra[_sends] as int? ?? 0;
    if (sends == 0) {
      extra[_sends] = 1;
      return handler.next(options);
    }
    // The server refused the last send before running it (a 401): an auth refresh sends it again.
    if (extra[_refused] == true) {
      extra.remove(_refused);
      extra[_sends] = sends + 1;
      return handler.next(options);
    }
    final first = extra[_error];
    if (first is DioException) {
      if (extra[_warned] != true) {
        extra[_warned] = true;
        assert(() {
          debugPrint(
            writeAboutToBeRetriedMessage(
              options.method.toUpperCase(),
              options.uri.path,
            ),
          );
          return true;
        }());
      }
      // To the caller, past the error interceptors: they have seen this error already.
      return handler.reject(first);
    }
    handler.reject(
      DioException(
        requestOptions: options,
        error: WriteNotRetried(options.method.toUpperCase(), options.uri.path),
      ),
    );
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    // A client that accepts a 401 as a response (`validateStatus`) has it replayed from here.
    final options = response.requestOptions;
    if (response.statusCode == 401 && isWrite(options)) {
      options.extra[_refused] = true;
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (isWrite(options)) {
      options.extra[_error] = err;
      options.extra[_refused] = err.response?.statusCode == 401;
    }
    handler.next(err);
  }
}

/// What a write that was sent again fails with when its first error is unknown ([WriteGuard] was
/// not first, so a re-sending interceptor ran before it) (since 0.9.0). See its [toString].
final class WriteNotRetried implements Exception {
  /// A refused second send of [method] to [path].
  const WriteNotRetried(this.method, this.path);

  /// The HTTP method, in capitals.
  final String method;

  /// The path of the request: no host and no query.
  final String path;

  @override
  String toString() =>
      'WriteNotRetried: $method $path was sent again by an interceptor that runs before '
      'WriteGuard, so the error of its first send is unknown. A write is never retried. Call '
      'WriteGuard.install(dio) after adding every other interceptor: it puts WriteGuard first.';
}
