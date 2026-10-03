#!/usr/bin/env bash
# A deferred route's page really is a chunk of its own on the web.
#
# Builds the example for the web (`flutter build web --release`, JavaScript) in a throwaway copy,
# and checks that dart2js split the deferred pages out: there is at least one
# `main.dart.js_N.part.js`, and each marker (a string only a deferred page contains) is in a part
# file and not in `main.dart.js`. The examples stay platform-free: the `web/` folder that
# `flutter create` adds lives in the copy, which is removed on exit.
#
# It then runs `fsp size` on the build: `fsp size --check` (the budgets in the example's `size:`
# section of pubspec.yaml), and `fsp size --json` to confirm that each marker's part file is one
# of the parts `fsp size` attributes to the route the marker belongs to. That is an end-to-end
# check of the attribution, which reads dart2js's table in main.dart.js, not the part files.
#
# Usage: scripts/check-deferred-chunks.sh <example-dir> <pattern>=<marker>...
#   scripts/check-deferred-chunks.sh examples/shop '/checkout=Place order' '/products/:id=Add to cart'
# A pattern is a route as `fsp routes` prints it; split at the first `=`.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <example-dir> <pattern>=<marker>..." >&2
  exit 2
fi
for arg in "${@:2}"; do
  case "$arg" in
    /*=?*) ;;
    *)
      echo "usage: $0 <example-dir> <pattern>=<marker>... (got '$arg')" >&2
      exit 2
      ;;
  esac
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
example="$(cd "$1" && pwd)"
shift

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The generator, built inside cli/ (cargo reads rust-toolchain.toml only from there).
(cd "$root/cli" && cargo build --quiet)
target="$(cd "$root/cli" && cargo metadata --no-deps --format-version 1 |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])')"
fsp="$target/debug/fsp"

# The example refers to the package by `path: ../../packages/fespalier`: keep that layout.
name="$(basename "$example")"
mkdir -p "$work/examples" "$work/packages"
cp -R "$example" "$work/examples/$name"
cp -R "$root/packages/fespalier" "$work/packages/fespalier"
rm -rf \
  "$work/examples/$name/build" "$work/examples/$name/.dart_tool" \
  "$work/packages/fespalier/build" "$work/packages/fespalier/.dart_tool"

cd "$work/examples/$name"
flutter create --platforms web --no-pub .
flutter pub get
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
for arg in "$@"; do
  marker="${arg#*=}"
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

# `fsp size` on the same build: within budget, and the same attribution as the marker strings.
fsp_project=(--project "$work/examples/$name")
"$fsp" size "${fsp_project[@]}" --check || status=1
"$fsp" size "${fsp_project[@]}" --json > "$work/size.jsonl"
for arg in "$@"; do
  pattern="${arg%%=*}"
  marker="${arg#*=}"
  for file in $(grep -lF -- "$marker" "${parts[@]}" | xargs -n1 basename); do
    if ! python3 - "$work/size.jsonl" "$pattern" "$file" << 'PY'; then
import json
import sys

path, pattern, file = sys.argv[1:]
with open(path, encoding="utf-8") as lines:
    rows = [json.loads(line) for line in lines]
route = next((r for r in rows if r["kind"] == "route" and r["pattern"] == pattern), None)
sys.exit(0 if route is not None and file in route["parts"] else 1)
PY
      echo "FAIL: '$marker' is in $file, which $pattern does not load according to fsp size" >&2
      status=1
    else
      echo "ok: fsp size attributes $file to $pattern"
    fi
  done
done
exit "$status"
