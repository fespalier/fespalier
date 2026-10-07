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
///
/// Since 0.9.0 several sinks share the one slot ([FespalierTelemetry.combine],
/// [FespalierTelemetry.add]), a sink can make the span of a `data()` or an action current while
/// it runs ([FespalierTelemetry.within]), and a navigation can say where it came from
/// ([navigateFrom]).
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
  ///
  /// There is one slot: a second `install` replaces the first. Use [combine] or [add] to report to
  /// several sinks.
  static void install(FespalierTelemetry? sink) => _current = sink;

  /// One sink that tells each of [sinks] everything, in order (since 0.9.0): OpenTelemetry,
  /// Sentry and analytics side by side, though [install] holds one sink.
  ///
  /// Each sink gets the token it returned itself, at [end], [page] and [within], and as the
  /// [TelemetryStart.parent] of what runs under one of its navigations: no sink ever sees another
  /// sink's token. A sink that throws is isolated: the others and the app go on, its error is
  /// printed once (`fespalier telemetry: <error> in <Sink> (not shown again)`), and it is called
  /// again next time. A combined sink in [sinks] is flattened; `combine([])` reports nothing, and
  /// `combine([sink])` is [sink].
  static FespalierTelemetry combine(List<FespalierTelemetry> sinks) {
    final children = <_Child>[];
    for (final sink in sinks) {
      switch (sink) {
        case _Combined():
          children.addAll(sink._children);
        case _NoTelemetry():
          break;
        default:
          children.add(_Child(sink));
      }
    }
    return switch (children.length) {
      0 => const _NoTelemetry(),
      1 => children.single.sink,
      _ => _Combined(List<_Child>.unmodifiable(children)),
    };
  }

  /// Installs [sink] next to the installed one (since 0.9.0): `install(combine([?current, sink]))`.
  /// For adapters (their `FespalierAdapter.beforeRun`) and apps that share the one slot;
  /// [install] replaces everything, `install(null)` removes everything.
  static void add(FespalierTelemetry sink) =>
      _current = combine([?_current, sink]);

  /// Runs [body] within the operation [token] came from, as fespalier does around `data()`
  /// (since 0.9.0): for adapter packages that start operations of their own with [begin]. [body]
  /// runs once, synchronously; what it returns (the very object) or throws comes back. With no
  /// sink, or a null [token], it is `body()`.
  static T run<T>(Object? token, T Function() body) =>
      telemetryWithin(token, body);

  /// Starts an operation with the installed sink, for an adapter package such as
  /// `fespalier_auth` (since 0.9.0): fespalier's own call sites use the internal functions of this
  /// library. Returns what the sink's [start] returned, to hand to [finish]; null when no sink
  /// is installed (the whole cost is one null check) or when the sink threw (printed once).
  ///
  /// With [underNavigation], an operation that has no [TelemetryStart.parent] is made the child of
  /// the navigation that is in progress, if there is one (`fespalier_image` does: an image that
  /// starts loading while a page is being reached is part of that navigation).
  static Object? begin(TelemetryStart start, {bool underNavigation = false}) {
    // Only with a sink installed: with telemetry off a package's mistake is not the app's to hear.
    assert(FespalierTelemetry._current == null || _checkCustom(start));
    final navigation = _pendingNavigation;
    return telemetryBegin(
      underNavigation && start.parent == null && navigation != null
          ? start._withParent(navigation)
          : start,
    );
  }

  /// Ends the operation [token] came from (what [begin] returned), for an adapter package
  /// (since 0.9.0). Does nothing without a sink; a sink that throws is printed once and dropped.
  static void finish(Object? token, TelemetryEnd end) {
    assert(FespalierTelemetry._current == null || _checkCustomEnd(end));
    telemetryFinish(token, end);
  }

  /// An operation started. Returns a token that fespalier hands back to [end] (and, for a
  /// navigation, to [page] and as [TelemetryStart.parent] of what runs during it); null is fine.
  Object? start(TelemetryStart start) => null;

  /// The operation [token] came from ended.
  void end(Object? token, TelemetryEnd end) {}

  /// A page was entered, focused or left at the end of the navigation [navigation] (the token
  /// [start] returned for it).
  void page(Object? navigation, TelemetryPage page) {}

  /// Runs [body] inside the operation [token] came from (since 0.9.0). fespalier calls it around a
  /// `data()` and an action's function, so a sink can make that operation's span current while
  /// they run: a span made inside them (an HTTP client's), after an `await` too, is then its child.
  ///
  /// Call [body] once, synchronously, before returning. You may run it in a zone of your own made
  /// with zone values only (`runZoned(body, zoneValues: ...)`; OpenTelemetry's
  /// `Context.current.withSpan(span).runSync(body)`). Never give that zone an error handler
  /// (`runZonedGuarded`, `onError:`, `ZoneSpecification.handleUncaughtError`): a `Future` that fails
  /// in another error zone never reaches Riverpod, so fespalier refuses such a zone and runs
  /// [body] outside it.
  ///
  /// [body] returns what the operation returned (null when it threw; [end] says so), so a sink can
  /// observe it, e.g. hand the `Future` to a vendor API that ends a span when it settles. It never
  /// throws: fespalier rethrows what the operation threw after this returns. Whatever this method
  /// does, fespalier returns the operation's own result, the very object; a sink cannot replace
  /// it. The default calls [body].
  void within(Object? token, Object? Function() body) => body();

  /// The trace the operation [token] came from is in, on this sink's own tracing backend (since
  /// 0.9.0), or null when it has none. A sink that makes OpenTelemetry spans answers with the
  /// trace and span id of the span it made for [token]; one that makes none keeps the default.
  ///
  /// [FespalierTelemetry.combine] asks it once per operation, right after every sink has started
  /// it, and tells the other sinks through [linkTrace]. It must return at once and never throw.
  TelemetryTrace? traceOf(Object? token) => null;

  /// Another sink of the same [combine] says that the operation [token] (a token this sink
  /// returned from [start]) is in [trace] (since 0.9.0): `fespalier_sentry` tags its events with
  /// it, so an error links to the OpenTelemetry trace of the screen or the call it came from. It
  /// is called at most once per operation, before the operation's [within] and [end]. The default
  /// ignores it.
  void linkTrace(Object? token, TelemetryTrace trace) {}
}

