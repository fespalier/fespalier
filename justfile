# fespalier — task runner. `just ci` is the gate: it runs locally what .github/workflows/ci.yml
# runs, and nothing is "verified" until it exits 0 on the final head. It needs Rust (the
# toolchain in cli/rust-toolchain.toml installs itself), Flutter (see FLUTTER_VERSION in
# ci.yml), python3, Node, `just` and `cargo-deny`.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The pub workspace's packages: the root pubspec.yaml's `workspace:` list, the packages that claim Flutter 3.35
# (fespalier_devtools aside). They share one resolution (`melos bootstrap`).
members := `sed -n '/^workspace:/,/^[^ ]/s/^  - //p' pubspec.yaml | sed 's/ *#.*//' | tr '\n' ' '`

# Resolved on their own, outside the workspace: the packages that need a newer Flutter, the DevTools extension
# (its lockfile is committed) and every example. cli/tests/versions.rs keeps this list complete.
outside_dirs := "packages/fespalier_devtools packages/fespalier_sign_keypair packages/fespalier_download_background examples/shop examples/features examples/tabs examples/minimal examples/telemetry examples/auth examples/plugins examples/downloads examples/i18n examples/maps examples/adopt examples/offline examples/cose"

# Every Dart folder: the workspace's packages, then the ones outside it. pub get, dart format, flutter analyze, flutter test.
dart_dirs := members + outside_dirs

# The examples whose committed lib/app.g.dart must match what `fsp gen` writes.
examples := "shop features tabs minimal telemetry auth plugins downloads i18n maps adopt offline cose"

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

# Needs `dart` on PATH for the tests that compare with `dart format` and for the one that checks typedefs
# against the analyzer (`types_tests::follows_typedefs_as_the_analyzer_does`); they skip without it.
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

# The workspace's packages (root pubspec.yaml): one resolution (`melos bootstrap`), then dart format (generated
# *.g.dart left out), analyze and test in each (`melos run check`). Then the packages and examples outside it:
# pub get, the same three, and the const lints on each example's generated code (scripts/check-const-lints.sh)
flutter:
    #!/usr/bin/env bash
    set -euo pipefail
    dart run melos bootstrap
    dart run melos run check < /dev/null
    for d in {{ outside_dirs }}; do
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

# What CI's `floor` job runs: the packages that claim Flutter 3.35 (the workspace's) and examples/minimal.
floor_dirs := members + "examples/minimal"

# Needs a Flutter 3.35 SDK, whose minor must match FLUTTER_FLOOR_VERSION in ci.yml:
# `git clone --depth 1 -b 3.35.7 https://github.com/flutter/flutter ~/flutter-3.35`. The packages run in a
# temporary copy outside the workspace (scripts/floor_copy.py), so the checkout's resolution and test assets
# are left as they were.
#
# The declared floor as CI's `floor` and `floor-app` jobs run it, `just floor <sdk dir>` or FLUTTER_FLOOR=<sdk dir>: pub downgrade, analyze, test for each package, each package alone as an app and then one app with every package (scripts/floor_app.py), at their lowest versions (not part of `just ci`)
floor sdk=env("FLUTTER_FLOOR", ""):
    #!/usr/bin/env bash
    set -euo pipefail
    sdk="{{ sdk }}"
    if [ -z "$sdk" ] || [ ! -x "$sdk/bin/flutter" ]; then
        echo "just floor needs a Flutter 3.35 SDK: just floor <dir>, or FLUTTER_FLOOR=<dir> (see 'just --list')" >&2
        exit 2
    fi
    want="$(sed -n 's/^  FLUTTER_FLOOR_VERSION: *\([0-9]*\.[0-9]*\)\..*/\1/p' .github/workflows/ci.yml)"
    have="$("$sdk/bin/flutter" --version --machine 2>/dev/null | sed -n 's/.*"frameworkVersion": *"\([0-9]*\.[0-9]*\)\..*/\1/p' | head -n 1)"
    if [ -z "$want" ] || [ "$have" != "$want" ]; then
        echo "just floor: $sdk is Flutter '${have:-?}', ci.yml's FLUTTER_FLOOR_VERSION is '${want:-?}'.x" >&2
        exit 2
    fi
    export PATH="$sdk/bin:$PATH"
    root="$(pwd)"
    # Inside the workspace a pub downgrade moves every package together (one resolution): each package runs
    # in a copy outside it, on its own (scripts/floor_copy.py), removed afterwards.
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    python3 scripts/floor_copy.py "$work/tree" > /dev/null
    # An app at its lowest versions (scripts/floor_app.py): pub downgrade, pub get (the plugin list), the Dart
    # code of the plugins it resolved, flutter test, and the web build (skipped when this SDK has no web
    # support, unless FSP_REQUIRE_WEB=1). $2 is `--only <package>` for an app with one package.
    app_floor() {
        (cd "$1" && flutter pub downgrade && flutter pub get \
            && python3 "$root/scripts/floor_app.py" $2 --plugins . \
            && flutter test \
            && python3 "$root/scripts/floor_app.py" --web .)
    }
    for d in {{ floor_dirs }}; do
        echo "==> $d (Flutter $have, lowest dependencies)"
        (cd "$work/tree/$d" && flutter pub downgrade && flutter analyze && flutter test)
        case "$d" in
            packages/*)
                echo "==> ${d##*/} alone, as an app (Flutter $have, lowest dependencies)"
                python3 scripts/floor_app.py --only "${d##*/}" "$work/tree" "$work/only" > /dev/null
                app_floor "$work/only" "--only ${d##*/}"
                rm -rf "$work/only"
                ;;
        esac
    done
    # One app with every package, at its lowest versions together: the packages meet there.
    python3 scripts/floor_app.py "$work/tree" "$work/app" > /dev/null
    echo "==> the app with every package (Flutter $have, lowest dependencies)"
    app_floor "$work/app" ""

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

