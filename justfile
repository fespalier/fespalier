# fespalier — task runner. `just ci` is the gate: it runs locally what .github/workflows/ci.yml
# runs, and nothing is "verified" until it exits 0 on the final head. It needs Rust (the
# toolchain in cli/rust-toolchain.toml installs itself), Flutter (see FLUTTER_VERSION in
# ci.yml), python3, Node, `just` and `cargo-deny`.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The Dart package, the DevTools extension and every example: pub get, dart format, flutter analyze, flutter test.
dart_dirs := "packages/fespalier packages/fespalier_devtools examples/shop examples/features examples/tabs examples/minimal"

# The examples whose committed lib/app.g.dart must match what `fsp gen` writes.
examples := "shop features tabs minimal"

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

# `fsp check` on every example, and `fsp maestro --check` on the shop
[working-directory: 'cli']
check-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in {{ examples }}; do
        cargo run --quiet -- check --project "../examples/$e"
    done
    # The shop's committed Maestro flows (.maestro/routes/) are what `fsp maestro` writes.
    cargo run --quiet -- maestro --check --project ../examples/shop

# Regenerate every example's committed lib/app.g.dart and the shop's .maestro/routes (after changing the emitter or a template)
[working-directory: 'cli']
gen-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in {{ examples }}; do
        cargo run --quiet -- gen --project "../examples/$e"
    done
    cargo run --quiet -- maestro --project ../examples/shop

# The package, the DevTools extension and every example: pub get, dart format (generated *.g.dart left out), analyze, test,
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

# Rebuild the DevTools extension into packages/fespalier/extension/devtools/build (needs Flutter)
devtools-build:
    scripts/build-devtools-extension.sh

# The committed DevTools extension is what its source builds to, and DevTools accepts it (needs Flutter)
devtools:
    scripts/build-devtools-extension.sh --check

# The Homebrew/Scoop rendering, checksum pinning and release staging tests
packaging:
    python3 scripts/test_packaging.py
    python3 scripts/test_pin_checksums.py
    python3 scripts/test_verify_staged.py
    python3 scripts/test_release_assets.py

# The agent skills in skills/ match the code: coverage, frontmatter, stamps, links (needs Node)
skills:
    node scripts/skills/verify-coverage.mjs
    npx --yes prettier@3.8.1 --check "skills/**/*.{md,json}"

# Build the skills' code samples, all or the given .md files (needs Flutter; slow, not in `just ci`)
skill-samples *files:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd cli && cargo build --quiet)
    FSP="$PWD/cli/target/debug/fsp" node scripts/skills/verify-samples.mjs {{ files }}

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

# The scaffold job (`fsp new` / `fsp init` into a fresh app) runs in CI only; the editor jobs
# are `just vscode` and `just intellij`, and the web build of the deferred pages is `just web-chunks`.
#
# The gate: CI's Rust, Flutter, DevTools, packaging and skills jobs
ci: lint test deny check-examples flutter devtools packaging skills
