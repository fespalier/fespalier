#!/usr/bin/env bash
# `fsp create` against the real flutter (`just create-check`): makes an app, then checks it the way
# a person would: `dart format --set-exit-if-changed` over the Dart files that are not generated,
# `flutter analyze` and `flutter test`.
#
# The cases are `base` (no features), one per feature that `fsp create --list-features --json`
# lists, and `all` (every feature at once, when there are two or more). Name the cases on the
# command line to run only those; with none, every case runs; `--list` prints them. CI's `create` job runs one case per
# matrix entry, with the same script.
#
# The apps depend on this checkout (`--local-packages`), not on a git tag, so what is checked is
# the code under review. Web is the only platform made: the checks need no other. Needs Flutter
# and network for `flutter pub get`. FSP_BIN is the fsp to run (default: cli/target/debug/fsp,
# built here).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fsp="${FSP_BIN:-}"
if [ -z "$fsp" ]; then
  (cd "$root/cli" && cargo build --quiet)
  fsp="${CARGO_TARGET_DIR:-$root/cli/target}/debug/fsp"
fi
[ -x "$fsp" ] || {
  echo "::error::no fsp at $fsp" >&2
  exit 1
}

# The ids of the optional features, one per line, from the table `fsp create` itself reads.
ids=$("$fsp" create --list-features --json | sed -n 's/^{"id":"\([a-z0-9_]*\)".*/\1/p')

all_cases=(base)
for id in $ids; do all_cases+=("$id"); done
if [ "$(printf '%s\n' "$ids" | grep -c .)" -ge 2 ]; then all_cases+=(all); fi

# `--list` prints the cases, one per line: CI builds its matrix from it.
if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${all_cases[@]}"
  exit 0
fi

cases=("$@")
if [ "${#cases[@]}" -eq 0 ]; then cases=("${all_cases[@]}"); fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
  local name=$1 features
  case "$name" in
    base) features="" ;;
    all) features=$(printf '%s\n' "$ids" | paste -sd, -) ;;
    *)
      printf '%s\n' "$ids" | grep -qx "$name" || {
        echo "::error::no feature called $name (fsp create --list-features)" >&2
        return 1
      }
      features=$name
      ;;
  esac
  local app="app_$name"
  echo "== create $name${features:+ (--features $features)}"
  if [ -n "$features" ]; then
    "$fsp" create "$work/$app" --local-packages "$root" --platforms web --features "$features"
  else
    "$fsp" create "$work/$app" --local-packages "$root" --platforms web
  fi
  (
    cd "$work/$app"
    # Generated files are left as the generator wrote them (`format:` is off), like the examples.
    find lib test -name '*.dart' ! -name '*.g.dart' -print0 | xargs -0 dart format --set-exit-if-changed
    flutter analyze
    flutter test
  )
  rm -rf "${work:?}/$app"
}

for name in "${cases[@]}"; do
  check "$name"
done
echo "✓ fsp create: ${cases[*]}"
