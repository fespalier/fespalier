# Telemetry and OpenTelemetry

Since 0.8.1. The docs' [Telemetry](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#telemetry) section is the user
documentation; this page is what an agent needs to set it up and to say why nothing shows.

Under `fsp dev` (since 0.9.0) the key `t` starts `fsp telemetry` in a pane of its own, and `before: fsp telemetry`
in `tasks: dev:` starts it with the app: it starts its stack and returns, so it goes in `before`, not `with`.

## The pieces

- **`fespalier: telemetry: true`** in `pubspec.yaml` (a bool; anything else is an error, see
  [troubleshooting](../../fespalier-troubleshooting/references/diagnostics-observability.md)). `fsp gen`
  then passes a `const TelemetrySite('products/$id/data.dart', route: '/products/:id')` to each guard,
  `data.dart` provider and action, gives each `DeferredLibrary` its page's pattern, and writes
  `telemetryAttach(router, base: () => _base)` into `AppRoutes.attach` (which `AppRoutes.router()`
  calls; an app that mounts the tree in a `GoRouter` of its own calls `AppRoutes.attach(router)` once).
  Off, the file is byte for byte what it was.
- **`FespalierTelemetry`**: the sink, in `package:fespalier`. `FespalierTelemetry.install(sink)` (null
  uninstalls) before `runApp` and before the router is built. A sink is called synchronously and must
  return at once and not throw; what it throws is caught and printed once
  (`fespalier telemetry: <error> (not shown again)`). There is **one slot**: a second `install`
  replaces the first (several sinks: see below, since 0.9.0).
- **`RecordingTelemetry`** (`package:fespalier/testing.dart`): a sink that keeps lines for a test.
- **`package:fespalier_otel`**: `FespalierOtel`, the sink that makes spans on the dartastic SDK, and
  `FespalierConventions`, the names ([conventions](conventions.md)). It does not depend on `otel_zone`,
  so it works with an app that starts the SDK itself (leave `isReady` out).

## Install with otel_zone

`otel_zone` is a Flutter plugin that is **not on pub.dev**: a git dependency, pinned to a **commit**
(`ref: <sha>`). `fespalier_otel` is a git dependency too:

```yaml
dependencies:
  fespalier:
    git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier, ref: v0.13.0 }
  fespalier_otel:
    git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier_otel, ref: v0.13.0 }
```

Use the **same `url` spelling (no `.git`) and the same `ref`** (the tag your app pins; `v0.13.0` here) for both, or pub fails with `Because ...
depends on fespalier from git ... is forbidden`. `otel_zone` pulls `otel_go_router`, which declares
`go_router: ^17.0.0`: the app resolves go_router 17.5.0 (fespalier accepts 17 and 18), and an app that
needs 18 adds `dependency_overrides: go_router: ^18.0.0`.

## Wire it

```dart
final observability = OtelZone(
  OtelZoneConfig(serviceName: 'shop', endpoint: FespalierOtel.endpoint()),
);

Future<void> main() => guarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await observability.start(
    serviceVersion: '1.4.0',
    resourceAttributes: {...FespalierOtel.resourceAttributes},
  );
  FespalierTelemetry.install(FespalierOtel(isReady: () => observability.isReady));
  runApp(/* ProviderScope(observers: [?observability.riverpodObserver()], child: ... */);
});

Future<void> guarded(Future<void> Function() body) =>
    kIsWeb ? body() : observability.runGuarded(body);
```

- `WidgetsFlutterBinding.ensureInitialized()` **and** `runApp` run inside the zone `runGuarded` opens
  (Flutter warns when `runApp` comes from another zone). Nothing Flutter-related may happen before it.
- `resourceAttributes` adds `fespalier.version` and `fespalier.telemetry.version` to the resource. The
  resource is fixed when the SDK starts, so they go into `start()`.
- `FespalierOtel(recordLocations: true)` adds `url.path`, `url.query` and `fespalier.guard.location`.
  It is off because segment and query values are app data.
- A failure while the app starts arrives through `FlutterError.reportError`.

