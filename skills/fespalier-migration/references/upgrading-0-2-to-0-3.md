# Upgrading from fespalier 0.2 to 0.3

As of v0.3.0 (root `CHANGELOG.md`, "0.3.0 — 2026-09-30", "Upgrading from 0.2"). The
package and the `fsp` CLI are versioned together, and 0.3.0's generated code relies
on runtime additions of the same release: **change both**.

## The checklist

1. **Bump the package** in `pubspec.yaml` (`ref: v0.3.0` on the git dependency) and run
   `flutter pub get`.
2. **Get the matching `fsp`**: `FSP_VERSION=v0.3.0` with `install.sh`, or simply use
   `dart run fespalier gen`, which runs the `fsp` that matches the package your
   `pubspec.lock` resolved. `fsp --version` must print `fsp 0.3.0`.
3. **Regenerate `lib/app.g.dart`** (`fsp gen`) and **commit it**. Every change below
   assumes it; a stale 0.2 file against the 0.3 runtime fails to compile or misbehaves
   (`NotFoundScope`, the `go`/`push`/`replace` overrides, `router()`/`mount()`).
4. **Fix the compile errors and behaviour changes** listed next.
5. Run `flutter analyze` and your tests; look at every screen that has a layout.

## Breaking changes and behaviour changes

| Change                                                                                                                                                                                  | What to do                                                                                                                                                                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`prefetch` returns a `PrefetchHandle`** and a prefetch without `keepFor` **lives until you `close()` the handle** (it used to lapse after 30 s). **`prefetchKeepAlive` is removed**   | Keep the handle and `close()` it when the next page is reached or the lease ends; or pass `keepFor:` for the old behaviour (`keepFor: Duration(seconds: 30)`). A handle you drop lives as long as the widget behind `ref`. Delete uses of `prefetchKeepAlive`              |
| **A `transition.dart` at or above a layout now animates that layout's shell too.** `fsp init` writes one at the root, so most apps see it; switching tabs does not re-animate the shell | Regenerate and look at your layouts. To keep a shell still, take `bool shell` in `transition()` and return `Transitions.none(key, child)` for it (`fespalier-layouts`)                                                                                                     |
| **Generated `data()` providers keep Riverpod's automatic retry** (0.1.1 and 0.2 gave them `retry: (retryCount, error) => null`)                                                         | A failing `data.dart` is now retried in the background (10 tries with backoff by default). Either give the app `ProviderScope(retry: ...)` a policy, or add `data_retry: none` to the `fespalier:` section. Tests that count calls or end with a pending timer will notice |
| **`DataView` keeps the old state on screen while `data.dart` reloads** (`keep_previous: true` by default)                                                                               | `loading.dart` is now only for the first load. `keep_previous: false` restores the loading view for every load                                                                                                                                                             |
| **`NotFoundScope`** (what the generated `notFound` passes to `nearestNotFound`) **takes a named `caseSensitive:`**                                                                      | Only hand-written scopes: add `caseSensitive: true`. Regenerating fixes generated ones                                                                                                                                                                                     |
| **`package:fespalier/fespalier.dart` hides go_router's own `RouteMatch`** to export fespalier's                                                                                         | If you used go_router's `RouteMatch`, `import 'package:go_router/go_router.dart'` too (and prefix or `hide` the clash)                                                                                                                                                     |
| **`AppRoutes.router()` and `mount()` have a new optional `navigatorKey`**, and `router()` passes `AppRoutes.rootNavigatorKey` to `GoRouter`                                             | Nothing for most apps; a host router mounting the tree should pass its **own** key (`fespalier-routing`)                                                                                                                                                                   |
| **Layouts are built as `pageBuilder` pages** (`layoutPage`, with a stable restoration id), not `builder`                                                                                | Nothing to write; regenerate. It is what makes tab restoration work                                                                                                                                                                                                        |
| **New reserved segment name `extra`**, and (since 0.2) `watch`, `read`, `prefetch`, `ref`, `keepFor` cannot be segment or query names                                                   | Rename an affected folder or parameter                                                                                                                                                                                                                                     |
| **Generated `go`/`push`/`replace` overrides of a route with an `extra` now take `locale`**                                                                                              | Regenerate; only matters if you wrote subclasses or call them positionally                                                                                                                                                                                                 |
| `pumpRouter` **defaults to no retries** and takes `retry:`                                                                                                                              | Tests that relied on the app's retry policy pass `retry: ProviderContainer.defaultRetry`                                                                                                                                                                                   |

The rest of 0.3.0 is additive, and worth reading once (each has a skill):

- **Function views** (`Widget page() => ...`), `routeName`, `fsp new --function`,
  `--not-found`, `not-found.dart`, `file_style: kebab` (`fespalier/references/file-kinds.md`).
- **Enum segments**, query parameters and catch-all parts; **typed catch-alls**
  (`List<int>`, ...) (`fespalier-routing`).
- **Localized paths** (`route.dart` `paths`, `locationFor`, `locale:`) and the **per-folder
  `caseSensitive`** in `route.dart` (`fespalier-routing`).
- **`navigator.dart`, `present.dart`**, `AppRoutes.rootNavigatorKey` (`fespalier-routing`).
- **`container`** for tab layouts (`fespalier-layouts`), shell transitions, restoration.
- **`extra` for layouts, guards and redirects**, `extra_codec.dart`, `ExtraCodec`
  (`fespalier-routing`).
- **`AppRoutes.dataAt`, `AppRoutes.match`, `AppRoutes.matchUrl`**, `ref.prefetchAll`,
  section query keys and the typed `Section` handle (`fespalier-data`).
- A **selector** form of `data.dart` and `keep_previous`/`data_retry` (`fespalier-data`).
- **`fsp watch`** is incremental and watches `lib/`; `fsp routes --json` gained fields
  and a `paths` key; `meta_unique`; the route manifest `presentation` values `root` and
  `custom`.

## Earlier notes you may still need (0.1 and 0.2)

- **0.1.x to 0.2:** static routes now sort before dynamic siblings below a page-less
  folder (`shops/new` before `shops/$id`): **regenerate, routes may move**. `guard.dart`
  works in page-less folders and groups. New reserved names for the typed helpers
  (`watch`, `read`, `prefetch`, `ref`, `keepFor`).
- **0.1.0 to 0.1.1:** generated providers stopped retrying (`error.dart` at once); since
  0.3.0 they retry again unless `data_retry: none`.

## After upgrading

- `fsp gen` should print `✓ N routes → lib/app.g.dart` with **no warnings you did not
  expect**; read every new warning, several 0.3.0 checks are new (`route.dart`,
  `navigator.dart`, `present.dart`, `tabOptions`, enum lookup).
- If `flutter analyze` fails inside `app.g.dart`, it is stale or mismatched: regenerate with
  the `fsp` of the package version, never patch it.
- The repository's `main` later moved to release-please for releases; a later tag is a
  newer package and needs the same steps (bump, matching `fsp`, regenerate).
