# Diagnostics: the generated `main()` (`app.dart`, `startup.dart`, `splash.dart`)

Since 0.8.1 (`cli/src/entry.rs`, `cli/src/config.rs`, `cli/src/resolve.rs`). Messages are quoted as
`fsp` prints them; the feature is in `fespalier` (`references/app-main.md`). An error leaves
`lib/app.g.dart` **and** `lib/app.main.g.dart` untouched (`N error(s); lib/app.g.dart and lib/app.main.g.dart left unchanged`).

## Config (`pubspec.yaml`)

Printed without a code frame, exit 1.

| Message                                                                                                                                             | Cause and fix                                                                                       |
| --------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| ``invalid pubspec.yaml: fespalier.main: unknown variant `always`, expected one of `auto`, `generated`, `manual` at line 3 column 9``                | `main:` is `auto`, `generated` or `manual`                                                          |
| `` `fespalier.output_manifest` is `lib/app.main.g.dart`, the file the generated main() goes in (`output` with `.main.g.dart`); pick another name `` | `output_manifest` named the generated main's path (`output` with `.main.g.dart`): pick another name |

## `adapters:` (since 0.9.0)

Printed without a code frame, exit 1. `adapters:` is explained in `fespalier` (`references/app-main.md`); an `fsp`
older than 0.9.0 rejects the key itself, as an unknown field (see `diagnostics-config-and-meta.md`).

| Message                                                                                                                                                                                 | Cause and fix                                                                                                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `invalid pubspec.yaml: fespalier.adapters: invalid type: string "fespalier_sentry", expected a sequence at line 3 column 13`                                                            | `adapters:` is a list: `adapters: [fespalier_sentry]`                                                                                  |
| `invalid pubspec.yaml: fespalier.adapters[0]: invalid type: map, expected a string at line 4 column 7` (a nested list says `invalid type: sequence`)                                    | An entry is a package name, nothing more (no options per adapter: they come from `--dart-define`)                                      |
| `` `fespalier.adapters` lists Dart packages by name, like `fespalier_sentry`; `Sentry` is not one ``                                                                                    | A name that is not a Dart package name (lowercase letters, digits and `_`, starting with a letter); a YAML number reads as its text    |
| `` `fespalier.adapters` lists `fespalier_sentry` twice ``                                                                                                                               | Each package once                                                                                                                      |
| `` `fespalier.adapters` lists packages that plug into fespalier's generated main(); `fespalier` is the framework itself, not an adapter ``                                              | Remove `fespalier` from the list                                                                                                       |
| `` `fespalier.adapters` lists `fespalier_sentry`, which is not under `dependencies:` in pubspec.yaml; add it there (next to fespalier, at the same git ref) ``                          | Add the package under `dependencies:` (`dev_dependencies:` does not count: the generated `main()` imports it)                          |
| `` `fespalier.adapters` is wired by the generated main(), and `main: manual` writes none; remove `main: manual`, or wire each adapter in your own main() and remove `adapters` ``       | `main: manual` writes no `main()`, so nothing would call the adapters                                                                  |
| warning ``app.dart's router() builds the router itself, so the adapters' router observers are not added: pass `observers: AppMain.routerObservers()` to `AppRoutes.router(...)` there`` | app.dart's `router()` does not mention `routerObservers`: pass `observers: AppMain.routerObservers()` to `AppRoutes.router(...)` there |

## Root files

| Message                                                                                                                                                          | Cause and fix                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| warning `app.dart is only read at the root of the app folder, so this one is ignored` (the same with `startup.dart`, `splash.dart`)                              | A copy in a subfolder: move it to the root or delete it                                                    |
| warning `` `main: manual` is set in pubspec.yaml, so app.dart is not read and no lib/app.main.g.dart is written `` (the same with `startup.dart`, `splash.dart`) | `main: manual` ignores the three files; remove the key (or the files) if you wanted the generated `main()` |

## `app.dart`

