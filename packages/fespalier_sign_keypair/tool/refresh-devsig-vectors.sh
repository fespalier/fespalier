#!/usr/bin/env bash
# Copies Authkestra's device-signature profile v1 conformance vectors at a commit into
# test/fixtures/devsig-profile-v1/, and pins that commit and the file's SHA-256 in PIN.
#
#   tool/refresh-devsig-vectors.sh <commit>                  # fetched from GitHub
#   tool/refresh-devsig-vectors.sh <commit> <checkout>       # read from a local Authkestra checkout
#
# A commit, never a branch or a tag: the pin must name bytes that cannot move. Then run
# `flutter test test/profile_v1_test.dart` and commit vectors.json and PIN together.
set -euo pipefail

commit="${1:?usage: $0 <commit> [authkestra checkout]}"
checkout="${2:-}"
if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: '$commit' is not a full 40-character commit SHA" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$here/test/fixtures/devsig-profile-v1"
path="conformance/devsig-profile-v1/vectors.json"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ -n "$checkout" ]]; then
  git -C "$checkout" show "$commit:$path" > "$tmp"
else
  curl -fsSL "https://raw.githubusercontent.com/Authkestra/authkestra/$commit/$path" -o "$tmp"
fi
python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$tmp"

sum="$(sha256sum "$tmp" | cut -d' ' -f1)"
mv "$tmp" "$dir/vectors.json"
trap - EXIT
cat > "$dir/PIN" << PIN
# Authkestra's device-signature profile v1 conformance vectors (RFC-014), copied unchanged.
# Never edit vectors.json: run tool/refresh-devsig-vectors.sh <commit>, which rewrites both files.
# test/profile_v1_test.dart fails when the copy's SHA-256 is not the one below.
repository: https://github.com/Authkestra/authkestra
path: $path
commit: $commit
sha256: $sum
PIN
echo "vectors.json at $commit ($sum)"
