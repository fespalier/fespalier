/// The telemetry conventions, contract version 1 (since 0.8.1): every span name, event name,
/// attribute key and enum-like value `FespalierOtel` emits. The README's "Telemetry conventions"
/// section is the published copy; `test/conventions_test.dart` holds each of these as a string
/// literal, so a rename fails a test before it ships.
///
/// Within version 1 a change may only add: a new attribute key, a new event or a new value of an
/// enum-like attribute. Renaming or removing one, or changing the meaning or unit of an
/// attribute, is version 2: it bumps [FespalierConventions.version].
library;

/// The names and values of the telemetry conventions, contract version 1. One declaration per
/// line, so a tool can read them.
abstract final class FespalierConventions {
  /// The contract version, `fespalier.telemetry.version` on the resource.
  static const String version = '1';

  /// The instrumentation scope every span is made in.
  static const String scope = 'fespalier';

  // The resource attributes fespalier adds (the app's `service.*` come from otel_zone).

  /// The fespalier release, e.g. `0.8.1`.
  static const String resourceVersion = 'fespalier.version';

  /// The contract version, as a string.
  static const String resourceTelemetryVersion = 'fespalier.telemetry.version';

  // The values of `fespalier.operation`, which is also the first word of a span's name.

  /// A location was requested, or a configuration committed.
  static const String opNavigate = 'navigate';

  /// A `guard.dart` ran.
  static const String opGuard = 'guard';

  /// A `redirect.dart` ran.
  static const String opRedirect = 'redirect';

  /// A `data.dart` ran.
  static const String opData = 'data';

  /// A function of an `action.dart` ran.
  static const String opAction = 'action';

  /// The code of a deferred page loaded.
  static const String opDeferred = 'deferred';

  // Span names: the operation, then what it is about.

  /// A navigation that matched no route is named `navigate (not found)`.
  static const String spanNavigateNotFound = 'navigate (not found)';

  // Attributes on every span.

  /// Which kind of operation the span is.
  static const String operation = 'fespalier.operation';

  /// The route pattern: `/`, `/products/:id`, `/docs/*rest`.
  static const String route = 'fespalier.route';

  /// The app file, relative to the app folder: `products/$id/data.dart`.
  static const String file = 'fespalier.file';

  /// Whether the operation returned a `Future`.
  static const String isAsync = 'fespalier.async';

  /// The exception's class (semconv `error.type`), on an outcome `error`.
  static const String errorType = 'error.type';

  // Attributes of a `navigate` span.

  /// How the navigation happened.
  static const String navigationKind = 'fespalier.navigation.kind';

  /// How it ended.
  static const String navigationOutcome = 'fespalier.navigation.outcome';

  /// The pattern of the page that was on top before.
  static const String navigationFrom = 'fespalier.navigation.from';

  /// Whether a guard or a `redirect.dart` sent it elsewhere.
  static const String navigationRedirected = 'fespalier.navigation.redirected';

  /// How many pushed pages the stack holds after the commit.
  static const String navigationDepth = 'fespalier.navigation.depth';

  /// The committed path (semconv `url.path`); only with `recordLocations`.
  static const String urlPath = 'url.path';

  /// The committed query (semconv `url.query`); only with `recordLocations`.
  static const String urlQuery = 'url.query';

  // The values of `fespalier.navigation.kind`.

  /// The first location the router committed.
  static const String kindInitial = 'initial';

  /// `go`, a link, the address bar, a tab switch or a redirect.
  static const String kindGo = 'go';

  /// A page was pushed.
  static const String kindPush = 'push';

  /// A pushed page was popped.
  static const String kindPop = 'pop';

  /// The page on top of the pushed ones was replaced.
  static const String kindReplace = 'replace';

  /// The same location again.
  static const String kindRefresh = 'refresh';

  // The values of `fespalier.navigation.outcome`.

  /// A page is on screen.
  static const String outcomeOk = 'ok';

  /// The location matched no route. Not an error.
  static const String outcomeNotFound = 'not_found';

  /// A newer navigation started before this one committed.
  static const String outcomeSuperseded = 'superseded';

  // Attributes of a `guard` and a `redirect` span.

  /// What the guard decided.
  static const String guardDecision = 'fespalier.guard.decision';

  /// Where it redirected to; only with `recordLocations`.
  static const String guardLocation = 'fespalier.guard.location';

  // The values of `fespalier.guard.decision`.

  /// The guard returned null.
  static const String decisionPass = 'pass';

  /// The guard returned a location.
  static const String decisionRedirect = 'redirect';

  /// The guard threw, or its `Future` failed.
  static const String decisionError = 'error';

  /// A segment it asks for did not parse, so it did not run.
  static const String decisionSkipped = 'skipped';

  // Attributes of a `data` span.

  /// How the load ended.
  static const String dataState = 'fespalier.data.state';

  /// Whether the provider is a family. The key itself is never recorded.
  static const String dataKeyed = 'fespalier.data.keyed';

  // The values of `fespalier.data.state`.

  /// The value is there.
  static const String stateData = 'data';

  /// `data()` threw, or its `Future` failed.
  static const String stateError = 'error';

  /// A `Stream` was returned: not listened to, so the span ends at once.
  static const String stateStream = 'stream';

  /// The provider was disposed before its `Future` settled.
  static const String stateDisposed = 'disposed';

  // Attributes of an `action` span.

  /// The function's name in `action.dart`.
  static const String actionName = 'fespalier.action.name';

  /// How the run ended. The input and the returned value are never recorded.
  static const String actionResult = 'fespalier.action.result';

  // Attributes of a `deferred` span.

  /// How the load ended.
  static const String deferredResult = 'fespalier.deferred.result';

  // The values of `fespalier.action.result` and `fespalier.deferred.result`.

  /// It worked.
  static const String resultOk = 'ok';

  /// It failed.
  static const String resultError = 'error';

  // Events on the `navigate` span.

  /// A page became the visible one for the first time.
  static const String eventEnter = 'fespalier.page.enter';

  /// An entered page is the visible one again.
  static const String eventFocus = 'fespalier.page.focus';

  /// An entered page is gone.
  static const String eventLeave = 'fespalier.page.leave';

  /// Milliseconds from a page's enter to its leave, on [eventLeave].
  static const String pageDuration = 'fespalier.page.duration_ms';
}