| Message                                                                                                                                                                                                                                               | Cause and fix                                                                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `expected a public widget class` / ``expected one public widget class, found A, B; make the others private (`_Name`)``                                                                                                                                | The view-file rules (`fespalier` `file-kinds.md`): one widget class, or `Widget app(...)`                           |
| ``the app's widget gets the router: add `required this.router` (a `GoRouter`) and pass it to `MaterialApp.router(routerConfig: router)`. If this file is not the app around the router, move it out of the app folder's root or set `main: manual` `` | No parameter named `router` or typed `GoRouter`. Add it; or the file is not the app (rename it into `_components/`) |
| `` `flavor`: app.dart's widget is built by the generated main(), which only gives it `router`; make `flavor` optional, or work it out inside the widget ``                                                                                            | Another **required** parameter (here `flavor`): make it optional, or compute it in `build`                          |
| `` `router` must be a `GoRouter` (or a `RouterConfig<Object>`), not String ``                                                                                                                                                                         | The `router` parameter has another type (here `String`)                                                             |
| `` router() builds the app's router: declare it `GoRouter router()`, with no parameters, and return `AppRoutes.router(...)` ``                                                                                                                        | app.dart's optional `router()` takes parameters or returns another type                                             |

## `startup.dart`

| Message                                                                                                                                                                     | Cause and fix                                                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| ``startup.dart exports none of `startup()`, `zone()`, `providerObservers`, `routerObservers` or `retry()`; add one, or delete the file``                                    | The file exports none of the names `fsp` reads                                         |
| ``startup() takes no parameters: it runs before the ProviderScope exists, so return the overrides it makes (`Future<List<Override>> startup()`) instead``                   | `startup()` cannot take a `Ref`: return the `Override`s instead                        |
| `` startup() must return `Future<void>` or `void`, or the providers it overrides: `Future<List<Override>>` or `List<Override>` ``                                           | Any other return type, or none                                                         |
| ``zone() wraps all of main(): declare it `Future<void> zone(Future<void> Function() body)` and call `body()` inside it``                                                    | `zone` has another shape (`FutureOr<void>` as the return type is fine)                 |
| `` retry() is the ProviderScope's retry policy: `Duration? retry(int retryCount, Object error)` ``                                                                          | `retry` has another shape                                                              |
| `` `providerObservers` is a list, not a function: `List<ProviderObserver> get providerObservers => [...];` `` (and the same for `routerObservers` with `NavigatorObserver`) | Written as a function: make it a getter or a variable                                  |
| ``app.dart's router() builds the router itself, so `routerObservers` is not used: pass them to `AppRoutes.router(observers: ...)` there, and remove this one``              | `routerObservers` and app.dart's `router()` together: pass the observers in `router()` |

## `splash.dart`

| Message                                                                                                                                                                  | Cause and fix                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `` splash.dart is shown while startup() runs too, when there is no `error`: make it `Object? error` `` (the same for `StackTrace? stackTrace` and `VoidCallback? retry`) | A non-nullable `error`, `stackTrace` or `retry`: all three are null while `startup()` runs         |
| ``splash.dart is built before the app, so it can ask only for `error`, `stackTrace` and `retry` (each null while startup() runs); `theme` is none of them``              | Another required parameter (here `theme`): there is no `Theme`, `ProviderScope` or `Localizations` |
| warning `splash.dart is shown while startup() runs and when it fails, and startup.dart has no startup(), so it is never shown`                                           | A splash with nothing to wait for                                                                  |

## At run time

| What you see                                                                       | Cause and fix                                                                                                                                                   |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| "Couldn't start the app." and "Try again" (the error text too, in debug builds)    | `startup()` threw and there is no `splash.dart`. The error was also reported to `FlutterError.onError` ("while running startup() in startup.dart")              |
| A widget test fails with the `startup()` error                                     | It was reported; `tester.takeException()` takes it                                                                                                              |
| The web app is blank when `zone()` calls a telemetry SDK's `runGuarded`            | The SDK's `runGuarded` never runs its body in a browser (`otel_zone`): `kIsWeb ? body() : observability.runGuarded(body)`                                       |
| Web URLs still have `#` with the generated `main()`                                | Call `usePathUrlStrategy()` as the first line of `startup()` (and add `flutter_web_plugins` to `pubspec.yaml`)                                                  |
| `adapters:` lists a package and nothing happens (no zone, no observer, no wrapper) | `lib/main.dart` does not call the generated main: it has to be `Future<void> main() => AppMain.run();`. `fsp` does not read `lib/main.dart`, so it says nothing |
| In debug, Riverpod says "Tried to override a provider twice" at startup            | An adapter's `overrides()` and `startup()` override the same provider (the adapters' come first): override it in one place                                      |
