# `main()`: app.dart, startup.dart and splash.dart

Since 0.8.1 the framework can own `main()`. You write up to three files at the **root** of the app
folder (a copy below it is ignored, with a warning), and `fsp` writes `lib/app.main.g.dart`, whose
`AppMain` runs them. `lib/main.dart` stays yours, and is one line:

```dart
// lib/main.dart
import 'package:my_app/app.main.g.dart';

Future<void> main() => AppMain.run();
```

```text
lib/app/
  app.dart       the widget around the router: MaterialApp.router, theme, title, locales
  startup.dart   what runs before the app: startup(), ready(), attach(), zone(), providerObservers, routerObservers, retry()
  splash.dart    shown while an async startup() or ready() runs, and when either fails
```

All three are optional. With none of them, `main: auto` (the default) writes nothing and your own `main()` keeps working. Any one of them makes `fsp` write `lib/app.main.g.dart`, and so does an [`adapters:`](adapters.md) list (since 0.9.0). `app.g.dart` is the same bytes whether or not they exist.

**`app.dart`** is a view file: one public widget class (of any kind: a `ConsumerWidget` to read a
theme-mode provider is the point) or a function `Widget app({required GoRouter router})`. It gets the
router as a parameter named `router`, or the one typed `GoRouter` (`RouterConfig<Object>` works too).
Every other parameter has to be optional.

```dart
// lib/app/app.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Shop',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    routerConfig: router,
  );
}

/// Optional: how the router is built. Called once, after startup(). Return AppRoutes.router(), or your own GoRouter.
GoRouter router() => AppRoutes.router(restorationScopeId: 'router');
```

