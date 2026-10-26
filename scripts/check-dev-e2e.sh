#!/usr/bin/env bash
# `fsp dev` against the real flutter (`just dev-e2e`): a fresh web app with `fsp init`, run in headless
# Chrome with `fsp dev --no-tui`. It waits for the app to run, then adds a route that a hot reload
# swaps in (the home page opens it and keeps its state), adds a route that sorts before a data route
# (a hot reload too, since 0.20.0: the names follow the folders), opens a deferred page after a route was put before it and reloads a second deferred route in beside it while that page is on screen (its code stays loaded, since 0.20.0), changes a data() into a stream (fsp
# dev sees that a reload would keep a provider it changes: a hot restart, and startup() runs again),
# then changes it back behind fsp dev's back (the app refuses the swap and prints so, and fsp dev
# restarts it on that line), changes the app's configuration (config/app.dev.yaml, the profile of a
# debug build: a hot restart brings the new value, since 0.24.0), and quits with `q` (since 0.19.0).
# This is the one check of fsp against
# flutter's real `--machine` protocol; every other test speaks it through a fake.
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
# The app's configuration (since 0.24.0): `dev` is the profile of a debug build.
mkdir -p config
printf 'greeting: e2e greeting one\n' > config/app.yaml
printf 'greeting: e2e greeting dev one\n' > config/app.dev.yaml
# startup() says when it ran and what the configuration holds, the home page says when its state was
# made, and the data route's page shows its id: a hot reload keeps the state, and a hot restart runs
# all of it again.
cat > lib/app/startup.dart << 'DART'
import 'package:e2e_app/app.config.g.dart';
import 'package:flutter/foundation.dart';

void startup() {
  debugPrint('e2e startup');
  debugPrint('e2e config ${AppConfig.profile}: ${AppConfig.greeting}');
}
DART
cat > lib/app/page.dart << 'DART'
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    debugPrint('e2e home init');
  }

  @override
  Widget build(BuildContext context) => const Text('home');
}
DART
mkdir -p "lib/app/items/\$id"
cat > "lib/app/items/\$id/data.dart" << 'DART'
import 'package:fespalier/fespalier.dart';

Future<int> data(Ref ref, {required int id}) async => id;
DART
cat > "lib/app/items/\$id/page.dart" << 'DART'
import 'package:flutter/widgets.dart';

class ItemPage extends StatelessWidget {
  const ItemPage({super.key, required this.data});

  final int data;

  @override
  Widget build(BuildContext context) => Text('item $data');
}
DART
# A deferred page from the start: its import is named after its folder (since 0.20.0).
mkdir -p lib/app/big
cat > lib/app/big/route.dart << 'DART'
const deferred = true;
DART
cat > lib/app/big/page.dart << 'DART'
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class BigPage extends StatelessWidget {
  const BigPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e big built');
    return const Text('big');
  }
}
DART

log="$work/dev.log"
keys="$work/keys"
mkfifo "$keys"
# Read and write ends in one process: opening the pipe does not wait for the other side.
exec 3<> "$keys"
# `--no-web-resources-cdn`: flutter serves CanvasKit and its other web resources from the app itself,
# not from gstatic.com, which a runner with no route to it cannot reach.
timeout 600 "$fsp" dev --no-tui -- -d chrome --no-web-resources-cdn \
  --web-browser-flag=--headless=new --web-browser-flag=--no-sandbox \
  <&3 > "$log" 2>&1 &
dev_pid=$!

fail() {
  echo "::error::$1" >&2
  echo "--- fsp dev output:" >&2
  cat "$log" >&2 || true
  exit 1
}