# The Homebrew/Scoop rendering, checksum pinning, release staging and manual-release tests
packaging:
    python3 scripts/test_packaging.py
    python3 scripts/test_pin_checksums.py
    python3 scripts/test_verify_staged.py
    python3 scripts/test_release_assets.py
    python3 scripts/test_release_dispatch.py

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

# The cose example's server (examples/cose/server, a standalone Rust crate on cratestack-api 0.15.3):
# fmt, clippy, tests (incl. the committed contracts.json and lib/src/contracts.g.dart), a locked build and
# cargo-deny. A cold build compiles cratestack and takes a couple of minutes, so it is not part of `just ci`.
[working-directory: 'examples/cose/server']
cose-server:
    cargo fmt --check
    cargo clippy --locked --all-targets -- -D warnings
    cargo test --locked
    cargo build --locked
    cargo deny --config deny.toml check

# What CI's `cose` job runs: the server (`cose-server`), then the app in examples/cose against the binary it
# built: dart format, analyze and every test, with the end-to-end test required (it fails instead of skipping),
# (the const lints on the generated code are the `dart` job's and `just flutter`'s). Needs Rust (examples/cose/server/rust-toolchain.toml), cargo-deny
# and Flutter; not part of `just ci` (`just flutter` runs the app's tests too, the end-to-end one skipped)
cose: cose-server
    #!/usr/bin/env bash
    set -euo pipefail
    cd examples/cose
    flutter pub get
    find . -name '*.dart' ! -name '*.g.dart' -not -path './.dart_tool/*' -not -path './build/*' -not -path './server/*' -print0 \
        | xargs -0 dart format --output=none --set-exit-if-changed
    flutter analyze
    COSE_SERVER_BIN="$PWD/server/target/debug/cose-demo-server" FSP_REQUIRE_COSE_SERVER=1 flutter test

# The wire-sizes example's server (examples/wire-sizes/server, a standalone Rust crate on cratestack-api 0.15.3):
# fmt, clippy, tests (the runner drives the router in process, and tests/socket.rs checks one request over a
# real socket), a locked build and cargo-deny, then the report regenerated and compared with the committed
# REPORT.md, so a stale report fails. A cold build compiles cratestack and takes a couple of minutes, so it
# is not part of `just ci`.
[working-directory: 'examples/wire-sizes/server']
wire-sizes:
    cargo fmt --check
    cargo clippy --locked --all-targets -- -D warnings
    cargo test --locked
    cargo build --locked
    cargo deny --config deny.toml check
    # `cargo test` already compares REPORT.md with a fresh measurement; this proves the binary the
    # README tells a reader to run produces the same text.
    diff <(cargo run --locked --quiet --bin wire-sizes-report) REPORT.md

# The committed Maestro flows of examples/shop open their routes in Chromium (Playwright, pinned in
# ci/web-routes/package-lock.json) against a release web build; every non-local request is blocked.
# Needs Flutter and Node; about two minutes, and not part of `just ci` (CI runs it as `web-routes`)
web-routes:
    cd ci/web-routes && npm ci && npx --no-install playwright install chromium
    scripts/check-web-routes.sh examples/shop

