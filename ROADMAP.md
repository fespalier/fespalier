# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md; one-time
maintainer steps (pub.dev, Homebrew tap, Scoop bucket, Marketplace) are in README's
"Releasing".

## In progress

- `AppRoutes.dataAt(uri)` / `match(uri)` and a `prefetch` handle (#8).

## Later

- `meta_unique: [code, slug]`: duplicate check over literal named arguments of `meta`.
- Enum segments, and `List<SomeEnum>` catch-alls: a segment is a `String`, `int`, `double` or `bool` today.
- `extra` for layouts and guards, and restoring it (an `extraCodec`) on the web.
- Localized paths.
- Incremental scan/resolve/emit for very large apps (`fsp watch` already reuses parse results).
- Instance methods `ProductRoute(id: 2).watch(ref)` / `.read(ref)`: needs the generated file to name the data type (or Dart macros); `watch` and `read` are static for now.
- A section's `data.dart` keyed by query parameters, and a typed handle (`.data`, `.refresh`) for it.
- A `not_found.dart` that can take the segments above it.
