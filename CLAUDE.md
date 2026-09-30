@AGENTS.md

# CLAUDE.md

This file gives Claude Code (claude.ai/code) guidance for this repository; the shared guide is
`AGENTS.md`, imported above.

## Claude Code specifics

- Flutter lives outside the default `PATH` in some environments: `export PATH=/opt/flutter/bin:$PATH`
  (or wherever Flutter is installed) before `just ci`, or the tests that compare with `dart format`
  skip silently and `just flutter` fails at once.
- Before finishing, run `just ci` and read its exit code. A filtered test run is feedback only.
- Commit subjects follow Conventional Commits (`ci:`, `build:`, `style:`, `docs:`, `chore:`,
  `fix:`, `feat:`). Do not push, and do not bump versions: release-please owns them.
- When a workflow changes, run `actionlint` and `zizmor --offline .github/workflows` (both are
  what the org lint runs) and resolve every new action to a SHA with `git ls-remote`.
- Regenerate the committed examples with `just gen-examples` after touching the emitter or a
  template; never edit a `*.g.dart` by hand.
