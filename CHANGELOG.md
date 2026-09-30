# Changelog

## Unreleased

- **Typed data helpers on routes.** A route with a `data.dart` gets `static watch(ref, {keys})`
  (an `AsyncValue<T>`), `static read(ref, {keys})` (a `Future<T>`, kept alive until it
  completes) and an instance `prefetch(ref, {keepFor})` that starts the load and keeps the result
  (30 s by default) so the next page shows it at once. `T` is inferred from the provider, so
  the generated file still never names your types; that's why `watch` and `read` are static and
  not `ProductRoute(id: 2).watch(ref)`. New reserved names: `watch`, `read`, `prefetch`, `ref`
  and `keepFor` can't be segment names, and a query parameter can't be called like a member of
  the route class (`go`, `read`, `refresh`, ...). Regenerate `app.g.dart`.
- **Section data.** A `data.dart` in a folder that has a `layout.dart` and no `page.dart` (a
  page-less folder or a `(group)`) is the data of the whole section: the layout waits for it,
  showing the nearest `loading.dart` / `error.dart`, and the layout and the pages below can take
  it by type or as a parameter called `data`. The layout and pages share one provider, so
  `data()` runs once. Two data.dart files yielding the same type for one parameter are an
  error. Segments only, no query parameters.
- **`not_found.dart` in any folder.** The nearest one covers unknown URLs under its folder
  (`AppRoutes.notFound(uri)`, used by the router's `errorBuilder`) and unparsable segments in
  the routes below it (a `(group)`'s too). It used to be an error outside the root.
- **`package:fespalier/testing.dart`**: `pumpRouter(tester, router, {overrides, container,
  settle})` and `currentLocation(tester)`. `fespalier` now lists `flutter_test` (an SDK
  package) as a dependency; the main library doesn't import it.
- Runtime: `DataRef.readData` / `prefetchData` on `WidgetRef`, `SectionView`,
  `nearestNotFound`, `prefetchKeepAlive`.

## 0.1.1 — 2026-09-30

Fixes from first-use testing.

- Generated `data()` providers no longer use Riverpod 3's automatic retry (it took about
  38 s of backoff before `error.dart` showed). `error.dart` now shows at once, and its
  `retry` is the retry path. Providers you write yourself keep Riverpod's default unless
  you pass `retry:`. Regenerate `app.g.dart` to pick this up.
- `fsp watch` no longer regenerates in a loop while idle: it ignores access and metadata
  events and its own output, and stays quiet when a run changes nothing.
- A file the parser can't fully read is now a warning (the Dart compiler reports the exact
  error) instead of passing silently.
- Parameters bound by name (`uri`, `child`, `error`, `stackTrace`, `retry`, `shell`, and
  `transition`'s `key` and `state`) are type-checked.
- Clearer errors: a URL served by two pages is one error naming both files; unreachable
  route and tab-start errors carry a code frame; an invalid `page.dart` no longer also
  warns that its folder has no page.
- `fsp gen`, `fsp check` and `fsp new` print a success line. `fsp new` regenerates right
  away, skips `page.dart` for a `(group)` folder, takes `--no-page`, and lists the files it
  created if generation fails.
- Docs: `GuardResult`, optional `not_found.dart`, deleting the stale `test/widget_test.dart`
  after `fsp init`, tab layouts without a page, retries, and a Testing section.

## 0.1.0 — 2026-09-30

Initial version.

- File-tree routing for Flutter: routes are described by small files under `lib/app/`,
  built on go_router, Riverpod and flutter_hooks, with no build_runner.
- File kinds: `page`, `data`, `loading`, `error`, `layout`, `guard`, `transition` and
  `not_found`. `loading`, `error` and `transition` are inherited by subfolders; `layout`
  becomes a ShellRoute.
- Constructor-based binding: the generator reads each constructor and fills parameters by
  name, by type (the data, the error, the child, the `Uri`) or from the query string.
  There are no base classes or interfaces to implement.
- Path segments (`$id`) and query parameters, typed as `String`, `int`, `double` or `bool`.
  An unparsable segment goes to `not_found.dart`. Files that disagree on a type are an
  error.
- Typed routes (`ProductRoute(id: 42).go(context)`), with `.location` and query
  parameters as optional arguments. Each route with a `data.dart` exposes `XRoute.data`
  as a Riverpod provider, and `refresh(ref)`.
- `data.dart` as a function (`Future<T>`, `Stream<T>` or `T`, wrapped in an autoDispose
  provider) or as your own `FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or
  `StreamNotifierProvider`.
- `(group)` folders: a layout, loading and error view that apply to a set of routes
  without changing their URLs.
- Tab layouts: a `layout.dart` that asks for a `StatefulNavigationShell` becomes a
  `StatefulShellRoute.indexedStack`, with one branch per subfolder (order set by an
  optional `const tabs = [...]`).
- Route order is static-first (`/about` before `/:slug`). Duplicate URLs and unreachable
  routes are errors.
- `transition.dart`: sets how a folder's routes animate (nearest one wins), with ready-made
  `Transitions`: `fade`, `slide`, `none`, `material` and `cupertino`.
- `fsp` generator (Rust, tree-sitter based): `fsp gen`, `fsp check` (for CI; writes
  nothing), `fsp watch`, `fsp new` (scaffolds route files) and `fsp init` (sets up an
  existing Flutter project without overwriting anything). Errors point at the offending
  parameter or declaration, and `app.g.dart` is left untouched while there are any.
- Optional `fespalier:` section in `pubspec.yaml` to move the app folder (`app_dir`, default
  `lib/app`) and the generated file (`output`, default `lib/app.g.dart`).
- Works with go_router 17 and 18. On go_router 18 with Flutter's `MaterialApp`, routes
  without a `transition.dart` don't animate; see the README's Getting started.
- Output is a single readable `lib/app.g.dart` with `AppRoutes.router()` for a whole app
  and `AppRoutes.mount(at:)` to embed it in an existing GoRouter.
- Prebuilt `fsp` binaries for Linux, macOS and Windows on each GitHub Release, and an
  `install.sh` installer, so installing doesn't need Rust.
