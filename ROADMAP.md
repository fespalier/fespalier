# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## Later

- Catch-all segments (`[...slug]`): go_router parameters don't span `/`.
- Typed `extra` objects passed between routes.
- Manifest `presentation` for dialog and sheet routes: `transition.dart` decides that at runtime, so the manifest only says `page` or `redirect`.
- Keep showing old data while `data.dart` refreshes (a section's data reloading now shows loading for the whole section).
- Case-insensitive paths and trailing slashes.
- Editor extension (VS Code / IntelliJ) on top of the JSON diagnostics.
- Publishing to pub.dev; Homebrew and Scoop packages.
- Localized paths.
- Incremental parsing for very large apps.
- `List` query parameters as `data.dart` keys.
- Instance methods `ProductRoute(id: 2).watch(ref)` / `.read(ref)`: needs the generated file to name the data type (or Dart macros); `watch` and `read` are static for now.
- A section's `data.dart` keyed by query parameters, and a typed handle (`.data`, `.refresh`) for it.
- `fsp new --not-found`, and a `not_found.dart` that can take the segments above it.
