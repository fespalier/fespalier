/// fespalier's telemetry in Sentry (since 0.9.0): errors and crashes tagged with the route pattern,
/// the app file and the action, one breadcrumb per page change, release health from the SDK, and,
/// next to `fespalier_otel`, the OpenTelemetry trace each event belongs to. Screen-load
/// transactions with spans for guards, data loads and actions are opt-in (`tracing: true`).
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugPrint,
        kDebugMode,
        kReleaseMode,
        visibleForTesting;
import 'package:flutter/widgets.dart' show NavigatorObserver;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'keys.dart';
import 'options.dart';
import 'scrub.dart' as scrub;
import 'tokens.dart';

/// Printed once when `tracing: true` meets `traceLifecycle: stream` (M-S2).
const String streamLifecycleMessage =
    "fespalier_sentry: Sentry's traceLifecycle is stream, which this version "
    'makes no spans for. Errors and breadcrumbs are still sent; use '
    'SentryTraceLifecycle.static for screen transactions.';

/// Printed once when `tracing: true` meets an SDK that samples nothing (M-S3).
const String tracingOffMessage =
    'fespalier_sentry: tracing: true needs Sentry to sample transactions, and '
    'tracesSampleRate is not set, so no transaction is sent. Pass tracing: true '
    'to FespalierSentry.configure, or set options.tracesSampleRate.';

/// fespalier's telemetry in Sentry (since 0.9.0): errors first.
///
/// ```dart
/// FespalierTelemetry.install(FespalierSentry());
/// ```
///
/// Out of the box it sends what a team debugging a production app asks for: every error and crash
/// tagged with the **route pattern** (`/products/:id`), the **app file** (`products/$id/data.dart`)
/// and the **action** that threw, with the screen as the event's transaction name; **one breadcrumb
/// per page change**; and, because the SDK owns them, release health and the crash itself. When
/// `fespalier_otel` runs next to it (`FespalierTelemetry.combine`), each event also carries the
/// OpenTelemetry trace id and span id of the screen or the call it came from (`otel.trace_id`,
/// `otel.span_id`), so an error links to its trace.
///
/// Performance is opt-in, for Sentry-only teams: `FespalierSentry(tracing: true)` turns each
/// navigation into a `ui.load` transaction named by the route pattern, with spans for guards,
/// redirects, data loads, deferred loads and actions, and time to initial and to full display. Pass
/// `tracing: true` to [configure] too, so the SDK samples.
///
/// Install it after `SentryFlutter.init` (in `startup()`, or in `zone()`'s `appRunner`) and before
/// the router is built. It returns at once, never throws, starts no timer and reads no provider; a
/// sync guard or `data()` stays sync. Segment values, query values, family keys, `extra`, action
/// inputs and results and data values are never sent, nor is a [FieldErrors] (its messages can echo
/// what the user typed).
final class FespalierSentry extends FespalierTelemetry {
  /// [hub] defaults to the hub `SentryFlutter.init` started ([HubAdapter]).
  FespalierSentry({
    Hub? hub,
    this.tracing = false,
    this.transactions = true,
    this.fullDisplay = true,
    this.breadcrumbs = true,
    this.routeTag = true,
    this.recordLocations = false,
    this.capture = unexpected,
    this.repeatWindow = const Duration(seconds: 30),
    @visibleForTesting SentryDisplay? Function(Hub hub)? currentDisplay,
    @visibleForTesting TargetPlatform? platform,
  }) : _hub = hub ?? HubAdapter(),
       _currentDisplay = currentDisplay ?? _sentryDisplay,
       _platform = platform;

  final Hub _hub;
  final SentryDisplay? Function(Hub hub) _currentDisplay;
  final TargetPlatform? _platform;

  static SentryDisplay? _sentryDisplay(Hub hub) =>
      SentryFlutter.currentDisplay(hub: hub);

  /// Whether each navigation becomes a `ui.load` transaction named by the route pattern, with
  /// child spans for the guards, redirects, data loads, deferred loads and actions that ran in it,
  /// and time to initial and to full display. Off by default: errors, breadcrumbs and release
  /// health need none of it. For a team that has only Sentry (with `fespalier_otel` the traces are
  /// there already). Needs the SDK to sample: pass `tracing: true` to [configure] too.
  final bool tracing;

  /// With [tracing]: whether this sink makes the transactions (the default), or a plain
  /// `SentryNavigatorObserver` does and this sink adds its data spans, time to full display, events
  /// and breadcrumbs to them (no guard, redirect or deferred spans: they run before the observer's
  /// transaction exists). Never run both: every screen would get two `ui.load` transactions.
  final bool transactions;

