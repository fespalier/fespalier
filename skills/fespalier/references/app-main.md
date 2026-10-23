# The generated `main()`: `app.dart`, `startup.dart`, `splash.dart`

Since 0.8.1. Three optional files at the **root** of the app folder make `fsp` write
`lib/app.main.g.dart`, whose `AppMain` is the app's `main()`. `lib/main.dart` stays the
app's own and is one line:

```dart
// lib/main.dart
import 'package:my_app/app.main.g.dart';

Future<void> main() => AppMain.run();
```

(`my_app` stands for your package's name.) Never edit
`lib/app.main.g.dart`: like `app.g.dart` it is generated, and `app.g.dart` is **byte for byte
the same** whether or not these files exist.

## When it is written: `main:`

`fespalier: main:` in `pubspec.yaml`:

| Value       | `lib/app.main.g.dart`                                                                                                                                                                                                                                            |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `auto`      | the default: written when the root has an `app.dart`, `startup.dart` or `splash.dart`, or, since 0.9.0, when `adapters:` lists a package (since 0.23.0, or `adapters: auto` finds one), or, since 0.19.0, when `otel: true` is set; otherwise nothing is written |
| `generated` | always written; without an `app.dart` the app is `MaterialApp.router(routerConfig: router)`                                                                                                                                                                      |
| `manual`    | never written; the three files are **not read**, and each one that exists gets a warning (below). `fsp init` then writes no `app.dart` either                                                                                                                    |

The path is `output` with `.main.g.dart` in place of `.g.dart`, in the same folder
(`lib/router/routes.g.dart` makes `lib/router/routes.main.g.dart`); there is no key for it.
`gen` names every file it wrote: `✓ 12 routes → lib/app.g.dart, lib/app.main.g.dart`. Use
`manual` for an app that keeps its own `main()` or its own `GoRouter` (mount the tree with
`AppRoutes.mount`), or whose `lib/app/app.dart` is some other widget.

## `app.dart`

A view file: one public widget class of any kind, or `Widget app({required GoRouter router})`.
It gets the router as a parameter named `router`, or the one typed `GoRouter`
(`RouterConfig<Object>` works too). Any **other required** parameter is an error; optional ones
keep their defaults.

```dart
// lib/app/app.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Minimal',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    routerConfig: router,
  );
}
```

It may also export `GoRouter router()` (no parameters) to say how the router is built, once,
after `startup()`. `fsp` checks only the signature (`GoRouter router()`, no parameters): return
`AppRoutes.router(...)`, or a hand-built `GoRouter` with `...AppRoutes.mount(at: ...)` among its routes
(adopting fespalier in a go_router app, `fespalier-migration`; `examples/adopt`), and `ready()` and
`attach()` still run around it. Without it the router is
`AppRoutes.router()`, with startup.dart's `routerObservers` if there are any.

## `startup.dart`

Exports read by name; at least one is required.

| Export                                                 | Shape                                                                                                                                    |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `startup()`                                            | No parameters. `void`, `Future<void>`, `FutureOr<void>`; or **the overrides**: `List<Override>`, `Future<List<Override>>`, `FutureOr<…>` |
| `zone(Future<void> Function() body)`                   | Wraps all of `main()`. Returns `Future<void>` or `FutureOr<void>`; call `body()`                                                         |
| `providerObservers`                                    | A list (variable or getter) of `ProviderObserver`s; read after `startup()`                                                               |
| `routerObservers`                                      | A list of `NavigatorObserver`s; read after `startup()`; an error when app.dart has `router()`                                            |
| `retry(int retryCount, Object error)`                  | `Duration?`: the `ProviderScope`'s retry                                                                                                 |
| `ready(ProviderContainer container)`                   | Since 0.12.0. `FutureOr<void>` (`Future<void>`, `void`): runs on the app's own container, after `startup()`, before the router           |
| `attach(GoRouter router, ProviderContainer container)` | Since 0.12.0. `void`: once, after the first frame that shows the router, after the adapters' `attach`                                    |

```dart
// lib/app/startup.dart
import 'package:fespalier/startup.dart'; // Override, ProviderObserver, NavigatorObserver

Future<List<Override>> startup() async {
  // usePathUrlStrategy();  // web: first line; the router is built after this returns
  return [];
}

List<ProviderObserver> get providerObservers => [];
```

`startup()` runs **before the router exists** and before the `ProviderScope`; it returns what the
scope overrides. `zone()` runs outermost: the binding, the deferred routes' code (off the web),
`startup()` and `runApp` are inside `body`. A `zone()` has to work on the web too (see below).

### `ready()` and `attach()` (since 0.12.0)

`startup()` has no container (it returns overrides). Work that needs the app's container (`await container.read(x.future)`
before the first route, an eager read, a `container.listen` that lives as long as the app) is `ready(container)`; a
step that also needs the router (a post-frame one) is `attach(router, container)`. Each is optional and independent.
With a `ready()` the gate builds the `ProviderContainer` itself (same overrides, observers and `retry()` as the plain
`ProviderScope` it builds without one), runs `ready` on it, then hosts it in an `UncontrolledProviderScope`. Without a
`ready()` the output and the runtime path are what they were. The order: `zone()`, `startup()` (overrides and observers
read once after it succeeded), the container, `ready()`, the router, `attach()` after the frame (the adapters' first, then
the app's; an error in one is reported, "while running attach() in startup.dart", and does not stop the other).

**Providers `ready()` reads must be `keepAlive`, or held**: the container is not mounted until `ready()` is done, and
Riverpod disposes an unlistened auto-dispose provider (a `@riverpod` one) on the next timer tick, so one that `ready()` only
reads or awaits is gone before the first route. Use `@Riverpod(keepAlive: true)`, or `container.listen(p, (_, _) {})` in `ready()`.

`ready()` is sync-stays-sync like `startup()`: a sync one is done before the first frame, an async one shows `splash.dart`
(or defers the first frame without one), a throw is reported ("while running ready() in startup.dart") and shown with
`retry`, which **disposes the container, makes a fresh one and runs `ready()` again, without running `startup()`
again**. So `ready()` can run more than once and must keep no state of its own between tries. No timer, microtask or listener
of the gate's own. `pumpRouter` runs neither; `AppMain.root()` does. A `main: manual` app owns its container and calls
its own `ready(container)` after creating it, and `attach(router, container)` in a post-frame callback beside
`AppRoutes.attach(router, container)` (which exists only when `app.g.dart` has it: adapters, observe.dart or telemetry; with
`adapters:` see "With `main: manual`: `AppAdapters`" below) (`docs/app-startup.md`).

### The order, and what stays sync

- `zone()` is entered; inside it `AppMain.run()` initializes the binding, loads the deferred
  routes' code (`!kIsWeb`), and calls `runApp(root())`.
- `startup()` is called when the first frame is built (inside the zone: the root is attached in a
  timer the zone owns), then `providerObservers` is read, then (since 0.12.0, with a `ready()`) the container is made and
  `ready()` runs, then the router is made.
- **Sync stays sync.** A `startup()` that returns no `Future` is done before the first frame; the first frame is the app.
  A `Future` costs a frame: `splash.dart` shows meanwhile, or, without one, the first frame is
  deferred so the native splash stays. No timer.
- A throw is reported with `FlutterError.reportError` (library `fespalier`, "while running startup() in startup.dart")
  and shown: `splash.dart` with `error`, `stackTrace` and `retry`, or a plain "Couldn't start the app." with "Try again".

## `splash.dart`

A view file built **before** the app: no `Theme`, `Localizations` or `ProviderScope` above it, only a
text direction. It can ask for `error` (`Object?`), `stackTrace` (`StackTrace?`) and `retry`
(`VoidCallback?`), by name; each **must be nullable**, because all three are null while `startup()` (or `ready()`)
runs. Any other required parameter is an error. With no async `startup()` it is never shown (a warning).

```dart
// lib/app/splash.dart
import 'package:flutter/widgets.dart';

class Splash extends StatelessWidget {
  const Splash({super.key, this.error, this.retry});

  final Object? error;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => Center(
    child: error == null
        ? const Text('Starting…')
        : GestureDetector(onTap: retry, child: Text('$error')),
  );
}
```

## What `AppMain` has

- `AppMain.run()`: what `main()` calls.
- `AppMain.root({router})`: the widget `runApp` gets (`StartupGate` from `package:fespalier/startup.dart`).
- StartupGate passes a hot reload to the router (`reloadRoutes`, since 0.19.0): its `reassemble` swaps in a regenerated route table in a debug build, and does nothing otherwise.
  Tests pump it to boot everything.
- `AppMain.app(router)`: `app.dart`'s widget around a router; `pumpRouter(tester, router, app: AppMain.app)`
  (see `fespalier-testing`).
- `AppMain.routerObservers()` (since 0.9.0, only with `adapters:`): the adapters' router observers, then
  startup.dart's `routerObservers`. An app.dart `router()` passes it on (below).
- `AppMain.launch` (since 0.11.0, only with `adapters:`): the `InboundLaunch?` the adapters answered, asked once in `run()`
  (null on the web); an app.dart `router()` passes it on as `launch:` (below).
- `AppMain.observability` (since 0.19.0, only with `otel: true`): the `OtelZone` that `run()` starts, see the section below.

## Adapters: `fespalier: adapters:` (since 0.9.0)

A package that plugs into the generated `main()` is listed by name, in order; the generator needs no table
and reads no manifest:

```yaml
# in pubspec.yaml
dependencies:
  my_tools: ^1.0.0 # a package that ships lib/fespalier_adapter.dart
  my_reporter: ^1.0.0
fespalier:
  adapters: [my_tools, my_reporter] # the first is the outermost
```

Since 0.23.0, `adapters: auto` takes the first-party adapter packages under `dependencies:` in place of a list you write:
`fespalier_analytics`, `fespalier_download`, `fespalier_launch` and `fespalier_push`, in the order `dependencies:` lists
them. It is opt-in, because each of them needs its `configure` call in `main()` (an unconfigured one reports an error once).
A package of your own is never taken: list it. With none of them, `auto` is no adapters. `auto` written inside a list is
refused: `` `fespalier.adapters` lists `auto`, which is not a package: write `adapters: auto` on its own (since 0.23.0) for every first-party adapter package under `dependencies:`, or list the packages ``.
`fsp doctor` prints one row per adapter, on or off, and whether a Dart file under `lib/` calls its `configure`.

For each name `n`, at index `i`, `lib/app.g.dart` (since 0.11.0; on 0.10.0 and earlier `lib/app.main.g.dart`) imports
`package:n/fespalier_adapter.dart as _a{i}` and `AppAdapters` calls `_a{i}.adapter`, a **`FespalierAdapter`** (`package:fespalier/startup.dart`) that the package exports as a
top-level `adapter`. The output depends on the pubspec alone, never on `pub get` or the pub cache, so `fsp check`
gives the same bytes before and after it. An app can write one in a package of its own:

```dart
// package:my_tools/fespalier_adapter.dart
import 'package:fespalier/startup.dart';

const adapter = MyToolsAdapter();

class MyToolsAdapter extends FespalierAdapter {
  const MyToolsAdapter();

  @override
  List<NavigatorObserver> routerObservers() => [MyNavigatorObserver()];
}
```

| Member                      | Runs                                                                                                     | Notes                                                                                                                                                                  |
| --------------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `zone(body)`                | around **all** of `main()`, outside startup.dart's `zone()`                                              | `Future<void>`; call `body` once. Before the binding exists                                                                                                            |
| `beforeRun()`               | after `ensureInitialized()`, before `runApp`                                                             | `Future<void>?`: return `null` for nothing to wait for (not awaited: no `Future`, no microtask). A `Future` delays the first frame, so a local read, never the network |
| `overrides()`               | once, after `startup()` succeeded, **before** `startup()`'s own overrides                                | Overriding a provider `startup()` also overrides is Riverpod's "Tried to override a provider twice" in debug                                                           |
| `providerObservers()`       | with `providerObservers` of startup.dart, the adapters' first                                            |                                                                                                                                                                        |
| `routerObservers()`         | when the router is built, before startup.dart's `routerObservers`                                        | A new observer on each call: an observer belongs to one navigator                                                                                                      |
| `wrap(root)`                | around the root widget, outside the `ProviderScope` and the splash                                       | `SentryWidget`, `PostHogWidget`                                                                                                                                        |
| `attach(router, container)` | once per router (since 0.11.0), after the first frame that shows the router (the `ProviderScope` exists) | Subscribe with `container.listen` (a notification tap, a shortcut); do not navigate synchronously. An adapter that throws here is reported and the others still run    |

Each default adds nothing. The rules are fespalier's own: no timer, sync stays sync, nothing touches a platform
plugin until it is used (so `AppMain.root()` boots in a widget test).

- **Order.** The first package is the outermost: its zone and its wrapper go around the others'.
- **Errors, all from `fsp`** (quoted in `fespalier-troubleshooting`, its app-main diagnostics page): a name that is
  not a package name, a duplicate, `fespalier` itself, and a name not under `dependencies:`. `main: manual` with
  `adapters:` was an error up to 0.10.0 and is fine since 0.11.0 (below).
- **`launch` and `onEnter` (since 0.11.0).** `launch()` returns an `InboundLaunch` (or `null`) once, after `beforeRun()`,
  never on the web; the first adapter's answer wins. `onEnter(InboundNavigation)` returns `null`, `Allow(then:)` or `Block.then(...)`;
  the first `Block` wins and the `then`s of the `Allow`s run in order. Never block `navigation.initial` (it is allowed, reported in every mode, and its `then` still runs). A `then` runs after the commit (go_router 17.2.3, the lowest since 0.16.0, and later; before 17.2 it ran inside the parse, before it). `launchRouter` and the platform-link marks are in `fespalier-routing`. The generated main asks
  `AppAdapters.launch()` once and gives `AppRoutes.router(launch: AppMain.launch)` the answer; with `main: manual`, `final launch = await AppAdapters.launch();`
  and `AppRoutes.router(launch: launch, ...)`. `AppRoutes.onEnter` exists only with adapters (go_router parses every navigation asynchronously, with its redirect limit, as soon as any `onEnter` is set).
- **`onEnter` is a getter (since 0.16.0).** An adapter that wants go_router's `onEnter` overrides
  `FespalierEnter? get onEnter => (navigation) { ... };` (a function of the `InboundNavigation`; the default is `null`). It was
  a method up to 0.15.0, and a method of that name now **fails to compile** (`Class 'X' can't define method 'onEnter' and have field 'FespalierAdapter.onEnter' with the same name.`):
  change it to the getter, `return` as before. `AppRoutes.router` passes go_router
  `onEnter: AppAdapters.handlesEnter ? onEnter : null`, so `onEnter` reaches go_router **only when some adapter's getter is not
  null**, and only those adapters are asked. No first-party adapter has one, so an app with `fespalier_push`,
  `fespalier_analytics` or `fespalier_download` keeps go_router's synchronous parsing. With an adapter that has one,
  `router.go('/a'); router.push('/b');` in one handler loses the `go()` (`/home > /b`) and `currentConfiguration` lags a
  frame: before 0.16.0 every app with `adapters:` had that. An app with a router of its own passes
  `onEnter: AppAdapters.handlesEnter ? AppRoutes.onEnter : null`.
- **`extends`, never `implements`** `FespalierAdapter`: a member added later (`attach`, since 0.11.0) has a default
  for a subclass only.
- **`attach` (since 0.11.0).** The generated main passes `AppRoutes.attach` to the `StartupGate`, which calls it
  after the first frame that shows the router, with the app's `ProviderContainer` (so an adapter may change a provider there). `AppRoutes.attach(router)` with no container (what
  `AppRoutes.router()` calls) skips the adapters. `pumpRouter` never attaches them.
