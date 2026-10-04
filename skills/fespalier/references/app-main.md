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

| Value       | `lib/app.main.g.dart`                                                                                                                                                  |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `auto`      | the default: written when the root has an `app.dart`, `startup.dart` or `splash.dart`, or, since 0.9.0, when `adapters:` lists a package; otherwise nothing is written |
| `generated` | always written; without an `app.dart` the app is `MaterialApp.router(routerConfig: router)`                                                                            |
| `manual`    | never written; the three files are **not read**, and each one that exists gets a warning (below). `fsp init` then writes no `app.dart` either                          |

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
after `startup()`; it has to return `AppRoutes.router(...)`. Without it the router is
`AppRoutes.router()`, with startup.dart's `routerObservers` if there are any.

## `startup.dart`

Exports read by name; at least one is required.

| Export                                | Shape                                                                                                                                    |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `startup()`                           | No parameters. `void`, `Future<void>`, `FutureOr<void>`; or **the overrides**: `List<Override>`, `Future<List<Override>>`, `FutureOr<…>` |
| `zone(Future<void> Function() body)`  | Wraps all of `main()`. Returns `Future<void>` or `FutureOr<void>`; call `body()`                                                         |
| `providerObservers`                   | A list (variable or getter) of `ProviderObserver`s; read after `startup()`                                                               |
| `routerObservers`                     | A list of `NavigatorObserver`s; read after `startup()`; an error when app.dart has `router()`                                            |
| `retry(int retryCount, Object error)` | `Duration?`: the `ProviderScope`'s retry                                                                                                 |

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

### The order, and what stays sync

- `zone()` is entered; inside it `AppMain.run()` initializes the binding, loads the deferred
  routes' code (`!kIsWeb`), and calls `runApp(root())`.
- `startup()` is called when the first frame is built (inside the zone: the root is attached in a
  timer the zone owns), then `providerObservers` is read, then the router is made.
- **Sync stays sync.** A `startup()` that returns no `Future` is done before the first frame; the first frame is the app.
  A `Future` costs a frame: `splash.dart` shows meanwhile, or, without one, the first frame is
  deferred so the native splash stays. No timer.
- A throw is reported with `FlutterError.reportError` (library `fespalier`, "while running startup() in startup.dart")
  and shown: `splash.dart` with `error`, `stackTrace` and `retry`, or a plain "Couldn't start the app." with "Try again".

## `splash.dart`

A view file built **before** the app: no `Theme`, `Localizations` or `ProviderScope` above it, only a
text direction. It can ask for `error` (`Object?`), `stackTrace` (`StackTrace?`) and `retry`
(`VoidCallback?`), by name; each **must be nullable**, because all three are null while `startup()`
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
  Tests pump it to boot everything.
- `AppMain.app(router)`: `app.dart`'s widget around a router; `pumpRouter(tester, router, app: AppMain.app)`
  (see `fespalier-testing`).
- `AppMain.routerObservers()` (since 0.9.0, only with `adapters:`): the adapters' router observers, then
  startup.dart's `routerObservers`. An app.dart `router()` passes it on (below).

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

For each name `n`, at index `i`, `lib/app.main.g.dart` imports `package:n/fespalier_adapter.dart as _a{i}` and calls
`_a{i}.adapter`, a **`FespalierAdapter`** (`package:fespalier/startup.dart`) that the package exports as a
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

| Member                | Runs                                                                      | Notes                                                                                                                                                                  |
| --------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `zone(body)`          | around **all** of `main()`, outside startup.dart's `zone()`               | `Future<void>`; call `body` once. Before the binding exists                                                                                                            |
| `beforeRun()`         | after `ensureInitialized()`, before `runApp`                              | `Future<void>?`: return `null` for nothing to wait for (not awaited: no `Future`, no microtask). A `Future` delays the first frame, so a local read, never the network |
| `overrides()`         | once, after `startup()` succeeded, **before** `startup()`'s own overrides | Overriding a provider `startup()` also overrides is Riverpod's "Tried to override a provider twice" in debug                                                           |
| `providerObservers()` | with `providerObservers` of startup.dart, the adapters' first             |                                                                                                                                                                        |
| `routerObservers()`   | when the router is built, before startup.dart's `routerObservers`         | A new observer on each call: an observer belongs to one navigator                                                                                                      |
| `wrap(root)`          | around the root widget, outside the `ProviderScope` and the splash        | `SentryWidget`, `PostHogWidget`                                                                                                                                        |

Each default adds nothing. The rules are fespalier's own: no timer, sync stays sync, nothing touches a platform
plugin until it is used (so `AppMain.root()` boots in a widget test).

- **Order.** The first package is the outermost: its zone and its wrapper go around the others'.
- **Errors, all from `fsp`** (quoted in `fespalier-troubleshooting`, its app-main diagnostics page): a name that is
  not a package name, a duplicate, `fespalier` itself, a name not under `dependencies:`, and `main: manual` with
  `adapters:` (a generated `main()` is what calls them).
- **No per-adapter keys.** Deploy-time options come from `--dart-define`; anything custom stays in `startup.dart`.
- **Tests.** `pumpRouter(tester, router, app: AppMain.app)` and `fsp test` never see the adapters; `AppMain.root()`
  is the app as it runs, adapters included.

## Gotchas

- **`usePathUrlStrategy()` goes in `startup()`.** The router is built after it, which is in time
  (checked in a release web build, with an async `startup()`). It needs `flutter_web_plugins` in `pubspec.yaml`.
- **`zone()` runs on the web.** A zone that needs `dart:io` or an isolate must behave there:
  `otel_zone`'s `runGuarded` never runs its body in a browser and leaves the app blank, so write
  `kIsWeb ? body() : observability.runGuarded(body)`.
- **Adapters do nothing unless `lib/main.dart` is `Future<void> main() => AppMain.run();`.** `fsp` does not
  read `lib/main.dart`: an app whose own `main()` still calls `runApp` by hand ignores them, without a message.
- **An app.dart `router()` must pass `observers: AppMain.routerObservers()`** to `AppRoutes.router(...)`, or the
  adapters' router observers are not added (a warning from `fsp`, quoted in `fespalier-troubleshooting`).
- **A `startup()` failure fails a widget test** until `tester.takeException()` takes it.
- **A root file that is something else** (a helper that happens to be `lib/app/app.dart`): rename it
  into `_components/`, or set `main: manual`.
- **`startup()` is not run by `pumpRouter`:** pass what it would override as `overrides`.

The diagnostics, quoted, are in `fespalier-troubleshooting` (its app-main diagnostics page);
moving a hand-written `main()` over is in `fespalier-migration`
(`references/upgrading-0-7-to-0-8.md`).