  /// With [tracing]: whether a screen's transaction waits for the data loads that started in its
  /// navigation, and reports time to full display when the last one ends.
  final bool fullDisplay;

  /// Whether a page change, a guard redirect, an action's result, an auth step, an image failure
  /// and a repeated error become breadcrumbs.
  final bool breadcrumbs;

  /// Whether each committed navigation names the scope after its screen: the scope's transaction
  /// (the name events are grouped and searched by in Sentry) and the tag `fespalier.route`, so that
  /// every later event, a crash included, says which screen it happened on.
  final bool routeTag;

  /// Whether a transaction carries the committed path (`url.path`) and a guard span the path it
  /// redirected to. Segment values are app data, so it is off. The query is never recorded.
  final bool recordLocations;

  /// Which failures become Sentry events; the others become breadcrumbs. [unexpected] by default.
  final bool Function(Object error, TelemetryStart start) capture;

  /// A failure with the same operation, file and exception type as one captured less than this
  /// long ago is a breadcrumb, not another event: a `data.dart` that Riverpod retries fails once
  /// per attempt. `Duration.zero` captures every one.
  final Duration repeatWindow;

  /// The default [capture]: every failure except a [FieldErrors] (a validation answer, shown on
  /// the form) and an `auth` step's (`fespalier_auth` reports a network failure there, which the
  /// next request retries).
  static bool unexpected(Object error, TelemetryStart start) =>
      error is! FieldErrors && start.op != TelemetryOp.auth;

  /// fespalier's defaults on Sentry's options. Call it first in `SentryFlutter.init`'s
  /// configuration; callbacks set before it are kept and run before its own.
  ///
  /// Sets [dsn] (`''` sends nothing: pass `const String.fromEnvironment('SENTRY_DSN')` and a build
  /// without the define is silent); `sendDefaultPii`, `attachScreenshot` and `attachViewHierarchy`
  /// to false (a screenshot or a widget tree can show user data); `enableAutoSessionTracking` to
  /// true (release health); `tracePropagationTargets` to [propagateTraceTo] (empty: no trace header
  /// leaves the app, where Sentry's default sends `baggage`, with the release and the environment,
  /// to every host); and `beforeBreadcrumb`, `beforeSend` and `beforeSendTransaction` to drop query
  /// and fragment values from Sentry's own HTTP breadcrumbs, events and spans ([recordQueries]
  /// keeps them) and navigations that a newer one superseded. `SentryNavigatorObserver`'s own
  /// breadcrumbs are dropped, since this sink's say the same with the route pattern
  /// ([observerBreadcrumbs] keeps them).
  ///
  /// Tracing is off unless asked for: [tracesSampleRate] sets it, and [tracing] without a rate
  /// samples 1.0 in debug and profile builds and 0.1 in release (an `options.tracesSampleRate` set
  /// before this call is kept). [tracing] also turns on `enableTimeToFullDisplayTracing`. Pass the
  /// same [tracing] to `FespalierSentry(tracing:)`.
  ///
  /// Throws an [ArgumentError] for a [tracesSampleRate] outside 0..1.
  static void configure(
    SentryFlutterOptions options, {
    required String dsn,
    bool tracing = false,
    double? tracesSampleRate,
    List<String> propagateTraceTo = const [],
    bool recordQueries = false,
    bool observerBreadcrumbs = false,
  }) {
    if (tracesSampleRate != null &&
        !(tracesSampleRate >= 0 && tracesSampleRate <= 1)) {
      throw ArgumentError.value(
        tracesSampleRate,
        'tracesSampleRate',
        'must be between 0 and 1',
      );
    }
    options
      ..dsn = dsn
      ..sendDefaultPii = false
      ..attachScreenshot = false
      // ignore: experimental_member_use
      ..attachViewHierarchy = false
      ..enableAutoSessionTracking = true;
    if (tracesSampleRate != null) {
      options.tracesSampleRate = tracesSampleRate;
    } else if (tracing) {
      options.tracesSampleRate ??= kReleaseMode ? 0.1 : 1.0;
    }
    if (tracing) options.enableTimeToFullDisplayTracing = true;
    options.tracePropagationTargets
      ..clear()
      ..addAll(propagateTraceTo);

    final beforeBreadcrumb = options.beforeBreadcrumb;
    options.beforeBreadcrumb = (breadcrumb, hint) {
      final kept = beforeBreadcrumb == null
          ? breadcrumb
          : beforeBreadcrumb(breadcrumb, hint);
      if (kept == null) return null;
      if (!observerBreadcrumbs && scrub.isObserverBreadcrumb(kept)) return null;
      return recordQueries ? kept : scrub.breadcrumbWithoutQueries(kept, hint);
    };
    final beforeSend = options.beforeSend;
    options.beforeSend = (event, hint) => _after<SentryEvent>(
      beforeSend == null ? event : beforeSend(event, hint),
      (kept) => recordQueries ? kept : scrub.eventWithoutQueries(kept, hint),
    );
    final beforeSendTransaction = options.beforeSendTransaction;
    options.beforeSendTransaction = (transaction, hint) =>
        _after<SentryTransaction>(
          beforeSendTransaction == null
              ? transaction
              : beforeSendTransaction(transaction, hint),
          (kept) => recordQueries
              ? (scrub.isSuperseded(kept) ? null : kept)
              : scrub.transactionWithoutQueries(kept, hint),
        );
  }

