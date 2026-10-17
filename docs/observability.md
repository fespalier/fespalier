# Observability

## Route lifecycle: `observe.dart`

Since 0.8.1, an `observe.dart` runs code when a page becomes the one the user sees, when it is on top again, and when it is gone: analytics, logging, a window title. It observes and cannot veto: to ask before a page goes, use [`leave.dart`](navigation.md#leaving-a-page-leavedart).

```dart
// lib/app/observe.dart: every page of the app
import 'package:fespalier/fespalier.dart';
import 'package:my_app/analytics.dart';
import 'package:my_app/app.g.dart';

void onEnter(Ref ref, {required TypedLocation route}) =>
    ref.read(analytics).screenView(AppManifest.byType[route.runtimeType]?.path ?? '?');

// lib/app/products/$id/observe.dart: /products/:id and everything below it
void onEnter(Ref ref, {required int id}) => ref.read(recent.notifier).add(id);
void onFocus({required int id}) => setDocumentTitle('Product $id');
void onLeave(Ref ref, {required int id}) => ref.read(log).info('left product $id');
```

**The functions.** Any of `onEnter`, `onLeave` and `onFocus`, at least one, each a public top-level function that returns `void` (written out). Other functions in the file are helpers and are ignored.

**The parameters.** An optional positional `Ref ref` first, then named parameters bound like a [guard's](guards.md): the folder's segments and those above it, typed (`required int id`); query parameters, optional and nullable (the folder route's when it has a `page.dart`, else the hook's alone); `Uri uri`, the page's location (mount prefix included); and `TypedLocation route`, the typed route of the page the hook runs for (`ProductRoute(id: 3)`); and, in `onEnter` only, `RouteScope scope`, the page instance's scope ([below](#the-pages-scope-routescope)).

`extra`, `ProviderContainer` and `WidgetRef` are errors. The `Ref` is a throwaway provider's, closed when the hook returns: `ref.read` works, and so does changing another provider (`ref.read(views.notifier).add(...)`); `ref.watch` watches nothing that lasts.

**Which pages, and in which order.** An `observe.dart` applies to every page (`page.dart`) at and below its folder, `nest = false` routes included. A `redirect.dart` route never stays on screen, so it never enters. For one page, the hooks of all the files that apply run outermost folder first for `onEnter` and `onFocus`, and innermost first for `onLeave`.

**When.** Hooks run at the end of the first frame that shows the change (a post-frame callback, never during `build`), by comparing what the router committed with what it showed before. The page the user sees is the top one: the last pushed page, else the leaf of the router's location. A page instance is one page on a navigator, told apart by its route and matched location: another segment value is another page (`/products/1` leaves, `/products/2` enters, whatever [`remount`](navigation.md#remounting-a-page-remount) says), and a query change is no transition.

- `onEnter`: the first time a page instance is the page the user sees.
- `onFocus`: an entered page is on top again (a page above it was popped, or its tab was shown).
  `onLeave`: an entered page is on no navigator any more. A page in a tab that is not current is _parked_, not gone: it leaves when it is gone from its branch or the whole tab layout leaves.

`onEnter` and `onLeave` come in pairs, and `onFocus` falls between them. On one frame the `onLeave`s run first, newest first, then the `onEnter` or `onFocus` of the page on top.

| Navigation                             | Events                                                                                            |
| -------------------------------------- | ------------------------------------------------------------------------------------------------- |
| boot at `/a`                           | enter `/a`                                                                                        |
| `go('/a/1')`, a nested page            | enter `/a/:id`; `/a` is covered, not left                                                         |
| `go('/a/2')` from there                | leave `/a/1`, enter `/a/2`                                                                        |
| `refresh()`, a rebuild, a query change | nothing                                                                                           |
| switch to another tab, and back        | enter its page (the first tab's page is parked), then focus                                       |
| `push('/x')`, then `pop()`             | enter `/x`; then leave `/x`, focus the page below                                                 |
| `replace('/y')` on a pushed page       | leave the old, enter the new                                                                      |
| `replace()` on a tree page             | the same page key: a query-only replace is no transition; another segment value leaves and enters |
| `pushReplacement('/y')`                | leave the page, enter `/y`                                                                        |
| a `go` that a guard redirects          | only the final location's events: the redirected-from one never ran                               |
| a `go` out of a tab layout             | leave every entered page of every tab, newest first, then enter                                   |
| a deep link to `/products/1`           | enter `/products/1` only; `/products` enters the first time it shows                              |
| a location with no route               | no hooks; the previous page leaves                                                                |

**Errors.** A hook that throws is caught and reported with `FlutterError.reportError` (library `fespalier`, context `while running onEnter of products/$id/observe.dart`, the hook and the file filled in), and the hooks after it still run. In a widget test that fails the test.

**Other rules:** hooks fire after the frame, not at `context.go()` (a test pumps first: `await tester.pump()`); none runs when the router is disposed or the app is killed; layouts and sections have none; a hook may navigate (it is looked at at the end of the next frame; to redirect, use a [guard](guards.md)); `fsp new 'orders/[id]' --observe` writes the file. An `observe.dart` with no `page.dart` at or below its folder is a warning, and one with none of the three functions an error.

### The page's scope: `RouteScope`

Since 0.11.0, `onEnter` may take `{required RouteScope scope}`: the scope of the page instance that entered, from the end of the frame that first shows it to the end of the frame it is gone from every navigator. It is how a hook ties something to the page's life without a widget:

```dart
// lib/app/orders/$id/observe.dart
void onEnter(Ref ref, {required int id, required RouteScope scope}) {
  scope.hold(OrderRoute.data(id));          // loaded for as long as this page is on a navigator
  final sub = ref.read(orderSocket).subscribe(id);
  scope.onLeave(sub.cancel);                // runs when this page instance is gone
}
```

- `scope.hold(provider)` keeps a provider listened in the app's container until the page leaves, so an `autoDispose` provider (a route's `data`) stays loaded while the page is parked in a tab or covered by another page. It throws a `StateError` once the page has left.
- `scope.onLeave(callback)` runs `callback` when the page leaves, newest first. It has no `Ref`: the hook's is closed by then, so capture what the callback needs. It throws a `StateError` once the page has left.
- `scope.id` is the page instance's identity (`pageInstanceId(state)` for the page's `GoRouterState`), `scope.uri` the location it entered with and `scope.isActive` false once it left.

The scope is the lifecycle's own instance, so it lives exactly as long as the events above say:

| Case                                            | Scope                                                                                |
| ----------------------------------------------- | ------------------------------------------------------------------------------------ |
| a page parked in another tab                    | stays (parked is not gone)                                                           |
| back to that tab                                | the same scope (`onFocus`)                                                           |
| `/c/1` to `/c/2`                                | the old one ends, a new one starts                                                   |
| a query change, or `remount: onLocation` on one | the same scope (remount rebuilds the widget, not the instance)                       |
| a page pushed twice                             | two scopes                                                                           |
| a page covered by a pushed one                  | stays                                                                                |
| a deferred page                                 | starts at enter, while the code loads: hold nothing declared in the deferred library |

All the `observe.dart` files of a page share one scope. At leave, for one page instance: the `onLeave` hooks run first, innermost folder first (they can still read what is held), then the `scope.onLeave` callbacks, newest first, each caught and reported with `FlutterError.reportError` (context `while running a RouteScope.onLeave callback of <id>`), then the held providers are released. When the router is disposed no leave runs, as for the hooks. A scope also ends when its container is disposed (a `pumpRouter` test ends, the app is torn down): its `onLeave` callbacks run then, newest first, so a socket or timer a callback cancels does not outlive a widget test. The scope does this with a provider of its own that it listens to on the first `hold` or `onLeave`: Riverpod's `ref.onDispose` ends it, and fespalier adds no listener, timer or microtask.

Hooks run in the container `AppRoutes.attach(router, container)` was given: the generated `main()` passes the app's root container to `attach` in an app with an `observe.dart` (since 0.11.0), so every hook runs there, not in a nested `ProviderScope` (a provider overridden only in a nested scope reads its default in a hook). Without a container (`AppRoutes.router()` alone, a router you attach yourself) they run in the one above the root navigator. A scope is a plain object made when the page's first `onEnter` runs, with no subscription until a hook calls `hold` or `onLeave`, and no timer, microtask or listener of its own. `hold` keeps a provider active while its page is parked in a tab: Riverpod would otherwise pause one whose only listeners are in a hidden tab, so a held stream keeps running. `keep_previous` is not affected: holding `XRoute.data(id)` only keeps it out of `autoDispose` while the page is on a navigator.

`onEnter` here is neither go_router's top-level `onEnter` (its router-level hook) nor `FespalierAdapter.onEnter(InboundNavigation)` (an adapter's hook for a platform link): `observe.dart`'s runs after the navigation, for one page. The generated `RouteHooks.onEnter` takes `(ref, scope)` since 0.11.0. A widget test of a hook that takes a scope uses `TestRouteScope(container)` from `package:fespalier/testing.dart` and calls `scope.leave()`.

The page instance's id (`scope.id`) is `'<pageKey>#<matchedLocation>'` when go_router's page key is a route's path template and `'<pageKey>@<path>'` when it is a random one (`push`, `pushReplacement`). `replace` keeps the key of the page it replaces, so `replace('/c/1?q=2')` on the tree page `/c/1` is the same instance, as the table says. An error page (a location with no route) is told apart by its whole location, query included, and `pageInstanceId` of its state is not that id.

## Telemetry

Since 0.8.1, fespalier reports what it does while it routes: each navigation, guard and `redirect.dart` decision, `data.dart` load, action run and deferred-page load, with the pages that entered, were focused or left ([the names](telemetry-conventions.md)). It has no OpenTelemetry dependency; it tells a `FespalierTelemetry` sink:

- `package:fespalier_otel` turns it into spans on the SDK that [`otel_zone`](https://github.com/vaam-apps/flutter-otel-zone) starts;
- `package:fespalier_sentry` (since 0.9.0) is the sink for [Sentry](#sentry-fespalier_sentry), errors first;
- a test installs a `RecordingTelemetry` instead.

### Turning it on

Telemetry is opt-in, in two steps. In `pubspec.yaml`:

```yaml
fespalier:
  telemetry: true
```

`fsp gen` then:

- passes a `const TelemetrySite('products/$id/data.dart', route: '/products/:id')` to each guard, `data.dart` provider and action;
- gives each deferred library its page's pattern;
- has `AppRoutes.attach` follow the router (`AppRoutes.router()` calls it; an app that mounts the tree in a `GoRouter` of its own calls `AppRoutes.attach(router)` once with that router);
- since 0.9.0, makes each data provider call `data()` inside a closure, `traceDataCall(ref, 'd4', id, () => data(ref, id: id), ...)`, so a sink can [run it inside the span](#spans-around-data-and-actions). That costs one closure per provider build.

A value that is not a bool is an error. Without the key nothing is generated for telemetry.

At run time nothing is reported until the app installs a sink, before `runApp` and before the router is built, so the first navigation is reported too:

```dart
FespalierTelemetry.install(sink); // null uninstalls
```

A sink is called synchronously from the router, a provider or an action, so it must return at once, not throw (fespalier catches it and prints `fespalier telemetry: <error> (not shown again)` once) and not navigate or read a provider. There is one slot: a second `install` replaces the first. To report to several sinks, [combine them](#several-sinks-combine-and-add) (since 0.9.0).

### OpenTelemetry from the generated main()

Since 0.19.0. With `otel: true`, `fsp gen` writes the OpenTelemetry wiring into `lib/app.main.g.dart`, so `lib/main.dart` is `Future<void> main() => AppMain.run();` and the app writes no OpenTelemetry code. Add `fespalier_otel` and `otel_zone` under `dependencies:` as [the next section](#opentelemetry-with-otel_zone) shows, then in `pubspec.yaml`:

```yaml
fespalier:
  telemetry: true
  otel: true
```

`otel: true` needs `telemetry: true`, both packages under `dependencies:` (not `dev_dependencies:`), and not `main: manual`, which writes no `main()` at all. [`otel`](configuration.md#otel) lists the errors `fsp` gives for each. The generated file then has:

- `static final OtelZone observability`, with `serviceName` the pubspec's `name` and `endpoint: FespalierOtel.endpoint()`. A release build without `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` exports nothing.
- In `_main()`, right after `WidgetsFlutterBinding.ensureInitialized()` and before the deferred routes, the adapters' `beforeRun` and `runApp`: `observability.start(...)` with the version and the build, then `FespalierTelemetry.add(FespalierOtel(isReady: ..., onScreen: observability.setCrashScreen))`. It is `add`, not `install`, so a sink that an adapter or your `startup()` adds stays.
- The Riverpod observer and the route observer, which are null until the SDK is up: they reach `ProviderScope(observers:)` and `AppRoutes.router(observers:)` through the same hooks the [adapters](adapters.md) use.
- The zone: `observability.runGuarded` around all of `main()`, off the web, where `runGuarded` never runs its body. On the web the body runs as it is, as in the [hand wiring](#opentelemetry-with-otel_zone). It is the innermost zone, inside the [adapters' zones](adapters.md), and a `zone()` in startup.dart replaces it, so Sentry's zone wins ([Wiring Sentry](#wiring-sentry)).

**The version and the build.** `serviceVersion` is the build name: `FLUTTER_BUILD_NAME`, which Flutter passes from 3.47 on (`1.4.0` of `version: 1.4.0+12`, or `--build-name`). An older Flutter passes none, and `service.version` is `unknown`, which `otel_zone` takes (it refuses an empty one). `buildId` is `FLUTTER_BUILD_NUMBER` (the `12`), or none. Neither is written into the file, so a version bump does not change the generated code. `FespalierOtel.serviceVersion()` and `FespalierOtel.buildId()` read them.

**What does not change.** `lib/app.g.dart` is the same bytes as without the key. An app's own sink goes in `startup()` with `FespalierTelemetry.add(sink)`, **once**: `install` would replace the OpenTelemetry one, and `fsp gen` says so, and `startup()` runs again on Retry after an async step failed, while `add` appends a sink each time it is called. Keep the sink in a top-level `final _sink = ...;` and write `if (!FespalierTelemetry.contains(_sink)) FespalierTelemetry.add(_sink);` (`fsp create --features otel,sentry` writes it so). A `startup.dart` that builds its own `OtelZone` is warned about too, because the SDK would start twice.

**`AppMain.observability`** is the SDK for what the app adds itself, such as `AppMain.observability.setEndUser(id)` after sign-in. `isReady` says whether it is up. A test that pumps `AppMain.root()` never starts it: the start is in `main()`, not in the widget tree.

**What it does not configure.** The rest of `OtelZoneConfig`: `deploymentEnvironmentName`, `exportFloor`, `redact` and the spool. An app that needs them keeps the hand wiring of [the next section](#opentelemetry-with-otel_zone) and leaves `otel: true` out. That works under `main: auto`, with no `main: manual`: write it in `lib/app/startup.dart` (the `OtelZone`, its `start()`, the sink and the observers, and a `zone()` for `runGuarded`), or in a `lib/main.dart` of your own that does not call `AppMain.run()`, as `examples/telemetry` does.

**Checked, and not checked.** CI's `create` jobs build `fsp create --features otel`, `telemetry` and `all` and run their tests, and the generator's tests check the emitted `main()`. Nothing runs the SDK on a phone or in a browser, so these are **UNCHECKED on a device**: the spans arrive with `service.name` set to the app, `service.version` the build name and `app.build_id` the build number (Android, iOS, Flutter 3.47 and later); the web is not blank and its spans reach `localhost`; a release build without the define exports nothing; a native crash names its screen ([above](#the-screen-a-native-crash-happened-on)); and with `sentry` and a DSN an uncaught async error reaches Sentry with `otel.trace_id`.

### OpenTelemetry with otel_zone

By hand, for your own `main()` and the options `otel: true` does not take (the [generated wiring](#opentelemetry-from-the-generated-main) is the default since 0.19.0). `otel_zone` is not on pub.dev: depend on it by git, pinned to a commit. Add `fespalier_otel` next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.18.0
  fespalier_otel:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_otel
      ref: v0.18.0
```

<!-- x-release-please-end -->

```yaml
otel_zone:
  git:
    url: https://github.com/vaam-apps/flutter-otel-zone
    ref: 8a72fc4162f6426951176d40c490389f77385647 # a commit, not a tag
```

Since 0.19.0, `otel_zone` from commit `8a72fc4162f6426951176d40c490389f77385647` (0.8.0 to be) is on the dartastic rc.4 line, and its `otel_go_router` accepts go_router 17 and 18, so pub resolves go_router 18 on a Flutter that has it and no override is needed; `fespalier_otel` follows the same line (`dartastic_opentelemetry` 1.1.0-beta.17, API 1.0.0-rc.4). An app that stays on an `otel_zone` before that commit (up to v0.7.0) still gets `otel_go_router: ^0.2.0`, which asks for `go_router: ^17.0.0`: it resolves go_router 17, and adds `dependency_overrides: go_router: ^18.0.0` to stay on 18, as `otel_zone`'s README says. `examples/telemetry` is on go_router 18.

The wiring, in `main.dart` (`examples/telemetry` is this, inside Sentry's zone):

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
  FespalierTelemetry.install(
    FespalierOtel(
      isReady: () => observability.isReady,
      onScreen: observability.setCrashScreen,
    ),
  );
  runApp(ProviderScope(
    observers: [?observability.riverpodObserver()],
    child: MaterialApp.router(
      routerConfig: AppRoutes.router(observers: [?observability.routeObserver()]),
    ),
  ));
});

Future<void> guarded(Future<void> Function() body) =>
    kIsWeb ? body() : observability.runGuarded(body);
```

`otel_zone` owns the zone that `WidgetsFlutterBinding.ensureInitialized()` and `runApp` run in, so both go inside `runGuarded`. A failure while the app starts arrives through `FlutterError.reportError`.

- `FespalierOtel(isReady:)` emits nothing until the SDK is up; an app that starts the SDK itself leaves it out.
- `recordLocations: true` adds the committed location and a guard's redirect target to the spans (segment and query values are app data, so it is off).
  `FespalierOtel.endpoint()` is the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when there is one. Without it a debug build exports to `http://10.0.2.2:4318` on Android (the emulator's host) and `http://localhost:4318` elsewhere; a release build gets `''`, which `otel_zone` takes as "telemetry off", so a store build never sends to a developer's computer.

**Known limitation on the web (since 0.8.1).** `OtelZone.runGuarded` never runs its body there, so the app stays blank: it builds a `ReceivePort`, which `dart:isolate` does not support on the web (`start()` works). Until `otel_zone` guards that call, run the body as it is on the web, as `guarded` above does; the error hooks `runGuarded` installs are then missing there.

### The screen a native crash happened on

Since 0.19.0. A native crash or an ANR that `otel_zone` records can say which screen the app was showing when it died: the record carries `otel_zone.crashed.screen`, and the Errors dashboard has a table of crashes and freezes by screen, "Which screen was the app on when it crashed?". The app does not write the call itself: `FespalierOtel` makes it on every committed navigation when it is given `onScreen`.

```dart
FespalierTelemetry.install(
  FespalierOtel(
    isReady: () => observability.isReady,
    onScreen: observability.setCrashScreen,
  ),
);
```

It needs `otel_zone` v0.7.0 or later; the pin above is the commit that carries the call.

- **What it is told:** the route **pattern** of the page on screen, `/orders/:id`, the value of `fespalier.route`. It is `null` after a navigation that matched no route, and a superseded navigation tells nothing, because the one that replaced it does. Only navigations that have a span tell it, so it is called only while the SDK is up. It never receives a location, a segment or a query value.
- **When it is told:** when the navigation commits, before the new page's `initState` and first `build`, so a crash or an ANR while that page opens (a plugin call in `initState`, a heavy synchronous first build) is recorded with that page. A navigation that commits twice before its first frame (a guard that changed its answer) tells both, and the second stays. While a guard or a `redirect.dart` is still deciding nothing has committed, so a crash then names the page the user still sees. A navigation made in the background is told at once, though its span ends after the app resumes. `otel_zone` keeps the value once its one message reaches the platform (sent at once, or as soon as the previous one has landed, on a background queue), so a crash in that same instant can still name the page before.
- **What it costs without `onScreen`:** nothing. The call is not made, and nothing is sent to the platform.
- **What the platform keeps:** a screen is trimmed, and kept only if it is at most 64 UTF-8 bytes with no control character. Anything else is `null`: it clears the previous value and is never cut to fit. On Android the screen is part of the 128-byte process state summary, and it is the first field dropped when the summary is full. `otel_zone`'s `redact` scrubs it at export, as it does every attribute, so a pattern a redactor would mangle reaches the collector mangled.
- **Where each kind of record gets its screen:** an Android JVM crash from memory; a native crash, an ANR, a signal or a low-memory kill from the process state summary, on Android 11 (API 30) and later, so below API 30 only the JVM crashes carry it; an iOS `NSException` from memory; an iOS MetricKit crash from a small per-run file matched by process id, on iOS 17 and later, and only when exactly one run matches. An iOS hang never carries one, because the process lived on. An Android ANR carries the last screen the platform received, because the frozen main thread cannot navigate, and a kill in the background carries the screen the app was left on.
- **What it is not:** a recovered crash is not stamped with the screen the app shows now, because it happened in an earlier launch. A crash that names no screen is `unknown` in the table, never a guess.

The platform details are in [`otel_zone`'s README](https://github.com/vaam-apps/flutter-otel-zone#which-screen-it-died-on), which lists the summary's layout and the cost of a change. **UNCHECKED on a device:** no fespalier test reads a native crash record. `otel_zone`'s own CI checks the screen on Android emulators (a JVM crash, a native crash and an ANR each carry `/home`), but nothing has run on a phone, and the Errors table has not been seen with a real crash. Whether each platform above names the screen it should, on a real phone or simulator, is a device run, not something this package has verified. Nor has a crash in a new page's `initState` been seen to name that page on a device.

### Several sinks: combine and add

Since 0.9.0. `install` holds one sink, so OpenTelemetry, Sentry and an analytics SDK would replace one another. `FespalierTelemetry.combine` makes one sink of several, which tells each of them everything, in list order:

```dart
FespalierTelemetry.install(
  FespalierTelemetry.combine([
    FespalierOtel(isReady: () => observability.isReady),
    AnalyticsTelemetry(),
  ]),
);
```

`FespalierTelemetry.add(sink)` is `install(combine([?current, sink]))`: use it where two places each install a sink (a package's setup and the app's `startup()`, say), so neither replaces the other. `install` replaces everything and `install(null)` removes everything; a second `install` that was meant to add is the usual mistake.

**Each sink has its own tokens.** The token a sink returns from `start` is what only that sink gets back at `end`, at `page`, at `commit`, in `within` and as the `TelemetryStart.parent` of what runs during its navigations. One sink's spans never become another's parents, and `FespalierOtel` keeps its navigation as the parent of its guard, data and deferred spans behind a `combine`.
**Each sink is isolated.** A sink that throws does not stop the others or the app: its error is printed once per sink (`fespalier telemetry: <error> in <Sink> (not shown again)`) and it is called again at the next operation. A sink with no token for an operation (`start` returned null) is still told the end, with null.
**Nesting.** A combined sink in the list is flattened, `combine([])` reports nothing and `combine([sink])` is `sink`. For [`within`](#spans-around-data-and-actions) the first sink is the outermost.
**Trace links.** A sink that makes OpenTelemetry spans overrides `traceOf(token)` to return a `TelemetryTrace(traceId, spanId)` (32 and 16 lowercase hex digits). `combine` then tells every other sink with `linkTrace(token, trace)`, with that sink's own token, once per operation, after every sink started it and before `within` and `end`. `FespalierOtel` answers `traceOf` with the span it made, and [`fespalier_sentry`](#sentry-fespalier_sentry) tags its events with `otel.trace_id` and `otel.span_id`. List order does not matter; with no sink that answers, nothing is called.
**Commits** (since 0.19.0). `commit(navigation, commit)` tells a sink, with its own token, that a navigation committed. The `TelemetryCommit` gives its `outcome` (`ok`, or `not_found`) and the `route` pattern of the page it puts on screen (null when not found). It comes synchronously from the router, before the new page's `initState` and first `build`, so before the navigation's `page` events and `end`. The first one comes while the `Router` widget is built, so never navigate, call `setState` or change a provider in it. A superseded navigation never commits. One that commits twice before its first frame is told twice, and, while the same sink stays installed, the last `route` is what `end` reports. The default does nothing; `FespalierOtel` passes it to [`onScreen`](#the-screen-a-native-crash-happened-on). A sink that implements `FespalierTelemetry` instead of extending it adds the method, and a member already named `commit` with another signature must be renamed.

### Spans around data() and actions

Since 0.9.0. A sink can make the span of a data load or an action the **current** one while `data()` or the action runs, so the spans an HTTP client makes inside it (after an `await` too) are its children, not roots of traces of their own. fespalier calls `FespalierTelemetry.within` around them:

```dart
/// Runs [body] inside the operation [token] came from. The default calls [body].
void within(Object? token, Object? Function() body) => body();
```

`FespalierOtel` overrides it with `Context.current.withSpan(span).runSync(body)`, so what `otel_http` and `otel_dio` instrument inside a `data()` or an action takes that span as its parent. A sink of your own overrides it the same way (a member already named `within` with another signature must be renamed). The rules:

Call `body` once, synchronously, before you return. It returns what the operation returned (null when it threw, which `end` says), so you may observe it, e.g. hand a `Future` to a vendor API that ends a span when it settles. It never throws; fespalier rethrows what the operation threw after your method returns.
fespalier returns the operation's **own** result, the very object, whatever `within` does: a sync `data()` is never made a `Future`, no microtask is scheduled, and a sink cannot replace the `Future` Riverpod awaits. `body` runs exactly once, even for a sink that never calls it, calls it twice or throws.

- Run `body` in a zone you make with zone values only (`runZoned(body, zoneValues: {...})`). **Never give that zone an error handler** (`runZonedGuarded`, `onError:`, a `ZoneSpecification` with `handleUncaughtError`): a `Future` that fails in another error zone never reaches Riverpod, and the page would stay on its loading view. fespalier refuses such a zone at run time: it runs `body` in the caller's zone instead and prints, once, `fespalier telemetry: <Sink>.within changed the error zone, so
data() and actions run outside it (use runZoned with zoneValues, not runZonedGuarded) (not shown again)`.
  Behind a `combine`, each sink's `within` runs the next one's, so every sink's scope wraps `data()`. Guards and deferred loads do not get `within`: a guard must stay cheap and a deferred load runs no app code.

`FespalierTelemetry.run(token, body)` is the same for an adapter package that starts operations of its own with `FespalierTelemetry.begin`: `body` runs once, synchronously, and what it returns or throws comes back (with no sink or a null token, it is `body()`).

The data span starts **before** `data()` runs, so its duration includes the synchronous part, and a `data()` that throws before it returns has a `data` span with `fespalier.data.state = error` and `fespalier.async = false`.

Since 0.18.0 a sink also reads what the span of a load and of an action say about itself: `TelemetryStart.dataAttempt` (which try the load is: `1`, or n + 1 when Riverpod ran a failed provider again on its own), `TelemetryEnd.dataSource` (`cache` or `fetch`, for a data.dart with a `dataCache`), and, on an action's end, `TelemetryEnd.actionRolledBack` and `TelemetryEnd.actionInvalid`. [Telemetry conventions](telemetry-conventions.md#telemetry-conventions) has the attribute names.

### Where a navigation came from: navigateFrom

Since 0.9.0. A navigation that starts from a tap on a notification, a home-screen shortcut or widget, or a link a bridge handed over looks like any other `go` to fespalier. `navigateFrom` marks it:

```dart
// The app is running: a tap on a notification.
navigateFrom(NavigationSource.notification, () => router.go('/orders/42'));

// A cold start from the same tap: the router's initial location is the launch.
final router = navigateFrom(
  NavigationSource.notification,
  () => AppRoutes.router(initialLocation: '/orders/42'),
);
```

`NavigationSource` has `notification`, `shortcut`, `widget` and `link`. Telemetry reports the mark as `TelemetryStart.source` and, in `FespalierOtel`, as the attribute `fespalier.navigation.source` of the `navigate` span; a navigation the app's own code started has none. Guards run as for any link, and `fespalier.navigation.kind` still says how the stack changed (a cold start is `initial`, a warm one `go` or `push`).

The closure runs once, synchronously, and what it returns is returned. The **first** navigation it starts takes the mark, which is dropped when the closure returns, so it cannot reach a later one; a closure that starts no navigation leaves nothing behind.
Since 0.11.0, with `launchRouter(..., links: true)` (what the generated `AppRoutes.router` passes for an app with `telemetry: true`, or with an adapter that has an `onEnter` since 0.16.0), fespalier marks a platform link `NavigationSource.link` by itself, at cold start and while running (never on the web); see [Opening the app](navigation.md#opening-the-app-launches-and-platform-links). Anything else (the browser's back button, a notification tap) looks like any other navigation: the bridge that knows calls `navigateFrom`, and an adapter's `launch()` covers the cold start.

- A source that is not one of the four values is an `AssertionError` in debug: ``navigateFrom: `banner`
is not a NavigationSource value (notification, shortcut, widget or link)``.
- `RecordingTelemetry` writes it as `source=notification` on the start line of the navigation, and only when it is set.

### Operations of your own: TelemetryOp.custom

Since 0.11.0. A package that is not fespalier's own reports an operation through the same two calls as `fespalier_auth` and `fespalier_image`, with `TelemetryOp.custom`: `TelemetryStart.name` says which, and the package's own attributes ride along.

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

- `name` is `fespalier.<pkg>.<op>` (lowercase letters, digits and underscores, at least three segments), and every key of `attributes` starts with the name's first two segments and a dot (`fespalier.push.`). A value is a `String`, an `int`, a `double` or a `bool`. `begin` asserts all of it in debug: `TelemetryOp.custom needs a name like fespalier.<pkg>.<op>, got ...`, `TelemetryOp.custom attribute "..." must start with "fespalier.push."` and `TelemetryOp.custom attribute "..." must be a String, int, double or bool, got ...`.
- `FespalierOtel` makes a span named `name` with `fespalier.operation = custom`, `fespalier.custom.name`, `fespalier.custom.result` (the outcome) and `fespalier.async`, plus the package's own attributes from the start and the end. A failed one has the status and `error.type`, never the exception's text. The package's own `fespalier.<pkg>.*` keys are that package's contract, not contract version 1's; `fespalier.custom.name` and `fespalier.custom.result` are version 1's (new keys within the version).
- `FespalierSentry` reports a custom operation as a span `fespalier.custom` described by its name (with `tracing: true`) and, when it fails, as a breadcrumb with the class only (an event with a `capture:` of your own), and **never sends its attributes**.
- `RecordingTelemetry` writes `#1 start custom fespalier.push.open fespalier.push.kind=alert` (the attributes sorted by key) and `#1 end custom ok fespalier.push.fresh=true`.
- **Privacy:** `FespalierOtel` exports `name` and every attribute **verbatim**, so they must hold no user value (a segment, a query value, an input, a result, a token), and the name must be a constant (`fespalier.push.open`, not `fespalier.push.order_42`: the regex allows digits). Only the class of an error is exported. A package segment of `custom`, `image`, `auth`, `operation` and the other names fespalier uses for its own attributes is refused in debug.
- `fespalier.custom.result` is the outcome the package ended with, usually `ok` or `error`.
- A sink of your own with an exhaustive `switch` on `TelemetryOp` needs a `TelemetryOp.custom` case.

### Testing telemetry

`package:fespalier/testing.dart` has `RecordingTelemetry`, a sink that keeps what it is told as lines to compare. Install it in `setUp` and uninstall it in `tearDown`:

```dart
setUp(() {
  recording = RecordingTelemetry();
  FespalierTelemetry.install(recording);
});
tearDown(() => FespalierTelemetry.install(null));

testWidgets('opens an order', (tester) async {
  final router = AppRoutes.router();
  await pumpRouter(tester, router);
  recording.log.clear();
  router.go('/orders/1');
  await tester.pumpAndSettle();
  expect(recording.log, contains('#3 end data data async'));
});
```

Each operation is `#n`, which ties its `start` line to its `end` line and names the navigation it ran under (`parent=#2`).

- `RecordingTelemetry(recordWithin: true)` also writes `#n within enter` and `#n within exit` around what runs inside a `data()` or an action, so a test can see a call run within its operation.
- An `image` operation (since 0.9.0) is `#4 start image emgr w=640 preload` and, when it ends, `#4 end image ok async` or `#5 end image error async status=404`: the builder's name and the width, never the URL.
- Since 0.18.0 a line can also say `attempt=N` (a data start that is the Nth try of a retry), `source=cache` or `source=fetch` (a data end of a `dataCache`), `rolled_back=true` or `rolled_back=false` (an action end with an optimistic patch shown), and `invalid` (an action that ended with `FieldErrors`).
- Since 0.19.0 `RecordingTelemetry(recordCommits: true)` also writes `#n commit ok route=/orders/:id` (`#n commit not_found` when no route matched) when a navigation commits, before its `page` lines and its end. It is off by default, so a log written before 0.19.0 reads the same.

To see real spans, initialise the SDK in `setUpAll` with `SimpleSpanProcessor` and `InMemorySpanExporter` from `package:dartastic_opentelemetry/testing.dart`, install `FespalierOtel()`, and read the exporter after a `pump()`: a span is exported when it ends. `OTel.initialize` runs once per isolate, so once per test file. `examples/telemetry/test/` does both.

### What it costs

An app without `telemetry: true` and without an `observe.dart` generates no telemetry code, and its release build carries none of it: no call site passes a site, so the telemetry parameter of each wrapper is null and the code behind it is not compiled in.

With a sink installed, fespalier never creates a `Future`, a microtask or a timer for telemetry:

- a sync guard, `data()` or action is reported with its start and its end in the same call stack;
- an async one is reported through a side listener on the very `Future` (which handles its own error, so it cannot make an unhandled one);
- the wrappers return the very object they were given.

Since 0.18.0, with a sink, each data load also registers one `ref.onManualInvalidation` callback and one `ref.onDispose` callback, which Riverpod drops when the provider rebuilds, and keeps one small entry per provider whose last load failed; the next load that succeeds removes it, and so does disposing the provider (or invalidating it by hand), so a page that is gone leaves nothing behind.

What does schedule microtasks is the OpenTelemetry SDK itself, whose span processors are `async` methods: they run when a span starts or ends, never in the path of a value the app gets. A backgrounded app draws no frames, so a navigation made in the background ends its span at the next frame after the app resumes.

Since 0.19.0, with a sink, each commit walks the router's configuration once more to name its page (a few small objects per navigation), and tells the sink in the same call stack.

## Sentry: fespalier_sentry

Since 0.9.0. `package:fespalier_sentry` is the `FespalierTelemetry` sink for [Sentry](https://sentry.io), and it is **errors first**: out of the box it sends what a team that debugs a production app asks for, and leaves performance monitoring to the teams that want it.

- **Every error and crash, with where it happened.** An error that a guard, a `data.dart`, an action or a deferred load threw is a Sentry event tagged with the route pattern (`/products/:id`, never the URL), the app file (`products/$id/data.dart`) and, for an action, its function name. Events are grouped by that file and not by the Riverpod frames on top of the stack. The screen is also the scope's _transaction_ name, which Sentry's issue list groups and searches by, so a crash that no fespalier operation reported says which screen it happened on too.
- **One breadcrumb per page change**, from the pattern of the page that was left to the pattern of the page that is shown, so a report reads as the path the user took.
- **Release health.** Sessions, crash-free users and crash-free sessions are the SDK's; a handled error marks its session _errored_.
- **A link to the OpenTelemetry trace.** Next to `fespalier_otel` (installed together with [`FespalierTelemetry.combine`](#several-sinks-combine-and-add)), each event carries `otel.trace_id` and `otel.span_id`: the trace of the span the failing call made, or, for a crash, of the navigation that opened the screen. Search the trace id in your OpenTelemetry backend to see what the app did.

Screen-load transactions, spans for guards, data loads and actions, and time to full display are opt-in (`FespalierSentry(tracing: true)`), for a team that has only Sentry: with `fespalier_otel` the traces are there already.

fespalier has no Sentry dependency. `SentryFlutter.init` still starts the SDK, which owns the crash capture, the sessions, the native integrations and the transport; this package only tells it what the router knows. Add it next to fespalier, with the same `url` and the same `ref` (as for `fespalier_otel`):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.18.0
  fespalier_sentry:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_sentry
      ref: v0.18.0
```

<!-- x-release-please-end -->

The app also depends on `sentry_flutter` for `SentryFlutter.init`, in the range this package accepts:
`>=9.26.0 <10.0.0`.

How an error travels, from the call that failed to sentry.io (every arrow into the sink is a plain synchronous call; every SDK call that returns a `Future` is fired and forgotten):

```text
 your app (lib/app/**)          package:fespalier        package:fespalier_sentry            Sentry SDK
 ─────────────────────          ─────────────────        ────────────────────────            ──────────
 ProductRoute(id: 7).go(ctx)
        └─────────────────────▶ navigation commits ─end(navigate)──▶ scope: transaction = '/products/:id',
                                page events ───────page(enter)────▶ tag fespalier.route, tag otel.trace_id;
                                                                    breadcrumb 'navigation' from → to
 orders/$id/action.dart throws ─ action ends ───────end(error)─────▶ captureException(error,
                                                                      tags: fespalier.route, .file,
                                                                      .operation, .action, otel.*;
                                                                      fingerprint: {{default}} + file) ──▶ event ──▶ sentry.io
 something else crashes ───────────────────────────────────────────▶ the SDK's own capture: the event
                                                                      has the scope's transaction and tags
```

### What Sentry gets from fespalier

| fespalier reports                                                       | In Sentry, by default                                                                                                                                                                         | With `tracing: true` too                                                                                |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| outcome `error` with an exception (guard, `data`, `action`, `deferred`) | an event, **handled**, mechanism `fespalier.{operation}`, tags `fespalier.operation`, `.route`, `.file` and `.action` (an action), fingerprint `['{{ default }}', file]`, context `fespalier` | the event belongs to the span of the operation that failed (status `internal_error`)                    |
| the same failure again within `repeatWindow` (30 s)                     | a breadcrumb `data products/$id/data.dart StateError again`, not another event (Riverpod retries a failing `data()` up to ten times)                                                          | —                                                                                                       |
| a `FieldErrors` (a validation answer)                                   | **not** an event: a breadcrumb `action ... rejected` (its messages can echo what the user typed)                                                                                              | the span has status `invalid_argument`                                                                  |
| an `auth` step that fails (`fespalier_auth`)                            | not an event (the next request retries it): a breadcrumb with the class of the error, never its text                                                                                          | a span `fespalier.auth`                                                                                 |
| a `custom` operation that fails (a package's own)                       | not an event: a breadcrumb with the class of the error, never its text; `capture:` opts in, and the event then has the tag and context `fespalier.custom.name` and is grouped by it           | a span `fespalier.custom` described by its name, with no attributes                                     |
| an `image` that fails (`fespalier_image`)                               | a breadcrumb `image emgr error status=404`, never the URL                                                                                                                                     | a span `fespalier.image`, a child of the navigation in progress                                         |
| a committed navigation                                                  | the scope's transaction name is the pattern, the tag `fespalier.route` too; with `fespalier_otel`, the tags `otel.trace_id` and `otel.span_id`                                                | a `ui.load` transaction named by the pattern, with `time_to_initial_display` and `time_to_full_display` |
| a page `enter` or `focus`                                               | one breadcrumb, type `navigation`, `from` and `to` patterns (a leave is no breadcrumb: a page change is one)                                                                                  | —                                                                                                       |
| a location that matched no route                                        | a warning breadcrumb `not found`, the transaction name `navigate (not found)`, no route tag                                                                                                   | a transaction with that name                                                                            |
| a guard or `redirect.dart` that redirects                               | a breadcrumb `redirect by checkout/guard.dart` (the target only with `recordLocations: true`)                                                                                                 | spans `fespalier.guard` and `fespalier.redirect`                                                        |
| an action that works                                                    | a breadcrumb `items/$id/action.dart#rename ok`, never its input or its result                                                                                                                 | a span `fespalier.action`, a child of the open screen's transaction or a transaction of its own         |
| a `data` load, a `deferred` load                                        | nothing                                                                                                                                                                                       | spans `fespalier.data` and `fespalier.deferred`; the screen ends when its last data load does           |
| a pop, a refresh                                                        | a breadcrumb and the scope's name                                                                                                                                                             | no transaction: they show a page that is already built                                                  |
| a navigation that a newer one superseded                                | nothing                                                                                                                                                                                       | not sent                                                                                                |

The keys are the telemetry conventions' names (contract version 1), so a search in Sentry and a query in OpenObserve use the same words. How they map onto Sentry is documented with this package and is not part of contract version 1.

**Never sent:** segment values, query values (`recordLocations: true` adds only the committed **path**), family keys, `extra`, action inputs and results, data values, and a `FieldErrors`. What is sent is route patterns, app file paths, action function names, enum-like outcomes, durations, and the exception with its type and stack. Exception **text** is the app's: Sentry sends it as it is, so redact what your app knows to be sensitive in `options.beforeSend`, as with any Sentry app.

### Wiring Sentry

Sentry starts first: its `appRunner` runs the binding, `startup()` and `runApp`, so crashes are Sentry's. In `lib/app/startup.dart`:

```dart
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

Next to OpenTelemetry (`otel_zone`), install both in the one slot. Do **not** also use `OtelZone.runGuarded`: its zone sends an uncaught async error to Talker only, and Sentry would never see it (it is also blank on the web). Start the SDK with `observability.start()` in `startup()` instead:

```dart
Future<void> zone(Future<void> Function() body) => SentryFlutter.init(
  (options) => FespalierSentry.configure(options, dsn: const String.fromEnvironment('SENTRY_DSN')),
  appRunner: body, // not observability.runGuarded: Sentry captures the crashes
);

Future<void> startup() async {
  FespalierTelemetry.install(
    FespalierTelemetry.combine([
      FespalierSentry(),
      FespalierOtel(isReady: () => observability.isReady), // emits once start() below is done
    ]),
  );
  await observability.start(serviceVersion: '1.4.0', resourceAttributes: {...FespalierOtel.resourceAttributes});
}
```

Since 0.19.0, `otel: true` writes the OpenTelemetry half of that second snippet for you: the generated `main()` starts the SDK and adds `FespalierOtel` before `startup()` runs, and `zone()` stays Sentry's, so nothing wraps the app in `runGuarded`. Then `startup()` needs only the first snippet's `FespalierTelemetry.add(FespalierSentry())`, written once (`final _sentry = FespalierSentry();` at the top level and `if (!FespalierTelemetry.contains(_sentry)) FespalierTelemetry.add(_sentry);`, because Retry runs `startup()` again and `add` appends a sink each time), and the Sentry half is the same. [Generated `main()`](#opentelemetry-from-the-generated-main) has the details.

The order rules:

1. **Sentry is the outermost zone.** A zone around `SentryFlutter.init` on the web makes Sentry skip its own `runZonedGuarded`, and uncaught errors go to that zone instead. Nothing may call `WidgetsFlutterBinding.ensureInitialized()` before it.
2. **Install the sink before the router exists**, in `startup()` or in `appRunner`.
3. With `fespalier_auth`'s `restoreAuth`, install first, so the restore is reported.
4. A failure while the app starts reaches Sentry through `FlutterError.reportError`, with no extra code.

`FespalierSentry`'s options:

- `breadcrumbs: false` drops every breadcrumb but keeps the events.
- `routeTag: false` stops naming the scope after the screen (`fespalier.route` and the transaction name).
- `capture:` decides which failures are events (`FespalierSentry.unexpected` by default: all but a `FieldErrors` and an `auth` step).
- `repeatWindow:` is the 30 seconds after which the same failure is an event again (`Duration.zero`: every one).
- `recordLocations: true` adds a guard's redirect target and, with `tracing`, the committed path.

### One transaction per screen

Performance monitoring is opt-in, and it is for a team that has only Sentry. Turn it on in both places, so that the SDK samples and the sink makes the transactions:

```dart
FespalierSentry.configure(options, dsn: dsn, tracing: true); // tracesSampleRate 1.0 in debug, 0.1 in release
FespalierTelemetry.install(FespalierSentry(tracing: true));
```

Each navigation is then a `ui.load` transaction named by the route pattern, started as `navigate` (so the HTTP calls made during it have a parent) and renamed when the page is on screen.

- Guards, redirects, data loads, deferred loads and actions are its child spans.
- The first frame is the transaction's _time to initial display_ (`ui.load.initial_display`) and the arrival of the screen's last data load its _time to full display_ (`ui.load.full_display`): the two spans and measurements that Sentry's Screen Loads view reads.
- A transaction ends when its data arrives or when the next navigation starts, whichever is first (the old screen's time to full display is then `deadline_exceeded`, with no measurement): fespalier starts no timer for it. `fullDisplay: false` ends it at the first frame.

**Do not run two observers.** Sentry's own `SentryNavigatorObserver` also makes one `ui.load` per route it sees pushed: run both and every screen has **two transactions**. Use one or the other.

- With `FespalierSentry(tracing: true)` add `FespalierSentry.navigatorObserver()`, a `SentryNavigatorObserver(enableAutoTransactions: false)`, never a plain `SentryNavigatorObserver()`.
- With `transactions: false` a plain observer makes the transactions and the sink adds its data spans, time to full display, events and breadcrumbs to them (no guard, redirect or deferred span: they run before the observer's transaction exists).

**The first screen.** On Android and iOS it has a transaction already: with tracing on and Sentry's defaults, its own app start is the first screen's `ui.load` (from the process start to the first frame, with the native spans). The sink opens none for that screen, and tells it when the screen's data is in (`SentryFlutter.currentDisplay()?.reportFullyDisplayed()`); that screen's guard and data spans are not recorded. With `enableStandaloneAppStartTracing: true` (Sentry 9.26.0, experimental) app start is a trace of its own, and the first screen is an ordinary one with all its spans: **recommended** with `tracing: true`. On the web and on the desktop the first screen is an ordinary one.

With `traceLifecycle: static`, an HTTP span made inside `data()` is a child of the screen's transaction, beside the data span, and not of the data span: Sentry's HTTP integrations parent to the scope's span. (`fespalier_otel` next to it parents them to the data span.)

### Span streaming

Since 0.19.0. Sentry's `traceLifecycle` is `static` by default: a screen is a _transaction_ and the SDK sends it when it finishes. Set `options.traceLifecycle = SentryTraceLifecycle.stream` (Sentry 9.26.0 has it) and the SDK sends _spans_ one by one, as each ends, with no transaction. `FespalierSentry(tracing: true)` follows the setting: it reads it at the first navigation and makes the same tree through Sentry's streaming API.

```dart
await SentryFlutter.init((options) {
  FespalierSentry.configure(options, dsn: dsn, tracing: true);
  options.traceLifecycle = SentryTraceLifecycle.stream;
}, appRunner: () => runApp(...));
FespalierTelemetry.install(FespalierSentry(tracing: true));
```

- Each navigation is a **segment** (a root span, `sentry.op` `ui.load`, named by the route pattern, started as `navigate`). Guards, redirects, data loads, deferred loads, images, auth steps and actions are its children, with the parent given: two screens that overlap stay apart.
- Initial and full display are child spans (`ui.load.initial_display`, `ui.load.full_display`) with the attributes `app.vitals.ttid.value` and `app.vitals.ttfd.value` (milliseconds), where a transaction has measurements.
- A span's status is `ok` or `error`, the only two a streamed span has. `error` is a failure (a validation answer, a `FieldErrors`, is `ok`: the span's `fespalier.action.result` says `error`), and a screen whose data had not arrived when the next navigation started: its data span and its full display are `error`, the full display with no value. What a static span says with another status (`cancelled`, `unauthenticated`) is in the span's `fespalier.*` attributes.
- A navigation that a newer one superseded **cannot be dropped**: Sentry has no way to discard a streamed span. It is sent, named `navigate`, with `fespalier.navigation.outcome` `superseded`; filter on it in Sentry.
- An error in a streamed `data()` or action is an event whose `contexts.trace` is that span's, so Sentry links the two. An action with no screen open is a segment of its own, and an auth step with no span open makes none.
- On Android and iOS the first screen is still Sentry's app start (see above).
- The sink never uses an idle span (it starts a timer) and ends every span itself, when the screen's data arrives or the next navigation starts. A span that ends before the route is known waits for it, so each carries the segment's name (`sentry.segment.name`); Sentry's span buffer and its flush are the SDK's.
- `FespalierSentry.configure` also installs `beforeSendSpan` (the app's first), which takes `http.query`, `http.fragment` and the query of `url` off a span (`recordQueries: true` keeps them). `FespalierSentry.spanWithoutQueries` is the same function.

Every segment of a session is in the trace of the scope's propagation context, exactly as `static`'s transactions are: a screen is not a trace of its own. `SentryNavigatorObserver(enableNewTraceOnNavigation: true)` (off by default) renews the trace on each navigation, and so does the SDK after the app has been in the background, when no navigator observer exists. UNCHECKED: whether Sentry's Screen Loads and trace views are right with one trace for many screens.

What is not the same as with `static`. HTTP spans (`SentryHttpClient`, `sentry_dio`) parent to the _active_ span of the running zone, and `data()` does not run inside one yet: in this mode they make no span under the screen. The `static` lifecycle is unchanged.

### Sentry defaults and privacy

`FespalierSentry.configure(options, dsn:, ...)` is called first in `SentryFlutter.init`'s configuration; a callback the app set before it is kept and runs before its own:

| Option                                    | Set to                                                                                                                                                                                                  | Sentry's default  | Why                                                                                                                            |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `dsn`                                     | `dsn` (`''` sends nothing)                                                                                                                                                                              | none              | `const String.fromEnvironment('SENTRY_DSN')`: a build without the define is silent                                             |
| `sendDefaultPii`                          | `false`                                                                                                                                                                                                 | `false`           | explicit                                                                                                                       |
| `attachScreenshot`, `attachViewHierarchy` | `false`                                                                                                                                                                                                 | `false`           | a screenshot or a widget tree can show user data                                                                               |
| `enableAutoSessionTracking`               | `true`                                                                                                                                                                                                  | `true`            | release health                                                                                                                 |
| `tracesSampleRate`                        | `tracesSampleRate:`; with `tracing: true` and none, 1.0 in debug and profile and 0.1 in release; else untouched                                                                                         | none (no tracing) | tracing is the opt-in; 10 % in release caps the quota                                                                          |
| `enableTimeToFullDisplayTracing`          | `true` with `tracing: true`                                                                                                                                                                             | `false`           | time to full display of Sentry's app start                                                                                     |
| `tracePropagationTargets`                 | `propagateTraceTo:` (empty: no trace header leaves the app)                                                                                                                                             | `['.*']`          | `baggage` names the release, the environment, the public key and the screen: send it to your API only                          |
| `beforeBreadcrumb`                        | the app's, then the query and fragment taken off HTTP breadcrumbs (`recordQueries: true` keeps them), then `SentryNavigatorObserver`'s own breadcrumbs dropped (`observerBreadcrumbs: true` keeps them) | none              | `sentry_dio` and `SentryHttpClient` breadcrumbs carry `http.query`; this sink's page breadcrumbs say the same with the pattern |
| `beforeSend`                              | the app's, then the query and fragment taken off the event's request                                                                                                                                    | none              | a request carries `queryString`                                                                                                |
| `beforeSendTransaction`                   | the app's, then the query taken off span data (`recordQueries: true` keeps it), and a superseded navigation dropped                                                                                     | none              | HTTP spans carry `http.query`; a superseded navigation never showed a screen                                                   |
| `beforeSendSpan` (since 0.19.0)           | the app's, then the query and fragment taken off the streamed span's attributes (`recordQueries: true` keeps them)                                                                                      | none              | the same HTTP spans with `traceLifecycle: stream`, which cannot drop a superseded navigation: it is sent, marked               |

Not touched: `environment`, `release`, `dist` (Sentry derives `name@version+build`), `captureFailedRequests` and session replay (off by default).

One line is printed in a debug build, once: with `tracing: true` on an SDK that samples nothing (no transaction is sent). Before 0.19.0 a second one said that `traceLifecycle: stream` made no spans. A `tracesSampleRate` outside 0 to 1 throws an `ArgumentError`.

**What it costs.** Installed, every call is synchronous and returns at once, a sync guard or `data()` stays sync, it starts no timer and no listener (the SDK's own timers belong to the SDK, and `tracing: true` never asks for one), and every SDK call is inside a `try`, so a failing SDK costs an event, never a feature.

### Testing with Sentry

`package:fespalier_sentry/testing.dart` has `RecordingSentry`: a real Sentry `Hub` over `SentryFlutterOptions` whose transport keeps what it would send, so a test reads the naming, the tags, the fingerprint and the envelope the SDK built, with no `SentryFlutter.init`, no native SDK, no timer and no network:

```dart
testWidgets('a refused refund is an event on its route and its file', (tester) async {
  final sentry = RecordingSentry();
  FespalierTelemetry.install(FespalierSentry(hub: sentry.hub));
  final router = AppRoutes.router(initialLocation: '/orders/1');
  await pumpRouter(tester, router);
  await tester.tap(find.text('Refuse'));
  await tester.pumpAndSettle();
  await tester.pump(); // the SDK hands the event to its transport a few microtasks later
  expect(await sentry.lines(), [
    r'event StateError operation=action route=/orders/:id file=(tabs)/orders/$id/action.dart action=action',
  ]);
  expect(sentry.breadcrumbs, ['navigation enter /orders/:id']);
});
```

`lines()` is one line per transaction, span and event without timestamps or ids (`transaction ui.load /orders/:id status=ok ttid ttfd`, then one indented `span fespalier.data ...` line for each of its spans, and `event StateError operation=data ...`). With `traceLifecycle: stream` (since 0.19.0) a streamed screen reads the same way after them, as `segment ui.load /orders/:id status=ok ttid ttfd` and its children, and `spans` holds the `SentrySpanV2`s themselves, in the order they ended (each is recorded in `beforeSendSpan`: no flush and no timer; pump a frame first).

- `sent()` is the JSON the SDK built, for the tags, the fingerprint and the contexts.
- `breadcrumbs`, `tags` and `transactionName` read the scope.
- `RecordingSentry(configure: (options) => ...)` runs after the test defaults (a made-up DSN, `tracesSampleRate` 1.0): run `FespalierSentry.configure` in it to test the defaults.
- A test of `tracing: true` navigates after the first screen, because on Android and iOS Sentry's app start owns that one (pass `platform: TargetPlatform.linux` to `FespalierSentry`, a `@visibleForTesting` parameter, to avoid it).

## Crashlytics

There is no `fespalier_crashlytics` package, on purpose (since 0.9.0). Crashlytics has no spans: its integration is three calls (`recordError`, `log`, `setCustomKey`). A native crash that `otel_zone` records already names the screen it happened on (since 0.19.0): see [The screen a native crash happened on](#the-screen-a-native-crash-happened-on). The policy (skip a `FieldErrors`; tag the route and the file) is a few lines in a `FespalierTelemetry` subclass of your own:

- `end` records a non-fatal error;
- `page` logs the page change;
- a navigation's end sets the route as a custom key.

Write it with `if` chains, not a `switch` over `TelemetryOp`, so an operation added later never breaks the app's build. `FespalierTelemetry.combine([FespalierSentry(), yourSink])` sends to both.
