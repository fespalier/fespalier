#!/usr/bin/env bash
# Builds fespalier's DevTools extension (packages/fespalier_devtools, a Flutter web app) into
# packages/fespalier/extension/devtools/build, which is what DevTools loads and what is committed.
#
#   scripts/build-devtools-extension.sh           build, replace the committed build, validate
#   scripts/build-devtools-extension.sh --check   build elsewhere, fail when it differs from the
#                                                 committed build; then validate (what CI runs)
#
# It does NOT call `dart run devtools_extensions build_and_copy`, which does the same build and
# adds what a committed build cannot carry: 37 MB of CanvasKit (the build loads it from gstatic
# anyway), a service worker with a random version in it (so no two builds are the same), and
# every icon of the Material font. This is the same build without them:
#
#   1. the runtime's protocol file is copied into the extension (the two are one source);
#   2. flutter pub get --enforce-lockfile (the committed pubspec.lock is the dependencies);
#   3. flutter build web --release, icons tree-shaken, no source maps;
#   4. the build goes to the destination, without canvaskit/, .last_build_id (it holds the
#      build's path) and the service worker (web/flutter_bootstrap.js registers none).
#
# The build is reproducible: the same sources and the same Flutter give the same bytes, whatever
# folder they are built in. Rebuild after touching packages/fespalier_devtools,
# packages/fespalier/lib/src/devtools/protocol.dart or FLUTTER_VERSION in ci.yml.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ext="$root/packages/fespalier_devtools"
package="$root/packages/fespalier"
dest="$package/extension/devtools/build"
protocol_source="$package/lib/src/devtools/protocol.dart"
protocol_copy="$ext/lib/src/protocol.dart"
rebuild="run scripts/build-devtools-extension.sh (just devtools-build) and commit the result"

check=false
case "${1:-}" in
  "") ;;
  --check) check=true ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

# 1. The protocol file is the runtime's; the extension holds a copy (see AGENTS.md).
if [ "$check" = true ]; then
  if ! cmp -s "$protocol_source" "$protocol_copy"; then
    echo "::error::packages/fespalier_devtools/lib/src/protocol.dart differs from packages/fespalier/lib/src/devtools/protocol.dart: $rebuild" >&2
    exit 1
  fi
else
  cp "$protocol_source" "$protocol_copy"
fi

# 2 and 3.
cd "$ext"
flutter pub get --enforce-lockfile
flutter build web --release --no-wasm-dry-run --no-source-maps

# 4. What the build holds that DevTools does not need or that varies between builds.
staged="$(mktemp -d)"
trap 'rm -rf "$staged"' EXIT
cp -R build/web/. "$staged/"
rm -rf "$staged/canvaskit" "$staged/.last_build_id" "$staged/flutter_service_worker.js"

if [ "$check" = true ]; then
  # flutter_bootstrap.js is the Flutter tool's loader, not built from these sources. Its
  # `_flutter.buildConfig` line carries the engine's revision and wasm hashes, which differ
  # between a local SDK and CI's even at the same FLUTTER_VERSION, so that one line is compared
  # for what the extension relies on rather than byte for byte.
  bootstrap=flutter_bootstrap.js
  if ! diff -r -x "$bootstrap" "$staged" "$dest" > /dev/null 2>&1 ||
    ! diff <(grep -v '^_flutter.buildConfig = ' "$staged/$bootstrap") \
      <(grep -v '^_flutter.buildConfig = ' "$dest/$bootstrap") > /dev/null 2>&1; then
    diff -rq "$staged" "$dest" >&2 || true
    diff -u "$dest/$bootstrap" "$staged/$bootstrap" 2>&1 | head -n 40 >&2 || true
    echo "::error::the committed DevTools extension is not what packages/fespalier_devtools builds to: $rebuild" >&2
    exit 1
  fi
  if ! grep -q '^_flutter.buildConfig = .*"builds":\[{"compileTarget":"dart2js","renderer":"canvaskit","mainJsPath":"main.dart.js"}\]' "$dest/$bootstrap"; then
    echo "::error::$dest/$bootstrap does not load main.dart.js with CanvasKit: $rebuild" >&2
    exit 1
  fi
  if ! cmp -s "$staged/$bootstrap" "$dest/$bootstrap"; then
    echo "::notice::flutter_bootstrap.js differs from the committed one only in its buildConfig line (the Flutter SDK's engine hashes)" >&2
    diff <(grep '^_flutter.buildConfig = ' "$dest/$bootstrap") <(grep '^_flutter.buildConfig = ' "$staged/$bootstrap") >&2 || true
  fi
else
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -R "$staged/." "$dest/"
fi

# `validate` exits 0 even when it fails: what it says is what counts.
if ! out="$(dart run devtools_extensions validate --package="$package" 2>&1)"; then
  echo "$out" >&2
  exit 1
fi
echo "$out"
if ! grep -q '^Extension validation successful$' <<< "$out"; then
  echo "::error::devtools_extensions validate did not accept the extension" >&2
  exit 1
fi
