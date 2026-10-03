# The `fsp` CLI, its config, and how to run it

As of v0.4.0 (`fsp --version` prints `fsp` and the version, e.g. `fsp 0.4.0`).

## Commands

Every command takes `--project <dir>`; the default is the nearest folder, at or
above the current one, with a `pubspec.yaml` (none: `no pubspec.yaml here or
above; pass --project`).

| Command                                     | What it does                                                                                                                                                                                                                                                                           |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fsp init`                                  | Writes `layout.dart`, `page.dart`, `not_found.dart`, `transition.dart` and, since 0.8.0, `app.dart` (not with `main: manual`) under `lib/app/` (never overwrites: `skip  ... (exists)`), then `gen`, then prints what is left to do (the `main.dart` that runs `AppMain`, since 0.8.0) |
| `fsp gen [--format] [--json]`               | Checks `lib/app/` and writes `lib/app.g.dart`; `--format` pipes it through `dart format`                                                                                                                                                                                               |
| `fsp check [--json]`                        | The same checks, string paths in `lib/` included (since 0.7.0); **writes nothing** and never runs `dart`; non-zero exit on errors. What CI runs                                                                                                                                        |
| `fsp watch`                                 | `gen` once, then again on every relevant change; keep it next to `flutter run`                                                                                                                                                                                                         |
| `fsp routes [--json]`                       | Prints the route table (errors: `N error(s); no route table`)                                                                                                                                                                                                                          |
| `fsp links [--check]`                       | Writes App Links, Universal Links and a sitemap files from the route tree and the `links:` config; `--check` writes nothing and fails when they are stale (since 0.5.0)                                                                                                                |
| `fsp maestro [--check]`                     | Writes one Maestro smoke flow per route (`openLink` to a sample URL, then wait for the page's semantics identifier) from the `maestro:` config; `--check` writes nothing and fails when they are stale (since 0.7.0)                                                                   |
| `fsp telemetry [flags]`       | Starts a local OpenTelemetry stack with fespalier's six dashboards in Docker: a collector, OpenObserve, and Grafana with `--grafana`. Needs no project and no pubspec key; writes `~/.fespalier/telemetry`. Flags: `--grafana`, `--lan`, `--stop`, `--reset`, `--dir`, `--no-start` (since 0.8.0) |
| `fsp size [--build DIR] [--json] [--check]` | Reports the web build's JavaScript per deferred route (own, shared and total bytes, read from dart2js's table in `main.dart.js`); `--check` exits 1 when a budget in the `size:` config is exceeded (since 0.8.0)                                                                      |
| `fsp test [--check]`                        | Writes one widget smoke test per route into `test/routes/routes_test.dart` (`pumpRouter`, wait on the fake clock for the page) from the route tree and the optional `test:` config (since 0.8.0); see below                                                                            |
| `fsp routes --graph [FORMAT]`               | Prints the route tree as a Mermaid `flowchart TD` (`mermaid`, the default), a Graphviz `digraph` (`dot`), since 0.5.0, or JSON (`json`, since 0.7.0)                                                                                                                                   |
| `fsp new <path> [flags]`                    | Scaffolds a route, skips files that exist, then runs `gen`                                                                                                                                                                                                                             |

What they print, to stderr unless noted:

- `gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged`
  (with `output_manifest`, or a generated `main()` since 0.8.0, every file is named:
  `✓ 12 routes → lib/app.g.dart, lib/app.main.g.dart`). On errors:
  `N error(s); lib/app.g.dart left unchanged` and exit code 1 (with several files,
  `N error(s); lib/app.g.dart and lib/app.main.g.dart left unchanged`).
- `check`: `✓ 12 routes, no errors`.
- `gen`, `check` and `watch` also read the **string paths** in `lib/` and warn about one that
  matches no route (since 0.7.0):
  ``warning: no route matches `/nope/x`, so it shows not-found [unknown_path]``, with a code
  frame in the file it is in (`lib/screens/home.dart`,
  not only under `lib/app/`; `--json` gives that path as `file`). A warning never changes the
  exit code or the success line. See `fespalier-routing`, `references/typed-routes-and-extra.md`
  ("String paths"), and `lints:` below.
- `watch`: `watching lib/app/ …`, the `gen` line at startup, then a line (with a
  duration) each time a save changes the output. An edit that changes nothing
  generated (a `build` method) prints nothing.
- `--json` on `gen` and `check` prints each **diagnostic** to stdout as one JSON
  object per line, `{"file","line","column","severity","message"}` (`file` is
  relative to the project root; `line`/`column` count from 1 and are `null` for a
  diagnostic that is not about a place in a file; `severity` is `error` or
  `warning`). Stdout is empty when there is nothing to report.
- `routes` prints `pattern  RouteClass  file  (tags)` per route. The tags are
  `redirect`, `data`, `action` (since 0.5.0), `guard`, `layout`, `present` or `transition`, `root`,
  `sibling` (a [`nest = false`](../../fespalier-routing/references/route-dart.md) route,
  since 0.4.0), `remount` (a page that starts again when its URL changes, since 0.6.0) and `deferred` (a page whose code loads on demand,
  since 0.7.0), in that order; `fresh` (its data has a `freshness`) and `cached` (a `dataCache`), since 0.8.0, follow `data`. `routes --json` prints, per line, in
  this order: `pattern`, `route`, `file`, `tags`, `params` (`{name, type, in}`
  with `in` of `path` or `query`), `folder`, `presentation` (`page`, `redirect`,
  `root`, `custom`), `groups`, `layouts`, `tabs`, `data_keys`, `meta`,
  `catch_all`, then `remount` (`on_segments` or `on_location`, since 0.6.0) **only** for a route
  that remounts, then `deferred` (`true`, since 0.7.0) **only** for a route whose page is deferred, and `paths` **only** for a route with
  localized segments.

### `fsp routes --graph` (since 0.5.0)

```sh
fsp routes --graph               # Mermaid, which GitHub renders in a mermaid code block
fsp routes --graph dot | dot -Tsvg > routes.svg
```

The tree as `app.g.dart` hands it to go_router, not the folders. A node is a route (its
URL pattern, route class, each localized spelling, and the markers `redirect`, `data`,
`action`, `guard`, `present`, `root`, `sibling`); an edge is nesting, so a `nest = false` route hangs
from the page above its parent, not from the page above it; a box is a navigator: the root
navigator, a `layout.dart` shell (marked `data` for a section, `guard`) and each tab
branch. The output is deterministic (no timestamps, a fixed order), so it can be
committed. `--graph` cannot be combined with `--json`, and a value other than `mermaid`,
`dot` or `json` is a usage error that lists the three (`invalid value 'svg' for '--graph [<FORMAT>]'`,
then `[possible values: mermaid, dot, json]`; before 0.7.0 only the first two).

**`--graph json`** (since 0.7.0) prints the same tree as indented JSON with a trailing newline: `protocol`
(1), `package` (the pubspec's `name`, or `null`), `appDir`, `items` and `sites`. An item is a `route`
(`pattern`, `route`, `file`, `folder`, `markers`, `params` as in `routes --json`, `spellings` only for a
localized route, `redirect`, `children`), a `shell` (a `layout.dart`, with its `items`) or `tabs` (with `branches`);
`file` and `folder` are relative to the app folder. `sites` names each guard (`g5@6`), `redirect.dart`
(`r32`), `data.dart` (`d37`, with `traced: false` when the file returns or selects a provider) and action
(`a37_0`) by the string the generated code uses (since 0.8.0 the views name it too: `watchData(ref, 'd37', …)`,
and `app.g.dart` lists the providers by site in `_devToolsProviders`). It is what the DevTools extension reads, and
`app.g.dart` embeds it (see the DevTools page of `fespalier-troubleshooting`).

### `fsp links` (since 0.5.0)

```yaml
# pubspec.yaml
fespalier:
  links:
    domains: [shop.example.com]            # required; the first one is the sitemap's
    scheme: myshop                         # optional custom scheme (needs a platform below)
    android_package: com.example.shop      # with android_sha256: the Android files
    android_sha256: ["AB:CD:...:EF"]       # 32 hex pairs each; the signing certificates
    ios_app_id: ABCDE12345.com.example.shop  # Team ID, a dot, the bundle id: the iOS files
    out: links                             # default; relative to the project, no `..`
