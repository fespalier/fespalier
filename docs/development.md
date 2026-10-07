# Development

```text
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
editors/vscode/      the VS Code extension (TypeScript): fsp diagnostics in the Problems panel
editors/intellij/    the IntelliJ / Android Studio plugin (Kotlin): fsp diagnostics in the editor
docs/                the user documentation, one page per topic
scripts/             packaging.py renders the Homebrew formula and Scoop manifest for a release;
                     pin_checksums.py writes the release's checksums into the Dart package
scripts/telemetry/   the dashboards' one spec (dashboards.toml) and build_dashboards.py, which writes
                     the OpenObserve and Grafana JSON; seed.py and smoke.py run the stack in Docker
cli/templates/telemetry/   the stack `fsp telemetry` writes (compose file, collector, importer,
                     dashboards); runs as it is with `docker compose up -d`
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation),
                     testing.dart, and bin/fespalier.dart, the `dart run fespalier` launcher for `fsp`
packages/fespalier_auth/   signed-in routes: session provider, guards, authenticated client, OpenID Connect
packages/fespalier_sign_keypair/   DPoP proofs for fespalier_auth, signed by a device key (Secure Enclave, AndroidKeyStore)
packages/fespalier_flags/   feature flags: FlagSource, flag() providers that guards watch, flagGuard (since 0.9.0)
packages/fespalier_storage/   dataCache storages on shared_preferences and Hive, with a size budget (since 0.9.0)
packages/fespalier_connectivity/   reconnectSignal from connectivity_plus, and hasNetwork for offline banners (since 0.9.0)
packages/fespalier_adaptive/   nav.dart menus as a bar, a rail or a drawer by window width
packages/fespalier_image/   responsive CDN images (ResponsiveImage, the URL builders), with FakeImages for tests
packages/fespalier_dio/   Dio and package:http: requests cancelled with their page, server field errors, writes never retried
packages/fespalier_sentry/   Sentry: errors tagged with the route and the file, page breadcrumbs, optional screen-load transactions
packages/fespalier_tolgee/   translations from Tolgee's CDN with a bundled fallback and route locales (since 0.10.0)
packages/fespalier_devtools/   the DevTools extension's source (a Flutter web app, tested on the VM)
packages/fespalier/extension/devtools/   what DevTools loads: config.yaml (its version is release-please's)
                     and build/, the extension's release build, committed
examples/minimal/    the smallest app: `flutter create` + `fsp init` + three pages, with widget tests
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, section data and nested not_found.dart, with widget tests
examples/tabs/       a tab layout (StatefulShellRoute), with widget tests
examples/auth/       fespalier_auth: sign-in, guards, refresh and Keycloak, with widget tests
skills/              agent skills: how to write lib/app/ and read fsp's errors (skills/README.md);
                     scripts/skills/ checks them against the code
```

```sh
just ci          # everything CI runs on the code, locally (needs Flutter, Node, just, cargo-deny)
just --list      # the individual steps: fmt, lint, test, deny, examples, flutter, devtools, packaging, telemetry, skills
just telemetry-dashboards   # regenerate the dashboards after editing scripts/telemetry/dashboards.toml
just telemetry-smoke        # run the telemetry stack in Docker and check every dashboard query (needs Docker)
just devtools-build   # rebuild the DevTools extension after touching its source (see below)
just web-routes  # the shop's Maestro flows open their routes in Chromium (needs Flutter and Node; not in `just ci`)
just dev-e2e     # fsp dev against the real flutter in headless Chrome (needs Flutter and Chrome; CI's scaffold job runs it)
```

[AGENTS.md](../AGENTS.md) is the contributor and agent guide: the layout, the gate commands, how to run each suite, and the conventions (Conventional Commit PR titles, squash merges, SHA-pinned actions, regenerating the examples).

**Building `fsp`.** `cd cli && cargo build --release` writes `cli/target/release/fsp`. After changing the emitter or a template, regenerate with `cargo run -- gen --project ../examples/<name>`; a test fails if a committed `app.g.dart` is stale. The code of `fsp size` is `cli/src/size.rs` and its tests `cli/src/size_tests.rs`, over an excerpt of a real build in `cli/tests/fixtures/shop-build/main.dart.js`.

