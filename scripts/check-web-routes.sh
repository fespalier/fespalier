#!/usr/bin/env bash
# Every committed Maestro flow's route opens on the web.
#
# Builds the example for the web (`flutter build web --release --no-web-resources-cdn`, so
# CanvasKit is bundled and nothing is fetched from a CDN) in a throwaway copy, serves it on the
# port the flows' `url:` names, and replays each flow in `<example>/.maestro/routes`:
#
#   default            Playwright (ci/web-routes, pinned by its package-lock.json) opens the flow's
#                      link in Chromium, with every request that is not to this machine blocked,
#                      and waits for the flow's Semantics identifier.
#   --maestro <bin>    Maestro itself: `maestro test --headless .maestro/routes`. Maestro's web
#                      support is beta and follows Chrome, so only the weekly maestro-web workflow
#                      uses it.
#
# The examples stay platform-free: the `web/` folder that `flutter create` adds lives in the copy
# (scripts/web-copy.sh), which is removed on exit.
#
# Usage: scripts/check-web-routes.sh <example-dir> [--maestro <maestro-binary>]
#   scripts/check-web-routes.sh examples/shop
# Needs `npm ci` in ci/web-routes and `npx playwright install chromium` there (`just web-routes`).
# `root`, `example`, `work` and `copy` come from web-copy.sh; `server` is read by its EXIT trap.
# shellcheck disable=SC2154,SC2034
set -euo pipefail

usage() {
  echo "usage: $0 <example-dir> [--maestro <maestro-binary>]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
dir="$1"
shift
maestro=""
if [ "$#" -gt 0 ]; then
  { [ "$#" -eq 2 ] && [ "$1" = "--maestro" ]; } || usage
  maestro="$2"
fi

# shellcheck source=web-copy.sh
source "$(dirname "${BASH_SOURCE[0]}")/web-copy.sh"

if [ -z "$maestro" ] && [ ! -d "$root/ci/web-routes/node_modules" ]; then
  echo "run npm ci in ci/web-routes first" >&2
  exit 2
fi

web_copy "$dir"
flutter build web --release --no-web-resources-cdn

flows=.maestro/routes
first="$(find "$flows" -name '*_route.yaml' | sort | head -n 1)"
if [ -z "$first" ]; then
  echo "FAIL: no flow in $example/$flows; run fsp maestro" >&2
  exit 1
fi
port="$(sed -n 's|^url: "http://localhost:\([0-9][0-9]*\)".*|\1|p' "$first" | head -n 1)"
if [ -z "$port" ]; then
  echo "FAIL: $first has no url: http://localhost:<port> (not a web flow)" >&2
  exit 1
fi

# Dual-stack, so `localhost` works over IPv4 and IPv6 (IPv4 only where the machine has no IPv6).
bind=::
python3 -c 'import socket; socket.socket(socket.AF_INET6).close()' 2>/dev/null || bind=127.0.0.1
python3 -m http.server "$port" --bind "$bind" --directory build/web >"$work/server.log" 2>&1 &
server=$!
ready=0
for _ in $(seq 1 50); do
  if curl -fsS "http://localhost:$port/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: the web build is not served on port $port" >&2
  cat "$work/server.log" >&2
  exit 1
fi

if [ -n "$maestro" ]; then
  MAESTRO_CLI_NO_ANALYTICS=true MAESTRO_DISABLE_UPDATE_CHECK=true \
    MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true \
    "$maestro" test --headless "$flows"
else
  node "$root/ci/web-routes/check.mjs" "$copy/$flows"
fi