`fsp` checks only the signature (`GoRouter router()`, no parameters), not the body, so an app that is adopting fespalier can return a `GoRouter` of its own with `...AppRoutes.mount(at: '/shop', navigatorKey: key)` among its routes ([Migration](migration.md#adopting-fespalier-in-a-go_router-app); `examples/adopt`). `ready()` and `attach()` run around it as around any other. Without `router()` the router is `AppRoutes.router()`, with the `routerObservers` of startup.dart if it
has any. Without an `app.dart` (with `main: generated`) the app is `MaterialApp.router(routerConfig: router)`.

**`startup.dart`** exports, by name, any of:

| Export                                                 | What it is                                                                                                                                                              |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `startup()`                                            | No parameters. Returns `void`, `Future<void>` or `FutureOr<void>`; or the providers to override: `List<Override>`, `Future<List<Override>>`, `FutureOr<List<Override>>` |
| `zone(Future<void> Function() body)`                   | Wraps **all** of `main()`: the binding, `startup()` and `runApp` run inside `body`. Returns `Future<void>` or `FutureOr<void>`; call `body()` in it                     |
| `providerObservers`                                    | A list (a variable or a getter) of `ProviderObserver`s for the `ProviderScope`; read after `startup()`                                                                  |
| `routerObservers`                                      | A list of `NavigatorObserver`s for the router; read after `startup()`. Not with a `router()` in app.dart: pass them there                                               |
| `retry(int retryCount, Object error)`                  | `Duration?`: the `ProviderScope`'s retry policy                                                                                                                         |
| `ready(ProviderContainer container)`                   | Since 0.12.0. `FutureOr<void>` (or `Future<void>`, `void`): runs on the app's own container, after `startup()`, before the router exists                                |
| `attach(GoRouter router, ProviderContainer container)` | Since 0.12.0. `void`: called once with the router and that container, after the first frame that shows the router                                                       |

```dart
// lib/app/startup.dart
import 'dart:async';

import 'package:fespalier/startup.dart'; // Override, ProviderObserver, NavigatorObserver
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runs once, before the app. The providers it returns are overridden in the app's ProviderScope.
Future<List<Override>> startup() async {
  usePathUrlStrategy(); // web: before the router reads the URL, which happens after startup()
  final prefs = await SharedPreferences.getInstance();
  return [prefsProvider.overrideWithValue(prefs)];
}

/// Optional: wraps all of main().
Future<void> zone(Future<void> Function() body) async {
  await runZonedGuarded(body, (error, stack) => reportCrash(error, stack));
}

/// Optional: read after startup().
List<ProviderObserver> get providerObservers => [];
List<NavigatorObserver> get routerObservers => [];
Duration? retry(int retryCount, Object error) => null;
```

`startup.dart` needs at least one of these exports. `startup()` runs **before the router exists**: the router is built once, after `startup()`, and disposed with the app. That is also why `usePathUrlStrategy()` belongs in `startup()`.

**`ready()` and `attach()` (since 0.12.0): work on the app's own container.** `startup()` runs before any `ProviderContainer` exists, so it can only return overrides. An app that must `await container.read(storeProvider.future)` before the first route (a native init, a store to open, a session to restore), read providers eagerly, or install a `container.listen` that lives as long as the app, exports `ready()`; one that needs the router as well (a notification tap, a post-frame step) exports `attach()`. Each is optional and independent of the other, and of `startup()`:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [prefsProvider.overrideWithValue(await SharedPreferences.getInstance())];

/// The container the app runs in: the overrides, observers and retry above are already on it.
Future<void> ready(ProviderContainer container) async {
  // keepAlive providers (or held with container.listen): an auto-dispose one nobody listens to is gone
  // before the first route, see below.
  await container.read(databaseProvider.future); // the first route renders with the store open
  container.read(analyticsProvider); // eager
  container.listen(sessionProvider, (_, next) => syncPushToken(next));
}

/// After the first frame that shows the router; the adapters' attach has run before it.
void attach(GoRouter router, ProviderContainer container) {
  container.listen(sessionProvider, (_, next) {
    if (next is SignedOut) router.go('/sign-in');
  });
}
```

The order is **`zone()` → `startup()` → the container → `ready()` → the router → `attach()`**:

1. `startup()` runs as before (no container yet, no change in what it may do). Its overrides, the adapters' overrides and `providerObservers` are read once, after it succeeded.
2. The gate makes the `ProviderContainer` itself, with those overrides and observers and `retry()`, and runs `ready(container)` on it. The container is then hosted with an `UncontrolledProviderScope`, so it is the one `ProviderScope.containerOf(context)` and every `ref` see. Without `ready()` the gate builds a plain `ProviderScope` exactly as before.
3. The router is built (once, after `ready()`), so a `ready()` that is still running means no route has been matched, no guard has run and no `data()` has been read.
4. After the frame that shows the router, `AppRoutes.attach` runs each adapter's `attach`, then startup.dart's `attach(router, container)`. An error from either is reported with `FlutterError.reportError` (library `fespalier`, "while running attach() in startup.dart"), does not stop the other, and the app still shows. Do not navigate synchronously from it.

`ready()` follows the rules of `startup()`. **Sync stays sync**: one that returns no `Future` is done before the first frame. An async one shows `splash.dart` meanwhile, or, without one, defers the first frame like an async `startup()` (still no timer, and the gate follows the `Future` with `then`). One that throws is reported ("while running ready() in startup.dart") and shown with `retry`; `retry` **disposes the failed container, makes a fresh one with the same overrides and runs `ready()` again**. It does not run `startup()` again: that had succeeded, and its overrides are kept. A failing `startup()` is retried whole, `ready()` after it. So `ready()` may be tried more than once, on a new container each time, and should not keep state of its own between tries.

**Providers `ready()` reads must not be auto-dispose, or must be held.** The container is not mounted until `ready()` is done, and Riverpod disposes an auto-dispose provider that nothing listens to on the next timer tick. A `@riverpod` provider (auto-dispose by default) that `ready()` only reads or awaits is therefore gone before the first route, and the route builds it again. Make it `@Riverpod(keepAlive: true)`, or hold it for the app's life with `container.listen(provider, (_, _) {})` in `ready()` (the listener lives as long as the container).

The gate disposes its container with the app. `ready()` and `attach()` name `ProviderContainer` and `GoRouter`, which `package:fespalier/fespalier.dart` exports. Declare them as shown: a different parameter list or return type is an error with the signature in its message. `pumpRouter` and a test that pumps a page do not run them; `AppMain.root()` does.

**With `main: manual`** the files are not read, so you own the container and call both yourself, in the same order. `ready` goes after the container exists and before `runApp`, `attach` after the router and the container exist (next to `AppRoutes.attach`, which runs the adapters', so the order is the same as the generated one's). `AppRoutes.attach` exists only when your `app.g.dart` has it (adapters, observe.dart or telemetry); drop that line otherwise. With `adapters:` the rest of the adapters' calls (`zone`, `wrap`, `overrides`, `launch`) are in [With `main: manual`](adapters.md#with-main-manual-appadapters):

```dart
// lib/main.dart, with `fespalier: {main: manual}`
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance(); // what startup() was
  final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
  await ready(container); // what ready() was: await the store, read eagerly, listen
  final router = AppRoutes.router();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppRoutes.attach(router, container); // the adapters', once; only when app.g.dart has it
    attach(router, container); // the app's
  });
}
```

Moving to the generated `main()` is then moving `prefs`/`overrides` into `startup()`, the body that follows the container into `ready()` and the post-frame lines into `attach()` (a manual app is untouched by all of this until it does).

**`splash.dart`** is a view file too (a class or `Widget splash({...})`), built **before** the app:
there is no `Theme`, `Localizations` or `ProviderScope` above it, only a text direction (from the
platform locale), so use plain widgets. It can ask for `error`, `stackTrace` and `retry`, by name. Each
is nullable: they are null while `startup()` (or, since 0.12.0, `ready()`) runs and set only after a failure (`retry` runs
`startup()` again, or only `ready()` when `startup()` had succeeded):

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
        : GestureDetector(
            onTap: retry,
            child: Text("Couldn't start: $error. Tap to try again"),
          ),
  );
}
```

