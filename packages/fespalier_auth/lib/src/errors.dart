import 'package:fespalier/fespalier.dart' show DataRefusal;
import 'package:fespalier_transport/fespalier_transport.dart'
    show CredentialsUnavailable;

import 'session.dart';

/// The server refused the session: an error such as `invalid_grant` (since 0.9.0). The
/// session is over, and the user has to sign in again. A [DataRefusal] (since 0.13.1).
final class AuthRejected implements Exception, DataRefusal {
  /// The refusal: the OAuth [error] code, and the server's [description] when it gave one.
  const AuthRejected([this.error = 'invalid_grant', this.description]);

  /// The error code (`invalid_grant`, `invalid_client`, ...).
  final String error;

  /// The server's `error_description`, when there is one.
  final String? description;

  @override
  String toString() =>
      'AuthRejected: the server refused the session ($error'
      '${description == null ? '' : ': $description'})';
}

/// The session could not be renewed for now (offline, a 5xx): the session stays, and the next
/// request tries again (since 0.9.0).
///
/// A `CredentialsUnavailable` (`package:fespalier_transport`), so a transfer that asked for the
/// credentials reports a network failure, not a lost session. Its text never names the server.
final class AuthUnavailable implements Exception, CredentialsUnavailable {
  /// Wraps what stopped the renewal: [cause].
  const AuthUnavailable(this.cause);

  /// What stopped it: a transport failure, a timeout, a 5xx.
  @override
  final Object cause;

  @override
  String toString() => "AuthUnavailable: couldn't renew the session: $cause";
}

/// What a backend throws from `AuthBackend.renew` when the server ended the session for a reason
/// other than `SignOutReason.expired` (since 0.21.0): a revoked device, say. The state becomes
/// `SignedOut(reason: reason)`, and whoever asked for the renewal gets an [AuthRejected] with
/// [error] and [description].
final class AuthEnded implements Exception {
  /// The session ended for [reason]; [error] and [description] are what the server said.
  const AuthEnded(
    this.reason, {
    this.error = 'invalid_grant',
    this.description,
  });

  /// Why the session ended.
  final SignOutReason reason;

  /// The error code the server gave.
  final String error;

  /// The server's description, when there is one.
  final String? description;

  @override
  String toString() =>
      'AuthEnded: the session ended (${reason.name}: $error'
      '${description == null ? '' : ': $description'})';
}

/// The user closed or cancelled the sign-in (since 0.9.0). Not an error to report: a form shows
/// nothing.
final class AuthCancelled implements Exception {
  /// A cancelled sign-in.
  const AuthCancelled();

  @override
  String toString() => 'AuthCancelled: the sign-in was cancelled';
}

/// `credential()` was asked while nobody is signed in, or the session ended while a request waited
/// for it (since 0.9.0).
final class NotSignedIn extends StateError {
  /// The error for a request made with no session.
  NotSignedIn() : super('fespalier_auth: not signed in');
}

/// What a `RequestAuthenticator` throws from `headers` when the user declined the proof one send
/// needed (since 0.25.0): a biometric or device-credential prompt for a stronger key, say
/// (`UserPresenceRefused` in `package:fespalier_sign_keypair` is one). Not a lost session: nothing
/// is signed out.
///
/// On the first send of a request it fails that request, as any error of `headers` does. On a send
/// the session makes again after a verdict (a replay, `transportReplayKey`), `SessionTransport`
/// hands back the response that asked for the replay instead: the server's refusal stands, so the
/// caller reads the server's answer (a step-up refusal, `StepUpRequired` in a CrateStack client)
/// rather than the prompt's.
abstract interface class ProofDeclined implements Exception {}