/// A trace and a span, as a sink reports them for an operation (since 0.9.0): the W3C Trace
/// Context identifiers every tracing backend uses, so one sink can tell another which trace an
/// operation is in ([FespalierTelemetry.traceOf], [FespalierTelemetry.linkTrace]).
final class TelemetryTrace {
  /// The trace [traceId] (32 lowercase hex digits) and its span [spanId] (16).
  const TelemetryTrace(this.traceId, this.spanId);

  /// The trace id, 32 lowercase hex digits.
  final String traceId;

  /// The span id, 16 lowercase hex digits.
  final String spanId;

  @override
  bool operator ==(Object other) =>
      other is TelemetryTrace &&
      other.traceId == traceId &&
      other.spanId == spanId;

  @override
  int get hashCode => Object.hash(traceId, spanId);

  @override
  String toString() => '$traceId-$spanId';
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

  /// `fespalier_auth` (since 0.9.0) restored, signed in, refreshed or signed out a session.
  auth,

  /// An image loaded from the network (`package:fespalier_image`, since 0.9.0).
  image,

  /// A package's own operation (since 0.11.0): [TelemetryStart.name] says which.
  custom,
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
    this.authStep,
    this.authBackend,
    this.authTrigger,
    this.authDpop = false,
    this.source,
    this.imageCdn,
    this.imageWidth,
    this.imagePreload = false,
    this.name,
    this.attributes,
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

  /// auth (since 0.9.0): which step, `restore`, `sign_in`, `refresh` or `sign_out`.
  final String? authStep;

  /// auth: the backend's short constant name (`oidc`, `firebase`), never a URL or an id.
  final String? authBackend;

  /// auth, on a refresh: what asked for it, `expired`, `unauthorized` or `forced`.
  final String? authTrigger;

  /// auth: whether the backend binds its tokens with DPoP.
  final bool authDpop;

  /// navigate: where the navigation came from when the app's own code did not start it, a
  /// [NavigationSource] value (since 0.9.0); null otherwise.
  final String? source;

  /// image (since 0.9.0): the URL builder's `name` (`emgr`, `imgproxy`, `cloudinary`, ...), never
  /// the URL.
  final String? imageCdn;

