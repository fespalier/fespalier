# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md; one-time
maintainer steps (pub.dev, Homebrew tap, Scoop bucket, Marketplace) are in README's
"Releasing".

## In progress

- Root navigator per folder (`navigator.dart`, #1), non-inherited `present.dart` for sheets
  and dialogs on the root navigator (#2), tab `container` builder and shell transitions (#3);
  manifest `presentation` for them.
- `page.dart` (and other views) as a function, `routeName` (#7); `not-found.dart` spelling and
  `file_style` (#10).

## Later

- Typed catch-alls (`List<int>`); today a catch-all is a `List<String>`.
- Per-folder `caseSensitive`, and a `case_sensitive` that keeps `.location` in the requested case.
- `extra` for layouts and guards, and restoring it (an `extraCodec`) on the web.
- An IntelliJ plugin on top of the JSON diagnostics.
- Localized paths.
- Incremental scan/resolve/emit for very large apps (`fsp watch` already reuses parse results).
