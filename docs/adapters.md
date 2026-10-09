# Adapters in the generated `main()`

Since 0.9.0 a package can plug into the [generated `main()`](app-startup.md) with one line in
`pubspec.yaml`, instead of code you write in `startup.dart`:

```yaml
dependencies:
  my_tools: ^1.0.0 # a package that ships lib/fespalier_adapter.dart
  my_reporter: ^1.0.0
fespalier:
  adapters: [my_tools, my_reporter] # Dart package names, in order
```

**The convention.** `fsp` has no table of packages and reads no manifest. For each name `n` it imports
`package:n/fespalier_adapter.dart` and calls its top-level `adapter`, a `FespalierAdapter` from
`package:fespalier/startup.dart`. The output depends on the pubspec alone, never on `pub get` or the pub
cache, so `fsp check` gives the same bytes before and after it. A package of your own can be an adapter:

```dart
// package:my_tools/fespalier_adapter.dart
import 'package:fespalier/startup.dart';

const adapter = MyToolsAdapter();

class MyToolsAdapter extends FespalierAdapter {
  const MyToolsAdapter();

  @override
  List<ProviderObserver> providerObservers() => [MyObserver()];
}
```

The adapters on the [roadmap](../ROADMAP.md) (error reporting, analytics, notification and shortcut
launches, ...) are packages of this kind; `fespalier_push` (since 0.13.0) is the first, see [Push notifications](push.md), `fespalier_analytics` is a sink installed in `beforeRun`, see [Analytics](analytics.md), and `fespalier_download` (since 0.15.0) opens a typed route from a download's notification tap, see [Notification taps](downloads.md#notification-taps). `FespalierAdapter` has nine members, each with a default that
adds nothing, so an adapter overrides what it needs:

