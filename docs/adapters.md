# Adapters in the generated `main()`

Since 0.9.0 a package can plug into the generated `main()` (the [section above](app-startup.md))
with one line in `pubspec.yaml`, instead of code you write in `startup.dart`:

```yaml
dependencies:
  my_tools: ^1.0.0 # a package that ships lib/fespalier_adapter.dart
  my_reporter: ^1.0.0
fespalier:
  adapters: [my_tools, my_reporter] # Dart package names, in order
```

**The convention.** `fsp` has no table of packages and reads no manifest: for each name `n` it imports
`package:n/fespalier_adapter.dart` and calls its top-level `adapter`, a `FespalierAdapter` from
`package:fespalier/startup.dart`. The output depends on the pubspec alone, never on `pub get` or the pub
cache, so `fsp check` gives the same bytes before and after it, and a package of your own can be an adapter:

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

The adapters on the [roadmap](../ROADMAP.md) (error reporting, analytics, notification and shortcut launches, ...)
are packages of this kind. `FespalierAdapter` has six members, each with a default that adds nothing, so an
adapter overrides what it needs:

| Member                | When it runs                                                                           | What it is for                                                                                                 |
| --------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `zone(body)`          | Around **all** of `main()`, outside startup.dart's `zone()`; before the binding exists | An SDK that wraps the app (`SentryFlutter.init(..., appRunner: body)`). Call `body` once                       |
| `beforeRun()`         | In `main()` after `WidgetsFlutterBinding.ensureInitialized()`, before `runApp`         | Installing a telemetry sink (`FespalierTelemetry.add`), opening a store. Return `null` for nothing to wait for |
| `overrides()`         | Once, after `startup()` succeeded, **before** `startup()`'s own overrides              | `dataCacheStorage`, `reconnectSignal`, a flag source                                                           |
| `providerObservers()` | With `startup()`'s `providerObservers`, the adapters' first                            | A `ProviderObserver`                                                                                           |
| `routerObservers()`   | When the router is built, before startup.dart's `routerObservers`                      | A `NavigatorObserver` (a new one on each call: an observer belongs to one navigator)                           |
| `wrap(root)`          | Around the root widget, outside the `ProviderScope` and the splash too                 | `SentryWidget`, `PostHogWidget`                                                                                |

The first package in the list is the outermost: its zone and its wrapper go around the others'. Each name
must be under `dependencies:` in the pubspec; a name that is
not a package name, is listed twice, is `fespalier` itself, or is not a dependency is an error, and so is
`main: manual` with `adapters:` (the generated `main()` is what calls them). `adapters:` makes `main: auto`
write `lib/app.main.g.dart` even with no `app.dart`, `startup.dart` or `splash.dart`. There are no
per-adapter options in the pubspec: what an adapter needs at deploy time comes from `--dart-define`, and
anything custom stays in `startup.dart`, which is yours.

With `adapters: [my_tools, my_reporter]` and a `startup.dart` with a `zone()` and a
`routerObservers`, the lines of `lib/app.main.g.dart` that are new (the rest is what the root files
alone make):

```dart
import 'package:my_tools/fespalier_adapter.dart' as _a0;
import 'package:my_reporter/fespalier_adapter.dart' as _a1;

  static Future<void> run() => _a0.adapter.zone(() => _a1.adapter.zone(() => _i1.zone(_main)));

    if (_a0.adapter.beforeRun() case final ready?) await ready;
    if (_a1.adapter.beforeRun() case final ready?) await ready;

  static Widget root({GoRouter Function() router = _router}) => _a0.adapter.wrap(_a1.adapter.wrap(StartupGate(
    extraOverrides: _extraOverrides,
    // ... overrides:, observers:, router:, app: as before
  )));

  static List<NavigatorObserver> routerObservers() => [..._a0.adapter.routerObservers(), ..._a1.adapter.routerObservers(), ..._i1.routerObservers];

GoRouter _router() => AppRoutes.router(observers: AppMain.routerObservers());
List<Override> _extraOverrides() => [..._a0.adapter.overrides(), ..._a1.adapter.overrides()];
```

Without `adapters:` none of these lines is written, and the file is what it was.

**What stays true.** An adapter follows the rules of fespalier itself: no timer, sync stays sync (a
`beforeRun()` that returns `null` is not awaited, so no `Future` and no microtask; a `Future` is awaited and
delays the first frame, with the platform's native splash still showing, so keep it to a local read, never
the network), and nothing touches a platform plugin until it is used, so `AppMain.root()` boots in a widget
test. `overrides()` goes before `startup()`'s: overriding a provider `startup()` also overrides is
Riverpod's "Tried to override a provider twice" in debug.

**Two things to check.**

- **`lib/main.dart` has to call `AppMain.run()`.** Adapters are wired by the generated `main()`: an app
  whose own `main()` still runs `runApp` by hand ignores them, without a message (`fsp` does not read
  `lib/main.dart`). The line is `Future<void> main() => AppMain.run();`.
- **An `app.dart` that builds the router** (`GoRouter router()`) has to pass the adapters' observers on:
  `AppRoutes.router(observers: AppMain.routerObservers())`. Without that `fsp` warns, on app.dart at the
  function: ``app.dart's router() builds the router itself, so the adapters' router observers are not added: pass `observers: AppMain.routerObservers()` to `AppRoutes.router(...)` there``.

**In tests.** `pumpRouter(tester, router, app: AppMain.app)` (see [Testing](testing.md)) never sees the
adapters, and neither do the [`fsp test`](cli.md#route-smoke-tests-fsp-test) smoke tests. `AppMain.root()` is the
app as it runs, adapters included.
