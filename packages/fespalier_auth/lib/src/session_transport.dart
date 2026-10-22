import 'dart:async';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'authorizer.dart';
import 'config.dart';
import 'errors.dart';
import 'util.dart';

/// The most bytes of a 401 or a 403 `SessionTransport` reads to tell the authenticator why a
/// server refused: a larger body is handed back unread.
const int _maxJudgedBody = 64 * 1024;

/// A transport whose requests to `AuthConfig.apiOrigins` carry the session (since 0.21.0; it
/// replaces `SessionClient` and `SessionInterceptor`): whatever the backend's
/// `RequestAuthenticator` adds, an `Authorization` header or a signature.
///
/// ```dart
/// final transport = SessionTransport(
///   WriteGuardTransport(HttpClientTransport(client)),
///   ref.watch(authorizer),
/// );
/// ```
///
/// A request to any other origin goes through untouched. When the credential has expired, the
/// request waits for one shared renewal. What a response means is the authenticator's to say
/// (`AuthVerdict`): a 401 renews once and sends the request again, a nonce challenge sends it
/// again with the nonce. At most three sends per request, and **every send is authorized again**
/// with the exact bytes of the body, so a signature is fresh each time; a send that follows a
/// verdict carries `transportReplayKey` in its attributes, which a write guard lets through. The
/// body of a 401 or a 403 is read (64 KiB at most) before the authenticator is asked, and handed
/// on to the caller whole.
///
/// A request with a streamed body (`TransportRequest.replayable` is false) is sent once: the
/// caller gets the 401, after the renewal, so its next attempt works; an authenticator that needs
/// the bytes refuses it with an `ArgumentError`.
///
/// Under Dio, put it below `TransportAdapter`, so a retrier above sends through it again and
/// each of its sends is signed afresh.
///
/// **One logical request, however many sends (since 0.21.0).** A retrier above the session
/// (`dio_smart_retry`, a `RetryClient`) calls it again for the same request, and what the
/// session settled the first time stands, through the request's `TransportMemo` (the client
/// gives every send of one request the same memo):
///
/// * a request the session refused (an `AuthRejected`: the renewal was refused, the server ended
///   the session) is refused again with the same error, with no renewal and no send, so a retrier
///   that retries every error cannot send it out unauthenticated;
/// * a request authorized for user A is never sent again as B, nor without a session, when the
///   user signed out or another signed in between two sends: `AuthRejected`, no send (a request
///   that could not get the session, an `AuthUnavailable`, is held to the user who wanted it too);
/// * a request renews at most once, however many sends it takes: a 401, a 503 and a 401 renew
///   once, and the second 401 is the answer.
///
/// A request with no memo (a client that keeps none) is a request seen once. `TransportClient`
/// keeps one per `http.BaseRequest`, so a `RetryClient`, which sends copies, gets none of this.
final class SessionTransport implements HttpTransport {
  /// A transport over [authorizer], sending through [inner].
  const SessionTransport(this.inner, this.authorizer);

  /// The transport every request goes to.
  final HttpTransport inner;

