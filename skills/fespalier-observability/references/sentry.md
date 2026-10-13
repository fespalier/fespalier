# Sentry: `fespalier_sentry`

Since 0.9.0. The docs' [Sentry](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#sentry-fespalier_sentry) section is the
user documentation; this page is what an agent needs to set it up, to say what Sentry will show, and to say why
something is missing. The package is **errors first**: by default it sends errors, crashes and breadcrumbs, and
no transaction. Performance (`tracing: true`) is the opt-in, for a team that has only Sentry.

## What you get by default

- **Every error and crash, tagged where it happened.** A guard, `data.dart`, action or deferred load that throws
  is a Sentry event (handled, mechanism `fespalier.{operation}`) with the tags `fespalier.operation`,
  `fespalier.route` (the pattern, `/products/:id`), `fespalier.file` (`products/$id/data.dart`) and, for an
  action, `fespalier.action`; the fingerprint is `['{{ default }}', file]` (grouped by the file, not by the
  Riverpod frames on top of the stack); the context `fespalier` repeats them, with `fespalier.async` and, for
  data, `fespalier.data.keyed`.
- **The screen names the scope.** At each committed navigation the scope's transaction name is the route
  pattern (`navigate (not found)` for a location that matched no route) and the tag `fespalier.route` is set,
  so a crash that no fespalier operation reported, caught by Sentry's own integrations, says which screen it
  happened on. A transaction that is Sentry's own (its app start, its navigator observer) is never renamed:
  the tag is still set.
- **One breadcrumb per page change**: type `navigation`, `from` and `to` patterns. A page being left makes
  none, so a go is one. A guard redirect, an action's result (never its input), an auth step and an image
  failure are breadcrumbs too.
- **Release health**: the SDK's sessions. `configure` sets `enableAutoSessionTracking` to true. On the web the
  SDK starts sessions only with a `SentryNavigatorObserver`: add `FespalierSentry.navigatorObserver()` to
  `routerObservers` there (it makes no transaction).
- **A link to the OpenTelemetry trace** when `fespalier_otel` is in the same `combine`: each event carries the
  tags `otel.trace_id` and `otel.span_id` and the context `otel`. For an error from an operation they are the
  span that operation made; for a crash they are the navigation that opened the screen (on the scope, from
  each commit; a navigation with no trace takes them off, so an event never links to the wrong screen). Search
  the trace id in the OpenTelemetry backend. Without `fespalier_otel` there are no `otel.*` tags.

Never sent: segment values, query values, family keys, `extra`, action inputs and results, data values, a
`FieldErrors` (a validation answer: a breadcrumb), an auth error's text. The exception **text** of a captured
error is the app's, and goes as it is: redact in `beforeSend`:

```dart
options.beforeSend = (event, hint) {
  final value = event.exceptions?.firstOrNull?.value;
  if (value != null && value.contains('@')) event.exceptions!.first.value = 'redacted';
  return event;
};
```

`FespalierSentry.configure` chains the callbacks the app set before it (they run first), so set `beforeSend`
**before** calling it.

## Wiring

```yaml
# pubspec.yaml dependencies
  sentry_flutter: ">=9.26.0 <10.0.0"
```

