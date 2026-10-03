#!/usr/bin/env bash
# Sourced by the web scripts (check-deferred-chunks.sh, check-web-routes.sh), not run.
#
# `web_copy <example-dir>` copies the example and the packages it depends on by path
# (`path: ../../packages/fespalier`, and `fespalier_image` for the shop) into a throwaway folder,
# keeping that layout, adds a `web/` folder with `flutter create`, runs
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
    kill "$server" 2> /dev/null || true
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
  rm -rf "$work/examples/$name/build" "$work/examples/$name/.dart_tool"
  # fespalier, and every other package of this repository that the example's pubspec.yaml names
  # by a path (fespalier_image, since 0.9.0).
  local package
  # shellcheck disable=SC2046 # the names are words
  for package in fespalier $(sed -n 's|^ *path: \.\./\.\./packages/\([a-z_]*\) *$|\1|p' "$example/pubspec.yaml"); do
    if [ ! -d "$work/packages/$package" ]; then
      cp -R "$root/packages/$package" "$work/packages/$package"
      rm -rf "$work/packages/$package/build" "$work/packages/$package/.dart_tool"
    fi
  done

  copy="$work/examples/$name"
  cd "$copy" || return 1
  flutter create --platforms web --no-pub .
  flutter pub get
}
