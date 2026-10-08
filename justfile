# fespalier — task runner. `just ci` is the gate: it runs locally what .github/workflows/ci.yml
# runs, and nothing is "verified" until it exits 0 on the final head. It needs Rust (the
# toolchain in cli/rust-toolchain.toml installs itself), Flutter (see FLUTTER_VERSION in
# ci.yml), python3, Node, `just` and `cargo-deny`.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The Dart package, the DevTools extension and every example: pub get, dart format, flutter analyze, flutter test.
dart_dirs := "packages/fespalier packages/fespalier_devtools packages/fespalier_otel packages/fespalier_auth packages/fespalier_sign_keypair packages/fespalier_adaptive packages/fespalier_flags packages/fespalier_storage packages/fespalier_connectivity packages/fespalier_image packages/fespalier_dio packages/fespalier_cratestack packages/fespalier_sentry packages/fespalier_tolgee packages/fespalier_forms packages/fespalier_maps packages/fespalier_push packages/fespalier_biometrics packages/fespalier_analytics packages/fespalier_frb packages/fespalier_riverpod examples/shop examples/features examples/tabs examples/minimal examples/telemetry examples/auth examples/plugins"

# The examples whose committed lib/app.g.dart must match what `fsp gen` writes.
examples := "shop features tabs minimal telemetry auth plugins"

# List recipes
default:
    @just --list

# Format everything: cargo fmt, and dart format over the package and the examples
fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd cli && cargo fmt)
    for d in {{ dart_dirs }}; do
        (cd "$d" && flutter pub get >/dev/null \
            && find . -name '*.dart' ! -name '*.g.dart' -not -path './.dart_tool/*' -not -path './build/*' -print0 \
            | xargs -0 dart format)
    done

# Formatting and clippy on the generator, warnings are errors
[working-directory: 'cli']
lint:
    cargo fmt --check
    cargo clippy --all-targets -- -D warnings

# Needs `dart` on PATH for the tests that compare with `dart format`; they skip without it.
#
# The generator's unit and integration tests, incl. the version checks
[working-directory: 'cli']
test:
    cargo test

# Licences, advisories, duplicate versions, sources (cli/deny.toml)
[working-directory: 'cli']
deny:
    cargo deny check

# `fsp check` on every example, and `fsp maestro --check` and `fsp test --check` on the shop
[working-directory: 'cli']
check-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in {{ examples }}; do
        cargo run --quiet -- check --project "../examples/$e"
    done
    # The shop's committed Maestro flows (.maestro/routes/) are what `fsp maestro` writes.
    cargo run --quiet -- maestro --check --project ../examples/shop
    # ... and its committed smoke tests (test/routes/routes_test.dart) are what `fsp test` writes.
    cargo run --quiet -- test --check --project ../examples/shop

# Regenerate every example's committed lib/app.g.dart, the shop's .maestro/routes and test/routes/routes_test.dart (after changing the emitter or a template)
[working-directory: 'cli']
gen-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in {{ examples }}; do
        cargo run --quiet -- gen --project "../examples/$e"
    done
    cargo run --quiet -- maestro --project ../examples/shop
    cargo run --quiet -- test --project ../examples/shop

