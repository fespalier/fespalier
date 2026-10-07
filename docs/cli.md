# CLI reference

Every `fsp` command, the generated file, the editor plugins and `fsp dev`.

## The generator

`cli/` is a Rust binary, `fsp`. A full scan, check and emit of an example runs in a few
milliseconds, fast enough to run on every save.

`fsp` installs as described in [Getting started](../README.md#getting-started). To build it from a
checkout, run `cd cli && cargo build --release` (→ `cli/target/release/fsp`). Commands:

```sh
fsp init                # first-time setup: starter files, then gen
fsp gen                 # check lib/app/, write lib/app.g.dart
fsp gen --format        # ...and run `dart format` on it
fsp routes              # print the route table (--json: one object per route)
fsp routes --graph      # the route tree as a Mermaid graph (--graph dot: Graphviz)
fsp routes --graph json # the same tree as JSON (what the DevTools extension reads)
fsp links               # App Links, Universal Links, assetlinks.json and a sitemap from the routes
fsp links --check       # CI: non-zero exit when those files are stale
fsp maestro             # Maestro smoke flows, one per route (since 0.7.0)
fsp maestro --check     # CI: non-zero exit when those flows are stale
fsp size                # the web build's JavaScript per deferred route (since 0.8.1)
fsp size --check        # CI: non-zero exit when a budget in `size:` is exceeded
fsp test                # a widget smoke test per route, in test/routes/ (since 0.8.1)
fsp test --check        # CI: non-zero exit when that file is stale
fsp telemetry           # a local OpenTelemetry stack with fespalier's dashboards (since 0.8.1; needs Docker)
fsp telemetry --grafana # ...and Grafana, with the same dashboards
fsp watch               # same, whenever the routing changes (keep it next to `flutter run`)
fsp dev                 # fsp watch and flutter run in one terminal, hot restarting when the routes change (since 0.9.0)
fsp build web           # fsp gen, then flutter build web, with the hooks of `tasks: build:` (since 0.9.0)
fsp run codegen         # a task of your own from `tasks:` in pubspec.yaml; `fsp run` lists them (since 0.9.0)
fsp check               # CI: non-zero exit on errors, writes nothing
fsp new 'products/[id]' --name Product --data --action --loading --error --layout --guard --transition
                        # [id] or :id both mean $id, so no shell quoting of $
fsp new '(account)' --layout    # a (group) folder: layout only, no page.dart
fsp new 'kyc/shop/name' --function --name KycShopName
                        # views as functions (`Widget page()`), with a routeName
fsp new 'shop' --not-found      # not_found.dart (not-found.dart with `file_style: kebab`)
fsp new 'orders' --nav          # nav.dart: how the folder shows in the generated menus (since 0.8.1)
fsp new 'orders/[id]' --observe # observe.dart: onEnter, onFocus and onLeave (since 0.8.1)
```

All commands take `--project <dir>` (default: the nearest folder with a `pubspec.yaml`).

### fsp new

`fsp new` writes `page.dart` plus the kinds you ask for with flags. It skips files that already exist,
then regenerates `lib/app.g.dart` and prints the result line (if that fails, it lists the files it
created).

- **Class names** come from `--name` (default: from the path, e.g. `ProductsId`). A segment that
  already has a type elsewhere in the tree keeps it.
- **`--function`** writes [function views](file-kinds.md#function-views) instead of classes, and
  `--name` becomes the `routeName` (an UpperCamelCase name).
- **`--no-page`** leaves `page.dart` out.
- **`--not-found`** adds a `not_found.dart` that takes the segments of its path as `String`s (see
  [Not-found views](routing.md#not-found-views)).
- **A `(group)` target** (like `'(account)'`) gets no `page.dart` either, since a group has no URL of
  its own; write one by hand if you want the group to serve its parent's URL. After
  `fsp new '(account)' --layout`, the generator warns "folder has no page.dart and no routes below
  it; skipped" until you add a route inside the group. That is expected.

`fsp gen`, `check` and `watch` also look at the string paths in `lib/` (see
[Checking string paths](#checking-string-paths)).

### fsp routes

`fsp routes` prints what the header of `lib/app.g.dart` lists: each route's URL pattern, its typed
route class, its `page.dart` and its tags.

```text
/products/:id  ProductRoute   products/$id/page.dart  (data, transition)
```

A route with [localized paths](routing.md#localized-paths) lists each spelling under its row (`fr  /produits/:id`).

The tags are `redirect`, `data`, `action`, `guard`, `layout`, `transition`, `present`, and:

- `observe`: a page with an [`observe.dart`](observability.md#route-lifecycle-observedart) at or above it (since 0.8.1);
- `root`;
- `sibling`: a route with [`nest = false`](routing.md#a-sibling-with-a-compound-path);
- `remount`: a page that [starts again when its URL changes](navigation.md#remounting-a-page-remount);
- `deferred`, always last: a page whose [code loads on demand](navigation.md#deferred-routes-a-pages-code-on-demand) (since 0.7.0);
- `fresh` (since 0.8.1), after `data`: its data has a [`freshness`](data.md#freshness-staletime-resume-and-reconnect);
- `cached` (since 0.8.1): it has a [`dataCache`](data.md#a-cache-that-survives-a-restart-datacache).

**`--graph`** (since 0.5.0) prints the route _tree_ instead, to paste into a README, a pull request
or an issue. `fsp routes --graph` (or `--graph mermaid`) writes a Mermaid `flowchart TD`, which
GitHub renders in Markdown; `--graph dot` writes a Graphviz `digraph` (`fsp routes --graph dot | dot -Tsvg`).

```text
flowchart TD
  subgraph rootnav["root navigator"]
    subgraph b0["layout layout.dart"]
      n0["/<br/>HomeRoute"]
      n1["/cart<br/>CartRoute"]
      n2["/checkout<br/>CheckoutRoute<br/>(guard)"]
      ...
```

The graph shows what `app.g.dart` gives go_router, not the folders:

- **Nodes** are routes: the URL pattern, the route class, each spelling of a
  [localized path](routing.md#localized-paths) and the markers (`redirect`, `data`, `fresh`, `cached`, `action`, `guard`,
  `observe`, `present`, `root`, `sibling`, and `deferred`, as in the tags above). A `redirect.dart` route is dashed.
- **Edges** are nesting: a page is the parent of the routes in the folders below it, and a route with
  [`nest = false`](routing.md#a-sibling-with-a-compound-path) hangs from the page above its parent instead.
  A shell's routes hang from the route above the shell.
- **Boxes** are navigators: the root navigator, a [layout](file-kinds.md)'s shell (`layout.dart`, with
  `data` for a [section](data.md#section-data) and `guard` for its folder's guard) and each branch of a
  [tab layout](layouts.md#tab-layouts).

The output has no timestamp and a fixed order, so a graph committed to a doc changes only when the
routes do. `--graph` and `--json` cannot be combined.

**`--graph json`** (since 0.7.0) prints the same tree as JSON, with each guard, `redirect.dart`,
`data.dart` and `action.dart` as a _site_ the generated code names. The
[DevTools extension](devtools.md) reads it, and `app.g.dart` embeds it. Every route has its URL
pattern, route class, file and folder (relative to the app folder), markers, typed parameters and
each other spelling of a localized path; layouts and tab layouts are items of their own.

**`--json`** prints one JSON object per line, for scripts and editors, with each
route's parameters and the [manifest](routing.md#route-manifest-and-metadart)'s fields; `file` is relative to
the project root:

```json
{
  "pattern": "/products/:id",
  "route": "ProductRoute",
  "file": "lib/app/products/$id/page.dart",
  "tags": ["data", "transition"],
  "params": [{ "name": "id", "type": "int", "in": "path" }],
  "folder": "products/$id",
  "presentation": "page",
  "groups": [],
  "layouts": [],
  "tabs": [],
  "data_keys": ["id"],
  "meta": null,
  "catch_all": null
}
```

### JSON diagnostics

`fsp gen --json` and `fsp check --json` print each diagnostic to stdout as one JSON object per line
instead of the rendering shown under [What the commands print](#what-the-commands-print), so an editor
can turn them into squiggles. The success and failure lines still go to stderr, and stdout is empty
when there is nothing to report.

```json
{
  "file": "lib/app/shops/$shop/items/$id/page.dart",
  "line": 6,
  "column": 18,
  "severity": "error",
  "message": "can't fill `label`: ..."
}
```

`line` and `column` count from 1 (the column counts characters, not bytes) and are `null` for
a diagnostic that isn't about a place in a file. `severity` is `error` or `warning`.

### Formatting

The generated file is not formatted by default, so a committed `app.g.dart` doesn't depend on which
Dart SDK ran `fsp`. To format it, use `fsp gen --format` or `format: true` in the pubspec section.

- It pipes the file through `dart format`, which needs `dart` on your `PATH`; without it `fsp` warns
  and writes the unformatted code.
- It uses your package's language version and `analysis_options.yaml` (`formatter: page_width`),
  like `dart format lib/`.
- `fsp gen` compares the formatted text with the file on disk, so a formatted file that is up to date
  stays "unchanged".
- `fsp watch`, `fsp new` and `fsp init` follow `format:` in the pubspec.
- `fsp check` writes and compares nothing, so it never runs `dart`.

### What the commands print

- `fsp gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged`
  when the output didn't change. With `output_manifest`, or a [generated `main()`](app-startup.md)
  since 0.8.1, every file is named: `✓ 12 routes → lib/app.g.dart, lib/app.main.g.dart`.
- `fsp check`: `✓ 12 routes, no errors`.
- `fsp dev` (since 0.9.0): the same `gen` line, then the [full-screen view](#running-your-app-fsp-dev), or with `--no-tui`
  the lines of each process with its name in front, `[fsp] ✓ 12 routes → lib/app.g.dart (3.1ms)`.
- `fsp watch`: the `gen` line once at startup, then a line each time a save changes
  `lib/app.g.dart`. An edit that doesn't (a widget's `build` method, say) prints nothing. It ignores
  its own output and file reads, so it doesn't loop while idle.
  - It keeps the parse results of files that didn't change, so a save parses only the file you saved.
    A save that leaves everything the generator reads as it was (a colocated widget, say) doesn't
    resolve or render again, and `dart format` (with `format: true`) only runs on generated code it
    hasn't formatted before.
  - It also watches the rest of `lib/` (Dart files and folders only), because the enum a segment names
    is declared there: editing `lib/models/category.dart` regenerates.
  - See [Performance](#performance).

Errors point at the parameter or declaration at fault, and `app.g.dart` is left untouched while there
are any. A file that can't be fully parsed gets a warning instead (the Dart compiler reports the exact
error), and the generator works with what it could read:

```text
error: can't fill `label`: it isn't a segment of this path ($shop, $id) or data.dart's String
  ┌─ lib/app/shops/$shop/items/$id/page.dart:6:18
  │
6 │   const ItemPage(this.label, {super.key});
  │                  ^^^^^^^^^^

error: `$id` is int in products/$id/data.dart:6 but String here
```

## The generated file

`lib/app.g.dart` is plain go_router + Riverpod code that's meant to be read and committed.
It opens with a route table (see `examples/shop/lib/app.g.dart`). Some details:

- **Types are never re-spelled.** The generator doesn't copy your imports. Values flow through
  inference, and each route's provider is a `static final` whose type is inferred. The exceptions are a
  page's (or a layout's, guard's or redirect's) [typed `extra`](navigation.md#typed-extra) and an
  [enum segment or query parameter](routing.md#enum-segments), whose types the typed route has to name;
  it imports those types by name from the file's imports.
- **Segments and query parameters are parsed into a record** (`({int id, int? page})`).
  Records compare by value, so providers are keyed by them directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
  `(group)` folders fold away completely, apart from the ShellRoute their layout adds.
- **Static routes come first** among siblings, then dynamic ones, then a
  [catch-all](routing.md#catch-all-segments), so go_router's first match is the most specific one.
- **`AppRoutes.mount(at:)`** only changes the root path (and, with `navigatorKey:`, the
  root navigator's key). Typed routes read `AppRoutes.base`, so `.location` stays correct when
  mounted under `/shop`.

## Editor plugins

Two editor plugins sit on top of the JSON diagnostics. Neither is on a marketplace yet, so you build
them from source. Both use `fsp` from your `PATH`, or `dart run fespalier` when there is none, and both
check again when you save a file under the app folder (`fespalier: app_dir:` in `pubspec.yaml`,
`lib/app` by default).

- **VS Code:** `editors/vscode/` puts the diagnostics in the Problems panel, with a
  `fespalier: generate` command and a status bar item. `fespalier.runner` chooses the runner. Build it
  with `npm install && npm test && npx @vscode/vsce package` in that folder and install the `.vsix`
  (see `editors/vscode/README.md`).
- **IntelliJ IDEA and Android Studio:** `editors/intellij/` (Kotlin) underlines the problems
  in the editor, with their severity, in the files under the app folder, and adds
  _Tools | fespalier: Generate_ and _fespalier: Check_; a notification says when `fsp` could
  not run. Settings | Tools | fespalier chooses the runner (auto, `fsp`, or `dart run fespalier`) and
  the path to `fsp`. It works on platform 252 (2025.2) and later; the
  highlighting of route files needs the Dart plugin, which Android Studio includes. Build it
  with JDK 21:

  ```sh
  cd editors/intellij
  ./gradlew build buildPlugin      # tests, then build/distributions/fespalier-intellij-<version>.zip
  ```

  Then _Settings | Plugins | gear icon | Install Plugin from Disk..._ and pick the zip.
  `./gradlew runIde` starts a sandbox IDE with the plugin instead. See
  `editors/intellij/README.md`.

## Running your app: `fsp dev`

Since 0.9.0. `fsp dev` is `fsp watch` and `flutter run` in one terminal, with no configuration. It
writes `lib/app.g.dart`, starts the app, and **hot restarts** it whenever the routes change, because a
new route needs a restart. Any other save of a Dart file under `lib/` gets a **hot reload**.

```sh
fsp dev                  # pick a device, run the app, keep app.g.dart current
fsp dev -- -d chrome     # anything after -- goes to flutter run
```

![fsp dev: a header with the app, the device and the DevTools link; a tab per process; the flutter log; a status line with the route count, the last generation and the last hot restart; the keys.](images/fsp-dev.svg)

| Key            |                                                    |
| -------------- | -------------------------------------------------- |
| `r` / `R`      | hot reload / hot restart                           |
| `d` / `o`      | open DevTools / open the app in the browser (web)  |
| `t`            | start [`fsp telemetry`](telemetry-dashboards.md)   |
| `Tab`, `1`–`9` | switch between flutter, fsp and your own processes |
| `/`            | filter the log; `Esc` clears                       |
| `?` / `q`      | help / quit                                        |

- The header shows the device, the web address or VM service, and the DevTools link.
- The status line shows the route count, the first routing error (clickable in terminals that support
  links), and how long the last hot reload took.
- When flutter stops by itself (a build error, say), the view stays: fix it and press `R`.
- `fsp dev` runs `flutter run --machine` and talks to it over flutter's own protocol, so it works the
  same on macOS, Linux and Windows. Flutter's other keys (`p`, `w`, ...) live in DevTools (`d`).
- You can still run `fsp watch` next to your own `flutter run`, or your editor's.
- With several devices, `fsp dev` asks which one (and remembers the answer in
  `.dart_tool/fespalier/dev.json`); with one phone or emulator it picks that, as `flutter run` does.
  Name one yourself after `--`: `fsp dev -- -d chrome`.

### Tasks: commands around `flutter run`

Add what your app needs around `flutter run` under `tasks:` in the `fespalier:` section of `pubspec.yaml`:

```yaml
fespalier:
  tasks:
    dev:
      before: dart run build_runner build -d # runs first; if it fails, fsp dev stops
      with:
        build_runner: dart run build_runner watch -d # runs alongside, in a pane of its own
      env:
        API_URL: http://localhost:8080
    codegen: dart run build_runner build -d # fsp run codegen
```

| Key          | What it is                                                                                                                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `run`        | The main command. `dev` defaults to `flutter run` (fsp adds `--machine`, the device and your args), `build` to `flutter build`. Write `fvm flutter run`, or a script that passes `"$@"` on to `flutter run`. |
| `before`     | A command or a list, run one after the other before `run`. The first that fails stops the task with its exit code.                                                                                           |
| `with`       | Long-running commands, by name, started next to `run` and stopped with it.                                                                                                                                   |
| `after`      | A command or a list, run when `run` exits 0.                                                                                                                                                                 |
| `env`        | Variables for these commands (not for the app: use `--dart-define` for that).                                                                                                                                |
| `hot_reload` | `dev` only. `false` turns the automatic reload and restart off; `r` and `R` still work.                                                                                                                      |

- A command written as a string runs in the shell (`sh` on macOS and Linux, `cmd` on Windows).
  Written as a list (`[flutter, test]`) it runs with no shell, the same everywhere.
- `fsp` at the start of a command is the `fsp` running the task, even under `dart run fespalier`.
- A list under `before` or `after` is a list of commands, so `before: [dart, run, x]` is three shell
  commands (`dart`, `run` and `x`); write `before: [[dart, run, x]]` for one command with no shell.
- A task that is only `run` can be written as the command itself, as `codegen` is above.
- A custom `run` gets `--machine` and the arguments after `--` appended, but not a device: put `-d` in
  it, or after `--`.
- A mistake in `tasks:` is reported by `fsp dev`, `fsp build` and `fsp run`, never by `fsp gen`.

### `fsp build` and `fsp run`

`fsp build <target>` runs `fsp gen`, then the `build` task: `before`, `flutter build <target>` (plus your args
after `--`), `after`. `fsp run <task>` runs a task of your own; `fsp run` alone lists them. `--dry-run` prints
what would run and runs nothing.

```yaml
check: # fsp run check
  before: [fsp check, fsp test --check]
  run: [flutter, test]
web: # fsp run web
  run: fsp build web -- --release
  after: fsp size --check
```

`fsp telemetry` starts its stack and returns, so it goes in `before` (`before: fsp telemetry`), not `with`.

### Plain output, CI and Windows

Outside a terminal (CI, an IDE's run panel), with `TERM=dumb`, or with `fsp dev --no-tui`, `fsp dev`
prints each line with the name of the process in front (`[flutter]`, `[fsp]`, `[build_runner]`). You type
`r`, `R` or `q` followed by Enter.

- With several devices and no terminal to ask in, pass one: `fsp dev -- -d <id>`.
- Quitting asks flutter to stop the app, then stops the `with` commands and everything they started. A
  second `q` or Ctrl-C stops them at once.

## Deep links and a sitemap (`fsp links`)

Since 0.5.0. The URLs your app opens are its routes, so `fsp links` writes the lists the platforms want
from the route tree instead of you keeping them by hand: the `<intent-filter>`s of Android App Links and
`assetlinks.json`, the `apple-app-site-association` file and the entitlement of iOS Universal Links, and a
`sitemap.xml`. Say where the app lives in `pubspec.yaml`:

```yaml
fespalier:
  links:
    domains: [shop.example.com] # required; the first one is the sitemap's
    scheme: myshop # optional custom scheme: myshop://shop.example.com/products/2
    android_package: com.example.shop # with android_sha256: the Android files
    android_sha256: ["AB:CD:...:EF"] # the signing certificates' fingerprints, 32 hex pairs each
    ios_app_id: ABCDE12345.com.example.shop # Team ID, a dot, the bundle id: the iOS files
    out: links # default: where the files go, relative to the project
```

`fsp links` then writes, below `out` (`links/` unless you say otherwise; commit it, like `app.g.dart`):

```text
links/
  android/intent-filters.xml                  one <intent-filter android:autoVerify="true"> per domain, one for `scheme`
  ios/associated-domains.entitlements         the applinks:<domain> entries
  ios/info-url-types.xml                      CFBundleURLTypes, with `scheme` and `ios_app_id`
  web/.well-known/assetlinks.json             serve it at https://<domain>/.well-known/assetlinks.json
  web/.well-known/apple-app-site-association  serve it at the same place, as application/json, without a redirect
  web/sitemap.xml                             every static route, on the first domain
```

- The Android files are written when `android_package` is set (it needs `android_sha256`, and the
  reverse), the iOS ones when `ios_app_id` is, and the sitemap always.
- A key that is missing, or a fingerprint or package that isn't one, is an error that names the key. Only
  `fsp links` checks them: a mistake there never stops `fsp gen`.
- A file the config no longer asks for is removed by `fsp links` and reported by `--check`.

**What is listed.** Each route's path, in each spelling of its [localized paths](routing.md#localized-paths),
and every route in a folder that doesn't say [`const linkable = false;`](routing.md#case-and-trailing-slashes)
(a `route.dart`, inherited down the tree, the nearest one wins). Redirects are opened by the app,
so they are in the Android and iOS lists; a sitemap leaves them out.

| Route                         | Android                                    | iOS (`components`)      | Sitemap                  |
| ----------------------------- | ------------------------------------------ | ----------------------- | ------------------------ |
| `/about` (static)             | `android:path="/about"`                    | `/about`                | listed                   |
| `/products/:id`               | `pathPattern="/products/..*"`              | `/products/?*`          | left out                 |
| `/docs/*rest`                 | `pathPrefix="/docs/"`                      | `/docs/?*`              | left out                 |
| `/files/*path?`               | `path="/files"` and `pathPrefix="/files/"` | `/files` and `/files/*` | left out                 |
| `help/` with `{'fr': 'aide'}` | one entry per spelling                     | one entry per spelling  | one `<url>` per spelling |

- **A `$dynamic` segment is a wildcard.** Android's `pathPattern` can't say "one segment", so
  `/products/..*` also lets `/products/2/extra` through; the app's router has the last word and shows
  its not-found view. iOS's `?*` is the same. `linkable = false` removes a route's own entries; it
  can't carve a hole out of the wildcard a dynamic sibling makes (a `$slug` at the root lets every
  one-segment path in).
- **Localized spellings.** Android gets the characters as written, which it compares with the decoded
  path (`/führer`); iOS and the sitemap get the percent-encoded form (`/f%C3%BChrer`). The sitemap gives
  each spelling its own `<url>` with `xhtml:link` `hreflang` alternates for every locale (the
  canonical path is `x-default`).
- **iOS case.** A route that is [case-insensitive](routing.md#case-and-trailing-slashes) gets
  `"caseSensitive": false` in its component. Android always matches by case.
- **The sitemap lists static routes only.** Dynamic routes and catch-alls have no URL to write down
  without data fespalier doesn't have, and there is no way to list them at runtime. Guards
  aren't looked at either: a route behind a guard is listed, so mark it `linkable = false` if a
  crawler shouldn't see it.
- **Mounting.** The paths are the routes' own. An app that mounts its routes under a
  prefix (`AppRoutes.mount(at: '/shop')`) has to put the prefix in front itself.

**Using the files.** `fsp links` never edits `AndroidManifest.xml`, `Runner.entitlements` or
`Info.plist`. Copy the output in yourself:

1. Paste `android/intent-filters.xml` into the `<activity>` of
   `android/app/src/main/AndroidManifest.xml` that has the `MAIN`/`LAUNCHER` filter (replace what you
   pasted last time).
2. Add the `applinks:` lines of `ios/associated-domains.entitlements` to `ios/Runner/Runner.entitlements`,
   and the entry of `ios/info-url-types.xml` to `Info.plist`.
3. Copy `links/web/` into your Flutter project's `web/` folder (`flutter build web` ships `.well-known/`
   as it ships the rest), or serve it from wherever the domain's server keeps its files.

Android only verifies a domain when `assetlinks.json` is served over HTTPS at
`/.well-known/assetlinks.json` with no redirect.

**Staying current.** The output is a function of the tree and the pubspec (a fixed order, no dates),
so the same input gives the same bytes. `fsp links --check` writes nothing and exits non-zero when
a file is missing, out of date or no longer wanted, and names it; run it in CI next to `fsp check`.
`fsp routes --json` is unchanged.

## Checking string paths

Since 0.7.0. A typed route (`ProductRoute(id: 2).go(context)`) can't be misspelled, but a string path is
sometimes the right thing (a CMS link, a notification payload), and `context.go('/prodcts/2')` compiles,
runs and shows `not_found.dart`. So `fsp gen`, `check` and `watch` read the string paths your code gives
the router and warn about one that **matches no route**. A path that matches is fine: typed routes are
preferred, not forced.

```text
warning: no route matches `/prodcts/2`, so it shows not-found; did you mean `/products/2`? [unknown_path]
  ┌─ lib/screens/home.dart:2:14
  │
2 │   context.go('/prodcts/2');
  │              ^^^^^^^^^^^^
```

**What is checked.** A string literal in one of these places:

- the first argument of `.go(...)`, `.push(...)`, `.pushReplacement(...)` or `.replace(...)` on
  anything (`context.go('/x')`, `GoRouter.of(context).push<int>('/x')`, `router..go('/x')`);
- `RouteLink(uri: Uri.parse('/x'))`;
- `initialLocation:` of `AppRoutes.router(...)` or `GoRouter(...)`.

Not these: a bare `go('/x')` with no receiver, `goNamed` and `pushNamed`, `Navigator.pushNamed`, the
typed routes (their argument is not a string), `TabOptions(initialLocation:)` (the generator already
checks it against the tab), and `AppRoutes.match`, `matchUrl`, `dataAt` and `preload`, which exist to
ask about any location. A path that is built (`'/a' + b`) or held in a variable is not a literal and is
not read.

**What matches.** The same rules as `AppRoutes.match`:

- segments, and [catch-alls](routing.md#catch-all-segments) (`$$rest` needs one part, `$$$rest` none);
- [case](routing.md#case-and-trailing-slashes) by the route's own setting;
- every [localized spelling](routing.md#localized-paths) (mixed spellings too);
- non-ASCII paths and `%` escapes decoded, and a trailing slash or `//` ignored;
- a `redirect.dart` is a route; a `not_found.dart` is not;
- the query and the fragment are not looked at (`go_router` ignores parameters it doesn't know);
- the first route that fits the path decides: a later route that would take the text is never tried.

Since 0.8.1 segment **types are checked** too, the way the route parses them. `/products/abc` reaches
`products/$id`, and with `{required int id}` that route shows not-found, so it is reported
(`` `/products/abc` reaches /products/:id, but `abc` is not an int, so it shows not-found [unknown_path] ``).
An app with `unknown_path: error` that passed on 0.7.0 can fail on 0.8.1 for a path that always showed
not-found.

- `int`, `double`, `num`, `bool`, `DateTime` (its start only) and [enum](routing.md#enum-segments)
  segments are checked, and each part of a typed [catch-all](routing.md#typed-catch-alls).
- An enum's message lists its values and suggests the nearest.
- A part with a space or other non-ASCII whitespace is not judged (Dart trims it before parsing).
- The message names the route by its canonical pattern, also for a [localized](routing.md#localized-paths) spelling.

**Interpolation.** A path that interpolates is checked up to its first `$`: `'/products/$id'` is fine and
`'/prodcts/$id'` is flagged (`no route starts with ...`). The complete segments before the `$` are checked
by type too (`'/products/abc/$tab'` is reported), but nothing after a `$` is, since the value can be empty
or hold a `/`.

**Skipped.** A path that is not an app path: a relative one (`'details'`), a URL (`'https://...'`), one
that starts with an interpolation (`'$base/x'`), one with a `..` or a malformed `%` escape.

**Which files.** Every Dart file under `lib/` (the app folder included), except the generated ones
(`*.g.dart`, the `output` and `output_manifest`) and folders that start with a `.`. Not `test/`,
`integration_test/` or `bin/`: tests navigate to paths that match nothing on purpose, to try
`not_found.dart`, and mount the tree under prefixes the app doesn't use.

**The mount point.** `AppRoutes.mount(at: '/shop')` is read, and a path is checked below it:
`/shop/products/2` is looked up as `/products/2`. A path outside the mount point belongs to the host
router (`legacyRoutes` beside `...AppRoutes.mount(at: '/shop')`) and is skipped.

- When `at:` is not a string literal, or two calls give two different values, `fsp` can't know where
  the tree is, and the check reports nothing for the run.
- A host router with routes of its own and the tree mounted at `/` gets a warning for those routes'
  string paths: silence them as below, or turn the lint off.

**Severity.** `lints:` in the `fespalier:` section of `pubspec.yaml`:

```yaml
fespalier:
  lints:
    unknown_path: warning # default; `error` fails `fsp gen` and `fsp check`; `off` skips the check
```

A warning never fails a command, so a false positive can't break a build. With `error`:

- `fsp check` exits 1 (``1 error(s) in string paths (`lints: unknown_path: error`)``).
- So do `fsp gen` and `fsp watch`, after they write the output (`...; lib/app.g.dart is up to date`):
  the generated file doesn't depend on the lint, so a typo in some other file does not stop `watch`
  from regenerating.
- `fsp new` and `fsp init` report it as a warning at most.
- If the route tree itself has errors, the check doesn't run: a half-resolved tree would make every
  path look unknown.

**Silencing one.** A comment on the line above, or after the path on its own line:

```dart
TextButton(
  // fsp:ignore unknown_path -- gift cards aren't built yet: not_found.dart shows
  onPressed: () => context.go('/gift-cards'),
  child: const Text('Gift cards'),
),
```

A comment on a line of its own covers the call that starts on the next line, however long it is; one
after code covers that line. `// fsp:ignore-file unknown_path` anywhere in a file silences the file.
The lint's id, `unknown_path`, is what both and `lints:` name; it is also the last word of the message.

**In the editor.** Both plugins show it in the file it is about, and check again when any Dart file
under `lib/` is saved, not only one under the app folder.

**Why in `fsp`.** It already has the route tree, parses Dart, and reports diagnostics that both
plugins show, so `fsp check` in CI and `fsp watch` get the lint with nothing for an app to add. An
analyzer plugin would need `analysis_options.yaml`, which takes a package from pub.dev or a `path:` and
not a git dependency (fespalier is one), would pin an `analyzer` major that moves several times a year,
and would need its own copy of the matcher. The cost of a syntax tree is that `fsp` can't know that
`context` is a `BuildContext`: it only reads string literals in the call shapes above.

`examples/shop` has a string path that matches (`context.go('/products?sort=expensive')`), one
that is silenced, and `unknown_path: error`, so `just check-examples` fails if it gains a bad one.

## Maestro flows (`fsp maestro`)

Since 0.7.0. [Maestro](https://docs.maestro.dev) drives an app from the outside, through the
platform's accessibility tree, so it cannot see a Flutter `Key`. It finds text, a `Semantics` label
and a `Semantics(identifier:)`, which its `id:` selector matches. `fsp` gives every page one, and
writes a smoke flow for each route that opens the route's URL and waits for that page.

**`semantics_ids: true`** in the `fespalier:` section of `pubspec.yaml` wraps each page's own widget in

```dart
Semantics(identifier: 'route:/products/:id', container: true, explicitChildNodes: true, child: ProductPage(id: v.id))
```

The identifier is `route:` and the pattern `fsp routes` prints (`route:/`, `route:/products/:id`,
`route:/docs/*rest`, `route:/files/*path?`). It depends only on the folder path, so it is the same for
every [localized spelling](routing.md#localized-paths) and every mount prefix, and it does not change when you
rename a class. It is in the widget tree **if and only if the route's own page is built**:

- The wrapper sits on the innermost call, inside `DataView`, `DeferredView` and `SectionView`, so `loading.dart`,
  `error.dart` and `not_found.dart` do not carry it. A flow cannot pass while a spinner or an error shows,
  nor while a [deferred](navigation.md#deferred-routes-a-pages-code-on-demand) page's code is loading.
- go_router builds the whole matched stack, but the pages underneath the top one are off screen and
  out of the semantics tree: `/products/1` has `route:/products/:id` and not `route:/products`.
- Only a `page.dart` gets one: not a layout, a shell, a redirect or a not-found view.
- `Semantics` has no `const` constructor, so the wrapper is never `const`; a page that was `const`
  keeps its own `const` inside it, and the generated code passes the `const` lints.
- The identifier's node is empty: `container: true` gives it a node of its own, and
  `explicitChildNodes: true` (since 0.9.1) keeps every descendant out of it. The node has no label and no
  action, and a screen reader reads each of the page's `Text` widgets as its own node. (Without it, TalkBack
  and VoiceOver read all the text outside a scroll view, such as a status line, a sheet's footer, or a title
  and its line, as one block.) A page that wants one announcement groups its own text with `MergeSemantics`.
- With the key off (the default), the generated file is exactly what it was without the feature.

**On the web, this is not free.** Flutter builds no semantics tree until a screen reader asks for one, so a
driver that reads the page from outside finds nothing. With `semantics_ids: true` the generated
`AppRoutes.mount()` (which `router()` calls, so an app that embeds the routes is covered too) first calls
`ensureWebSemantics()` from `package:fespalier`. On the web it calls `SemanticsBinding.instance.ensureSemantics()`
once and keeps the handle for the life of the app; anywhere else, and in every widget test (which runs on
the VM), it does nothing. **The tree then stays on in the web build for every user of it,** which costs
frame time and DOM nodes, and no key narrows it to a test build. Weigh it before you turn the key on in an
app whose web build you ship.

**`maestro:`** says what the flows open. These are all the keys:

```yaml
fespalier:
  semantics_ids: true # required by `fsp maestro`
  maestro:
    app_id: com.example.shop # Android and iOS: each flow's `appId:`   } exactly one
    url: http://localhost:8080 # the web: each flow's `url:`             } of the two
    link: myshop://shop.example.com # what a route's path is appended to; default below
    out: .maestro/routes # default; a folder inside the project, no `..`
    guard_flow: .maestro/sign-in.yaml # optional: runs before the link of a guarded route
    timeout: 20000 # default; how long a flow waits for the page, 1000 to 600000 ms
    samples: # the value of each dynamic folder, inherited by the routes below it
      products/$id: 2
      greet/$name: Ada
      docs/$$rest: [guides, intro] # a catch-all takes a list of parts (a lone value is one part)
```

- `app_id`, `url` and `link` may be a Maestro variable written whole, such as `app_id: ${APP_ID}`; it is
  copied into the flow as written, and `maestro test -e APP_ID=com.example.shop` fills it in.
- **`link`** is what a route's path goes after: `myshop://shop.example.com` plus `/products/2`. It defaults
  to the `url` for the web. For an app it comes from [`links:`](#deep-links-and-a-sitemap-fsp-links)
  (`<scheme>://<first domain>` with a `scheme`, else `https://<first domain>`), and with neither it is
  an error. A Flutter web app on the default **hash URL strategy** needs `link: http://localhost:8080/#`,
  because its routes live after the `#`; with `usePathUrlStrategy()` the default is right.
- **`samples`** keys are folders as `fsp routes` prints them without `/page.dart` (`products/$id`,
  `(members)/notes/$id`), and each must be a `$x`, `$$x` or `$$$x` folder.
  - A value is text, a number, a boolean or, for a catch-all, a list of them. It is percent-encoded and
    checked against the segment's type (`int`, `double`, `num`, `bool`, and `List` of them); a `String`, a
    `DateTime` or an enum is taken as written, because the generator doesn't know an enum's values.
  - The sample is for the _folder_, so every route below `products/$id` opens `/products/2/...`.
  - An optional catch-all (`$$$path`) with no sample is the bare path.
  - Quote a value that must stay text (`'1.10'`).

`fsp maestro` writes one flow per route into `out` (commit it, like `app.g.dart`). This is the shop
example's, `examples/shop/.maestro/routes/product_route.yaml`:

```yaml
# Written by `fsp maestro` from lib/app/products/$id/page.dart: don't edit it, run `fsp maestro` again.
url: "http://localhost:8080"
name: "/products/:id"
tags:
  - "fespalier"
---
- launchApp
- openLink: "http://localhost:8080/#/products/1"
- extendedWaitUntil:
    visible:
      id: "route:/products/:id"
    timeout: 20000
```

- `launchApp` starts the app afresh, so every flow begins from the same state.
- `openLink` opens the route's sample URL (the long form with `autoVerify: true` for an Android app whose
  link is `https`, which skips Android's "Open with" dialog).
- `extendedWaitUntil` returns the moment the identifier is on the screen, or fails after `timeout`. When it
  returns, the route's guards ran, its data loaded and its page was built.
- A guarded route's flow also has `- runFlow: "../sign-in.yaml"` between `launchApp` and `openLink` (the
  path is relative to the flow, as Maestro wants it) and a comment naming the `guard.dart` files.

**Which routes get a flow.** The rows are checked in this order, and the first that applies wins. Every
skip is printed, on every run, and none of them fails `--check`.

| Route                                          | Result  | Printed                                                                                                               |
| ---------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------- |
| A `redirect.dart` route                        | skipped | `skipped /old: a redirect, with no page to see`                                                                       |
| `app_id`, and `const linkable = false;`        | skipped | ``skipped /secret: `const linkable = false;`, so `fsp links` does not open the app at it``                            |
| A `$x` or `$$x` segment with no sample         | skipped | ``skipped /products/:id: no sample for products/$id in `fespalier.maestro.samples` ``                                 |
| A `guard.dart` at or above it, no `guard_flow` | skipped | ``skipped /checkout: guarded by checkout/guard.dart; set `fespalier.maestro.guard_flow` to a flow that gets past it`` |

A `(group)` folder's guard covers the routes in it. Samples come from the pubspec only. Layouts,
not-found views, query parameters and the localized spellings get no flow: a route is opened at its
canonical path.

**Files and ownership.** A flow is named after its typed route class in snake case: `ProductRoute`
is `product_route.yaml`, `ProPlanRoute` is `pro_plan_route.yaml`, the root `HomeRoute` is
`home_route.yaml` (the `_route` ending keeps a file from being Maestro's `config.yaml`).

- Every file `fsp maestro` writes starts with ``# Written by `fsp maestro` ``. In `out`, a `*.yaml` file with
  that first line is `fsp`'s: `fsp maestro` deletes it when no route needs it any more, and `--check`
  reports it.
- Any other file there (a flow you wrote, a `config.yaml`) is never read or touched, so hand-written
  journeys live beside the generated ones.
- The output is a function of the tree and the pubspec (a fixed order, no dates), so `fsp maestro --check`
  writes nothing and exits non-zero when a flow is missing, out of date or no longer a route's, and names
  it. Run it next to `fsp check`: it does not check that `lib/app.g.dart` is current.
- The values of `maestro:` are checked only by `fsp maestro`, so a mistake there never stops `fsp gen`.

**Running them.** `maestro test .maestro/routes`. Pass the folder, not `.maestro`: Maestro runs only the top-level flows of
the folder it is given, and skips subfolders unless a `config.yaml` there lists them (`flows: ["routes/*"]`).
`maestro test -e APP_ID=... -e URL=...` fills in variables.

- **The web.** Maestro's web support is in beta. Serve the app at the `url`
  (`flutter run -d web-server --web-port 8080`, or a static server for `flutter build web`; with the
  path strategy it must serve `index.html` for unknown paths) and run the flows. `openLink` navigates
  the browser, which reloads a Flutter web app. Maestro 2.7.0 or later reads `id:` from
  `flt-semantics-identifier`, the attribute Flutter's web engine writes for `Semantics(identifier:)`.
- **Android and iOS.** The app must open the link: Android needs the intent filters, iOS the
  associated domains or the URL scheme, which [`fsp links`](#deep-links-and-a-sitemap-fsp-links) writes
  (paste them in, as it says). iOS may ask "Open in ...?" before a custom scheme opens the app; the
  generated flows do not answer it, so prefer an `https` link or start the run with a flow of your own.
- **A guard flow** runs after `launchApp` and before `openLink`: write the sign-in once
  (`.maestro/sign-in.yaml`), give it as `guard_flow`, and every guarded route's flow runs it first.
  On the web `openLink` reloads the app, so the sign-in has to survive a reload (a stored token, not
  in-memory state), or the guard will send the flow back to the login page.

**In CI.** Since 0.8.1 this repository's `web-routes` job builds `examples/shop` for the web (a release build with
`--no-web-resources-cdn`, in a throwaway copy: the examples have no `web/` folder), serves it, and replays
every committed flow in Chromium, with every request that is not to the local server blocked. It reads the
very same YAML: `launchApp`, `openLink`, then it waits for the element whose `flt-semantics-identifier` is
the flow's `id:`, within the flow's `timeout`.

That is not Maestro (the browser is the Chromium that a pinned [Playwright](https://playwright.dev)
installs, and Maestro's own driver is out of the picture), so it can gate a pull request. What it proves is
what fespalier answers for: the identifier reaches the web DOM, `ensureWebSemantics()` ran, the link opens
the route, and its guards, data and deferred chunk let the page build in time. `just web-routes` runs it
(Flutter and Node needed, about two minutes, not part of `just ci`), and `scripts/check-web-routes.sh <example>`
with `ci/web-routes/` is a template for an app's own CI.

To run Maestro itself, build and serve the web app, then run the flows and `fsp maestro --check`. Maestro's
web driver follows Chrome and has broken on Chrome upgrades before (its changelog has Chrome-version fixes
in 2.1.0, 2.2.0 and 2.9.0), so pin the Maestro version, check the download's sha256, and do not make it the
only gate. This repository runs it weekly and on demand (`maestro-web.yml`, Maestro 2.11.0), and a red run
there is not a failed pull request.

```yaml
- run: fsp maestro --check
- run: curl -fsSL "https://get.maestro.mobile.dev" | bash
- run: flutter build web --release --no-web-resources-cdn
- run: python3 -m http.server 8080 --directory build/web &
- run: maestro test --headless .maestro/routes
```

**What is not verified, and what is not built.**

- On the web, CI opens every committed flow's link in Chromium and finds the identifier (`web-routes`,
  since 0.8.1), and a weekly job runs Maestro itself (`maestro-web`, not a gate). The identifier is also
  covered by widget tests (`find.bySemanticsIdentifier`) and the flows by golden files. **On iOS it has
  not been verified in this repository.** If a flow waits and times out on a page you can see, check
  that first.
- No `link:` identifier on `RouteLink` and no `samples` in `meta.dart`.
- A route reached by a query parameter or a localized spelling has no flow of its own.

## Web chunk sizes (`fsp size`)

Since 0.8.1. A [deferred route](navigation.md#deferred-routes-a-pages-code-on-demand) is a
`main.dart.js_N.part.js` on the web, and the chunk files say nothing about which route they belong
to. `fsp size` reads that out of the build, reports what each deferred route costs, and can hold
the build to byte budgets in CI. Build for the web first (`flutter build web`), then:

```sh
fsp size                # report main.dart.js and each deferred route's chunks
fsp size --json         # the same, one JSON object per line
fsp size --check        # CI: non-zero exit when a budget in `size:` is exceeded
fsp size --build out    # a build in another folder (default: `build/web`, or `size.build`)
```

For `examples/shop`, which defers `/checkout` and `/products/:id` (a release build, Flutter 3.47.5):

```text
main.dart.js                                          2384299 B (2.3 MB)  budget 3.0 MB
/checkout      CheckoutRoute  checkout/page.dart      5259 B (5.1 KB)     own 1090 B, shared 4169 B  budget 8.0 KB
/products/:id  ProductRoute   products/$id/page.dart  5982 B (5.8 KB)     own 1813 B, shared 4169 B  budget 8.0 KB
shared  main.dart.js_2.part.js  4169 B (4.1 KB): /checkout, /products/:id
```

```text
✓ size: 6 routes, 2 deferred, 3 parts, within budget
```

(The summary goes to stderr, the report to stdout, so `fsp size > report.txt` keeps the report.)

- **Own** is the bytes of the chunks only this route loads, **shared** the bytes of the chunks it
  loads that other deferred routes load too, and the **total** is both: what a first visit
  downloads when nothing else is loaded. dart2js moves code that several deferred pages use into a
  shared chunk, so one chunk can count for several routes.
- Routes that are not deferred have no line: their code is in `main.dart.js`, which the first line
  reports. The summary counts them (`6 routes, 2 deferred`).
- A chunk that no route loads is listed as `other`, with the deferred imports that do load it (code
  of your own that uses `deferred as`).
- **`--json`** prints one object per line on stdout:
  - `{"kind":"main","file":"main.dart.js","bytes":…,"budget":…}`;
  - then `{"kind":"route","pattern","route","file","parts":[…],"own","shared","bytes","budget"}` for each
    deferred route (`file` is the page, relative to the project, as in `fsp routes --json`; `parts` are
    in dart2js's order);
  - then `{"kind":"part","file","bytes","routes":[…]}` for every chunk (`routes` is empty for an `other` one).
  - `budget` is `null` without one.

**How it knows.** dart2js writes a table of deferred parts into `main.dart.js`, in every build mode:

```text
deferredLibraryParts:{_i7:[0,1],_i14:[0,2]},deferredPartUris:["main.dart.js_2.part.js","main.dart.js_1.part.js","main.dart.js_3.part.js"],
```

The keys are the import prefixes of the generated `app.g.dart` (`import 'app/checkout/page.dart' deferred as _i7;`),
which `fsp` assigns, and each value lists indexes into `deferredPartUris` (not the file
numbering: index 0 is `_2`). `fsp size` knows each deferred route's prefix from the same tree that wrote
the file, and adds up the sizes of the part files on disk. It needs no flag and no special build: it reads
the build you deploy.

**A budget** goes in the `fespalier:` section of `pubspec.yaml`:

```yaml
fespalier:
  size:
    build: build/web # default; the `flutter build web` output, inside the project
    main: 3 MB # main.dart.js
    route: 64 KB # each deferred route's total (own + shared)
    routes: # per route, by pattern as `fsp routes` prints it; wins over `route`
      /checkout: 8 KB
```

- A size is a number of bytes (an integer of at least 1), or a number with a unit: `B`, `KB` (1,024
  bytes) or `MB` (1,048,576 bytes), spelled in capitals, with or without a space, and with a fraction if
  you like: `3 MB`, `1.5 MB`, `64KB`, `900 B`.
- A budget on a route that is not deferred is an error (budget that code with `main`).
- `fsp size --check` reports as above and exits non-zero when anything is over
  (`2 over budget: /checkout, /products/:id`), and also when there is no budget to check.

In CI:

```yaml
- run: flutter build web --release
- run: fsp size --check
```

dart2js's output is deterministic for one Flutter version and one version of your code, so a budget is
a ceiling that holds. A Flutter upgrade moves `main.dart.js` by kilobytes: keep about 30 % headroom on
`main` and raise the budgets deliberately, in the commit that bumps Flutter. This repository does it
(`just web-chunks`, the `web` job: it builds `examples/shop`, runs `fsp size --check` against the budgets in its
pubspec, and cross-checks the attribution with strings that only each deferred page contains).

**A stale build is caught.** The table is keyed by the routes as they were when you built, so a build
older than your routes would be reported against the wrong ones. `fsp size` fails when the keys of the
table are not exactly the prefixes the routes defer now (a deferred route added, removed or moved), and it
warns when `lib/app.g.dart` is newer than `main.dart.js`:

```text
warning: build/web/main.dart.js is older than lib/app.g.dart; if the routes changed since, run `flutter build web` again
```

Every message `fsp size` can print is quoted in the `fespalier-troubleshooting` skill.

**Limits.**

- Sizes are bytes on disk, **not compressed**: a server's gzip or brotli makes each chunk
  several times smaller, in about the same proportion for all of them. Use the numbers to compare
  chunks and to notice growth, not as a download size.
- It reads the JavaScript build (`flutter build web`). A `--wasm` build also writes a
  `main.dart.js` (the fallback), which is what is read; the `.wasm` file is not looked at.
- A load id is the import prefix, and two deferred libraries with the same prefix in one app
  would be told apart by dart2js, not by `fsp size`. The routes' own prefixes are the only ones it
  matches, which is exact for an app whose deferred imports are the generated ones.
- For what is _in_ a chunk, `flutter build web --dump-info` writes `main.dart.js.info.json` (tens of
  megabytes) that a tool like `dart pub global run dart2js_info` reads. `fsp size` does not
  use it.

**Not built:** gzip sizes (`--gzip`), and a mode that reads `main.dart.js.info.json` when it is there,
which would be exact whatever the prefixes are.

`cli/src/size.rs` is the code, `cli/src/size_tests.rs` its tests, and `cli/tests/fixtures/shop-build/main.dart.js`
the excerpt of a real build they read.

## Route smoke tests (`fsp test`)

Since 0.8.1. `fsp test` writes a widget smoke test for every route, into one file,
`test/routes/routes_test.dart`. Each test opens the route at a sample URL with `pumpRouter`, waits until
its page is on screen, and expects exactly one. It proves what a [Maestro flow](#maestro-flows-fsp-maestro)
proves (the route exists, its guards let it through, its data loaded, its page was built) in
`flutter test`, on the VM, with no device and no browser. `fsp test` does not run Flutter: it writes the
file, or with `--check` compares it, as `fsp maestro` does.

The shop example carries it: `examples/shop/test/routes/routes_test.dart` is what `fsp test` wrote, and
`just check-examples` fails when it is stale. This is its first test:

```dart
testWidgets(
  '/products/:id at /products/1',
  (tester) => smokeTestRoute(
    tester,
    '/products/:id',
    AppRoutes.router(
      initialLocation: '/products/1',
    ),
    overrides: setup.overrides(
      '/products/:id',
    ),
  ),
);
```

**What a test does.** `smokeTestRoute` (in `package:fespalier/testing.dart`) runs these steps:

1. `pumpRouter(..., settle: false)`, which also loads the code of every deferred route first.
2. It pumps 100 ms of the test's **fake** clock at a time until the page is on screen. A `data.dart`
   fake that answers after a delay is waited out, and nothing waits on the real clock.
3. It fails after `timeout` (30 s of fake time by default) with
   `The page of /items is not on screen after 30000 ms of fake time: the router is at /sign-in. A guard that redirects, a data.dart that fails or never completes, or an exception while building (above) keeps it away.`
   A guard that redirects, a `data.dart` that fails or never completes, or an exception while building
   the page (Flutter prints it above) is what keeps the page away; the location says where the router
   ended.
4. It expects exactly one page, takes the tree down, and runs the clock `timeout` on, so a fake's pending
   one-shot timer fires with no widget left to react and the test does not end with "A Timer is still
   pending". A _periodic_ timer in a fake still fails the test, which is the right signal.

**How the page is found.** With [`semantics_ids: true`](#maestro-flows-fsp-maestro) the test looks for the
page's `Semantics(identifier: 'route:<pattern>')` with `findRoutePage(pattern)`; it needs no semantics tree,
and a page underneath another is off screen and not found. Without it, a class page is found by its type
(`find.byType`), and the test file imports the page's library; a function page has no type to find, so it is
skipped (printed below). To find a page some other way in a hand-written test, pass `page:` to
`smokeTestRoute`.

**The file and who owns it.**

- The file's first line is
  ``// Written by `fsp test` from lib/app/: don't edit it, run `fsp test` again.`` and `fsp test` writes only
  that file. It never overwrites a file of that name that does not start with the marker: it fails and says
  so (move your file, or set `out`).
- The output is a function of the tree and the pubspec (route-table order, no dates), so `fsp test --check`
  writes nothing and exits non-zero when the file is missing or out of date.
- The second line is `// dart format off`. The file is laid out to need no formatting: a call is split one
  argument to a line, each with a trailing comma, which is what `dart format` leaves alone under an SDK
  older than 3.7 (the short style, which does not read the marker); under 3.7 and later the marker holds
  the formatter off. Either way `dart format --set-exit-if-changed` is clean on it, in every style.

**`test:`** has these keys, all optional. `fsp test` works with no `test:` section at all:

```yaml
fespalier:
  test:
    out: test/routes # default; `test`, `integration_test` or a folder below one
    setup: test/routes/setup.dart # default: <out>/setup.dart, used when it exists
    timeout: 30000 # default; milliseconds of the fake clock a test waits for its page, 1000 to 600000
    samples: # default: `maestro.samples`; same format
      products/$id: 1
    skip: [/admin] # patterns as `fsp routes` prints them
```

**Samples** are the values of the dynamic folders, in the format of
[`maestro.samples`](#maestro-flows-fsp-maestro). When `test.samples` is not there, `maestro.samples` is
used: only that key of `maestro:` is read, so a `maestro:` section that `fsp maestro` would refuse does not
stop `fsp test`. With neither, a route with a dynamic segment is skipped. A sample is percent-encoded and
checked against the segment's type, with the same messages as Maestro's, naming `fespalier.test.samples`
or `fespalier.maestro.samples`, whichever is in use.

**The setup file** is yours: `test/routes/setup.dart` by default, or `test.setup`. `fsp test` only reads
which of two top-level functions it exports, and imports it as `setup` into the test file:

```dart
// test/routes/setup.dart
import 'package:fespalier/testing.dart';

/// Called once per test, so every test gets fresh fakes.
List<Override> overrides(String pattern) => [
  apiProvider.overrideWithValue(FakeApi()),
  // checkout/guard.dart sends an empty cart back to /cart: this one has a line.
  if (pattern == '/checkout') cartProvider.overrideWith(_FullCart.new),
];

/// Optional: the app around the router, for an app that needs its theme or localizations.
Widget app(GoRouter router) => MaterialApp.router(routerConfig: router, theme: appTheme);
```

- `List<Override> overrides(String pattern)` is called once per test with the route's pattern. It
  returns the providers that test boots with (`package:fespalier/testing.dart` exports riverpod's
  `Override` since 0.8.1), and it can vary by route: a signed-in user for a guarded route.
- `Widget app(GoRouter router)` builds the app around the router; the default is
  `MaterialApp.router(routerConfig: router)`. `pumpRouter` takes the same `app:` since 0.8.1.
- Each takes exactly one required positional parameter. A setup file with neither, or with one that takes
  another shape, is an error that says what to write.
- A route with a `guard.dart` at or above it is skipped when there is no `overrides`, because the guard would
  most likely redirect. With `overrides` it gets a test, and a guard that still redirects fails it, naming
  where the router ended.

**Which routes get a test.** Each is checked in this order, and the first that applies wins. Every skip is
printed on every run (and listed in the test file's header), and none of them fails `--check`.

| Route                                             | Result  | Printed                                                                                                                             |
| ------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| A `redirect.dart` route                           | skipped | `skipped /old: a redirect, with no page to see`                                                                                     |
| Listed in `test.skip`                             | skipped | ``skipped /admin: listed in `fespalier.test.skip` ``                                                                                |
| A `$x` or `$$x` segment with no sample            | skipped | ``skipped /products/:id: no sample for products/$id in `fespalier.test.samples` ``                                                  |
| A `guard.dart` at or above it, and no `overrides` | skipped | ``skipped /checkout: guarded by checkout/guard.dart; give test/routes/setup.dart an `overrides(String pattern)` that gets past it`` |
| A function page, and no `semantics_ids`           | skipped | ``skipped /fn: a function page; set `semantics_ids: true` so its test can find it``                                                 |

A route with `const linkable = false;` is tested: the test runs in the process, not through a link. Each
route is opened at its canonical path. The success lines are `✓ test: 6 routes in test/routes/routes_test.dart`
(with `; 1 route skipped` when there are skips, and `(unchanged)` when nothing was written) and, for
`--check`, `✓ test: test/routes/routes_test.dart is up to date (6 routes)`.

**In CI**, next to `fsp check`:

```yaml
- run: fsp test --check
- run: flutter test
```

**Not built.** Query parameters and localized spellings (a route is opened at its canonical path), one
file per route (`flutter test` compiles each test file on its own, so fifty files cost minutes), running
Flutter from `fsp`, and tests of `not_found.dart`. The values of `test:` are checked only by `fsp test`,
so a mistake there never stops `fsp gen`.

## fsp telemetry

`fsp telemetry` writes a local OpenTelemetry stack to `~/.fespalier/telemetry` and runs it with Docker Compose,
with fespalier's dashboards in OpenObserve (and Grafana with `--grafana`). It needs Docker and no project. See
[Dashboards on your computer](telemetry-dashboards.md).

## Performance

Measured on synthetic apps (`cli/src/bench.rs`: sections of 25 routes with layouts and guards, a
`data.dart` on every fifth route, query parameters on every third page, dynamic segments; 5,000 routes are
7,400 files and a 5.8 MB `app.g.dart`), a release build, 4 cores, warm file cache. Re-run them with
`cd cli && cargo test --release bench -- --ignored --nocapture --test-threads=1`. Milliseconds (run to run
they vary by about 15%):

| Routes | `gen` cold | `watch`: a save, output unchanged | `watch`: a save, output changed | `watch`: a file `fsp` doesn't read |
| -----: | ---------: | --------------------------------: | ------------------------------: | ---------------------------------: |
|    500 |         56 |                                28 |                              22 |                                  7 |
|  2,000 |        156 |                               113 |                             108 |                                 28 |
|  5,000 |        429 |                               263 |                             279 |                                 77 |

With `format: true` (`dart format` of the generated file):

| Routes | `gen` cold | `watch`: a save, output unchanged | `watch`: a save, output changed | `watch`: a file `fsp` doesn't read |
| -----: | ---------: | --------------------------------: | ------------------------------: | ---------------------------------: |
|    500 |     1.41 s |                             29 ms |                          1.27 s |                               8 ms |
|  2,000 |     5.05 s |                            104 ms |                          4.93 s |                              30 ms |
|  5,000 |     13.4 s |                            274 ms |                          14.1 s |                              77 ms |

"Output unchanged" is a comment added to a page, which changes the file and not what is generated;
"output changed" changes the type of a query parameter. Where the time goes at 5,000 routes, cold: walking
the folders and reading the files 82, parsing 208 (now spread over the cores), resolving 29, emitting 153
(the model 50, `minijinja` 105), writing 6. And `dart format`, when it is on, dwarfs all of it: 1.4 s at
500 routes, 5.3 s at 2,000, 14 s at 5,000, because the formatter reads the whole file.

What `watch` does about it:

- **Only the files you changed are parsed** (the parse cache), and the first run parses on all cores.
- **A tree the generator has seen isn't resolved or rendered again.** Resolve and emit depend
  on nothing but the scanned folders and their sources, so a run that scans a tree equal to
  the last one reuses its diagnostics and code. Editing a file under `lib/app/` that isn't
  a route file, or saving without changes, costs a walk of the folders. The one input beside
  the folders is the set of files outside the app folder that were read to find enum
  declarations (`enums.rs`); their contents are compared on every run, so an enum renamed or
  deleted there is never served stale.
- **`dart format` runs only on code it hasn't formatted before**, so a save that doesn't change
  the generated code (a `build` method, most of the time) skips it: a save takes the 30 to 270 ms above, about
  what a run without `format:` takes, not the 1.2 to 13 s that formatting the whole file costs. Code that did
  change is formatted in full, because the formatter needs the whole file. If that hurts in a huge app,
  leave `format:` off in `watch` and format in CI.
- Nothing is written when the output is byte-identical to the file on disk.

What it doesn't do, and why: per-route caching of resolved results, and re-scanning only the changed
folders.

- A full resolve is 30 ms at 5,000 routes, a tenth of a save that changes output. Resolving one route
  reads the folders above it and shares state with the others (names claimed, query types settled), so a
  per-route cache would have to replay those effects for a saving smaller than its bookkeeping.
- The walk is 80 ms at 5,000 routes, and reading the files a small part of it. A cache keyed on
  modification times would save less than it risks (an edit in the same timestamp tick, a file replaced by
  one with the same size and time).
