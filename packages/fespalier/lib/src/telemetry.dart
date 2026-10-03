/// What fespalier reports while it routes (since 0.8.1): navigations, guard and redirect
/// decisions, data loads, actions and deferred loads, for an OpenTelemetry adapter
/// (`package:fespalier_otel`) or a test (`RecordingTelemetry` in `package:fespalier/testing.dart`).
///
/// fespalier has no OpenTelemetry dependency: it tells a [FespalierTelemetry] sink what happened,
/// and the sink decides what to do with it. Nothing is reported until [FespalierTelemetry.install]
/// is called, and only by an app generated with `telemetry: true`: the generated call sites pass
/// a `const` [TelemetrySite] to `traceGuard`, `traceData` and the actions, which are
/// pass-through wrappers (they return their last argument, the very object, so a sync guard or `data()` stays
/// sync).
///
/// This library never creates a `Future` of its own for a sync operation, never schedules a
/// microtask and never starts a timer: a sync guard, `data()` or action is reported with its
/// start and its end in the same call stack, and an async one through a side listener on the very
/// `Future` (the pattern DevTools support uses), which handles its own error so it cannot make an
/// unhandled one. Every call into the sink is inside a `try`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart' show Ref;

import 'lifecycle.dart' show RouterWatch;

/// What fespalier reports while it routes (since 0.8.1): navigations, guard and redirect
/// decisions, data loads, actions and deferred loads.
///
/// Nothing is reported until [install] is called, and only from an app generated with
/// `telemetry: true`. A sink is called synchronously from the router, a provider or an action,
/// so it must return at once, must not throw (fespalier catches and drops what it throws, and
/// prints it once) and must not navigate, read a provider or schedule work it waits for.
abstract class FespalierTelemetry {
  /// Constant so a sink with no state can be `const`.
  const FespalierTelemetry();

  static FespalierTelemetry? _current;

  /// The installed sink, or null.
  static FespalierTelemetry? get current => _current;

  /// Installs [sink] (null uninstalls). Call it before `runApp`, once the SDK is up and before
  /// the router is built, so that the initial navigation is reported too.
  static void install(FespalierTelemetry? sink) => _current = sink;

  /// An operation started. Returns a token that fespalier hands back to [end] (and, for a
  /// navigation, to [page] and as [TelemetryStart.parent] of what runs during it); null is fine.
  Object? start(TelemetryStart start) => null;

  /// The operation [token] came from ended.
  void end(Object? token, TelemetryEnd end) {}

  /// A page was entered, focused or left at the end of the navigation [navigation] (the token
  /// [start] returned for it).
  void page(Object? navigation, TelemetryPage page) {}
}

/// What an operation is, which says which fields of [TelemetryStart] are set.
enum TelemetryOp {
  /// A location was requested, or a configuration committed.
  navigate,

  /// A `guard.dart` ran.
  guard,

  /// A `redirect.dart` ran.
  redirect,

  /// A `data.dart` ran.
  data,

  /// A function of an `action.dart` ran.
  action,

  /// The code of a deferred page loaded.
  deferred,
}

/// What started. [op] says which fields are set.
final class TelemetryStart {
  /// Describes the start of an operation of kind [op].
  const TelemetryStart(
    this.op, {
    this.site,
    this.file,
    this.route,
    this.uri,
    this.parent,
    this.keyed = false,
  });

  /// Which kind of operation started.
  final TelemetryOp op;

  /// guard, redirect, data and action: the generated call site.
  final TelemetrySite? site;

  /// deferred: the library's `page.dart`, relative to the app folder.
  final String? file;

  /// deferred: the page's pattern.
  final String? route;

  /// navigate: the requested location (null when the navigation starts at its commit); guard
  /// and redirect: the location being guarded.
  final Uri? uri;

  /// The token of the navigation in progress, when there is one (never for navigate or action).
  final Object? parent;

  /// data: whether the provider is a family (keyed by segments or query parameters). The key
  /// itself is never reported.
  final bool keyed;
}

/// The values of [TelemetryEnd.outcome]. They are the contract values of the telemetry
/// conventions (README, "Telemetry conventions").
abstract final class TelemetryOutcome {
  /// navigate: the location matched a page. action, deferred: it worked.
  static const String ok = 'ok';

  /// navigate: the location matched no route.
  static const String notFound = 'not_found';

  /// navigate: a newer navigation started before this one committed.
  static const String superseded = 'superseded';

  /// guard, redirect: the guard returned null.
  static const String pass = 'pass';

  /// guard, redirect: it returned a location.
  static const String redirect = 'redirect';

  /// guard, redirect, data, action, deferred: it threw, or its `Future` failed.
  static const String error = 'error';

  /// guard: a segment it asks for did not parse, so it did not run.
  static const String skipped = 'skipped';

  /// data: the value is there.
  static const String data = 'data';

  /// data: a `Stream` was returned (it is not listened to, so the operation ends at once).
  static const String stream = 'stream';

  /// data: the provider was disposed before its `Future` settled.
  static const String disposed = 'disposed';
}

