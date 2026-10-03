import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;

import 'backend.dart';
import 'config.dart';
import 'errors.dart';
import 'session.dart';
import 'telemetry.dart';
import 'util.dart';

/// The session (since 0.9.0): where the app is signed in or out, and the way to sign in, out and
/// to get tokens. Not auto-disposed: the session outlives every page.
final NotifierProvider<AuthSessionNotifier, SessionState> authSession =
    NotifierProvider<AuthSessionNotifier, SessionState>(
      AuthSessionNotifier.new,
      retry: noRetry,
    );

/// Whether somebody is signed in. Watch this in a guard: a token refresh does not change it, so
/// a refresh never runs a guard again.
final Provider<bool> isSignedIn = Provider<bool>(
  (ref) => ref.watch(authSession.select((state) => state is SignedIn)),
  retry: noRetry,
);

/// The signed-in user, or null. It changes when the user or their roles and claims do, never on a
/// token refresh that changes nothing about them.
final Provider<AuthUser?> authUser = Provider<AuthUser?>(
  (ref) => ref.watch(authSession.select((state) => state.user)),
  retry: noRetry,
);

/// The signed-in user's id, or null. Watch it in a `data.dart` whose data belongs to the user:
/// another user loads it again, a token refresh does not.
final Provider<String?> authUserId = Provider<String?>(
  (ref) => ref.watch(authUser.select((user) => user?.id)),
  retry: noRetry,
);

/// The session's notifier (since 0.9.0): `ref.read(authSession.notifier)`.
///
/// There is no timer, no `Future.delayed` and no listener here: the only clock is
/// `clock.now()`, read when a token is asked for. A refresh is lazy (the first request that finds
/// the access token expired) and single-flight (one refresh at a time, shared by every waiter),
/// which is what refresh-token rotation needs.
class AuthSessionNotifier extends Notifier<SessionState> {
  late AuthConfig _config;

  /// Bumped by every sign-in, sign-out and rejected refresh: work that started under an older
  /// number finds the session changed under it, and throws its result away.
  int _generation = 0;

  Completer<AuthSession>? _refreshing;
  Completer<SessionState>? _ready;

  @override
  SessionState build() {
    _config = ref.watch(authConfig);
    _generation++;
    _refreshing = null;
    _ready = null;
    final initial = ref.watch(authInitialState);
    if (initial != null) return initial;
    final FutureOr<SessionState> restored;
    try {
      restored = restoreSession(_config);
    } catch (error, stackTrace) {
      reportRestoreError(error, stackTrace);
      return const SignedOut();
    }
    if (restored is! Future<SessionState>) return restored;
    final generation = _generation;
    final ready = _ready = Completer<SessionState>();
    ref.onDispose(() {
      if (!ready.isCompleted) ready.complete(const SignedOut());
    });
    restored.then<void>(
      (value) => _restored(generation, ready, value),
      onError: (Object error, StackTrace stackTrace) {
        reportRestoreError(error, stackTrace);
        _restored(generation, ready, const SignedOut());
      },
    );
    return const SessionRestoring();
  }

  void _restored(
    int generation,
    Completer<SessionState> ready,
    SessionState value,
  ) {
    if (ready.isCompleted) return;
    if (ref.mounted && generation == _generation) state = value;
    ready.complete(ref.mounted ? state : value);
    if (identical(_ready, ready)) _ready = null;
  }

  /// Completes with the state once it is not [SessionRestoring] (at once when it is not).
  Future<SessionState> get ready {
    final pending = _ready;
    if (state is! SessionRestoring || pending == null) {
      return Future<SessionState>.value(state);
    }
    return pending.future;
  }

  /// The session, or null when nobody is signed in (or it is still being restored).
  AuthSession? get session => switch (state) {
    SignedIn(:final session) => session,
    _ => null,
  };

  /// Signs in with the configured backend, stores the session, and sets [SignedIn].
  ///
  /// Rethrows what the backend threw, with the state unchanged: `AuthCancelled` when the user
  /// gave up, `FieldErrors` for wrong credentials (a form shows them under its fields),
  /// `AuthRejected` when the server refused. The sign-in route's guard
  /// (`redirectIfSignedIn`) then sends the user back to where they came from: a page has no
  /// navigation code of its own.
  Future<AuthSession> signIn(SignInRequest request) async {
    final backend = _config.backend;
    final token = authSpan('sign_in', backend);
    final generation = ++_generation;
    try {
      final session = await backend.signIn(request);
      await _adopt(session, generation);
      authSpanEnd(token, TelemetryOutcome.ok);
      return session;
    } catch (error, stackTrace) {
      _endSignIn(token, error, stackTrace);
      rethrow;
    }
  }

