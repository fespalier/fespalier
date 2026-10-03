# fespalier — agent guide

File-tree routing for Flutter. Plain widgets and functions in `lib/app/` (`page.dart`, `data.dart`,
`layout.dart`, `guard.dart`, ...) become one typed `go_router` entry point, `lib/app.g.dart`,
written by a Rust generator (`fsp`). A Dart package carries the runtime that generated file
imports. `README.md` is the user documentation; read the section for the file kind you touch
before changing how it behaves.

## Layout

| Path | What it is |
| --- | --- |
| `cli/` | The generator, Rust crate `fespalier`, binary `fsp`. Pipeline: `scan.rs` (the file tree) → `dart.rs` (tree-sitter reads each Dart file) → `resolve.rs` (binds parameters, checks how the files fit) → `emit.rs` and `manifest.rs` (write the output through `templates/`). Also `smoke.rs` (`fsp test`) and `samples.rs` (the `samples:` it shares with `fsp maestro`), `scaffold.rs` (`fsp new`), `init.rs`, `size.rs` (`fsp size`, the web build's JavaScript per deferred route), `session.rs` and `parse_cache.rs` (incremental `fsp watch`), `locale.rs`, `enums.rs`, `extra.rs`. Unit tests sit next to the code as `*_tests.rs`; `cli/tests/` spawns the binary. |
| `cli/templates/` | minijinja templates: `app.g.dart.jinja`, the manifest, and the files `fsp new` / `fsp init` write (`new/`, `init/`). |
| `packages/fespalier/` | The Dart runtime (`DataView`, `DeferredLibrary` and `DeferredView`, segment parsing, `TypedLocation`, `testing.dart`) and `bin/fespalier.dart`, the `dart run fespalier` launcher that downloads the matching `fsp`. `lib/src/devtools/` is the app side of the DevTools extension (`protocol.dart` is the wire format and imports nothing; `devtools.dart` is behind `kFespalierDevTools`, false in release). `lib/src/lifecycle.dart` runs the `observe.dart` hooks and is the one router watch telemetry shares; `lib/src/telemetry.dart` is the `FespalierTelemetry` sink API and what the generated call sites reach (since 0.8.0). Not published to a registry: apps use it as a git dependency at a release tag. |
| `packages/fespalier/extension/devtools/` | What DevTools loads: `config.yaml` (its `version:` is release-please's) and `build/`, the extension's release build, **committed and generated** by `scripts/build-devtools-extension.sh`. Never edit a file in `build/`. |
| `packages/fespalier_otel/` | The OpenTelemetry adapter (since 0.8.0): `FespalierOtel`, a `FespalierTelemetry` sink that makes spans on the dartastic SDK `otel_zone` starts, and `FespalierConventions`, every span, event and attribute name of the telemetry conventions (contract version 1: a rename is a breaking change, and `test/conventions_test.dart` pins them). It depends on `fespalier` by git, like an app; `dependency_overrides` points it at the checkout here. Not published: apps use it as a git dependency at the same tag as `fespalier` |
| `packages/fespalier_devtools/` | The DevTools extension's source, a Flutter web app; only `lib/main.dart` imports `devtools_extensions`, so the rest is tested on the VM against a fake client. Its build is committed to `packages/fespalier/extension/devtools/build/`. `lib/src/protocol.dart` is a copy of the runtime's protocol file; `pubspec.lock` is committed on purpose. |
| `examples/{minimal,shop,features,tabs,telemetry}/` | Runnable apps with widget tests. Each commits its `lib/app.g.dart` (`tabs` also a manifest library); a test fails when one is stale. `telemetry` carries `observe.dart` and `telemetry: true`, wires `otel_zone` in a hand-written `main.dart`, and is the one example on go_router 17 (`otel_zone` needs it). |
| `editors/vscode/`, `editors/intellij/` | Editor plugins (TypeScript, Kotlin) that show `fsp --json` diagnostics. |
| `skills/` | Agent skills for **apps that use fespalier** (one directory per skill, `SKILL.md` plus `references/`), with `skills/coverage.json`, the map from README sections, file kinds, config keys and commands to the skill that covers each. `skills/README.md` is their guide. Not published. |
| `scripts/` | Python and shell helpers for releases (Homebrew/Scoop rendering, checksum pinning, staged-asset verification) and their tests, `check-const-lints.sh`, `web-copy.sh` (sourced: the throwaway web copy of an example), `check-deferred-chunks.sh` (the web build behind `just web-chunks`) and `check-web-routes.sh` (behind `just web-routes`); `scripts/skills/` holds the skills' coverage gate and sample builder (Node). |
| `ci/commit-message-parse/` | The squash-message parser the `pr-title` workflow runs; a standalone npm project pinned to release-please's grammar. |
| `ci/web-routes/` | The Playwright replay of the shop's Maestro flows (`check.mjs`); a standalone npm project whose lockfile pins Playwright, and so its Chromium. |
| `.github/workflows/` | `ci.yml` (the gate), `maestro-web.yml` (weekly real Maestro, not a gate), `quality.yml` (org lint and trivy), `pr-title.yml`, `issue-governance.yml`, and the release workflows. |

## Commands

| Command | What it proves |
| --- | --- |
| `just ci` | **The gate.** It runs what `ci.yml` runs on the code. Nothing is "verified" until it exits 0 on the final head. |
| `just lint` | `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` in `cli/` |
| `just test` | The generator's tests in `cli/` (unit, CLI, version checks) |
| `just deny` | `cargo deny check` (licences, advisories, sources; `cli/deny.toml`) |
| `just check-examples` | `fsp check` on every example, and on `examples/shop` `fsp maestro --check` (its committed `.maestro/routes/`) and `fsp test --check` (its committed `test/routes/routes_test.dart`) |
| `just flutter` | In the package, the DevTools extension, the OpenTelemetry adapter and every example: `flutter pub get`, `dart format --set-exit-if-changed`, `flutter analyze`, `flutter test`; in each example also `scripts/check-const-lints.sh` (the const lints on a copy of the generated files, which `ignore_for_file` hides) |
| `just devtools` | The committed DevTools extension build is what `packages/fespalier_devtools` builds to (a fresh build compared byte for byte, in a temporary folder), and `devtools_extensions validate` accepts it. Needs Flutter |
| `just devtools-build` | Rebuild `packages/fespalier/extension/devtools/build` (and refresh the protocol copy). Run it and commit the result after touching `packages/fespalier_devtools/`, `lib/src/devtools/protocol.dart` or `FLUTTER_VERSION` |
| `just packaging` | The Python tests for Homebrew/Scoop rendering, checksum pinning and release staging |
| `just skills` | The skills' coverage gate: every README section, file kind, config key and `fsp` command is claimed by a skill, every claim still exists, and frontmatter, stamps and links are valid |
| `just web-chunks` | `flutter build web --release` of `examples/shop` in a temporary copy, a check that each deferred page is a `main.dart.js_N.part.js` of its own, then `fsp size --check` against the budgets in the shop's `size:` (cross-checked with the marker strings). It builds `fsp` too (a few minutes, web artifacts; CI's `web` job runs it, `just ci` does not) |
| `just web-routes` | `flutter build web --release --no-web-resources-cdn` of `examples/shop` in a temporary copy, served locally, and Playwright (`ci/web-routes/`, exact versions in its lockfile) replays each committed `.maestro/routes` flow in Chromium with every non-local request blocked: the link must show the flow's `id:` (`flt-semantics-identifier`) in time. Needs Flutter and Node, about two minutes; CI's `web-routes` job (the one to require) runs it, `just ci` does not. `.github/workflows/maestro-web.yml` runs real Maestro (sha256-pinned) weekly, not required |
| `just skill-samples [file.md ...]` | Builds the skills' code samples in a scratch app with this checkout's `fsp` (`gen`, `analyze`, `test`). Slow; not in `just ci` or CI, so run it when you touch a sample |
| `just gen-examples` | Regenerate every example's committed `lib/app.g.dart`, and `examples/shop`'s `.maestro/routes/` and `test/routes/routes_test.dart` |
| `just fmt` | `cargo fmt` and `dart format` over everything |
| `just vscode`, `just intellij` | The editor plugins (need Node / JDK 21; CI runs them, `just ci` does not) |

The toolchains are pinned: Rust in `cli/rust-toolchain.toml` (CI reads the channel from that file,
and `rust-version` in `cli/Cargo.toml` moves with it), Flutter in `env.FLUTTER_VERSION` of
`.github/workflows/ci.yml`. `just ci` also needs `just`, `cargo-deny`, `python3` and `node` on `PATH`.
CI additionally scaffolds every file kind with `fsp new` and `fsp init` and checks the result
with `flutter analyze` and `dart format`; that job has no `just` recipe because it writes into
the examples.

Run `just ci`, not a reconstruction of it: the flags you drop are the ones that were set on purpose.

## Running one suite

- One Rust unit test: `cd cli && cargo test <name>` (a module: `cargo test resolve::`). One
  integration file: `cargo test --test cli`. Tests that compare with `dart format` skip when
  `dart` is not on `PATH`, so put Flutter's `bin/` there before trusting a green run.
- The package: `cd packages/fespalier && flutter pub get && flutter test`; one file:
  `flutter test test/guards_test.dart`.
- One example: `cd examples/<name> && flutter pub get && flutter test`.
- The generator on an example: `cd cli && cargo run -- check --project ../examples/shop`.
- Release scripts: `python3 scripts/test_packaging.py` (and the other `scripts/test_*.py`).
- The editors: `cd editors/vscode && npm ci && npm test`; `cd editors/intellij && ./gradlew build`.

A filtered run is feedback, not verification; `just ci` still has to pass.

## Conventions

- **Conventional Commit PR titles.** The repository squash-merges, so the PR title becomes the one
  commit on `main`, and release-please reads only that. `feat:` and `fix:` decide the version;
  `docs:`, `ci:`, `build:`, `style:`, `refactor:`, `perf:`, `test:`, `chore:` and `revert:` are
  patches. `pr-title.yml` refuses anything else and also parses the whole squash message with
  release-please's own grammar, so a body line starting with a call-like token with nested
  parentheses (`A(B(c)) ...`) fails it. Commits on a branch need not be conventional; the title
  and the body must parse. Do not bump versions or edit `CHANGELOG.md` or
  `.release-please-manifest.json` by hand: release-please does (see "Releasing" in the README).
- **Squash merges**, so cite "PR #N" rather than a branch commit.
- **Actions are pinned to a full commit SHA** with a `# vX.Y.Z` comment, resolved with
  `git ls-remote https://github.com/<owner>/<repo> refs/tags/<tag>` (add `^{}` for an annotated
  tag), preferring the versions the org repositories already pin. Workflows declare
  `permissions: {}` or `contents: read` and grant more per job, set `timeout-minutes` and a
  `concurrency` group, use `persist-credentials: false` on checkouts that do not push, and never
  put `${{ }}` inside `run:` (pass values through `env:`). The org lint runs zizmor and
  actionlint, so run them on workflow changes. `on.pull_request.paths` is never used: gate jobs
  with an `if:` over the paths-filter job in `quality.yml`.
- **Regenerate the examples.** After changing the emitter, a template or `manifest.rs`, run
  `just gen-examples` and commit the new `lib/app.g.dart` files; a generator test fails on a stale
  one. Generated files stay unformatted (the `format:` option is off) so they do not depend on the
  Dart SDK; `dart format` checks skip `*.g.dart`, except that `examples/minimal` sets
  `format: true`.
- **Scaffolds are formatted.** What `fsp init` and `fsp new` write must be what `dart format`
  leaves alone; `cli/templates/new/_macros.dart.jinja` lays out long names the way the formatter
  does. Change a template, and `scaffolded_files_are_dart_format_clean` tells you.
- **Rust.** Edition 2024, `rustfmt.toml` (max width 100), `[lints]` in `cli/Cargo.toml`
  (`unsafe_code` forbidden, clippy pedantic as a warning, `unwrap_used` / `expect_used` warn).
  Allow a lint only with a reason, at module level or in `[lints]`. Tests may unwrap.
- **Dart.** `flutter_lints` everywhere; the package also runs strict casts, inference and raw
  types, and requires a doc comment on every public member (`public_member_api_docs` is an
  error). File names are `snake_case`. The package is published nowhere (`publish_to: 'none'`).
- **Licence** is MIT, copyright holder Vaam.

## Things that bite

- `cargo` only honours `cli/rust-toolchain.toml` from inside `cli/`; run it there, not with
  `--manifest-path` from the root.
- `dart format` picks its style from the package's language version, so format after
  `flutter pub get`; the examples declare an older SDK than the package.
- Adding a file kind or a binding rule touches the resolver, the emitter, the README section,
  the examples and usually `manifest.rs` (the `fsp routes --json` fields); the editors read that
  JSON, so keep it additive.
- **The skills move with the code.** A new README heading, file kind, `fespalier:` config key or
  `fsp` command fails `just skills` until a skill covers it (prose in the owning skill, its
  diagnostics in `fespalier-troubleshooting`, the id in `skills/coverage.json`). A changed
  message, behaviour or README claim needs the skill pages that quote it updated too: grep
  `skills/` for the old text. Say the release a change lands in ("since 0.5.0"), since apps
  pin older ones; `skills/README.md` has the rules.
- **The DevTools extension's build is committed.** After touching `packages/fespalier_devtools/`,
  `packages/fespalier/lib/src/devtools/protocol.dart` or `FLUTTER_VERSION` in `ci.yml`, run
  `just devtools-build` and commit `packages/fespalier/extension/devtools/build/` with the change; CI
  rebuilds it and compares byte for byte, so a Flutter bump fails the `devtools` job until someone
  does. Do not run `dart run devtools_extensions build_and_copy`: it adds 37 MB of CanvasKit, a service
  worker with a random version and every Material icon. The protocol file has one source,
  `packages/fespalier/lib/src/devtools/protocol.dart` (it imports nothing); the extension holds a copy
  that the build script refreshes and a test compares. The extension's `pubspec.lock` is committed on
  purpose (a build must not change when a dependency publishes) and has no `fespalier` in it, which is why
  the protocol is copied and not a path dependency: a release bump would make the lock stale.
  `config.yaml`'s `version:` is release-please's, like the pubspec's.
- **fespalier must not make apps flaky.** Everything the DevTools support adds sits behind
  `kFespalierDevTools` (a `const`, false in release), so a release build has none of it (CI greps a
  release build for `ext.fespalier`); in debug it starts no timer, schedules no frame, reads no
  provider and wraps every path in a `try`. `app.g.dart` calls `devToolsRegister` and `devToolsAttach`:
  never remove them by hand, and keep new calls under `if (kFespalierDevTools)`. The calls that follow
  the guards, the data and the actions (`traceGuard`, `traceData`, an action's `site:`) are not under an
  `if`: they are **pass-through wrappers** that return their last argument, the very object, so a sync
  guard or `data()` stays sync (no `Future`, no microtask) and a `Future` is never replaced; `devtools_trace_test.dart`
  checks it, and in release they are the identity and dart2js inlines them away (the scaffold CI job
  greps a release build with a guard, a `data.dart` and an action in it). Keep them that way: no provider
  read, no listener on a provider or a stream, no timer.
- **Telemetry costs nothing when off, and never makes async.** An app generated without `telemetry: true`
  passes no `TelemetrySite`, so every `telemetry:` parameter (`traceGuard`, `traceData`, `ActionNotifier`,
  `DeferredLibrary(route:)`) is null and the code behind it is compiled out; the scaffold CI job greps a
  release web build for `fespalier telemetry` (the line `telemetry.dart` prints when a sink throws), and
  also builds an app with an `observe.dart`, which must not pull telemetry in. `telemetry.dart` and the
  watch in `lifecycle.dart` never create a `Future`, a microtask or a timer: a sync guard, `data()` or
  action is reported in the same call stack, an async one through a side `then` with its own `onError`,
  and the wrappers return the very object. A hook runs after the frame, never in `build`, with the `Ref`
  of a throwaway provider that has finished building (Riverpod forbids changing a provider during
  another's build). The names `fespalier_otel` emits are contract version 1 (README, "Telemetry
  conventions"): adding is fine, renaming or removing is a breaking release.
- Every place that spells out the release version is annotated for release-please and checked by
  `cli/tests/versions.rs`; if that test fails after your change, you moved or removed an annotation.