/// How an operation ended.
final class TelemetryEnd {
  /// Describes the end of an operation with [outcome].
  const TelemetryEnd(
    this.outcome, {
    this.isAsync = false,
    this.error,
    this.stackTrace,
    this.location,
    this.route,
    this.from,
    this.kind,
    this.redirected = false,
    this.depth = 0,
  });

  /// One of the [TelemetryOutcome] values.
  final String outcome;

  /// Whether the operation returned a `Future` (guard, redirect, data, action).
  final bool isAsync;

  /// The exception, on outcome [TelemetryOutcome.error].
  final Object? error;

  /// The stack trace of [error], when there is one.
  final StackTrace? stackTrace;

  /// navigate: the committed location; guard and redirect: where it redirected to.
  final String? location;

  /// navigate: the pattern of the page that is on screen (null when not found).
  final String? route;

  /// navigate: the pattern of the page that was on top before (null at the start).
  final String? from;

  /// navigate: `initial`, `go`, `push`, `pop`, `replace` or `refresh` (null when superseded).
  final String? kind;

  /// navigate: the committed path differs from the requested one (a guard or a
  /// `redirect.dart` sent it elsewhere).
  final bool redirected;

  /// navigate: how many pushed pages the stack holds after the commit.
  final int depth;
}

/// What happened to a page.
enum TelemetryPageKind {
  /// The page became the visible one for the first time.
  enter,

  /// An entered page is the visible one again.
  focus,

  /// An entered page is gone.
  leave,
}

/// A page event: reported to [FespalierTelemetry.page] for the navigation that caused it.
final class TelemetryPage {
  /// Describes [kind] happening to the page [route].
  const TelemetryPage(this.kind, this.route, {this.duration});

  /// Entered, focused or left.
  final TelemetryPageKind kind;

  /// The page's pattern; null when not known.
  final String? route;

  /// On a leave: how long the page was entered, covered time included.
  final Duration? duration;
}

/// Where a generated call site is: `const` in `app.g.dart`, so naming it costs nothing at run
/// time.
final class TelemetrySite {
  /// A call site in [file], on the route whose pattern is [route].
  const TelemetrySite(this.file, {required this.route, this.name});

  /// The app file: `products/$id/data.dart`.
  final String file;

  /// The pattern of the route (or section) it belongs to: `/products/:id`.
  final String route;

  /// An action's function name; null otherwise.
  final String? name;
}

/// Lets telemetry follow [router]'s navigations. The generated `AppRoutes.attach` calls it in an
/// app generated with `telemetry: true`; an app that mounts the tree in a `GoRouter` of its own
/// calls `AppRoutes.attach(router)`. [base] returns where the tree is mounted (`AppRoutes.base`).
void telemetryAttach(GoRouter router, {required String Function() base}) {
  try {
    RouterWatch.of(router).enableTelemetry(base);
  } catch (e) {
    _report(e);
  }
}

// ---------------------------------------------------------------------------------------------
// Dispatch. Everything below is internal: not exported.

/// The token of the `navigate` span that is open (started and not yet ended): the parent of the
/// guards, data loads and deferred loads that run during it. One per isolate, owned by the last
/// router to start a navigation: tests build one router at a time.
Object? _pendingNavigation;

/// Whether the guard whose answer comes next did not run (see [markTelemetrySkipped]).
bool _skipped = false;

/// Whether an error of ours was printed: one line, then the rest are dropped.
bool _reported = false;

void _report(Object error) {
  if (_reported) return;
  _reported = true;
  debugPrint('fespalier telemetry: $error (not shown again)');
}

/// Starts an operation with the installed sink; null when there is none, or when it threw.
Object? telemetryBegin(TelemetryStart start) {
  final sink = FespalierTelemetry._current;
  if (sink == null) return null;
  try {
    return sink.start(start);
  } catch (e) {
    _report(e);
    return null;
  }
}

/// Ends the operation [token] came from.
void telemetryFinish(Object? token, TelemetryEnd end) {
  final sink = FespalierTelemetry._current;
  if (sink == null) return;
  try {
    sink.end(token, end);
  } catch (e) {
    _report(e);
  }
}

/// Reports a page event of the navigation [navigation].
void telemetryPageEvent(Object? navigation, TelemetryPage page) {
  final sink = FespalierTelemetry._current;
  if (sink == null) return;
  try {
    sink.page(navigation, page);
  } catch (e) {
    _report(e);
  }
}

/// Reports an error of the watch's telemetry side: printed once, then dropped.
void telemetryAttachError(Object error) => _report(error);

/// Whether a sink is installed.
bool get telemetryOn => FespalierTelemetry._current != null;

/// A navigation starts: [uri] is the requested location, or null when it starts at its commit.
/// Returns its token, which is also what runs during it is parented to until
/// [telemetryNavigationEnd].
Object? telemetryNavigationStart(Uri? uri) {
  final token = telemetryBegin(TelemetryStart(TelemetryOp.navigate, uri: uri));
  _pendingNavigation = token;
  return token;
}

