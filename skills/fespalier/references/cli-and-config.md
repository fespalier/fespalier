# The `fsp` CLI, its config, and how to run it

As of v0.13.0 (`fsp --version` prints `fsp` and the version, e.g. `fsp 0.13.0`).

## Commands

Every command takes `--project <dir>`; the default is the nearest folder, at or
above the current one, with a `pubspec.yaml` (none: `no pubspec.yaml here or
above; pass --project`).

| Command                                                      | What it does                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fsp create <dir> [flags]`                                   | Since 0.15.0: a **new** app (`flutter create --empty`, the pubspec, `lib/main.dart`, `lib/app/`, then `pub get`, `gen` and `fsp test`); takes no `--project`; see the section below                                                                                                                            |
| `fsp add <feature>... [flags]`                               | Since 0.23.0: a feature of `fsp create` into an app that exists (packages pinned as `fespalier` is, keys, files, the shared files composed again), then `pub get`, `dart format` on what it wrote, `gen` and `fsp test`; see the section below                                                                 |
| `fsp init`                                                   | Writes `layout.dart`, `page.dart`, `not_found.dart`, `transition.dart` and, since 0.8.1, `app.dart` (not with `main: manual`) under `lib/app/` (never overwrites: `skip  ... (exists)`), then `gen`, then prints what is left to do (the `main.dart` that runs `AppMain`, since 0.8.1)                         |
| `fsp gen [--format] [--json]`                                | Checks `lib/app/` and writes `lib/app.g.dart`; `--format` pipes it through `dart format`                                                                                                                                                                                                                       |
| `fsp check [--json]`                                         | The same checks, string paths in `lib/` included (since 0.7.0); **writes nothing** and never runs `dart`; non-zero exit on errors. What CI runs                                                                                                                                                                |
| `fsp watch`                                                  | `gen` once, then again on every relevant change; keep it next to `flutter run`, or use `fsp dev`                                                                                                                                                                                                               |
| `fsp dev [-- <args>] [--no-tui] [--dry-run]`                 | `fsp watch` and `flutter run --machine` in one terminal, in a full-screen view: hot reload when `lib/app.g.dart` changed and the app can swap its routes, hot restart when it cannot, hot reload on any other save, the `tasks: dev:` hooks (since 0.9.0); see below                                           |
| `fsp build <target> [-- <args>] [--dry-run]`                 | `fsp gen`, then `flutter build <target>` with the hooks of `tasks: build:` (since 0.9.0)                                                                                                                                                                                                                       |
| `fsp run [task] [-- <args>] [--dry-run] [--json]`            | Runs a task of `tasks:` in pubspec.yaml; with no name, lists them on stdout (since 0.9.0); `--json`: one JSON object per task, for the editor plugins (since 0.22.0)                                                                                                                                           |
| `fsp routes [--json]`                                        | Prints the route table (errors: `N error(s); no route table`)                                                                                                                                                                                                                                                  |
| `fsp links [--check]`                                        | Writes App Links, Universal Links and a sitemap files from the route tree and the `links:` config; `--check` writes nothing and fails when they are stale (since 0.5.0)                                                                                                                                        |
| `fsp maestro [--check]`                                      | Writes one Maestro smoke flow per route (`openLink` to a sample URL, then wait for the page's semantics identifier) from the `maestro:` config; `--check` writes nothing and fails when they are stale (since 0.7.0)                                                                                           |
| `fsp telemetry [flags]`                                      | Starts a local OpenTelemetry stack with fespalier's four dashboards in Docker: a collector, OpenObserve, and Grafana with `--grafana`. Needs no project and no pubspec key; writes `~/.fespalier/telemetry`. Flags: `--grafana`, `--lan`, `--stop`, `--reset`, `--report`, `--dir`, `--no-start` (since 0.8.1) |
| `fsp upgrade [--check] [--dry-run] [--json] [--version TAG]` | Upgrades `fsp` the way it was installed; needs no project (since 0.15.0); see below                                                                                                                                                                                                                            |
| `fsp upgrade --app [flags]`                                  | Since 0.23.0: moves the `ref:` of `fespalier` and every companion in the app's pubspec to one release, then `pub get`, `gen` and the migration notes; see `fsp upgrade` below                                                                                                                                  |
| `fsp doctor [--json]`                                        | Since 0.23.0: what the generated `main()` wires and why, and what is out of line: the fespalier refs against this `fsp`, `pubspec.lock`, `go_router`, Flutter and Dart; one row per check, `ok`, `info`, `warning`, `error` or `skipped`; exit 1 on an error row; see below                                    |
| `fsp schema [--pubspec]`                                     | Since 0.23.0: prints the JSON Schema of the `fespalier:` section, for editors; `--pubspec`: a schema for the whole `pubspec.yaml`; needs no project; see below                                                                                                                                                 |
| `fsp size [--build DIR] [--json] [--check]`                  | Reports the web build's JavaScript per deferred route (own, shared and total bytes, read from dart2js's table in `main.dart.js`); `--check` exits 1 when a budget in the `size:` config is exceeded (since 0.8.1)                                                                                              |
| `fsp test [--check]`                                         | Writes one widget smoke test per route into `test/routes/routes_test.dart` (`pumpRouter`, wait on the fake clock for the page) from the route tree and the optional `test:` config (since 0.8.1); see below                                                                                                    |
| `fsp routes --graph [FORMAT]`                                | Prints the route tree as a Mermaid `flowchart TD` (`mermaid`, the default), a Graphviz `digraph` (`dot`), since 0.5.0, or JSON (`json`, since 0.7.0)                                                                                                                                                           |
| `fsp new <path> [flags]`                                     | Scaffolds a route, skips files that exist, then runs `gen`                                                                                                                                                                                                                                                     |

What they print, to stderr unless noted:

- `gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged`
  (with `output_manifest`, or a generated `main()` since 0.8.1, every file is named:
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
- `gen`, `check`, `watch` and `dev` also warn when **`build_runner` can delete the output** (since 0.17.0): the
  output is `X.g.dart`, an `X.dart` is beside it (a `lib/app.dart` for the default `lib/app.g.dart`) and
  `build_runner` is under `dependencies` or `dev_dependencies`. The warning is on that `.dart` file
  (``warning: lib/app.dart: `build_runner` can delete `lib/app.g.dart`: ...``; `--json` gives `file`
  `lib/app.dart` and `line` `null`), and never changes the exit code. The way out is `output:` in another
  file (`lib/routes.g.dart`) or renaming the `.dart` file; the text is in `fespalier-troubleshooting`,
  `references/diagnostics-config-and-meta.md`.
- `watch`: `watching lib/app/ …`, the `gen` line at startup, then a line (with a
  duration) each time a save changes the output. An edit that changes nothing
  generated (a `build` method) prints nothing.
- `dev` (since 0.9.0): the `gen` line, then the full-screen view, or with `--no-tui`, off a terminal, with
  `TERM=dumb` or in CI, `[flutter]`, `[fsp]` and `[name]` lines (see below). `build`: the `gen` line, then
  flutter's own output. `run`: the task's own output, and with no name the list, on stdout.
- `--json` on `gen` and `check` prints each **diagnostic** to stdout as one JSON
  object per line, `{"file","line","column","severity","message"}` (`file` is
  relative to the project root; `line`/`column` count from 1 and are `null` for a
  diagnostic that is not about a place in a file; `severity` is `error` or
  `warning`). Stdout is empty when there is nothing to report.
- A reader that stops early (`fsp routes --json | head -1`, or `fsp check 2>&1 | head -1`, since
  `gen` and `check` write to stderr) ends the output, not the command (since 0.23.1): nothing more
  is written to the closed pipe, and the exit code is the command's own, so with `set -o pipefail`
  `fsp check --json | head -1` still fails on an error. An older `fsp` panics there, with exit 101
  and `failed printing to stdout: Broken pipe` (or `stderr`).
- `routes` prints `pattern  RouteClass  file  (tags)` per route. The tags are
  `redirect`, `data`, `action` (since 0.5.0), `guard`, `observe` (an `observe.dart` at or above the page, since 0.8.1),
  `leave` (a `leave.dart` in the page's own folder, since 0.11.0), `flow` (a step of a multi-page form, since 0.11.0),
  `layout`, `present` or `transition`, `root`,
  `sibling` (a [`nest = false`](../../fespalier-routing/references/route-dart.md) route,
  since 0.4.0), `remount` (a page that starts again when its URL changes, since 0.6.0) and `deferred` (a page whose code loads on demand,
  since 0.7.0), in that order; `fresh` (its data has a `freshness`) and `cached` (a `dataCache`), since 0.8.1, follow `data`. `routes --json` prints, per line, in
  this order: `pattern`, `route`, `file`, `tags`, `params` (`{name, type, in}`
  with `in` of `path` or `query`), `folder`, `presentation` (`page`, `redirect`,
  `root`, `custom`), `groups`, `layouts`, `tabs`, `data_keys`, `meta`,
  `catch_all`, then, each **only** for a route that has it: `remount` (`on_segments` or `on_location`, since 0.6.0),
  `deferred` (`true`, since 0.7.0), `freshness` (the file whose `Freshness` applies to the route's own `data.dart`, since 0.8.1),
  `cache` (`true` for a `dataCache`, since 0.8.1), `paths` (localized segments) and `nav` (`{file, label, order}` of the
  folder's `nav.dart`, since 0.8.1). `file` and `meta` are relative to the project root.

### `fsp routes --graph` (since 0.5.0)

```sh
fsp routes --graph               # Mermaid, which GitHub renders in a mermaid code block
fsp routes --graph dot | dot -Tsvg > routes.svg
```

The tree as `app.g.dart` hands it to go_router, not the folders. A node is a route (its
URL pattern, route class, each localized spelling, and the markers `redirect`, `data`, `fresh`, `cached`,
`action`, `guard`, `observe`, `leave`, `flow`, `present`, `root`, `sibling`, `deferred`: `fsp routes`' tags, without `layout`,
`transition` and `remount`); an edge is nesting, so a `nest = false` route hangs
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
(`r32`), `data.dart` (`dProductsId`, with `traced: false` when the file returns or selects a provider) and action
(`aNotesId_edit`) by the string the generated code uses (since 0.8.1 the views name it too: `watchData(ref, 'dProductsId', …)`,
and `app.g.dart` lists the providers by site in `_devToolsProviders`). Since 0.20.0 a `data.dart`'s site is `d` and its folder's
stem, and an action's is `a`, its stem, `_` and the function, so they stay when a route is added; guards and `redirect.dart`s keep
`g5@6` and `r32`. Read a site as an opaque key. It is what the DevTools extension reads, and
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
    scheme_host: true                      # since 0.11.0; false: myshop:///orders/2, no host (needs scheme)
    paths: [/, /orders/*]                  # since 0.11.0; default: every linkable route
    android_manifest: android/app/src/main/AndroidManifest.xml  # since 0.11.0; opt in: fsp edits it
    ios_entitlements: ios/Runner/Runner.entitlements            # since 0.11.0; opt in: fsp edits its applinks: entries
    # flavors:                             # since 0.11.0, instead of the keys for one app (android_manifest stays top-level)
    #   prod:  {android_package: ..., android_sha256: [...], ios_app_id: ..., ios_entitlements: ios/Runner/RunnerProd.entitlements}
    #   debug: {android_package: ..., android_sha256: [...], ios_app_id: ..., ios_entitlements: ios/Runner/RunnerDebug.entitlements}
    out: links                             # default; relative to the project, no `..`; `false` (since 0.12.0): no sitemap or .well-known, platform files only, android_sha256 optional
```

