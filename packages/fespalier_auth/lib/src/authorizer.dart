import 'dart:async';
import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_transport/fespalier_transport.dart';

import 'authenticator.dart';
import 'config.dart';
import 'errors.dart';
import 'notifier.dart';
import 'session.dart';
import 'util.dart';

/// The credentials one send of a request carried (since 0.9.0). It is an [HttpAuthorization]
/// since 0.15.0.
final class AuthAttempt implements HttpAuthorization {
  AuthAttempt._({
    this.headers = const <String, String>{},
    this.request,
    this.session,
    this.resent = false,
    this.renewed = false,
  });

  /// What the authenticator added to the request (`Authorization`, a signature, an
  /// attestation); empty when nothing was attached.
  @override
  final Map<String, String> headers;

  /// The request as the authenticator saw it; null when nothing was attached.
  final TransportRequest? request;

  /// The session this send was made for; null when nothing was attached.
  final AuthSession? session;

  /// What proved the session on this send; null when nothing was attached.
  SessionCredential? get credential => session?.credential;

  /// Whether this send is the one that follows a `Resend` (a nonce, a clock correction).
  final bool resent;

  /// Whether this send is the one that follows a `Renew`.
  final bool renewed;

  /// Whether this send is the one that follows a `Resend` or a `Renew`, so a request sent again
  /// by the authorizer: `SessionTransport` marks the request's attributes
  /// (`transportReplayKey`).
  @override
  bool get isReplay => resent || renewed;

  bool _resendNext = false;
  bool _renewNext = false;
}

/// What a transport needs from the session (since 0.9.0): the headers for a request, and the
/// answer to "send it once more?". One per container: `ref.watch(authorizer)`.
///
/// `SessionTransport` is the client over it. A client of your own asks [authorize] before each
/// send, with the request and the exact bytes of its body, and [retry] after each response, and
/// sends at most three times.
///
/// It is an [HttpCredentials] since 0.15.0, so a transfer that is not a transport can take it as
/// it is.
final class Authorizer implements HttpCredentials {
  Authorizer._(this._notifier, this._origins, this._authenticator);

  final AuthSessionNotifier _notifier;
  final List<Uri> _origins;
  final RequestAuthenticator _authenticator;

  /// Whether [uri]'s origin (scheme, host and port) is one of `AuthConfig.apiOrigins`. Nothing
  /// else gets a credential.
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

  /// The id of the user signed in now, or null when nobody is (or the session is still being
  /// restored) (since 0.21.0). `SessionTransport` compares it with the user a request was
  /// first authorized for.
  String? get userId => _notifier.session?.user.id;

  /// The headers for [request]: none when its URL is not covered or nobody is signed in;
  /// otherwise the authenticator's, after a renewal when the credential has expired (shared with
  /// every request that finds it expired at the same time).
  ///
  /// The authenticator is given [request] as it is, with the exact bytes of its body in
  /// `TransportRequest.body` (null for a streamed one): a scheme that signs the request signs
  /// them. Throws `AuthRejected` when that renewal was refused (the session is over), or when
  /// [previous] was made for another user than the one signed in now (since 0.19.0), and
  /// `AuthUnavailable` when it could not run. Pass the [previous] attempt of the same request
  /// when sending it again, so the retries are counted; an `ArgumentError` when it is not an
  /// attempt this package made. The result is an [AuthAttempt].
  @override
  Future<AuthAttempt> authorize(
    TransportRequest request, {
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
    final resent = prior != null && (prior.resent || prior._resendNext);
    final renewed = prior != null && (prior.renewed || prior._renewNext);
    AuthAttempt unauthenticated() =>
        AuthAttempt._(resent: resent, renewed: renewed);
    if (!covers(request.uri)) return unauthenticated();
    try {
      await _notifier.credential();
    } on NotSignedIn {
      return unauthenticated();
    }
    // The session as it is after any renewal above: it is what the request is made for.
    final session = _notifier.session;
    if (session == null) return unauthenticated();
    final priorUser = prior?.session?.user.id;
    if (priorUser != null && session.user.id != priorUser) {
      // A request made for one user is never sent again as another.
      throw const AuthRejected();
    }
    final added = await _authenticator.headers(session, request);
    return AuthAttempt._(
      headers: Map<String, String>.unmodifiable(added),
      request: request,
      session: session,
      resent: resent,
      renewed: renewed,
    );
  }

  /// After [response] to [attempt]: asks the authenticator what it means, and says whether to
  /// send the request once more, with `authorize(..., previous: attempt)`.
  ///
  /// The authenticator reads the body only when [response] is buffered (a transport layer
  /// buffers a 401 or a 403 before asking). True for a `Resend` (a nonce, a clock correction:
  /// once), or for a `Renew` after one shared renewal (once). False when the response stands
  /// (`Accept`), and when the renewal was refused (the user is signed out). A `SessionEnded`
  /// verdict signs the user out with its reason and throws `AuthRejected`. Throws
  /// `AuthUnavailable` when the renewal could not run.
  ///
  /// With [mayRenew] false (since 0.21.0) a `Renew` verdict is not acted on: the response
  /// stands, as for a request that has renewed already. `SessionTransport` passes false once the
  /// logical request has spent its renewal on an earlier send.
  @override
  Future<bool> retry(
    covariant AuthAttempt attempt,
    TransportResponse response, {
    bool mayRenew = true,
  }) async {
    final request = attempt.request;
    final session = attempt.session;
    if (request == null || session == null) return false;
    final verdict = _authenticator.judge(
      session,
      request,
      statusCode: response.statusCode,
      headers: response.headers,
      body: response.isBuffered
          ? utf8.decode(await response.bytes(), allowMalformed: true)
          : null,
      retried: attempt.isReplay,
    );
    switch (verdict) {
      case Accept():
        return false;
      case Resend():
        if (attempt.resent) return false;
        attempt._resendNext = true;
        return true;
      case Renew(:final hint):
        if (attempt.renewed || !mayRenew) return false;
        try {
          await _notifier.credential(rejected: session.credential, hint: hint);
        } on AuthRejected {
          return false;
        } on NotSignedIn {
          return false;
        }
        attempt._renewNext = true;
        return true;
      case SessionEnded(:final reason):
        await _notifier.endSession(reason, only: session.user.id);
        throw const AuthRejected();
    }
  }
}

/// The [Authorizer] of the app's session (since 0.9.0). Throws a `StateError` that says what to do
/// when `AuthConfig.apiOrigins` is empty.
///
/// It does not depend on the session's state, so watching it never rebuilds anything on a
/// renewal.
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
    config.backend.authenticator,
  );
}, retry: noRetry);
