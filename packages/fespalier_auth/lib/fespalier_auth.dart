/// Signed-in routes for fespalier (since 0.9.0): a session provider, guards, session storage,
/// lazy single-flight renewal and an authenticated transport, with pluggable backends.
///
/// The core is protocol-agnostic since 0.21.0: it knows a `SessionCredential`, a
/// `RequestAuthenticator` and an `AuthBackend`, and never a token, an OpenID Connect flow or a
/// key. `package:fespalier_oidc` is the token backend (Keycloak first, bearer and DPoP), and
/// `package:fespalier_sign_keypair` the device-signed one.
///
/// ```dart
/// // lib/app/startup.dart: read the stored session before the first frame
/// FutureOr<List<Override>> startup() => restoreAuth(authSetup());
///
/// // lib/app/(signed-in)/guard.dart: the routes under it need a session
/// GuardResult guard(Ref ref, {required Uri uri}) =>
///     requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));
///
/// // lib/app/sign-in/guard.dart: signing in sends the user back by itself
/// GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);
/// ```
///
/// The core adds no timer, no `Future.delayed` and no listener: the clock is read when the
/// credential is asked for, and a renewal is lazy (the first request that finds it expired) and
/// single-flight (one renewal at a time, shared). It sends only through
/// `package:fespalier_transport`'s `HttpTransport`, so it links neither `package:http` nor Dio:
/// `SessionTransport` is the transport that carries the session, and
/// `package:fespalier_auth/testing.dart` has a fake backend and `fakeAuth` for widget tests.
library;

export 'src/authenticator.dart';
export 'src/authorizer.dart' show AuthAttempt, Authorizer, authorizer;
export 'src/backend.dart';
export 'src/config.dart'
    show AuthConfig, authConfig, authInitialState, restoreAuth;
export 'src/errors.dart';
export 'src/guards.dart';
export 'src/notifier.dart';
export 'src/session.dart';
export 'src/session_transport.dart' show SessionTransport, authTransport;
export 'src/store.dart';
