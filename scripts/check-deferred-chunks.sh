#!/usr/bin/env bash
# A deferred route's page really is a chunk of its own on the web.
#
# Builds the example for the web (`flutter build web --release`, JavaScript) in a throwaway copy,
# and checks that dart2js split the deferred pages out: there is at least one
# `main.dart.js_N.part.js`, and each marker (a string only a deferred page contains) is in a part
# file and not in `main.dart.js`. The examples stay platform-free: the `web/` folder that
# `flutter create` adds lives in the copy (scripts/web-copy.sh), which is removed on exit.
#
# Usage: scripts/check-deferred-chunks.sh <example-dir> <marker>...
#   scripts/check-deferred-chunks.sh examples/shop 'Place order' 'Add to cart'
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <example-dir> <marker>..." >&2
  exit 2
fi

# shellcheck source=web-copy.sh
source "$(dirname "${BASH_SOURCE[0]}")/web-copy.sh"
web_copy "$1"
shift
flutter build web --release

out=build/web
main="$out/main.dart.js"
parts=("$out"/main.dart.js_*.part.js)
if [ ! -f "$main" ] || [ ! -e "${parts[0]}" ]; then
  echo "FAIL: no deferred chunk (main.dart.js_N.part.js) in $out; dart2js did not split anything" >&2
  ls -l "$out" >&2
  exit 1
fi
echo "main.dart.js and ${#parts[@]} deferred chunk(s): ${parts[*]##*/}"

status=0
for marker in "$@"; do
  if grep -qF -- "$marker" "$main"; then
    echo "FAIL: '$marker' is in main.dart.js: its page is not deferred" >&2
    status=1
  elif ! grep -qF -- "$marker" "${parts[@]}"; then
    echo "FAIL: '$marker' is in no deferred chunk" >&2
    status=1
  else
    where="$(grep -lF -- "$marker" "${parts[@]}" | xargs -n1 basename | paste -sd, -)"
    echo "ok: '$marker' is in $where and not in main.dart.js"
  fi
done
exit "$status"
