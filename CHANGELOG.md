# Changelog

## Unreleased

### IntelliJ IDEA and Android Studio plugin

- New `editors/intellij/`, a Kotlin plugin on top of `fsp check --json` (the counterpart of the
  VS Code extension). Files under the app folder (`fespalier: app_dir:`, `lib/app` by default)
  get the reported errors and warnings underlined in the editor, and saving one checks again;
  *Tools | fespalier: Generate* runs `fsp gen` and *Tools | fespalier: Check* checks on demand,
  each ending in a notification, which also says when `fsp` could not be run. Settings | Tools |
  fespalier chooses the runner (auto: `fsp` from `PATH`, else `dart run fespalier`) and the
  path to `fsp`. Platform 252 (2025.2) and later; built with JDK 21 and the IntelliJ Platform
  Gradle Plugin 2. Not on the JetBrains Marketplace yet: build it with `./gradlew buildPlugin`
  and install the zip from disk (README, "Editor support"). CI builds and tests it.

### Data refresh and retry

- **Behaviour change: generated `data()` providers no longer switch off Riverpod's retry.**
  0.1.1 gave them `retry: (retryCount, error) => null`, which overrode the app's
  `ProviderScope(retry: ...)`. Now the app's policy applies (Riverpod's default, 10 retries
  with backoff, when it sets none), so a failing `data.dart` is run again in the background.
  What the route shows is unchanged (see `keep_previous`), but the provider runs more than
  once, so a test that counts calls or ends with a pending timer will notice. To keep the old
  behaviour, add `data_retry: none` to the `fespalier:` section of `pubspec.yaml`, or give the
  app a retry policy of its own. Regenerate `app.g.dart`.
- **`DataView` keeps the old state on screen while `data.dart` reloads.** `loading.dart` is
  now only for the first load. A refresh or reload keeps rendering the old value (or error),
  and a provider that failed and is being retried keeps showing `error.dart` for the whole
  retry window, then the data once a retry succeeds. Before, a reload driven by a dependency
  and every retry blinked to `loading.dart`. A section's data reloading no longer shows loading
  for the whole section. `keep_previous: false` restores the loading view for every load.
  (`AsyncValue.when` with `skipLoadingOnReload` and `skipLoadingOnRefresh`.)
- New `fespalier:` config keys: `data_retry: inherit | none` (default `inherit`) and
  `keep_previous: true | false` (default `true`). The generated `DataView` gets a
  `keepPrevious:` argument.
- **`List` query parameters can key `data.dart`.** `data(Ref ref, {List<String> tags = const []})`
  is accepted, and `?tags=a&tags=b` is one provider whatever list instance the page builds:
  the generated key wraps the list in the new runtime `QueryList<T>`, a list with value
  equality. `data()` and the typed helpers still take a plain `List<T>`. It used to be an error.
