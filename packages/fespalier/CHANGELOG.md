## 0.2.0 - 2026-09-30

- Guards: `firstRedirect(guards)` chains the guards above a route (outermost first, the first
  location wins), and `returnTo(from, fallback: '/')` turns a `from` query value into a
  location to go back to, accepting only in-app locations.
- `TabOptions(preload:, initialLocation:)`, for the per-tab options of a tab layout.
- `Transitions.dialog`, `Transitions.sheet` and `Transitions.fullscreenDialog`: routes that open
  as a dialog or a bottom sheet over the previous page.
- Route data: `readData` and `prefetchData` on `WidgetRef` (what the generated `read` and
  `prefetch` on routes use), `prefetchKeepAlive` (30 s), and `SectionView`, which shows the
  data of a whole section (a `data.dart` next to a `layout.dart` with no `page.dart`).
- `nearestNotFound`: picks the `not_found.dart` of the deepest folder that covers a URL.
- `package:fespalier/testing.dart` with `pumpRouter` and `currentLocation`, for widget tests.
  The package now depends on `flutter_test` (SDK); the main library doesn't import it.
- `dart run fespalier <command>` runs the `fsp` release that matches this package's version,
  downloading and caching it on first use (SHA-256 checked). `FSP_BINARY` runs a binary of
  your own; an `fsp` on PATH is used when its version matches. The package also declares an
  `fsp` executable for `dart pub global activate`.
- Regenerate `lib/app.g.dart` with `fsp` 0.2.0: the generated code uses the additions above.

## 0.1.1 - 2026-09-30

- Generated `data()` providers turn off Riverpod's automatic retry, so `error.dart` shows
  as soon as `data.dart` fails and its `retry` callback is the retry path. Regenerate
  `lib/app.g.dart` with `fsp` 0.1.1 to pick this up.
- Docs only otherwise; no runtime API changes.

## 0.1.0 - 2026-09-30

- Initial release: the runtime for the `fsp` file-tree router generator, built on go_router
  (17 and 18), hooks_riverpod 3 and flutter_hooks. It re-exports all three from
  `package:fespalier/fespalier.dart`.
- Generated `lib/app.g.dart` uses this package for typed route locations (`TypedLocation`),
  segment parsing (`int`, `double`, `bool`, `String`) and query parameter helpers,
  including list values.
- `DataView`: renders a Riverpod `AsyncValue` with the route's page, loading and error widgets,
  with default loading and error widgets when the tree has none.
- `Transitions` for `transition.dart`: `fade`, `slide`, `none`, `material` and `cupertino`.
- Supports `(group)` folders, tab layouts (`StatefulNavigationShell`) and `AppRoutes.mount(at:)`
  in the generated code.
