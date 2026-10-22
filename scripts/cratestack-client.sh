#!/usr/bin/env bash
# The generated client of examples/cratestack: `cratestack generate-dart --preset fespalier` over
# examples/cratestack/server/schema.cstack, into examples/cratestack/client.
#
#   scripts/cratestack-client.sh install    cargo install the pinned CLI (a few minutes)
#   scripts/cratestack-client.sh generate   write the client (and its build_runner output) in place
#   scripts/cratestack-client.sh check      generate into a temporary directory and compare: fails
#                                           when the committed client is stale against the schema
#
# Needs the `cratestack` CLI built from CrateStack's commit CRATESTACK_REV (`just cratestack-cli`
# installs it: the preset is merged there, cratestack/cratestack#1206, and is in no release yet) and
# Flutter's `dart`. `generate` also needs network (`flutter pub get` and build_runner).
#
# The CLI goes into a folder of its own, named after the commit (CRATESTACK_CLI_ROOT, by default
# ~/.cache/fespalier/cratestack-<rev>), and this script runs that binary and no other: a `cratestack`
# on PATH is often another version (another project's pin), and `cargo install` into ~/.cargo/bin
# would replace it.
#
# What is compared by `check` is what the generator writes (the sources, the pubspec, the READMEs),
# formatted. The files build_runner writes from them (`*.g.dart`, `*.mapper.dart`, `*.builder.dart`)
# are committed too, so that the example builds from a clone with `flutter pub get`, but they are not
# compared: their text depends on the builders' resolution, and a stale one does not compile.
set -euo pipefail

# Where the preset is merged: CrateStack's main at the merge of cratestack/cratestack#1206.
CRATESTACK_REV=642fc9abec3da6906ab0423fd9452a3198cb97ca
# The fespalier commit the generated pubspec pins fespalier_transport at (`--fespalier-ref`). A
# commit and not a tag: the pin is never read by anything in this repository (the example overrides
# fespalier_transport with the checkout, see its pubspec.yaml), a `ref: v...` in a pubspec is read by
# cli/tests/versions.rs as fespalier's own version, and release-please, which moves those on every
# release, does not edit generated files. In your own app leave --fespalier-ref out: it defaults to
# the release tag the generator targets.
FESPALIER_REF=d6e14404bf4bbfe9f558fab489f9f2f80f7cc42a

root=$(cd "$(dirname "$0")/.." && pwd)
cli_root=${CRATESTACK_CLI_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/fespalier/cratestack-$CRATESTACK_REV}
cli=$cli_root/bin/cratestack
example=$root/examples/cratestack
schema=$example/server/schema.cstack

# The package's SDK constraint is '>=3.0.0 <4.0.0', so that is the language version dart format uses
# for it inside the example (its package_config says so): the style of Dart 3.0.
format() {
  find "$1" -name '*.dart' ! -name '*.g.dart' -not -path '*/.dart_tool/*' -print0 |
    xargs -0 dart format --language-version=3.0 --output=write --summary=none > /dev/null 2>&1
}

require_cli() {
  if [ ! -x "$cli" ]; then
    echo "$cli is missing: run \`just cratestack-cli\` (scripts/cratestack-client.sh install) first" >&2
    exit 1
  fi
}

generate_into() {
  require_cli
  "$cli" generate-dart \
    --schema "$schema" \
    --out "$1" \
    --library-name orders_client \
    --preset fespalier \
    --fespalier-ref "$FESPALIER_REF" \
    --no-native-cbor
}

case "${1:-}" in
  install)
    cargo install --git https://github.com/cratestack/cratestack --rev "$CRATESTACK_REV" cratestack-cli \
      --locked --root "$cli_root"
    ;;
  generate)
    out=$example/client
    # A type that left the schema must leave the client: the generator only writes.
    rm -rf "${out:?}/lib" "${out:?}/test" "${out:?}/example" "${out:?}/.dart_tool"
    generate_into "$out"
    cp "$out/analysis_options.yaml" "$out/analysis_options.yaml.generated"
    # Resolve the client on its own, with fespalier_transport from this checkout (the pubspec pins a
    # commit of github.com/fespalier/fespalier), and run its builders.
    cat > "$out/pubspec_overrides.yaml" << 'YAML'
dependency_overrides:
  fespalier_transport:
    path: ../../../packages/fespalier_transport
YAML
    (cd "$out" && flutter pub get && dart run build_runner build)
    # `flutter pub get` adds an `analyzer: exclude:` block to analysis_options.yaml; the generator's
    # file is the one that is compared.
    mv "$out/analysis_options.yaml.generated" "$out/analysis_options.yaml"
    rm -rf "$out/pubspec_overrides.yaml" "$out/pubspec.lock" "$out/.dart_tool"
    format "$out"
    ;;
  check)
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    generate_into "$tmp/client"
    format "$tmp/client"
    if ! diff -r \
      -x '*.g.dart' -x '*.mapper.dart' -x '*.builder.dart' \
      -x pubspec.lock -x .dart_tool -x pubspec_overrides.yaml \
      "$tmp/client" "$example/client"; then
      echo "examples/cratestack/client is stale against server/schema.cstack: run scripts/cratestack-client.sh generate" >&2
      exit 1
    fi
    echo "examples/cratestack/client is up to date"
    ;;
  *)
    echo "usage: $0 install|generate|check" >&2
    exit 2
    ;;
esac