- `pumpRouter` in `package:fespalier/testing.dart` takes `retry:` and defaults to no retries,
  so a failing `data.dart` shows `error.dart` at once and leaves no timer behind in a test.
  Pass `ProviderContainer.defaultRetry` (or `null`, Riverpod's default) to test retries.
- **`fsp watch` parses only what changed.** It keeps the parse results of every file between
  runs, keyed by the file's source, so a save re-parses the file you saved and nothing else.
  On a synthetic 1,000-route app a regeneration after a one-file edit takes about 32 ms
  instead of about 50 ms in a release build (the rest is scanning, resolving and emitting).
  `gen` and `check` are unchanged.
- **VS Code extension** (`editors/vscode/`, not published yet): `fsp check --json` on save
  becomes Problems panel diagnostics, plus `fespalier: generate`, `fespalier: check` and a
  status bar item. Runs `fsp`, or `dart run fespalier` when `fsp` isn't on `PATH`.
- **Homebrew and Scoop.** Each release attaches `fsp.rb` and `fsp.json`, rendered from the
  archives' checksums by `scripts/packaging.py`, and pushes them to a tap and bucket when
  the `PACKAGING_TOKEN` secret exists.
- **pub.dev.** `flutter pub publish --dry-run` is clean and checked in CI (the package gains
  a shorter description and `example/README.md`). New `Publish to pub.dev` workflow: publishes
  through GitHub OIDC automated publishing when run from the `v<version>` tag.

### `data.dart` can select a provider you already have

- **New third `data.dart` form: a selector.**
  `ProviderListenable<AsyncValue<ProductView>> data({required String productId}) => productProvider(productId);`
  is recognised by its return type (and no `Ref` parameter). Its named parameters are segments
  and query parameters exactly as in the function form (any other parameter is an error at
  it), and `T` from `AsyncValue<T>` is what a page's parameter is bound to by type. Nothing is
  wrapped: `XRoute.data` is the selected provider (`ProductDetailRoute.data('x') ==
  productProvider('x')`), `DataView` watches it directly, and `watch`, `read`, `prefetch` and
  `refresh` target it, so a `riverpod_generator` provider is fetched once per navigation, keeps
  its own `retry`, `keepAlive` and dependencies, and keeps the error it holds while it retries.
  `data_retry` doesn't apply to it. `refresh` and `error.dart`'s retry invalidate the selected
  provider (`refresh` also reads it, so it runs once) through new runtime helpers,
  `invalidateSelected`, `refreshSelected` and `readSelected` on `WidgetRef`, which check at
  run time that the listenable is a provider and throw a `StateError` naming the fix if not.
  Regenerate `app.g.dart` (the generated `DataView` calls `invalidateSelected` for selectors).
- `package:fespalier/fespalier.dart` re-exports `ProviderListenable`; `prefetchData` takes any
  `ProviderListenable<AsyncValue<…>>`.
- A selector can be keyed by a catch-all segment like the function form: the key is the
  encoded path (`restKey`) and the selector function gets the `List<String>` back (`restParts`).
- README: `data.dart` has three forms now, with when to use each.

### Paths

- **Catch-all segments.** A folder `$$rest` matches one or more remaining segments and
  `$$$rest` zero or more; the page takes them as a `List<String>`, each part decoded on
  its own. It is a go_router parameter with its own pattern (`docs/:rest(.+)`), so deep
  links, guards and redirects work as for any route; `$$$rest` is two routes with one builder
  (`/files` and `/files/:path(.+)`). The typed route is `DocsRoute(rest: ['a', 'b c'])`
  (`/docs/a/b%20c`, each part encoded). Siblings are ordered static, dynamic, then catch-all,
  and the unreachable-route check knows catch-alls. `data.dart` can be keyed by one (the
  provider takes the path as an encoded string: new `restKey` / `restParts`). Limits: last
  segment only, `List<String>` only, nothing below it, no `not_found.dart` in it.
  `fsp new 'docs/[...rest]'` and `'docs/[[...rest]]'` scaffold them. Runtime: `Segment.asRest`,
  `restPath`, `restKey`, `restParts`. `fsp routes` shows `/docs/*rest` and `/files/*path?`.
- **`case_sensitive: false`** under `fespalier:` in pubspec.yaml emits `caseSensitive: false` on
  every route, so `/Products` reaches `/products` (parameters keep their case). The
  nearest-`not_found.dart` lookup (`nearestNotFound(..., caseSensitive:)`) follows it. The default
  is unchanged.
- **Trailing slashes** need no option: go_router drops them before matching, so `/products/`
  and `/products/?page=2` reach `/products` (checked on go_router 17.5 and 18, and now tested).
- **Typed `extra`.** A page parameter called `extra` receives what `context.go(location,
  extra: obj)` passed, and the typed route takes it: `NoteRoute(id: 3).go(context, extra:
  note)` (also `push` and `replace`), checked at compile time. The parameter must be nullable:
  the URL alone can't produce it, so a deep link or a reload gets `null`. The generated file
  imports the type by name (`show`) from `page.dart`'s imports, the one place it names one of
  your types. Runtime: `extraOf<T>(state)`. New reserved name: `extra` can't be a segment.

### `dart run fespalier`: pinned checksums, offline, "generate, don't commit"

- **Checksums are pinned inside the package.** `lib/src/release_checksums.dart` holds the
  SHA-256 of every `fsp` archive of the package's own version, and `dart run fespalier`
  refuses a download that doesn't match (before, the `.sha256` came from the same release as
  the binary, so it caught corruption but not a tampered release). A package with no pins for
  its version (a development build from a branch) still checks the release's `.sha256` and
  prints one warning line.
