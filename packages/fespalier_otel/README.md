# fespalier_otel

OpenTelemetry for [fespalier](https://github.com/vaam-apps/fespalier) (since 0.8.0): spans for
navigations, guards and redirects, data loads, actions and deferred loads, on the SDK that
[`otel_zone`](https://github.com/vaam-apps/flutter-otel-zone) (or your app) started. fespalier
itself has no OpenTelemetry dependency: it tells a `FespalierTelemetry` sink what happened, and
this package is the sink that turns it into spans.

The main README documents all of it: [Telemetry](https://github.com/vaam-apps/fespalier#telemetry)
(turning it on, the install, the conventions every span and attribute follows, testing, what it
costs). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one
package only if they are the same repository dependency.

<!-- x-release-please-start-version -->
```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/vaam-apps/fespalier
      path: packages/fespalier
      ref: v0.7.0
  fespalier_otel:
    git:
      url: https://github.com/vaam-apps/fespalier
      path: packages/fespalier_otel
      ref: v0.7.0
```
<!-- x-release-please-end -->

Turn it on in `pubspec.yaml` and regenerate:

```yaml
fespalier:
  telemetry: true
```

## Wire it

With `otel_zone` (a git dependency, pinned to a commit: it is not on pub.dev), in `main.dart`:

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
  // Before the router is built, so the first navigation is a span too.
  FespalierTelemetry.install(
    FespalierOtel(isReady: () => observability.isReady),
  );
  runApp(
    ProviderScope(
      observers: [?observability.riverpodObserver()],
      child: MaterialApp.router(
        routerConfig: AppRoutes.router(
          observers: [?observability.routeObserver()],
        ),
      ),
    ),
  );
});

/// `runGuarded` leaves a Flutter web app blank (see below): run the body as it is there.
Future<void> guarded(Future<void> Function() body) =>
    kIsWeb ? body() : observability.runGuarded(body);
```

`FespalierOtel.endpoint()` is the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when set.
Without it, a debug build exports to `http://10.0.2.2:4318` on Android (the emulator's address for
its host) and `http://localhost:4318` elsewhere, and a release build gets `''`, which `otel_zone`
takes as "telemetry off", so a store build never sends to a developer's computer.

An app that starts the SDK itself (`OTel.initialize`) leaves `isReady` out.

## Known limitation: `otel_zone` `runGuarded` on the web

Since 0.8.0, known limitation: on the web, `OtelZone.runGuarded` never runs its body, so the app
stays blank. Inside the zone, before the body, it builds a `ReceivePort`, which `dart:isolate` does
not support there. `OtelZone.start()` itself works on the web, so spans and logs are exported.
Until `otel_zone` guards that call, run the body as it is on the web, as `guarded` above does. The
hooks `runGuarded` installs (`FlutterError.onError` and `PlatformDispatcher.onError` forwarding to
`otel_zone`'s sink) are then not installed on the web: errors there are not exported unless the app
forwards them itself.

## go_router

`otel_zone` depends on `otel_go_router`, which declares `go_router: ^17.0.0`. fespalier accepts 17
and 18, so an app with `otel_zone` resolves go_router 17. An app that needs 18 adds
`dependency_overrides: go_router: ^18.0.0`, as `otel_zone`'s README says.

## Startup failures

A failure while the app starts arrives through `FlutterError.reportError`. Outside the web,
`runGuarded` has pointed `FlutterError.onError` at `otel_zone`'s sink, so it is exported; nothing
here needs to catch it.

## Tests

`FespalierOtel` on an in-memory exporter is what this package's own tests do
(`package:dartastic_opentelemetry/testing.dart`). To test an app without the SDK, install a
`RecordingTelemetry` from `package:fespalier/testing.dart`.
