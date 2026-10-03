# Roadmap

What fespalier doesn't do yet. Released features are in CHANGELOG.md; one-time
maintainer steps (pub.dev, Homebrew tap, Scoop bucket, Marketplace) are in README's
"Releasing".

- **Reload instead of restart after a regeneration.** `fsp dev` hot restarts when `lib/app.g.dart` changes, because
  the generated router is built once, so a hot reload would keep the old route table. In debug the router could rebuild
  itself on `reassemble` (go_router's `GoRouter.routingConfig`, with a `ValueListenable<RoutingConfig>`); a
  regeneration would then need only a hot reload and keep the app's state.

Ideas and bugs go in GitHub issues.