Add `fespalier_sentry` next to fespalier with the **same `url` and `ref`** (path `packages/fespalier_sentry`;
see the package's README for the block), turn on `fespalier: telemetry: true`, run `fsp gen`, then in
`startup.dart`:

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart'; // NavigatorObserver
import 'package:fespalier_sentry/fespalier_sentry.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sentry_flutter/sentry_flutter.dart';

/// Sentry starts first: the binding, startup() and runApp all run in its appRunner.
Future<void> zone(Future<void> Function() body) => SentryFlutter.init(
  (options) => FespalierSentry.configure(
    options,
    dsn: const String.fromEnvironment('SENTRY_DSN'), // empty: Sentry is off
    propagateTraceTo: const ['api.example.com'],
  ),
  appRunner: body,
);

/// Before the router is built, so the first navigation is reported. Sync: the first frame is the app.
void startup() => FespalierTelemetry.add(FespalierSentry()); // add, not install: install replaces a sink an adapter added

/// Release health on the web needs it; it makes no transaction.
List<NavigatorObserver> get routerObservers => [
  if (kIsWeb) FespalierSentry.navigatorObserver(),
];
```

Next to OpenTelemetry, install both in the one slot (the order of the list does not matter), and start the SDK
in `startup()`:

```dart
FespalierTelemetry.install(
  FespalierTelemetry.combine([
    FespalierSentry(),
    FespalierOtel(isReady: () => observability.isReady),
  ]),
);
```

The order rules:

1. **Sentry is the outermost zone.** A zone outside `SentryFlutter.init` on the web makes Sentry skip its own
   `runZonedGuarded`, so uncaught errors go to that zone. Nothing calls
   `WidgetsFlutterBinding.ensureInitialized()` before it.
2. **No `OtelZone.runGuarded` next to Sentry**: its zone sends an uncaught async error to Talker only, and Sentry
   would never see it (it is also blank on the web). Pass Sentry's `body` and start the SDK with
   `observability.start()`.
3. **Install the sink before the router exists**, in `startup()` or `appRunner`; with `fespalier_auth`'s
   `restoreAuth`, install first so the restore is reported.
4. A failure in `startup()` reaches Sentry through `FlutterError.reportError`: no extra code.
5. An empty DSN disables the SDK, and the sink with it: it checks `hub.isEnabled` first and returns null.

## Performance, on request (`tracing: true`)

Both places, so that the SDK samples and the sink makes the transactions:

```dart
FespalierSentry.configure(options, dsn: dsn, tracing: true); // 1.0 in debug, 0.1 in release unless set
FespalierTelemetry.install(FespalierSentry(tracing: true));
```

Each navigation is a `ui.load` transaction named by the pattern (started as `navigate`, renamed at the commit),
with child spans `fespalier.guard`, `.redirect`, `.data`, `.deferred`, `.action`, `.auth` and `.image` (and, since 0.11.0, one described by a package's own `custom` operation, `fespalier.push.open`, without its attributes), the
spans `ui.load.initial_display` and `ui.load.full_display`, and the measurements `time_to_initial_display` and
`time_to_full_display` (what Sentry's Screen Loads view reads). It ends when the screen's last data load
does (TTFD), or when the next navigation starts (the old screen's TTFD is then `deadline_exceeded`, no
measurement): **there is no timer**, and `autoFinishAfter` and `waitForChildren` are never passed. A pop and a
refresh make no transaction. A superseded navigation is dropped by `configure`'s `beforeSendTransaction`.

- **One or the other for transactions.** A plain `SentryNavigatorObserver()` also makes one `ui.load` per push:
  with it and `tracing: true` every screen has two transactions. Use `FespalierSentry.navigatorObserver()`
  (`enableAutoTransactions: false`), or `FespalierSentry(tracing: true, transactions: false)` to let a plain
  observer make them (the sink then adds data spans, TTFD, events and breadcrumbs; no guard, redirect or
  deferred span, which run before the observer's transaction exists).
- **The first screen on Android and iOS** is Sentry's own app start (tracing on, `enableAutoPerformanceTracing`
  on, standalone app start off): the sink opens no transaction for it, still names the scope, and calls
  `SentryFlutter.currentDisplay()?.reportFullyDisplayed()` when its data is in. Its guard and data spans are not
  recorded. `enableStandaloneAppStartTracing: true` (9.26.0, experimental) makes the first screen an ordinary
  one: recommended. Web and desktop: ordinary.
- **An HTTP span made in `data()`** is a child of the screen's transaction (Sentry's integrations parent to the
  scope's span), beside the data span, not under it. Under `fespalier_otel` it is under the data span.
- **`traceLifecycle: stream`** is not supported in this version: the sink prints once (in a debug build)
  `fespalier_sentry: Sentry's traceLifecycle is stream, which this version makes no spans for. Errors and
breadcrumbs are still sent; use SentryTraceLifecycle.static for screen transactions.` and makes no spans.
  Errors and breadcrumbs are unaffected.
- `tracing: true` on an SDK that samples nothing prints once (debug) `fespalier_sentry: tracing: true needs
Sentry to sample transactions, and tracesSampleRate is not set, so no transaction is sent. Pass tracing: true
  to FespalierSentry.configure, or set options.tracesSampleRate.`

## Options

`FespalierSentry({hub, tracing = false, transactions = true, fullDisplay = true, breadcrumbs = true,
routeTag = true, recordLocations = false, capture = FespalierSentry.unexpected, repeatWindow = 30 s})`.
`capture(error, start)` decides which failures are events (the default, `FespalierSentry.unexpected`: all but a `FieldErrors`, an `auth`
step and a package's own `custom` operation, which is a breadcrumb with the class only); a failure of the same operation, file and exception type inside `repeatWindow` (read from
`package:clock`) is a breadcrumb `... again`, since Riverpod retries a failing `data()` up to ten times.
`FespalierSentry.configure(options, {dsn, tracing = false, tracesSampleRate, propagateTraceTo = [],
recordQueries = false, observerBreadcrumbs = false})`: see the defaults table in [`docs/observability.md`](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#sentry-fespalier_sentry). `tracesSampleRate`
throws `Invalid argument (tracesSampleRate): must be between 0 and 1: 1.5` outside 0..1.

## Testing

`package:fespalier_sentry/testing.dart`: `RecordingSentry` is a real `Hub` over `SentryFlutterOptions` with a
recording transport (no `SentryFlutter.init`, no native SDK, no network, no timer).

```dart
final sentry = RecordingSentry(
  configure: (options) => FespalierSentry.configure(options, dsn: 'https://key@sentry.invalid/1'),
);
FespalierTelemetry.install(FespalierSentry(hub: sentry.hub));
// ... navigate, pump ...
await tester.pump(); // the SDK hands an event to its transport a few microtasks later
expect(await sentry.lines(), ['event StateError operation=data route=/items/:id file=items/$id/data.dart']);
```

`lines()` is one line per transaction, span and event, without timestamps or ids; `sent()` is the JSON the SDK
built (tags, fingerprint, contexts, measurements); `breadcrumbs`, `rawBreadcrumbs`, `tags` and
`transactionName` read the scope. Traps:

- **Pump before reading** (`await tester.pump()`), or use a plain `test()` and a real zero delay.
- **A `ProviderContainer` read inside `testWidgets` leaves a Riverpod timer pending**: use `test()` for a
  container-only test.
- **The first screen on Android and iOS** is Sentry's app start with `tracing: true`: the test's
  `defaultTargetPlatform` is Android. Navigate after the first screen, or pass the `@visibleForTesting`
  `platform: TargetPlatform.linux` to `FespalierSentry`.
- A plain `SentryNavigatorObserver` with transactions starts a timer (`autoFinishAfter`) that a test cannot leave
  pending: bind a transaction to the scope by hand to stand for it.
- `debugPrint` is a foundation debug variable: put it back before the test body ends, not in `tearDown`.

## Where the code is

`packages/fespalier_sentry/`: `lib/src/fespalier_sentry.dart` (the sink and `configure`), `scrub.dart` (the
query and fragment, the observer's breadcrumbs, superseded transactions), `options.dart` (the one read of
`hub.options`, which is `@internal`, with the experimental `enableStandaloneAppStartTracing`), `tokens.dart`,
`keys.dart`, and `lib/testing.dart`. The link to a trace is core's `FespalierTelemetry.traceOf` and `linkTrace`
(`packages/fespalier/lib/src/telemetry.dart`), which `FespalierOtel` answers. The example is
`examples/telemetry` (`test/sentry_test.dart`).
