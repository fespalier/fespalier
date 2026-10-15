import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';

import 'keys.dart';
import 'reporter.dart';

/// fespalier's telemetry in Crashlytics (since 0.18.0): every failure of a guard, a `data.dart`, an
/// action or a deferred load is a non-fatal report named by the **route pattern** and the **app
/// file** that threw, each committed navigation sets the screen as a custom key, and each page change
/// is a line in the log.
///
/// ```dart
/// FespalierTelemetry.add(FespalierCrashlytics(FirebaseCrashReporter()));
/// ```
///
/// The report's reason is what the console shows with it: `in data items/$id/data.dart on
/// /items/:id`, or `in action items/$id/action.dart#rename on /items/:id`. The keys are the four
/// `CrashlyticsKeys` of the failing site (`fespalier_operation`, `_route`, `_file`, `_action`, `''`
/// when there is none), and the session's `fespalier_screen` says where the person was.
///
/// Everything it records is **non-fatal**: a failure fespalier reports is one the app has handled or
/// shows (a data error view, an action's `AsyncError`, go_router's error page). A fatal crash belongs
/// to the app's own handlers (`recordFlutterFatalError`, `recordError(fatal: true)`), which should
/// skip what [reported] answers for, so one error is reported once.
///
/// The defaults are the errors and the page changes, and nothing else: a [FieldErrors] (a validation
/// answer, shown on the form, and its text can echo what the user typed), an `auth` step (the next
/// request retries it) and a package's own `custom` operation are logged by class only, unless
/// [capture] says otherwise. The same failure within [repeatWindow] is a log line, not another
/// report (Riverpod retries a failing `data()`).
///
/// **Never sent:** a segment value, a query value, a family key, `extra`, an action's input or result,
/// a data value, a [FieldErrors], a URL or an id. No error's text is in a log, a key or a reason: an
/// exception object goes to the reporter as the app's own, which is what Crashlytics' handlers do
/// with every error.
///
/// Crashlytics keeps custom keys for the whole session, and the four error keys hold the last
/// recorded error until the next one; `fespalier_screen` is where the person is. The sink sends a key
/// only when its value changes. There is no OpenTelemetry link in this version: `fespalier_sentry`
/// keeps that.
///
/// Install it in `startup()`, before the router is built, with `add`, not `install`. It returns at
/// once, never throws, starts no timer, listens to nothing and reads no provider; a sync guard or
/// `data()` stays sync.
final class FespalierCrashlytics extends FespalierTelemetry {
  /// [reporter] is the Crashlytics side, the port [CrashReporter].
  FespalierCrashlytics(
    this.reporter, {
    this.logs = true,
    this.capture = unexpected,
    this.repeatWindow = const Duration(seconds: 30),
  });

  /// Where the reports, the keys and the logs go.
  final CrashReporter reporter;

  /// Whether a page change and a failure the sink does not report become lines in the log. The
  /// screen key and the reports are sent either way.
  final bool logs;

  /// Which failures become reports; the others are logged by class. [unexpected] by default.
  final bool Function(Object error, TelemetryStart start) capture;

  /// A failure with the same operation, file and exception type as one reported less than this long
  /// ago is a log line, not another report. `Duration.zero` reports every one.
  final Duration repeatWindow;

  /// The default [capture]: every failure except a [FieldErrors] (a validation answer), an `auth`
  /// step (`fespalier_auth` reports a network failure there, which the next request retries) and a
  /// package's own `custom` operation (its text is the package's, and could hold a token or a URL:
  /// a log line with the class only; pass a `capture:` that returns true for it to report it).
  static bool unexpected(Object error, TelemetryStart start) =>
      error is! FieldErrors &&
      start.op != TelemetryOp.auth &&
      start.op != TelemetryOp.custom;

  /// The last errors the sink saw, reported or not, compared by identity.
  final List<Object> _seen = [];

  /// The reports inside [repeatWindow], by operation, file and exception type.
  final Map<String, DateTime> _lastReport = {};

  /// The screen key as the reporter has it, so an unchanged one is not sent again.
  String? _screen;

