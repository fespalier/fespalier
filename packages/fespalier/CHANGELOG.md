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