# The package, the DevTools extension, the companion packages and every example: pub get, dart format (generated *.g.dart left out), analyze, test,
# and the const lints on each example's generated code (scripts/check-const-lints.sh)
flutter:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in {{ dart_dirs }}; do
        echo "==> $d"
        (cd "$d" \
            && flutter pub get \
            && find . -name '*.dart' ! -name '*.g.dart' -not -path './.dart_tool/*' -not -path './build/*' -print0 \
                | xargs -0 dart format --output=none --set-exit-if-changed \
            && flutter analyze \
            && flutter test)
        # The generated code is clean under the const lints its `ignore_for_file` hides.
        case "$d" in examples/*) scripts/check-const-lints.sh "$d" ;; esac
    done

# What CI's `floor` job runs: the package, its companions that claim Flutter 3.32 and examples/minimal.
floor_dirs := "packages/fespalier packages/fespalier_otel packages/fespalier_auth packages/fespalier_adaptive packages/fespalier_image packages/fespalier_flags packages/fespalier_storage packages/fespalier_connectivity packages/fespalier_dio packages/fespalier_cratestack packages/fespalier_sentry packages/fespalier_tolgee packages/fespalier_forms packages/fespalier_maps packages/fespalier_push packages/fespalier_biometrics packages/fespalier_analytics packages/fespalier_frb packages/fespalier_riverpod examples/minimal"

# Needs a Flutter 3.32 SDK, whose minor must match FLUTTER_FLOOR_VERSION in ci.yml:
# `git clone --depth 1 -b 3.32.8 https://github.com/flutter/flutter ~/flutter-3.32`. Each pubspec.lock
# is put back as it was afterwards (and the test assets removed), so a later `just flutter` is not left
# on the lowest versions or on assets that another Flutter compiled.
#
# The declared floor as CI's `floor` job runs it, `just floor <sdk dir>` or FLUTTER_FLOOR=<sdk dir>: pub downgrade, analyze, test (not part of `just ci`)
floor sdk=env("FLUTTER_FLOOR", ""):
    #!/usr/bin/env bash
    set -euo pipefail
    sdk="{{ sdk }}"
    if [ -z "$sdk" ] || [ ! -x "$sdk/bin/flutter" ]; then
        echo "just floor needs a Flutter 3.32 SDK: just floor <dir>, or FLUTTER_FLOOR=<dir> (see 'just --list')" >&2
        exit 2
    fi
    want="$(sed -n 's/^  FLUTTER_FLOOR_VERSION: *\([0-9]*\.[0-9]*\)\..*/\1/p' .github/workflows/ci.yml)"
    have="$("$sdk/bin/flutter" --version --machine 2>/dev/null | sed -n 's/.*"frameworkVersion": *"\([0-9]*\.[0-9]*\)\..*/\1/p' | head -n 1)"
    if [ -z "$want" ] || [ "$have" != "$want" ]; then
        echo "just floor: $sdk is Flutter '${have:-?}', ci.yml's FLUTTER_FLOOR_VERSION is '${want:-?}'.x" >&2
        exit 2
    fi
    export PATH="$sdk/bin:$PATH"
    saved="$(mktemp -d)"
    restore() {
        for d in {{ floor_dirs }}; do
            rm -f "$d/pubspec.lock"
            # The 3.32 test assets (compiled shaders) do not load under another Flutter.
            rm -rf "$d/build/unit_test_assets"
            if [ -f "$saved/${d//\//_}" ]; then mv "$saved/${d//\//_}" "$d/pubspec.lock"; fi
        done
        rm -rf "$saved"
    }
    trap restore EXIT
    for d in {{ floor_dirs }}; do
        if [ -f "$d/pubspec.lock" ]; then cp "$d/pubspec.lock" "$saved/${d//\//_}"; fi
    done
    for d in {{ floor_dirs }}; do
        echo "==> $d (Flutter $have, lowest dependencies)"
        (cd "$d" && flutter pub downgrade && flutter analyze && flutter test)
    done

# Rebuild the DevTools extension into packages/fespalier/extension/devtools/build (needs Flutter)
devtools-build:
    scripts/build-devtools-extension.sh

# The committed DevTools extension is what its source builds to, and DevTools accepts it (needs Flutter)
devtools:
    scripts/build-devtools-extension.sh --check

# The telemetry stack (cli/templates/telemetry): generated dashboards are fresh, queries use only the telemetry conventions,
# the JSON has the shape OpenObserve and Grafana need, compose.yaml pins its images, and the importer runs against a fake
# OpenObserve. `docker compose config` checks the compose file where Compose is installed (CI requires it)
telemetry:
    python3 scripts/test_telemetry.py

