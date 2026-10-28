#!/usr/bin/env bash
# fespalier_dio's fetch adapter in real browsers (`just fetch-adapter`, CI's `fetch-adapter` job):
# compiles packages/fespalier_dio/test/browser/harness.dart with dart2js and dart2wasm into a
# temporary folder, starts packages/fespalier_dio/tool/stream_server.dart on two free ports, and
# runs ci/web-routes/fetch.mjs (Playwright, pinned in ci/web-routes/package-lock.json) in Chromium,
# Firefox and WebKit, or the engines named as arguments.
#
#   scripts/check-fetch-adapter.sh [chromium|firefox|webkit ...]
#
# Needs Flutter's dart on PATH (with the workspace resolved: `flutter pub get` is run here), Node,
# and `npm ci` plus `npx playwright install` done in ci/web-routes.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
package="$root/packages/fespalier_dio"
work=$(mktemp -d)
server=
cleanup() {
  if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

(cd "$package" && flutter pub get >/dev/null)

# An entry under packages/fespalier_dio finds the workspace's package config by walking up.
started=$(date +%s)
dart compile js -O2 -o "$work/js/harness.dart.js" "$package/test/browser/harness.dart"
dart compile wasm -O2 -o "$work/wasm/harness.wasm" "$package/test/browser/harness.dart"
echo "check-fetch-adapter: compiled both builds in $(($(date +%s) - started)) s"

(cd "$package" && exec dart run tool/stream_server.dart --root "$work" --ports "$work/ports.json") &
server=$!
for _ in $(seq 1 300); do
  [ -f "$work/ports.json" ] && break
  kill -0 "$server" 2>/dev/null || { echo "check-fetch-adapter: the server did not start" >&2; exit 1; }
  sleep 0.1
done
[ -f "$work/ports.json" ] || { echo "check-fetch-adapter: the server wrote no ports" >&2; exit 1; }

node "$root/ci/web-routes/fetch.mjs" "$work/ports.json" "$@"
