import 'dart:async';

import 'package:dio/dio.dart';

import 'authorizer.dart';
import 'errors.dart';

const String _attemptKey = 'fespalier_auth.attempt';

/// Adds the session to a Dio's requests to `AuthConfig.apiOrigins`, and sends a request once more
/// after a proof challenge or a 401 (a refresh), like `SessionClient` (since 0.9.0).
///
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(SessionInterceptor(ref.watch(authorizer), dio));
/// ```
///
/// A request to another origin is untouched. `FormData` bodies are not sent again: the caller
/// gets the 401, after the refresh, so its next attempt works. Every response goes through
/// the authorizer, so a DPoP nonce on a success is remembered too, and a request is sent at most
/// three times.
final class SessionInterceptor extends Interceptor {
  /// An interceptor over [authorizer], sending a request again through [dio].
  SessionInterceptor(this.authorizer, this.dio);

  /// What decides which requests carry the session.
  final Authorizer authorizer;

  /// The client a request is sent again through.
  final Dio dio;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final uri = options.uri;
    if (!authorizer.covers(uri)) return handler.next(options);
    try {
      final previous = options.extra[_attemptKey];
      final attempt = await authorizer.authorize(
        options.method,
        uri,
        previous: previous is AuthAttempt ? previous : null,
      );
      options.headers.addAll(attempt.headers);
      options.extra[_attemptKey] = attempt;
      handler.next(options);
    } on Object catch (error) {
      // AuthRejected and AuthUnavailable (the refresh before the request), or a proof that could
      // not be made: the request is not sent.
      handler.reject(DioException(requestOptions: options, error: error), true);
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    // A success is never sent again: asking records a DPoP-Nonce, and that is all. A client
    // that accepts a 401 as a response (validateStatus) is treated like onError below.
    if ((response.statusCode ?? 0) < 400) {
      final attempt = response.requestOptions.extra[_attemptKey];
      if (attempt is AuthAttempt) {
        try {
          await authorizer.retry(
            attempt,
            statusCode: response.statusCode ?? 0,
            headers: _headers(response),
          );
        } on Object {
          // Nothing to refresh on a success.
        }
      }
      return handler.next(response);
    }
    try {
      final again = await _replay(response);
      handler.next(again ?? response);
    } on AuthUnavailable catch (error) {
      handler.reject(
        DioException(requestOptions: response.requestOptions, error: error),
      );
    } on DioException catch (error) {
      handler.reject(error);
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final response = err.response;
    if (response == null) return handler.next(err);
    try {
      final again = await _replay(response);
      if (again == null) return handler.next(err);
      handler.resolve(again);
    } on AuthUnavailable catch (error) {
      handler.reject(
        DioException(requestOptions: err.requestOptions, error: error),
      );
    } on DioException catch (error) {
      handler.reject(error);
    }
  }

  /// The answer to sending [response]'s request again, or null when it stands. Throws
  /// [AuthUnavailable] when the refresh could not run.
  Future<Response<dynamic>?> _replay(Response<dynamic> response) async {
    final options = response.requestOptions;
    final attempt = options.extra[_attemptKey];
    if (attempt is! AuthAttempt) return null;
    final again = await authorizer.retry(
      attempt,
      statusCode: response.statusCode ?? 0,
      headers: _headers(response),
    );
    if (!again || options.data is FormData) return null;
    // Marked, so a write guard that refuses re-sends can let this one through. onRequest
    // authorizes again, with the attempt that was just answered.
    options.extra[authReplayKey] = true;
    return dio.fetch<dynamic>(options);
  }

  /// A response's headers with lower-case names, as `package:http` gives them.
  static Map<String, String> _headers(Response<dynamic> response) => {
    for (final entry in response.headers.map.entries)
      entry.key.toLowerCase(): entry.value.join(', '),
  };
}
