# Upgrading from fespalier 0.7 to 0.8

As of v0.8.0 (the generated `main()`; see `fespalier` `references/app-main.md`). The package
and `fsp` move together: bump both, regenerate, commit.

## What changes without you doing anything

Nothing in the generated code. An app with no `app.dart`, `startup.dart` or `splash.dart` at the
root of its app folder gets **no new file and a byte-identical `lib/app.g.dart`**. Every other new
feature of 0.8.0 is opt-in.

## The one thing that can break: a root file that is something else

`fsp` now reads `app.dart`, `startup.dart` and `splash.dart` at the **root** of the app folder
(`main: auto`). An app that already has a `lib/app/app.dart` which is not "the widget around the
router" fails with

```text
the app's widget gets the router: add `required this.router` (a `GoRouter`) and pass it to `MaterialApp.router(routerConfig: router)`. If this file is not the app around the router, move it out of the app folder's root or set `main: manual`
```

Move the file into `_components/` (a private folder is never read), or set `main: manual` in the
`fespalier:` section: then the three files are not read at all (one warning each: `` `main: manual` is
set in pubspec.yaml, so app.dart is not read and no lib/app.main.g.dart is written ``). A
`splash.dart`, `startup.dart` or `app.dart` **below** the root was ignored before and still is, with a
warning now (`app.dart is only read at the root of the app folder, so this one is ignored`).

## Moving a hand-written `main()` to the generated one

Optional. `fsp init` (or `main: generated`) writes `lib/app/app.dart`; the printed `main.dart` is
`Future<void> main() => AppMain.run();`.

| Today, in `lib/main.dart`                                                 | 0.8.0                                                                                        |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `MaterialApp.router(title:, theme:, builder:, routerConfig: _router)`     | the same widget in `lib/app/app.dart`, with `routerConfig: router`                           |
| `final _router = AppRoutes.router(restorationScopeId: …, observers: …)`   | `GoRouter router() => AppRoutes.router(…)` in app.dart, or `routerObservers` in startup.dart |
| `await Firebase.initializeApp(…)`, `usePathUrlStrategy()` before `runApp` | `startup()`                                                                                  |
| `ProviderScope(overrides: [x.overrideWithValue(v)])`                      | `startup()` returns `[x.overrideWithValue(v)]`                                               |
| `ProviderScope(retry: …, observers: …)`                                   | `retry()` and `providerObservers` in startup.dart                                            |
| `runZonedGuarded(…)`                                                      | `zone()` in startup.dart (it has to work on the web)                                         |
| `if (!kIsWeb) await AppRoutes.loadDeferred();`                            | generated: delete it                                                                         |
| `void main() => runApp(…)`                                                | `Future<void> main() => AppMain.run();`                                                      |

Two changes of behaviour to expect when you do: the router is built **after** `startup()` (not at
the top of `main.dart` as a `final`), and an async `startup()` shows `splash.dart` (or keeps the native
splash) instead of a frame you built by hand.

Tests: `pumpRouter(tester, router, app: AppMain.app)` (since 0.8.0) boots a page in `app.dart`'s
theme and localizations; `startup()` does not run there, so pass its overrides as `overrides`.
Pump `AppMain.root()` to boot everything.

## Also new in 0.8.0

- `fsp gen` names every file it writes: `✓ 12 routes → lib/app.g.dart, lib/app.main.g.dart`.
- `fsp init` writes `app.dart` (not with `main: manual`).
- `fespalier: main:` (`auto`, `generated`, `manual`).