**Benchmarks.** The numbers of [Performance](cli.md#performance) come from synthetic apps in `cli/src/bench.rs`; re-run them with `cd cli && cargo test --release bench -- --ignored --nocapture --test-threads=1`. At 5,000 routes, cold, walking the folders and reading the files takes 82 ms, parsing 208 (spread over the cores), resolving 29, emitting 153 (the model 50, `minijinja` 105) and writing 6; `dart format`, when on, takes 1.4 s at 500 routes, 5.3 s at 2,000 and 14 s at 5,000.

**What CI runs.** CI (`.github/workflows/ci.yml`) runs `just ci`'s steps:

- `cargo fmt --check`, clippy and the tests, `cargo deny check`, and `fsp check` on the examples.
- `dart format`, `flutter analyze` and `flutter test` on the package, the DevTools extension and every example.
- A `devtools` job builds the extension again and fails when the committed build in `packages/fespalier/extension/devtools/build` is not what its source builds to, then runs `devtools_extensions validate` (`scripts/build-devtools-extension.sh --check`). After touching `packages/fespalier_devtools`, `lib/src/devtools/protocol.dart` or the Flutter version in `ci.yml`, run `just devtools-build` and commit the result.
- A scaffold job writes every file kind with `fsp new` and `fsp init` and checks the result with `flutter analyze` and `dart format`. It gives that app a guarded route with a `data.dart` and an `action.dart`, builds it for profile and for release, and checks that the release build holds none of the DevTools code (the `traceGuard`, `traceData` and `watchData` wrappers included). It also runs `dart run fespalier` against a freshly built `fsp`.
- The VS Code extension compiles and its tests run.
- The Homebrew and Scoop rendering, checksum pinning and release staging are tested (`python3 scripts/test_packaging.py`, `python3 scripts/test_pin_checksums.py`, `python3 scripts/test_verify_staged.py`, `python3 scripts/test_release_assets.py`).
- The telemetry stack's files and dashboards are checked (`python3 scripts/test_telemetry.py`): the generated dashboards are fresh, every query uses only the telemetry conventions, `compose.yaml` pins its images, and the dashboard importer runs against a fake OpenObserve.
  - The `telemetry-smoke` job (`just telemetry-smoke`) runs the whole stack in Docker, sends a seeded session and runs every panel's query in OpenObserve and Grafana.
  - After touching `scripts/telemetry/dashboards.toml`, run `just telemetry-dashboards`.
  - To bump an image pin, edit the tag, resolve the digest with `docker buildx imagetools inspect <image>:<tag>` and run `just telemetry-smoke`.
- The agent skills in `skills/` cover every README and `docs/` section, file kind, config key and `fsp` command (`node scripts/skills/verify-coverage.mjs`, which also checks every link and anchor of the docs; see [skills/README.md](../skills/README.md)).
- The version agrees everywhere it is spelled out (`cli/tests/versions.rs`):
  - `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`, `packages/fespalier/extension/devtools/config.yaml`, `.release-please-manifest.json`, the `ref:` that `fsp init` prints, and the READMEs', the docs pages' and the skills' `ref:`, `--tag` and `FSP_VERSION`;
  - each of them is annotated for release-please and listed in `release-please-config.json`;
  - the release workflows' own version readers, `scripts/read-version.sh`, still find each one;
  - `release_checksums.dart` pins nothing, or a version no newer than the package's.

You do not bump any version: release-please does (see [Releasing](releasing.md)).

Two more jobs build `examples/shop` for the web in a throwaway copy (`scripts/web-copy.sh`), outside `just ci`:

- `web` checks that each deferred page is a chunk of its own (`just web-chunks`): it builds `examples/shop`, runs `fsp size --check` against the budgets in its pubspec, and cross-checks the attribution with strings that only each deferred page contains.
- `web-routes` replays the committed Maestro flows (since 0.8.1) in a pinned Chromium, with every request that is not to the local server blocked (`just web-routes`; `ci/web-routes/`). It builds the shop as a release build with `--no-web-resources-cdn` (the examples have no `web/` folder), serves it, and reads the very same YAML: `launchApp`, `openLink`, then it waits for the element whose `flt-semantics-identifier` is the flow's `id:`, within the flow's `timeout`. That is not Maestro (the browser is the Chromium that a pinned [Playwright](https://playwright.dev) installs), so it can gate a pull request. What it proves is what fespalier answers for: the identifier reaches the web DOM, `ensureWebSemantics()` ran, the link opens the route, and its guards, data and deferred chunk let the page build in time. It needs Flutter and Node and takes about two minutes. `scripts/check-web-routes.sh <example>` with `ci/web-routes/` is a template for an app's own CI.

`maestro-web.yml` runs real Maestro 2.11.0 on the same build weekly and on demand; a red run there is not a failed pull request, and it is not a required check. Maestro's web driver follows Chrome and has broken on Chrome upgrades (its changelog has Chrome-version fixes in 2.1.0, 2.2.0 and 2.9.0).

## Built on

It's built on existing libraries rather than hand-rolled parts:

- [tree-sitter](https://tree-sitter.github.io/) with [tree-sitter-dart](https://github.com/nielsenko/tree-sitter-dart) parses Dart.
- [minijinja](https://github.com/mitsuhiko/minijinja) renders the output. The shape of `app.g.dart` and of every scaffolded file lives in `cli/templates/`.
- [codespan-reporting](https://github.com/brendanzab/codespan) renders diagnostics.
- [clap](https://github.com/clap-rs/clap) handles the command line, and [notify](https://github.com/notify-rs/notify) drives `watch`.

## What the tests cover

The generator tests cover:

- **Parsing and binding:** every binding rule and contract error, query parameters, `(group)` folders and route order, tab layouts, navigators and shells, transitions, all three data forms, section data, nested `not_found.dart`, the typed helpers, guards and redirects, `extra` for pages, layouts and guards and `extra_codec.dart`.
- **Output:** scaffolding, the generated `main()` (which files make it, every shape of `lib/app.main.g.dart`, every diagnostic of the three root files), the route manifest, meta.dart (and `meta_unique`) and restoration ids, `match` / `dataAt`.
- **Paths:** typed catch-alls, enum segments, per-folder case, localized paths (spellings, non-ASCII, collisions, and `route.dart` `paths` edits in the incremental test), routes that leave the page above (`nest = false`).
- **Deferred routes:** the `route.dart` switch and what it inherits, the `deferred as` imports and views, `preload`, the type rule.
- **Checks:** string paths that match no route (the lint, its matching, mount point and ignore comments), `fsp size` (dart2js's table of deferred parts read from a real build's `main.dart.js`, own and shared bytes, the stale-build checks and the `size:` budgets), that the committed outputs are up to date, and that `watch`'s incremental runs equal a from-scratch `gen` after random edits (enum files outside the app folder included).

Clippy is clean. The Flutter tests cover the package, the DevTools extension, the OpenTelemetry adapter and the examples `shop`, `features`, `tabs`, `minimal` and `telemetry`; the example tests drive the generated router through every file kind.
