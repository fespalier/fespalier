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

### OpenTelemetry with otel_zone

`otel_zone` is not on pub.dev: depend on it by git, pinned to a commit. Add `fespalier_otel` next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.15.0
  fespalier_otel:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_otel
      ref: v0.15.0
```

<!-- x-release-please-end -->

```yaml
otel_zone:
  git:
    url: https://github.com/vaam-apps/flutter-otel-zone
    ref: a9648533f6f8f0a6bfb341b368e8be0747b7dc21 # a commit, not a tag
```

`otel_zone` depends on `otel_go_router`, which declares `go_router: ^17.0.0`, so an app with it resolves go_router 17 (fespalier accepts 17 and 18). An app that needs 18 adds `dependency_overrides: go_router: ^18.0.0`, as `otel_zone`'s README says. `examples/telemetry` is on go_router 17.

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
  FespalierTelemetry.install(FespalierOtel(isReady: () => observability.isReady));
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

**Each sink has its own tokens.** The token a sink returns from `start` is what only that sink gets back at `end`, at `page`, in `within` and as the `TelemetryStart.parent` of what runs during its navigations. One sink's spans never become another's parents, and `FespalierOtel` keeps its navigation as the parent of its guard, data and deferred spans behind a `combine`.
**Each sink is isolated.** A sink that throws does not stop the others or the app: its error is printed once per sink (`fespalier telemetry: <error> in <Sink> (not shown again)`) and it is called again at the next operation. A sink with no token for an operation (`start` returned null) is still told the end, with null.
**Nesting.** A combined sink in the list is flattened, `combine([])` reports nothing and `combine([sink])` is `sink`. For [`within`](#spans-around-data-and-actions) the first sink is the outermost.
**Trace links.** A sink that makes OpenTelemetry spans overrides `traceOf(token)` to return a `TelemetryTrace(traceId, spanId)` (32 and 16 lowercase hex digits). `combine` then tells every other sink with `linkTrace(token, trace)`, with that sink's own token, once per operation, after every sink started it and before `within` and `end`. `FespalierOtel` answers `traceOf` with the span it made, and [`fespalier_sentry`](#sentry-fespalier_sentry) tags its events with `otel.trace_id` and `otel.span_id`. List order does not matter; with no sink that answers, nothing is called.

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
Since 0.11.0, with `launchRouter(..., links: true)` (what the generated `AppRoutes.router` passes for an app with `telemetry: true` or adapters), fespalier marks a platform link `NavigationSource.link` by itself, at cold start and while running (never on the web); see [Opening the app](navigation.md#opening-the-app-launches-and-platform-links). Anything else (the browser's back button, a notification tap) looks like any other navigation: the bridge that knows calls `navigateFrom`, and an adapter's `launch()` covers the cold start.

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

To see real spans, initialise the SDK in `setUpAll` with `SimpleSpanProcessor` and `InMemorySpanExporter` from `package:dartastic_opentelemetry/testing.dart`, install `FespalierOtel()`, and read the exporter after a `pump()`: a span is exported when it ends. `OTel.initialize` runs once per isolate, so once per test file. `examples/telemetry/test/` does both.

### What it costs

An app without `telemetry: true` and without an `observe.dart` generates no telemetry code, and its release build carries none of it: no call site passes a site, so the telemetry parameter of each wrapper is null and the code behind it is not compiled in.

With a sink installed, fespalier never creates a `Future`, a microtask or a timer for telemetry:

- a sync guard, `data()` or action is reported with its start and its end in the same call stack;
- an async one is reported through a side listener on the very `Future` (which handles its own error, so it cannot make an unhandled one);
- the wrappers return the very object they were given.

What does schedule microtasks is the OpenTelemetry SDK itself, whose span processors are `async` methods: they run when a span starts or ends, never in the path of a value the app gets. A backgrounded app draws no frames, so a navigation made in the background ends its span at the next frame after the app resumes.

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
      ref: v0.15.0
  fespalier_sentry:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_sentry
      ref: v0.15.0
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

An HTTP span made inside `data()` is a child of the screen's transaction, beside the data span, and not of the data span: Sentry's HTTP integrations parent to the scope's span. (`fespalier_otel` next to it parents them to the data span.)

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

Not touched: `environment`, `release`, `dist` (Sentry derives `name@version+build`), `captureFailedRequests` and session replay (off by default).

Two lines are printed in a debug build, once: with `tracing: true` on an SDK whose `traceLifecycle` is `stream` (this version makes no spans for it; the events and breadcrumbs are still sent), and with `tracing: true` on an SDK that samples nothing (no transaction is sent). A `tracesSampleRate` outside 0 to 1 throws an `ArgumentError`.

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

`lines()` is one line per transaction, span and event without timestamps or ids (`transaction ui.load /orders/:id status=ok ttid ttfd`, then one indented `span fespalier.data ...` line for each of its spans, and `event StateError operation=data ...`).

- `sent()` is the JSON the SDK built, for the tags, the fingerprint and the contexts.
- `breadcrumbs`, `tags` and `transactionName` read the scope.
- `RecordingSentry(configure: (options) => ...)` runs after the test defaults (a made-up DSN, `tracesSampleRate` 1.0): run `FespalierSentry.configure` in it to test the defaults.
- A test of `tracing: true` navigates after the first screen, because on Android and iOS Sentry's app start owns that one (pass `platform: TargetPlatform.linux` to `FespalierSentry`, a `@visibleForTesting` parameter, to avoid it).

## Crashlytics

There is no `fespalier_crashlytics` package, on purpose (since 0.9.0). Crashlytics has no spans: its integration is three calls (`recordError`, `log`, `setCustomKey`). The policy (skip a `FieldErrors`; tag the route and the file) is a few lines in a `FespalierTelemetry` subclass of your own:

- `end` records a non-fatal error;
- `page` logs the page change;
- a navigation's end sets the route as a custom key.

Write it with `if` chains, not a `switch` over `TelemetryOp`, so an operation added later never breaks the app's build. `FespalierTelemetry.combine([FespalierSentry(), yourSink])` sends to both.
