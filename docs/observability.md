# Observability

## Route lifecycle: `observe.dart`

Since 0.8.1, an `observe.dart` runs code when a page becomes the one the user sees, when it is on
top again, and when it is gone: analytics, logging, a window title. It observes and cannot veto
(blocking a leave is go_router's `GoRoute.onExit`, which fespalier does not wrap).

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

**The functions.** Any of `onEnter`, `onLeave` and `onFocus`, at least one, each a public top-level
function that returns `void` (written out). Other functions in the file are helpers and are ignored.

**The parameters.** An optional positional `Ref ref` first, then named parameters bound like a
[guard's](guards.md): the segments of its folder and the folders above it, typed (`required int id`);
query parameters, optional and nullable (they belong to the folder's route when it has a `page.dart`,
and otherwise to the hook alone); `Uri uri`, the page's location (the mount prefix included); and
`TypedLocation route`, the typed route of the page the hook runs for (`ProductRoute(id: 3)`), bound by
its type. `extra`, `ProviderContainer` and `WidgetRef` are errors. The `Ref` is a throwaway provider's,
closed as soon as the hook returns: `ref.read` works, and so does changing another provider
(`ref.read(views.notifier).add(...)`); `ref.watch` watches nothing that lasts.

**Which pages, and in which order.** An `observe.dart` applies to every page (`page.dart`) at and
below its folder, `nest = false` routes included. A `redirect.dart` route never stays on screen, so it
never enters. For one page, the hooks of all the files that apply run outermost folder first for
`onEnter` and `onFocus`, and innermost first for `onLeave`.

**When.** Hooks run at the end of the first frame that shows the change (a post-frame callback, never
during `build`), by comparing what the router committed with what it showed before. A page instance is
one page on a navigator: a tree page is told apart by its route and its matched location, so another
segment value is another page (`/products/1` leaves, `/products/2` enters, whatever
[`remount`](navigation.md#remounting-a-page-remount) says) and a query change is no transition at all. The page the
user sees is the top one: the last pushed page, else the leaf of the router's location.

- `onEnter`: the first time a page instance is the page the user sees.
- `onFocus`: an entered page is on top again (a page above it was popped, or its tab was shown).
- `onLeave`: an entered page is on no navigator any more. A page in a tab that is not the current one is
  _parked_, not gone: its tab keeps its stack, and it leaves when it is gone from its branch or the whole
  tab layout leaves.

`onEnter` and `onLeave` come in pairs, and `onFocus` only falls between them. On one frame the `onLeave`s
run first, newest first, then the `onEnter` or `onFocus` of the page on top.

| Navigation                             | Events                                                               |
| -------------------------------------- | -------------------------------------------------------------------- |
| boot at `/a`                           | enter `/a`                                                           |
| `go('/a/1')`, a nested page            | enter `/a/:id`; `/a` is covered, not left                            |
| `go('/a/2')` from there                | leave `/a/1`, enter `/a/2`                                           |
| `refresh()`, a rebuild, a query change | nothing                                                              |
| switch to another tab, and back        | enter its page (the first tab's page is parked), then focus          |
| `push('/x')`, then `pop()`             | enter `/x`; then leave `/x`, focus the page below                    |
| `replace('/y')` on a pushed page       | leave the old, enter the new                                         |
| a `go` that a guard redirects          | only the final location's events: the redirected-from one never ran  |
| a `go` out of a tab layout             | leave every entered page of every tab, newest first, then enter      |
| a deep link to `/products/1`           | enter `/products/1` only; `/products` enters the first time it shows |
| a location with no route               | no hooks; the previous page leaves                                   |

**Errors.** A hook that throws is caught and reported with `FlutterError.reportError` (library
`fespalier`, context `while running onEnter of products/$id/observe.dart`, the hook and the file filled
in), and the hooks after it still run. In a widget test that fails the test. **Hooks fire after the
frame**, not at `context.go()`: a test pumps first (`await tester.pump()`). No hook runs when the router
is disposed or the app is killed, and layouts and sections have none. A hook may navigate, and it is
looked at at the end of the next frame; to redirect, use a [guard](guards.md) instead. `fsp new
'orders/[id]' --observe` writes the file. An `observe.dart` with no `page.dart` at or below its folder is
a warning, and one with none of the three functions an error.

## Telemetry

Since 0.8.1, fespalier reports what it does while it routes: each navigation, guard and
`redirect.dart` decision, `data.dart` load, action run and deferred-page load, with the pages that
entered, were focused or left. fespalier has no OpenTelemetry dependency: it tells a
`FespalierTelemetry` sink, and `package:fespalier_otel` is the sink that turns it into spans on the SDK
that [`otel_zone`](https://github.com/vaam-apps/flutter-otel-zone) starts. Since 0.9.0
`package:fespalier_sentry` is the sink for [Sentry](#sentry-fespalier_sentry), errors first. A test installs a
`RecordingTelemetry` instead.

### Turning it on

Telemetry is opt-in, in two steps. In `pubspec.yaml`:

```yaml
fespalier:
  telemetry: true
```

`fsp gen` then passes a `const TelemetrySite('products/$id/data.dart', route: '/products/:id')` to each
guard, `data.dart` provider and action, gives each deferred library its page's pattern, and has
`AppRoutes.attach` follow the router (`AppRoutes.router()` calls it; an app that mounts the tree in a
`GoRouter` of its own calls `AppRoutes.attach(router)` once with that router). Since 0.9.0 each data
provider also calls `data()` inside a closure, `traceDataCall(ref, 'd4', id, () => data(ref, id: id), ...)`,
so a sink can [run it inside the span](#spans-around-data-and-actions). A value that is not a bool is an
error. Without the key, the generated file is exactly what it was before 0.8.1.

At run time nothing is reported until the app installs a sink, before `runApp` and before the router is
built, so the first navigation is reported too:

```dart
FespalierTelemetry.install(sink); // null uninstalls
```

A sink is called synchronously from the router, a provider or an action: it must return at once, must not
throw (fespalier catches what it throws and prints `fespalier telemetry: <error> (not shown again)`
once), and must not navigate or read a provider. There is one slot: a second `install` replaces the
first. To report to several sinks, [combine them](#several-sinks-combine-and-add) (since 0.9.0).

### OpenTelemetry with otel_zone

`otel_zone` is not on pub.dev: depend on it by git, pinned to a commit. Add `fespalier_otel` next to
fespalier, with the same `url` and the same `ref` (pub resolves the two to one package only if they are the
same repository dependency; a mismatch fails with `Because every version of fespalier_otel from path
depends on fespalier from git https://github.com/fespalier/fespalier at v0.7.0 in packages/fespalier and
demo depends on fespalier from git https://github.com/fespalier/fespalier at v0.6.0 in packages/fespalier,
fespalier_otel from path is forbidden.`, the form it takes when the second is a path):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.9.1
  fespalier_otel:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_otel
      ref: v0.9.1
```

<!-- x-release-please-end -->

```yaml
  otel_zone:
    git:
      url: https://github.com/vaam-apps/flutter-otel-zone
      ref: a9648533f6f8f0a6bfb341b368e8be0747b7dc21 # a commit, not a tag
```

`otel_zone` depends on `otel_go_router`, which declares `go_router: ^17.0.0`, so an app with it resolves
go_router 17 (fespalier accepts 17 and 18). An app that needs 18 adds `dependency_overrides: go_router:
^18.0.0`, as `otel_zone`'s README says. `examples/telemetry` is the one example on go_router 17.

The wiring, in `main.dart` (`examples/telemetry` is this, inside Sentry's zone since 0.9.0: see
[Sentry](#sentry-fespalier_sentry)):

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

`otel_zone` owns the zone that `WidgetsFlutterBinding.ensureInitialized()` and `runApp` run in, so both
go inside `runGuarded`. `FespalierOtel(isReady:)` emits nothing until the SDK is up, and an app that
starts the SDK itself leaves it out; `recordLocations: true` adds the committed location and a guard's
redirect target to the spans (segment and query values are app data, so it is off).
`FespalierOtel.endpoint()` is the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when there is
one; without it a debug build exports to `http://10.0.2.2:4318` on Android (the emulator's address for its
host) and `http://localhost:4318` elsewhere, and a release build gets `''`, which `otel_zone` takes as
"telemetry off", so a store build never sends to a developer's computer. A failure while the app
starts arrives through `FlutterError.reportError`.

Since 0.8.1, known limitation: otel_zone `runGuarded` on web. On the web `OtelZone.runGuarded` never runs
its body, so the app stays blank: it builds a `ReceivePort` first, which `dart:isolate` does not support
there. `start()` itself works on the web. Until `otel_zone` guards that call, run the body as it is on the
web, as `guarded` above does; the error hooks `runGuarded` installs are then not installed there.

### Several sinks: combine and add

Since 0.9.0. `install` holds one sink, so OpenTelemetry for the traces, Sentry for the crashes and an
analytics SDK for the screens would replace one another. `FespalierTelemetry.combine` makes one sink of
several, which tells each of them everything, in the order of the list:

```dart
FespalierTelemetry.install(
  FespalierTelemetry.combine([
    FespalierOtel(isReady: () => observability.isReady),
    AnalyticsTelemetry(),
  ]),
);
```

`FespalierTelemetry.add(sink)` is `install(combine([?current, sink]))`: it puts a sink next to the
installed one. Use it where two places each install a sink, such as a package's setup and the app's own
`startup()`, so that neither replaces the other. `install` still replaces everything and `install(null)`
removes everything. A second `install` that was meant to add is the usual mistake: use `add`.

- **Each sink has its own tokens.** The token a sink returns from `start` is what that sink, and only
  that sink, gets back at `end`, at `page`, in `within`, and as the `TelemetryStart.parent` of what runs
  during one of its navigations. A sink never sees another sink's token, so one sink's spans cannot become
  another sink's parents, and `FespalierOtel` keeps its navigation as the parent of its guard, data and
  deferred spans behind a `combine`.
- **Each sink is isolated.** A sink that throws does not stop the others or the app: its error is printed
  once, per sink, as `fespalier telemetry: <error> in <Sink> (not shown again)`, and it is called again at
  the next operation. A sink that has no token for an operation (it returned null from `start`) is still
  told the end, with null.
- **Nesting.** A combined sink in the list is flattened, `combine([])` reports nothing and
  `combine([sink])` is `sink`. For [`within`](#spans-around-data-and-actions) the first sink is the
  outermost.
- **Trace links.** A sink that makes OpenTelemetry spans can say which trace an operation is in: it
  overrides `traceOf(token)` to return a `TelemetryTrace(traceId, spanId)` (32 and 16 lowercase hex
  digits), and `combine` tells every other sink with `linkTrace(token, trace)`: with that sink's own token,
  once per operation, right after every sink started it and before its `within` and `end`. `FespalierOtel`
  answers `traceOf` with the span it made, and [`fespalier_sentry`](#sentry-fespalier_sentry) keeps what it
  is told and tags its events with `otel.trace_id` and `otel.span_id` (since 0.9.0). The order of the list
  does not matter, and with no sink that answers nothing is called.

### Spans around data() and actions

Since 0.9.0. A sink can make the span of a data load or an action the **current** one while `data()` or
the action runs, so that the spans an HTTP client makes inside it (after an `await` too) are its children
instead of the roots of traces of their own. fespalier calls `FespalierTelemetry.within` around them:

```dart
/// Runs [body] inside the operation [token] came from. The default calls [body].
void within(Object? token, Object? Function() body) => body();
```

`FespalierOtel` overrides it with `Context.current.withSpan(span).runSync(body)`, so what Dartastic's
`otel_http` and `otel_dio` instrument inside a `data()` or an action takes that span as its parent. A sink
of your own overrides it the same way. The rules:

- Call `body` once, synchronously, before you return. It returns what the operation returned (null when
  it threw, which `end` says), so you may observe it: hand a `Future` to a vendor API that ends a span
  when it settles. It never throws; fespalier rethrows what the operation threw after your method
  returns.
- fespalier returns the operation's **own** result, the very object, whatever `within` does: a value
  stays a value (a sync `data()` is never made a `Future`, and no microtask is scheduled), and a `Future`
  is the one Riverpod awaits. A sink cannot replace it. `body` runs exactly once, even for a sink that
  never calls it, calls it twice or throws.
- Run `body` in a zone you make with zone values only (`runZoned(body, zoneValues: {...})`). **Never give
  that zone an error handler** (`runZonedGuarded`, `onError:`, a `ZoneSpecification` with
  `handleUncaughtError`): a `Future` that fails in another error zone never reaches Riverpod, and the
  page would stay on its loading view. fespalier refuses such a zone at run time: it runs `body` in the
  caller's zone instead and prints, once, `fespalier telemetry: <Sink>.within changed the error zone, so
  data() and actions run outside it (use runZoned with zoneValues, not runZonedGuarded) (not shown
  again)`.
- Behind a `combine`, each sink's `within` runs the next one's, so every sink's scope wraps `data()`, and
  each sees what it returned.
- Guards and deferred loads do not get `within`: a guard must stay cheap and a deferred load runs no app
  code.

`FespalierTelemetry.run(token, body)` is the same thing for an adapter package that starts operations of
its own with `FespalierTelemetry.begin`: `body` runs once, synchronously, and what it returns or throws
comes back. With no sink, or a null token, it is `body()`.

Since 0.9.0 the generated data provider of an app made with `telemetry: true` is
`traceDataCall(ref, 'd4', id, () => data(ref, id: id), telemetry: ...)`, and the data span starts
**before** `data()` runs. What that changes for an app that already had telemetry:

- `app.g.dart` gains the closure on each data provider (regenerate with `fsp gen`): one closure per
  provider build, with no `Future` and no microtask. An app without `telemetry: true` keeps
  `traceData(...)`, and its file does not change.
- A `data` span's duration now includes the synchronous part of `data()`.
- A `data()` that throws before it returns now has a `data` span, with `fespalier.data.state = error`
  and `fespalier.async = false`; before 0.9.0 it had none.
- `FespalierOtel` makes data and action spans current, so the HTTP spans of `otel_http` and `otel_dio` are
  their children. A sink of your own that already had a member named `within` with another signature must
  rename it.

### Where a navigation came from: navigateFrom

Since 0.9.0. A navigation that starts from a tap on a notification, a home-screen shortcut or widget, or a
link a bridge handed over looks like any other `go` to fespalier. `navigateFrom` marks it:

```dart
// The app is running: a tap on a notification.
navigateFrom(NavigationSource.notification, () => router.go('/orders/42'));

// A cold start from the same tap: the router's initial location is the launch.
final router = navigateFrom(
  NavigationSource.notification,
  () => AppRoutes.router(initialLocation: '/orders/42'),
);
```

`NavigationSource` has `notification`, `shortcut`, `widget` and `link`. Telemetry reports the mark as
`TelemetryStart.source` and, in `FespalierOtel`, as the attribute `fespalier.navigation.source` of the
`navigate` span; a navigation the app's own code started has none. Nothing else changes: guards run as
for any link, and `fespalier.navigation.kind` still says how the stack changed (a cold start is `initial`,
a warm one `go` or `push`).

- The closure runs once, synchronously, and what it returns is returned. The mark is taken by the **first**
  navigation the closure starts and is dropped when the closure returns, so it cannot reach a later one.
  A closure that starts no navigation, or goes where the router already is, leaves nothing behind.
- fespalier never sets it by itself: a platform deep link and the browser's back button look the same to
  it as any other navigation. The bridge that knows (a notification handler) calls `navigateFrom`.
- A source that is not one of the four values is an `AssertionError` in debug: ``navigateFrom: `banner`
  is not a NavigationSource value (notification, shortcut, widget or link)``.
- `RecordingTelemetry` writes it as `source=notification` on the start line of the navigation, and only
  when it is set.

### Telemetry conventions

This section is **contract version 1**: dashboards and alerts are built on it. Within version 1 a change
may only add (a new attribute, a new event, a new value of an enum-like attribute, announced in the
changelog); renaming or removing a name or a value, or changing the meaning or unit of an attribute, is
version 2, which bumps `fespalier.telemetry.version` and is a breaking release.
`packages/fespalier_otel/test/conventions_test.dart` holds every name below as a string literal, so a
rename fails a test before it ships. The names follow OpenTelemetry's semantic conventions where they
exist (`service.*`, `url.*`, `error.type`, `exception.*`, span status) and use the `fespalier.` prefix
for the rest.

**Resource attributes**, fixed when the SDK starts:

| Key                           | Value                                            | Set by                                     |
| ----------------------------- | ------------------------------------------------ | ------------------------------------------ |
| `service.name`                | the app's name                                   | `OtelZoneConfig.serviceName`               |
| `service.version`             | the app's version                                | `otel_zone` `start(serviceVersion:)`       |
| `app.build_id`                | the build number                                 | `otel_zone` `start(buildId:)`              |
| `deployment.environment.name` | e.g. `production`                                | `OtelZoneConfig.deploymentEnvironmentName` |
| `fespalier.version`           | the fespalier release, e.g. `0.8.1`              | `FespalierOtel.resourceAttributes`         |
| `fespalier.telemetry.version` | `1` (a string): the version of these conventions | `FespalierOtel.resourceAttributes`         |

**Scope.** Every span is made by the instrumentation scope `fespalier`, whose version is the fespalier
release. To pick fespalier's spans out of a service's, filter on `fespalier.operation` (a backend that
does not keep the scope on spans, like OpenObserve, has no scope column to filter on).

**Spans.** Every span is `SpanKind.internal` and carries `fespalier.operation`. A span's duration is its
own (end minus start), so no attribute repeats it; for `navigate` it is _requested to first frame_:
redirects, async guards, the build of the new page and its first-frame loads.

| `fespalier.operation` | Span name                                                              | Starts                                                                                                                                      | Ends                                                                                                              | Parent                                           |
| --------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `navigate`            | `navigate {route}`; `navigate (not found)`; `navigate` when superseded | a location is requested (`go`, `push`, `replace`, a tab switch, a deep link), a pop or a guard's refresh commits, or the router is attached | the end of the first frame rendered after the commit, or when a newer navigation starts before this one committed | none (a root span)                               |
| `guard`               | `guard {file}`, e.g. `guard (members)/guard.dart`                      | the guard returned                                                                                                                          | the answer is known (sync: at once; async: when its `Future` settles)                                             | the pending `navigate`, else the current context |
| `redirect`            | `redirect {file}`                                                      | as `guard`                                                                                                                                  | as `guard`                                                                                                        | as `guard`                                       |
| `data`                | `data {file}`, e.g. `data products/$id/data.dart`                      | the provider of a `data.dart` runs `data()` (since 0.9.0: before it runs, and the span is the current one while it runs)                    | the value is there, its `Future` settles, or the provider is disposed first; a `Stream` ends at once              | the pending `navigate`, else the current context |
| `action`              | `action {file}#{name}`                                                 | `ActionNotifier.call` (since 0.9.0 the span is the current one while the function runs)                                                     | the result is there, or its `Future` settles                                                                      | the current context (usually none)               |
| `deferred`            | `deferred {file}`                                                      | `DeferredLibrary.load()` starts a load (not one that joins a load in flight)                                                                | the load completes or fails                                                                                       | the pending `navigate`, else the current context |
| `auth`                | `auth {operation}`, e.g. `auth refresh` (since 0.9.0)                  | `restoreAuth`, `signIn` or `adopt`, a refresh, `signOut` (`fespalier_auth`)                                                                 | the outcome is known                                                                                              | the current context (usually none)               |
| `image`               | `image {cdn}`, e.g. `image emgr` (since 0.9.0)                         | a network image starts loading (`fespalier_image`: a widget or a precache; not a cache hit, and not a load already in flight)               | the image is decoded, or the load fails                                                                           | the navigation in progress, if there is one      |

A span's status is `Error` (with the exception's text) exactly when its outcome attribute is `error`; a
`not_found` navigation is not an error, and neither is an `auth` span that ends `rejected` or `cancelled`.
An `auth` span that ends `error` has the status and `error.type`, but never the exception's text, which
can name a host. An `image` span that ends `error` has the status and, when the load carries one,
`fespalier.image.status`; the exception's text is never recorded, since it holds the URL.

**Events.** On one `navigate` span the order is every `leave`, most recently entered first, then one
`enter` or `focus`. The page events fire whether or not the app has an `observe.dart`.

| Event                  | On                                                                              | When                                                       | Attributes                                                    |
| ---------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------- |
| `fespalier.page.enter` | the `navigate` span that caused it                                              | a page instance became the visible page for the first time | `fespalier.route`                                             |
| `fespalier.page.focus` | the same                                                                        | an entered page is the visible page again                  | `fespalier.route`                                             |
| `fespalier.page.leave` | the same                                                                        | an entered page is gone                                    | `fespalier.route`, `fespalier.page.duration_ms`               |
| `exception` (semconv)  | a `guard`, `redirect`, `data`, `action` or `deferred` span with outcome `error` | the operation threw or its `Future` failed                 | `exception.type`, `exception.message`, `exception.stacktrace` |

**Attributes on every span:**

| Key                   | Type   | Values and meaning                                                                                                                                                                                      |
| --------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.operation` | string | `navigate`, `guard`, `redirect`, `data`, `action`, `deferred`, `auth` or `image`                                                                                                                        |
| `fespalier.route`     | string | the route pattern, as `fsp routes` prints it and `AppManifest.byPath` keys it: `/`, `/products/:id`, `/docs/*rest`. Absent when not found. For a section's data or action, the section folder's pattern |
| `fespalier.file`      | string | the app file, relative to the app folder, as spelled on disk: `products/$id/data.dart`. Absent on `navigate`                                                                                            |
| `fespalier.async`     | bool   | whether the operation returned a `Future` (`guard`, `redirect`, `data`, `action`, `auth`)                                                                                                               |
| `error.type`          | string | semconv: on an error, the exception's class (minified on a release web build)                                                                                                                           |

**On a `navigate` span:**

| Key (`navigate`)                  | Type   | Values and meaning                                                                                                                                                                                        |
| --------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.navigation.kind`       | string | `initial`, `go`, `push`, `pop`, `replace` or `refresh` (the classification DevTools shows); absent when superseded                                                                                        |
| `fespalier.navigation.outcome`    | string | `ok`, `not_found` or `superseded`                                                                                                                                                                         |
| `fespalier.navigation.from`       | string | the pattern of the page that was on top before (absent at the start)                                                                                                                                      |
| `fespalier.navigation.redirected` | bool   | the committed path differs from the requested one: a guard or a `redirect.dart` sent it elsewhere                                                                                                         |
| `fespalier.navigation.depth`      | int    | how many pushed pages the stack holds after the commit (0 for a plain `go`)                                                                                                                               |
| `fespalier.navigation.source`     | string | since 0.9.0: where it came from when the app's own code did not start it: `notification`, `shortcut`, `widget` or `link` ([`navigateFrom`](#where-a-navigation-came-from-navigatefrom)); absent otherwise |
| `url.path`, `url.query`           | string | semconv: the committed location, mount prefix included. Only with `recordLocations: true`                                                                                                                 |

**On the other spans and events:**

| Key                                                      | Type   | Values and meaning                                                                                                                                                   |
| -------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.guard.decision` (`guard`, `redirect`)         | string | `pass`, `redirect`, `error` or `skipped` (a segment it asks for did not parse, so it did not run); a `redirect` span is `redirect` or `error`                        |
| `fespalier.guard.location`                               | string | where it redirected to. Only with `recordLocations: true`                                                                                                            |
| `fespalier.data.state` (`data`)                          | string | `data`, `error`, `stream` (a `Stream` was returned: not listened to, so the span ends at once) or `disposed` (the provider was disposed before its `Future` settled) |
| `fespalier.data.keyed`                                   | bool   | the provider is a family; the key itself is never recorded                                                                                                           |
| `fespalier.action.name` (`action`)                       | string | the function's name in `action.dart`                                                                                                                                 |
| `fespalier.action.result`                                | string | `ok` or `error`                                                                                                                                                      |
| `fespalier.deferred.result` (`deferred`)                 | string | `ok` or `error`                                                                                                                                                      |
| `fespalier.page.duration_ms` (on `fespalier.page.leave`) | int    | milliseconds from that instance's enter to its leave, covered time included                                                                                          |

**On an `auth` span** (since 0.9.0; `fespalier_auth`; no new contract version, as a new operation and its
attributes only add):

| Key                        | Type   | Values and meaning                                                                                                                                                                                                                                                                                   |
| -------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.auth.operation` | string | `restore` (the stored session was read at start-up), `sign_in` (also a session the app adopted), `refresh` or `sign_out`                                                                                                                                                                             |
| `fespalier.auth.result`    | string | `ok`; `none` (restore: nothing was stored); `expired` (restore: the stored refresh token had expired, or the device key is gone); `rejected` (the server refused: wrong credentials, or a refresh token it no longer accepts); `cancelled` (the user closed the sign-in); `error` (it could not run) |
| `fespalier.auth.backend`   | string | the backend's short constant name: `oidc`, `firebase`, `fake`, or an app's own                                                                                                                                                                                                                       |
| `fespalier.auth.trigger`   | string | refresh only: `expired` (before a request), `unauthorized` (after a 401) or `forced`                                                                                                                                                                                                                 |
| `fespalier.auth.dpop`      | bool   | the backend binds its tokens with DPoP                                                                                                                                                                                                                                                               |

**On an `image` span** (since 0.9.0; `fespalier_image`; no new contract version, as a new operation and its
attributes only add):

| Key                       | Type   | Values and meaning                                                                                                                  |
| ------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.image.cdn`     | string | the URL builder's name: `imgproxy`, `emgr`, `cloudinary`, `imgix`, `thumbor`, `template`, `srcset`, `direct`, or a builder's own    |
| `fespalier.image.width`   | int    | the width asked for, in physical pixels (a bucket)                                                                                  |
| `fespalier.image.preload` | bool   | a precache started the load, not a widget                                                                                           |
| `fespalier.image.result`  | string | `ok` or `error`                                                                                                                     |
| `fespalier.image.status`  | int    | the HTTP status of a failed load, when the error carries one                                                                        |

**Metrics.** fespalier emits none: `otel_zone` turns metrics off on purpose (a periodic reader is a timer
that keeps the radio busy), and rates and latencies are on the wire as spans already. Derive metrics in the
collector with the `spanmetrics` connector, with `fespalier.operation`, `fespalier.route`,
`fespalier.navigation.kind`, `fespalier.navigation.outcome`, `fespalier.guard.decision`,
`fespalier.data.state`, `fespalier.action.name`, `fespalier.action.result`, `fespalier.deferred.result`
and `fespalier.file` as dimensions, next to the resource's `service.name`, `service.version` and
`fespalier.version`. A data attempt, a data source, an action rolled back and an action rejected by
validation are not recorded in 0.8.1. The `fespalier.auth.*` attributes are not dimensions of the
collector `fsp telemetry` starts yet (since 0.9.0): its dashboards label an `auth` span as a
session operation, and nothing more. Nor is `fespalier.navigation.source` (since 0.9.0): the bundled stack
keeps it as a span column, with no panel and no spanmetrics dimension of its own yet. The same goes for
`fespalier.image.*` (since 0.9.0): span columns, no panel, no dimension; a failed image load is on the
Errors dashboard under "Image load".

**Never recorded.** Segment and query values (unless `recordLocations: true`), family keys, `extra`, action
inputs and results, data values and guard inputs; and, from `fespalier_auth`, tokens, user ids, claims, user
names, e-mails, issuer and endpoint URLs, DPoP proofs and key thumbprints; and, from `fespalier_image`, an image's
URL, source and signature. What is recorded is a route pattern, a file path, a
function name or an enum-like value, all fixed when the app is built, and exception text, which
`otel_zone` scrubs (`redact`) as it scrubs every span string.

### Testing telemetry

`package:fespalier/testing.dart` has `RecordingTelemetry`, a sink that keeps what it is told as lines to
compare. Install it in `setUp` and uninstall it in `tearDown`:

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

Each operation is `#n`, which ties its `start` line to its `end` line and names the navigation it ran
under (`parent=#2`). A navigation that `navigateFrom` marked has `source=notification` at the end of its
start line (since 0.9.0), and `RecordingTelemetry(recordWithin: true)` also writes `#n within enter` and
`#n within exit` around what runs inside a `data()` or an action, so a test can see a call run within its
operation. An `image` operation (since 0.9.0) is `#4 start image emgr w=640 preload` and, when it ends,
`#4 end image ok async` or `#5 end image error async status=404`: the builder's name and the width, never the
URL. To see real spans, initialise the SDK in `setUpAll` with `SimpleSpanProcessor` and
`InMemorySpanExporter` from `package:dartastic_opentelemetry/testing.dart`, install `FespalierOtel()`, and
read the exporter after a `pump()`: a span is exported when it ends. `OTel.initialize` runs once per
isolate, so once per test file. `examples/telemetry/test/` does both.

### What it costs

**Off, nothing.** An app without `telemetry: true` and without an `observe.dart` generates the same file
as before, and its release build carries none of it: no call site passes a site, so the telemetry
parameter of each wrapper is null and the code behind it is not compiled in (CI greps a release web build
for the line `fespalier telemetry`, which only that code prints). **Sync stays sync.** fespalier never
creates a `Future`, a microtask or a timer for telemetry: a sync guard, `data()` or action is reported with
its start and its end in the same call stack, an async one through a side listener on the very `Future`
(which handles its own error, so it cannot make an unhandled one), and the wrappers return the very object
they were given. What does schedule microtasks is the OpenTelemetry SDK itself, whose span processors are
`async` methods: they run when a span starts or ends, never in the path of a value the app gets. A
backgrounded app draws no frames, so a navigation made in the background ends its span at the next frame
after the app resumes. Since 0.9.0 a telemetry app's data providers call `data()` through
`traceDataCall`, which costs one closure per provider build (an app without `telemetry: true` has none).

## Sentry: fespalier_sentry

Since 0.9.0. `package:fespalier_sentry` is the `FespalierTelemetry` sink for [Sentry](https://sentry.io), and
it is **errors first**: out of the box it sends what a team that debugs a production app asks for, and
leaves performance monitoring to the teams that want it.

- **Every error and crash, with where it happened.** An error that a guard, a `data.dart`, an action or a
  deferred load threw is a Sentry event tagged with the route pattern (`/products/:id`, never the URL), the
  app file (`products/$id/data.dart`) and, for an action, its function name, grouped by that file and not
  by the Riverpod frames on top of the stack. The screen is also the scope's *transaction* name, the field
  Sentry's issue list groups and searches by, so a crash that no fespalier operation reported says which
  screen it happened on too.
- **One breadcrumb per page change**, from the pattern of the page that was left to the pattern of the page
  that is shown, so a report reads as the path the user took.
- **Release health.** Sessions, crash-free users and crash-free sessions are the SDK's; a handled error
  marks its session *errored*.
- **A link to the OpenTelemetry trace.** Next to `fespalier_otel` (installed together with
  [`FespalierTelemetry.combine`](#several-sinks-combine-and-add)), each event carries `otel.trace_id` and
  `otel.span_id`: the trace of the span the failing call made, or, for a crash, of the navigation that
  opened the screen. Search the trace id in your OpenTelemetry backend to see what the app did.

Screen-load transactions, spans for guards, data loads and actions, and time to full display are opt-in
(`FespalierSentry(tracing: true)`), for a team that has only Sentry: with `fespalier_otel` the traces are
there already. fespalier has no Sentry dependency: `SentryFlutter.init` still starts the SDK, which owns
the crash capture, the sessions, the native integrations and the transport, and this package only tells it
what the router knows. Add it next to fespalier, with the same `url` and the same `ref` (as for
`fespalier_otel`):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.9.1
  fespalier_sentry:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_sentry
      ref: v0.9.1
```

<!-- x-release-please-end -->

The app also depends on `sentry_flutter` for `SentryFlutter.init`, in the range this package accepts:
`>=9.26.0 <10.0.0`.

An error, from the call that failed to sentry.io (every arrow into the sink is a plain synchronous call; every
SDK call that returns a `Future` is fired and forgotten):

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
| an `image` that fails (`fespalier_image`)                               | a breadcrumb `image emgr error status=404`, never the URL                                                                                                                                     | a span `fespalier.image`, a child of the navigation in progress                                         |
| a committed navigation                                                  | the scope's transaction name is the pattern, the tag `fespalier.route` too; with `fespalier_otel`, the tags `otel.trace_id` and `otel.span_id`                                                | a `ui.load` transaction named by the pattern, with `time_to_initial_display` and `time_to_full_display` |
| a page `enter` or `focus`                                               | one breadcrumb, type `navigation`, `from` and `to` patterns (a leave is no breadcrumb: a page change is one)                                                                                  | —                                                                                                       |
| a location that matched no route                                        | a warning breadcrumb `not found`, the transaction name `navigate (not found)`, no route tag                                                                                                   | a transaction with that name                                                                            |
| a guard or `redirect.dart` that redirects                               | a breadcrumb `redirect by checkout/guard.dart` (the target only with `recordLocations: true`)                                                                                                 | spans `fespalier.guard` and `fespalier.redirect`                                                        |
| an action that works                                                    | a breadcrumb `items/$id/action.dart#rename ok`, never its input or its result                                                                                                                 | a span `fespalier.action`, a child of the open screen's transaction or a transaction of its own         |
| a `data` load, a `deferred` load                                        | nothing                                                                                                                                                                                       | spans `fespalier.data` and `fespalier.deferred`; the screen ends when its last data load does           |
| a pop, a refresh                                                        | a breadcrumb and the scope's name                                                                                                                                                             | no transaction: they show a page that is already built                                                  |
| a navigation that a newer one superseded                                | nothing                                                                                                                                                                                       | not sent                                                                                                |

The keys are the telemetry conventions' names (contract version 1), so a search in Sentry and a query in
OpenObserve use the same words. How they map onto Sentry is documented with this package and is not part of
contract version 1.

What leaves the app, and what never does:

| Sent                                                                                 | Never sent by `fespalier_sentry`                                                                                                                      |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| route patterns, app file paths, action function names, enum-like outcomes, durations | segment values, query values (`recordLocations: true` adds only the committed **path**), family keys, `extra`, action inputs and results, data values |
| the exception, its type and its stack                                                | a `FieldErrors`                                                                                                                                       |

Exception **text** is the app's: Sentry sends it as it is, so redact what your app knows to be sensitive in
`options.beforeSend`, as with any Sentry app.

### Wiring Sentry

Sentry starts first: its `appRunner` runs the binding, `startup()` and `runApp`, so crashes are Sentry's. In
`lib/app/startup.dart`:

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
void startup() => FespalierTelemetry.install(FespalierSentry());

/// Release health on the web needs it; it makes no transaction.
List<NavigatorObserver> get routerObservers => [
  if (kIsWeb) FespalierSentry.navigatorObserver(),
];
```

Next to OpenTelemetry (`otel_zone`), install both in the one slot. Do **not** also use `OtelZone.runGuarded`:
its zone sends an uncaught async error to Talker only, and Sentry would never see it (it is also blank on the
web); start the SDK with `observability.start()` in `startup()` instead:

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

1. **Sentry is the outermost zone.** A zone around `SentryFlutter.init` on the web makes Sentry skip its own
   `runZonedGuarded`, and uncaught errors go to that zone instead. Nothing may call
   `WidgetsFlutterBinding.ensureInitialized()` before it.
2. **Install the sink before the router exists**, in `startup()` or in `appRunner`.
3. With `fespalier_auth`'s `restoreAuth`, install first, so the restore is reported.
4. A failure while the app starts reaches Sentry through `FlutterError.reportError`, with no extra code.

`FespalierSentry`'s options: `breadcrumbs: false` drops every breadcrumb but keeps the events;
`routeTag: false` stops naming the scope after the screen (`fespalier.route` and the transaction name);
`capture:` decides which failures are events (`FespalierSentry.unexpected` by default: all but a
`FieldErrors` and an `auth` step); `repeatWindow:` is the 30 seconds after which the same failure is an
event again (`Duration.zero`: every one); `recordLocations: true` adds a guard's redirect target and, with
`tracing`, the committed path.

### One transaction per screen

Performance monitoring is opt-in, and it is for a team that has only Sentry. Turn it on in both places, so
that the SDK samples and the sink makes the transactions:

```dart
FespalierSentry.configure(options, dsn: dsn, tracing: true); // tracesSampleRate 1.0 in debug, 0.1 in release
FespalierTelemetry.install(FespalierSentry(tracing: true));
```

Each navigation is then a `ui.load` transaction named by the route pattern, started as `navigate` (so the HTTP
calls made during it have a parent) and renamed when the page is on screen; guards, redirects, data loads,
deferred loads and actions are its child spans; the first frame is the transaction's *time to initial
display* (`ui.load.initial_display`) and the arrival of the screen's last data load its *time to full
display* (`ui.load.full_display`), the two spans and measurements that Sentry's Screen Loads view reads. A
transaction ends when its data arrives or when the next navigation starts, whichever is first (the old
screen's time to full display is then `deadline_exceeded`, with no measurement): fespalier starts no timer
for it. `fullDisplay: false` ends it at the first frame.

Sentry's own `SentryNavigatorObserver` also makes one `ui.load` per route it sees pushed: run both and every
screen has **two transactions**. Use one or the other. With `FespalierSentry(tracing: true)` add
`FespalierSentry.navigatorObserver()`, a `SentryNavigatorObserver(enableAutoTransactions: false)`, never a
plain `SentryNavigatorObserver()`; with `transactions: false` a plain observer makes the transactions and
the sink adds its data spans, time to full display, events and breadcrumbs to them (no guard, redirect or
deferred span: they run before the observer's transaction exists).

The first screen on Android and iOS has a transaction already: with tracing on and Sentry's defaults, its own
app start is the first screen's `ui.load` (from the process start to the first frame, with the native spans).
The sink opens none for that screen, and tells it when the screen's data is in
(`SentryFlutter.currentDisplay()?.reportFullyDisplayed()`); that screen's guard and data spans are not
recorded. With `enableStandaloneAppStartTracing: true` (Sentry 9.26.0, experimental) app start is a trace of
its own, and the first screen is an ordinary one with all its spans: **recommended** with `tracing: true`.
On the web and on the desktop the first screen is an ordinary one.

An HTTP span made inside `data()` is a child of the screen's transaction, beside the data span, and not
of the data span: Sentry's HTTP integrations parent to the scope's span. (`fespalier_otel` next to it
parents them to the data span.)

### Sentry defaults and privacy

`FespalierSentry.configure(options, dsn:, ...)` is called first in `SentryFlutter.init`'s configuration; a
callback the app set before it is kept and runs before its own:

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

Not touched: `environment`, `release`, `dist` (Sentry derives `name@version+build`), `captureFailedRequests`
and session replay (off by default). Two lines are printed in a debug build, once: with `tracing: true` on
an SDK whose `traceLifecycle` is `stream` (this version makes no spans for it; the events and breadcrumbs are
still sent), and with `tracing: true` on an SDK that samples nothing (no transaction is sent). A
`tracesSampleRate` outside 0 to 1 throws an `ArgumentError`. **What it costs:** not installed, nothing: no
code of it runs and `app.g.dart` is the same bytes. Installed, every call is synchronous and returns at once,
a sync guard or `data()` stays sync, it starts no timer and no listener (the SDK's own timers belong to the
SDK, and `tracing: true` never asks for one), and every SDK call is inside a `try`, so a failing SDK costs an
event, never a feature.

### Testing with Sentry

`package:fespalier_sentry/testing.dart` has `RecordingSentry`: a real Sentry `Hub` over `SentryFlutterOptions`
whose transport keeps what it would send, so a test reads the naming, the tags, the fingerprint and the
envelope the SDK built, with no `SentryFlutter.init`, no native SDK, no timer and no network:

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

`lines()` is one line per transaction, span and event without timestamps or ids (`transaction ui.load
/orders/:id status=ok ttid ttfd`, then one indented `span fespalier.data ...` line for each of its spans, and
`event StateError operation=data ...`); `sent()`
is the JSON the SDK built, for the tags, the fingerprint and the contexts; `breadcrumbs`, `tags` and
`transactionName` read the scope. `RecordingSentry(configure: (options) => ...)` runs after the test defaults
(a made-up DSN, `tracesSampleRate` 1.0): run `FespalierSentry.configure` in it to test the defaults. A test
of `tracing: true` navigates after the first screen, because on Android and iOS Sentry's app start owns
that one (pass `platform: TargetPlatform.linux` to `FespalierSentry`, a `@visibleForTesting` parameter, to
avoid it). `examples/telemetry/test/sentry_test.dart` does this next to the OpenTelemetry SDK's in-memory
exporter.

## Crashlytics

Since 0.9.0 there is no `fespalier_crashlytics` package, on purpose. Crashlytics has no spans: its
integration is three calls (`recordError`, `log`, `setCustomKey`), and the policy (skip a `FieldErrors`; tag the
route and the file) is a few lines in a `FespalierTelemetry` subclass of your own whose `end` records a
non-fatal error, whose `page` logs the page change and whose navigation end sets the route as a custom key.
It uses `if` chains and not a `switch` over `TelemetryOp`, so an operation added later never breaks the app's
build, and `FespalierTelemetry.combine([FespalierSentry(), yourSink])` sends to both.