# Regenerate the OpenObserve and Grafana dashboards, fields.json and the collector's dimensions from scripts/telemetry/dashboards.toml
telemetry-dashboards:
    python3 scripts/telemetry/build_dashboards.py

# Run the stack in Docker, send a seeded session and run every panel's query on both backends (needs Docker and about 1.9 GB of
# images; CI runs it as the `telemetry-smoke` job, `just ci` does not)
telemetry-smoke:
    python3 scripts/telemetry/smoke.py

# The Homebrew/Scoop rendering, checksum pinning and release staging tests
packaging:
    python3 scripts/test_packaging.py
    python3 scripts/test_pin_checksums.py
    python3 scripts/test_verify_staged.py
    python3 scripts/test_release_assets.py

# The agent skills in skills/ match the code: coverage, frontmatter, stamps, links (needs Node)
skills:
    node scripts/skills/verify-coverage.mjs
    npx --yes prettier@3.8.1 --check README.md "docs/*.md" "skills/**/*.{md,json}"

# Build the skills' code samples, all or the given .md files (needs Flutter; slow, not in `just ci`)
skill-samples *files:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd cli && cargo build --quiet)
    FSP="$PWD/cli/target/debug/fsp" node scripts/skills/verify-samples.mjs {{ files }}

# FSP_CHROMIUM=/path/to/chrome uses a Chromium that is already on disk.
#
# Regenerate the docs screenshots in docs/images/telemetry (Docker, Node, Chromium; about 10 minutes; not part of `just ci` or CI)
telemetry-screenshots:
    cd ci/web-routes && npm ci
    node scripts/telemetry/screenshots.mjs

# The VS Code extension: compile, unit-test, package (needs Node; not part of `just ci`)
[working-directory: 'editors/vscode']
vscode:
    npm ci
    npm test
    npx --no-install vsce package --no-dependencies

# The IntelliJ plugin: build and package (needs JDK 21; not part of `just ci`)
[working-directory: 'editors/intellij']
intellij:
    ./gradlew build --no-daemon
    ./gradlew buildPlugin verifyPluginStructure --no-daemon

# A deferred route's page is a chunk of its own on the web: builds examples/shop for the web in
# a temporary copy, checks the split, and runs `fsp size --check` on it (the budgets in the shop's
# `size:` section), cross-checked with the marker strings (needs Flutter with web support; about a
# minute plus building `fsp`, and not part of `just ci`; CI runs it as the `web` job)
web-chunks:
    scripts/check-deferred-chunks.sh examples/shop '/checkout=Place order' '/products/:id=Add to cart'

# The committed Maestro flows of examples/shop open their routes in Chromium (Playwright, pinned in
# ci/web-routes/package-lock.json) against a release web build; every non-local request is blocked.
# Needs Flutter and Node; about two minutes, and not part of `just ci` (CI runs it as `web-routes`)
web-routes:
    cd ci/web-routes && npm ci && npx --no-install playwright install chromium
    scripts/check-web-routes.sh examples/shop

# `fsp dev` against the real flutter: a fresh web app with `fsp init` in headless Chrome. It waits for the
# app, adds a route (a hot restart), edits a page (a hot reload) and quits with `q`: the one check of fsp
# against flutter's real `--machine` protocol. Needs Flutter with web support and Chrome (CHROME_EXECUTABLE
# names one that is not on the path); about a minute, and not part of `just ci`
dev-e2e:
    scripts/check-dev-e2e.sh

# The scaffold job (`fsp new` / `fsp init` into a fresh app) runs in CI only; the editor jobs
# are `just vscode` and `just intellij`, the web builds are `just web-chunks` (the deferred pages) and
# `just web-routes` (the Maestro flows), the stack in Docker is `just telemetry-smoke`, the Flutter 3.32
# floor is `just floor`, and the docs screenshots are `just telemetry-screenshots` (not in CI at all).
#
# The gate: CI's Rust, Flutter, DevTools, packaging, telemetry and skills jobs
ci: lint test deny check-examples flutter devtools packaging telemetry skills