  /// Takes a session the app obtained itself (a deep-link callback, a multi-step SDK flow) and
  /// signs in with it. Throws an `ArgumentError` when it comes from another backend than the
  /// configured one.
  Future<void> adopt(AuthSession session) async {
    final backend = _config.backend;
    if (session.backend != backend.name) {
      throw ArgumentError(
        'fespalier_auth: this session comes from the backend "${session.backend}", '
        'but the configured backend is "${backend.name}"',
      );
    }
    final token = authSpan('sign_in', backend);
    final generation = ++_generation;
    try {
      await _adopt(session, generation);
      authSpanEnd(token, TelemetryOutcome.ok);
    } catch (error, stackTrace) {
      _endSignIn(token, error, stackTrace);
      rethrow;
    }
  }

  void _endSignIn(Object? token, Object error, StackTrace stackTrace) {
    final outcome = switch (error) {
      AuthCancelled() || NotSignedIn() => TelemetryOutcome.cancelled,
      AuthRejected() || FieldErrors() => TelemetryOutcome.rejected,
      _ => TelemetryOutcome.error,
    };
    authSpanEnd(
      token,
      outcome,
      error: outcome == TelemetryOutcome.error ? error : null,
      stackTrace: outcome == TelemetryOutcome.error ? stackTrace : null,
    );
  }

  /// Stores [session], then publishes it. A sign-out, or another sign-in, that came first wins:
  /// this one throws [NotSignedIn] and changes nothing.
  Future<void> _adopt(AuthSession session, int generation) async {
    if (generation != _generation || !ref.mounted) throw NotSignedIn();
    await _persist(session);
    if (generation != _generation || !ref.mounted) throw NotSignedIn();
    state = SignedIn(session);
    _readyDone();
  }

  /// A sign-in or a sign-out while the stored session was still being read ends the wait.
  void _readyDone() {
    final pending = _ready;
    _ready = null;
    if (pending != null && !pending.isCompleted) pending.complete(state);
  }

