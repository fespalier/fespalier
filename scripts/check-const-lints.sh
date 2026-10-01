#!/usr/bin/env bash
# The generated lib/*.g.dart files of the examples are clean under the const lints.
#
# The generated files carry `// ignore_for_file: type=lint` so they never add warnings to an
# app, which also hides a `const` the generator forgot (a page built without `const` is
# rebuilt on every navigation, with its hook effects). This script copies each generated file
# without that ignore into the example, turns the const lints on, analyzes the copies and
# puts everything back. Run it after `flutter pub get` in each example.
#
# Usage: scripts/check-const-lints.sh <example-dir>...
set -euo pipefail

rules='prefer_const_constructors prefer_const_literals_to_create_immutables prefer_const_declarations prefer_const_constructors_in_immutables'
pattern="${rules// /|}"
status=0

for dir in "$@"; do
  (
    cd "$dir"
    options="$(mktemp)"
    cp analysis_options.yaml "$options"
    copies=()
    # shellcheck disable=SC2329 # invoked by the EXIT trap below
    cleanup() {
      cp "$options" analysis_options.yaml
      rm -f "$options" "${copies[@]}"
    }
    trap cleanup EXIT

    {
      printf '\nlinter:\n  rules:\n'
      for r in $rules; do printf '    - %s\n' "$r"; done
    } >> analysis_options.yaml
    for f in lib/*.g.dart; do
      copy="lib/const_lint_copy_$(basename "$f" .g.dart).dart"
      sed -e 's#ignore_for_file: type=lint, #ignore_for_file: #' -- "$f" > "$copy"
      copies+=("$copy")
    done

    out="$(dart analyze --no-fatal-warnings "${copies[@]}" 2>&1 || true)"
    hits="$(grep -E "$pattern" <<< "$out" || true)"
    if [ -n "$hits" ]; then
      echo "$dir: the generated code is missing a const:" >&2
      echo "$hits" >&2
      exit 1
    fi
    echo "$dir: const lints clean (${#copies[@]} generated file(s))"
  ) || status=1
done
exit "$status"