```

It writes, below `out` (commit it, like `app.g.dart`): `android/intent-filters.xml` (one
`<intent-filter android:autoVerify="true">` per domain, one more for `scheme`),
`web/.well-known/assetlinks.json` (Android, when `android_package` is set);
`ios/associated-domains.entitlements`, `web/.well-known/apple-app-site-association`
and, with `scheme`, `ios/info-url-types.xml` (iOS, when `ios_app_id` is set); and always
`web/sitemap.xml`.

- **It never edits** `AndroidManifest.xml`, `Runner.entitlements` or `Info.plist`: paste the
  intent filters into the `<activity>` that has the `MAIN`/`LAUNCHER` filter, add the
  `applinks:` lines to `Runner.entitlements`, and copy `web/` into the Flutter project's
  `web/` (or serve it from the domain). Android verifies only an `assetlinks.json` served
  over HTTPS at `/.well-known/assetlinks.json` with no redirect.
- **What is listed.** Every route in a folder not marked `const linkable = false;` (a
  `route.dart`, nearest wins, inherited like `caseSensitive`; see
  [`route-dart.md`](../../fespalier-routing/references/route-dart.md)), one entry per
  localized spelling. `$id` is a wildcard that cannot be empty (Android `/products/..*`,
  iOS `/products/?*`) and also lets longer paths through; a catch-all is a prefix
  (`pathPrefix="/docs/"`, `/docs/?*`; an optional one also the bare path). `linkable = false`
  cannot carve a hole out of a dynamic sibling's wildcard.
- **The sitemap** has only static routes (no `$id`, no catch-all, no redirect), as
  absolute `https://<first domain>/...` URLs, with `hreflang` alternates (and `x-default`,
  the canonical path) from `route.dart` `paths`. Guards are not looked at.
