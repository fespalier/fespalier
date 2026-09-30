# fespalier — task runner. `just ci` is the gate: it runs locally what .github/workflows/ci.yml
# runs, and nothing is "verified" until it exits 0 on the final head. It needs Rust (the
# toolchain in cli/rust-toolchain.toml installs itself), Flutter (see FLUTTER_VERSION in
# ci.yml), python3, `just` and `cargo-deny`.

set shell := ["bash", "-euo", "pipefail", "-c"]

# The Dart package and every example: pub get, dart format, flutter analyze, flutter test.
dart_dirs := "packages/fespalier examples/shop examples/features examples/tabs examples/minimal"

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

# `fsp check` on every example
[working-directory: 'cli']
check-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in {{ examples }}; do
        cargo run --quiet -- check --project "../examples/$e"
    done

# Regenerate every example's committed lib/app.g.dart (after changing the emitter or a template)
[working-directory: 'cli']
gen-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in {{ examples }}; do
        cargo run --quiet -- gen --project "../examples/$e"
    done

# The package and every example: pub get, dart format (generated *.g.dart left out), analyze, test
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
    done

# The Homebrew/Scoop rendering, checksum pinning and release staging tests
packaging:
    python3 scripts/test_packaging.py
    python3 scripts/test_pin_checksums.py
    python3 scripts/test_verify_staged.py
    python3 scripts/test_release_assets.py

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

# The scaffold job (`fsp new` / `fsp init` into a fresh app) runs in CI only; the editor jobs
# are `just vscode` and `just intellij`.
#
# The gate: CI's Rust, Flutter and packaging jobs
ci: lint test deny check-examples flutter packaging
