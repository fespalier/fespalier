/// Signed-in routes for fespalier (since 0.9.0): a session provider, guards, token storage, lazy
/// single-flight refresh and an authenticated HTTP client, with pluggable backends.
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
/// The core adds no timer, no `Future.delayed` and no listener: the clock is read when a token is
/// asked for, and a refresh is lazy (the first request that finds the access token expired) and
/// single-flight (one refresh at a time, shared). `package:fespalier_auth/oidc.dart` has an OpenID
/// Connect backend (Keycloak first), `package:fespalier_auth/dio.dart` an interceptor, and
/// `package:fespalier_auth/testing.dart` a fake backend and `fakeAuth` for widget tests.
library;

export 'src/authorizer.dart'
    show AuthAttempt, Authorizer, authBaseClient, authorizer;
export 'src/backend.dart';
export 'src/config.dart'
    show AuthConfig, authConfig, authInitialState, restoreAuth;
export 'src/errors.dart';
export 'src/guards.dart';
export 'src/jwt.dart' show unverifiedJwtClaims;
export 'src/notifier.dart';
export 'src/session.dart';
export 'src/session_client.dart' show SessionClient, authHttpClient;
export 'src/store.dart';