  /// image: the width asked for, in physical pixels (a bucket).
  final int? imageWidth;

  /// image: a precache started the load, not a widget.
  final bool imagePreload;

  /// custom (since 0.11.0): the operation's name, `fespalier.<pkg>.<op>` (for example
  /// `fespalier.push.open`).
  final String? name;

  /// custom (since 0.11.0): the operation's own attributes. Values are `String`, `int`, `double`
  /// or `bool`; every key starts with `fespalier.<pkg>.` (the first two segments of [name]).
  final Map<String, Object>? attributes;

  /// This start with [parent] as its parent, every other field copied. A field added to this
  /// class must be added here too: `telemetry_combine_test.dart` ("combine copies every field of
  /// a start") sets every field and fails when one is lost.
  TelemetryStart _withParent(Object? parent) => TelemetryStart(
    op,
    site: site,
    file: file,
    route: route,
    uri: uri,
    parent: parent,
    keyed: keyed,
    authStep: authStep,
    authBackend: authBackend,
    authTrigger: authTrigger,
    authDpop: authDpop,
    source: source,
    imageCdn: imageCdn,
    imageWidth: imageWidth,
    imagePreload: imagePreload,
    name: name,
    attributes: attributes,
  );
}

/// Where a navigation came from when the app's own code did not start it (since 0.9.0): the
/// values of [TelemetryStart.source] and of `fespalier.navigation.source`. Telemetry conventions,
/// contract version 1.
abstract final class NavigationSource {
  /// A tap on a push or local notification.
  static const String notification = 'notification';

  /// A home-screen shortcut (`quick_actions`).
  static const String shortcut = 'shortcut';

  /// A home-screen widget (`home_widget`).
  static const String widget = 'widget';

  /// An app link, universal link or custom-scheme link that a bridge handed over (`app_links`).
  static const String link = 'link';

  /// Every value, in this order.
  static const List<String> values = [notification, shortcut, widget, link];
}

final RegExp _customName = RegExp(
  r'^fespalier\.[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$',
);

/// Package segments a custom operation may not use: they are the namespaces of fespalier's own
/// attributes (`fespalier.custom.name`, `fespalier.image.cdn`, `fespalier.operation`, ...).
const Set<String> _reservedPackages = {
  'custom',
  'operation',
  'route',
  'file',
  'action',
  'data',
  'guard',
  'redirect',
  'navigate',
  'navigation',
  'page',
  'deferred',
  'auth',
  'image',
  'async',
  'keyed',
  'error',
};

/// Debug check of the result attributes of a custom operation (since 0.11.0): each key is
/// `fespalier.<pkg>.<name>` and each value a `String`, `int`, `double` or `bool`. The prefix is the
/// start's; a sink drops a key outside it. Always true, so it can sit in an `assert`.
bool _checkCustomEnd(TelemetryEnd end) {
  for (final MapEntry(:key, :value) in (end.attributes ?? const {}).entries) {
    if (!RegExp(r'^fespalier\.[a-z][a-z0-9_]*\.').hasMatch(key)) {
      throw AssertionError(
        'TelemetryEnd attribute "$key" must start with fespalier.<pkg>.',
      );
    }
    if (value is! String &&
        value is! int &&
        value is! double &&
        value is! bool) {
      throw AssertionError(
        'TelemetryEnd attribute "$key" must be a String, int, double or bool, '
        'got ${value.runtimeType}',
      );
    }
  }
  return true;
}

/// Debug check of a [TelemetryOp.custom] start (since 0.11.0): the name's shape, the keys' prefix
/// and the value types. Always true, so it can sit in an `assert`.
bool _checkCustom(TelemetryStart start) {
  if (start.op != TelemetryOp.custom) return true;
  final name = start.name;
  if (name == null || !_customName.hasMatch(name)) {
    throw AssertionError(
      'TelemetryOp.custom needs a name like fespalier.<pkg>.<op>, got $name',
    );
  }
  final pkg = name.split('.')[1];
  if (_reservedPackages.contains(pkg)) {
    throw AssertionError(
      'TelemetryOp.custom name "$name": "$pkg" is one of fespalier\'s own attribute '
      'namespaces, pick another package segment',
    );
  }
  final prefix = 'fespalier.$pkg.';
  for (final MapEntry(:key, :value) in (start.attributes ?? const {}).entries) {
    if (!key.startsWith(prefix)) {
      throw AssertionError(
        'TelemetryOp.custom attribute "$key" must start with "$prefix"',
      );
    }
    if (value is! String &&
        value is! int &&
        value is! double &&
        value is! bool) {
      throw AssertionError(
        'TelemetryOp.custom attribute "$key" must be a String, int, double or bool, '
        'got ${value.runtimeType}',
      );
    }
  }
  return true;
}

