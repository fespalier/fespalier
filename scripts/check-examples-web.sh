#!/usr/bin/env bash
# One example's routes open in a release web build in Chromium.
#
# Builds the example for the web (`flutter build web --release --no-web-resources-cdn`, so
# CanvasKit and Roboto are bundled and nothing is fetched from a CDN) in a throwaway copy
# (scripts/web-copy.sh), with the `--dart-define`s its entry in ci/web-routes/examples.json names,
# and hands build/web to ci/web-routes/examples.mjs:
#
#   default   every URL of the entry opens, shows its text, settles, logs no error and requests
#             nothing but the local server (`just examples-web`, CI's `examples-web` job).
#   --print   the same, and every text each page shows (to write an `expect`).
#
# The examples stay platform-free: the `web/` folder that `flutter create` adds lives in the copy,
# which is removed on exit.
#
# Usage: scripts/check-examples-web.sh <example-dir> [--print]
#   scripts/check-examples-web.sh examples/minimal
# Needs `npm ci` in ci/web-routes, and a Chromium: FSP_CHROMIUM=/path/to/chrome, or
# `npx --no-install playwright install chromium` there.
# `root` and `copy` come from web-copy.sh.
# shellcheck disable=SC2154
set -euo pipefail

usage() {
  echo "usage: $0 <example-dir> [--print]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
dir="$1"
shift
print=()
if [ "$#" -eq 1 ] && [ "$1" = "--print" ]; then
  print=(--print)
elif [ "$#" -gt 0 ]; then
  usage
fi
name="$(basename "$dir")"

# shellcheck source=web-copy.sh
source "$(dirname "${BASH_SOURCE[0]}")/web-copy.sh"

if [ ! -d "$root/ci/web-routes/node_modules" ]; then
  echo "run npm ci in ci/web-routes first" >&2
  exit 2
fi

# The entry's `defines`, one `--dart-define=KEY=VALUE` per line (exit 2 when the example has no entry).
# shellcheck disable=SC2016 # the ${...} are JavaScript's, not the shell's
spec_defines="$(node -e '
  const spec = require(process.argv[1]);
  const entry = spec.examples[process.argv[2]];
  if (!entry) {
    console.error(`ci/web-routes/examples.json has no entry for ${process.argv[2]}`);
    process.exit(2);
  }
  for (const [key, value] of Object.entries(entry.defines ?? {})) console.log(`--dart-define=${key}=${value}`);
' "$root/ci/web-routes/examples.json" "$name")"
defines=()
while IFS= read -r define; do
  if [ -n "$define" ]; then
    defines+=("$define")
  fi
done <<< "$spec_defines"

web_copy "$dir"
# --no-wasm-dry-run: the dry run of a Wasm build only prints warnings, and takes minutes for the
# examples with large dependencies (telemetry).
flutter build web --release --no-web-resources-cdn --no-wasm-dry-run ${defines[@]+"${defines[@]}"}

node "$root/ci/web-routes/examples.mjs" check "$name" "$copy/build/web" ${print[@]+"${print[@]}"}
