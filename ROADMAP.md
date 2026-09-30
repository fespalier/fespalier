# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## Later

- Typed catch-alls (`List<int>`); today a catch-all is a `List<String>`.
- Per-folder `caseSensitive`, and a `case_sensitive` that keeps `.location` in the requested case.
- `extra` for layouts and guards, and restoring it (an `extraCodec`) on the web.
- Publish the VS Code extension to the Marketplace; an IntelliJ plugin on top of the JSON diagnostics.
- The one-time pub.dev, Homebrew tap and Scoop bucket setup described in README's "Releasing", then the first publish.
- Manifest `presentation` for dialog and sheet routes: `transition.dart` decides that at runtime, so the manifest only says `page` or `redirect`.
- Localized paths.
- Incremental scan/resolve/emit for very large apps (`fsp watch` already reuses parse results).
- Instance methods `ProductRoute(id: 2).watch(ref)` / `.read(ref)`: needs the generated file to name the data type (or Dart macros); `watch` and `read` are static for now.
- A section's `data.dart` keyed by query parameters, and a typed handle (`.data`, `.refresh`) for it.
- `fsp new --not-found`, and a `not_found.dart` that can take the segments above it.
