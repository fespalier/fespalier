## 0.1.0

- Initial release: runtime for the `fsp` file-tree router generator, built on go_router (17 and 18), hooks_riverpod 3 and flutter_hooks.
- File kinds under `lib/app/`: page, data, loading, error, layout and guard, wired together by the generated `lib/app.g.dart`.
- Typed routes (`TypedLocation`) with dynamic path segments and typed query parameters (`Segment` / `Query` helpers for string, int, double, bool and list values).
- `(group)` folders that organize files without affecting the URL.
- Per-route page transitions, plus `Transitions` helpers (`fade`, `slide`, `none`, `material`).
- `DataView` for async data with default loading, error and not-found widgets.
