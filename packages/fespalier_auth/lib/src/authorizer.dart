import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:http/http.dart' as http;

import 'backend.dart';
import 'config.dart';
import 'errors.dart';
import 'notifier.dart';
import 'session.dart';
import 'util.dart';

/// The credentials one send of a request carried (since 0.9.0). It is an [HttpAuthorization]
/// since 0.15.0.
final class AuthAttempt implements HttpAuthorization {
  AuthAttempt._({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.accessToken,
    this.proofUsed = false,
    this.proofRetried = false,
    this.refreshRetried = false,
  });

  /// The HTTP method this send is for.
  @override
  final String method;

  /// The URL this send is for.
  @override
  final Uri uri;

  /// `Authorization`, and `DPoP` for a DPoP-bound token; empty when none was attached.
  @override
  final Map<String, String> headers;

  /// The access token the headers carry; null when none was attached.
  final String? accessToken;

  /// Whether this send carried a proof of possession.
  final bool proofUsed;

  /// Whether this send is the one that follows a proof challenge (a nonce, a clock correction).
  final bool proofRetried;

  /// Whether this send is the one that follows a refresh.
  final bool refreshRetried;

  /// Whether this send is the one that follows a challenge or a refresh, so a request sent again
  /// by the authorizer: `SessionClient` marks the request (`isAuthReplay`), and
  /// `SessionInterceptor` sets `options.extra[authReplayKey]`.
  @override
  bool get isReplay => proofRetried || refreshRetried;

  bool _proofRetryNext = false;
  bool _refreshRetryNext = false;
}

/// The `RequestOptions.extra` key `SessionInterceptor` sets to `true` on a request it sends again
/// after a proof challenge or a 401 (since 0.9.0): `fespalier.auth.replay`. A write guard that
/// refuses re-sends lets this one through. Never sent to a server.
const String authReplayKey = 'fespalier.auth.replay';

/// What an HTTP client needs from the session (since 0.9.0): the headers for a request, and the
/// answer to "send it once more?". One per container: `ref.watch(authorizer)`.
///
/// `SessionClient` and `SessionInterceptor` (dio) are two clients over it. A client of your own
/// asks [authorize] before each send and [retry] after each response, and sends at most three
/// times.
///
/// It is an [HttpCredentials] since 0.15.0, so a transfer that is not an `http.Client` can take
/// it as it is.
final class Authorizer implements HttpCredentials {
  Authorizer._(this._notifier, this._origins, this._proof);

  final AuthSessionNotifier _notifier;
  final List<Uri> _origins;
  final ProofOfPossession? _proof;

  /// Whether [uri]'s origin (scheme, host and port) is one of `AuthConfig.apiOrigins`. Nothing
  /// else gets a token.
  @override
  bool covers(Uri uri) {
    if (uri.host.isEmpty) return false;
    for (final origin in _origins) {
      if (origin.scheme == uri.scheme &&
          origin.host == uri.host &&
          origin.port == uri.port) {
        return true;
      }
    }
    return false;
  }