| Member                      | When it runs                                                                                                   | What it is for                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `zone(body)`                | Around **all** of `main()`, outside startup.dart's `zone()`; before the binding exists                         | An SDK that wraps the app (`SentryFlutter.init(..., appRunner: body)`). Call `body` once                                                           |
| `beforeRun()`               | In `main()` after `WidgetsFlutterBinding.ensureInitialized()`, before `runApp`                                 | Installing a telemetry sink (`FespalierTelemetry.add`), opening a store. Return `null` for nothing to wait for                                     |
| `overrides()`               | Once, after `startup()` succeeded, **before** `startup()`'s own overrides                                      | `dataCacheStorage`, `reconnectSignal`, a flag source                                                                                               |
| `providerObservers()`       | With `startup()`'s `providerObservers`, the adapters' first                                                    | A `ProviderObserver`                                                                                                                               |
| `routerObservers()`         | When the router is built, before startup.dart's `routerObservers`                                              | A `NavigatorObserver` (a new one on each call: an observer belongs to one navigator)                                                               |
| `wrap(root)`                | Around the root widget, outside the `ProviderScope` and the splash too                                         | `SentryWidget`, `PostHogWidget`                                                                                                                    |
| `attach(router, container)` | Once per router (since 0.11.0), after the first frame that shows the router (the app's `ProviderScope` exists) | Subscribing to something that outlives a screen (a notification tap, a shortcut) with `container.listen`. Do not navigate synchronously            |
| `launch()`                  | Once, after `beforeRun()`, before the router is built (since 0.11.0); never on the web                         | Where the app was opened from: a notification tap that cold-started it, a shortcut. Return `null` when this adapter did not; the first answer wins |
| `onEnter(navigation)`       | For every navigation go_router parses, the first one included (since 0.11.0)                                   | Rewriting a custom-scheme link, a push payload link. `null` for no say, `Allow(then:)` or `Block.then(...)`; never block `navigation.initial`      |

Write adapters with `extends FespalierAdapter`, never `implements`: a member added later (`attach` is
one, since 0.11.0) has a default for a subclass and breaks a class that implements all of them.

**Order and rules.** The first package in the list is the outermost: its zone and its wrapper go around
the others'.

- Each name must be under `dependencies:` in the pubspec. A name that is not a package name, is listed
  twice, is `fespalier` itself, or is not a dependency is an error. `main: manual` with `adapters:` is
  fine since 0.11.0 (it used to be an error): your own `main()` calls them through `AppAdapters`, see
  [With `main: manual`](#with-main-manual-appadapters).
- `adapters:` makes `main: auto` write `lib/app.main.g.dart` even with no `app.dart`, `startup.dart` or
  `splash.dart`.
- There are no per-adapter options in the pubspec: what an adapter needs at deploy time comes from
  `--dart-define`, and anything custom stays in `startup.dart`, which is yours.

**What gets generated.** With `adapters:` the generated `lib/app.g.dart` (not the main) imports each adapter
and defines `AppAdapters` (since 0.11.0), whatever `main:` says; the generated main only calls it. With
`adapters: [my_tools, my_reporter]`:

```dart
// lib/app.g.dart
import 'package:fespalier/startup.dart' show FespalierAdapters, Override;
import 'package:my_tools/fespalier_adapter.dart' as _a0;
import 'package:my_reporter/fespalier_adapter.dart' as _a1;

abstract final class AppAdapters {
  static final _all = FespalierAdapters([_a0.adapter, _a1.adapter]);
  static Future<void> zone(Future<void> Function() body) => _all.zone(body);
  static Future<void>? beforeRun() => _all.beforeRun();
  static FutureOr<InboundLaunch?> launch() => _all.launch();
  static List<Override> overrides() => _all.overrides();
  static List<ProviderObserver> providerObservers() => _all.providerObservers();
  static List<NavigatorObserver> routerObservers() => _all.routerObservers();
  static Widget wrap(Widget root) => _all.wrap(root);
}

// AppRoutes.attach(router, [container]) also runs each adapter's attach(router, container)
// AppRoutes.onEnter(context, current, next, router) forwards to _all.onEnter (since 0.11.0), and
// AppRoutes.router(launch:, ...) passes it to GoRouter(onEnter:)
```

`AppRoutes.router` takes `launch:` (an `InboundLaunch`), with or without adapters, and `AppRoutes.onEnter` exists only
with adapters: without them go_router keeps its simplest code path, and with them every navigation is parsed
asynchronously and counts against go_router's redirect limit (any `onEnter` does that). See
[Opening the app](navigation.md#opening-the-app-launches-and-platform-links).

`FespalierAdapters` (in `package:fespalier/startup.dart`) holds the order, so it is Dart that is tested, not
generated text. These are the lines of `lib/app.main.g.dart` that are new, for a `startup.dart` with a
`zone()` and a `routerObservers` (the rest is what the root files alone make):

```dart
  static Future<void> run() => AppAdapters.zone(() => _i1.zone(_main));

    if (AppAdapters.beforeRun() case final ready?) await ready;
    final launch = AppAdapters.launch();
    _launch = launch is Future<InboundLaunch?> ? await launch : launch;

  static InboundLaunch? get launch => _launch;

  static Widget root({GoRouter Function() router = _router}) => AppAdapters.wrap(StartupGate(
    extraOverrides: _extraOverrides,
    // ... overrides:, observers:, retry:, as before
    attach: AppRoutes.attach,
    router: router,
    app: app,
  ));

  static List<NavigatorObserver> routerObservers() => [...AppAdapters.routerObservers(), ..._i1.routerObservers];

GoRouter _router() => AppRoutes.router(launch: AppMain.launch, observers: AppMain.routerObservers());
List<Override> _extraOverrides() => [...AppAdapters.overrides()];
```

The main no longer imports the adapters (0.10.0 and earlier did, as `_a0.adapter`), so an app with adapters
regenerates both files.

Without `adapters:` none of these lines is written, and `app.g.dart` is what it was before adapters existed.

**What stays true.** An adapter follows the rules of fespalier itself:

- No timer.
- Sync stays sync. A `beforeRun()` that returns `null` is not awaited, so no `Future` and no microtask. A
  `Future` is awaited and delays the first frame, with the platform's native splash still showing, so
  keep it to a local read, never the network.
- Nothing touches a platform plugin until it is used, so `AppMain.root()` boots in a widget test.
- `overrides()` goes before `startup()`'s: overriding a provider `startup()` also overrides is
  Riverpod's "Tried to override a provider twice" in debug.

**`attach` (since 0.11.0).** The generated main passes `AppRoutes.attach` to the `StartupGate`, which calls it
after the first frame that shows the router (an adapter may change a provider there), with the router and the `ProviderContainer` of the app's `ProviderScope`.
`AppRoutes.attach(router)` without a container (what `AppRoutes.router()` does) only follows the router for
DevTools, observe.dart and telemetry. Each adapter is attached once per router, in the pubspec's order, and
one that throws is reported with `FlutterError.reportError` while the others still run. `pumpRouter` does not
attach adapters, so a widget test of a page never runs them. The app's own `attach(router, container)` in
startup.dart (since 0.12.0) runs right after the adapters' `attach`; its `ready(container)` runs earlier, before the
router exists: [`ready()` and `attach()`](app-startup.md).

**`launch` and `onEnter` (since 0.11.0).** `FespalierAdapters.launch()` asks every adapter once, in order, and the
first non-null answer (an `InboundLaunch`) wins; it is `null` on the web and sync unless an adapter answers with a
`Future`. `FespalierAdapters.onEnter` (what the generated `AppRoutes.onEnter` forwards to) composes the adapters'
answers: the first `Block` wins, the `Allow.then` callbacks run in order as one, and no say is `Allow()`. Blocking
the initial navigation is refused: it is allowed, reported with `FlutterError.reportError` in every mode, and the block's `then` still runs; answer `launch()` instead. `InboundNavigation.initial` is true when go_router has no route yet (it hands the same state as current and next). A `Block.then` for a platform link keeps the link's mark: the `go` inside it is reported with `source=link`. See
[Opening the app](navigation.md#opening-the-app-launches-and-platform-links).

**Two things to check.**

- **`lib/main.dart` has to call `AppMain.run()`, or call `AppAdapters` itself.** Adapters are wired by the
  generated `main()` (or by `AppAdapters`, below): an app whose own `main()` still runs `runApp` by hand
  ignores them, without a message (`fsp` does not read `lib/main.dart`). The line is
  `Future<void> main() => AppMain.run();`.
- **An `app.dart` that builds the router** (`GoRouter router()`) has to pass the adapters' observers on:
  `AppRoutes.router(observers: AppMain.routerObservers())`. Without that `fsp` warns, on app.dart at the
  function: ``app.dart's router() builds the router itself, so the adapters' router observers are not added: pass `observers: AppMain.routerObservers()` to `AppRoutes.router(...)` there``.
  It warns the same way for the launch (since 0.11.0): ``app.dart's router() builds the router itself, so the adapters' launch is not used: pass `launch: AppMain.launch` to `AppRoutes.router(...)` there``.
  `AppRoutes.router(launch: AppMain.launch, observers: AppMain.routerObservers())` says both.

**In tests.** `pumpRouter(tester, router, app: AppMain.app)` (see [Testing](testing.md)) never sees the
adapters, and neither do the [`fsp test`](route-tests.md#route-smoke-tests-fsp-test) smoke tests.
`AppMain.root()` is the app as it runs, adapters included.

## With main: manual: AppAdapters

Since 0.11.0 `adapters:` works with `main: manual` too: `fsp` writes no `lib/app.main.g.dart`, but
`lib/app.g.dart` still defines `AppAdapters`, and your own `main()` calls it, in the order the generated one
does. An app that brings its own telemetry zone and builds its own router looks like this:

```dart
// lib/main.dart, with `fespalier: {main: manual, telemetry: true, adapters: [my_tools]}`
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'app.g.dart';

Future<void> main() => AppAdapters.zone(() async {
  WidgetsFlutterBinding.ensureInitialized();
  // your own setup: a telemetry sink goes here, before the router (FespalierTelemetry.add)
  if (AppAdapters.beforeRun() case final ready?) await ready;
  final launch = await AppAdapters.launch(); // a notification cold start, a shortcut: null on the web
  final container = ProviderContainer(
    overrides: [...AppAdapters.overrides() /*, the app's own */],
    observers: [...AppAdapters.providerObservers()],
  );
  final router = AppRoutes.router(
    launch: launch,
    observers: [...AppAdapters.routerObservers()],
  );
  AppRoutes.attach(router, container); // each adapter's attach(router, container), once
  runApp(AppAdapters.wrap(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  )));
});
```

- Moving from `main: auto` to `manual`: delete `lib/app.main.g.dart`; `fsp` no longer writes or updates it.
- Each adapter's top-level `adapter` is read once, at the first `AppAdapters` call.
- Call `AppRoutes.attach(router, container)` once, after both exist. Without it the adapters' `attach` never
  runs; calling it twice is safe.
- An app that mounts the tree in a `GoRouter` of its own (`AppRoutes.mount`) calls the same line with that
  router.
- `AppAdapters.overrides()` goes before your own overrides, as in the generated main.

## Adapters that need your code

_Since 0.12.0 (a pattern; it needs nothing new in fespalier)._ The pubspec carries no per-adapter options, and
`launch()` runs before any `ProviderScope` exists, so a provider override cannot hand an adapter the app's own code:
a push adapter needs your mapping from a payload to a route, a download adapter its backend, store and the mapping from a notification tap, an analytics adapter its backend, a bridge its generated
client. The one place that runs before the adapters is your `main()`. So an adapter that needs app code is configured
there, with one static call, before `AppMain.run()`:

```dart
// lib/main.dart
Future<void> main() {
  FespalierPush.configure(source: MyPushSource(), route: pushRoute); // before the adapters run
  return AppMain.run();
}
```

Every package that does this has the same shape, so that a second one holds no surprise:

- **`configure` is a static method on an `abstract final class`** (`FespalierPush`, `FespalierAnalytics`, `FespalierDownload`), and the
  adapter in `fespalier_adapter.dart` reads what it stored. Nothing else is global.
- **Calling it twice replaces.** A hot restart runs `main()` again, and the second call wins.
- **An unconfigured adapter says so once and does nothing.** It reports one `FlutterError.reportError` that names the
  missing call (`call FespalierPush.configure(...) in main() before AppMain.run()`) and leaves `launch()`, `attach()`
  and the others as no-ops. It never throws out of them: an adapter must not stop an app from starting.
- **`@visibleForTesting static void debugReset()`** clears what `configure` stored, for the test that sets up its own.

With `main: manual`, call `configure` in your own `main()` before `AppAdapters.zone`, the first line of the example
under [With `main: manual`](#with-main-manual-appadapters). `AppMain.root()` in a widget test runs no `main()`, so a
test that boots the app calls `configure` itself (with the package's fake from its `testing.dart`) before it pumps.

**An adapter that needs `telemetry: true`.** A sink that wants page events (screen views for analytics) gets them only
from an app generated with `telemetry: true`: the generated `attach` is what makes the router report them. An adapter
cannot read the pubspec, but its `attach(router, container)` can ask the router:

```dart
@override
void attach(GoRouter router, ProviderContainer container) {
  if (!telemetryFollows(router)) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError('my_analytics needs `telemetry: true` in the fespalier: section of pubspec.yaml'),
      library: 'my_analytics',
    ));
  }
}
```

`telemetryFollows(router)` (since 0.12.0, in `package:fespalier/fespalier.dart`) is true once `telemetryAttach` ran for
that router, which the generated `AppRoutes.attach` does only with `telemetry: true`. It reads, and starts nothing: no
watch, no timer, no provider. It says nothing about whether a sink is installed (`FespalierTelemetry.current`), only
whether the router reports to one. The generated `AppRoutes.attach` calls `telemetryAttach` just before it calls the
adapters' `attach`, so the answer is settled there.