- **No per-adapter keys.** Deploy-time options come from `--dart-define`; anything custom stays in `startup.dart`.
- **An adapter that needs your code (since 0.12.0; a pattern):** configure it in `main()` before `AppMain.run()`
  (`FespalierPush.configure(...)`; with `main: manual`, before `AppAdapters.zone`), because `launch()` runs before any
  `ProviderScope`. Shape: a static `configure` on an `abstract final class`; a second call replaces (hot restart); an
  unconfigured adapter reports one `FlutterError.reportError` naming the call and does nothing; a `debugReset()` marked
  `@visibleForTesting`. `AppMain.root()` in a test runs no `main()`: call `configure` with the fake first. An adapter
  whose sink needs page events asks `telemetryFollows(router)` (since 0.12.0, `package:fespalier/fespalier.dart`) in
  `attach` and reports a missing `telemetry: true`. `docs/adapters.md`, "Adapters that need your code".
- **Not every companion is an adapter** (since 0.10.0): `fespalier_tolgee` and `fespalier_cratestack` ship **no**
  `fespalier_adapter.dart` (the setup is app code, which `startup()` already is), so `adapters: [fespalier_tolgee]` makes the
  generated `lib/app.g.dart` import a file that does not exist (`Target of URI doesn't exist`). Wire them in `startup()`
  ([`fespalier-i18n`](../../fespalier-i18n/SKILL.md), [`fespalier-cratestack`](../../fespalier-cratestack/SKILL.md)).
