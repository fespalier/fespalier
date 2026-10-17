import 'dart:async';

import 'package:dio/dio.dart';

import 'authorizer.dart';
import 'errors.dart';

const String _attemptKey = 'fespalier_auth.attempt';
const String _wantedByKey = 'fespalier_auth.wanted_by';

/// Adds the session to a Dio's requests to `AuthConfig.apiOrigins`, and sends a request once more
/// after a proof challenge or a 401 (a refresh), like `SessionClient` (since 0.9.0).
///
/// ```dart
/// final dio = Dio();
/// dio.interceptors.add(SessionInterceptor(ref.watch(authorizer), dio));
/// ```
///
/// A request to another origin is untouched. A body that can be read once is not sent again:
/// `FormData`, and a `Stream` (what `DioHttpClient` makes of a streamed or multipart
/// `package:http` request; since 0.16.0). The caller gets the 401, after the refresh, so its next
/// attempt works. A body of bytes (`Uint8List`, a `String`, a map, and what `DioHttpClient` makes
/// of an `http.Request`) is sent again whole. Every response goes through the authorizer, so a
/// DPoP nonce on a success is remembered too, and a request is sent at most three times.
///
/// A request whose session was refused or ended is not sent again without it (since 0.19.0), whoever
/// sends it again: a retrier calls `dio.fetch` with the same options, and the retry is rejected with
/// the `AuthRejected` ([authRefusedKey]), when the user signed out or another signed in between
/// two sends. A send never keeps the headers of the one before.
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
    // A session that was refused stays refused for this request: a retrier sends the very same
    // options again, and the authorizer would now answer "nobody is signed in".
    final refused = options.extra[authRefusedKey];
    if (refused is AuthRejected) {
      return handler.reject(
        DioException(requestOptions: options, error: refused),
        true,
      );
    }
    try {
      final previous = options.extra[_attemptKey];
      final prior = previous is AuthAttempt ? previous : null;
      final attempt = await authorizer.authorize(
        options.method,
        uri,
        previous: prior,
      );
      final hadSession =
          (prior != null && prior.headers.isNotEmpty) ||
          options.extra[authWantedKey] == true;
      if (hadSession && attempt.headers.isEmpty) {
        // The session ended between two sends of one request: it is not sent without it.
        throw const AuthRejected();
      }
      final wantedBy = options.extra[_wantedByKey];
      if (wantedBy != null && attemptUserId(attempt) != wantedBy) {
        // The authorizer failed for another user's session than the one signed in now.
        throw const AuthRejected();
      }
      if (prior != null) {
        // The headers of the send before are stale: a new proof, a new token.
        for (final name in prior.headers.keys.toList()) {
          options.headers.remove(name);
        }
      }
      options.headers.addAll(attempt.headers);
      options.extra[_attemptKey] = attempt;
      handler.next(options);
    } on Object catch (error) {
      // AuthRejected and AuthUnavailable (the refresh before the request), or a proof that could
      // not be made: the request is not sent, and it wanted the session, so a later send of the
      // same options does not go out without it.
      options.extra[authWantedKey] = true;
      // Who wanted it, so a retry is not sent as somebody else (kept under a key of its own: the
      // value of authWantedKey stays true). The first failure's user stands.
      final who = authorizerUserId(authorizer);
      if (who != null) options.extra.putIfAbsent(_wantedByKey, () => who);
      if (error is AuthRejected) options.extra[authRefusedKey] = error;
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
    // A form or a stream body was read by the first send: it is not there to send again, and the
    // refresh above is what makes the caller's next attempt work.
    if (!again || options.data is FormData || options.data is Stream) {
      return null;
    }
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