# count <text>: how many lines of fsp dev's output hold <text>.
count() {
  grep -cF -- "$1" "$log" || true
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

# wait_count <text> <n> <seconds>: until fsp dev has printed <text> at least <n> times.
wait_count() {
  local end=$((SECONDS + $3))
  until [ "$(count "$1")" -ge "$2" ]; do
    kill -0 "$dev_pid" 2> /dev/null || fail "fsp dev ended before it printed '$1' $2 times"
    [ "$SECONDS" -lt "$end" ] || fail "fewer than $2 of '$1' in $3 s"
    sleep 1
  done
}

# expect_count <text> <n>: fsp dev has printed <text> exactly <n> times.
expect_count() {
  local got
  got=$(count "$1")
  [ "$got" -eq "$2" ] || fail "'$1' printed $got times, not $2"
}

wait_for '[fsp] app running' 300
wait_for '[fsp] watching lib/app/' 30
wait_for 'e2e home init' 120
wait_for 'e2e config dev: e2e greeting dev one' 120
expect_count 'e2e startup' 1

# A new route that sorts last changes lib/app.g.dart and adds no name a hot reload keeps: a hot reload.
mkdir -p lib/app/zz
cat > lib/app/zz/page.dart << 'DART'
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class ZzPage extends StatelessWidget {
  const ZzPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e zz built');
    return const Text('zz');
  }
}
DART
wait_for '[fsp] hot reload: lib/app.g.dart changed' 120
wait_count '✓ hot reload in' 1 120

# The home page opens the new route, which the reload brought in. Its state is kept: no init again.
cat > lib/app/page.dart << 'DART'
import 'package:e2e_app/app.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    debugPrint('e2e home init');
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) const ZzRoute().go(context);
    });
    return const Text('home');
  }
}
DART
wait_for 'e2e zz built' 120
wait_count '✓ hot reload in' 2 120
expect_count 'e2e startup' 1
expect_count 'e2e home init' 1
expect_count '✓ hot restart in' 0
expect_count '[fsp] hot restart:' 0

# A route that sorts before items, which has a data() function, renames nothing since 0.20.0: a hot
# reload too.
mkdir -p lib/app/about
cat > lib/app/about/page.dart << 'DART'
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e about built');
    return const Text('about');
  }
}
DART
wait_count '[fsp] hot reload: lib/app.g.dart changed' 2 120
wait_count '✓ hot reload in' 3 120

# The zz page opens the new route: a hot reload again, and no restart.
cat > lib/app/zz/page.dart << 'DART'
import 'package:e2e_app/app.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class ZzPage extends StatelessWidget {
  const ZzPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e zz built');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) const AboutRoute().go(context);
    });
    return const Text('zz');
  }
}
DART
wait_for 'e2e about built' 120
wait_count '✓ hot reload in' 4 120
expect_count 'e2e startup' 1
expect_count '[fsp] hot restart:' 0
expect_count '✓ hot restart in' 0

# big/ was there before a reload put a route before it (about/; zz/ sorts after it): its code loads
# now, through the library the app kept. The about page, which is on screen, opens it: a page edit,
# so one hot reload.
reloads=$(count '✓ hot reload in')
cat > lib/app/about/page.dart << 'DART'
import 'package:e2e_app/app.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e about built');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) const BigRoute().go(context);
    });
    return const Text('about');
  }
}
DART
wait_for 'e2e big built' 120
wait_count '✓ hot reload in' $((reloads + 1)) 120

# A second deferred route, put before big/ while big/ is on screen: one pass, one hot reload, and big/
# keeps its code (since 0.20.0). aaa/ is staged and moved in, so it appears as one new folder.
built=$(count 'e2e big built')
mkdir -p "$work/stage/aaa"
cat > "$work/stage/aaa/route.dart" << 'DART'
const deferred = true;
DART
cat > "$work/stage/aaa/page.dart" << 'DART'
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class AaaPage extends StatelessWidget {
  const AaaPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e aaa built');
    return const Text('aaa');
  }
}
DART
mv "$work/stage/aaa" lib/app/aaa
wait_count '[fsp] hot reload: lib/app.g.dart changed' 3 120
wait_count '✓ hot reload in' $((reloads + 2)) 120
wait_count 'e2e big built' $((built + 1)) 120
expect_count '[fsp] hot restart:' 0

