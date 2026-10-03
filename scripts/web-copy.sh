#!/usr/bin/env bash
# Sourced by the web scripts (check-deferred-chunks.sh, check-web-routes.sh), not run.
#
# `web_copy <example-dir>` copies the example and the package into a throwaway folder, keeping the
# `path: ../../packages/fespalier` layout, adds a `web/` folder with `flutter create`, runs
# `flutter pub get` and changes into the copy. The examples stay platform-free: the `web/` folder
# is never committed.
#
# It sets `root` (this repository), `example` (the example's absolute path), `work` (the
# throwaway folder) and `copy` (the example inside it), and installs an EXIT trap that removes
# `work` (and kills `$server`, when the caller starts one and sets it). The caller has
# `set -euo pipefail`.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

web_cleanup() {
  if [ -n "${server:-}" ]; then
    kill "$server" 2>/dev/null || true
  fi
  rm -rf "${work:-}"
}

web_copy() {
  example="$(cd "$1" && pwd)"
  work="$(mktemp -d)"
  trap web_cleanup EXIT

  local name
  name="$(basename "$example")"
  mkdir -p "$work/examples" "$work/packages"
  cp -R "$example" "$work/examples/$name"
  cp -R "$root/packages/fespalier" "$work/packages/fespalier"
  rm -rf \
    "$work/examples/$name/build" "$work/examples/$name/.dart_tool" \
    "$work/packages/fespalier/build" "$work/packages/fespalier/.dart_tool"

  copy="$work/examples/$name"
  cd "$copy" || return 1
  flutter create --platforms web --no-pub .
  flutter pub get
}