- **Tests.** `pumpRouter(tester, router, app: AppMain.app)` and `fsp test` never see the adapters; `AppMain.root()`
  is the app as it runs, adapters included.

### With `main: manual`: `AppAdapters` (since 0.11.0)

`adapters:` with `main: manual` writes no `app.main.g.dart`, but `lib/app.g.dart` defines **`AppAdapters`**
(`zone`, `beforeRun`, `launch`, `overrides`, `providerObservers`, `routerObservers`, `wrap`, each forwarding to
`FespalierAdapters` from `package:fespalier/startup.dart`) and your own `main()` calls it, in the same order as
the generated one, all inside `AppAdapters.zone(() async { ... })`:

1. `WidgetsFlutterBinding.ensureInitialized()`, then `await AppAdapters.beforeRun()`, then `final launch = await AppAdapters.launch()`.
2. A `ProviderContainer` with `AppAdapters.overrides()` and `AppAdapters.providerObservers()`.
3. `AppRoutes.router(launch: launch, observers: [...AppAdapters.routerObservers()])`.
4. **`AppRoutes.attach(router, container)`**.
5. `runApp(AppAdapters.wrap(UncontrolledProviderScope(...)))`.

Forgetting `AppRoutes.attach(router, container)` means no adapter's `attach` runs (calling it twice is safe).
Full example: `docs/adapters.md`, "With main: manual: AppAdapters".

