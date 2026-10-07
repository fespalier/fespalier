# `main()`: app.dart, startup.dart and splash.dart

Since 0.8.1 the framework can own `main()`. You write what is yours, in up to three files at the
**root** of the app folder (a copy below it is ignored, with a warning), and `fsp` writes
`lib/app.main.g.dart`, whose `AppMain` runs them. `lib/main.dart` stays yours, and is one line:

```dart
// lib/main.dart
import 'package:my_app/app.main.g.dart';

Future<void> main() => AppMain.run();
```

```text
lib/app/
  app.dart       the widget around the router: MaterialApp.router, theme, title, locales
  startup.dart   what runs before the app: startup(), zone(), providerObservers, routerObservers, retry()
  splash.dart    shown while an async startup() runs, and when it fails
```

All three are optional. With none of them, `main: auto` (the default) writes nothing and your own
`main()` keeps working; any one of them makes `fsp` write `lib/app.main.g.dart`, and so does an
[`adapters:`](adapters.md) list (since 0.9.0). `app.g.dart` is the same bytes whether
or not they exist.

**`app.dart`** is a view file: one public widget class (of any kind: a `ConsumerWidget` to read a
theme-mode provider is the point) or a function `Widget app({required GoRouter router})`. It
gets the router as a parameter named `router`, or the one typed `GoRouter` (`RouterConfig<Object>`
works too); every other parameter has to be optional:

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

/// Optional: how the router is built. Called once, after startup(). Call AppRoutes.router().
GoRouter router() => AppRoutes.router(restorationScopeId: 'router');
```

Without `router()` the router is `AppRoutes.router()`, with the `routerObservers` of
startup.dart if it has any. Without an `app.dart` (with `main: generated`) the app is
`MaterialApp.router(routerConfig: router)`.

**`startup.dart`** exports, by name, any of:

| Export                                | What it is                                                                                                                                                              |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `startup()`                           | No parameters. Returns `void`, `Future<void>` or `FutureOr<void>`; or the providers to override: `List<Override>`, `Future<List<Override>>`, `FutureOr<List<Override>>` |
| `zone(Future<void> Function() body)`  | Wraps **all** of `main()`: the binding, `startup()` and `runApp` run inside `body`. Returns `Future<void>` or `FutureOr<void>`; call `body()` in it                     |
| `providerObservers`                   | A list (a variable or a getter) of `ProviderObserver`s for the `ProviderScope`; read after `startup()`                                                                  |
| `routerObservers`                     | A list of `NavigatorObserver`s for the router; read after `startup()`. Not with a `router()` in app.dart: pass them there                                               |
| `retry(int retryCount, Object error)` | `Duration?`: the `ProviderScope`'s retry policy                                                                                                                         |

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

At least one of them has to be there. `startup()` runs **before the router exists**: the router is
built once, after `startup()`, and disposed with the app. That is also why `usePathUrlStrategy()`
belongs in `startup()` (checked in a release web build with a 300 ms async `startup()`: a deep link
`/items/2?qty=3` opened the item page, and tapping a link put `/about` in the address bar, with no `#`).

**`splash.dart`** is a view file too (a class or `Widget splash({...})`), built **before** the
app: there is no `Theme`, `Localizations` or `ProviderScope` above it, only a text direction
(from the platform locale), so use plain widgets. It can ask for `error`, `stackTrace` and
`retry`, by name; each is nullable, because they are null while `startup()` runs and set only after
a failure (`retry` runs `startup()` again):

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

**Sync stays sync.** A `startup()` that returns no `Future` (a `void`, a `List<Override>`) is done
before the first frame, and the first frame is the app. A `Future` costs a frame: with a `splash.dart`
it is shown meanwhile; without one, the first frame is deferred
(`WidgetsBinding.deferFirstFrame`), so the platform's native splash (the Android and iOS launch screen,
the web's loading page) stays until the app is ready. No timer is involved. A `startup()` that
throws is reported with `FlutterError.reportError` (so `FlutterError.onError`, and anything listening
to it, sees it) and shows the splash with `error` and `retry`, or, without a `splash.dart`, a plain
"Couldn't start the app." with the error (in debug builds) and "Try again".

**`zone()` has to work on the web.** It runs on every platform, so a zone implementation that
needs `dart:io` or an isolate (a crash reporter's `runGuarded`, say) must behave on the web as well.
The telemetry SDK `otel_zone` is one that does not yet: its `runGuarded` never runs its body in a
browser, which leaves the app blank. Until that is fixed, write
`Future<void> zone(Future<void> Function() body) => kIsWeb ? body() : observability.runGuarded(body);`
(`kIsWeb` is in `package:flutter/foundation.dart`).

**`main:` in the pubspec** (see [Config](configuration.md#main)) is `auto`, `generated` or `manual`.
With `manual`, `fsp` writes no `main()` and reads none of the three files (each one that is
there gets a warning saying so): use it for an app that keeps its own `main()` or its own
`GoRouter`, or when a file called `app.dart` at the root of the app folder is something else.

**What is generated.** `AppMain` has three members:

- `AppMain.run()`: what `lib/main.dart` calls. Inside `zone()` (if any): the binding, the code of the
  [deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand) (loaded before the first frame, off the web,
  as a hand-written `main()` did with `AppRoutes.loadDeferred()`), then `runApp(root())`.
- `AppMain.root({router})`: the widget `runApp` gets, a `StartupGate` from `package:fespalier/startup.dart`:
  `startup()`, `splash.dart`, then a `ProviderScope` with the overrides, observers and retry around
  `app.dart`. `router` builds the router (default: app.dart's `router()`, else `AppRoutes.router`).
- `AppMain.app(router)`: `app.dart`'s widget around a router, for tests (see [Testing](testing.md)).

**From a 0.7 app.** Nothing changes until you opt in. To move the code of a hand-written `main()`:

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

A bad root file is an error with the way out in its message: an `app.dart` without a `router`
parameter says "the app's widget gets the router: add `required this.router` (a `GoRouter`) … If this
file is not the app around the router, move it out of the app folder's root or set `main: manual`".
`examples/minimal`, `shop` and `features` use the generated `main()` (`features` has all three
files and a `zone()`), and `examples/tabs` keeps a `main()` of its own.