- **`--check`** exits 1 and names each file that is missing, out of date, or not wanted by
  the config any more (`fsp links` deletes those); it is byte-exact because the output has a fixed
  order and no dates. Run it in CI.
- The config values are checked only by `fsp links` (a mistake there never stops `gen`);
  the messages are in `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`.

### `fsp maestro` (since 0.7.0)

Writes one [Maestro](https://docs.maestro.dev) smoke flow per route. Maestro reads the platform's
accessibility tree, never a `Key`, so it **needs `semantics_ids: true`**: every page's own widget
call is then wrapped in `Semantics(identifier: 'route:<pattern>', container: true, child: ...)`
(`route:/`, `route:/products/:id`, `route:/docs/*rest`, `route:/files/*path?`), and a flow waits for it.

```yaml
# pubspec.yaml
fespalier:
  semantics_ids: true                  # required by `fsp maestro`
  maestro:
    app_id: com.example.shop           # Android and iOS: the flow's `appId:`  } exactly one
    url: http://localhost:8080         # the web: the flow's `url:`            } of the two
    link: myshop://shop.example.com    # what a route's path is appended to
    out: .maestro/routes               # default; a folder inside the project, no `..`
    guard_flow: .maestro/sign-in.yaml  # optional: runs before the link of a guarded route
    timeout: 20000                     # default; ms the flow waits for the page, 1000 to 600000
    samples:                           # a dynamic folder's value, inherited by the routes below it
      products/$id: 2
      docs/$$rest: [guides, intro]     # a catch-all: a list of parts (a lone value is one part)
```

- **The identifier** is in the tree **only when the route's own page is built**: not on
  `loading.dart`, `error.dart` or `not_found.dart`, and not on a page underneath the top one. It
  depends only on the folder path, so it is the same for every localized spelling. The wrapper is
  never `const` (`Semantics` has no `const` constructor); a `const` page keeps its own `const`
  inside it. With the key off the generated file is exactly what it was. On the web, `mount()` also
  calls `ensureWebSemantics()` (`package:fespalier`), which turns the semantics tree on **for every
  user of that web build** for good: say so before enabling the key in an app whose web build ships.
- **`app_id`, `url` and `link`** may each be one whole Maestro variable (`app_id: ${APP_ID}`), copied
  through as written. **`link` defaults** to the `url` on the web, and for an app to `<scheme>://<first
domain>` (else `https://<first domain>`) of `links:`; an app with neither is an error. A Flutter web
  app on the default **hash** strategy needs `link: http://localhost:8080/#`.
- **`samples`** keys are folders as `fsp routes` prints them, without `/page.dart` (`products/$id`,
  `(members)/notes/$id`), each a `$x`, `$$x` or `$$$x` folder. Values are text, numbers, booleans
  or (catch-all) lists of them, checked against `int`, `double`, `num`, `bool` and `List<...>` of those;
  `String`, `DateTime` and enums are taken as written. An optional catch-all with no sample is the
  bare path. Samples come from the pubspec only (not `meta.dart`).
- **Which routes get a flow**, first rule that applies: a redirect is skipped (`a redirect, with no
page to see`); with `app_id`, a `const linkable = false;` route is skipped; a route with a `$x` or
  `$$x` segment and no sample is skipped; a route with a `guard.dart` at or above it (a `(group)`
  folder's too) is skipped unless `guard_flow` is set. Each skip is printed on every run, and **no
  skip fails `--check`**.
- **A flow** is `launchApp`, then `runFlow` of `guard_flow` (guarded routes only, path relative to
  the flow), then `openLink` (the `autoVerify: true` form for an Android `https` link), then
  `extendedWaitUntil` the identifier is visible, up to `timeout`. On the web `openLink` reloads the
  app, so a guard flow's sign-in must survive a reload.
- **Files.** `<route class in snake case>.yaml`: `ProductRoute` is `product_route.yaml`, the root
  `home_route.yaml`. Each starts with ``# Written by `fsp maestro` ``; in `out` a `*.yaml` with that
  first line is `fsp`'s, and `fsp maestro` removes it when no route needs it. Any other file in
  `out` (a hand-written flow, `config.yaml`) is never read or touched. The output has no dates, so
  `--check` is byte-exact.
- **`--check`** exits 1 and names each flow that is missing, out of date or no longer a route's.
  It does not check that `lib/app.g.dart` is current (`fsp check`'s job).
- **Running them:** `maestro test .maestro/routes`, **not** `maestro test .maestro` (Maestro runs only the
  top-level flows of the folder it is given, and a `config.yaml` has to list subfolders in `flows:`).
- **Verified here:** the identifier in widget tests (`find.bySemanticsIdentifier`) and the flows as
  golden files; since 0.8.0 also, on the web, that CI opens every committed flow's link in Chromium and
  finds the identifier (`web-routes`; a weekly `maestro-web` job runs Maestro itself and is not a gate).
  **Not verified:** the same on iOS.
- **Not built:** a `link:` identifier on `RouteLink`, `samples` in `meta.dart`, a flow for a layout,
  a not-found view, a query parameter or a localized spelling.
- The config values are checked only by `fsp maestro` (a mistake there never stops `gen`); the
  messages are in `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`. The
  recipe for testing the identifier is in `fespalier-testing`, `references/maestro.md`.

### `fsp size` (since 0.8.0)

Reports the **web build's JavaScript per deferred route**, and checks byte budgets. Run it after
`flutter build web` (`--release`, or any mode: the table it reads is in all of them).

```sh
fsp size                  # main.dart.js and each deferred route, as a table on stdout
fsp size --json           # one JSON object per line: main, each deferred route, then every part
fsp size --check          # exits 1 when a budget in `size:` is exceeded (CI)
fsp size --build out/web  # the build is not in build/web (or `size.build`)
```

```yaml
# pubspec.yaml
fespalier:
  size:
    build: build/web # default; a folder inside the project, no `..`
    main: 3 MB # main.dart.js
    route: 64 KB # each deferred route's total: own + shared
    routes: # by pattern as `fsp routes` prints it; wins over `route`
      /checkout: 8 KB
```

- **How it attributes.** dart2js writes `deferredLibraryParts:{_i7:[0,1],_i14:[0,2]}` and
  `deferredPartUris:["main.dart.js_2.part.js", ...]` into `main.dart.js`. The keys are the import prefixes
  of the generated `app.g.dart` (`deferred as _i7`), so `fsp size` matches them to the routes whose
  `page.dart` has that prefix, and adds up the part files' sizes on disk. The index into
  `deferredPartUris` is **not** the file number. No flag and no `--dump-info` build are needed.
- **Own, shared, total.** **Own** is the parts only this route loads, **shared** the parts other deferred
  routes load too, **total** both (a first visit's download). Routes that are not deferred are in
  `main.dart.js`; only the summary counts them.
- **Output.** stdout: a `main.dart.js` line, a line per deferred route
  (`/checkout  CheckoutRoute  checkout/page.dart  5259 B (5.1 KB)  own 1090 B, shared 4169 B  budget 8.0 KB`, columns padded),
  a `shared  main.dart.js_2.part.js  4169 B (4.1 KB): /checkout, /products/:id` line per shared part, and an
  `other ...` line for a part no route loads. stderr: `✓ size: 6 routes, 2 deferred, 3 parts, within budget`
  (`, within budget` only when a budget is set and met). A budget that is exceeded reads
  `OVER budget 8.0 KB by 3098 B` in the table.
- **Sizes** are a number of bytes, or `3 MB`, `1.5 MB`, `64 KB`, `64KB`, `900 B` (KB is 1,024 bytes; capital
  units; one optional space). A budget under `routes` must be a **deferred** route's pattern.
- **`--check`** needs at least one budget (`main`, `route` or `routes`), prints the report, then fails with
  `N over budget: main.dart.js, /checkout` when any is exceeded. Keep about 30 % headroom on `main`, and
  raise a budget deliberately in the commit that bumps Flutter: a Flutter upgrade moves `main.dart.js` by
  kilobytes.
- **A stale build** is an error when the `_iN` keys in `main.dart.js` are not exactly the prefixes the
  routes defer now, and a **warning** when `lib/app.g.dart` is newer than `main.dart.js`. Run
  `flutter build web` again.
- **Not so:** the sizes are **uncompressed** bytes on disk (a server's gzip makes them several times smaller);
  it reads the JavaScript build (a `--wasm` build also writes `main.dart.js`, which is what is read); a
  deferred import of your own that dart2js gives another load id shows as an `other` part. **Not built:**
  gzip sizes, and a mode that reads `main.dart.js.info.json` (`flutter build web --dump-info`).
- The config values are checked only by `fsp size` (a mistake there never stops `gen`); the messages are in
  `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`. This repository runs it in the
  `web` job (`just web-chunks`) against `examples/shop`'s budgets.

### `fsp test` (since 0.8.0)

Writes one widget smoke test per route, all in **one file**, `test/routes/routes_test.dart` (`flutter test`
compiles each test file on its own, so a file per route would cost minutes). It does not run Flutter:
`flutter test` does. Each test opens the route at a sample URL with `pumpRouter`, pumps the fake clock in
100 ms steps until the route's page is on screen (`smokeTestRoute`, in `package:fespalier/testing.dart`) and
expects exactly one. The page is found by its `route:<pattern>` semantics identifier with
`semantics_ids: true`, else by its class (`find.byType`); a function page needs `semantics_ids`.

```yaml
fespalier:
  test:                            # optional: `fsp test` works with no section at all
    out: test/routes               # default; `test`, `integration_test` or a folder below one
    setup: test/routes/setup.dart  # default: <out>/setup.dart, used when it exists
    timeout: 30000                 # default; ms of the fake clock a test waits for its page, 1000 to 600000
    samples:                       # default: `maestro.samples`; same format and checks
      products/$id: 1
    skip: [/admin]                 # patterns as `fsp routes` prints them
```

- **`setup.dart` is yours**, never written by `fsp`. It may export `List<Override> overrides(String pattern)`
  (called once per test, so fakes are fresh; it can vary by route) and `Widget app(GoRouter router)` (the app
  around the router, default `MaterialApp.router(routerConfig: router)`). `fsp test` only parses it to see
  which exists. Each takes exactly one required positional parameter. `Override` comes from
  `package:fespalier/testing.dart` (since 0.8.0).
- **Samples** are `test.samples`, else `maestro.samples`, else none; nothing else of `maestro:` is read, so a
  `maestro:` section `fsp maestro` refuses does not stop `fsp test`.
- **Skipped, and printed on every run** (never a failure, also in `--check`): a redirect, a route in `skip`,
  a dynamic route with no sample, a route with a `guard.dart` above it when there is no `overrides`, a
  function page without `semantics_ids`. A `linkable = false` route is tested.
- **Ownership.** The first line is ``// Written by `fsp test` ``; a file of that name that does not start with
  it is never overwritten (it is an error). The second line is `// dart format off`, and the file is laid out
  one argument to a line with trailing commas, so `dart format` leaves it alone under every language
  version (the short style, before Dart 3.7, does not read the marker). Never edit it: edit `setup.dart`.
- **`--check`** exits 1 when the file is missing or out of date. CI: `fsp test --check`, then `flutter test`.
- **Not built:** query parameters and localized spellings (each route opens at its canonical path), a file per
  route, running Flutter from `fsp`, and tests of not-found views.
- The config values are checked only by `fsp test` (a mistake there never stops `gen`); the messages are in
  `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`. The setup file, the failure
  message and the pitfalls are in `fespalier-testing`, `references/route-smoke-tests.md`.

### `fsp new`

```sh
fsp new 'products/[id]' --name Product --data --action --loading --error --layout --guard --transition
fsp new '(account)' --layout        # a group: no page.dart
fsp new 'kyc/shop/name' --function --name KycShopName
fsp new 'shop' --not-found
fsp new 'orders' --nav                # nav.dart: how the folder shows in the menus (since 0.8.0)
fsp new 'docs/[...rest]'            # $$rest; 'docs/[[...rest]]' is $$$rest
```

Flags: `--name`, `--function`, `--data`, `--action` (`action.dart`, since 0.5.0),
`--loading`, `--error`, `--layout`, `--not-found`, `--guard`, `--observe` (`observe.dart`, since 0.8.0), `--transition`, `--no-page`. A `(group)` target gets no
`page.dart`, and with nothing left to write it fails with `nothing to create`.
`--name` is the class-name stem (default: from the path, `ProductsId`), and with
`--function` the `routeName` (UpperCamelCase). **Every new segment is a
`String`**; `fsp new 'products/[id]' --data` writes
`data(Ref ref, {required String id})`. Change the type in **each** file that
asks for it, then regenerate. A segment that already has a type elsewhere in the
tree keeps it. There is no `--redirect`, `--present` or `--meta` flag.

After `fsp new '(account)' --layout`, `gen` warns `folder has no page.dart and
no routes below it; skipped` until a route exists inside the group. That is
expected.

### `fsp telemetry` (since 0.8.0)

Starts a local stack that receives fespalier's telemetry and shows it in six dashboards; it needs
Docker with Compose 2.20 or later and a running daemon, and **no project**: run it anywhere. It
writes its files to `~/.fespalier/telemetry` (`--dir`, or `FSP_TELEMETRY_DIR`), runs
`docker compose up -d` there, waits for the one-shot importer that loads the dashboards into
OpenObserve, and prints the addresses. `--grafana` adds Grafana, `--lan` opens the OTLP ports to
phones for one run, `--stop` and `--reset` stop it (keeping or deleting its data), `--no-start` only
writes the files. Settings are in `.env` in that folder (written once, never overwritten). The
dashboards, the app's endpoint (`FespalierOtel.endpoint()`) and the traps are in `fespalier-testing`,
`references/observability.md`; every message is in `fespalier-troubleshooting`,
`references/diagnostics-telemetry.md`.

## Installing `fsp`

| Way                                                                                      | Notes                                                                                                        |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh \| sh` | Linux and macOS. `~/.local/bin`, SHA-256 checked. `FSP_VERSION=v<x.y.z>`, `FSP_INSTALL_DIR`, `FSP_BASE_URL`  |
| `irm https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.ps1 \| iex`      | Windows. `%LOCALAPPDATA%\fespalier\bin`; same three variables, set as `$env:...`                             |
| `cargo install --git https://github.com/vaam-apps/fespalier --tag v<x.y.z> fespalier`    | Any platform with Rust                                                                                       |
| `brew install vaam-apps/tap/fsp`, `scoop bucket add vaam-apps ... && scoop install fsp`  | Only **once the maintainers have set up the tap and bucket** (README, "Releasing"): do not assume they exist |
| `dart run fespalier <command>`                                                           | Installs nothing; see below                                                                                  |

### `dart run fespalier`

Runs the `fsp` release that matches the `fespalier` package your
`pubspec.lock` resolved, so generator and runtime cannot drift.

- **Lookup order.** `FSP_BINARY` (used as is, version not checked; it must
  exist) → the cached binary → an `fsp` on `PATH` **whose version equals the
  package's** → download.
- **Download.** The release archive is checked against the SHA-256 the package
  pins for its own version; a mismatch is `checksum mismatch for <archive>:
expected ..., got ...`. A package built from a branch has no pins and says
  `warning: this package has no pinned checksums for fsp <v> (a development
build); checking the release's own .sha256 instead`.
- **Cache.** `$FSP_CACHE_DIR`, else `$XDG_CACHE_HOME` or `~/.cache/fespalier`
  (Linux), `~/Library/Caches/fespalier` (macOS), `%LOCALAPPDATA%\fespalier`
  (Windows). A warm cache never touches the network. Needs `tar` to unpack.
- **Offline with an empty cache.** `fespalier: fsp <version> isn't cached and the
download failed (offline?); run once online or set FSP_BINARY`.
- Other one-line failures: `no fsp binary is published for <abi>` (build with
  cargo and set `FSP_BINARY`), `<url> answered HTTP 404 (does this release
exist?)`, `cannot locate package:fespalier (run flutter pub get?)`.

## Config: the `fespalier:` section of `pubspec.yaml`

Optional; `fsp` needs none. **Unknown keys are an error**: ``invalid
pubspec.yaml: fespalier: unknown field `nope`, expected one of ...``. These are
the defaults:

```yaml
# pubspec.yaml
fespalier:
  app_dir: lib/app
  output: lib/app.g.dart
  format: false
  case_sensitive: true
  remount: never
  deferred: false           # since 0.7.0
  data_retry: inherit
  keep_previous: true
  push_updates_url: false   # since 0.6.0
  file_style: snake
  meta: optional
  semantics_ids: false      # since 0.7.0
  scroll_restoration: false # since 0.8.0
  telemetry: false          # since 0.8.0
  main: auto                # since 0.8.0; `generated` | `manual`
  # meta_unique: [code]
  # output_manifest: lib/app.routes.g.dart
  # links: {domains: [shop.example.com]}   # see `fsp links` above
  lints: {unknown_path: warning}   # since 0.7.0; `error` | `off`
  # maestro: {url: http://localhost:8080}  # see `fsp maestro` above
  # size: {main: 3 MB, routes: {/checkout: 8 KB}}  # since 0.8.0; see `fsp size` above
  # test: {timeout: 30000}                # since 0.8.0; see `fsp test` above
```

| Key                  | Values                                           | Effect                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app_dir`            | a path under `lib/`                              | Where the tree is. Not under `lib/`: `` `fespalier.app_dir` must be a path under lib/ (it is imported as package code) ``                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `output`             | a `.dart` path under `lib/`                      | Where `app.g.dart` goes: `` `fespalier.output` must be a .dart file ``                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `format`             | `true` / `false`                                 | Run `dart format` on the output (needs `dart` on `PATH`; without it `fsp` warns and writes the unformatted code)                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `case_sensitive`     | `true` / `false`                                 | `false` emits `caseSensitive: false` on every route; a `route.dart` overrides it per folder                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `remount`            | `never` / `on_segments` / `on_location`          | When a page gets a fresh state because its URL changed (since 0.6.0): `on_segments` when a segment's value changes, `on_location` on any change, the query included; a `route.dart` overrides it per folder. See `fespalier-routing`. Another value: `` invalid pubspec.yaml: fespalier.remount: unknown variant `x`, expected one of `never`, `on_segments`, `on_location` ``                                                                                                                                                                                                            |
| `deferred`           | `true` / `false`                                 | Since 0.7.0. `true` makes every page's code load on demand (`import ... deferred as`, a chunk of its own on the web); a `route.dart` with `const deferred = ...;` overrides it per folder. See `fespalier-routing`. Not a bool: `invalid pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13`                                                                                                                                                                                                                                          |
| `data_retry`         | `inherit` / `none`                               | `none` gives generated `data()` providers `retry: (retryCount, error) => null`. See `fespalier-data`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `keep_previous`      | `true` / `false`                                 | `false` shows `loading.dart` on every reload. See `fespalier-data`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `push_updates_url`   | `true` / `false`                                 | Since 0.6.0. `true` puts a `push`ed route's URL in the browser's address bar: `router()` sets `GoRouter.optionURLReflectsImperativeAPIs = true` (`false` otherwise, on every call). See `fespalier-routing`                                                                                                                                                                                                                                                                                                                                                                               |
| `file_style`         | `snake` / `kebab`                                | What `fsp init` and `fsp new` write: `not_found.dart` or `not-found.dart`. Reading accepts both                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `meta`               | `optional` / `required`                          | `required`: a route without `meta.dart` is an error                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `meta_unique`        | list of argument names                           | No two routes may pass the same **literal** for that named argument of `meta`'s constructor call                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `output_manifest`    | a `.dart` path under `lib/`                      | Writes `AppManifest` to a library of its own (it may not equal `output`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `links`              | a map (keys above)                               | What `fsp links` writes; only that command checks the values (since 0.5.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `lints`              | a map: `unknown_path: off` / `warning` / `error` | Since 0.7.0. How a **string path that matches no route** is reported (default `warning`; `off` skips the check). `error` makes `check` exit 1 with ``1 error(s) in string paths (`lints: unknown_path: error`)`` and `gen` and `watch` too, after writing the output (`...; lib/app.g.dart is up to date`). A bad value: ``invalid pubspec.yaml: fespalier.lints.unknown_path: unknown variant `warn`, expected one of `off`, `warning`, `error` ``; a key of its own: ``invalid pubspec.yaml: fespalier.lints: unknown field `nope`, expected `unknown_path` ``. See `fespalier-routing` |
| `semantics_ids`      | `true` / `false`                                 | Since 0.7.0. `true` wraps each page in `Semantics(identifier: 'route:<pattern>')` and makes `mount()` call `ensureWebSemantics()`; `fsp maestro` needs it. See `fsp maestro` above                                                                                                                                                                                                                                                                                                                                                                                                        |
| `telemetry`          | `true` / `false`                                 | Since 0.8.0. `true` makes `app.g.dart` pass a `const TelemetrySite` to each guard, data provider, action and deferred page and follow the router (`telemetryAttach`); nothing is reported until the app installs a sink. A value that is not a bool is an error. See `fespalier-observability`                                                                                                                                                                                                                                                                                            |
| `scroll_restoration` | `true` / `false`                                 | Since 0.8.0. `true` wraps each page's view in `RouteScrollMemory`, a `PageStorage` per history entry that the browser's back and forward hand back: a scrollable under a `PageStorageKey` returns to its offset, a `go` starts at the top. Off, `app.g.dart` is unchanged. See `fespalier-layouts`. Not a bool: `invalid pubspec.yaml: fespalier.scroll_restoration: invalid type: string "sometimes", expected a boolean at line 3 column 23`                                                                                                                                            |
| `maestro`            | a map (keys above)                               | What `fsp maestro` writes flows for; only that command checks the values (since 0.7.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `main`               | `auto` / `generated` / `manual`                  | Since 0.8.0. Whether `fsp` writes `lib/app.main.g.dart` (`AppMain`). `auto` (default): when the app root has an `app.dart`, `startup.dart` or `splash.dart`; `generated`: always; `manual`: never, and those three are not read (one warning each). Another value: ``unknown variant `always`, expected one of `auto`, `generated`, `manual` ``. See [`app-main.md`](app-main.md)                                                                                                                                                                                                         |
| `size`               | a map (keys above)                               | What `fsp size` checks the web build against; only that command checks the values (since 0.8.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `test`               | a map (keys above)                               | What `fsp test` writes a smoke test file for; only that command checks the values (since 0.8.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

There is no key for `extraCodec`: `lib/app/extra_codec.dart` is found by name. Nor for the generated `main()`'s path:
it is `output` with `.main.g.dart` in place of `.g.dart` (`lib/app.main.g.dart`), and `output_manifest` may not be it.

## In CI

Committed-output mode (the default), either with `fsp` installed or without:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
# or, with nothing to install, after `flutter pub get`:
- run: dart run fespalier check
```

Generate-don't-commit mode: add `lib/app.g.dart` to `.gitignore`, and generate
before anything analyses or builds, because the file does not exist until then:

```yaml
- run: flutter pub get
- run: dart run fespalier gen
- run: flutter analyze
- run: flutter test
```

Cache `~/.cache/fespalier` (or `FSP_CACHE_DIR`) keyed on `pubspec.lock` to skip
the download. `fsp check` works in this mode too and does not need the generated
file to exist.

## Platform notes

- **Web.** Flutter web uses hash URLs unless you switch:
  `flutter_web_plugins: {sdk: flutter}` plus `usePathUrlStrategy()` before
  `runApp` (with the generated `main()`: the first line of `startup()`), and a server that serves `index.html` for unknown paths.
- **go_router 18 and `MaterialApp`.** go_router 18 looks for `MaterialApp` from
  `package:material_ui`, not Flutter's, so with Flutter's `MaterialApp` routes
  **without a `transition.dart` do not animate** and its own error screen is
  unstyled. `fsp init` writes a root `transition.dart`
  (`Transitions.material(key, child)`), which fixes it on both 17 and 18. The
  alternatives are `MaterialApp` from `package:material_ui` (it has its own
  `Theme` and localizations: do not mix) or pinning `go_router: ^17.0.0`.
- **Editors.** `editors/vscode/` and `editors/intellij/` show `fsp check --json`
  diagnostics in the editor and offer generate and check commands. Neither is
  on a marketplace as of v0.4.0; build them from source. Both run `fsp` from
  `PATH`, else `dart run fespalier`. Since 0.7.0 both also check again when any Dart
  file under `lib/` is saved (not `*.g.dart`), and show a string-path warning in that file,
  because `fsp check` now reports on files outside the app folder.
- **`flutter create` leftovers.** `flutter create` writes
  `test/widget_test.dart`, which refers to the `MyApp` you replaced, so
  `flutter analyze` fails on it until you delete or rewrite it.

## Speed (as measured by the maintainers)

README "Performance", synthetic apps, release build, 4 cores, warm cache: a **cold `gen`**
is about 56 ms at 500 routes, 156 ms at 2,000 and 429 ms at 5,000 (the 5,000-route app is
7,400 files and a 5.8 MB `app.g.dart`); a cold `gen`/`check` parses on all cores once a run
has about 64 files to parse. `fsp watch` keeps parse results between runs and **skips
resolving and rendering** when a save leaves the scanned tree and the enum files it read
unchanged, so a save that changes nothing generated costs a walk of the folders (77 ms at
5,000 routes). **`dart format` dominates when `format: true`**: 1.4 s at 500 routes, 5 s at
2,000, 13 s at 5,000, because the formatter reads the whole file; `watch` only formats
code it has not formatted before. In a huge app leave `format:` off in `watch` and format
in CI. Re-run the benchmark with `cd cli && cargo test --release bench -- --ignored
--nocapture --test-threads=1`.
