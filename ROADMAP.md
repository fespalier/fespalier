# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## In progress (0.2)

**Navigation**
- Tab layouts nested inside tab layouts.
- Per-tab options: `initialLocation`, `preload`.
- Dialog and bottom-sheet routes.

**Route API and testing**
- Typed helpers on route instances: `ProductRoute(id: 2).watch(ref)`, `.read(ref)`, `.prefetch(ref)`.
- `data.dart` next to a layout, shared by the section below it.
- `not_found.dart` in any folder.
- `package:fespalier/testing.dart` with helpers to pump the router in widget tests.

## Later

- Catch-all segments (`[...slug]`): go_router parameters don't span `/`.
- Typed `extra` objects passed between routes.
- Route metadata: web tab titles, analytics names.
- State restoration (`restorationScopeId`).
- Keep showing old data while `data.dart` refreshes.
- Case-insensitive paths and trailing slashes.
- Editor extension (VS Code / IntelliJ) on top of the JSON diagnostics.
- Publishing to pub.dev; Homebrew and Scoop packages.
- Localized paths.
- Incremental parsing for very large apps.
- `List` query parameters as `data.dart` keys.
