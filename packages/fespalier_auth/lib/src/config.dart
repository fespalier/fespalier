import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_transport/fespalier_transport.dart'
    show HttpTransport;
import 'package:flutter/foundation.dart'
    show ErrorDescription, FlutterError, FlutterErrorDetails;

import 'backend.dart';
import 'session.dart';
import 'store.dart';
import 'telemetry.dart';
import 'util.dart';

/// How the app signs in: one per app (since 0.9.0). Give it to [restoreAuth] in `startup()`.
final class AuthConfig {
  /// The [backend] sessions come from, the [transport] requests are sent through, and the
  /// [store] that keeps sessions between runs.
  const AuthConfig({
    required this.backend,
    required this.transport,
    this.store = const SecureTokenStore(),
    this.apiOrigins = const <Uri>[],
  });

  /// Where sessions come from.
  final AuthBackend backend;

  /// What requests are sent through (since 0.21.0): `HttpClientTransport` (`fespalier_http`),
  /// `DioTransport` (`fespalier_dio`) or your own. `authTransport` wraps it in a
  /// `SessionTransport`; a backend that calls its provider (`OidcBackend`) takes the same one.
  final HttpTransport transport;

  /// Where the session is kept between runs: `SecureTokenStore` by default, `MemoryTokenStore`
  /// for tests, and for the web when nothing should persist.
  final TokenStore store;

  /// The origins (scheme, host and port) whose requests carry the session. Nothing else gets a
  /// credential, so a request to a third-party host never leaks one.
  final List<Uri> apiOrigins;
}

/// Reads the stored session and returns the overrides for the app's `ProviderScope` (since
/// 0.9.0): return it from `startup()`.
///
/// ```dart
/// // lib/app/startup.dart
/// FutureOr<List<Override>> startup() => restoreAuth(authSetup());
/// ```
///
/// It is synchronous when the store (or a backend that keeps its own session) answers
/// synchronously, and it never touches the network: no credential is renewed at start-up, so
/// an offline start works, and an expired one is renewed by the first request that needs it.
/// With `SecureTokenStore` it is one keychain read before the first frame, shown behind
/// `splash.dart`, and the guards are synchronous from the first navigation. A store that fails
/// to read makes `startup()` fail, which the generated `main()` shows with a retry.
///
/// Install the telemetry sink first, to see the restore as a span.
FutureOr<List<Override>> restoreAuth(AuthConfig config) =>
    then<SessionState, List<Override>>(
      restoreSession(config),
      (state) => <Override>[
        authConfig.overrideWithValue(config),
        authInitialState.overrideWithValue(state),
      ],
    );

/// The app's [AuthConfig]. [restoreAuth] overrides it (and `fakeAuth` in a test); reading it
/// otherwise throws a `StateError` that says what to do.
final Provider<AuthConfig> authConfig = Provider<AuthConfig>(
  (ref) => throw StateError(
    'fespalier_auth: no AuthConfig. Return restoreAuth(config) from startup() in '
    'lib/app/startup.dart, or add authConfig.overrideWithValue(config) to your '
    'ProviderScope; in a test, pass overrides: fakeAuth(...) to pumpRouter.',
  ),
  retry: noRetry,
);

/// The state [restoreAuth] read; null makes the session restore by itself, at the first read.
final Provider<SessionState?> authInitialState = Provider<SessionState?>(
  (ref) => null,
  retry: noRetry,
);

