/// The telemetry conventions, contract version 1 (since 0.8.1): every span name, event name,
/// attribute key and enum-like value `FespalierOtel` emits. The "Telemetry conventions" section of
/// docs/telemetry-conventions.md is the published copy; `test/conventions_test.dart` holds each of these as
/// a string literal, so a rename fails a test before it ships.
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

  /// fespalier_auth restored, signed in, refreshed or signed out a session (since 0.9.0).
  static const String opAuth = 'auth';

  /// An image loaded from the network (`package:fespalier_image`, since 0.9.0).
  static const String opImage = 'image';

  /// A package's own operation (since 0.11.0): `fespalier.custom.name` says which.
  static const String opCustom = 'custom';

  /// One HTTP request sent through `OtelTransport` (since 0.21.0): a `CLIENT` span named by the
  /// method (`GET`), as OpenTelemetry's HTTP semantic conventions name it.
  static const String opHttp = 'http';

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

  /// The exception's class (semconv `error.type`), on an outcome `error`; on an `http` span the
  /// status code (`503`) of an error answer or the `TransportFailure` class of no answer.
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

  /// Where the navigation came from when the app's own code did not start it (since 0.9.0).
  static const String navigationSource = 'fespalier.navigation.source';

  /// The committed path (semconv `url.path`); only with `recordLocations`. On an `http` span it is
  /// the request's path, always (never its query).
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

  // The values of `fespalier.navigation.source` (since 0.9.0).

  /// A tap on a notification.
  static const String sourceNotification = 'notification';

  /// A home-screen shortcut.
  static const String sourceShortcut = 'shortcut';

  /// A home-screen widget.
  static const String sourceWidget = 'widget';

  /// A link a bridge handed over.
  static const String sourceLink = 'link';

  // The values of `fespalier.navigation.outcome`.

  /// A page is on screen.
  static const String outcomeOk = 'ok';

  /// The location matched no route. Not an error.
  static const String outcomeNotFound = 'not_found';

  /// A newer navigation started before this one committed.
  static const String outcomeSuperseded = 'superseded';

  /// A guard or a `redirect.dart` failed, and the router shows the error view (since 0.21.0). The
  /// span has the status `Error` and no exception: the guard's span has it.
  static const String outcomeError = 'error';

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

  /// Which try the load is: 1, or n + 1 when Riverpod ran the provider again on its own after try n
  /// failed (since 0.18.0). A `Stream` load is always 1.
  static const String dataAttempt = 'fespalier.data.attempt';

  /// Where the content came from, `cache` or `fetch`, for a data.dart with a `dataCache` (since
  /// 0.18.0). Absent for a data.dart without one.
  static const String dataSource = 'fespalier.data.source';

  // The values of `fespalier.data.state`.

  /// The value is there.
  static const String stateData = 'data';

  /// `data()` threw, or its `Future` failed.
  static const String stateError = 'error';

  /// A `Stream` was returned: not listened to, so the span ends at once.
  static const String stateStream = 'stream';

  /// The provider was disposed before its `Future` settled.
  static const String stateDisposed = 'disposed';

  // The values of `fespalier.data.source` (since 0.18.0).

  /// The saved copy of a `dataCache` was on screen before the fetch settled (a retry or a reload
  /// after an offline start counts, while the copy is still shown).
  static const String dataSourceCache = 'cache';

  /// The value came from the fetch: no saved copy was on screen.
  static const String dataSourceFetch = 'fetch';

  // Attributes of an `action` span.

  /// The function's name in `action.dart`.
  static const String actionName = 'fespalier.action.name';

  /// How the run ended. The input and the returned value are never recorded.
  static const String actionResult = 'fespalier.action.result';

  /// An optimistic patch was shown for the run and then undone (`true`), or kept (`false`). Absent
  /// when no patch was shown (since 0.18.0).
  static const String actionRolledBack = 'fespalier.action.rolled_back';

  /// The run ended with `FieldErrors`: `validate()` refused its input, or the action named wrong
  /// fields. Recorded on an error only (since 0.18.0).
  static const String actionInvalid = 'fespalier.action.invalid';

  /// How many items a streaming action's stream gave in the run, whatever its outcome
  /// (`fespalier.action.result` is `cancelled` when the run was stopped). Absent for an action
  /// that returns a `Future` or a value (since 0.25.0). Never the items themselves.
  static const String actionItems = 'fespalier.action.items';

  // Attributes of a `deferred` span.

  /// How the load ended.
  static const String deferredResult = 'fespalier.deferred.result';

  // The values of `fespalier.action.result`, `fespalier.deferred.result`,
  // `fespalier.image.result` and `fespalier.custom.result`.

  /// It worked.
  static const String resultOk = 'ok';

  /// It failed.
  static const String resultError = 'error';

  /// A value of `fespalier.action.result` only (since 0.25.0): a streaming action's run was stopped
  /// before its stream ended (`cancel()`, a newer run, or its page went away). It is not a failure:
  /// the span's status is `ok`.
  static const String actionResultCancelled = 'cancelled';

  // Attributes of an `auth` span (since 0.9.0). Never recorded: tokens, user ids, claims, user
  // names, e-mails, issuer and endpoint URLs, DPoP proofs and thumbprints.

  /// Which step: restore, sign in, renew (`refresh` until 0.20.0) or sign out.
  static const String authOperation = 'fespalier.auth.operation';

  /// How the step ended.
  static const String authResult = 'fespalier.auth.result';

  /// The backend's short constant name (`oidc`, `firebase`, `fake`, an app's own).
  static const String authBackend = 'fespalier.auth.backend';

  /// What asked for a renewal (renew only).
  static const String authTrigger = 'fespalier.auth.trigger';

  /// How the backend authenticates requests, a short constant of its own (`bearer`, `dpop`,
  /// `device`), since 0.21.0 in place of `fespalier.auth.dpop`.
  static const String authScheme = 'fespalier.auth.scheme';

  // The values of `fespalier.auth.operation`.

  /// The stored session was read at start-up.
  static const String authOpRestore = 'restore';

  /// A sign-in, or a session the app adopted.
  static const String authOpSignIn = 'sign_in';

  /// The session's credential was renewed (since 0.21.0; `refresh` until 0.20.0).
  static const String authOpRenew = 'renew';

  /// The user signed out.
  static const String authOpSignOut = 'sign_out';

  // The values of `fespalier.auth.result`.

  /// It worked.
  static const String authResultOk = 'ok';

  /// Restore: nothing was stored.
  static const String authResultNone = 'none';

  /// Restore: the stored credential could not be renewed any more, or the device key is gone.
  static const String authResultExpired = 'expired';

  /// The server refused: invalid credentials, or a session it no longer renews.
  static const String authResultRejected = 'rejected';

  /// The user closed the sign-in.
  static const String authResultCancelled = 'cancelled';

  /// It could not run; a renewal keeps the session.
  static const String authResultError = 'error';

  // The values of `fespalier.auth.trigger` (renew only).

  /// The access token had expired before a request.
  static const String authTriggerExpired = 'expired';

  /// A server answered 401 to the access token.
  static const String authTriggerUnauthorized = 'unauthorized';

  /// The app asked for a renewal.
  static const String authTriggerForced = 'forced';

  // Attributes of an `image` span (since 0.9.0). Never recorded: the image's URL, its source, a
  // signature, the error's text.

  /// The URL builder: `imgproxy`, `emgr`, `cloudinary`, `imgix`, `thumbor`, `template`, `srcset`,
  /// `direct`.
  static const String imageCdn = 'fespalier.image.cdn';

  /// The width asked for, in physical pixels (a bucket).
  static const String imageWidth = 'fespalier.image.width';

  /// Whether a precache started the load.
  static const String imagePreload = 'fespalier.image.preload';

  /// How the load ended: `ok` or `error`.
  static const String imageResult = 'fespalier.image.result';

  /// The HTTP status of a failed load, when known.
  static const String imageStatus = 'fespalier.image.status';

  // Attributes of a `custom` span (since 0.11.0). A package's own `fespalier.<pkg>.*` attributes
  // on it are that package's contract, not contract version 1's.

  /// The operation's name, `fespalier.<pkg>.<op>` (`fespalier.push.open`).
  static const String customName = 'fespalier.custom.name';

  /// How the operation ended: the `TelemetryOutcome` the package finished with, usually `ok` or
  /// `error` (`cancelled`, `disposed`, `rejected` and `skipped` are possible).
  static const String customResult = 'fespalier.custom.result';

  // Attributes of an `http` span (since 0.21.0), OpenTelemetry's HTTP client semantic conventions
  // (plus `fespalier.operation`, `url.path` and `error.type` above). Never recorded: a query, a
  // fragment, a header value, a body, a credential.

  /// The request method, upper case: `GET`.
  static const String httpMethod = 'http.request.method';

  /// The host the request went to.
  static const String serverAddress = 'server.address';

  /// The port the request went to (the scheme's default when the URL names none).
  static const String serverPort = 'server.port';

  /// `https` or `http`.
  static const String urlScheme = 'url.scheme';

  /// The response's status code, when one came back.
  static const String httpStatusCode = 'http.response.status_code';

  /// How many times the request had been sent before this send, on a re-send (an auth replay, a
  /// retry): absent on the first send.
  static const String httpResendCount = 'http.request.resend_count';

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