- **Two-phase release.** The *Release* workflow (manual publish) builds the five targets, then
  commits the pins to `main` as `Pin fsp <version> checksums` (`scripts/pin_checksums.py`,
  tested by `scripts/test_pin_checksums.py`), and creates the `v<version>` tag and the Release
  at that commit, so a git dependency on the tag carries the pins. The binaries are built from
  the parent commit and differ only by that one file. Manual publish must now run on the
  default branch, and the workflow needs to be able to push to it. After a version bump, run
  `python3 scripts/pin_checksums.py --reset`; `cli/tests/versions.rs` checks that the file pins
  nothing or the pubspec's version.
- **Offline with an empty cache** stops with one line: `fespalier: fsp 0.3.0 isn't cached and
  the download failed (offline?); run once online or set FSP_BINARY`. A cached binary never
  touches the network.
- README: a "Generate, don't commit" mode (gitignore `lib/app.g.dart`, run
  `dart run fespalier gen` before `flutter analyze` in CI; the generator follows
  `pubspec.lock`), next to the committed mode with `fsp check`, which still writes nothing.

### Route manifest and metadata

- A generated route manifest: `AppRoutes.all`, `byType` (typed-route class) and `byPath` (path
  template), a `const` list of `RouteInfo`s (`AppManifest`) with each route's typed route,
  path, folder, `(group)` chain, layout chain, `page` or `redirect` presentation, segment and
  query parameters (name and Dart type), tab membership (`RouteTab`), `data.dart` keys and
  `meta`. `AppManifest.of(GoRouterState.of(context))` gives the route a layout is showing,
  e.g. for the web tab title with Flutter's `Title` (see the README; `examples/features`).
- `meta.dart` per folder: `const meta = <any const expression>;` is copied into the manifest
  by reference (`_iN.meta`), untyped. It belongs to its own route (not inherited), and a
  `meta` that isn't `const`, a `meta.dart` without one, or one declared twice is an error at the
  declaration. `fespalier: { meta: required }` makes a route without one an error naming its
  folder.
- `fespalier: { output_manifest: lib/app.routes.g.dart }` writes the manifest to a library
  of its own, importing `app.g.dart` for the typed routes, so production code that imports
  `app.g.dart` alone never imports a `meta.dart`. `gen`, `check` and `watch` handle both files,
  and the success line names both; `examples/tabs` uses it.
