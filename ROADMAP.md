# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md; one-time
maintainer steps (pub.dev, Homebrew tap, Scoop bucket, Marketplace) are in README's
"Releasing".

## In progress

- Incremental scan/resolve/emit for very large apps.

## Later

- Enum segments, and `List<SomeEnum>` catch-alls: a segment is a `String`, `int`, `double` or `bool` today.
- Localized paths with non-ASCII spellings (`/продукты`, `/über`): a `paths` value is limited to `a-z 0-9 - _ . ~` for now; other letters would have to be matched percent-encoded.
