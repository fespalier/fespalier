#!/usr/bin/env bash
# Every Dart dependency of the repository at once, through Melos:
#   dart run melos run deps:outdated   what is newer than the constraints allow
#   dart run melos run deps:upgrade    flutter pub upgrade --major-versions: raises the constraints that keep a
#                                      dependency below its newest major (to ^<newest>), in every pubspec at once
#
# The pub workspace (the root pubspec.yaml) is one resolution, so one run at the root covers all its packages
# and rewrites each pubspec in it that names the dependency. The packages and examples outside it resolve on
# their own: each gets its own run. They are every folder under packages/ and examples/ with a pubspec.yaml
# that the root's `workspace:` does not list.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

case "${1:-}" in
  outdated) args=(outdated) ;;
  upgrade) args=(upgrade --major-versions) ;;
  *)
    echo "usage: scripts/deps.sh outdated|upgrade" >&2
    exit 2
    ;;
esac

members="$(sed -n '/^workspace:/,/^[^ ]/s/^  - //p' pubspec.yaml)"
outside=()
for pubspec in packages/*/pubspec.yaml examples/*/pubspec.yaml; do
  dir="${pubspec%/pubspec.yaml}"
  if ! grep -qx "$dir" <<< "$members"; then
    outside+=("$dir")
  fi
done

# `pub outdated` reads the lockfile, which a folder nobody resolved yet does not have.
pub_run() {
  if [ "${args[0]}" = outdated ]; then
    flutter pub get > /dev/null
  fi
  flutter pub "${args[@]}"
}

echo "==> the workspace: $(wc -l <<< "$members") packages, one resolution"
pub_run
for dir in "${outside[@]}"; do
  echo "==> $dir"
  (cd "$dir" && pub_run)
done

if [ "$1" = upgrade ]; then
  if ! git diff --quiet -- packages/fespalier_devtools/pubspec.lock; then
    echo "packages/fespalier_devtools/pubspec.lock changed: run 'just devtools-build' and commit the build." >&2
  fi
  cat >&2 << 'EOF'
Next:
  cd cli && cargo test --test versions   # one constraint per dependency, fsp create's recipes too (cargo test create_tests::)
  just floor <a Flutter 3.35 SDK>          # a raised lower bound may need a newer Flutter: write a range (go_router's)
  just ci
EOF
fi