- `fsp routes --json` adds `folder`, `presentation`, `groups`, `layouts`, `tabs`, `data_keys` and
  `meta` (the route's meta.dart, or null) and `catch_all` to each object; the shape is documented and
  pinned by a test. A catch-all segment is a `List<String>` `RouteParam` with `catchAll: true`, and
  `AppManifest.of` finds the route for it (and for an optional catch-all's bare path).

### State restoration

- `AppRoutes.router(restorationScopeId: ...)` passes the id to `GoRouter`. Tab layouts and
  their branches (and plain layouts) get a stable `restorationScopeId` from their folder, and
  a layout's page is built by the runtime's new `layoutPage`, with a restoration id from the
  folder: go_router keys shell pages by the route's `hashCode`, which changes on every launch,
  so the tabs and their stacks were never found again. The selected tab, each visited tab's
  stack and a page's `RestorableProperty`s survive `tester.restartAndRestore()`
  (`examples/tabs/test/restoration_test.dart`).
- The pages `Transitions.*` build take their `restorationId` from the page key, so what a
  page keeps in a `RestorationMixin` is restored too. A `Page` you write in a `transition.dart`
  should pass `restorationId: key.value`.
- Layouts are now built as `pageBuilder` pages (`layoutPage`: a Material page, or a Cupertino
  one in a `CupertinoApp`) instead of `builder`. Regenerate `lib/app.g.dart`.

## 0.2.0 — 2026-09-30

### Guards and redirects

- `guard.dart` works in a folder without a `page.dart`, in a `(group)` and at the root, and
  guards every route at and below its folder. Guards run outermost first and the first
  location wins. Each page route's `redirect` chains the guards above it (`firstRedirect`).
  An inherited guard takes the segments at its own folder level and query parameters. A guard
  with no route at or below its folder is a warning.
- Guards can take `Uri uri`, the requested location, to build a return-to link:
  `LoginRoute(from: uri.toString()).location`. New `returnTo(from, fallback: '/')` in the
  runtime accepts only in-app locations.
- `redirect.dart` in place of `page.dart`: `String redirect({...})` makes a route that only
  redirects (`/old-products/:id` to `/products/:id`). It gets a typed route named after its
  path (`OldProductsIdRoute`) and takes part in route order checks.

### Navigation

- Nested tab layouts: a tab layout inside a branch of another one generates a nested
  `StatefulShellRoute.indexedStack`. Each level has its own `tabs`, and an inner tab keeps
  its state while you switch outer tabs. `examples/tabs` gets a Library tab with two inner
  tabs.
- Per-tab options: a `const tabOptions = {'search': TabOptions(preload: true), ...}` map in
  a tab layout sets each `StatefulShellBranch`'s `preload` and `initialLocation` (the mount
  point is added for you). Checked like `tabs`; an `initialLocation` must be a route inside
  its tab. A tab with an `initialLocation` may start with a dynamic route. `TabOptions` is a
  new runtime export.
- `Transitions.dialog`, `Transitions.sheet` and `Transitions.fullscreenDialog`: a
  `transition.dart` can make a route open as a dialog or bottom sheet over the previous page
  (`examples/features` has `/photos`, `/photos/:id`, `/photos/sort`, `/photos/upload`).
- `not_found.dart` in any folder. The nearest one covers unknown URLs under its folder
  (`AppRoutes.notFound(uri)`, used by the router's `errorBuilder`, backed by the new runtime
  `nearestNotFound`) and unparsable segments in the routes below it (a `(group)`'s too). It
  used to be an error outside the root.

### Route API and testing

- **Typed data helpers on routes.** A route with a `data.dart` gets `static watch(ref, {keys})`
  (an `AsyncValue<T>`), `static read(ref, {keys})` (a `Future<T>`, kept alive until it
  completes) and an instance `prefetch(ref, {keepFor})` that starts the load and keeps the result
  (30 s by default, `prefetchKeepAlive`) so the next page shows it at once. `T` is inferred from
  the provider, so the generated file still never names your types; that's why `watch` and
  `read` are static and not `ProductRoute(id: 2).watch(ref)`. They build on `readData` and
  `prefetchData`, new on `WidgetRef` (`DataRef`). New reserved names: `watch`, `read`,
  `prefetch`, `ref` and `keepFor` can't be segment names, and a query parameter can't be called
  like a member of the route class (`go`, `read`, `refresh`, ...). Regenerate `app.g.dart`.
- **Section data.** A `data.dart` in a folder that has a `layout.dart` and no `page.dart` (a
  page-less folder or a `(group)`) is the data of the whole section: the layout waits for it,
  showing the nearest `loading.dart` / `error.dart` (`SectionView`), and the layout and the
  pages below can take it by type or as a parameter called `data`. The layout and pages share
  one provider, so `data()` runs once. Two data.dart files yielding the same type for one
  parameter are an error. Segments only, no query parameters.
- **`package:fespalier/testing.dart`**: `pumpRouter(tester, router, {overrides, container,
  settle})` and `currentLocation(tester)`. `fespalier` now lists `flutter_test` (an SDK
  package) as a dependency; the main library doesn't import it.

### Tooling

- `dart run fespalier <command>`: runs the `fsp` release that matches the package's version,
  so nothing needs installing (Windows included). It downloads the release archive on first
  use, checks its SHA-256 and caches it; `FSP_BINARY` runs a binary of your own, and a matching
  `fsp` on PATH is used as is.
- `install.ps1`: installs `fsp.exe` on Windows from PowerShell, like `install.sh`
  (`FSP_VERSION`, `FSP_INSTALL_DIR`, SHA-256 check).
- `fsp routes` prints the route table (pattern, route class, file, tags); `--json` prints one
  object per route, with its parameters, for tools.
- `fsp gen --json` and `fsp check --json` print diagnostics to stdout as JSON lines (file, line,
  column, severity, message) instead of the code-frame rendering, for editors.
- `fsp gen --format`, or `format: true` under `fespalier:` in pubspec.yaml, runs `dart format` on
  the generated file (needs `dart` on PATH). Off by default, so committed output is unchanged.
- CI checks that the versions in `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`, `fsp init`'s
  `ref:` and the READMEs agree, and that `dart run fespalier` runs a freshly built `fsp`.

### Fixes

- Static routes now sort before dynamic siblings below a page-less folder
  (`shops/new` before `shops/$id`); before, both were kept in folder order and `shops/new`
  could be reported unreachable. Regenerate `app.g.dart`: routes may move.

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