/// The source the navigation that starts next is marked with, set by [navigateFrom].
String? _source;

/// Runs [navigate] (a `router.go`, `push` or `replace`, or the call that builds the router whose
/// initial location is the launch) and marks the navigation it starts as coming from [source], one
/// of [NavigationSource]'s values (since 0.9.0). Telemetry reports it as
/// `fespalier.navigation.source`; nothing else changes (guards run as for any link). [navigate]
/// runs once, synchronously, and what it returns is returned. The mark is taken by the first
/// navigation [navigate] starts and dropped when it returns, so it cannot reach a later one.
///
/// ```dart
/// // A tap on a notification, with the app running:
/// navigateFrom(NavigationSource.notification, () => router.go('/orders/42'));
/// // A cold start from a notification: the router's initial location is the launch.
/// final router = navigateFrom(
///   NavigationSource.notification,
///   () => AppRoutes.router(initialLocation: '/orders/42'),
/// );
/// ```
///
/// fespalier calls it by itself only for a platform link (since 0.11.0, `launchRouter` with
/// `links: true`: `link`, never on the web). The browser's back button looks the same to it as
/// any other navigation, and the bridge that knows (a notification handler) calls it.
T navigateFrom<T>(String source, T Function() navigate) {
  assert(
    NavigationSource.values.contains(source),
    'navigateFrom: `$source` is not a NavigationSource value (notification, '
    'shortcut, widget or link)',
  );
  final outer = _source;
  _source = source;
  try {
    return navigate();
  } finally {
    _source = outer;
  }
}

/// The source [navigateFrom] set, if a navigation did not take it yet; taking it clears it, so only
/// the first navigation of the closure is marked.
String? takeNavigationSource() {
  final source = _source;
  _source = null;
  return source;
}

/// The values of [TelemetryEnd.outcome]. They are the contract values of the telemetry
/// conventions (docs/telemetry-conventions.md, "Telemetry conventions").
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

  /// auth, restore: nothing was stored (since 0.9.0).
  static const String none = 'none';

  /// auth, restore: the stored refresh token had expired, or the device key it was bound to is
  /// gone (since 0.9.0).
  static const String expired = 'expired';

  /// auth: the server refused (wrong credentials, or a refresh token it no longer accepts); an
  /// expected outcome, not an error (since 0.9.0).
  static const String rejected = 'rejected';

  /// auth, sign-in: the user closed the sign-in; an expected outcome (since 0.9.0).
  static const String cancelled = 'cancelled';
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
    this.imageStatus,
    this.attributes,
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

  /// image (since 0.9.0): the HTTP status of a failed load, when the error carries one.
  final int? imageStatus;

  /// custom (since 0.11.0): the operation's own result attributes. Values are `String`, `int`,
  /// `double` or `bool`; each key starts with the prefix of the start's [TelemetryStart.name]
  /// (`fespalier.<pkg>.`). `begin`'s sibling [FespalierTelemetry.finish] asserts the shape in
  /// debug, and a sink drops a key outside the start's prefix.
  final Map<String, Object>? attributes;
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

/// Whether [router] reports its navigations and page events to the installed
/// [FespalierTelemetry] sink (since 0.12.0): true once `telemetryAttach` ran for it, which the
/// generated `AppRoutes.attach` does only in an app generated with `telemetry: true`. An adapter
/// whose sink needs page events calls it from `attach` and reports the missing `telemetry: true`
/// once. It makes no watch, starts no timer and reads no provider.
bool telemetryFollows(GoRouter router) =>
    RouterWatch.peek(router)?.followsTelemetry ?? false;

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

