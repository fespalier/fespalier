#!/usr/bin/env bash
# Prints one of the places that spell out fsp's version, so that the release workflows and the
# PR-time check (`cargo test --test versions`, cli/tests/versions.rs) run the SAME extractions.
#
#   scripts/read-version.sh cargo     cli/Cargo.toml       [package] version
#   scripts/read-version.sh pubspec   packages/fespalier/pubspec.yaml
#   scripts/read-version.sh manifest  .release-please-manifest.json
#   scripts/read-version.sh lock      cli/Cargo.lock       the fespalier package's own entry
#
# Every extraction tolerates trailing content on the line: release-please's annotation makes the
# Cargo and pubspec lines read `version = "X.Y.Z" # <annotation>`, and an
# end-anchored pattern (`s/^version = "\(.*\)"$/\1/p`) then matches NOTHING and prints an empty
# version. That is how vaam-apps/vsms published nothing for v0.3.2 (org releasing.md, trap 6).
# An empty result is an error here, never an empty string.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

extract() {
  case "$1" in
    cargo)
      sed -n '/^\[package\]/,/^\[/s/^version *= *"\([^"]*\)".*$/\1/p' "$root/cli/Cargo.toml" | head -n 1
      ;;
    pubspec)
      sed -n -E "s/^version:[[:space:]]*[\"']?([^[:space:]\"'#]+).*\$/\\1/p" "$root/packages/fespalier/pubspec.yaml" | head -n 1
      ;;
    manifest)
      sed -n -E 's/^[[:space:]]*"\.":[[:space:]]*"([^"]*)".*$/\1/p' "$root/.release-please-manifest.json" | head -n 1
      ;;
    lock)
      awk '/^name = "fespalier"$/ { getline; if ($0 ~ /^version = "/) { sub(/^version = "/, ""); sub(/".*$/, ""); print; exit } }' "$root/cli/Cargo.lock"
      ;;
    *)
      echo "usage: $0 cargo|pubspec|manifest|lock" >&2
      exit 2
      ;;
  esac
}

version="$(extract "${1:-}")"
if [[ -z "$version" ]]; then
  echo "::error::could not read the $1 version (see scripts/read-version.sh)" >&2
  exit 1
fi
printf '%s\n' "$version"
