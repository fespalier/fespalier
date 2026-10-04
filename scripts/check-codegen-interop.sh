#!/usr/bin/env bash
# fespalier next to freezed, json_serializable and build_runner (`just codegen-interop`): a fresh app
# with `fsp init`, those three, and the files in ci/codegen-interop/ (a freezed `Note` passed as an
# `extra` and cached with `DataCache.json`, and a `lib/app.dart`). No example uses build_runner, so
# `just ci` cannot notice when it and fsp trip over each other; this is the check that does. It shows:
#
#   1. the clash, as it is: with a `lib/app.dart` and the default output, `fsp gen` warns, and
#      `dart run build_runner build` deletes `lib/app.g.dart` (a notice, not a failure, if a later
#      build_runner stops doing that: then the warning is obsolete, and someone should look);
#   2. the way out: `output: lib/routes.g.dart`. No warning, build_runner builds the models and leaves
#      fsp's files alone (a second `fsp gen` says "unchanged"), `fsp check` passes;
#   3. the app analyses and its tests pass: a freezed class is a private `_Note`, which `ExtraCodec.of`
#      saves and restores (an exact-type `ExtraCodec` would save it as null), and `DataCache.json`
#      saves it.
#
# Needs Flutter and network for `flutter pub get` (the packages are the newest the constraints allow:
# that is the point; the log says which). FSP_BIN is the fsp to run (default: cli/target/debug/fsp,
# built here). KEEP=1 keeps the app (its path is printed). About two minutes.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fsp="${FSP_BIN:-}"
if [ -z "$fsp" ]; then
  (cd "$root/cli" && cargo build --quiet)
  fsp="${CARGO_TARGET_DIR:-$root/cli/target}/debug/fsp"
fi
[ -x "$fsp" ] || {
  echo "::error::no fsp at $fsp" >&2
  exit 1
}

work=$(mktemp -d)
if [ -n "${KEEP:-}" ]; then
  echo "the app is kept in $work/interop_app"
else
  trap 'rm -rf "$work"' EXIT
fi

fail() {
  echo "::error::$1" >&2
  exit 1
}

# quiet <label> <command...>: runs it with its output kept, and shows the output only if it fails.
quiet() {
  local label=$1
  shift
  "$@" > "$work/out.log" 2>&1 || {
    cat "$work/out.log" >&2
    fail "$label failed"
  }
}

cd "$work"
flutter create --empty --project-name interop_app --platforms web interop_app > /dev/null
cd interop_app
quiet "flutter pub add" flutter pub add fespalier --path "$root/packages/fespalier"
quiet "flutter pub add" flutter pub add freezed_annotation json_annotation
quiet "flutter pub add" flutter pub add --dev build_runner freezed json_serializable
for package in build_runner freezed json_serializable; do
  echo "$package $(sed -n "/^  $package:\$/,/version:/s/.*version: \"\(.*\)\"/\1/p" pubspec.lock)"
done
"$fsp" init > /dev/null 2>&1
cp -R "$root/ci/codegen-interop/lib/." lib/

# 1. The clash. `fsp gen` writes lib/app.g.dart and warns, because lib/app.dart exists and
# build_runner is a dependency; build_runner then takes the file as its own and deletes it.
"$fsp" gen 2> "$work/gen.log" || {
  cat "$work/gen.log" >&2
  fail "fsp gen failed"
}
warning="\`build_runner\` can delete \`lib/app.g.dart\`: \`lib/app.dart\` exists"
grep -qF "$warning" "$work/gen.log" || {
  cat "$work/gen.log" >&2
  fail "fsp gen did not warn that build_runner can delete lib/app.g.dart"
}
test -f lib/app.g.dart || fail "fsp gen wrote no lib/app.g.dart"
quiet "dart run build_runner build" dart run build_runner build
if [ -f lib/app.g.dart ]; then
  echo "::notice::build_runner did not delete lib/app.g.dart, though lib/app.dart exists: the fsp warning may be obsolete"
else
  echo "build_runner deleted lib/app.g.dart, as the warning says"
fi
test -f lib/models/note.freezed.dart || fail "build_runner wrote no lib/models/note.freezed.dart"
test -f lib/models/note.g.dart || fail "build_runner wrote no lib/models/note.g.dart"

# 2. The way out: the output in a file of its own. The generated main() follows it, and the files
# written for the old name go.
cat >> pubspec.yaml << 'YAML'

fespalier:
  output: lib/routes.g.dart
YAML
rm -f lib/app.g.dart lib/app.main.g.dart
"$fsp" gen 2> "$work/gen.log" || {
  cat "$work/gen.log" >&2
  fail "fsp gen failed with output: lib/routes.g.dart"
}
if grep -q 'build_runner' "$work/gen.log"; then
  cat "$work/gen.log" >&2
  fail "fsp still warns about build_runner with output: lib/routes.g.dart"
fi
test -f lib/routes.g.dart || fail "fsp gen wrote no lib/routes.g.dart"
test -f lib/routes.main.g.dart || fail "fsp gen wrote no lib/routes.main.g.dart"
quiet "dart run build_runner build" dart run build_runner build
test -f lib/routes.g.dart || fail "build_runner deleted lib/routes.g.dart"
test -f lib/routes.main.g.dart || fail "build_runner deleted lib/routes.main.g.dart"
"$fsp" gen 2> "$work/gen.log"
grep -qF 'unchanged' "$work/gen.log" || {
  cat "$work/gen.log" >&2
  fail "build_runner changed what fsp wrote"
}
"$fsp" check 2> "$work/check.log" || {
  cat "$work/check.log" >&2
  fail "fsp check failed"
}
if grep -q 'warning' "$work/check.log"; then
  cat "$work/check.log" >&2
  fail "fsp check warns with output: lib/routes.g.dart"
fi

# 3. The app, and what it does with the freezed class and json_serializable.
mkdir -p test
cp "$root/ci/codegen-interop/test/interop_test.dart" test/
find lib test -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' -print0 |
  xargs -0 dart format --output=none --set-exit-if-changed
quiet "flutter analyze" flutter analyze
quiet "flutter test" flutter test
echo "codegen interop: fsp warned about the clash, output: lib/routes.g.dart avoids it, and a freezed extra and DataCache.json work next to build_runner"