## OpenTelemetry: `otel: true` (since 0.19.0)

With `fespalier: otel: true` in pubspec.yaml, and `telemetry: true`, `fespalier_otel` and `otel_zone` under `dependencies:`,
`app.main.g.dart` declares `AppMain.observability` (an `OtelZone` named after the pubspec's `name`, exporting to
`FespalierOtel.endpoint()`) and starts it first in `_main()`, with `FespalierOtel.serviceVersion()` and
`FespalierOtel.buildId()`. It adds `FespalierOtel` as a sink with `FespalierTelemetry.add` (so a sink an adapter or
`startup()` adds stays), passes the Riverpod and route observers, and wraps `main()` in `runGuarded` on every platform (the web too, since 0.19.0, with otel_zone v0.8.1 or later): the
innermost zone, inside the adapters' zones, and not used when startup.dart has a `zone()`. `lib/main.dart` is
`Future<void> main() => AppMain.run();`, and `app.g.dart` is unchanged. It is not an adapter, and `main: manual` refuses it.
The version is the build name (`FLUTTER_BUILD_NAME`, Flutter 3.47 and later; `unknown` before), and no version is
written into the file. Details and the errors: `fespalier-observability` (`references/telemetry.md`, "Wire it with
`otel: true`").

## Gotchas

- **`usePathUrlStrategy()` goes in `startup()`.** The router is built after it, which is in time
  (checked in a release web build, with an async `startup()`). It needs `flutter_web_plugins` in `pubspec.yaml`.
- **`zone()` runs on the web.** A zone that needs `dart:io` or an isolate must behave there:
  `otel_zone` before v0.8.1 never ran its `runGuarded` body in a browser and left the app blank: there, call
  the body directly when `kIsWeb` is true. From v0.8.1 the zone runs on the web.
- **Adapters do nothing unless `lib/main.dart` is `Future<void> main() => AppMain.run();` (or calls `AppAdapters`).** `fsp` does not
  read `lib/main.dart`: an app whose own `main()` still calls `runApp` by hand ignores them, without a message.
- **An app.dart `router()` must pass `observers: AppMain.routerObservers()` and `launch: AppMain.launch`** to
  `AppRoutes.router(...)`, or the adapters' router observers are not added and their launch is not used (a warning from `fsp` for each,
  quoted in `fespalier-troubleshooting`).
- **A `startup()` failure fails a widget test** until `tester.takeException()` takes it (a `ready()` failure too).
- **`ready()` runs on a container that is thrown away when it fails** (since 0.12.0): a retry makes a new one, so
  a listener or a read made in the failed run is gone with it.
- **A root file that is something else** (a helper that happens to be `lib/app/app.dart`): rename it
  into `_components/`, or set `main: manual`.
- **`startup()` is not run by `pumpRouter`:** pass what it would override as `overrides`.

The diagnostics, quoted, are in `fespalier-troubleshooting` (its app-main diagnostics page);
moving a hand-written `main()` over is in `fespalier-migration`
(`references/upgrading-0-7-to-0-8.md`).
