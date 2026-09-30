# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## Later

- Catch-all segments (`[...slug]`): go_router parameters don't span `/`.
- Typed `extra` objects passed between routes.
- Route metadata: web tab titles, analytics names.
- State restoration (`restorationScopeId`).
- Case-insensitive paths and trailing slashes.
- Editor extension (VS Code / IntelliJ) on top of the JSON diagnostics.
- Publishing to pub.dev; Homebrew and Scoop packages.
- Localized paths.
- Incremental parsing for very large apps.
- Instance methods `ProductRoute(id: 2).watch(ref)` / `.read(ref)`: needs the generated file to name the data type (or Dart macros); `watch` and `read` are static for now.
- A section's `data.dart` keyed by query parameters, and a typed handle (`.data`, `.refresh`) for it.
- `fsp new --not-found`, and a `not_found.dart` that can take the segments above it.