/// The navigation [token] ended.
void telemetryNavigationEnd(Object? token, TelemetryEnd end) {
  if (identical(_pendingNavigation, token)) _pendingNavigation = null;
  telemetryFinish(token, end);
}

/// `guardWithParams` calls this when the route's segments did not parse and the guard did not
/// run: the `traceGuard` around it, which comes next, reports `skipped` instead of a pass.
/// Only while a sink is installed, so a stale mark can't outlive it.
void markTelemetrySkipped() {
  if (FespalierTelemetry._current != null) _skipped = true;
}

/// What `traceGuard` does with a [telemetry] site: [result] is what the guard returned.
void telemetryGuardTrace(
  GoRouterState state,
  String site,
  TelemetrySite telemetry,
  FutureOr<String?> result,
) {
  if (FespalierTelemetry._current == null) {
    _skipped = false;
    return;
  }
  final skipped = _skipped;
  _skipped = false;
  try {
    final token = telemetryBegin(
      TelemetryStart(
        site.startsWith('r') ? TelemetryOp.redirect : TelemetryOp.guard,
        site: telemetry,
        uri: state.uri,
        parent: _pendingNavigation,
      ),
    );
    if (skipped) {
      telemetryFinish(token, const TelemetryEnd(TelemetryOutcome.skipped));
    } else if (result is Future<String?>) {
      // Only reports. It handles its own errors, so it cannot make an unhandled one, and it
      // leaves the original `Future` to its real consumer.
      unawaited(
        result.then<void>(
          (location) => telemetryFinish(token, _guardEnd(location, true)),
          onError: (Object error, StackTrace stack) => telemetryFinish(
            token,
            TelemetryEnd(
              TelemetryOutcome.error,
              isAsync: true,
              error: error,
              stackTrace: stack,
            ),
          ),
        ),
      );
    } else {
      telemetryFinish(token, _guardEnd(result, false));
    }
  } catch (e) {
    _report(e);
  }
}

TelemetryEnd _guardEnd(String? location, bool isAsync) => TelemetryEnd(
  location == null ? TelemetryOutcome.pass : TelemetryOutcome.redirect,
  isAsync: isAsync,
  location: location,
);

/// What `traceData` does with a [telemetry] site: [result] is what `data()` returned.
void telemetryDataTrace(
  Ref ref,
  TelemetrySite telemetry,
  bool keyed,
  Object? result,
) {
  if (FespalierTelemetry._current == null) return;
  try {
    final token = telemetryBegin(
      TelemetryStart(
        TelemetryOp.data,
        site: telemetry,
        keyed: keyed,
        parent: _pendingNavigation,
      ),
    );
    if (result is Future<Object?>) {
      var ended = false;
      void end(TelemetryEnd e) {
        if (ended) return;
        ended = true;
        telemetryFinish(token, e);
      }

      unawaited(
        result.then<void>(
          (_) => end(const TelemetryEnd(TelemetryOutcome.data, isAsync: true)),
          onError: (Object error, StackTrace stack) => end(
            TelemetryEnd(
              TelemetryOutcome.error,
              isAsync: true,
              error: error,
              stackTrace: stack,
            ),
          ),
        ),
      );
      ref.onDispose(
        () => end(const TelemetryEnd(TelemetryOutcome.disposed, isAsync: true)),
      );
    } else if (result is Stream<Object?>) {
      telemetryFinish(token, const TelemetryEnd(TelemetryOutcome.stream));
    } else {
      telemetryFinish(token, const TelemetryEnd(TelemetryOutcome.data));
    }
  } catch (e) {
    _report(e);
  }
}

/// An action run starts. Returns what [telemetryActionEnd] takes.
Object? telemetryActionStart(TelemetrySite telemetry) {
  if (FespalierTelemetry._current == null) return null;
  return telemetryBegin(TelemetryStart(TelemetryOp.action, site: telemetry));
}

/// The action run [token] ended, with [error] when it failed.
void telemetryActionEnd(
  Object? token, {
  required bool isAsync,
  bool failed = false,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (FespalierTelemetry._current == null) return;
  telemetryFinish(
    token,
    TelemetryEnd(
      failed ? TelemetryOutcome.error : TelemetryOutcome.ok,
      isAsync: isAsync,
      error: error,
      stackTrace: stackTrace,
    ),
  );
}

/// A deferred library starts loading its code.
Object? telemetryDeferredStart(String file, String route) {
  if (FespalierTelemetry._current == null) return null;
  return telemetryBegin(
    TelemetryStart(
      TelemetryOp.deferred,
      file: file,
      route: route,
      parent: _pendingNavigation,
    ),
  );
}

/// The deferred load [token] came from ended, with [error] when it failed.
void telemetryDeferredEnd(
  Object? token, {
  bool failed = false,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (FespalierTelemetry._current == null) return;
  telemetryFinish(
    token,
    TelemetryEnd(
      failed ? TelemetryOutcome.error : TelemetryOutcome.ok,
      isAsync: true,
      error: error,
      stackTrace: stackTrace,
    ),
  );
}
