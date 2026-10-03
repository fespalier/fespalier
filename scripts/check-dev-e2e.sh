#!/usr/bin/env bash
# `fsp dev` against the real flutter (`just dev-e2e`): a fresh web app with `fsp init`, run in headless
# Chrome with `fsp dev --no-tui`. It waits for the app to run, adds a route (app.g.dart changes: a
# hot restart), edits a page's body (a hot reload), and quits with `q`. This is the one check of
# fsp against flutter's real `--machine` protocol; every other test speaks it through a fake.
#
# Needs Flutter with web support, Chrome (`CHROME_EXECUTABLE` names one that is not on the path) and
# network for `flutter pub get`. FSP_BIN is the fsp to run (default: cli/target/debug/fsp, built here).
# A browser that has to run as root or in a container gets `--no-sandbox`, which is passed below.
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
dev_pid=""
cleanup() {
  exec 3>&- 2> /dev/null || true
  if [ -n "$dev_pid" ] && kill -0 "$dev_pid" 2> /dev/null; then
    kill "$dev_pid" 2> /dev/null || true
    sleep 2
    kill -9 "$dev_pid" 2> /dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

cd "$work"
flutter create --empty --project-name e2e_app --platforms web e2e_app > /dev/null
cd e2e_app
flutter pub add fespalier --path "$root/packages/fespalier" > /dev/null
"$fsp" init > /dev/null 2>&1
cat > lib/main.dart << 'DART'
import 'package:e2e_app/app.main.g.dart';

Future<void> main() => AppMain.run();
DART

log="$work/dev.log"
keys="$work/keys"
mkfifo "$keys"
# Read and write ends in one process: opening the pipe does not wait for the other side.
exec 3<> "$keys"
timeout 420 "$fsp" dev --no-tui -- -d chrome \
  --web-browser-flag=--headless=new --web-browser-flag=--no-sandbox \
  <&3 > "$log" 2>&1 &
dev_pid=$!

fail() {
  echo "::error::$1" >&2
  echo "--- fsp dev output:" >&2
  cat "$log" >&2 || true
  exit 1
}

# wait_for <text> <seconds>: until fsp dev prints it, while it is still running.
wait_for() {
  local end=$((SECONDS + $2))
  until grep -qF -- "$1" "$log"; do
    kill -0 "$dev_pid" 2> /dev/null || fail "fsp dev ended before it printed: $1"
    [ "$SECONDS" -lt "$end" ] || fail "no '$1' in $2 s"
    sleep 1
  done
}

wait_for '[fsp] app running' 300
wait_for '[fsp] watching lib/app/' 30

# A new route changes lib/app.g.dart: the app is restarted, not reloaded.
mkdir -p lib/app/about
cat > lib/app/about/page.dart << 'DART'
import 'package:flutter/widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('about');
}
DART
wait_for '✓ hot restart in' 120

# A change to a page's body leaves app.g.dart alone: a hot reload.
sed -i.bak "s/'about'/'about us'/" lib/app/about/page.dart
wait_for '✓ hot reload in' 120

echo q >&3
wait "$dev_pid" || fail "fsp dev exited with $? after q"
dev_pid=""
grep -qF 'stopping flutter' "$log" || fail "no 'stopping flutter…' line after q"
echo "fsp dev: the app ran, restarted on a new route, reloaded on an edit, and stopped on q"
