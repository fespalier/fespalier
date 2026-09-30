# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md; one-time
maintainer steps (pub.dev, Homebrew tap, Scoop bucket, Marketplace) are in README's
"Releasing".

## In progress

- Root navigator per folder (`navigator.dart`, #1), non-inherited `present.dart` for sheets
  and dialogs on the root navigator (#2), tab `container` builder and shell transitions (#3);
  manifest `presentation` for them.

## Later

- Enum segments, and `List<SomeEnum>` catch-alls: a segment is a `String`, `int`, `double` or `bool` today.
- `extra` for layouts and guards, and restoring it (an `extraCodec`) on the web.
- Localized paths.
- Incremental scan/resolve/emit for very large apps (`fsp watch` already reuses parse results).