# Every example (or the named ones) as a release web build in Chromium: each URL of ci/web-routes/examples.json
# shows its text, nothing throws or logs an error, and nothing is requested but from the local server (the examples stay
# platform-free: each is built in a throwaway copy). FSP_CHROMIUM=/path/to/chrome uses a Chromium already on disk.
# Needs Flutter and Node; two to five minutes per example, and not part of `just ci` (CI runs it as `examples-web`)
examples-web *names:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd ci/web-routes && npm ci)
    if [ -z "${FSP_CHROMIUM:-}" ]; then (cd ci/web-routes && npx --no-install playwright install chromium); fi
    names="{{ names }}"
    failed=()
    for e in ${names:-{{ examples }}}; do
        echo "==> examples/$e"
        scripts/check-examples-web.sh "examples/$e" || failed+=("$e")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        echo "examples-web: failed: ${failed[*]}" >&2
        exit 1
    fi

# The README screenshots of every example (or the named ones): the shots of ci/web-routes/examples.json taken in
# Chromium at 390 x 844 (2x) from a release web build, optimised with a pinned oxipng (Docker, or FSP_OXIPNG) and
# held to the byte budget, into docs/images/examples/<example>/. Needs Flutter, Node and Docker; two to five
# minutes per example; not part of `just ci` or CI (`just example-images` checks the result)
example-screenshots *names:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd ci/web-routes && npm ci)
    if [ -z "${FSP_CHROMIUM:-}" ]; then (cd ci/web-routes && npx --no-install playwright install chromium); fi
    names="{{ names }}"
    for e in ${names:-{{ examples }}}; do
        echo "==> examples/$e"
        scripts/check-examples-web.sh "examples/$e" --shots "docs/images/examples/$e"
    done
    node ci/web-routes/example-images.mjs

# The examples' README screenshots match ci/web-routes/examples.json: every shot is there, of its size, within the
# byte budget, shown by its README, made from the current spec and not edited since (ci/web-routes/example-shots.lock.json),
# and one of the URLs `just examples-web` opens (no browser, no build)
example-images:
    node ci/web-routes/example-images.mjs

# `fsp dev` against the real flutter: a fresh web app with `fsp init` in headless Chrome. fsp dev runs the
# app, reloads a new route in, restarts when it must and quits with `q`: the one check of fsp against
# flutter's real `--machine` protocol. Needs Flutter with web support and Chrome (CHROME_EXECUTABLE
# names one that is not on the path); a few minutes, and not part of `just ci`
dev-e2e:
    scripts/check-dev-e2e.sh

# `fsp create` against the real flutter: the base app and each optional feature, made with this checkout
# as the packages (`--local-packages`) and checked with `dart format`, `flutter analyze` and `flutter test`.
# Name cases to run only those (`just create-check base`). Needs Flutter and network; about two minutes per
# case, and not part of `just ci` (CI's `create` job runs it)
create-check *cases:
    scripts/check-create.sh {{ cases }}

# fespalier next to freezed, json_serializable and build_runner, in a fresh app (about two minutes; needs Flutter and
# network; not part of `just ci`, CI runs it in the `scaffold` job): the warning that build_runner deletes
# lib/app.g.dart, `output:` as the way out, a freezed `extra` restored through `ExtraCodec.of`, and `DataCache.json`
codegen-interop:
    scripts/check-codegen-interop.sh

# The scaffold job (`fsp new` / `fsp init` into a fresh app) runs in CI only, apart from its two steps
# that have a recipe, `just dev-e2e` and `just codegen-interop`; the editor jobs are `just vscode` and
# `just intellij`, the web builds are `just web-chunks` (the deferred pages), `just web-routes` (the
# Maestro flows) and `just examples-web` (every example's routes, one CI job each), the stack in Docker
# is `just telemetry-smoke`, the Flutter 3.35 floor is `just floor`, the cose example with its Rust
# server is `just cose`, and the docs screenshots are `just telemetry-screenshots` (not in CI at all).
# The examples' README screenshots are `just example-screenshots` (not in CI at all); `just example-images` checks them.
#
# The gate: CI's Rust, Flutter, DevTools, packaging, telemetry and skills jobs
ci: lint test deny check-examples flutter devtools packaging telemetry skills example-images
