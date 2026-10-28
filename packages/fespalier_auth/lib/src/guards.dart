import 'package:clock/clock.dart';
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
/// sign-in page in that frame, from a page that was pushed too (since 0.21.0: the guard of a pushed
/// page watches while the page is on top, and a page go_router shows again without its redirect, after
/// a refresh or a pop back, runs it again after the frame; docs/guards.md, "A guard on a pushed
/// page"). It does not run again on a token refresh.
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

/// The phase, and the authentication time when signed in: what the freshness guards watch, so a
/// renewal (which keeps the time) never runs them again, and a step-up does.
(_Phase, DateTime?) _freshness(SessionState state) => (
  _phaseOf(state),
  switch (state) {
    SignedIn(:final session) => session.authenticatedAt,
    _ => null,
  },
);

bool _fresh(SessionState state, Duration maxAge) => switch (state) {
  SignedIn(:final session) => session.authenticatedWithin(maxAge, clock.now()),
  _ => false,
};

/// For a `guard.dart` of a route that needs a recent sign-in (since 0.25.0): [requireSignedIn],
/// then [reauthenticate] with the requested location as `from` when the user last proved who
/// they are more than [maxAge] ago (`AuthSession.authenticatedAt`: an OpenID Connect
/// `auth_time`, else the time of the sign-in or the last step-up). An unknown time is too old.
///
/// ```dart
/// // lib/app/(signed-in)/payouts/guard.dart
/// GuardResult guard(Ref ref, {required Uri uri}) => requireFreshAuth(
///   ref, uri,
///   maxAge: const Duration(minutes: 5),
///   signIn: (from) => SignInRoute(from: from),
///   reauthenticate: (from) => ReauthRoute(from: from),
/// );
/// ```
///
/// The age is read from `clock.now()` when the guard runs: when the route is opened, and when
/// the session's user or authentication time changes. It starts no timer, so a page open for
/// longer than [maxAge] stays open; the API's own step-up refusal (`StepUp`) covers what it
/// sends from there. A renewal does not run it again (it keeps the time); a step-up does.
GuardResult requireFreshAuth(
  Ref ref,
  Uri uri, {
  required Duration maxAge,
  required TypedLocation Function(String from) signIn,
  required TypedLocation Function(String from) reauthenticate,
}) {
  final (phase, _) = ref.watch(authSession.select(_freshness));
  String? decide(SessionState state) {
    if (state is! SignedIn) return signIn(uri.toString()).location;
    return _fresh(state, maxAge)
        ? null
        : reauthenticate(uri.toString()).location;
  }

  if (phase == _Phase.restoring) {
    // Only without restoreAuth in startup(): the answer waits for the stored session. It reads
    // the notifier, not the ref, which is gone by then.
    return ref.read(authSession.notifier).ready.then<String?>(decide);
  }
  return decide(ref.read(authSession));
}

/// For the re-proof route's own `guard.dart` (since 0.25.0), as [redirectIfSignedIn] is for the
/// sign-in route: `returnTo(from, fallback: fallback)` when the user authenticated within
/// [maxAge], else null. A step-up on that page (`AuthSessionNotifier.stepUp`) sends the user back
/// to `from` by itself.
///
/// ```dart
/// // lib/app/(signed-in)/reauth/guard.dart
/// GuardResult guard(Ref ref, {String? from}) =>
///     redirectIfFreshAuth(ref, maxAge: const Duration(minutes: 5), from: from);
/// ```
///
/// Pass the same [maxAge] as the [requireFreshAuth] that sent the user there. Put the page under
/// the signed-in routes: signed out, this guard answers null.
GuardResult redirectIfFreshAuth(
  Ref ref, {
  required Duration maxAge,
  String? from,
  String fallback = '/',
}) {
  ref.watch(authSession.select(_freshness));
  return _fresh(ref.read(authSession), maxAge)
      ? returnTo(from, fallback: fallback)
      : null;
}
