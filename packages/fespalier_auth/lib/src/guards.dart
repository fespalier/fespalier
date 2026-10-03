import 'package:fespalier/fespalier.dart';

import 'notifier.dart';
import 'session.dart';

enum _Phase { restoring, signedOut, signedIn }

_Phase _phaseOf(SessionState state) => switch (state) {
  SessionRestoring() => _Phase.restoring,
  SignedOut() => _Phase.signedOut,
  SignedIn() => _Phase.signedIn,
};

GuardResult _check(
  Ref ref,
  Uri uri, {
  required TypedLocation Function(String from) signIn,
  bool Function(AuthUser user)? test,
  TypedLocation? forbidden,
}) {
  // Only the phase is watched, so a token refresh (another SignedIn) never runs a guard again.
  switch (ref.watch(authSession.select(_phaseOf))) {
    case _Phase.signedOut:
      return signIn(uri.toString()).location;
    case _Phase.signedIn:
      if (test == null) return null;
      final allowed = ref.watch(
        authUser.select((user) => user != null && test(user)),
      );
      return allowed ? null : forbidden?.location;
    case _Phase.restoring:
      // Only without restoreAuth in startup(): the answer waits for the stored session. It reads
      // the notifier, not the ref, which is gone by then.
      final notifier = ref.read(authSession.notifier);
      return notifier.ready.then<String?>((state) {
        final user = state.user;
        if (user == null) return signIn(uri.toString()).location;
        if (test == null || test(user)) return null;
        return forbidden?.location;
      });
  }
}

/// For a `guard.dart`: null when signed in, else [signIn] with the requested location as `from`
/// (since 0.9.0). Synchronous, unless the session is still being restored.
///
/// ```dart
/// // lib/app/(signed-in)/guard.dart
/// GuardResult guard(Ref ref, {required Uri uri}) =>
///     requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));
/// ```
///
/// The guard watches the session, so it runs again on sign-out and the user is moved to the
/// sign-in page in that frame. It does not run again on a token refresh.
GuardResult requireSignedIn(
  Ref ref,
  Uri uri, {
  required TypedLocation Function(String from) signIn,
}) => _check(ref, uri, signIn: signIn);

/// [requireSignedIn], then [forbidden] when the user lacks [role] (since 0.9.0). It watches only
/// that answer: another role the user gains or loses runs it again, a refresh does not.
///
/// ```dart
/// // lib/app/(signed-in)/admin/guard.dart
/// GuardResult guard(Ref ref, {required Uri uri}) => requireRole(
///   ref, uri, 'admin',
///   signIn: (from) => SignInRoute(from: from),
///   forbidden: const ForbiddenRoute(),
/// );
/// ```
GuardResult requireRole(
  Ref ref,
  Uri uri,
  String role, {
  required TypedLocation Function(String from) signIn,
  required TypedLocation forbidden,
}) => _check(
  ref,
  uri,
  signIn: signIn,
  test: (user) => user.hasRole(role),
  forbidden: forbidden,
);

/// [requireSignedIn], then [forbidden] when [test] says no (since 0.9.0). It watches
/// `authUser.select(test)`, so [test] runs again only when the user changes.
GuardResult requireUser(
  Ref ref,
  Uri uri,
  bool Function(AuthUser user) test, {
  required TypedLocation Function(String from) signIn,
  required TypedLocation forbidden,
}) => _check(ref, uri, signIn: signIn, test: test, forbidden: forbidden);

/// For the sign-in route's own `guard.dart` (since 0.9.0): `returnTo(from, fallback: fallback)`
/// when signed in, else null.
///
/// It watches the session, so a sign-in on that page sends the user back to `from` by itself:
/// the page has no navigation code. Without this guard, signing in changes the state and
/// nothing moves.
///
/// ```dart
/// // lib/app/sign-in/guard.dart
/// GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);
/// ```
///
/// `returnTo` refuses `//host`, `https://…` and `/\`, so a crafted `?from=` cannot send the user
/// elsewhere.
GuardResult redirectIfSignedIn(
  Ref ref, {
  String? from,
  String fallback = '/',
}) => ref.watch(isSignedIn) ? returnTo(from, fallback: fallback) : null;
