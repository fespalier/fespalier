import 'dart:async';

import 'authenticator.dart';
import 'challenge.dart';
import 'session.dart';

/// What a sign-in asks for (since 0.9.0). Not sealed: an app adds its own (a magic-link code, a
/// passkey), and its backend reads it. `package:fespalier_oidc` has `BrowserSignIn` and
/// `PasswordSignIn`.
abstract class SignInRequest {
  /// A request; subclasses are `const` too.
  const SignInRequest();
}

/// Where sessions come from (since 0.9.0). Implement it for a scheme `fespalier_auth` does not
/// ship; `OidcBackend` (`package:fespalier_oidc`), `DeviceAuthBackend`
/// (`package:fespalier_sign_keypair`) and `FakeAuthBackend` are three.
///
/// A backend owns what is specific to its scheme: how a session is made ([signIn]), how it is
/// renewed ([renew]), what proves it on each request ([authenticator]) and what is left when it
/// ends ([discard]). The core owns when: lazy single-flight renewal, the store, the guards, the
/// clients.
abstract class AuthBackend {
  /// A backend; subclasses may be `const`.
  const AuthBackend();

  /// A short constant naming the backend: `oidc`, `device`, `demo`. It is what a stored session
  /// is tied to, and telemetry's `fespalier.auth.backend`: never a URL or an id.
  String get name;

  /// A short constant naming how requests are authenticated: `bearer`, `dpop`, `device`.
  /// Telemetry's `fespalier.auth.scheme` (since 0.21.0). The backend's [name] by default.
  String get scheme => name;

  /// What authenticates each request and reads each response (since 0.21.0).
  RequestAuthenticator get authenticator;

  /// True when the backend's SDK keeps the session itself (Firebase, Supabase): the token store
  /// is not used.
  bool get keepsOwnSession => false;

  /// With [keepsOwnSession]: the session the SDK holds at a cold start, read once by
  /// `restoreAuth`. Return it synchronously when the SDK can.
  FutureOr<AuthSession?> currentSession() => null;

  /// Reads the credential `SessionCredential.toJson` wrote (since 0.21.0). Throws
  /// [FormatException] on anything else: `restoreAuth` reports it and drops the stored session.
  SessionCredential readCredential(Map<String, Object?> json);

  /// How long before `SessionCredential.expiresAt` the credential is renewed (lazily, by the
  /// next request that asks for it). Zero renews at the last moment; a token backend picks
  /// seconds, a device attestation hours.
  Duration get renewAhead;

  /// Signs in. Throws `AuthCancelled` when the user gave up, `FieldErrors` for wrong credentials
  /// (a form shows them), `AuthRejected` when the server refused, and anything else when it
  /// could not ask.
  Future<AuthSession> signIn(SignInRequest request);

  /// A renewed [session] (was `refresh` before 0.21.0). Throws `AuthRejected` when the server
  /// refused (the session is over: `SignedOut(reason: SignOutReason.expired)`, or `AuthEnded`
  /// to give another reason), and anything else when it could not ask (offline, a 5xx): the
  /// session stays and the next request asks again. [hint] is `Renew.hint`, for instance which
  /// key role to renew; null for the default.
  Future<AuthSession> renew(AuthSession session, {Object? hint});

  /// The same user, proved again to what [challenge] asks (since 0.25.0): an OpenID Connect
  /// re-authorization with `acr_values`, `max_age` or `prompt=login` (`OidcBackend`). The core
  /// calls it for a `StepUp` verdict and for `AuthSessionNotifier.stepUp`, one at a time.
  ///
  /// Return the new session, with `AuthSession.authenticatedAt` when the backend knows when the
  /// user authenticated (the core sets the time of the step-up otherwise). Throw `AuthCancelled`
  /// when the user gave up, `AuthRejected` when the server refused (the session stays: it is not
  /// a renewal), and anything else when it could not ask. A session for another user is refused
  /// by the core.
  ///
  /// The default throws an `UnsupportedError`: a backend that cannot ask the user again (a device
  /// session steps up per request, with the user-present key) never gets a `StepUp` verdict from
  /// its own authenticator.
  Future<AuthSession> stepUp(
    AuthSession session,
    StepUpChallenge challenge,
  ) async => throw UnsupportedError(
    'fespalier_auth: the "$name" backend cannot step up the user\'s authentication',
  );

  /// The check `restoreAuth` runs on a stored session after the expiry rule (since 0.21.0): null
  /// keeps it, a reason drops it (`SignOutReason.keyLost` when the device key is gone, or is not
  /// the one the credential is bound to).
  FutureOr<SignOutReason?> check(AuthSession session) => null;

  /// Ends [session] on the server, best effort: the local sign-out has already happened (a
  /// device revoke, a token revocation).
  Future<void> signOut(AuthSession session);

  /// Forgets the local secrets bound to [session] (since 0.21.0): keys, nonces, a clock
  /// correction. Called after [signOut], and when the server ended the session.
  Future<void> discard(AuthSession session) async {}
}