  /// Writes the session to the store. A store that fails is reported and not fatal: the session
  /// works in memory, and does not outlive the app.
  FutureOr<void> _persist(AuthSession session) {
    if (_config.backend.keepsOwnSession) return null;
    try {
      final done = _config.store.write(jsonEncode(session.toJson()));
      if (done is Future<void>) {
        return done.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) =>
              _reportStore(error, stackTrace, 'while storing the session'),
        );
      }
    } catch (error, stackTrace) {
      _reportStore(error, stackTrace, 'while storing the session');
    }
    return null;
  }

  FutureOr<void> _clear() {
    if (_config.backend.keepsOwnSession) return null;
    try {
      final done = _config.store.delete();
      if (done is Future<void>) {
        return done.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) => _reportStore(
            error,
            stackTrace,
            'while clearing the stored session',
          ),
        );
      }
    } catch (error, stackTrace) {
      _reportStore(error, stackTrace, 'while clearing the stored session');
    }
    return null;
  }

  void _reportStore(Object error, StackTrace stackTrace, String when) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'fespalier_auth',
          context: ErrorDescription(when),
        ),
      );

  /// Signs out: the state is [SignedOut] with [SignOutReason.user] at once, so the guards move
  /// the user in this frame. Then the store is cleared, the backend's `signOut` runs (best
  /// effort: its errors are not thrown) and the proof of possession is reset. Does nothing when
  /// nobody is signed in.
  Future<void> signOut() async {
    if (state is SessionRestoring) await ready;
    final old = session;
    if (old == null) return;
    final backend = _config.backend;
    final token = authSpan('sign_out', backend);
    _generation++;
    state = const SignedOut(reason: SignOutReason.user);
    var outcome = TelemetryOutcome.ok;
    Object? failure;
    StackTrace? failureStack;
    try {
      await _clear();
      await backend.signOut(old);
    } catch (error, stackTrace) {
      outcome = TelemetryOutcome.error;
      failure = error;
      failureStack = stackTrace;
    }
    try {
      await backend.proof?.reset();
    } catch (error, stackTrace) {
      outcome = TelemetryOutcome.error;
      failure ??= error;
      failureStack ??= stackTrace;
    }
    authSpanEnd(token, outcome, error: failure, stackTrace: failureStack);
  }

  /// The tokens to send now: **synchronous** while the access token is good (the answer is not a
  /// `Future`); otherwise one shared refresh.
  ///
  /// [forceRefresh] refreshes anyway. [rejected] is the access token a server just answered 401
  /// to: when the session already has another one (a request that finished first refreshed), it
  /// is returned without a second refresh, which refresh-token rotation would refuse.
  ///
  /// Throws [NotSignedIn] when signed out (a request that waited for a refresh while the user
  /// signed out gets it too), [AuthRejected] when the server refused the refresh (the state is
  /// then `SignedOut(reason: SignOutReason.expired)`), and [AuthUnavailable] when it could not
  /// ask (offline, a 5xx): the session stays, and the next call asks again.
  FutureOr<AuthTokens> tokens({bool forceRefresh = false, String? rejected}) {
    final current = state;
    if (current is SessionRestoring) {
      return ready.then<AuthTokens>(
        (_) => tokens(forceRefresh: forceRefresh, rejected: rejected),
      );
    }
    if (current is! SignedIn) throw NotSignedIn();
    final held = current.session.tokens;
    if (rejected != null && held.accessToken != rejected) return held;
    if (!forceRefresh &&
        rejected == null &&
        !held.isExpiredAt(clock.now(), leeway: _config.leeway)) {
      return held;
    }
    final trigger = rejected != null
        ? 'unauthorized'
        : forceRefresh
        ? 'forced'
        : 'expired';
    final running = _refreshing ?? _startRefresh(current.session, trigger);
    return running.future.then<AuthTokens>((session) => session.tokens);
  }

  Completer<AuthSession> _startRefresh(AuthSession from, String trigger) {
    final completer = Completer<AuthSession>();
    // Set before the work starts: a second `tokens()` finds it, and the work, which may fail
    // before its first `await`, clears it only once it is set.
    _refreshing = completer;
    unawaited(_refresh(completer, from, trigger));
    return completer;
  }

  Future<void> _refresh(
    Completer<AuthSession> completer,
    AuthSession from,
    String trigger,
  ) async {
    final generation = _generation;
    final backend = _config.backend;
    final token = authSpan('refresh', backend, trigger: trigger);
    try {
      final next = await backend.refresh(from);
      if (generation != _generation || !ref.mounted) {
        authSpanEnd(token, TelemetryOutcome.cancelled);
        completer.completeError(NotSignedIn());
        return;
      }
      // The store gets the new (rotated) refresh token before the state does: a kill between the
      // two leaves the store on the one the server accepts.
      await _persist(next);
      if (generation != _generation || !ref.mounted) {
        authSpanEnd(token, TelemetryOutcome.cancelled);
        completer.completeError(NotSignedIn());
        return;
      }
      state = SignedIn(next);
      authSpanEnd(token, TelemetryOutcome.ok);
      completer.complete(next);
    } on AuthRejected catch (error, stackTrace) {
      if (generation == _generation && ref.mounted) {
        _generation++;
        state = const SignedOut(reason: SignOutReason.expired);
        unawaited(_endedByServer(backend));
      }
      authSpanEnd(token, TelemetryOutcome.rejected);
      completer.completeError(error, stackTrace);
    } catch (error, stackTrace) {
      final unavailable = error is AuthUnavailable
          ? error
          : AuthUnavailable(error);
      authSpanEnd(
        token,
        TelemetryOutcome.error,
        error: unavailable,
        stackTrace: stackTrace,
      );
      completer.completeError(unavailable, stackTrace);
    } finally {
      if (identical(_refreshing, completer)) _refreshing = null;
    }
  }

  /// The server ended the session: forget it here too, and the device key the tokens were bound
  /// to.
  Future<void> _endedByServer(AuthBackend backend) async {
    try {
      await _clear();
      await backend.proof?.reset();
    } catch (_) {
      // Best effort: the state already says signed out.
    }
  }
}