It writes, below `out` (commit it, like `app.g.dart`): `android/intent-filters.xml` (one
`<intent-filter android:autoVerify="true">` per domain, one more for `scheme`),
`web/.well-known/assetlinks.json` (Android, when `android_package` is set);
`ios/associated-domains.entitlements`, `web/.well-known/apple-app-site-association`
and, with `scheme`, `ios/info-url-types.xml` (iOS, when `ios_app_id` is set); and always
`web/sitemap.xml`.

- **Platform files (since 0.11.0): opt in, or paste.** Without `android_manifest:` and
  `ios_entitlements:` it edits no file outside `out`, and never `Info.plist`: paste the
  intent filters into the `<activity>` that has the `MAIN`/`LAUNCHER` filter, add the
  `applinks:` lines to `Runner.entitlements`, and copy `web/` into the Flutter project's
  `web/` (or serve it from the domain). Android verifies only an `assetlinks.json` served
  over HTTPS at `/.well-known/assetlinks.json` with no redirect.
- **`android_manifest:` (since 0.11.0)** is the path of an `AndroidManifest.xml` under `android/`
  (needs `android_package`; top level only, also with `flavors:`). The filters go between `<!-- fsp links: begin. ... -->` and
  `<!-- fsp links: end -->` in the one `<activity>` with the `MAIN` action (not an
  `<activity-alias>`, not a comment): the first run inserts the block before its `</activity>`,
  later runs replace only what is between the markers (idempotent, line endings kept). With
  several launcher activities, write `<!-- fsp links: begin -->` and `<!-- fsp links: end -->` on
  two lines of their own in the right one. The file must exist. A filter of yours for a domain
  outside the markers is a warning (not for `tools:node="remove"`). Markers must both sit in one
  `<activity>`, else it is an error; a file that is not UTF-8 is refused; writes are atomic.
- **`ios_entitlements:` (since 0.11.0)** is a `.entitlements` file under `ios/`, flat or per
  flavour (needs `ios_app_id`). `fsp` owns **every** `applinks:` string of
  `com.apple.developer.associated-domains` (one not in `domains:` is removed, with a warning);
  only those items are rewritten, other entries and comments stay byte for byte and ours go
  before `</array>`; no key gets
  one at the end of the top-level `<dict>`; a missing file is written whole, but only when its folder exists (no `ios/Runner/` is an error). A value that is not
  an `<array>`, or a file that is not a plist with a `<dict>`, is an error. It warns when
  `ios/Runner.xcodeproj/project.pbxproj` has no `CODE_SIGN_ENTITLEMENTS` naming the file.
- **Flavours (since 0.11.0).** `flavors:` maps a name (letters, digits, `_`, starting lower-case: `prod`, `devStaging`) to
  `android_package` (with `android_sha256`, unless `out: false`) and/or `ios_app_id`, instead of the flat keys (both
  is an error; the flat keys stay valid as one unnamed app and give the output they always did).
  `assetlinks.json` has one statement per package, the association file one `details` entry with
  every app id in `appIDs`; domains and the scheme are shared (a flavour with `domains:` is
  rejected); `info-url-types.xml` takes the bundle id of the first iOS app.
- **`scheme_host: false` (since 0.11.0)** writes the scheme filter with the scheme only (no
  host, no path) and makes the default `fsp maestro` link `myshop://`, so a flow opens
  `myshop:///orders/42`. Prefer it: the router matches the path only, so `myshop://orders/42`
  reaches `/42`.
- **`paths:` (since 0.11.0)** replaces the route-derived Android `<data>` paths and AASA
  components: `/x` is `android:path="/x"` and `/x`, `/x/*` is `pathPrefix="/x/"` and `/x/*`, `*`
  only as the whole last segment, never `:id` or `$id`. A case-insensitive route an entry
  meets gives it `caseSensitive: false` in the association file. The sitemap still comes from
  the routes, and `fsp maestro` still writes a flow for every route, so one `paths:` leaves out
  can't open with a hosted link. A linkable route no entry covers (the warning suggests `/x`
  for a static route, `/x/*` below a dynamic segment, both for `$$$x`), and an entry no route
  matches, are warnings (never a `--check` failure).
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
  order and no dates. It also follows the platform files it edits (`... has no fsp links markers
yet`, `... the intent filters between the fsp links markers are out of date`, `... the applinks:
entries ... are out of date`, `... is missing`); warnings never fail it. Run it in CI next to
  `fsp check`: `dart run fespalier check && dart run fespalier links --check`.
- **`AppRoutes.urlOf` (since 0.16.0).** `fsp gen` reads one value of the section, the first of `domains`, and writes
  `static Uri urlOf(TypedLocation route, {String? locale})` into `AppRoutes`: `https://<first domain>` and
  `route.locationFor(locale)`, so a share link is built from the typed route, in the spelling of a locale (`fr-CA`
  falls back to `fr`), with the mount prefix in it (unlike the sitemap and the platform files). No `links:`, no
  `urlOf`. Domains `fsp links` would refuse (none, not a host name, a wildcard first) give no `urlOf` and
  ``! pubspec.yaml  `AppRoutes.urlOf` is not generated: ...`` (a warning, exit 0); the rest of the section stays
  `fsp links`' to check. An app that adds `links:` regenerates `app.g.dart` with the method.