  /// [then] on what an earlier callback returned, which may be a `Future`: a sync callback stays
  /// sync, and one that dropped the event (null) stays dropped.
  static FutureOr<T?> _after<T extends SentryEvent>(
    FutureOr<T?> earlier,
    T? Function(T kept) then,
  ) {
    if (earlier is Future<T?>) {
      return earlier.then((kept) => kept == null ? null : then(kept));
    }
    return earlier == null ? null : then(earlier);
  }

  /// A `SentryNavigatorObserver` that makes no transaction (`enableAutoTransactions: false`): it
  /// is what starts release health on the web (`WebSessionIntegration` waits for it), names
  /// Sentry's app-start screen and fills `view_names`. Add it to `routerObservers` on the web; on
  /// Android, iOS and desktop the SDK needs none for sessions. Never add a plain
  /// `SentryNavigatorObserver()` next to this sink with [tracing]: every screen gets two `ui.load`
  /// transactions.
  static NavigatorObserver navigatorObserver({Hub? hub}) =>
      SentryNavigatorObserver(hub: hub, enableAutoTransactions: false);

  /// [breadcrumb] without the query and fragment values Sentry's HTTP integrations put on it
  /// (`http.query`, `http.fragment`, and the query of `url`); what [configure] installs.
  static Breadcrumb? withoutQueries(Breadcrumb? breadcrumb, Hint hint) =>
      scrub.breadcrumbWithoutQueries(breadcrumb, hint);

  /// [event] without the query and the fragment of its request; what [configure] installs.
  static SentryEvent? eventWithoutQueries(SentryEvent event, Hint hint) =>
      scrub.eventWithoutQueries(event, hint);

  /// [transaction] without query and fragment values on the data of its spans, or null for a
  /// navigation that a newer one superseded (it never showed a screen); what [configure] installs.
  static SentryTransaction? transactionWithoutQueries(
    SentryTransaction transaction,
    Hint hint,
  ) => scrub.transactionWithoutQueries(transaction, hint);

  // ---------------------------------------------------------------------------------------------
  // State. Tokens are `NavToken` (navigations) and `OpToken` (everything else); nothing else.

  /// Whether `tracing: true` can make spans on this SDK: decided at the first operation.
  bool? _spans;

  /// What `readHub` said at that moment.
  HubReads? _reads;

  /// The last screen that waits for its data (`tracing: true`).
  NavToken? _waiting;

  /// The last page entered or focused: the `from` of the next breadcrumb.
  String? _visible;

  /// The captures inside [repeatWindow], by operation, file and exception type.
  final Map<String, DateTime> _lastCapture = {};

  bool _sawNavigation = false;
  bool _saidStream = false;
  bool _saidNoTracing = false;

  /// Whether this sink makes spans: [tracing], on an SDK that samples and is not streaming.
  bool _spansOn() {
    final known = _spans;
    if (known != null) return known;
    if (!tracing) return _spans = false;
    final reads = _reads = readHub(_hub, platform: _platform);
    if (reads.stream) {
      _say(streamLifecycleMessage, stream: true);
      return _spans = false;
    }
    if (!reads.tracingOn) {
      _say(tracingOffMessage, stream: false);
      return _spans = false;
    }
    return _spans = true;
  }

  void _say(String message, {required bool stream}) {
    if (stream ? _saidStream : _saidNoTracing) return;
    if (stream) {
      _saidStream = true;
    } else {
      _saidNoTracing = true;
    }
    if (kDebugMode) debugPrint(message);
  }

