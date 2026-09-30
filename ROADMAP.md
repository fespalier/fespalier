# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## Later

- Catch-all segments (`[...slug]`): go_router parameters don't span `/`.
- Typed `extra` objects passed between routes.
- Route metadata: web tab titles, analytics names.
- State restoration (`restorationScopeId`).
- Keep showing old data while `data.dart` refreshes (a section's data reloading now shows loading for the whole section).
- Case-insensitive paths and trailing slashes.
- Publish the VS Code extension to the Marketplace; an IntelliJ plugin on top of the JSON diagnostics.
- The one-time pub.dev, Homebrew tap and Scoop bucket setup described in README's "Releasing", then the first publish.
- Localized paths.
- Incremental scan/resolve/emit for very large apps (`fsp watch` already reuses parse results).
- `List` query parameters as `data.dart` keys.
- Instance methods `ProductRoute(id: 2).watch(ref)` / `.read(ref)`: needs the generated file to name the data type (or Dart macros); `watch` and `read` are static for now.
- A section's `data.dart` keyed by query parameters, and a typed handle (`.data`, `.refresh`) for it.
- `fsp new --not-found`, and a `not_found.dart` that can take the segments above it.