- The config values are checked only by `fsp links` (a mistake there never stops `gen`; `gen` reads `domains`
  for `urlOf` and only warns); the messages are in `fespalier-troubleshooting`,
  `references/diagnostics-config-and-meta.md`.

### `fsp maestro` (since 0.7.0)

Writes one [Maestro](https://docs.maestro.dev) smoke flow per route. Maestro reads the platform's
accessibility tree, never a `Key`, so it **needs `semantics_ids: true`**: every page's own widget
call is then wrapped in `Semantics(identifier: 'route:<pattern>', container: true, explicitChildNodes: true, child: ...)`
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
domain>` (`<scheme>://` with `scheme_host: false`; else `https://<first domain>`) of `links:`; an app with neither is an error. A Flutter web
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
  golden files; since 0.8.1 also, on the web, that CI opens every committed flow's link in Chromium and
  finds the identifier (`web-routes`; a weekly `maestro-web` job runs Maestro itself and is not a gate).
  **Not verified:** the same on iOS.
- **Not built:** a `link:` identifier on `RouteLink`, `samples` in `meta.dart`, a flow for a layout,
  a not-found view, a query parameter or a localized spelling.
- The config values are checked only by `fsp maestro` (a mistake there never stops `gen`); the
  messages are in `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`. The
  recipe for testing the identifier is in `fespalier-testing`, `references/maestro.md`.

### `fsp size` (since 0.8.1)

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

- **How it attributes.** dart2js writes `deferredLibraryParts:{_pageCheckout:[0,1],_pageProductsId:[0,2]}` and
  `deferredPartUris:["main.dart.js_2.part.js", ...]` into `main.dart.js`. The keys are the import prefixes
  of the generated `app.g.dart` (`deferred as _pageCheckout`, since 0.20.0; `_i7` before), so `fsp size` matches them to the routes whose
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

### `fsp test` (since 0.8.1)

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
    a11y: true                     # since 0.16.0; default false. Or a list of tap_targets, labels, contrast
```

- **`a11y` (since 0.16.0)** makes every test also check Flutter's accessibility guidelines once its page is on
  screen: `true` is all of them (`guidelines: routeA11yGuidelines` on each `smokeTestRoute`), a list names some
  (`tap_targets` is the 48×48 Android and 44×44 iOS guidelines, `labels` is a semantic label on a tappable
  widget, `contrast` is WCAG text contrast) and the file declares `const _a11y = [...]` for them. The whole screen
  is checked, so a shared app bar with an unlabeled `IconButton` fails every route. See `fespalier-testing`,
  `references/route-smoke-tests.md`.
- **`setup.dart` is yours**, never written by `fsp`. It may export `List<Override> overrides(String pattern)`
  (called once per test, so fakes are fresh; it can vary by route) and `Widget app(GoRouter router)` (the app
  around the router, default `MaterialApp.router(routerConfig: router)`). `fsp test` only parses it to see
  which exists. Each takes exactly one required positional parameter. `Override` comes from
  `package:fespalier/testing.dart` (since 0.8.1).
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
fsp new 'orders' --nav                # nav.dart: how the folder shows in the menus (since 0.8.1)
fsp new 'docs/[...rest]'            # $$rest; 'docs/[[...rest]]' is $$$rest
```

Flags: `--name`, `--function`, `--data`, `--action` (`action.dart`, since 0.5.0),
`--loading`, `--error`, `--layout`, `--not-found`, `--guard`, `--nav` (`nav.dart`, since 0.8.1), `--observe` (`observe.dart`, since 0.8.1), `--leave` (`leave.dart`, since 0.11.0), `--transition`, `--no-page`. A `(group)` target gets no
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

### `fsp create` (since 0.15.0)

```sh
fsp create my_app                                  # the base app
fsp create my_app --org com.example --platforms android,ios,web
fsp create my_app --dry-run --json                 # the plan as JSON lines; nothing is written or run
fsp create my_app --features storage,connectivity  # or --features all (every one your Flutter runs)
fsp create my_app --template tabs                  # the `adaptive` feature: tabs as a bar, rail or drawer
fsp create --list-features [--json]                # the optional features
```

For a **new** app; use `fsp init` for one that exists. `<dir>` must not exist or be empty, `--project` is
refused (`fsp create takes the new app's folder as its argument`), and Flutter 3.35 or newer must be on
`PATH`. It runs `flutter create --no-pub --empty` into a sibling folder `.<dir>.fsp-create-<pid>`, writes
`pubspec.yaml` whole (fespalier by git at the tag of the `fsp` you run, never a version you type),
`lib/main.dart` (`AppMain.run()`) and `lib/app/` (`fsp init`'s five files, a home page with a typed link to
`about/page.dart`), moves the folder into place, then `flutter pub get`, `gen` and `fsp test` in the same
process. `fsp test` needs no `test:` key, so there is no hand-written test.

- **Failure.** Before the move nothing is left behind. After it the app stays, and the message names the
  step (`flutter pub get failed`, `fsp gen failed`) and the commands that finish the job.
- **Flags.** `--project-name` (default: the folder's name, lower case, `-` as `_`), `--org`, `--platforms`
  (`android,ios,linux,macos,web,windows`), `--description`, `--features a,b`, `--no-pub-get`, `--offline`
  (for `pub get`), `--template minimal|tabs` (`tabs` is the `adaptive` feature: either one gives the same app;
  `--template minimal` with `adaptive` is refused, with `all` it leaves `adaptive` out), `--dry-run` (stderr: the commands and every file; it does not run Flutter), `--json`
  (stdout: `run`, `file`, `done`, `error` events as JSON lines, with `content` on a dry run's `file`; text
  and Flutter's own output on stderr).
- **Features.** `--features` takes ids from `--list-features`, or `all` (every feature of the table that the
  installed Flutter runs, with a note for each left out; `all` is not in the `--json` listing). One that another needs is added with a note, two that conflict or one above the
  installed Flutter are refused, an unknown id says what there is. The table is `cli/src/create/recipes.rs`.
  0.15.0 has `storage` (`fespalier_storage`: `startup()` awaits `PrefsDataStorage.open()` into
  `dataCacheStorage`; the test boots `AppMain.root()` over `fakePrefsStore`) and `connectivity`
  (`fespalier_connectivity`: `reconnectSignal.overrideWith(ConnectivitySignal.new)` in `startup()`; the test
  uses `FakeConnectivity`). Each writes a pubspec dependency at the same tag as `fespalier`, its lines in
  `lib/app/startup.dart` and a file in `test/`. Also since 0.15.0: `devtools` (a committed
  `devtools_options.yaml` with `- fespalier: true`, from `docs/devtools.md` "How to see it"; no dependency),
  `adaptive` (`fespalier_adaptive`; takes out the base app's `layout.dart`, `page.dart` and `about/page.dart`
  and writes `lib/app/(tabs)/layout.dart` with `AdaptiveNavScaffold`, a `nav.dart` and page in `(home)` and
  `about`, and a test that resizes the window to see a bar, a rail and a drawer; it is what
  `--template tabs` asks for), `forms` (`fespalier_forms`; `lib/app/contact/` with `form()`, `validate()`,
  an `action()` and a page on `ContactRoute.useForm`; the test uses `isFieldErrors`) and `flags`
  (`fespalier_flags`; `lib/flags.dart`, a `flagGuard` in `lib/app/labs/guard.dart`, `flagSource` from
  `--dart-define=LABS=true` in `startup()`; the test uses `FakeFlags`). The `forms` and `flags` pages have a
  `Scaffold` of their own and are opened by URL. Also since 0.15.0, and since 0.19.0 with no `startup.dart` of its own:
  `otel` (`fespalier_otel` and `otel_zone` by commit, `telemetry: true` and `otel: true`; the generated `main()` starts
  the SDK and adds `FespalierOtel`, inside `runGuarded` on every platform, so a test that builds the app does not start
  it, plus the Riverpod and route observers in `app.main.g.dart`;
  the test reads spans from `dartastic_opentelemetry`'s in-memory exporter; Flutter 3.35 or newer,
  because `otel_zone` needs Dart 3.9: the floor since 0.16.0, so `all` on 3.32 left it out and naming it was refused
  before) and `sentry`
  (`fespalier_sentry` and `sentry_flutter` `>=9.26.0 <10.0.0`, `telemetry: true`; `zone()` is `SentryFlutter.init`
  with `FespalierSentry.configure` and `SENTRY_DSN`, empty meaning off; the test uses `RecordingSentry`). With both,
  the composer keeps Sentry's `zone()`, and `startup()` adds Sentry's sink with `FespalierTelemetry.add`, once (a
  top-level `final _sentry = FespalierSentry();` and `if (!FespalierTelemetry.contains(_sentry)) FespalierTelemetry.add(_sentry);`,
  because Retry runs `startup()` again and `add` appends a sink each time), next to the OpenTelemetry one the generated
  `main()` installs (since 0.19.0; before, one `install` of a `combine`). The generated
  zone is a fallback used only when no other feature has one (docs/observability.md "Wiring
  Sentry" says why). Those shared files (`pubspec.yaml`, `lib/app/startup.dart`,
  `lib/app/app.dart`, `lib/main.dart`) are never written by one feature but composed from all of them
  (`cli/src/create/compose.rs`): imports sorted and deduplicated, startup steps in a fixed order (telemetry
  sinks, then `restoreAuth`, then the rest), `startup()` async only when a step awaits, at most one `zone()` (two
  features that each have one are an error naming both; `weak_zone` is the exception above).
  Also since 0.15.0: `auth` (`fespalier_auth` and `fespalier_forms`; `/account` under a `(signed-in)` folder
  with `requireSignedIn`, `/sign-in` as a form on an action with `redirectIfSignedIn`, `restoreAuth(authSetup())`
  in the Session phase of `startup()` (after the telemetry sink, before the rest); `IdentityBackend` in
  `lib/auth_setup.dart` throws `UnimplementedError('connect your identity provider: docs/auth.md')` from every
  method; the test uses `fakeAuth`. `flutter_secure_storage` needs Android `minSdk` 24 and Flutter's default is 21
  before 3.35 (read in `FlutterExtension.kt` of both SDKs), so with an Android folder `fsp create` rewrites
  `minSdk = flutter.minSdkVersion` in `android/app/build.gradle.kts` to `maxOf(flutter.minSdkVersion, 24)`
  (`cli/src/create/android.rs`; a file without that line is left, with a note)), `i18n` (`fespalier_tolgee`
  and `flutter_localizations`; bundled `assets/i18n/{en,fr}.arb`, no key and no `remote:`; `app.dart` is the
  scope's `TranslationScope.routerConfig` with `localeOf` on the `lang` query; `/translations`, which `fsp test`
  skips through `test: skip:` in the pubspec because it needs the scope; the test switches language) and `image`
  (`fespalier_image`; `lib/images.dart` with a `TemplateUrlBuilder` and no signing key, `imageCdnProvider` in
  `startup()`, `/photo`; the test uses `FakeImages`). A feature can also give the composer a whole
  `app_template`, `assets`, `smoke_skip` and `android_min_sdk`.
  Also since 0.15.0: `http` (`fespalier_http` and `http` ^1.5.0, no Dio; `lib/api.dart` has the `httpClient` provider that closes
  its client and `apiUrl` from `--dart-define=API_URL`; `lib/app/headlines/data.dart` loads through
  `ref.abortable(ref.watch(httpClient))` before its first `await`; the test serves it from `FakeHttpClient` and counts an
  abort when the page is left; `/headlines` is in `test: skip:`; session, retry and `WriteGuardTransport` are the app's, in the
  order of docs/http.md, "The wrapping order") and `download` (`fespalier_download` and `path_provider`, with `platform` and `file`, which nothing imports: they keep the app's lowest dependency versions compiling; `startup()`
  overrides `downloadsEngine` with a `Downloads` over `HttpDownloadBackend`, `FileDownloadStore` and
  `TransferDownloadFiles`, the base folders from `path_provider` in `appBases`; `/downloads` shows `downloadStatus`; the test
  uses `downloadTestOverrides` and `FakeDownloadBackend`; `/downloads` is in `test: skip:`; the background package
  `fespalier_download_background` needs Flutter 3.47 and platform setup, so it is not a feature, and `--local-packages`
  overrides `fespalier_transport` for `download` through `COMPANION_DEPS`).
  Since 0.21.0 `fespalier_transport`, `fespalier_oidc`, `fespalier_keypair`, `fespalier_keypair_dpop` and `fespalier_sign_keypair` have
  no feature either (an identity provider, a key and a protocol are the app's own; `NOT_A_CREATE_FEATURE` in `cli/src/create/recipes.rs` gives each reason).
  The messages are in `fespalier-troubleshooting`, `references/diagnostics-create.md`.

### `fsp telemetry` (since 0.8.1)

Starts a local stack that receives fespalier's telemetry and shows it in four dashboards; it needs
Docker with Compose 2.20 or later and a running daemon, and **no project**: run it anywhere. It
writes its files to `~/.fespalier/telemetry` (`--dir`, or `FSP_TELEMETRY_DIR`), runs
`docker compose up -d` there, waits for the one-shot importer that loads the dashboards into
OpenObserve, and prints the addresses. `--grafana` adds Grafana, `--lan` opens the OTLP ports to
phones for one run, `--stop` and `--reset` stop it (keeping or deleting its data), `--no-start` only
writes the files, and `--report` prints how each app is doing in plain words (the stack must be running). Run from inside an app whose `telemetry` key is off (its default), a start prints
one warning, `⚠ this app sends no fespalier spans yet: ...`, before the summary and exits 0; outside a
project it prints nothing. Settings are in `.env` in that folder (written once, never overwritten). The
dashboards, the app's endpoint (`FespalierOtel.endpoint()`) and the traps are in `fespalier-testing`,
`references/observability.md`; every message is in `fespalier-troubleshooting`,
`references/diagnostics-telemetry.md`.

### `fsp add` (since 0.23.0)

```sh
fsp add storage                 # one feature of `fsp create --list-features`
fsp add http image              # several; one another needs comes with it
fsp add auth --dry-run          # stderr: the pubspec's change and every file; nothing written or run
```

For an app that exists; the features are `fsp create`'s, from the one table (`cli/src/create/recipes.rs`), and the
plan is pure (`cli/src/add/plan.rs`, pinned by `add_tests.rs`). It reads the pubspec and the files the features
write, and takes a feature as **present** when its companions and third-party packages are under `dependencies:`,
its `fespalier:` keys are set and all its files exist (asking for a present one is a note, `nothing to add`).

- **The pubspec** is edited by `cli/src/pubspec_edit.rs`, a line editor that keeps comments, layout, quotes and
  line endings, puts a dependency in name order when its section is (SDK packages aside), and reads the result back
  with `serde_yaml_ng` after each edit: a layout it does not edit stops everything, with the lines to write. Each
  companion is pinned as `fespalier` is (`cli/src/pins.rs`): the same git `url` and `ref`, or a checkout's folder
  plus the `dependency_overrides:` of the companions it reaches and of `fespalier` (as `--local-packages`; since
  0.23.1 in `pubspec_overrides.yaml` when that file has the key, and not one the root of the app's pub workspace
  has already, since pub refuses a package overridden twice). A
  third-party package the app lists keeps its constraint (a note). Then the `fespalier:` keys (a different value
  is set, saying what it was), `test: skip:` routes (those of the features being added: a route the app took out of
  `skip:` stays out; guarded ones only once there is a `test/routes/setup.dart`, and a setup file made now also lists
  those of the features the app had) and `flutter: assets:`; a companion under `dev_dependencies:` only is a note.
  A file that starts with `---`, a `%YAML` line or a comment after a byte order mark is edited like any other.
- **The files.** The feature's own are written when none is there, never over one: some there is a refusal.
  The shared files (`lib/app/startup.dart`, `lib/app/app.dart`, `lib/main.dart`, `test/routes/setup.dart`) and
  the files of present features that depend on the set (`test/storage_test.dart` with `auth`) are composed twice,
  for the present features and with the new ones: a file equal to the first (for Dart, but for white space and
  trailing commas, compared token by token: strings and comments are exact) is replaced by the second; any other is the
  app's, and the difference is printed, `By hand: <file> (...)`, as `+`/`-` lines, before any command runs. Adding every feature one at a time to `fsp create`'s base app gives
  `fsp create --features` with all of them, in any order, with nothing by hand (`add_tests`), and CI's `create`
  job has an `add` case that builds that app with the real flutter.
- **Refused:** no feature, `all`, an unknown one, `adaptive` (it replaces the base app's layout and pages: only
  `fsp create --template tabs`), `main: manual`, an `app_dir:` or `output:` of the app's own, no `fespalier`
  dependency, companions pinned otherwise than `fespalier`, a git `fespalier` pinned at a release other than this
  `fsp`'s when there is something to add (`fsp upgrade --app` first, or `dart run fespalier add` for a pin of 0.23.0
  or later; a branch, a commit and a checkout are let through), `environment: sdk:` below `^3.9.0` (the Dart of
  `fsp create`'s files: wildcards need 3.7), `environment: flutter:` below a feature's floor.
- **Then** the Android `minSdk` of `auth` (as `fsp create`), `flutter pub get` (`--no-pub-get`, `--offline`),
  `dart format` on the Dart files it wrote (the app's language version and page width), `gen`, and `fsp test`
  when `test/routes/routes_test.dart` exists. A failure after the write (each step is named: `fsp test` is not
  `fsp gen`) keeps the files, points at the changes by hand already printed, and lists the commands that finish the
  job; the app then has the feature, so do not run `fsp add` again. Ctrl-C keeps the exit code 130. Messages: `fespalier-troubleshooting`, `references/diagnostics-add.md`.

### `fsp upgrade` (since 0.15.0)

Looks up the latest release (the redirect of GitHub's `releases/latest`, by the system `curl`; no
API, no token), tells how this `fsp` was installed from its canonical path, and acts by that:
Homebrew (`Cellar/fsp/`) runs `brew upgrade fespalier/tap/fsp`; Scoop (`scoop/apps/fsp/` or under
`$SCOOP`) and cargo (`$CARGO_HOME/bin`) print their command; the install script's folder gets the
binary replaced in place (`--version vX.Y.Z` picks the release, a downgrade prints a notice; Homebrew and
Scoop are refused it). The in-place replace downloads `fsp-<target>.tar.gz` (`.zip` on Windows) next to
the binary with `curl`, requires its SHA-256 to equal both the release's `.sha256` and the pin in the
tag's `release_checksums.dart` (pins of the same release; a mismatch or no pins is refused, naming both
values, with nothing changed; `FSP_UPGRADE_ALLOW_UNPINNED=1` is only for a release you staged), unpacks it
with `tar`, runs the new `fsp --version` (must say `fsp Y`), then renames it over the old binary (Windows:
`fsp.exe` to `fsp.exe.old` first, rolled back on failure; any later `fsp` run deletes the `.old`); a folder it cannot write is refused with the
`FSP_INSTALL_DIR` install-script alternative, never `sudo`; on success it prints `✓ fsp X → Y (path)`; the copy `dart run fespalier` keeps in its cache and a `target/debug` build are refused
(the first follows the `ref:` in `pubspec.yaml`: change the `ref` of fespalier and every companion).
`--check` writes nothing and exits **0** up to date, **3** an update is available, **1** error;
`--json` is one object (`current`, `latest`, `target`, `method`, `command`, `upToDate`);
`FSP_RELEASES_URL` and `FSP_BASE_URL` redirect the lookup and the downloads. It needs no project; the
only pubspec it reads is for a closing note, printed after Homebrew's upgrade or an in-place replace
(never for `--check`, `--dry-run`, or the printed Scoop and cargo commands): when `dependencies.fespalier` pins a `ref:` that is a release
tag different from the `fsp` now installed it says to update the refs of fespalier and every companion (same `url` and `ref`) or use
`dart run fespalier` (for a pin newer than the `fsp`, to upgrade `fsp` or use `dart run fespalier`); a path or hosted dependency, a branch or commit ref, or no project prints nothing. Messages: `fespalier-troubleshooting`, `references/diagnostics-dev.md`.
Since 0.23.0 the note says to move them with `fsp upgrade --app`, and the refusal of the `dart run fespalier` copy
names `dart run fespalier upgrade --app --version vX.Y.Z`.

**`--app` (since 0.23.0, `cli/src/upgrade_app.rs`).** Needs the project. Moves every `ref:` of a package of this
repository (`cli/src/pins.rs`: `fespalier` and the companions `cli/src/create/recipes.rs` knows, a feature's or
`NOT_A_CREATE_FEATURE`, and, since 0.23.1, a `fespalier_` git dependency on `packages/<name>` of fespalier's `url`, as a
package newer than this `fsp` is) under `dependencies:`, `dev_dependencies:` and, as a git override of the same repository,
`dependency_overrides:` (and, since 0.23.1, in `pubspec_overrides.yaml`, which pub reads in place of it), to this `fsp`'s
release or `--version`'s; only the ref values change (`pubspec_edit`'s
`Set`, quotes and comments kept, a flow `git: {..., ref: ...}` too). Refused, nothing written: a companion from
another repository, a folder while `fespalier` is git, a ref that is not `vX.Y.Z`. A `path:` `fespalier` has
nothing to move (exit 0); an override to a folder, in the pubspec or `pubspec_overrides.yaml`, is a note, and so,
since 0.23.1, is an override at a commit or a branch of this repository (a hotfix) and a `fespalier` from a fork or a mirror
(whose tag names and notes are this repository's; the official repository over ssh or `http` is not one). When
`pubspec_overrides.yaml` alone has a ref to move, the lines and the failure texts name it, not `pubspec.yaml`. **It never
moves the app back on its own:** without `--version`, a ref newer than this `fsp` is a refusal (exit 1, also for
`--check`; upgrade `fsp` or use `dart run fespalier`), and `--version vX.Y.Z` goes back on purpose, marked
`(a downgrade)`. The migration notes come right after `pubspec.yaml` is written, so a failing `pub get` or `gen`
leaves them above its message: the sections `### X.Y.Z` of `docs/migration.md` after the oldest release pinned up to
the new one, from the copy the binary carries (`include_str!`), each as its first paragraph, its `####` headings and
the lead of each bullet (its bold words, else its first sentence), with a link at the new tag; a release after the
binary's own is a link. Then `flutter pub get` (`--no-pub-get`) and `fsp gen` when the release is this `fsp`'s.
`--check` exits 3 when a ref would move; `--json` is one object (`from`, the oldest release pinned or, when
everything goes back, the newest; `target`, `upToDate`, `packages` with `name`, `section`, `file` (since 0.23.1),
`from`, `to`, `downgrade`, and `notes`; `checkout` for a folder). From a pin before 0.23.0 the first move is a global `fsp` of
0.23.0 or later (an older `fsp`, `dart run fespalier` included, has no `--app`). Messages:
`references/diagnostics-add.md` of `fespalier-troubleshooting`.

### `fsp doctor` (since 0.23.0)

Reports what the generated `main()` wires and why, in the section "What the generated main() wires, and why": `main` (skipped when the
app folder cannot be read as a tree), `root_file`, `hot_reload`, `adapter` (per adapter on, whether a Dart file under `lib/` calls its
`configure(`; per first-party adapter package under `dependencies:` that is off: `info` when no Dart file calls its `configure(`, a
package of the family is often a dependency for something else, and a warning when one does and `adapters:` leaves the package out),
`telemetry`, `otel`, `forms`, `deferred` and `tasks`. Then "Versions": `fespalier` (its `ref:`
against this `fsp`; since 0.23.1 also a warning when a git dependency on `https://github.com/fespalier/fespalier` has no `path: packages/fespalier`
or another folder: a mirror's, a fork's or a vendored copy's `path:` is not compared, and `./packages/x` or a final `/` is `packages/x`),
`companion` (per package of fespalier's repository: the same `url` and `ref`, and the same warning for its folder; since 0.23.1 a package is
one when `fsp` knows it, or when it is a `fespalier_` git dependency on `packages/<name>` of fespalier's `url`, never a `fespalier_` name alone
or its place alone, so a fork's own `acme_ui` gets no row), `override`, `lock` (what `pubspec.lock`
resolved, skipped without it; a pub workspace member's is the workspace root's), `go_router` (against `>=17.2.3 <19.0.0`), `flutter` and
`dart` (against 3.35.0 and 3.9.0, a pre-release of the floor counting as below it, a Flutter that reports `0.0.0` being an error of
its own; `flutter` per dependency that needs a newer one). Then "Checks": `config` (a `pubspec.yaml` that `config.rs` refuses: one error row, and the
wiring rows and the other checks are left out, the versions still show), `section` (per `links:`, `maestro:`, `size:` and `test:`,
as their own command checks them), `build_runner` (the warning `fsp check` prints for a generated file `build_runner` would delete),
`main_dart` (whether `lib/main.dart`, or a Dart file under `lib/` it hands over to, calls `AppMain.run()`), and `fsp_check` (one line
counting the routes, errors and warnings of `fsp check`, which it does not repeat; the `forms` error and the `build_runner` warning,
which have a row of their own, are left out of its count, so a problem is counted once).

Marks: `✓` ok, `·` info, `!` warning, `✗` error, `-` skipped (not checked, and why). Exit **0** when no row is an error (warnings and
skipped rows included), **1** when one is (the report is the whole output), **2** a usage error. `--json` prints one object per
row, every key always there and in this order: `{"section":"wiring|versions|checks","check":"...","subject":null|"...","status":"ok|info|warning|error|skipped","message":"..."}`.
It reads `pubspec.yaml`, `pubspec.lock` (a workspace member's is the root's), the Dart files under `lib/` but the ones `fsp` writes
(`*.g.dart`, `output:`, `output_manifest:`; by their text, for `AppMain.run(`, `AppAdapters.` and `configure(`), whatever `fsp check`
reads (the `path:` dependencies' files, `pubspec_overrides.yaml`, the workspace root's pubspec), and `flutter --version --machine` from
PATH (with FVM or puro, through their `exec`). `fsp` itself never reads the pub cache or `.dart_tool/`, never reaches the network and
writes nothing; the `flutter` it runs may do either (its analytics, the download of its Dart SDK on a fresh clone, its own cache). It
never fails because `flutter` is missing (that row is skipped). The messages and what to do with each: `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`.

### `fsp schema` (since 0.23.0)

`fsp schema` prints the JSON Schema (draft-07) of the `fespalier:` section, for an editor: completion of its keys and values, a
description on hover, and an error on a key `fsp` does not read or a value it refuses. `fsp schema --pubspec` prints a schema for
the whole `pubspec.yaml`: the JSON Schema Store's pubspec schema, through its URL, with the section added. That is the form the
VS Code and IntelliJ plugins ship, because an editor applies one schema to a file. It needs no project, and the schema is this
`fsp`'s own (`dart run fespalier schema` is the pin's). The file at a tag: `https://raw.githubusercontent.com/fespalier/fespalier/vX.Y.Z/cli/schema/fespalier.schema.json`.
The editor setup is in `docs/configuration.md`, "Completion and checks in your editor".

### `fsp dev`, `fsp build` and `fsp run` (since 0.9.0)

`fsp dev` generates, runs the `before` steps of `tasks: dev:`, starts the `with` commands and
`flutter run --machine` (flutter's daemon protocol on stdin and stdout, so there are no signals and no pty,
and it works the same on Windows), and keeps `lib/app.g.dart` current while it runs. It needs no
configuration; everything after `--` goes to `flutter run` (`fsp dev -- -d chrome --flavor dev`).

**`--profile` and the app's configuration (since 0.24.0).** `fsp dev --profile <name>` and `fsp build <target> --profile <name>`
pass `--dart-define=FSP_PROFILE=<name>` to flutter, in front of the arguments after `--`, and print the line
`profile <name> (FSP_PROFILE): config/app.<name>.yaml over config/app.yaml` (the reason is `(the flavour)` or `(a debug build)`
when that picks it). A profile that `config/` does not have, `--profile release`, or a define of your own after `--` as well is
refused before anything runs. The commands of `tasks:` (`before`, `with`, `run`, `after`) get `FSP_PROFILE` and one
`FSP_CONFIG_<PATH>` per value. A save of a file of `config/` hot restarts the app, and `fsp run <task>` sets neither. Details:
[`app-config.md`](app-config.md).

**A hot reload after a regeneration (since 0.19.0).** In a debug build a hot reload swaps in the regenerated route table when the
generated file's version changed and no name it keeps (a provider, a deferred library, a router setting) changed; a refused swap
prints a message and keeps the old routes until `R`. Since 0.20.0 a route added, removed or renamed anywhere swaps, and so does a deferred route added or removed beside another (`AppRoutes.deferred` is a getter a reload lists again): the names a reload keeps follow the folders, not the order of `fsp routes`, so a route put before one with a `data()` function, an action or a deferred page renames nothing (in the shop example `zz/page.dart` and `about/page.dart` both swap). Still refused: a changed `data()` or action, a moved folder that has a `data.dart` or an `action.dart` (also the second of two folders whose names share a stem, added or removed, when a renamed name is a `data.dart`'s provider or an action: it renames the first one's names once, or back; two deferred pages alone swap, and a page of the renamed library on screen loads again through its loading view), an `import ... as m` pointed at another library (an action's input, a data route's enum segment), and a router setting; a restart (`R`) brings those in. Only the generated
`main()` swaps (`StartupGate`): `main: manual` apps, even with `AppRoutes.router()`, keep their routes. `fsp dev` uses it (next paragraph). Profile and release builds never
swap. See
[the CLI reference](https://github.com/fespalier/fespalier/blob/main/docs/cli.md#a-hot-reload-after-a-regeneration).

**The rule an agent needs: a save reloads; a regeneration reloads when the app can swap its routes, and restarts
otherwise.** A hot reload swaps the route table only when the generated main was written and not rewritten, the app's
`router()` is the generated one, and the file's `_version` and `_kept` (read back from `lib/app.g.dart`) swap in: no name
both keep has another hash (`Stamp::swaps_to`, the rule of `RoutesReload`). A pass of the generator that **wrote** an
output sends `app.restart` with `fullRestart: false` when it can swap, and with `fullRestart: true` otherwise: when
`lib/app.main.g.dart` was rewritten, when the routes do not swap in, when the file has no stamp, before `app.start`, with
no baseline (also after a save found a `router()` of your own), when the last hot result failed, when a reload still in flight
does not swap to the new routes either, or when a restart is under way. A reload that a regeneration asked for and
that flutter refuses is followed by one restart; the app printing its refusal of a swap is answered with one too (heard as an
`app.log` event or, where flutter prints the app's output as plain lines, on the web, as one, and only after a reload went out
since the last restart). The
lines are `hot reload: lib/app.g.dart changed`, `hot restart: lib/app.g.dart changed`, `hot restart: lib/app.g.dart changed
and the hot reload failed` and `hot restart: the app kept its old routes`. Any other save under `lib/` sends a hot reload;
a pass with errors sends nothing, and `app.g.dart` is left as it was. `r` and `R` do it by hand; `hot_reload: false` turns
the automatic ones off. Requests are coalesced: a restart in flight covers a reload.

```yaml
# pubspec.yaml
fespalier:
  tasks: # since 0.9.0; read only by `fsp dev`, `fsp build` and `fsp run`
    dev:
      before: dart run build_runner build # one command, or a list; in order; the first that fails stops
      with: # long-running, next to flutter; each gets a pane named by its key
        build_runner: dart run build_runner watch
      run: fvm flutter run # default `flutter run`; fsp adds --machine, -d <device> and the args after --
      env: # for every command of this task, not for the app (that is --dart-define)
        API_URL: http://localhost:8080
      hot_reload: true # default; false: no automatic reload or restart (r and R still work)
      after: [] # runs when `run` exits 0
    build: # `fsp build <target>`: fsp gen, then `<run> <target> <args>`
      before: [dart run build_runner build]
    codegen: dart run build_runner build # a task that is only `run`; `fsp run codegen`
    check: # `fsp run check`
      before: [fsp check, fsp test --check]
      run: [flutter, test] # a list is argv: no shell, the same on every OS
```

- **A command** is a string, which the shell runs (`sh -c`; `cmd /d /s /c` on Windows), or a list of words,
  which runs with no shell. `before` and `after` take a command or a **list of commands**, so
  `before: [dart, run, x]` is **three** shell commands; one argv command in a list is `[[dart, run, x]]`.
  A leading `fsp` is the very `fsp` that runs the task (it works under `dart run fespalier dev`).
- **Defaults and additions.** `dev.run` is `[flutter, run]`, `build.run` is `[flutter, build]`. `fsp dev` adds
  `--machine` (unless given), `-d <id>` when it chose the device, then the args after `--`; `fsp build` adds
  the target and the args; a task of your own gets the args. To a shell string they are appended as quoted words.
  A custom `run` (`fvm flutter run`, a script) gets `--machine` and the args but **no device**: put `-d`
  in it or after `--`, and make a script pass `"$@"` on.
- **Every command** runs in the project root with the task's `env` and `FSP=<path of this fsp>`; `fsp build` also
  sets `FSP_BUILD_TARGET`. A task other than `dev` and `build` needs a `run`; `hot_reload` is `dev` only; a
  `with` name is `[A-Za-z0-9_-]{1,20}`, not `flutter` or `fsp`.
- **`build_runner` and `lib/app.dart`.** `build_runner` needs no `-d`: it has ignored the flag since 2.7.0 and always
  deletes conflicting outputs, which is why the examples do not pass it. It is also why a `lib/app.g.dart` that a
  builder claims (json_serializable, riverpod_generator and the other `.g.dart` writers claim an `X.g.dart` for every
  `X.dart`, so a `lib/app.dart` claims it) is deleted, with nothing logged: in `before`, in `with` (a `watch` does
  it again on every save) and in `fsp run codegen` alike. `fsp` warns (above). **Set `output: lib/routes.g.dart` (or
  rename `lib/app.dart`) before you write a `build_runner` task**; `fsp init`'s commented example says so.
- **Checked by the commands that read it.** `Config.tasks` is the raw value, so a mistake in `tasks:` never fails
  `fsp gen`, `check` or `watch`; `fsp dev`, `build` and `run` report it with the key (the 17 messages are in
  `fespalier-troubleshooting`, `references/diagnostics-dev.md`). `--dry-run` prints the plan and runs nothing.
- **The device.** With no `-d` after `--` and the default `run`, `fsp dev` asks `flutter devices --machine` (while
  the `before` steps run) and picks the one device, or the one phone or emulator among desktop and web ones, as
  `flutter run` does; with several it asks (a picker; `pick a device [1-3]:` in plain mode; the last choice is
  remembered in `.dart_tool/fespalier/dev.json`) and with no terminal says
  ``more than one device: pick one with `fsp dev -- -d <id>` (ids: macos, chrome)``.
- **The view.** A header (app, state, device, VM service or web URL, DevTools), a tab per process (`flutter`, `fsp`,
  each `with`, `telemetry` after `t`) with marks for new lines (`•`), new errors (`!`) and an ended process
  (`✗`, `■`), the selected log, a status line (route count, the last generation, the first routing error with
  its location as a link, the last hot restart or reload) and the keys: `r` `R` `d` `o` `t`, `Tab` and `1`-`9`,
  `/` filter, `c` clear, `?` help, `q` or Ctrl-C quit (a second kills everything). When flutter stops by itself the
  view stays open (`✗ stopped (exit N)`): `R` or Enter runs it again.
- **Plain mode** (`--no-tui`, stdout or stdin not a terminal, `TERM=dumb`, or `CI` set): each line is `[flutter] ...`,
  `[fsp] ...` or `[name] ...`, and the keys are lines on stdin (`r`, `R`, `q`, `d`, `o`, then Enter). An end of
  input does not quit. There is no JSON event stream.
- **Quitting.** `app.stop` goes to flutter (SIGTERM after 10 s, SIGKILL 5 s later), then each `with` group gets
  SIGTERM (SIGKILL after 5 s; `taskkill /T /F` on Windows); the `after` steps run unless flutter failed by itself.
  Exit codes: 0 after `q`, 130 after a signal or a second `q`, flutter's own code when it ended with a failure, a
  failed step's code.

`fsp build <target>` is `fsp gen` and then `before`, `flutter build <target> <args>` and `after` (`after` only when
the build exits 0), with fsp's own stdio. `fsp run <task>` does the same for a task of your own; `fsp run dev` and
`fsp run build` are refused, with a hint. `with` commands of both are started next to `run`, with their output
prefixed, and stopped when it ends. `fsp telemetry` starts its stack and returns, so it goes in `before`, not `with`.

**`fsp run --json` (since 0.22.0).** With no task name it prints one JSON object per task on stdout, for the editor plugins: `name` (the key in `tasks:`), `args` (what to give `fsp`: `["dev"]`, `["build"]` or `["run", "<name>"]`), `needs_target` (`true` for `build`, whose target goes after `args`), `run` (the task's main command as `fsp run` lists it: its `run`, else `flutter run` for `dev` and `flutter build` for `build`, else empty) and `declared` (whether pubspec.yaml has the task). Every key is always present and keys are only added. The order is `dev`, `build`, then `tasks:`. It exits 0 when it lists them (also with no `tasks:`), 1 on a mistake in `tasks:` or pubspec.yaml (stdout empty, the message on stderr), and 2 when `--json` comes with a task name, `--dry-run` or arguments after `--`. An `fsp` older than 0.22.0 has no `--json` (exit 2, `unexpected argument '--json' found`), and the editor plugins say so. The Run Task list, the run console and Stop are **UNCHECKED on a device** (`docs/cli.md`, "Tasks in your editor").

## Installing `fsp`

| Way                                                                                         | Notes                                                                                                                                              |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh \| sh`    | Linux and macOS. `~/.local/bin`, SHA-256 checked. `FSP_VERSION=v<x.y.z>`, `FSP_INSTALL_DIR`, `FSP_BASE_URL`                                        |
| `irm https://raw.githubusercontent.com/fespalier/fespalier/main/install.ps1 \| iex`         | Windows. `%LOCALAPPDATA%\fespalier\bin`; same three variables, set as `$env:...`                                                                   |
| `cargo install --git https://github.com/fespalier/fespalier --tag v<x.y.z> fespalier`       | Any platform with Rust                                                                                                                             |
| `scoop bucket add fespalier https://github.com/fespalier/scoop-bucket && scoop install fsp` | Windows. The latest release, once it has pushed to the bucket (docs/releasing.md, "Releasing")                                                     |
| `scoop install https://github.com/fespalier/fespalier/releases/latest/download/fsp.json`    | Windows, from the release's own manifest: no bucket needed                                                                                         |
| `brew tap fespalier/tap && brew install fsp` (or `brew install fespalier/tap/fsp`)          | macOS and Linux. The latest release, once it has pushed to the tap. `brew install ./fsp.rb` or a URL is refused: use the install script until then |
| `dart run fespalier <command>`                                                              | Installs nothing; see below                                                                                                                        |

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
  scroll_restoration: false # since 0.8.1
  telemetry: false          # since 0.8.1
  otel: false               # since 0.19.0; `true` needs telemetry, fespalier_otel and otel_zone under dependencies, and not `main: manual`
  main: auto                # since 0.8.1; `generated` | `manual`
  # meta_unique: [code]
  # output_manifest: lib/app.routes.g.dart
  # links: {domains: [shop.example.com]}   # see `fsp links` above
  lints: {unknown_path: warning}   # since 0.7.0; `error` | `off`
  # maestro: {url: http://localhost:8080}  # see `fsp maestro` above
  # size: {main: 3 MB, routes: {/checkout: 8 KB}}  # since 0.8.1; see `fsp size` above
  # test: {timeout: 30000}                # since 0.8.1; see `fsp test` above
  # tasks: {codegen: dart run build_runner build}   # since 0.9.0; see `fsp dev` below
  # adapters: [my_tools]   # since 0.9.0; packages that plug into the generated main(), see app-main.md
  # adapters: auto          # since 0.23.0: every first-party adapter package under dependencies:
```

| Key                  | Values                                           | Effect                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app_dir`            | a path under `lib/`                              | Where the tree is. Not under `lib/`: `` `fespalier.app_dir` must be a path under lib/ (it is imported as package code) ``                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `output`             | a `.dart` path under `lib/`                      | Where `app.g.dart` goes: `` `fespalier.output` must be a .dart file `` A `.g.dart` with an `X.dart` beside it is a file `build_runner` can delete: `gen`, `check` and `watch` warn since 0.17.0 (see `fsp gen` above); `lib/routes.g.dart` is the way out                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `format`             | `true` / `false`                                 | Run `dart format` on the output (needs `dart` on `PATH`; without it `fsp` warns and writes the unformatted code)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `case_sensitive`     | `true` / `false`                                 | `false` emits `caseSensitive: false` on every route; a `route.dart` overrides it per folder                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `remount`            | `never` / `on_segments` / `on_location`          | When a page gets a fresh state because its URL changed (since 0.6.0): `on_segments` when a segment's value changes, `on_location` on any change, the query included; a `route.dart` overrides it per folder. See `fespalier-routing`. Another value: `` invalid pubspec.yaml: fespalier.remount: unknown variant `x`, expected one of `never`, `on_segments`, `on_location` ``                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `deferred`           | `true` / `false`                                 | Since 0.7.0. `true` makes every page's code load on demand (`import ... deferred as`, a chunk of its own on the web); a `route.dart` with `const deferred = ...;` overrides it per folder. See `fespalier-routing`. Not a bool: `invalid pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `data_retry`         | `inherit` / `none`                               | `none` gives generated `data()` providers `retry: (retryCount, error) => null`. See `fespalier-data`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `keep_previous`      | `true` / `false`                                 | `false` shows `loading.dart` on every reload. See `fespalier-data`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `push_updates_url`   | `true` / `false`                                 | Since 0.6.0. `true` puts a `push`ed route's URL in the browser's address bar: `router()` sets `GoRouter.optionURLReflectsImperativeAPIs = true` (`false` otherwise, on every call). See `fespalier-routing`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `file_style`         | `snake` / `kebab`                                | What `fsp init` and `fsp new` write: `not_found.dart` or `not-found.dart`. Reading accepts both                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `meta`               | `optional` / `required`                          | `required`: a route without `meta.dart` is an error                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `meta_unique`        | list of argument names                           | No two routes may pass the same **literal** for that named argument of `meta`'s constructor call                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `output_manifest`    | a `.dart` path under `lib/`                      | Writes `AppManifest` to a library of its own (it may not equal `output`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `links`              | a map (keys above)                               | What `fsp links` writes; only that command checks the values, though `fsp gen` reads the first of `domains` for `AppRoutes.urlOf` (since 0.5.0; `urlOf` since 0.16.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `lints`              | a map: `unknown_path: off` / `warning` / `error` | Since 0.7.0. How a **string path that matches no route** is reported (default `warning`; `off` skips the check). `error` makes `check` exit 1 with ``1 error(s) in string paths (`lints: unknown_path: error`)`` and `gen` and `watch` too, after writing the output (`...; lib/app.g.dart is up to date`). A bad value: ``invalid pubspec.yaml: fespalier.lints.unknown_path: unknown variant `warn`, expected one of `off`, `warning`, `error` ``; a key of its own: ``invalid pubspec.yaml: fespalier.lints: unknown field `nope`, expected `unknown_path` ``. See `fespalier-routing`                                                                                                                                                                                                                                                      |
| `semantics_ids`      | `true` / `false`                                 | Since 0.7.0. `true` wraps each page in `Semantics(identifier: 'route:<pattern>')` and makes `mount()` call `ensureWebSemantics()`; `fsp maestro` needs it. See `fsp maestro` above                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `otel`               | `true` / `false`                                 | Since 0.19.0. `true` has the generated `main()` start otel_zone (`AppMain.observability`, the version from `FLUTTER_BUILD_NAME`) and add `FespalierOtel` as a sink, with the Riverpod and route observers, so `startup.dart` writes none of it. Needs `telemetry: true`, `fespalier_otel` and `otel_zone` under `dependencies:`, and not `main: manual`; see `fespalier-observability`                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `telemetry`          | `true` / `false`                                 | Since 0.8.1. `true` makes `app.g.dart` pass a `const TelemetrySite` to each guard, data provider, action and deferred page and follow the router (`telemetryAttach`); nothing is reported until the app installs a sink. A value that is not a bool is an error. See `fespalier-observability`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `scroll_restoration` | `true` / `false`                                 | Since 0.8.1. `true` wraps each page's view in `RouteScrollMemory`, a `PageStorage` per history entry that the browser's back and forward hand back: a scrollable under a `PageStorageKey` returns to its offset, a `go` starts at the top. Off, `app.g.dart` is unchanged. See `fespalier-layouts`. Not a bool: `invalid pubspec.yaml: fespalier.scroll_restoration: invalid type: string "sometimes", expected a boolean at line 3 column 23`                                                                                                                                                                                                                                                                                                                                                                                                 |
| `maestro`            | a map (keys above)                               | What `fsp maestro` writes flows for; only that command checks the values (since 0.7.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `main`               | `auto` / `generated` / `manual`                  | Since 0.8.1. Whether `fsp` writes `lib/app.main.g.dart` (`AppMain`). `auto` (default): when the app root has an `app.dart`, `startup.dart` or `splash.dart` (or, since 0.9.0, `adapters:` lists a package); `generated`: always; `manual`: never, and those three are not read (one warning each). Another value: ``unknown variant `always`, expected one of `auto`, `generated`, `manual` ``. See [`app-main.md`](app-main.md)                                                                                                                                                                                                                                                                                                                                                                                                               |
| `size`               | a map (keys above)                               | What `fsp size` checks the web build against; only that command checks the values (since 0.8.1)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `test`               | a map (keys above)                               | What `fsp test` writes a smoke test file for; only that command checks the values (since 0.8.1; `a11y` since 0.16.0)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `adapters`           | a list of Dart package names, or `auto`          | Since 0.9.0. Packages that plug into the generated `main()`: for each, `lib/app.g.dart` imports `package:<name>/fespalier_adapter.dart` and calls its `adapter` (a `FespalierAdapter`); the first is the outermost. Each has to be under `dependencies:`. Makes `main: auto` write the file. Since 0.11.0 `lib/app.g.dart` defines `AppAdapters` whatever `main:` says, and `main: manual` with it is fine (up to 0.10.0 it was an error); a manual `main()` calls `AppAdapters`. Since 0.23.0 `adapters: auto` takes every first-party adapter package under `dependencies:`, in their order (`fespalier_analytics`, `fespalier_download`, `fespalier_launch`, `fespalier_push`), and nothing else; it is opt-in, because each needs its `configure` call. See [`app-main.md`](app-main.md). An `fsp` older than 0.9.0 rejects the key itself |
| `tasks`              | a map of tasks (see `fsp dev`)                   | The commands `fsp dev`, `fsp build` and `fsp run` run: `run`, `before`, `with`, `after`, `env`, `hot_reload`. Only those commands check it, so a mistake in it never stops `fsp gen` (since 0.9.0). An `fsp` older than 0.9.0 rejects the key itself                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |

There is no key for `extraCodec`: `lib/app/extra_codec.dart` is found by name. Nor for the generated `main()`'s path:
it is `output` with `.main.g.dart` in place of `.g.dart` (`lib/app.main.g.dart`), and `output_manifest` may not be it.

**Completion and checks in the editor (since 0.23.0).** The VS Code and IntelliJ plugins complete and check the `fespalier:`
section of `pubspec.yaml` with one schema of the whole file (`fsp schema --pubspec`), which keeps the JSON Schema Store's checks on the
rest of the file. VS Code needs the YAML extension (`redhat.vscode-yaml`); IntelliJ uses the JSON support the IDE bundles. Other
editors: `fsp schema --pubspec > .fespalier-pubspec.schema.json`, mapped to `pubspec.yaml` in the YAML language server's
`yaml.schemas` setting. A modeline works only when it points at that `--pubspec` file, never at the section-only `fsp schema`, which
would replace the store's schema for the whole file. Two readings are stricter than `fsp`'s: an empty key (`app_dir:` with no value)
and a number or boolean where text is expected (`meta_unique: [true]`) are refused by the schema, although `fsp` takes them.

## In CI

Committed-output mode (the default), either with `fsp` installed or without:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
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
  on a marketplace yet; build them from source. Both run `fsp` from
  `PATH`, else `dart run fespalier`. Since 0.7.0 both also check again when any Dart
  file under `lib/` is saved (not `*.g.dart`), and show a string-path warning in that file,
  because `fsp check` now reports on files outside the app folder. Since 0.22.0 both run the `tasks:` too: VS Code lists them in Run Task (`build` through a tasks.json entry with a `target`), IntelliJ has `fespalier task` run configurations, a run icon on each task key of a block-mapping `tasks:` in pubspec.yaml and _Tools | fespalier: Run Task..._; both read `fsp run --json`.
- **`flutter create` leftovers.** `flutter create` writes
  `test/widget_test.dart`, which refers to the `MyApp` you replaced, so
  `flutter analyze` fails on it until you delete or rewrite it.

## Speed (as measured by the maintainers)

docs/cli.md, "Performance", synthetic apps, release build, 4 cores, warm cache: a **cold `gen`**
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