**Sync stays sync.** A `startup()` that returns no `Future` (a `void`, a `List<Override>`) is done before
the first frame, and the first frame is the app. A `Future` costs a frame:

- with a `splash.dart`, it is shown meanwhile;
- without one, the first frame is deferred (`WidgetsBinding.deferFirstFrame`), so the platform's native
  splash (the Android and iOS launch screen, the web's loading page) stays until the app is ready.

No timer is involved. A `startup()` that throws is reported with `FlutterError.reportError` (so
`FlutterError.onError`, and anything listening to it, sees it) and shows the splash with `error` and
`retry`. Without a `splash.dart` it shows a plain "Couldn't start the app." with the error (in debug
builds) and "Try again".

**`zone()` has to work on the web.** It runs on every platform, so a zone implementation that needs `dart:io` or an isolate (a crash reporter's `runGuarded`, say) must behave on the web as well. The telemetry SDK `otel_zone` does not yet: its `runGuarded` never runs its body in a browser, which leaves the app blank. Until that is fixed, write this (`kIsWeb` is in `package:flutter/foundation.dart`):

```dart
Future<void> zone(Future<void> Function() body) => kIsWeb ? body() : observability.runGuarded(body);
```

**`main:` in the pubspec** (see [Config](configuration.md#main)) is `auto`, `generated` or `manual`. With `manual`, `fsp` writes no `main()` and reads none of the three files (each one that is there gets a warning saying so). Use it for an app that keeps its own `main()` or its own `GoRouter`, or when a file called `app.dart` at the root of the app folder is something else. Since 0.11.0 `adapters:` still works with it: `lib/app.g.dart` defines `AppAdapters`, which your `main()` calls ([With `main: manual`](adapters.md#with-main-manual-appadapters)).

**What is generated.** `AppMain` has three members:

- `AppMain.run()`: what `lib/main.dart` calls. Inside `zone()` (if any): the binding, the code of the
  [deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand) (loaded before the first frame,
  off the web, as `AppRoutes.loadDeferred()` does in a hand-written `main()`), then `runApp(root())`.
- `AppMain.root({router})`: the widget `runApp` gets, a `StartupGate` from `package:fespalier/startup.dart`:
  `startup()`, `splash.dart`, then a `ProviderScope` with the overrides, observers and retry around
  `app.dart` (with a `ready()`, a container the gate makes and hosts instead, see above). `router` builds the router (default: app.dart's `router()`, else `AppRoutes.router`).
- `AppMain.app(router)`: `app.dart`'s widget around a router, for tests (see [Testing](testing.md)).

**From a 0.7 app.** Nothing changes until you opt in. To move the code of a hand-written `main()` (the full upgrade notes are in [Migration](migration.md#081)):

| Today, in `lib/main.dart`                                                 | 0.8.1                                                                                        |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `MaterialApp.router(title:, theme:, builder:, routerConfig: _router)`     | the same widget in `lib/app/app.dart`, with `routerConfig: router`                           |
| `final _router = AppRoutes.router(restorationScopeId: …, observers: …)`   | `GoRouter router() => AppRoutes.router(…)` in app.dart, or `routerObservers` in startup.dart |
| `await Firebase.initializeApp(…)`, `usePathUrlStrategy()` before `runApp` | `startup()`                                                                                  |
| `ProviderScope(overrides: [x.overrideWithValue(v)])`                      | `startup()` returns `[x.overrideWithValue(v)]`                                               |
| `ProviderScope(retry: …, observers: …)`                                   | `retry()` and `providerObservers` in startup.dart                                            |
| `runZonedGuarded(…)`                                                      | `zone()` in startup.dart                                                                     |
| `if (!kIsWeb) await AppRoutes.loadDeferred();`                            | generated: delete it                                                                         |
| `void main() => runApp(…)`                                                | `Future<void> main() => AppMain.run();`                                                      |

A bad root file is an error with the way out in its message. An `app.dart` without a `router` parameter
says "the app's widget gets the router: add `required this.router` (a `GoRouter`) … If this file is not
the app around the router, move it out of the app folder's root or set `main: manual`".