/// Runs [body] within the operation [token] came from (since 0.9.0): the installed sink's
/// [FespalierTelemetry.within] runs it, and what it returns (the very object) or throws comes
/// back. With no sink, or a null [token] (nothing was started), it is `body()`.
///
/// This is what `traceDataCall` and an action's `call` use; adapter packages reach it as
/// [FespalierTelemetry.run].
T telemetryWithin<T>(Object? token, T Function() body) {
  final sink = FespalierTelemetry._current;
  if (sink == null || token == null) return body();
  return _through(sink, token, body, _report);
}

/// Calls `sink.within(token, once)`, where `once` is [body] made safe to hand a sink:
///
/// - it runs [body] at most once, however often the sink calls it (a second call returns the
///   same result), and when the sink never calls it, [body] runs after `within` returned;
/// - it hands the sink what [body] returned, and null when it threw: the exception is kept and
///   rethrown, with its stack trace, after `within` returned, outside the sink;
/// - it refuses an error zone of the sink's own: if `once` finds itself in a zone that is not in
///   the caller's error zone (`runZonedGuarded`, `onError:`), [body] runs in the caller's zone
///   instead and the mistake is printed once;
/// - a sink whose `within` throws is reported through [failed], and the operation goes on.
///
/// What comes back is [body]'s own result, never the sink's.
T _through<T>(
  FespalierTelemetry sink,
  Object? token,
  T Function() body,
  void Function(Object error) failed,
) {
  final caller = Zone.current;
  var ran = false;
  var threw = false;
  Object? result;
  Object? error;
  StackTrace? stackTrace;
  Object? once() {
    if (ran) return result;
    ran = true;
    try {
      if (Zone.current.inSameErrorZone(caller)) {
        result = body();
      } else {
        _report(
          '${sink.runtimeType}.within changed the error zone, so data() and '
          'actions run outside it (use runZoned with zoneValues, not '
          'runZonedGuarded)',
        );
        result = caller.run(body);
      }
    } catch (e, s) {
      threw = true;
      error = e;
      stackTrace = s;
    }
    return result;
  }

  try {
    sink.within(token, once);
  } catch (e) {
    failed(e);
  }
  once();
  if (threw) Error.throwWithStackTrace(error!, stackTrace!);
  return result as T;
}

/// Reports an error of the watch's telemetry side: printed once, then dropped.
void telemetryAttachError(Object error) => _report(error);

/// Whether a sink is installed.
bool get telemetryOn => FespalierTelemetry._current != null;