/// What `restoreAuth` and the notifier's own restore run. Not exported.
///
/// Throws, or fails, only when the store cannot be read: a stored session that is corrupt is
/// reported, dropped, and answers signed out.
FutureOr<SessionState> restoreSession(AuthConfig config) {
  final token = authSpan('restore', config.backend);
  final FutureOr<(SessionState, String)> result;
  try {
    result = _restore(config);
  } catch (error, stackTrace) {
    authSpanEnd(
      token,
      TelemetryOutcome.error,
      isAsync: false,
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
  if (result is! Future<(SessionState, String)>) {
    authSpanEnd(token, result.$2, isAsync: false);
    return result.$1;
  }
  return result.then<SessionState>(
    (done) {
      authSpanEnd(token, done.$2);
      return done.$1;
    },
    onError: (Object error, StackTrace stackTrace) {
      authSpanEnd(
        token,
        TelemetryOutcome.error,
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    },
  );
}

/// Reports a stored session that could not be read (a corrupt one, or a store that failed): the
/// text is `while restoring the stored session`.
void reportRestoreError(Object error, StackTrace stackTrace) =>
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'fespalier_auth',
        context: ErrorDescription('while restoring the stored session'),
      ),
    );

typedef _Found = (AuthSession?, String);

FutureOr<(SessionState, String)> _restore(AuthConfig config) {
  final backend = config.backend;
  if (backend.keepsOwnSession) {
    return then<AuthSession?, (SessionState, String)>(
      backend.currentSession(),
      (session) => _check(config, session, TelemetryOutcome.none),
    );
  }
  return then<_Found, (SessionState, String)>(
    _readStored(config),
    (found) => _check(config, found.$1, found.$2),
  );
}

FutureOr<_Found> _readStored(
  AuthConfig config,
) => then<String?, _Found>(config.store.read(), (raw) {
  if (raw == null) return (null, TelemetryOutcome.none);
  try {
    final json = jsonDecode(raw);
    if (json is! Map<String, Object?>) {
      throw const FormatException(
        'fespalier_auth: the stored session is not a JSON object',
      );
    }
    final backend = config.backend;
    // Another backend's session is not read with this one's credential reader: it is
    // dropped, without a report, as it always was.
    final named = json['backend'];
    if (json['v'] == 2 && named is String && named != backend.name) {
      return then<void, _Found>(
        _forget(config),
        (_) => (null, TelemetryOutcome.none),
      );
    }
    return (
      AuthSession.fromJson(json, backend.readCredential),
      TelemetryOutcome.ok,
    );
  } catch (error, stackTrace) {
    reportRestoreError(error, stackTrace);
    return then<void, _Found>(
      _forget(config),
      (_) => (null, TelemetryOutcome.error),
    );
  }
});

/// The stored session [session] becomes a state, or is dropped: one whose credential can no
/// longer be renewed, or that the backend's `check` refuses (a device key that is gone).
FutureOr<(SessionState, String)> _check(
  AuthConfig config,
  AuthSession? session,
  String noneOutcome,
) {
  if (session == null) return (const SignedOut(), noneOutcome);
  final backend = config.backend;
  final own = backend.keepsOwnSession;
  FutureOr<(SessionState, String)> dropped(
    SignOutReason? reason,
    String outcome,
  ) => then<void, (SessionState, String)>(
    _forget(config),
    (_) => (SignedOut(reason: reason), outcome),
  );

  if (!own && session.backend != backend.name) {
    return dropped(null, TelemetryOutcome.none);
  }
  final now = clock.now();
  final credential = session.credential;
  final renewableUntil = credential.renewableUntil;
  final expiresAt = credential.expiresAt;
  if (!own &&
      ((renewableUntil != null && !renewableUntil.isAfter(now)) ||
          (!credential.renewable &&
              expiresAt != null &&
              !expiresAt.isAfter(now)))) {
    return dropped(SignOutReason.expired, TelemetryOutcome.expired);
  }
  return then<SignOutReason?, (SessionState, String)>(
    backend.check(session),
    (reason) => reason == null
        ? (SignedIn(session), TelemetryOutcome.ok)
        : dropped(reason, TelemetryOutcome.expired),
  );
}

/// Deletes the stored session; a store that fails to delete is not worth failing a restore.
FutureOr<void> _forget(AuthConfig config) {
  if (config.backend.keepsOwnSession) return null;
  try {
    final done = config.store.delete();
    if (done is Future<void>) {
      return done.then<void>((_) {}, onError: (Object _) {});
    }
  } catch (_) {
    // Same.
  }
  return null;
}