# big/ opens the new route, whose code is loaded on the first visit: one page edit, one hot reload.
cat > lib/app/big/page.dart << 'DART'
import 'package:e2e_app/app.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class BigPage extends StatelessWidget {
  const BigPage({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint('e2e big built');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) const AaaRoute().go(context);
    });
    return const Text('big');
  }
}
DART
wait_for 'e2e aaa built' 120
wait_count '✓ hot reload in' $((reloads + 3)) 120
expect_count 'was not loaded' 0

# A data() that becomes a stream changes a provider a reload keeps: fsp dev sees that, and restarts
# the app, and startup() runs again.
cat > "lib/app/items/\$id/data.dart" << 'DART'
import 'package:fespalier/fespalier.dart';

Stream<int> data(Ref ref, {required int id}) async* {
  yield id;
}
DART
wait_for '[fsp] hot restart: lib/app.g.dart changed' 120
wait_for '✓ hot restart in' 120
wait_count 'e2e startup' 2 120
expect_count '[fsp] hot reload: lib/app.g.dart changed' 3

# The app refuses a swap that fsp dev did not predict. Its pass finds nothing to write, because the
# regenerated file is already on disk: a copy of the app generates it, and it is put in place before
# the data.dart that changes back to a future (fsp watches lib/app/, not the generated file, so the
# save of data.dart is the pass). That makes a save reload, which the app refuses by printing so:
# flutter on the web sends that as a plain line of its output, not as an `app.log` event, and fsp dev
# must restart the app on it.
copy="$work/regenerated"
mkdir -p "$copy"
cp pubspec.yaml "$copy/"
cp -R lib "$copy/lib"
cat > "$copy/lib/app/items/\$id/data.dart" << 'DART'
import 'package:fespalier/fespalier.dart';

Future<int> data(Ref ref, {required int id}) async => id;
DART
(cd "$copy" && "$fsp" gen > /dev/null 2>&1) || fail "fsp gen failed in the copy of the app"
cp "$copy/lib/app.g.dart" lib/app.g.dart
cp "$copy/lib/app/items/\$id/data.dart" "lib/app/items/\$id/data.dart"
wait_for '[fsp] hot restart: the app kept its old routes' 120
wait_count '✓ hot restart in' 2 120
wait_count 'e2e startup' 3 120

# A value of the app's configuration changes: fsp dev writes lib/app.config.g.dart and restarts the
# app, which reads the new value (since 0.24.0).
printf 'greeting: e2e greeting dev two\n' > config/app.dev.yaml
wait_for '[fsp] hot restart: lib/app.config.g.dart changed' 120
wait_count '✓ hot restart in' 3 120
wait_for 'e2e config dev: e2e greeting dev two' 120

echo q >&3
wait "$dev_pid" || fail "fsp dev exited with $? after q"
dev_pid=""
grep -qF 'stopping flutter' "$log" || fail "no 'stopping flutter…' line after q"
# One refusal is one restart, and the stream before it was one too, and nothing else restarted.
expect_count '[fsp] hot restart: the app kept its old routes' 1
expect_count '[fsp] hot restart: lib/app.g.dart changed' 1
expect_count '[fsp] hot restart: lib/app.config.g.dart changed' 1
expect_count '[fsp] hot restart:' 3
expect_count '✓ hot restart in' 3
expect_count '[fsp] hot reload: lib/app.g.dart changed' 3
expect_count 'was not loaded' 0
echo "fsp dev: an inserted route hot reloaded in and opened, a route put before a data route did too, a deferred page opened after a route was put before it, a second deferred route reloaded in beside it while it was on screen, a data() that became a stream restarted the app, an app that refused a swap was restarted on its own line, a changed configuration restarted it with the new value, and q stopped it"
echo "EXCEPTION CAUGHT lines in the log (reported, not asserted): $(count 'EXCEPTION CAUGHT')"