  /// Whether the sink saw [error] (the object itself) as a failure of one of its operations, in the
  /// last 32: a report, a repeat, or a line in the log by class (a [FieldErrors] included). Compared
  /// with `identical`, and answered whatever the sink did with it, so that a handler the app runs
  /// after the sink (`FlutterError.onError`, `PlatformDispatcher.onError`) can skip it. Answers
  /// false for an object it never saw, and it does not depend on [logs].
  bool reported(Object error) {
    for (final seen in _seen) {
      if (identical(seen, error)) return true;
    }
    return false;
  }

  /// The token is the start itself: [end] needs what the operation was, and nothing else.
  @override
  Object? start(TelemetryStart start) => start;

  @override
  void end(Object? token, TelemetryEnd end) {
    if (token is! TelemetryStart) return;
    try {
      if (token.op == TelemetryOp.navigate) {
        _navigated(end);
      } else if (end.outcome == TelemetryOutcome.error) {
        _failed(token, end);
      }
    } catch (_) {
      // A reporter that fails costs this report, never the app.
    }
  }

  /// The screen of a committed navigation. A superseded one showed nothing, so it sets nothing.
  void _navigated(TelemetryEnd e) {
    if (e.outcome == TelemetryOutcome.superseded) return;
    if (e.outcome == TelemetryOutcome.notFound) {
      _screenKey('');
      _log('navigation not found');
      return;
    }
    final route = e.route;
    if (route != null) _screenKey(route);
  }

  /// Sets the screen key to [value] when it differs from the one the reporter has.
  void _screenKey(String value) {
    if (value == _screen) return;
    _screen = value;
    _set(CrashlyticsKeys.screen, value);
  }

  /// A failure of [s]: an error object is reported (or logged by class), and one without an error
  /// object is a line in the log, which names the image's HTTP status.
  void _failed(TelemetryStart s, TelemetryEnd e) {
    final label =
        s.site?.file ?? s.file ?? s.authStep ?? s.imageCdn ?? s.name ?? '';
    final what = '${s.op.name} $label';
    final error = e.error;
    if (error == null) {
      final status = e.imageStatus;
      _log('$what error${status == null ? '' : ' status=$status'}');
      return;
    }
    _remember(error);
    if (!capture(error, s)) {
      _log('$what ${error is FieldErrors ? 'rejected' : error.runtimeType}');
      return;
    }
    final key = '$what ${error.runtimeType}';
    final now = clock.now();
    final last = _lastReport[key];
    if (last != null && now.difference(last) < repeatWindow) {
      _log('$what ${error.runtimeType} again');
      return;
    }
    _lastReport[key] = now;
    final route = s.site?.route ?? s.route;
    final file = s.site?.file ?? s.file;
    final action = s.op == TelemetryOp.action ? s.site?.name : null;
    final reason =
        'in $what${action == null ? '' : '#$action'}'
        '${route == null ? '' : ' on $route'}';
    final keys = <String, String>{
      CrashlyticsKeys.operation: s.op.name,
      CrashlyticsKeys.route: route ?? '',
      CrashlyticsKeys.file: file ?? '',
      CrashlyticsKeys.action: action ?? '',
    };
    final stack = e.stackTrace;
    _send(() => reporter.recordError(error, stack, reason: reason, keys: keys));
  }

  /// Keeps [error] as one the sink saw, forgetting the oldest beyond 32.
  void _remember(Object error) {
    _seen.add(error);
    if (_seen.length > _kept) _seen.removeAt(0);
  }

  /// How many errors [reported] remembers.
  static const int _kept = 32;

  @override
  void page(Object? navigation, TelemetryPage page) {
    try {
      if (!logs || page.kind == TelemetryPageKind.leave) return;
      final route = page.route;
      if (route == null) return;
      _log('navigation ${page.kind.name} $route');
    } catch (_) {
      // Same as every call into the reporter.
    }
  }

  void _set(String key, String value) =>
      _send(() => reporter.setCustomKey(key, value));

  void _log(String message) {
    if (logs) _send(() => reporter.log(message));
  }

  /// Calls one method of the reporter and drops its result: a returned `Future` is awaited by
  /// nobody, and its failure is handled here, so none is ever unhandled. A call that throws costs
  /// that call.
  static void _send(Future<void>? Function() call) {
    try {
      final future = call();
      if (future != null) {
        unawaited(
          future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      }
    } catch (_) {
      // A reporter that throws costs this call, never the app.
    }
  }
}
