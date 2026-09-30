## Unreleased

- `dart run fespalier <command>` runs the `fsp` release that matches this package's version,
  downloading and caching it on first use (SHA-256 checked). `FSP_BINARY` runs a binary of
  your own; an `fsp` on PATH is used when its version matches. The package also declares an
  `fsp` executable for `dart pub global activate`.

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
