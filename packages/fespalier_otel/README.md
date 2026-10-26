# fespalier_otel

OpenTelemetry for [fespalier](https://github.com/fespalier/fespalier) (since 0.8.1): spans for
navigations, guards and redirects, data loads, actions and deferred loads, on the SDK that
[`otel_zone`](https://github.com/vaam-apps/flutter-otel-zone) (or your app) started. fespalier
itself has no OpenTelemetry dependency: it tells a `FespalierTelemetry` sink what happened, and
this package is the sink that turns it into spans.

The docs cover all of it: [Telemetry](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#telemetry)
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
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.23.1
  fespalier_otel:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_otel
      ref: v0.23.1
```
<!-- x-release-please-end -->

Turn it on in `pubspec.yaml` and regenerate:

```yaml
fespalier:
  telemetry: true
```

## Wire it

### With the generated main(): `otel: true` (since 0.19.0)

Add `telemetry: true` and `otel: true` under `fespalier:` in pubspec.yaml, with `fespalier_otel` and
`otel_zone` under `dependencies:` as below. `fsp gen` then writes the wiring into
`lib/app.main.g.dart`, and `lib/main.dart` is `Future<void> main() => AppMain.run();`.
[`docs/observability.md`](../../docs/observability.md) ("OpenTelemetry from the generated main()")
has the rest: the zone, the service's name and version, and what is not configured this way.

`FespalierOtel.serviceVersion()` is the build name (`FLUTTER_BUILD_NAME`, Flutter 3.47 and later,
else `unknown`) and `FespalierOtel.buildId()` the build number (`FLUTTER_BUILD_NUMBER`, or null).

### By hand, in your own main()

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

/// Since otel_zone v0.8.1 the zone runs on the web too: no `kIsWeb` branch.
Future<void> guarded(Future<void> Function() body) =>
    observability.runGuarded(body);
```

`FespalierOtel.endpoint()` is the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when set.
Without it, a debug build exports to `http://10.0.2.2:4318` on Android (the emulator's address for
its host) and `http://localhost:4318` elsewhere, and a release build gets `''`, which `otel_zone`
takes as "telemetry off", so a store build never sends to a developer's computer.

An app that starts the SDK itself (`OTel.initialize`) leaves `isReady` out.

### The screen a native crash happened on (since 0.19.0)

Pass `onScreen` and a native crash record names the page the app was on: `FespalierOtel(isReady: () => observability.isReady, onScreen: observability.setCrashScreen)`.
It needs `otel_zone` v0.7.0 or later. `onScreen` is told the route pattern (`/orders/:id`, the value of `fespalier.route`)
after each committed navigation, `null` when no route matched, and nothing for a superseded one. It is told when the
navigation commits, before the new page's `initState` and first `build`, so a crash while that page opens names the page.
It is never told a location, a segment or a query value, and a callback that throws costs nothing but itself. Without `onScreen` nothing changes. The
docs' [The screen a native crash happened on](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#the-screen-a-native-crash-happened-on)
have the platform limits.

### Next to another sink, and HTTP spans under `data()` (since 0.9.0)

`install` holds one sink: to send to OpenTelemetry and to Sentry or an analytics SDK, use
`FespalierTelemetry.combine([FespalierOtel(...), other])`, or `FespalierTelemetry.add(sink)` to put one next
to the installed one. Each sink keeps its own tokens, so `FespalierOtel` still parents its guard, data and
deferred spans under its own navigation span.

`FespalierOtel` makes a data span and an action span the **current** span while `data()` or the action runs
(`Context.current.withSpan(span).runSync`), so the spans that `otel_http` and `otel_dio` make inside them,
after an `await` too, are their children. `OtelTransport(inner, propagateTo: [...])` (since 0.21.0) does the same
for a `fespalier_transport` chain without `otel_http` or `otel_dio`: one `CLIENT` span named by the method
(`GET`) with OpenTelemetry's HTTP attributes, `url.path` but never a query, a header value or a body, and
`traceparent` only for the origins in `propagateTo`. A navigation that `navigateFrom` marked (a notification, a
shortcut, a widget, a link) carries `fespalier.navigation.source`. The docs'
[Spans around data() and actions](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#spans-around-data-and-actions) and
[Where a navigation came from](https://github.com/fespalier/fespalier/blob/main/docs/observability.md#where-a-navigation-came-from-navigatefrom)
have the details.

### See what it sends

`fsp telemetry` (since 0.8.1) starts OpenObserve with four dashboards that answer plain questions ("Do screens
open quickly?") in green, amber or red, and `fsp telemetry --report` says the same in the terminal. The
[Dashboards on your computer](https://github.com/fespalier/fespalier/blob/main/docs/telemetry-dashboards.md) page has the details.

![fespalier's App health dashboard in OpenObserve: eight tiles answer whether screens open and load quickly and whether loads, actions or the app fail, coloured green, amber or red, above a table of verdicts in words.](../../docs/images/telemetry/openobserve-app-health.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

## `runGuarded` on the web

Since otel_zone v0.8.1, `OtelZone.runGuarded` runs its body on the web. Before it, the zone built a
`ReceivePort` ahead of the body, which `dart:isolate` does not support there, so the app stayed blank.
`OtelZone.start()` works on the web either way, so spans and logs are exported. On an older
`otel_zone`, return the body without `runGuarded` on the web (when `kIsWeb` is true):
the hooks `runGuarded` installs (`FlutterError.onError` and `PlatformDispatcher.onError` forwarding to
`otel_zone`'s sink) are then missing there, and errors are not exported unless the app forwards them
itself. On v0.8.1 the web gets framework errors and uncaught async errors, but no isolate listener,
because a browser has no isolates.

## go_router

Since 0.19.0 this package follows the dartastic rc.4 line (`dartastic_opentelemetry` 1.1.0-beta.17,
API 1.0.0-rc.4), which starts at `otel_zone` v0.8.0. This repository pins v0.8.1 (commit
`64c4661ac6cd09718141864d528892916677cc38`), the first whose `runGuarded` runs on the web. That
`otel_zone`'s `otel_go_router` accepts go_router 17 and 18: pub resolves 18 where Flutter has it, with
no override. An `otel_zone` before the rc.4 line (up to v0.7.0) is on the rc.3 line and cannot resolve
beside this package at all; it also pins `go_router: ^17.0.0`, so move it to v0.8.1 first.

## Startup failures

A failure while the app starts arrives through `FlutterError.reportError`. `runGuarded` points
`FlutterError.onError` at `otel_zone`'s sink on the web too (since otel_zone v0.8.1), so it is exported;
nothing here needs to catch it.

## Tests

`FespalierOtel` on an in-memory exporter is what this package's own tests do
(`package:dartastic_opentelemetry/testing.dart`). To test an app without the SDK, install a
`RecordingTelemetry` from `package:fespalier/testing.dart`.