  /// The headers for [method] [uri]: none when [uri] is not covered or nobody is signed in;
  /// otherwise the session's, after a refresh when the access token has expired (shared with every
  /// request that finds it expired at the same time).
  ///
  /// Throws `AuthRejected` when that refresh was refused (the session is over), and
  /// `AuthUnavailable` when it could not run. Pass the [previous] attempt of the same request
  /// when sending it again, so the retries are counted; an `ArgumentError` when it is not an
  /// attempt this package made. The result is an [AuthAttempt].
  @override
  Future<AuthAttempt> authorize(
    String method,
    Uri uri, {
    HttpAuthorization? previous,
  }) async {
    if (previous != null && previous is! AuthAttempt) {
      throw ArgumentError.value(
        previous,
        'previous',
        'not an AuthAttempt: pass the attempt the Authorizer returned for this request',
      );
    }
    final prior = previous as AuthAttempt?;
    final proofRetried =
        prior != null && (prior.proofRetried || prior._proofRetryNext);
    final refreshRetried =
        prior != null && (prior.refreshRetried || prior._refreshRetryNext);
    AuthAttempt unauthenticated() => AuthAttempt._(
      method: method,
      uri: uri,
      proofRetried: proofRetried,
      refreshRetried: refreshRetried,
    );
    if (!covers(uri)) return unauthenticated();
    final AuthTokens tokens;
    try {
      tokens = await _notifier.tokens();
    } on NotSignedIn {
      return unauthenticated();
    }
    if (!tokens.isDpop) {
      return AuthAttempt._(
        method: method,
        uri: uri,
        headers: {'Authorization': 'Bearer ${tokens.accessToken}'},
        accessToken: tokens.accessToken,
        proofRetried: proofRetried,
        refreshRetried: refreshRetried,
      );
    }
    final proof = _proof;
    if (proof == null) {
      throw StateError(
        'fespalier_auth: the access token is DPoP-bound (token_type DPoP), but the backend has '
        'no proof of possession: pass proof: DpopProof.device() '
        '(package:fespalier_sign_keypair) to the backend',
      );
    }
    final proofHeaders = await proof.headers(
      method: method,
      uri: uri,
      accessToken: tokens.accessToken,
    );
    return AuthAttempt._(
      method: method,
      uri: uri,
      headers: {'Authorization': 'DPoP ${tokens.accessToken}', ...proofHeaders},
      accessToken: tokens.accessToken,
      proofUsed: true,
      proofRetried: proofRetried,
      refreshRetried: refreshRetried,
    );
  }

  /// After the response to [attempt] ([statusCode] and its [headers], with lower-case names):
  /// records a `DPoP-Nonce`, and says whether to send the request once more, with
  /// `authorize(..., previous: attempt)`.
  ///
  /// True for a proof challenge (a nonce, a clock correction: once), or for a 401 to the access
  /// token it carried, after one shared refresh (once). False when the response stands, and when
  /// the refresh was refused (the user is signed out). Throws `AuthUnavailable` when the
  /// refresh could not run.
  @override
  Future<bool> retry(
    covariant AuthAttempt attempt, {
    required int statusCode,
    required Map<String, String> headers,
  }) async {
    final token = attempt.accessToken;
    if (token == null) return false;
    final proof = _proof;
    if (attempt.proofUsed &&
        proof != null &&
        proof.onResponse(
          uri: attempt.uri,
          statusCode: statusCode,
          headers: headers,
          retried: attempt.proofRetried,
        )) {
      attempt._proofRetryNext = true;
      return true;
    }
    if (statusCode != 401 || attempt.refreshRetried) return false;
    try {
      await _notifier.tokens(rejected: token);
    } on AuthRejected {
      return false;
    } on NotSignedIn {
      return false;
    }
    attempt._refreshRetryNext = true;
    return true;
  }
}

/// The [Authorizer] of the app's session (since 0.9.0). Throws a `StateError` that says what to do
/// when `AuthConfig.apiOrigins` is empty.
///
/// It does not depend on the session's state, so watching it never rebuilds anything on a token
/// refresh.
final Provider<Authorizer> authorizer = Provider<Authorizer>((ref) {
  final config = ref.watch(authConfig);
  if (config.apiOrigins.isEmpty) {
    throw StateError(
      'fespalier_auth: AuthConfig.apiOrigins is empty, so no request would carry the session; '
      "list your API's origins, e.g. apiOrigins: [Uri.parse('https://api.example.com')]",
    );
  }
  return Authorizer._(
    ref.read(authSession.notifier),
    List<Uri>.unmodifiable(config.apiOrigins),
    config.backend.proof,
  );
}, retry: noRetry);

/// The client `SessionClient` sends through (since 0.9.0): override it with a `MockClient` in a
/// test. Closed with the container.
final Provider<http.Client> authBaseClient = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
}, retry: noRetry);
