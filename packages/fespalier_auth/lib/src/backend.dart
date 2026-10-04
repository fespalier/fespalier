import 'dart:async';

import 'session.dart';

/// What a sign-in asks for (since 0.9.0). Not sealed: an app adds its own (a magic-link code, a
/// passkey), and its backend reads it.
abstract class SignInRequest {
  /// A request; subclasses are `const` too.
  const SignInRequest();
}

/// Sign in in the browser (OpenID Connect).
final class BrowserSignIn extends SignInRequest {
  /// A browser sign-in. [prompt] `login` forces the login form over a single-sign-on cookie.
  const BrowserSignIn({
    this.loginHint,
    this.prompt,
    this.parameters = const {},
  });

  /// Pre-fills the user name (`login_hint`).
  final String? loginHint;

  /// `login` shows the login form even when the browser has a session, `none` fails instead of
  /// showing it, `consent` and `select_account` ask again.
  final String? prompt;

  /// Extra authorization parameters, e.g. `{'kc_idp_hint': 'google', 'ui_locales': 'fr'}`.
  final Map<String, String> parameters;
}

/// A user name and a password, for a backend that takes them. `toString` hides both.
final class PasswordSignIn extends SignInRequest {
  /// The credentials the user typed.
  const PasswordSignIn({required this.username, required this.password});

  /// The account's user name or e-mail address.
  final String username;

  /// The password, as typed.
  final String password;

  @override
  String toString() => 'PasswordSignIn(<redacted>)';
}

/// Where sessions come from (since 0.9.0). Implement it for a backend `fespalier_auth` does not
/// ship; `OidcBackend` and `FakeAuthBackend` are two.
abstract class AuthBackend {
  /// A backend; subclasses may be `const`.
  const AuthBackend();

  /// A short constant naming the backend: `oidc`, `firebase`, `demo`. It is what a stored session
  /// is tied to, and telemetry's `fespalier.auth.backend`: never a URL or an id.
  String get name;

  /// The proof of possession (DPoP) this backend's tokens are bound with, or null.
  ProofOfPossession? get proof => null;

  /// True when the backend's SDK keeps the session itself (Firebase, Supabase): the token store
  /// is not used.
  bool get keepsOwnSession => false;

  /// With [keepsOwnSession]: the session the SDK holds at a cold start, read once by
  /// `restoreAuth`. Return it synchronously when the SDK can.
  FutureOr<AuthSession?> currentSession() => null;

  /// Signs in. Throws `AuthCancelled` when the user gave up, `FieldErrors` for wrong credentials
  /// (a form shows them), `AuthRejected` when the server refused, and anything else when it
  /// could not ask.
  Future<AuthSession> signIn(SignInRequest request);

  /// New tokens for [session]. Throws `AuthRejected` when the server refused (the session is
  /// over), and anything else when it could not ask (the session stays).
  Future<AuthSession> refresh(AuthSession session);

  /// Ends [session] on the server, best effort: the local sign-out has already happened.
  Future<void> signOut(AuthSession session);
}

/// Proof of possession for requests: DPoP (RFC 9449) (since 0.9.0).
/// `package:fespalier_sign_keypair` implements it (`DpopProof`).
///
/// The backend owns it: it signs the token-endpoint calls with it, and the `Authorizer` signs
/// each API call.
abstract interface class ProofOfPossession {
  /// The key's RFC 7638 thumbprint (the key is made on first use); null when proofs are off on
  /// this device.
  Future<String?> thumbprint();

  /// The headers proving possession for [method] [uri] (`{'DPoP': '<jwt>'}`), with `ath` when
  /// [accessToken] is given; empty when proofs are off.
  Future<Map<String, String>> headers({
    required String method,
    required Uri uri,
    String? accessToken,
  });

  /// Called with every response to a request [headers] was used for: records a `DPoP-Nonce`, and
  /// returns true when the request should be sent once more with new headers (a nonce challenge,
  /// a clock correction), never when [retried] is true. [body] is given for authorization-server
  /// responses.
  bool onResponse({
    required Uri uri,
    required int statusCode,
    required Map<String, String> headers,
    String? body,
    required bool retried,
  });

  /// The session ended: forget nonces and the clock correction. `DpopProof` also deletes the
  /// key.
  Future<void> reset();
}
