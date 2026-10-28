import 'package:fespalier_transport/fespalier_transport.dart';

import 'challenge.dart';
import 'session.dart';

/// What a response means for the session (since 0.21.0). Sealed: switch on it.
///
/// Anything ambiguous is [Accept]: the session is never wiped, and a request never loops, on a
/// response that could be about something else.
sealed class AuthVerdict {
  /// A verdict; the subclasses are [Accept], [Resend], [Renew], [StepUp] (since 0.25.0) and
  /// [SessionEnded].
  const AuthVerdict();
}

/// Hand the response back as it is.
final class Accept extends AuthVerdict {
  /// The response stands.
  const Accept();

  @override
  String toString() => 'Accept()';
}

/// Same session, new headers (a DPoP nonce, a clock correction): send the request again, once.
final class Resend extends AuthVerdict {
  /// Send it again with fresh headers.
  const Resend();

  @override
  String toString() => 'Resend()';
}

/// The credential was refused or has run out: renew the session (one renewal at a time, shared),
/// then send the request again, once.
final class Renew extends AuthVerdict {
  /// Renew; [hint] goes to `AuthBackend.renew` (for instance which key role).
  const Renew({this.hint});

  /// What the authenticator wants the backend to know about this renewal; null for none.
  final Object? hint;

  @override
  String toString() => 'Renew()';
}

/// The credential is good but the user's authentication is too weak or too old for this request
/// (RFC 9470, `insufficient_user_authentication`) (since 0.25.0): the user proves who they are
/// again (`AuthBackend.stepUp`: one at a time, shared by every request that asks), then the
/// request is sent again, once.
///
/// It is not a [Renew]: a renewal is silent and its refusal ends the session, while a step-up
/// asks the user and its refusal or cancellation leaves the session as it was and the request's
/// 401 stands. A request steps up at most once, so a second refusal is the answer.
final class StepUp extends AuthVerdict {
  /// Step up to what [challenge] asks for.
  const StepUp(this.challenge);

  /// What the server asks of the user's authentication.
  final StepUpChallenge challenge;

  @override
  String toString() => 'StepUp($challenge)';
}

/// The server confirmed the session is dead: sign out with [reason], forget what is bound to it
/// and fail the request with `AuthRejected`.
final class SessionEnded extends AuthVerdict {
  /// The session ended for [reason].
  const SessionEnded(this.reason);

  /// Why; it becomes `SignedOut(reason: reason)`.
  final SignOutReason reason;

  @override
  String toString() => 'SessionEnded(${reason.name})';
}

/// How a scheme authenticates requests and reads the answers (since 0.21.0): the part of a
/// backend that runs on every send. `BearerAuthenticator` (`package:fespalier_oidc`) adds
/// `Authorization: Bearer <token>`; `DeviceSigner` (`package:fespalier_sign_keypair`) signs the
/// request with the device key.
abstract interface class RequestAuthenticator {
  /// The headers for one send of [request], to add to its own. [request] has the exact bytes of
  /// the body in `TransportRequest.body` (null for a streamed body, which can be signed only by a
  /// scheme that does not need it: throw an `ArgumentError` otherwise), so a signature covers
  /// the bytes that are sent. Called again for every send, retries included, so a signature is
  /// fresh each time. Throw to refuse the send (the request is not made).
  Future<Map<String, String>> headers(
    AuthSession session,
    TransportRequest request,
  );

  /// What a response to a send of [request] means for [session]. [retried] is true when this
  /// send already followed a [Resend] or a [Renew]. [body] is the response body when it was
  /// read (the transport layer reads a 401 or a 403 before asking), else null; [headers] has
  /// lower-case names.
  AuthVerdict judge(
    AuthSession session,
    TransportRequest request, {
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  });
}
