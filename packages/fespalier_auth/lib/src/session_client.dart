import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:http/http.dart' as http;

import 'authorizer.dart';
import 'util.dart';

/// A `package:http` client whose requests to `AuthConfig.apiOrigins` carry the session (since
/// 0.9.0): `Authorization: Bearer <token>`, or `Authorization: DPoP <token>` and a `DPoP` proof for
/// a DPoP-bound token.
///
/// A request to any other origin goes through untouched. When the access token has expired, the
/// request waits for one shared refresh. A 401 to the token it carried refreshes once and sends
/// the request again; a DPoP nonce challenge sends it again with the nonce. At most three sends
/// per request, and only a request that can be sent again (an `http.Request`, which `get`,
/// `post`, `put`, `patch` and `delete` make): a multipart or streamed body is sent once, and the
/// caller gets the 401, after the refresh, so its next attempt works.
///
/// ```dart
/// final response = await ref.watch(authHttpClient).get(Uri.parse('https://api.example.com/orders'));
/// ```
final class SessionClient extends http.BaseClient {
  /// A client over [authorizer], sending through [inner] (a new `http.Client` by default).
  SessionClient(this.authorizer, {http.Client? inner})
    : _inner = inner ?? http.Client();

  /// What decides which requests carry the session.
  final Authorizer authorizer;

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!authorizer.covers(request.url)) return _inner.send(request);
    final replayable = request is http.Request;
    var attempt = await authorizer.authorize(request.method, request.url);
    while (true) {
      final toSend = request is http.Request
          ? _copy(request, attempt.headers)
          : (request..headers.addAll(attempt.headers));
      final response = await _inner.send(toSend);
      final bool again;
      try {
        again = await authorizer.retry(
          attempt,
          statusCode: response.statusCode,
          headers: response.headers,
        );
      } catch (_) {
        unawaited(_discard(response));
        rethrow;
      }
      if (!again || !replayable) return response;
      await _discard(response);
      attempt = await authorizer.authorize(
        request.method,
        request.url,
        previous: attempt,
      );
    }
  }

  @override
  void close() => _inner.close();
}

/// Reads and drops a response that is not going to be used, so its connection is freed.
Future<void> _discard(http.StreamedResponse response) =>
    response.stream.drain<void>().then<void>((_) {}, onError: (Object _) {});

/// A request of its own to send: a [http.Request] is finalized by sending it, so each attempt
/// needs a new one.
http.Request _copy(http.Request original, Map<String, String> credentials) =>
    http.Request(original.method, original.url)
      ..headers.addAll(original.headers)
      ..headers.addAll(credentials)
      ..bodyBytes = original.bodyBytes
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection;

/// A [SessionClient] on [authBaseClient] (since 0.9.0), for a `data.dart` or an `action.dart`.
///
/// Stable: it depends on the authorizer, which depends on the configuration and not on the
/// session's state, so watching it never loads a `data.dart` again on a token refresh. Watch
/// `authUserId` for that.
final Provider<http.Client> authHttpClient = Provider<http.Client>(
  (ref) =>
      SessionClient(ref.watch(authorizer), inner: ref.watch(authBaseClient)),
  retry: noRetry,
);
