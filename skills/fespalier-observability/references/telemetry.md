# Telemetry and OpenTelemetry

Since 0.8.1. The README's [Telemetry](https://github.com/fespalier/fespalier#telemetry) section is the user
documentation; this page is what an agent needs to set it up and to say why nothing shows.

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
  (`fespalier telemetry: <error> (not shown again)`).
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
    git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier, ref: v0.8.1 }
  fespalier_otel:
    git: { url: https://github.com/fespalier/fespalier, path: packages/fespalier_otel, ref: v0.8.1 }
```

Use the **same `url` spelling (no `.git`) and the same `ref`** for both, or pub fails with `Because ...
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

## What it costs

- **Off, nothing.** No `TelemetrySite` is passed, so each wrapper's `telemetry` parameter is null and the
  code behind it is compiled out of a release build. CI builds an app (with an `observe.dart`) for the web
  and greps the release build for `fespalier telemetry`.
- **Sync stays sync.** fespalier creates no `Future`, microtask or timer for telemetry; the wrappers
  return the very object they were given. The OpenTelemetry SDK's own span processors are `async`
  methods, so the SDK schedules microtasks when a span starts or ends; they are never in the path of a
  value the app gets.
- A backgrounded app draws no frames, so a navigation made then ends its span at the next frame after
  resume, and its duration is long: use a percentile, and leave `superseded` navigations out of latency.