### `FespalierOtel.endpoint()`

The OTLP/HTTP endpoint: the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when set. Otherwise, in
debug and profile, `http://10.0.2.2:4318` on Android (the emulator's address for its host) and
`http://localhost:4318` on every other platform and on the web; in release, `''`, which `otel_zone` takes
as "telemetry off" (a store build never sends to a developer's computer). A physical phone needs the
define.

### Known limitation: `otel_zone` `runGuarded` on web

Since 0.8.1: on the web `OtelZone.runGuarded` **never runs its body** and the app stays blank (it builds a
`ReceivePort`, which `dart:isolate` does not support there; nothing is printed). `start()` works on the
web, and spans and logs are exported. Run the body as it is on the web (the `guarded` helper above); the
error hooks `runGuarded` installs are then not installed there. `OtelZoneConfig` and everything else is
unchanged.

## Several sinks: `combine` and `add` (since 0.9.0)

`install` holds one sink, so OpenTelemetry, Sentry and an analytics SDK need one sink made of the three:

```dart
FespalierTelemetry.install(
  FespalierTelemetry.combine([
    FespalierOtel(isReady: () => observability.isReady),
    AnalyticsTelemetry(),
  ]),
);
```

`FespalierTelemetry.add(sink)` is `install(combine([?current, sink]))`: use it where two places each install
a sink (a package's setup and the app's `startup()`) so neither replaces the other. `install` still replaces
everything and `install(null)` removes everything.

- **Each sink has its own tokens.** What a sink returned from `start` is what it, and only it, gets back at
  `end`, `page` and `within`, and as the `TelemetryStart.parent` of what runs under one of its
  navigations. One sink's spans therefore cannot become another sink's parents, and `FespalierOtel` behind
  a `combine` still parents its guard, data and deferred spans under its own navigation span.
- **Each sink is isolated.** One that throws costs only its own report: the others and the app go on, and
  its error is printed **once per sink**, `fespalier telemetry: <error> in <Sink> (not shown again)`, and
  it is called again next time. A sink whose `start` returned null is still told the end, with null.
- `combine` flattens a combined sink in the list, `combine([])` reports nothing and `combine([sink])` is
  `sink`. Sinks are called in list order; for `within` the **first is outermost**.
- **Trace links** (since 0.9.0). A sink that makes OpenTelemetry spans overrides `TelemetryTrace? traceOf(Object?
token)` to say which trace an operation is in (`FespalierOtel` does: the trace and span id of its span, 32
  and 16 lowercase hex digits); `combine` asks once per operation, right after every sink started it, and
  tells each **other** sink `linkTrace(token, trace)` with that sink's own token, before its `within` and
  `end`. `fespalier_sentry` keeps it and tags its events with `otel.trace_id` and `otel.span_id`
  ([sentry.md](sentry.md)). The order of the list does not matter; a sink that throws from either is
  isolated like from any call. A sink of your own that has a member named `traceOf` or `linkTrace` with
  another signature must rename it.

## `within`: the data and action span is current (since 0.9.0)

By default a span made while `data()` or an action runs (an HTTP client's) is a root of its own trace.
A sink may override the hook fespalier calls around them:

```dart
/// Runs [body] inside the operation [token] came from. The default calls [body].
void within(Object? token, Object? Function() body) => body();
```

`FespalierOtel` overrides it with `Context.current.withSpan(span).runSync(body)`, so the spans of Dartastic's
`otel_http` and `otel_dio` made inside `data()` or an action, after an `await` too, are children of its
span. The rules for a sink of your own:

- **Call `body` once, synchronously, before you return.** It returns what the operation returned (null if it
  threw) so you may observe it, for example hand a `Future` to a vendor API that ends a span when it
  settles; it never throws (fespalier rethrows after you return). `body` runs once even if you never call
  it, call it twice or throw.
- **fespalier returns the operation's own result, the very object**, whatever you do: a sync `data()` stays
  sync (no `Future`, no microtask) and a `Future` is the one Riverpod awaits. A sink cannot replace it.
- **Zone values only.** `runZoned(body, zoneValues: {...})` is right, and what Dartastic's `Context.runSync`
  is. **Never give the zone an error handler** (`runZonedGuarded`, `onError:`, a `ZoneSpecification` with
  `handleUncaughtError`): a `Future` that fails in another error zone never reaches Riverpod and the page
  stays on its loading view. fespalier refuses such a zone: it runs `body` in the caller's zone and prints
  once `fespalier telemetry: <Sink>.within changed the error zone, so data() and actions run outside it
(use runZoned with zoneValues, not runZonedGuarded) (not shown again)`.
- Behind a `combine`, each sink's `within` runs the next, so every sink's scope wraps `data()` and each
  sees the result. A sink with no token for the operation, or one that throws, is stepped over.
- **Guards and deferred loads do not get `within`** (a guard must stay cheap; a deferred load runs no app
  code). `FespalierTelemetry.run(token, body)` is the same for an adapter package that starts operations
  of its own with `FespalierTelemetry.begin`.

An app made with `telemetry: true` gets `traceDataCall(ref, 'd4', id, () => data(ref, id: id), telemetry: ...)`
in `app.g.dart` instead of `traceData(ref, 'd4', id, data(ref, id: id), telemetry: ...)`: **regenerate with
`fsp gen`**. The data span now starts before `data()` runs (its duration includes the sync part), and a
`data()` that throws before it returns now has a `data` span (`fespalier.data.state = error`,
`fespalier.async = false`). An app without `telemetry: true` is unchanged. A sink that already had a member
called `within` with another signature must rename it.

## `navigateFrom`: where a navigation came from (since 0.9.0)

```dart
// A tap on a notification, with the app running:
navigateFrom(NavigationSource.notification, () => router.go('/orders/42'));
// A cold start from it: the router built inside the closure starts the launch navigation.
final router = navigateFrom(
  NavigationSource.notification,
  () => AppRoutes.router(initialLocation: '/orders/42'),
);
```

`NavigationSource` is `notification`, `shortcut`, `widget` or `link`. The closure runs once, synchronously,
and what it returns is returned. **The first navigation it starts takes the mark; it is dropped when the
closure returns**, so it cannot reach a later one (a closure that starts nothing, or goes where the router
already is, leaves nothing). Telemetry reports it as `TelemetryStart.source` and `FespalierOtel` as
`fespalier.navigation.source` on the `navigate` span; `fespalier.navigation.kind` still says how the stack
changed (a cold start is `initial` with a source). **fespalier calls it by itself only for a platform link** (since 0.11.0, `launchRouter(links: true)`: `link`, cold start and warm, never on the web); the browser's back button looks like any other navigation, and the bridge that knows (a notification handler) calls `navigateFrom`. Another value asserts in debug, ``navigateFrom: `banner` is not a
NavigationSource value (notification, shortcut, widget or link)``.

## `TelemetryOp.custom`: a package's own operation (since 0.11.0)

A package that is not fespalier's own reports an operation with `FespalierTelemetry.begin` and `finish`:

```dart
final token = FespalierTelemetry.begin(
  const TelemetryStart(
    TelemetryOp.custom,
    name: 'fespalier.push.open',
    attributes: {'fespalier.push.kind': 'alert'},
  ),
);
FespalierTelemetry.finish(
  token,
  const TelemetryEnd(TelemetryOutcome.ok, attributes: {'fespalier.push.fresh': true}),
);
```

`name` is `fespalier.<pkg>.<op>`, every attribute key starts with `fespalier.<pkg>.` and a value is a String, an
int, a double or a bool; `begin` asserts it in debug (`TelemetryOp.custom needs a name like
fespalier.<pkg>.<op>, got ...`). `FespalierOtel` makes a span named `name`; `FespalierSentry` a span described
by it and never sends the attributes. A sink of your own with an exhaustive `switch` on `TelemetryOp` needs a
`TelemetryOp.custom` case. docs/observability.md, "Operations of your own: TelemetryOp.custom".

## Testing

```dart
setUp(() => FespalierTelemetry.install(recording = RecordingTelemetry()));
tearDown(() => FespalierTelemetry.install(null));
```

`recording.log` holds lines such as `#2 start navigate /orders/1`, `#3 start data
(tabs)/orders/$id/data.dart keyed parent=#2`, `#2 page enter /orders/:id`, `#2 end navigate ok
route=/orders/:id kind=go from=/ at=/orders/1`. `#n` ties a start to its end and names the navigation an
operation ran under. For real spans: `OTel.initialize(..., spanProcessor: SimpleSpanProcessor(exporter))`
with `InMemorySpanExporter` from `package:dartastic_opentelemetry/testing.dart` in `setUpAll`
(**once per isolate**, so once per test file), install `FespalierOtel()`, and read the exporter after a
`pump()`: a span is exported when it ends.

Since 0.9.0 a navigation that `navigateFrom` marked has `source=notification` at the end of its start line
(`#1 start navigate /orders/42 source=notification`; unmarked lines do not change), and
`RecordingTelemetry(recordWithin: true)` also writes `#n within enter` and `#n within exit` around what runs
inside `data()` or an action, so a line the code under test adds to `recording.log` shows it ran within its
operation. An `image` operation (since 0.9.0, `fespalier_image`) is `#4 start image emgr w=640 preload`, then
`#4 end image ok async` or `#5 end image error async status=404`: the builder's name and the width, never the URL.
Image spans follow the installed sink and need no `telemetry: true`, like `auth` spans.
A `custom` operation (since 0.11.0) is `#6 start custom fespalier.push.open fespalier.push.kind=alert`, then
`#6 end custom ok fespalier.push.fresh=true`: the attributes sorted by key.
Two sinks next to each other, and a sink of your own that makes its operation current:

```dart
// test/sinks_test.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A sink that makes the file of its operation the current one while data() and actions run.
final class CurrentFile extends FespalierTelemetry {
  static const _key = #currentFile;

  static String? get current => Zone.current[_key] as String?;

  @override
  Object? start(TelemetryStart start) => start.site?.file;

  @override
  void within(Object? token, Object? Function() body) {
    // Zone values only: never runZonedGuarded, never onError.
    runZoned(body, zoneValues: {_key: token});
  }
}

const site = TelemetrySite('orders/\$id/data.dart', route: '/orders/:id');

void main() {
  tearDown(() => FespalierTelemetry.install(null));

  test('two sinks, and data() runs inside its span', () async {
    final recording = RecordingTelemetry(recordWithin: true);
    FespalierTelemetry.install(
      FespalierTelemetry.combine([recording, CurrentFile()]),
    );
    final order = FutureProvider.autoDispose<String?>(
      (ref) => traceDataCall(ref, 'd1', null, () async {
        await Future<void>.delayed(Duration.zero);
        return CurrentFile.current;
      }, telemetry: site),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // After an await, the current file is still the data span's.
    expect(await container.read(order.future), 'orders/\$id/data.dart');
    expect(recording.log, [
      '#1 start data orders/\$id/data.dart',
      '#1 within enter',
      '#1 within exit',
      '#1 end data data async',
    ]);
  });
}
```

## What it costs

- **Off, nothing.** No `TelemetrySite` is passed, so each wrapper's `telemetry` parameter is null and the
  code behind it is compiled out of a release build. CI builds an app (with an `observe.dart`) for the web
  and greps the release build for `fespalier telemetry`.
- **Sync stays sync.** fespalier creates no `Future`, microtask or timer for telemetry; the wrappers
  return the very object they were given. Since 0.9.0 a telemetry app's data provider also allocates one
  closure per build (`traceDataCall`), and nothing else. The OpenTelemetry SDK's own span processors are `async`
  methods, so the SDK schedules microtasks when a span starts or ends; they are never in the path of a
  value the app gets.
- A backgrounded app draws no frames, so a navigation made then ends its span at the next frame after
  resume, and its duration is long: use a percentile, and leave `superseded` navigations out of latency.
