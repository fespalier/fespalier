# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md.

## In progress (0.2)

**Guards and redirects**
- `guard.dart` in a folder without a page, a `(group)` or the root, guarding every route below it (parent guards first).
- `redirect.dart`: routes that only redirect (`/old` → `/new`).
- A helper to send users back after a redirect (e.g. `?from=`).

**Navigation**
- Tab layouts nested inside tab layouts.
- Per-tab options: `initialLocation`, `preload`.
- Dialog and bottom-sheet routes.

**Tooling and distribution**
- `dart run fespalier <command>`: runs the matching `fsp` release binary, no curl or Rust needed (Windows included).
- `install.ps1` for Windows.
- `fsp routes` (route table, `--json`) and `--json` diagnostics for editors.
- Optional `dart format` of the generated file.
- CI check that versions agree (Cargo.toml, pubspec.yaml, `fsp init`'s `ref:`, README).

## Later

- Catch-all segments (`[...slug]`): go_router parameters don't span `/`.
- Typed `extra` objects passed between routes.
- Route metadata: web tab titles, analytics names.
- State restoration (`restorationScopeId`).
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