/// A navigation starts: [uri] is the requested location, or null when it starts at its commit,
/// and [source] says where it came from when the app's own code did not start it (since 0.9.0,
/// what [takeNavigationSource] returned). Returns its token, which is also what runs during it is
/// parented to until [telemetryNavigationEnd].
Object? telemetryNavigationStart(Uri? uri, {String? source}) {
  final token = telemetryBegin(
    TelemetryStart(TelemetryOp.navigate, uri: uri, source: source),
  );
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

/// What `traceData` does with a [telemetry] site: [result] is what `data()` returned. The span
/// starts here, after `data()` ran; an app made with `telemetry: true` calls `traceDataCall`
/// (since 0.9.0), which starts it before.
void telemetryDataTrace(
  Ref ref,
  TelemetrySite telemetry,
  bool keyed,
  Object? result,
) {
  if (FespalierTelemetry._current == null) return;
  try {
    telemetryDataEnd(ref, telemetryDataStart(telemetry, keyed), result);
  } catch (e) {
    _report(e);
  }
}

/// A data load starts, before `data()` runs (since 0.9.0): returns its token, null with no sink
/// (or when the sink threw).
Object? telemetryDataStart(TelemetrySite telemetry, bool keyed) {
  if (FespalierTelemetry._current == null) return null;
  return telemetryBegin(
    TelemetryStart(
      TelemetryOp.data,
      site: telemetry,
      keyed: keyed,
      parent: _pendingNavigation,
    ),
  );
}

/// `data()` threw before it returned (since 0.9.0): the span [token] came from ends with an error.
void telemetryDataThrew(Object? token, Object error, StackTrace stackTrace) {
  if (FespalierTelemetry._current == null) return;
  telemetryFinish(
    token,
    TelemetryEnd(TelemetryOutcome.error, error: error, stackTrace: stackTrace),
  );
}

/// `data()` returned [result]: a value ends the span [token] came from at once, a `Future` ends it
/// when it settles (or when [ref] is disposed first), and a `Stream` is not listened to.
void telemetryDataEnd(Ref ref, Object? token, Object? result) {
  if (FespalierTelemetry._current == null) return;
  try {
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

// ---------------------------------------------------------------------------------------------
// `FespalierTelemetry.combine`.

/// The sink of `combine([])`: reports nothing.
final class _NoTelemetry extends FespalierTelemetry {
  const _NoTelemetry();
}

/// A sink of a [_Combined], and whether its error was printed.
final class _Child {
  _Child(this.sink);

  final FespalierTelemetry sink;
  bool _printed = false;

  /// Prints [error] once for this sink, the way the others are not told.
  void failed(Object error) {
    if (_printed) return;
    _printed = true;
    debugPrint(
      'fespalier telemetry: $error in ${sink.runtimeType} (not shown again)',
    );
  }
}

/// The token of an operation a [_Combined] started: what each child returned, by position.
final class _Tokens {
  const _Tokens(this.of);

  final List<Object?> of;
}

/// The token child [i] of a [_Combined] returned for the operation [token] stands for; null when
/// it returned none, or when [token] is not one of ours.
Object? _own(Object? token, int i) =>
    token is _Tokens && i < token.of.length ? token.of[i] : null;

/// Tells each child everything, in order, as the one installed sink. Each child gets its own
/// token (never another sink's) and the parent token it gave itself, and every call into a child
/// is inside its own `try`.
final class _Combined extends FespalierTelemetry {
  _Combined(this._children);

  final List<_Child> _children;

  @override
  Object? start(TelemetryStart start) {
    final parent = start.parent;
    List<Object?>? tokens;
    for (var i = 0; i < _children.length; i++) {
      final child = _children[i];
      try {
        final token = child.sink.start(
          parent == null ? start : start._withParent(_own(parent, i)),
        );
        if (token != null) {
          (tokens ??= List<Object?>.filled(_children.length, null))[i] = token;
        }
      } catch (e) {
        child.failed(e);
      }
    }
    if (tokens == null) return null;
    _linkTraces(tokens);
    return _Tokens(tokens);
  }

  /// Tells every sink the trace the others put an operation in: [FespalierTelemetry.traceOf] of
  /// the sink that has one, [FespalierTelemetry.linkTrace] of each of the others. The first
  /// answer is the one every other sink gets.
  void _linkTraces(List<Object?> tokens) {
    TelemetryTrace? trace;
    var from = -1;
    for (var i = 0; i < _children.length && trace == null; i++) {
      final token = tokens[i];
      if (token == null) continue;
      final child = _children[i];
      try {
        trace = child.sink.traceOf(token);
        from = i;
      } catch (e) {
        child.failed(e);
      }
    }
    if (trace == null) return;
    for (var i = 0; i < _children.length; i++) {
      final token = tokens[i];
      if (i == from || token == null) continue;
      final child = _children[i];
      try {
        child.sink.linkTrace(token, trace);
      } catch (e) {
        child.failed(e);
      }
    }
  }

  @override
  void end(Object? token, TelemetryEnd end) {
    for (var i = 0; i < _children.length; i++) {
      final child = _children[i];
      try {
        child.sink.end(_own(token, i), end);
      } catch (e) {
        child.failed(e);
      }
    }
  }

  @override
  void page(Object? navigation, TelemetryPage page) {
    for (var i = 0; i < _children.length; i++) {
      final child = _children[i];
      try {
        child.sink.page(_own(navigation, i), page);
      } catch (e) {
        child.failed(e);
      }
    }
  }

  /// The first child is outermost: its `within` runs the second's, which runs the third's, and
  /// the innermost runs [body]. Each child sees what [body] returned. A child that has no token
  /// for the operation is stepped over, and so is one that throws or never calls through;
  /// [body] runs exactly once.
  @override
  void within(Object? token, Object? Function() body) => _nest(0, token, body);

  Object? _nest(int from, Object? token, Object? Function() body) {
    var i = from;
    while (i < _children.length && _own(token, i) == null) {
      i++;
    }
    if (i == _children.length) return body();
    final child = _children[i];
    return _through<Object?>(
      child.sink,
      _own(token, i),
      () => _nest(i + 1, token, body),
      child.failed,
    );
  }
}
