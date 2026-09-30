#!/usr/bin/env bash
# Refuses binaries that are not the ones this commit pins. Run from a checkout of the commit
# (the release-pins workflow's verify mode, on the release PR; release.yml, on the tag) with the
# staged files in DIR (scripts/release-assets.sh fetch).
#
#   scripts/verify-staged.sh VERSION DIR
#
# Three facts have to hold, and each is the failure it names:
#   1. build-info.json says the binaries are VERSION's: not the leftovers of an earlier build of
#      the release PR, which proposed another version.
#   2. build-info.json's `cli_tree` equals the tree of cli/ in this commit. cli/ is everything
#      the fsp build reads (sources, templates, Cargo.toml, Cargo.lock), so the binaries were built
#      from the code that is now being tagged. A merge that changed cli/ after the last build
#      fails here. A pin commit, or any change outside cli/, does not.
#   3. every archive's SHA-256 equals what release_checksums.dart pins, for exactly VERSION.
#      (`scripts/pin_checksums.py --check` hashes the archives themselves.)
set -euo pipefail

version="${1:?usage: verify-staged.sh VERSION DIR}"
dir="${2:?usage: verify-staged.sh VERSION DIR}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fail() {
  echo "::error::$*" >&2
  exit 1
}

info="$dir/build-info.json"
[[ -f "$info" ]] || fail "$info is missing: the staged binaries carry no record of what they were built from"

built="$(jq -r '.version // empty' "$info")"
[[ "$built" == "$version" ]] || fail "the staged binaries are for '${built}', this is ${version}: they were built for another version of the release PR"

want="$(jq -r '.cli_tree // empty' "$info")"
have="$(git rev-parse HEAD:cli)"
[[ -n "$want" && "$want" == "$have" ]] || fail "cli/ changed since the staged binaries were built (built from tree '${want}', this commit has '${have}'): they are not this code"

# PINS_FILE exists for the tests
python3 scripts/pin_checksums.py --check --version "$version" --dist "$dir" ${PINS_FILE:+--out "$PINS_FILE"} \
  || fail "the staged archives are not the ones release_checksums.dart pins for ${version}"

echo "verified: the staged archives are the ${version} binaries built from this cli/ tree and pinned in this commit"