  /// [result] of an SDK call, fired and forgotten: an error of the SDK is dropped, so none is ever
  /// unhandled.
  static void _fire(Object? result) {
    if (result is Future<Object?>) {
      unawaited(
        result.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  // ---------------------------------------------------------------------------------------------
  // start

  @override
  Object? start(TelemetryStart start) {
    try {
      if (!_hub.isEnabled) return null;
      final spans = _spansOn();
      return switch (start.op) {
        TelemetryOp.navigate => _startNavigation(start, spans),
        TelemetryOp.data => _startData(start, spans),
        TelemetryOp.action => _startAction(start, spans),
        TelemetryOp.auth => _startAuth(start, spans),
        TelemetryOp.guard ||
        TelemetryOp.redirect ||
        TelemetryOp.deferred ||
        TelemetryOp.image ||
        TelemetryOp.custom => _startChild(start, spans),
      };
    } catch (_) {
      return null;
    }
  }

  NavToken _startNavigation(TelemetryStart s, bool spans) {
    final first = !_sawNavigation;
    _sawNavigation = true;
    if (!spans) return NavToken(NavKind.light);
    // The previous screen never got its data in time.
    _deadline(_waiting);
    if (!transactions) return NavToken(NavKind.observer);
    // A pop or a refresh starts at its commit and shows a page that is already built: a
    // near-zero `ui.load` would only skew the screen-load numbers.
    if (s.uri == null) return NavToken(NavKind.light);
    if (first && (_reads?.appStartOwnsFirstScreen ?? false)) {
      return NavToken(NavKind.appStart);
    }
    // No `waitForChildren` and no `autoFinishAfter`: Sentry starts no timer for this. It ends when
    // the screen's data has arrived, or when the next navigation starts.
    final tx = _hub.startTransactionWithContext(
      SentryTransactionContext(
        'navigate',
        SentryKeys.uiLoad,
        transactionNameSource: SentryTransactionNameSource.route,
        origin: SentryKeys.navigationOrigin,
      ),
      bindToScope: true,
    );
    return NavToken(NavKind.transaction, tx);
  }

  /// The navigation [s] belongs to, if its parent is one of ours.
  static NavToken? _screenOf(TelemetryStart s) {
    final parent = s.parent;
    return parent is NavToken ? parent : null;
  }

  OpToken _startChild(TelemetryStart s, bool spans) {
    final screen = _screenOf(s);
    if (!spans) return OpToken(s, screen: screen);
    ISentrySpan? parent;
    if (screen != null) {
      // Observer mode and the app-start screen make no guard, redirect, deferred or image span:
      // those run before the transaction of the screen exists.
      parent = screen.kind == NavKind.transaction ? screen.tx : null;
    } else if (s.op != TelemetryOp.image && transactions) {
      parent = _hub.getSpan();
    }
    return OpToken(
      s,
      screen: screen,
      span: _child(parent, 'fespalier.${s.op.name}', s),
    );
  }

  OpToken _startData(TelemetryStart s, bool spans) {
    final screen = _screenOf(s);
    if (!spans) return OpToken(s, screen: screen);
    ISentrySpan? parent;
    if (screen == null) {
      parent = transactions ? null : _hub.getSpan();
    } else {
      parent = switch (screen.kind) {
        NavKind.transaction => screen.tx,
        NavKind.observer => _hub.getSpan(),
        NavKind.appStart || NavKind.light => null,
      };
    }
    final token = OpToken(
      s,
      screen: screen,
      span: _child(parent, 'fespalier.data', s),
    );
    if (screen != null && screen.kind != NavKind.light && fullDisplay) {
      screen.openData++;
      token.counted = true;
      if (screen.kind == NavKind.transaction) screen.open.add(token);
    }
    return token;
  }

  OpToken _startAction(TelemetryStart s, bool spans) {
    if (!spans) return OpToken(s);
    final bound = _hub.getSpan();
    if (bound != null && !bound.finished) {
      return OpToken(s, span: _child(bound, 'fespalier.action', s));
    }
    // No screen is open: the action is a transaction of its own, so the HTTP calls it makes
    // have a parent.
    final site = s.site;
    final tx = _hub.startTransactionWithContext(
      SentryTransactionContext(
        'action ${site?.file}#${site?.name}',
        SentryKeys.actionOp,
        transactionNameSource: SentryTransactionNameSource.component,
        origin: SentryKeys.navigationOrigin,
      ),
      bindToScope: true,
    );
    _describeStart(tx, s);
    return OpToken(s, span: tx, ownsTransaction: true);
  }

  OpToken _startAuth(TelemetryStart s, bool spans) {
    if (!spans) return OpToken(s);
    final bound = _hub.getSpan();
    final parent = bound == null || bound.finished ? null : bound;
    return OpToken(s, span: _child(parent, 'fespalier.auth', s));
  }

  /// A child of [parent] for [s], with what the start says; null when there is no parent.
  ISentrySpan? _child(ISentrySpan? parent, String operation, TelemetryStart s) {
    if (parent == null) return null;
    final span = parent.startChild(operation, description: _describe(s));
    _describeStart(span, s);
    return span;
  }

  /// The span's description: the operation, then what it is about (a file, a step), never a
  /// value.
  static String _describe(TelemetryStart s) {
    final site = s.site;
    return switch (s.op) {
      TelemetryOp.navigate => 'navigate',
      TelemetryOp.guard ||
      TelemetryOp.redirect ||
      TelemetryOp.data => '${s.op.name} ${site?.file}',
      TelemetryOp.action => 'action ${site?.file}#${site?.name}',
      TelemetryOp.deferred => 'deferred ${s.file}',
      TelemetryOp.auth => 'auth ${s.authStep}',
      TelemetryOp.image => 'image ${s.imageCdn}',
      TelemetryOp.custom => '${s.name}',
    };
  }

  /// The data every span of [s] starts with: the conventions' keys, never a value.
  void _describeStart(ISentrySpan span, TelemetryStart s) {
    final site = s.site;
    final route = site?.route ?? s.route;
    final file = site?.file ?? s.file;
    span.setData(SentryKeys.operation, s.op.name);
    if (route != null) span.setData(SentryKeys.route, route);
    if (file != null) span.setData(SentryKeys.file, file);
    switch (s.op) {
      case TelemetryOp.data:
        span.setData(SentryKeys.keyed, s.keyed);
      case TelemetryOp.action:
        final name = site?.name;
        if (name != null) span.setData(SentryKeys.action, name);
      case TelemetryOp.auth:
        final step = s.authStep;
        final backend = s.authBackend;
        final trigger = s.authTrigger;
        if (step != null) span.setData(SentryKeys.authOperation, step);
        if (backend != null) span.setData(SentryKeys.authBackend, backend);
        if (trigger != null) span.setData(SentryKeys.authTrigger, trigger);
        span.setData(SentryKeys.authDpop, s.authDpop);
      case TelemetryOp.image:
        final width = s.imageWidth;
        final cdn = s.imageCdn;
        if (cdn != null) span.setData(SentryKeys.imageCdn, cdn);
        if (width != null) span.setData(SentryKeys.imageWidth, width);
        span.setData(SentryKeys.imagePreload, s.imagePreload);
      // A custom operation's own attributes are never sent: only its name (the span's
      // description) and the operation.
      case TelemetryOp.navigate ||
          TelemetryOp.guard ||
          TelemetryOp.redirect ||
          TelemetryOp.deferred ||
          TelemetryOp.custom:
        break;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // The other sink's trace

  @override
  void linkTrace(Object? token, TelemetryTrace trace) {
    if (token is NavToken) {
      token.trace = trace;
    } else if (token is OpToken) {
      token.trace = trace;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // end

  @override
  void end(Object? token, TelemetryEnd end) {
    try {
      switch (token) {
        case NavToken():
          _endNavigation(token, end);
        case OpToken():
          _endOp(token, end);
      }
    } catch (_) {
      // A failing SDK costs this operation's detail, never the app.
    }
  }

  void _endNavigation(NavToken nav, TelemetryEnd e) {
    final tx = nav.tx;
    if (e.outcome == TelemetryOutcome.superseded) {
      // A newer navigation started before this one committed: it never showed a screen.
      if (tx != null) {
        tx.setTag(SentryKeys.navigationOutcome, TelemetryOutcome.superseded);
        _fire(tx.finish(status: const SpanStatus.cancelled()));
      }
      return;
    }
    final notFound = e.outcome == TelemetryOutcome.notFound;
    final route = notFound ? null : e.route;
    nav.name = notFound ? 'navigate (not found)' : (route ?? 'navigate');
    _nameScope(nav, route);
    switch (nav.kind) {
      case NavKind.transaction:
        _endTransaction(nav, e);
      case NavKind.appStart || NavKind.observer:
        nav.ended = true;
        if (fullDisplay && e.outcome == TelemetryOutcome.ok) {
          nav.display = _currentDisplay(_hub);
        }
        if (nav.openData == 0) _displayed(nav);
      case NavKind.light:
        break;
    }
    if (notFound && breadcrumbs) {
      _crumb(
        Breadcrumb(
          type: SentryKeys.navigationCategory,
          category: SentryKeys.navigationCategory,
          message: 'not found',
          level: SentryLevel.warning,
          data: {if (e.from != null) 'from': e.from},
        ),
      );
    }
  }

  /// Names the scope after the screen: its transaction, the tag `fespalier.route`, and the
  /// OpenTelemetry trace of the navigation, so that every later event, a crash included, says
  /// which screen it happened on and links to the trace that opened it.
  void _nameScope(NavToken nav, String? route) {
    final trace = nav.trace;
    _fire(
      _hub.configureScope((scope) {
        final span = scope.span;
        final ours = nav.tx != null && identical(span, nav.tx);
        // Only a transaction that is ours, or none: never rename Sentry's own. Ours is renamed
        // whatever `routeTag` says (it is the screen's transaction); the scope keeps the name
        // only with `routeTag`.
        if (ours || (routeTag && span == null)) scope.transaction = nav.name;
        if (routeTag) {
          _tag(scope, SentryKeys.route, route);
        } else if (ours) {
          scope.transaction = null;
        }
        _tag(scope, SentryKeys.otelTraceId, trace?.traceId);
        _tag(scope, SentryKeys.otelSpanId, trace?.spanId);
      }),
    );
  }

  /// Sets the scope tag [key] to [value], or takes it off when [value] is null; only when that
  /// changes it, since each call is told to the native SDK.
  static void _tag(Scope scope, String key, String? value) {
    if (scope.tags[key] == value) return;
    _fire(value == null ? scope.removeTag(key) : scope.setTag(key, value));
  }

  void _endTransaction(NavToken nav, TelemetryEnd e) {
    final tx = nav.tx!;
    tx.setTag(SentryKeys.navigationOutcome, e.outcome);
    final kind = e.kind;
    if (kind != null) tx.setTag(SentryKeys.navigationKind, kind);
    final trace = nav.trace;
    if (trace != null) {
      tx
        ..setTag(SentryKeys.otelTraceId, trace.traceId)
        ..setTag(SentryKeys.otelSpanId, trace.spanId);
    }
    final from = e.from;
    if (from != null) tx.setData(SentryKeys.navigationFrom, from);
    tx
      ..setData(SentryKeys.navigationRedirected, e.redirected)
      ..setData(SentryKeys.navigationDepth, e.depth);
    final location = e.location;
    if (recordLocations && location != null) {
      tx.setData(SentryKeys.urlPath, Uri.parse(location).path);
    }
    final ok = e.outcome == TelemetryOutcome.ok;
    nav.shown = ok;
    if (ok) {
      final ttid = tx.startChild(
        SentryKeys.initialDisplayOp,
        description: '${nav.name} initial display',
        startTimestamp: tx.startTimestamp,
      );
      _fire(ttid.finish(status: const SpanStatus.ok()));
      _measure(tx, SentryKeys.ttidMeasurement, ttid.endTimestamp);
    }
    if (!fullDisplay || nav.openData == 0 || !ok) {
      _displayed(nav);
    } else {
      // Its data is still loading: it ends when the last load does, or when the next navigation
      // starts, whichever is first.
      nav.ended = true;
      _waiting = nav;
    }
  }

  /// Sets the measurement [name] of [tx]: the time from its start to [end].
  void _measure(ISentrySpan tx, String name, DateTime? end) {
    if (end == null) return;
    tx.setMeasurement(
      name,
      end.difference(tx.startTimestamp).inMilliseconds,
      unit: DurationSentryMeasurementUnit.milliSecond,
    );
  }

  /// The screen [nav] has its data (or never waited for any).
  void _displayed(NavToken nav) {
    if (identical(_waiting, nav)) _waiting = null;
    switch (nav.kind) {
      case NavKind.transaction:
        _finishScreen(nav, deadline: false);
      case NavKind.appStart || NavKind.observer:
        final display = nav.display;
        nav.display = null;
        if (display != null) _fire(display.reportFullyDisplayed());
      case NavKind.light:
        break;
    }
  }

  /// The next navigation started before [screen] had all its data: its open data spans, and its
  /// time to full display, end with `deadline_exceeded` and no measurement.
  void _deadline(NavToken? screen) {
    if (screen == null) return;
    _waiting = null;
    for (final op in List<OpToken>.of(screen.open)) {
      op.done = true;
      final span = op.span;
      if (span != null) {
        _fire(span.finish(status: const SpanStatus.deadlineExceeded()));
      }
    }
    screen.open.clear();
    screen.openData = 0;
    if (screen.kind == NavKind.transaction) {
      _finishScreen(screen, deadline: true);
    }
  }

  /// Ends a screen's transaction, with its time to full display.
  void _finishScreen(NavToken screen, {required bool deadline}) {
    final tx = screen.tx;
    if (tx == null) return;
    if (fullDisplay && screen.shown) {
      final span = tx.startChild(
        SentryKeys.fullDisplayOp,
        description: '${screen.name} full display',
        startTimestamp: tx.startTimestamp,
      );
      _fire(
        span.finish(
          status: deadline
              ? const SpanStatus.deadlineExceeded()
              : const SpanStatus.ok(),
        ),
      );
      if (!deadline) {
        _measure(tx, SentryKeys.ttfdMeasurement, span.endTimestamp);
      }
    }
    _fire(tx.finish(status: const SpanStatus.ok()));
  }

  void _endOp(OpToken t, TelemetryEnd e) {
    if (t.done) return;
    t.done = true;
    final s = t.start;
    final span = t.span;
    if (span != null) {
      _describeEnd(span, s, e);
      _fire(span.finish(status: _status(s, e)));
    }
    if (e.outcome == TelemetryOutcome.error) _error(t, e);
    if (breadcrumbs) _opCrumb(t, e);
    final screen = t.screen;
    if (t.counted && screen != null) {
      screen.openData--;
      screen.open.remove(t);
      if (screen.ended && screen.openData <= 0) _displayed(screen);
    }
  }

  /// What an operation's end says, on its span: the outcome keys of the conventions.
  void _describeEnd(ISentrySpan span, TelemetryStart s, TelemetryEnd e) {
    final outcomeKey = switch (s.op) {
      TelemetryOp.guard || TelemetryOp.redirect => SentryKeys.guardDecision,
      TelemetryOp.data => SentryKeys.dataState,
      TelemetryOp.action => SentryKeys.actionResult,
      TelemetryOp.deferred => SentryKeys.deferredResult,
      TelemetryOp.auth => SentryKeys.authResult,
      TelemetryOp.image => SentryKeys.imageResult,
      TelemetryOp.custom => SentryKeys.customResult,
      TelemetryOp.navigate => null,
    };
    if (outcomeKey != null) span.setData(outcomeKey, e.outcome);
    if (s.op != TelemetryOp.deferred &&
        s.op != TelemetryOp.image &&
        s.op != TelemetryOp.navigate) {
      span.setData(SentryKeys.isAsync, e.isAsync);
    }
    final location = e.location;
    if (recordLocations &&
        location != null &&
        (s.op == TelemetryOp.guard || s.op == TelemetryOp.redirect)) {
      span.setData(SentryKeys.guardLocation, Uri.parse(location).path);
    }
    final status = e.imageStatus;
    if (status != null) span.setData(SentryKeys.imageStatus, status);
  }

  /// The span status an operation's end maps to.
  static SpanStatus _status(TelemetryStart s, TelemetryEnd e) {
    final outcome = e.outcome;
    if (outcome == TelemetryOutcome.disposed ||
        outcome == TelemetryOutcome.cancelled) {
      return const SpanStatus.cancelled();
    }
    if (outcome == TelemetryOutcome.rejected && s.op == TelemetryOp.auth) {
      return const SpanStatus.unauthenticated();
    }
    if (outcome == TelemetryOutcome.error) {
      if (e.error is FieldErrors) return const SpanStatus.invalidArgument();
      final status = e.imageStatus;
      if (s.op == TelemetryOp.image && status != null) {
        return SpanStatus.fromHttpStatusCode(status);
      }
      return const SpanStatus.internalError();
    }
    return const SpanStatus.ok();
  }

  // ---------------------------------------------------------------------------------------------
  // Errors

  /// What names an operation in a breadcrumb or a key: its file, its auth step, its image CDN or
  /// its custom name.
  static String _label(TelemetryStart s) =>
      s.site?.file ?? s.file ?? s.authStep ?? s.imageCdn ?? s.name ?? '';

  void _error(OpToken t, TelemetryEnd e) {
    final error = e.error;
    final s = t.start;
    if (error == null) return;
    final what = '${s.op.name} ${_label(s)}';
    if (!capture(error, s)) {
      if (breadcrumbs) {
        _crumb(
          Breadcrumb(
            category: 'fespalier.${s.op.name}',
            message:
                '$what ${error is FieldErrors ? 'rejected' : error.runtimeType}',
            level: error is FieldErrors
                ? SentryLevel.info
                : SentryLevel.warning,
          ),
        );
      }
      return;
    }
    final key = '$what ${error.runtimeType}';
    final now = clock.now();
    final last = _lastCapture[key];
    if (last != null && now.difference(last) < repeatWindow) {
      if (breadcrumbs) {
        _crumb(
          Breadcrumb(
            category: 'fespalier.${s.op.name}',
            message: '$what ${error.runtimeType} again',
            level: SentryLevel.warning,
          ),
        );
      }
      return;
    }
    _lastCapture[key] = now;
    final site = s.site;
    final route = site?.route ?? s.route;
    final file = site?.file ?? s.file;
    final action = site?.name;
    final trace = t.trace;
    // `withScope` runs on a clone, so the global scope keeps no per-error tags. The callback runs
    // before `captureException` first suspends, so what it sets is what is sent.
    _fire(
      _hub.captureException(
        ThrowableMechanism(
          Mechanism(type: 'fespalier.${s.op.name}', handled: true),
          error,
        ),
        stackTrace: e.stackTrace,
        withScope: (scope) {
          scope
            ..setTag(SentryKeys.operation, s.op.name)
            ..fingerprint = ['{{ default }}', ?file];
          if (route != null) scope.setTag(SentryKeys.route, route);
          if (file != null) scope.setTag(SentryKeys.file, file);
          if (action != null) scope.setTag(SentryKeys.action, action);
          scope.setContexts(SentryKeys.fespalierContext, {
            SentryKeys.operation: s.op.name,
            SentryKeys.route: ?route,
            SentryKeys.file: ?file,
            SentryKeys.action: ?action,
            SentryKeys.isAsync: e.isAsync,
            if (s.op == TelemetryOp.data) SentryKeys.keyed: s.keyed,
          });
          if (trace != null) {
            scope
              ..setTag(SentryKeys.otelTraceId, trace.traceId)
              ..setTag(SentryKeys.otelSpanId, trace.spanId)
              ..setContexts(SentryKeys.otelContext, {
                'trace_id': trace.traceId,
                'span_id': trace.spanId,
              });
          }
          final span = t.span;
          if (span != null) scope.span = span;
        },
      ),
    );
  }

  /// Breadcrumbs for what an operation decided: a guard that redirected, an action's result, an
  /// auth step, an image that failed. Failures that [_error] handles are its own.
  void _opCrumb(OpToken t, TelemetryEnd e) {
    final s = t.start;
    switch (s.op) {
      case TelemetryOp.guard || TelemetryOp.redirect:
        if (e.outcome != TelemetryOutcome.redirect) return;
        final location = e.location;
        _crumb(
          Breadcrumb(
            category: 'fespalier.guard',
            message: 'redirect by ${_label(s)}',
            data: {
              if (recordLocations && location != null)
                SentryKeys.guardLocation: Uri.parse(location).path,
            },
          ),
        );
      case TelemetryOp.action:
        if (e.outcome == TelemetryOutcome.error) return;
        _crumb(
          Breadcrumb(
            category: 'fespalier.action',
            message: '${_label(s)}#${s.site?.name} ${e.outcome}',
          ),
        );
      case TelemetryOp.auth:
        if (e.outcome == TelemetryOutcome.error) return;
        _crumb(
          Breadcrumb(
            category: 'fespalier.auth',
            message: 'auth ${s.authStep} ${e.outcome}',
          ),
        );
      case TelemetryOp.image:
        if (e.outcome != TelemetryOutcome.error) return;
        final status = e.imageStatus;
        _crumb(
          Breadcrumb(
            category: 'fespalier.image',
            message:
                'image ${s.imageCdn} error${status == null ? '' : ' status=$status'}',
            level: SentryLevel.warning,
          ),
        );
      case TelemetryOp.navigate ||
          TelemetryOp.data ||
          TelemetryOp.deferred ||
          TelemetryOp.custom:
        break;
    }
  }

  void _crumb(Breadcrumb breadcrumb) => _fire(_hub.addBreadcrumb(breadcrumb));

  // ---------------------------------------------------------------------------------------------
  // page

  @override
  void page(Object? navigation, TelemetryPage page) {
    try {
      final route = page.route;
      if (page.kind == TelemetryPageKind.leave || route == null) return;
      final from = _visible;
      _visible = route;
      if (!breadcrumbs || !_hub.isEnabled) return;
      _crumb(
        Breadcrumb(
          type: SentryKeys.navigationCategory,
          category: SentryKeys.navigationCategory,
          message: '${page.kind.name} $route',
          data: {'from': ?from, 'to': route},
        ),
      );
    } catch (_) {
      // Same as every call into the SDK.
    }
  }
}
