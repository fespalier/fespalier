# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## Later

- Typed catch-alls (`List<int>`); today a catch-all is a `List<String>`.
- Per-folder `caseSensitive`, and a `case_sensitive` that keeps `.location` in the requested case.
- `extra` for layouts and guards, and restoring it (an `extraCodec`) on the web.
- Route metadata: web tab titles, analytics names.
- State restoration (`restorationScopeId`).
- Keep showing old data while `data.dart` refreshes (a section's data reloading now shows loading for the whole section).
- Editor extension (VS Code / IntelliJ) on top of the JSON diagnostics.
- Publishing to pub.dev; Homebrew and Scoop packages.
- Localized paths.
- Incremental parsing for very large apps.
- `List` query parameters as `data.dart` keys.
- Instance methods `ProductRoute(id: 2).watch(ref)` / `.read(ref)`: needs the generated file to name the data type (or Dart macros); `watch` and `read` are static for now.
- A section's `data.dart` keyed by query parameters, and a typed handle (`.data`, `.refresh`) for it.
- `fsp new --not-found`, and a `not_found.dart` that can take the segments above it.