  /// What decides which requests carry the session.
  final Authorizer authorizer;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    if (!authorizer.covers(request.uri)) return inner.send(request);
    // The request's memo, when its client keeps one across sends: what an earlier send of this
    // same logical request settled stands for this one (a retrier above sends it again).
    final memo = request.memo ?? TransportMemo();
    final refused = memo.get<AuthRejected>(_refusedKey);
    if (refused != null) throw refused;
    final wanted = memo.get<String>(_userKey);
    if (wanted != null && authorizer.userId != wanted) {
      // A request made for one user is never sent again as another, nor without the session.
      return _refuse(memo, const AuthRejected());
    }
    try {
      return await _send(request, memo);
    } on AuthRejected catch (error) {
      memo.set(_refusedKey, error);
      rethrow;
    } on AuthUnavailable {
      // The request wanted the session and could not get it: a later send of it is not made
      // without it, nor for another user.
      final who = authorizer.userId;
      if (who != null) memo.putIfAbsent(_userKey, who);
      rethrow;
    }
  }

  Never _refuse(TransportMemo memo, AuthRejected error) {
    memo.set(_refusedKey, error);
    throw error;
  }

  Future<TransportResponse> _send(
    TransportRequest request,
    TransportMemo memo,
  ) async {
    var attempt = await authorizer.authorize(request);
    if (attempt.session case final session?) {
      memo.putIfAbsent(_userKey, session.user.id);
    }
    while (true) {
      var response = await inner.send(request.authorized(attempt));
      if (response.statusCode == 401 || response.statusCode == 403) {
        response = await _judged(response);
      }
      final bool again;
      try {
        again = await authorizer.retry(
          attempt,
          response,
          mayRenew: (memo.get<int>(_renewalsKey) ?? 0) == 0,
        );
      } catch (_) {
        unawaited(_discard(response));
        rethrow;
      }
      if (!again || !request.replayable) return response;
      await _discard(response);
      final renewedBefore = attempt.renewed;
      attempt = await authorizer.authorize(request, previous: attempt);
      // The previous attempt carried headers (retry() says yes only then): the user signed out
      // while the answer was read. The replay is not sent without the session.
      if (attempt.request == null) throw const AuthRejected();
      if (attempt.renewed && !renewedBefore) {
        // One renewal per logical request, whatever number of sends it takes.
        memo.set(_renewalsKey, (memo.get<int>(_renewalsKey) ?? 0) + 1);
      }
    }
  }
}

/// The memo keys `SessionTransport` owns: the `AuthRejected` that stopped the request, the id of
/// the user it was authorized for, and the number of renewals it has spent.
const String _refusedKey = 'fespalier_auth.refused';
const String _userKey = 'fespalier_auth.user';
const String _renewalsKey = 'fespalier_auth.renewals';

/// [response] with its body read, up to [_maxJudgedBody] bytes; a larger one is handed back
/// unbuffered (its stream whole).
Future<TransportResponse> _judged(TransportResponse response) async {
  if (response.isBuffered) return response;
  final length = int.tryParse(response.headers['content-length'] ?? '');
  if (length != null && length > _maxJudgedBody) return response;
  final chunks = <List<int>>[];
  var total = 0;
  final iterator = StreamIterator<List<int>>(response.body);
  while (await iterator.moveNext()) {
    chunks.add(iterator.current);
    total += iterator.current.length;
    if (total > _maxJudgedBody) {
      Stream<List<int>> whole() async* {
        yield* Stream<List<int>>.fromIterable(chunks);
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
      }

      return TransportResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: whole(),
        reasonPhrase: response.reasonPhrase,
      );
    }
  }
  final all = Uint8List(total);
  var at = 0;
  for (final chunk in chunks) {
    all.setRange(at, at + chunk.length, chunk);
    at += chunk.length;
  }
  return TransportResponse.fromBytes(
    statusCode: response.statusCode,
    headers: response.headers,
    bytes: all,
    reasonPhrase: response.reasonPhrase,
  );
}

/// Reads and drops a response that is not going to be used, so its connection is freed.
Future<void> _discard(TransportResponse response) =>
    response.body.drain<void>().then<void>((_) {}, onError: (Object _) {});

/// A [SessionTransport] on the transport of the app's `AuthConfig` (since 0.21.0), for the
/// clients an app builds over it: `TransportClient` (`fespalier_http`) for `package:http` code,
/// `TransportAdapter` (`fespalier_dio`) for a Dio.
///
/// Stable: it depends on the authorizer, which depends on the configuration and not on the
/// session's state, so watching it never loads a `data.dart` again on a renewal. Watch
/// `authUserId` for that.
final Provider<HttpTransport> authTransport = Provider<HttpTransport>(
  (ref) =>
      SessionTransport(ref.watch(authConfig).transport, ref.watch(authorizer)),
  retry: noRetry,
);
