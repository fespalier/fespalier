# CLI reference

Every `fsp` command, the generated file, the editor plugins and `fsp dev`. For `fsp maestro` and `fsp test`, see [Route tests](route-tests.md).

## The generator

```sh
fsp create my_app       # a new Flutter app with fespalier in it, ready to run (since 0.15.0)
fsp init                # first-time setup of an existing app: starter files, then gen
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
fsp new 'orders/[id]/edit' --leave # leave.dart: asked before this page goes; true lets it go (since 0.11.0)
```

All commands take `--project <dir>` (default: the nearest folder with a `pubspec.yaml`). `fsp` is one native binary, fast enough to run on every save (a full scan, check and emit of an example takes a few milliseconds). Install it as described in [Installation and setup](getting-started.md#install-fsp); to build it from source, see [Development](development.md).

### fsp new

`fsp new` writes `page.dart` plus the kinds you ask for with flags. It skips files that already exist, then regenerates `lib/app.g.dart` and prints the result line (if that fails, it lists the files it created).

- **Class names** come from `--name` (default: from the path, e.g. `ProductsId`). A segment that already has a type elsewhere in the tree keeps it.
- **`--function`** writes [function views](file-kinds.md#function-views) instead of classes; `--name` becomes the `routeName` (UpperCamelCase). **`--no-page`** leaves `page.dart` out.
- **`--not-found`** adds a `not_found.dart` that takes the segments of its path as `String`s (see [Not-found views](routing.md#not-found-views)).
- **A `(group)` target** (`'(account)'`) gets no `page.dart`, since a group has no URL of its own. After `fsp new '(account)' --layout` the generator warns "folder has no page.dart and no routes below it; skipped" until you add a route inside the group. That is expected.

`fsp gen`, `check` and `watch` also look at the string paths in `lib/` (see [Checking string paths](#checking-string-paths)).

### fsp create

Since 0.15.0. `fsp create my_app` makes a new Flutter app with fespalier in it, and leaves it with a green `flutter test`:

```sh
fsp create my_app                      # the base app: two pages and a layout
fsp create my_app --org com.example --platforms android,ios,web
fsp create my_app --dry-run            # print every file and command; write and run nothing
fsp create --list-features             # the optional features (--json: one object per line)
```

It needs Flutter 3.32 or newer on `PATH` and a folder that does not exist or is empty (to add fespalier to an app you already have, use [`fsp init`](getting-started.md#fsp-init)). It does not read a project, so `--project` is refused: the folder is the argument.

What it does, in order:

1. `flutter create --empty --no-pub` into a folder next to the app, `.my_app.fsp-create-<pid>`, so a failure leaves nothing behind.
2. Writes `pubspec.yaml` whole (fespalier by git at the tag of the `fsp` you run, `flutter_lints`, a commented [`tasks:`](#tasks-commands-around-flutter-run) example), `lib/main.dart` (`AppMain.run()`) and `lib/app/`: the files [`fsp init`](getting-started.md#fsp-init) writes, plus a home page that links to an about page with a typed route.
3. Moves the folder to `my_app`. This is before `pub get` because the platform files and the package config hold absolute paths.
4. `flutter pub get`, then `fsp gen` and [`fsp test`](route-tests.md) in the same process: `fsp test` needs no `test:` key, so the app starts with a smoke test per route.

If a step before the move fails, the app is not made. If a later one fails, the app stays, and the message says which step failed and the commands that finish the job (`cd my_app`, then `flutter pub get && fsp gen && fsp test`).

| Flag                    | What it does                                                                                                                                                                                                                                   |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--project-name <name>` | The Dart package name. The default is the folder's name, lower case with `-` and spaces as `_`; a name that is a Dart keyword, starts with a digit or is the name of a dependency is refused.                                                  |
| `--org <org>`           | The organization for the Android and iOS identifiers, `flutter create`'s `--org`.                                                                                                                                                              |
| `--platforms <a,b>`     | `android`, `ios`, `linux`, `macos`, `web` and `windows`; the default is all of them.                                                                                                                                                           |
| `--description <text>`  | The pubspec's `description:`.                                                                                                                                                                                                                  |
| `--features <a,b>`      | Optional features to add. A feature another one needs is added with it, with a note; two that conflict are refused; one that needs a newer Flutter than the one installed is refused. There are none yet: `--list-features` shows what exists. |
| `--list-features`       | Print the features and exit, as `id  description` lines, or with `--json` one object per line (`id`, `description`, `flutter`, `requires`, `conflicts`, `companions`).                                                                         |
| `--no-pub-get`          | Write the app and generate, but leave `flutter pub get` to you.                                                                                                                                                                                |
| `--offline`             | Pass `--offline` to `flutter pub get`.                                                                                                                                                                                                         |
| `--dry-run`             | Print the plan (the commands, then every file in full) on stderr and write nothing. It does not run Flutter, so it checks no Flutter version.                                                                                                  |
| `--json`                | Print events to stdout, one JSON object per line, and keep the text for people on stderr (Flutter's own output goes there too).                                                                                                                |

The events of `--json` are `run` (`command`, before each command and, with `--dry-run`, for each one planned), `file` (`path` and `action`, which is `new` or `overwrite`, and with `--dry-run` the file's `content`), `done` (`dir`, `name`, `features` and `dry_run`) and, when the command fails, `error` (`message`).

### fsp routes

`fsp routes` prints what the header of `lib/app.g.dart` lists: each route's URL pattern, its typed route class, its `page.dart` and its tags (a [localized](routing.md#localized-paths) route lists each spelling under its row, `fr  /produits/:id`).

```text
/products/:id  ProductRoute   products/$id/page.dart  (data, transition)
```

The tags are `redirect`, `data`, `action`, `guard`, `layout`, `transition`, `present`, and:

- `observe` (since 0.8.1): an [`observe.dart`](observability.md#route-lifecycle-observedart) at or above the page;
- `leave` (since 0.11.0): a [`leave.dart`](navigation.md#leaving-a-page-leavedart) in the page's own folder;
- `root`;
- `sibling`: a route with [`nest = false`](routing.md#a-sibling-with-a-compound-path);
- `remount`: the page [starts again when its URL changes](navigation.md#remounting-a-page-remount);
- `deferred` (since 0.7.0), always last: its [code loads on demand](navigation.md#deferred-routes-a-pages-code-on-demand);
- `fresh` (since 0.8.1), after `data`: its data has a [`freshness`](data.md#freshness-staletime-resume-and-reconnect);
- `cached` (since 0.8.1): it has a [`dataCache`](data.md#a-cache-that-survives-a-restart-datacache).

**`--graph`** (since 0.5.0) prints the route _tree_ instead, to paste into a README, a pull request or an issue: a Mermaid `flowchart TD` (the default, or `--graph mermaid`; GitHub renders it) or a Graphviz `digraph` (`--graph dot | dot -Tsvg`).

```text
flowchart TD
  subgraph rootnav["root navigator"]
    subgraph b0["layout layout.dart"]
      n0["/<br/>HomeRoute"]
      n1["/cart<br/>CartRoute"]
      n2["/checkout<br/>CheckoutRoute<br/>(guard)"]
      ...
```

The graph shows what `app.g.dart` gives go_router, not the folders. **Nodes** are routes: the URL pattern, the route class, each spelling of a [localized path](routing.md#localized-paths) and the markers (the tags above); a `redirect.dart` route is dashed. **Edges** are nesting: a page is the parent of the routes in the folders below it, a route with [`nest = false`](routing.md#a-sibling-with-a-compound-path) hangs from the page above its parent, and a shell's routes hang from the route above the shell. **Boxes** are navigators: the root navigator, a [layout](file-kinds.md)'s shell (with `data` for a [section](data.md#section-data) and `guard` for its folder's guard) and each branch of a [tab layout](layouts.md#tab-layouts). The output has no timestamp and a fixed order, so a committed graph changes only when the routes do. `--graph` and `--json` cannot be combined.

**`--graph json`** (since 0.7.0) prints the same tree as JSON, with each guard, `redirect.dart`, `data.dart` and `action.dart` as a _site_ the generated code names. The [DevTools extension](devtools.md) reads it, and `app.g.dart` embeds it. Every route has its URL pattern, route class, file and folder (relative to the app folder), markers, typed parameters and each other spelling of a localized path; layouts and tab layouts are items of their own.

**`--json`** prints one JSON object per line, for scripts and editors, with each route's parameters and the [manifest](routing.md#route-manifest-and-metadart)'s fields; `file` is relative to the project root:

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

`fsp gen --json` and `fsp check --json` print each diagnostic to stdout as one JSON object per line, instead of the rendering under [What the commands print](#what-the-commands-print), so an editor can draw squiggles. The success and failure lines still go to stderr, and stdout is empty when there is nothing to report.

```json
{
  "file": "lib/app/shops/$shop/items/$id/page.dart",
  "line": 6,
  "column": 18,
  "severity": "error",
  "message": "can't fill `label`: ..."
}
```

`line` and `column` count from 1 (the column counts characters, not bytes) and are `null` for a diagnostic that isn't about a place in a file. `severity` is `error` or `warning`.

### Formatting

The generated file is not formatted by default, so a committed `app.g.dart` doesn't depend on which Dart SDK ran `fsp`. To format it, use `fsp gen --format` or `format: true` in the pubspec section. It pipes the file through `dart format` (which needs `dart` on your `PATH`; without it `fsp` warns and writes the unformatted code), using your package's language version and `analysis_options.yaml` (`formatter: page_width`). `fsp gen` compares the formatted text with the file on disk, so a formatted file that is up to date stays "unchanged". `fsp watch`, `fsp new` and `fsp init` follow `format:` too; `fsp check` writes and compares nothing, so it never runs `dart`.

### What the commands print

- `fsp gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged` when the output didn't change. With `output_manifest`, or a [generated `main()`](app-startup.md) (since 0.8.1), every file is named: `✓ 12 routes → lib/app.g.dart, lib/app.main.g.dart`.
- `fsp check`: `✓ 12 routes, no errors`.
- `fsp dev` (since 0.9.0): the same `gen` line, then the [full-screen view](#running-your-app-fsp-dev), or with `--no-tui` the lines of each process with its name in front, `[fsp] ✓ 12 routes → lib/app.g.dart (3.1ms)`.
- `fsp watch`: the `gen` line once at startup, then a line each time a save changes `lib/app.g.dart`; an edit that doesn't (a widget's `build` method) prints nothing, and it ignores its own output, so it doesn't loop while idle. It keeps the parse results of files that didn't change, so a save parses only the file you saved, and it also watches the rest of `lib/` (Dart files and folders only), because the enum a segment names is declared there: editing `lib/models/category.dart` regenerates. See [Performance](#performance).

Errors point at the parameter or declaration at fault, and `app.g.dart` is left untouched while there are any. A file that can't be fully parsed gets a warning instead (the Dart compiler reports the exact error), and the generator works with what it could read:

```text
error: can't fill `label`: it isn't a segment of this path ($shop, $id) or data.dart's String
  ┌─ lib/app/shops/$shop/items/$id/page.dart:6:18
  │
6 │   const ItemPage(this.label, {super.key});
  │                  ^^^^^^^^^^

error: `$id` is int in products/$id/data.dart:6 but String here
```

## The generated file

`lib/app.g.dart` is plain go_router and Riverpod code, meant to be read and committed. It opens with a route table (see `examples/shop/lib/app.g.dart`).

- **Types are never re-spelled.** The generator doesn't copy your imports: values flow through inference, and each route's provider is a `static final` whose type is inferred. The exceptions are a [typed `extra`](navigation.md#typed-extra) and an [enum segment or query parameter](routing.md#enum-segments), whose types the typed route has to name; it imports those from the file's imports.
- **Segments and query parameters are parsed into a record** (`({int id, int? page})`), which compares by value, so providers are keyed by it directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`). `(group)` folders fold away completely, apart from the ShellRoute their layout adds.
- **Static routes come first** among siblings, then dynamic ones, then a [catch-all](routing.md#catch-all-segments), so go_router's first match is the most specific one.
- **`AppRoutes.mount(at:)`** only changes the root path (and, with `navigatorKey:`, the root navigator's key). Typed routes read `AppRoutes.base`, so `.location` stays correct when mounted under `/shop`.

## Editor plugins

Two editor plugins show the JSON diagnostics. Neither is on a marketplace yet, so you build them from source. Both use `fsp` from your `PATH`, or `dart run fespalier` when there is none, and check again when you save a file under the app folder (`app_dir`, `lib/app` by default).

- **VS Code:** `editors/vscode/` puts the diagnostics in the Problems panel, with a `fespalier: generate` command and a status bar item; `fespalier.runner` chooses the runner. Build it with `npm install && npm test && npx @vscode/vsce package` in that folder and install the `.vsix` (see `editors/vscode/README.md`).
- **IntelliJ IDEA and Android Studio:** `editors/intellij/` (Kotlin) underlines the problems, with their severity, in the files under the app folder, and adds _Tools | fespalier: Generate_ and _fespalier: Check_; a notification says when `fsp` could not run. Settings | Tools | fespalier chooses the runner (auto, `fsp`, or `dart run fespalier`) and the path to `fsp`. It needs platform 252 (2025.2) or later, and the Dart plugin for highlighting route files (Android Studio includes it). Build it with JDK 21:

  ```sh
  cd editors/intellij
  ./gradlew build buildPlugin      # tests, then build/distributions/fespalier-intellij-<version>.zip
  ```

  Then _Settings | Plugins | gear icon | Install Plugin from Disk..._ and pick the zip. `./gradlew runIde` starts a sandbox IDE with the plugin instead (see `editors/intellij/README.md`).

## Running your app: `fsp dev`

Since 0.9.0. `fsp dev` is `fsp watch` and `flutter run` in one terminal, with no configuration. It writes `lib/app.g.dart`, starts the app, and **hot restarts** it whenever the routes change (a new route needs a restart). Any other save of a Dart file under `lib/` gets a **hot reload**.

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

- The header shows the device, the web address or VM service, and the DevTools link. The status line shows the route count, the first routing error (clickable in terminals that support links), and how long the last hot reload took.
- When flutter stops by itself (a build error, say), the view stays: fix it and press `R`.
- `fsp dev` runs `flutter run --machine` and talks to it over flutter's own protocol, so it works the same on macOS, Linux and Windows. Flutter's other keys (`p`, `w`, ...) live in DevTools (`d`).
- You can still run `fsp watch` next to your own `flutter run`, or your editor's.
- With several devices, `fsp dev` asks which one and remembers the answer in `.dart_tool/fespalier/dev.json`; with one phone or emulator it picks that. To name one yourself: `fsp dev -- -d chrome`.

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

- A command written as a string runs in the shell (`sh` on macOS and Linux, `cmd` on Windows). Written as a list (`[flutter, test]`) it runs with no shell, the same everywhere.
- `fsp` at the start of a command is the `fsp` running the task, even under `dart run fespalier`.
- A list under `before` or `after` is a list of commands, so `before: [dart, run, x]` is three shell commands; write `before: [[dart, run, x]]` for one command with no shell.
- A task that is only `run` can be written as the command itself, as `codegen` is above.
- A custom `run` gets `--machine` and the arguments after `--` appended, but not a device: put `-d` in it, or after `--`.
- A mistake in `tasks:` is reported by `fsp dev`, `fsp build` and `fsp run`, never by `fsp gen`.

### `fsp build` and `fsp run`

`fsp build <target>` runs `fsp gen`, then the `build` task: `before`, `flutter build <target>` (plus your args after `--`), `after`. `fsp run <task>` runs a task of your own; `fsp run` alone lists them. `--dry-run` prints what would run and runs nothing.

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

Outside a terminal (CI, an IDE's run panel), with `TERM=dumb`, or with `fsp dev --no-tui`, `fsp dev` prints each line with the name of the process in front (`[flutter]`, `[fsp]`, `[build_runner]`). You type `r`, `R` or `q` followed by Enter. With several devices and no terminal to ask in, pass one: `fsp dev -- -d <id>`. Quitting asks flutter to stop the app, then stops the `with` commands and everything they started; a second `q` or Ctrl-C stops them at once.

## Deep links and a sitemap (`fsp links`)

Since 0.5.0. `fsp links` writes the lists the platforms want from the route tree, so you don't keep them by hand: the `<intent-filter>`s of Android App Links and `assetlinks.json`, the `apple-app-site-association` file and the entitlement of iOS Universal Links, and a `sitemap.xml`. Say where the app lives in `pubspec.yaml`:

```yaml
fespalier:
  links:
    domains: [shop.example.com] # required; the first one is the sitemap's
    scheme: myshop # optional custom scheme: myshop://shop.example.com/products/2
    scheme_host: true # since 0.11.0; `false`: myshop:///products/2, any host (see below)
    paths: [/, /products/*] # since 0.11.0; default: every linkable route (see below)
    android_package: com.example.shop # with android_sha256: the Android files
    android_sha256: ["AB:CD:...:EF"] # the signing certificates' fingerprints, 32 hex pairs each
    ios_app_id: ABCDE12345.com.example.shop # Team ID, a dot, the bundle id: the iOS files
    android_manifest: android/app/src/main/AndroidManifest.xml # since 0.11.0; opt in: `fsp links` edits it (see below)
    ios_entitlements: ios/Runner/Runner.entitlements # since 0.11.0; opt in: `fsp links` edits its applinks: entries
    # flavors: ...                    # since 0.11.0: instead of the keys for one app above (see Flavours)
    out: links # default: where the files go, relative to the project; `false` (since 0.12.0): no sitemap, no .well-known (see below)
```

It then writes below `out` (`links/` unless you say otherwise; commit it, like `app.g.dart`):

```text
links/
  android/intent-filters.xml                  one <intent-filter android:autoVerify="true"> per domain, one for `scheme`
  ios/associated-domains.entitlements         the applinks:<domain> entries
  ios/info-url-types.xml                      CFBundleURLTypes, with `scheme` and `ios_app_id`
  web/.well-known/assetlinks.json             serve it at https://<domain>/.well-known/assetlinks.json
  web/.well-known/apple-app-site-association  serve it at the same place, as application/json, without a redirect
  web/sitemap.xml                             every static route, on the first domain
```

- The Android files are written when `android_package` is set (it needs `android_sha256`, and the reverse), the iOS ones when `ios_app_id` is, and the sitemap always.
- **`out: false`** (since 0.12.0) writes nothing below `out`: no sitemap, no `.well-known` files, no copies of the snippets. `fsp links` then manages only the [platform files](#editing-androidmanifestxml-and-the-entitlements) you opted into (`android_manifest`, `ios_entitlements`), and `fsp links --check` compares only those, ignoring whatever is left in the old folder (`fsp links` doesn't remove it). `true` is an error. Use it when the app serves its own `/.well-known` files and sitemap. It needs something to manage: without `android_manifest` or `ios_entitlements` it is an error (``leaves `fsp links` nothing to write``). The rest of the config is checked as usual: the first domain still can't be a wildcard, and `ios_app_id` still takes a Team ID. A YAML 1.2 `out: no` is the folder `no/`, not `false`.
- **`android_sha256` is optional with `out: false`** (since 0.12.0): the fingerprints only go into `assetlinks.json`, which isn't written then, so `android_package` can stand alone (the manifest's filters don't need them), and `android_sha256` without `android_package` is still an error. Any you list are still checked. While `fsp links` writes `assetlinks.json`, `android_package` without `android_sha256` is the error ``needs `android_sha256` while `fsp links` writes assetlinks.json``.
- A missing key, or a fingerprint or package that isn't one, is an error that names the key. Only `fsp links` checks them: a mistake there never stops `fsp gen`.
- A file the config no longer asks for is removed by `fsp links` and reported by `--check`.

**What is listed.** Each route's path, in each spelling of its [localized paths](routing.md#localized-paths), and every route in a folder that doesn't say [`const linkable = false;`](configuration.md#per-folder-settings-routedart) (a `route.dart` constant, inherited down the tree). Redirects are opened by the app, so they are in the Android and iOS lists; a sitemap leaves them out.

| Route                         | Android                                    | iOS (`components`)      | Sitemap                  |
| ----------------------------- | ------------------------------------------ | ----------------------- | ------------------------ |
| `/about` (static)             | `android:path="/about"`                    | `/about`                | listed                   |
| `/products/:id`               | `pathPattern="/products/..*"`              | `/products/?*`          | left out                 |
| `/docs/*rest`                 | `pathPrefix="/docs/"`                      | `/docs/?*`              | left out                 |
| `/files/*path?`               | `path="/files"` and `pathPrefix="/files/"` | `/files` and `/files/*` | left out                 |
| `help/` with `{'fr': 'aide'}` | one entry per spelling                     | one entry per spelling  | one `<url>` per spelling |

- **A `$dynamic` segment is a wildcard.** Android's `pathPattern` can't say "one segment", so `/products/..*` also lets `/products/2/extra` through; the app's router has the last word and shows its not-found view. iOS's `?*` is the same. `linkable = false` removes a route's own entries; it can't carve a hole out of the wildcard a dynamic sibling makes (a `$slug` at the root lets every one-segment path in).
- **Localized spellings.** Android gets the characters as written, which it compares with the decoded path (`/führer`); iOS and the sitemap get the percent-encoded form (`/f%C3%BChrer`). The sitemap gives each spelling its own `<url>` with `xhtml:link` `hreflang` alternates for every locale (the canonical path is `x-default`).
- **iOS case.** A [case-insensitive](routing.md#case-and-trailing-slashes) route gets `"caseSensitive": false` in its component (with `paths:`, an entry such a route meets). Android always matches by case.
- **The sitemap lists static routes only.** Dynamic routes and catch-alls have no URL to write down without data fespalier doesn't have. Guards aren't looked at: a route behind a guard is listed, so mark it `linkable = false` if a crawler shouldn't see it.
- **Mounting.** The paths are the routes' own: an app that mounts its routes under a prefix (`AppRoutes.mount(at: '/shop')`) has to put the prefix in front itself.

**Using the files.** Since 0.11.0 `fsp links` can edit `AndroidManifest.xml` and the `.entitlements` files itself, when you [ask it to](#editing-androidmanifestxml-and-the-entitlements). It never edits `Info.plist`, and without those keys it edits nothing: copy the output in yourself.

1. Paste `android/intent-filters.xml` into the `<activity>` of `android/app/src/main/AndroidManifest.xml` that has the `MAIN`/`LAUNCHER` filter (replace what you pasted last time), or set `android_manifest:`.
2. Add the `applinks:` lines of `ios/associated-domains.entitlements` to `ios/Runner/Runner.entitlements`, or set `ios_entitlements:`. Add the entry of `ios/info-url-types.xml` to `Info.plist`. With [flavours](#flavours), do it in each flavour's own `.entitlements` and `Info.plist`.
3. Copy `links/web/` into your Flutter project's `web/` folder (`flutter build web` ships `.well-known/` as it ships the rest), or serve it from wherever the domain's server keeps its files.

Android only verifies a domain when `assetlinks.json` is served over HTTPS at `/.well-known/assetlinks.json` with no redirect.

**Staying current.** The output is a function of the tree and the pubspec (a fixed order, no dates). `fsp links --check` writes nothing and exits non-zero when a file is missing, out of date or no longer wanted, and names it; run it in CI next to `fsp check` ([Links in CI](#links-in-ci)).

### Flavours

Since 0.11.0. An app built in flavours (`prod` and `debug`, each with its own application id, signing certificate and bundle id) lists them instead of the flat keys:

```yaml
fespalier:
  links:
    domains: [shop.example.com]
    scheme: myshop
    android_manifest: android/app/src/main/AndroidManifest.xml # since 0.11.0, one for all flavours (see below)
    flavors:
      prod:
        android_package: com.example.shop
        android_sha256: ["AB:CD:...:EF"]
        ios_app_id: ABCDE12345.com.example.shop
        ios_entitlements: ios/Runner/RunnerProd.entitlements # since 0.11.0, see below
      debug:
        android_package: com.example.shop.debug
        android_sha256: ["12:34:...:56"]
        ios_app_id: ABCDE12345.com.example.shop.debug
        ios_entitlements: ios/Runner/RunnerDebug.entitlements
```

- **Each flavour is an app.** Name it as Gradle does (`prod`, `devStaging`): letters, digits and `_`, starting with a lower-case letter. An empty `flavors:` or a name listed twice is an error. It sets `android_package` (with `android_sha256`, unless `out: false`), `ios_app_id` (with an optional `ios_entitlements`, the file of that flavour) or both. Two flavours can't share a package or an app id.
- **`assetlinks.json`** has one statement per package, in the order the pubspec lists them. **The association file** has one `details` entry whose `appIDs` holds every app id, with the same `components`.
- **The flat keys still work**, as one app with no name (`android_package`, `android_sha256`, `ios_app_id` and `ios_entitlements`): a config with no `flavors:` writes exactly what it wrote before. Setting any of them beside `flavors:` is an error.
- **Domains and the scheme are shared.** A flavour with its own `domains:` is an `invalid pubspec.yaml` error.
- **`info-url-types.xml`** uses the bundle id of the first iOS app.

### Host-less schemes and path patterns

Since 0.11.0.

**`scheme_host: false`** writes the scheme's intent filter with the scheme alone (`<data android:scheme="myshop" />`: no host and no path, since Android ignores path attributes without a host), and makes the default `link:` of [`fsp maestro`](route-tests.md#maestro-flows-fsp-maestro) `myshop://`, so a flow opens `myshop:///orders/42`. The default, `true`, is the `myshop://shop.example.com/orders/42` of before. Prefer the host-less form: the router matches the path only, so `myshop:///orders/42` is `/orders/42` however the embedding hands the link over, while `myshop://orders/42` would be read as host `orders` and reach `/42`. It needs `scheme`.

**`paths:`** lists what the platforms open instead of every linkable route (the sitemap still comes from the routes). Each entry starts with `/`: `/about` is that path, `/orders/*` is everything below `/orders/` (not `/orders` itself), and `*` is only ever the whole last segment (`/*` is everything). An entry is literal: `/orders/:id` and `/orders/$id` are errors (write `/orders/*`), and so are an empty, `.` or `..` segment and any of `?`, `#`, `%`, `\` and whitespace. A component is case-sensitive, except that an entry a [case-insensitive](routing.md#case-and-trailing-slashes) route meets gets `"caseSensitive": false`; Android always matches by case.

| Entry       | Android                 | iOS (`components`) |
| ----------- | ----------------------- | ------------------ |
| `/`         | `android:path="/"`      | `/`                |
| `/about`    | `android:path="/about"` | `/about`           |
| `/orders/*` | `pathPrefix="/orders/"` | `/orders/*`        |

`fsp links` warns, without failing (`--check` doesn't either), where `paths:` and the routes disagree: a linkable route no entry covers (``add `/orders/*`, or `const linkable = false;` in its route.dart``: the entry it suggests is the exact path for a static route, `/orders/*` below a dynamic segment, and both `/files` and `/files/*` for an optional catch-all), and an entry no linkable route matches. An empty list is an error: leave `paths:` out to list every route.

**Maestro and `paths:`.** `fsp maestro` writes a flow for every route, whatever `paths:` lists. With the default `https://` or `scheme://<domain>` link, a flow for a route that `paths:` leaves out can't open on a device (a host-less scheme filter has no paths, so it can). Give those routes no flow with `const linkable = false;`, or ignore them.

### Editing AndroidManifest.xml and the entitlements

Since 0.11.0. Two keys of `links:` make `fsp links` edit the platform files, so the filters and the associated domains are never pasted by hand. Both are opt-in: without them `fsp links` writes only the files below `out`.

```yaml
fespalier:
  links:
    android_manifest: android/app/src/main/AndroidManifest.xml # needs android_package
    ios_entitlements: ios/Runner/Runner.entitlements # needs ios_app_id; per flavour with `flavors:`
```

`android_manifest` is a path to a file called `AndroidManifest.xml` under `android/`, and `ios_entitlements` a `.entitlements` file under `ios/`, both relative to the project. `android_manifest` is top-level only (a flavour's own is an unknown field): the filters are the same for every flavour, and a flavour's manifest in `android/app/src/<flavour>/` is a case for markers by hand. Each flavour names its own `ios_entitlements` (two may name the same file). The domains are the same in every flavour, so each file gets the same entries.

**The manifest.** The intent filters go between two comment markers, in the one `<activity>` that has the `MAIN` intent filter:

```xml
            <!-- fsp links: begin. Written from lib/app by `fsp links`; change links: in pubspec.yaml, not these lines. -->
            <intent-filter android:autoVerify="true">
                ...
            </intent-filter>
            <!-- fsp links: end -->
        </activity>
```

- **The first run** has no markers to go by. It finds the activity with the `MAIN` action (an `<activity-alias>` and anything in a comment don't count) and inserts the block before its `</activity>`, indented four spaces deeper than that line. The file must have exactly one such activity, and the file must exist: `fsp` doesn't create a manifest (`flutter create --platforms android .` does).
- **Later runs** replace only what is between the markers, so a second run changes no byte, and nothing outside them is touched: your other filters, your comments, the file's line endings.
- **Markers must be inside an `<activity>`** (or `<activity-alias>`), both in the same one: Android reads intent filters nowhere else, so markers in `<application>` or split between elements are an error.
- **By hand.** A manifest with several launcher activities, or a flavour manifest of its own, gets the markers where you want them: write `<!-- fsp links: begin -->` and `<!-- fsp links: end -->` on two lines of their own inside the activity that opens links, and run `fsp links`. Those marker lines stay as you wrote them.
- **A filter of your own** for one of the `domains` (or for the `scheme`, with `scheme_host: false`) outside the markers is a warning, with its line: remove it, `fsp links` writes that filter now.

**An entitlements file.** `fsp links` owns **every** `<string>applinks:...</string>` entry of the `com.apple.developer.associated-domains` array, one per domain, and nothing else in the file. An `applinks:` entry you added by hand (a staging domain, `applinks:x.example.com?mode=developer`) is removed on the next run, with a warning that names it: put the domain in `domains:` instead.

- With the key there, only the `applinks:` items are removed and rewritten: the other entries (`webcredentials:`, `activitycontinuation:`), comments and their indentation stay byte for byte, and the new `applinks:` items go before the end of the array, in domain order. An array that already holds exactly them is not touched. An empty `<array/>` is filled. A key whose value isn't an `<array>` is an error: fix it by hand.
- Without the key, the entry goes in before the end of the top-level `<dict>`.
- A file that doesn't exist is written whole (a property list with that one entry), but only when its folder does: with no `ios/Runner/`, it is an error that points at `flutter create --platforms ios .`, so `fsp links` never makes an iOS tree by itself. A file that isn't a property list with a `<dict>` at the top is an error.
- The rest of the file is left as it is: toggling the Associated Domains capability rewrites the file, and the next run splices into what Xcode wrote.
- A file that no `CODE_SIGN_ENTITLEMENTS` (spelled plainly, or with `$(SRCROOT)/`, `${SRCROOT}/`, `$(PROJECT_DIR)/`, `$(SOURCE_ROOT)/` or `./` in front) in `ios/Runner.xcodeproj/project.pbxproj` names is a warning: no build uses it. Add the Associated Domains capability in Xcode, or point the build setting (per flavour configuration) at the file.

A file that isn't UTF-8 is an error (`{path} is not UTF-8; fsp links edits only UTF-8 files`): the edit writes the whole file back, and a lossy rewrite would change bytes outside the markers. Files are written through a temporary file and a rename, so an interrupted run never leaves one empty. The copies below `out` say, when a platform file is managed, that `fsp links` does the pasting. A filter with `tools:node="remove"` or `"removeAll"` is not warned about.

`Info.plist` stays by hand, for the `CFBundleURLTypes` entry of `ios/info-url-types.xml`.

**Flutter's deep linking switch (since 0.12.0).** `fsp links` and `fsp links --check` read, and never edit, two settings that stop Flutter from handing links to the router: `<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />` (any value but `true`, inside the `<activity>`) in `AndroidManifest.xml` (the file `android_manifest:` names, else `android/app/src/main/AndroidManifest.xml` when an Android app is configured), and `FlutterDeepLinkingEnabled` set to `<false/>` (or `<string>NO</string>`, `<integer>0</integer>`) in `ios/Runner/Info.plist` (when an iOS app is configured). Each is a warning that doesn't fail `--check`: `flutter_deeplinking_enabled is false in {manifest}: Flutter will not hand links to the router (intended with a deep-link plugin: ...)`, and the same for `FlutterDeepLinkingEnabled is false in ios/Runner/Info.plist`. A deep-link plugin asks for the switch off on purpose; see [With a deep-link plugin](navigation.md#with-a-deep-link-plugin-app_links-branch). Flutter has had deep linking on by default since 3.27, so an app that never set the key is quiet.

**`--check`.** `fsp links --check` works out each platform file's edited text, compares it with the disk, writes nothing, and exits non-zero when one is stale. It says `{path} has no fsp links markers yet` for a manifest the first run hasn't reached, `{path}: the intent filters between the fsp links markers are out of date`, `{path}: the applinks: entries of com.apple.developer.associated-domains are out of date` or `{path} is missing`. A missing manifest is an error rather than a stale file, and the warnings don't fail it. When all is current it prints `✓ links: 5 files in links are up to date, and 2 platform files`.

### Links in CI

Since 0.11.0. Run `fsp links --check` next to `fsp check`, so a new route or a changed domain can't ship with a manifest, an entitlement or an association file that still says the old thing:

```yaml
- run: dart run fespalier check && dart run fespalier links --check
```

With the platform files opted in, the same step also fails when someone changed a route and forgot to run `fsp links`, or hand-edited the lines between the markers. The fix is the one command locally: `dart run fespalier links`, and commit the result. Warnings (a filter outside the markers, an entitlements file no build uses, a `paths:` entry no route matches) print but don't fail the step.

## Checking string paths

Since 0.7.0. A typed route can't be misspelled, but a string path is sometimes the right thing (a CMS link, a notification payload), and `context.go('/prodcts/2')` compiles, runs and shows `not_found.dart`. So `fsp gen`, `check` and `watch` read the string paths your code gives the router and warn about one that **matches no route**. A path that matches is fine: typed routes are preferred, not forced. ([Why `fsp` and not an analyzer plugin](faq.md#why-string-paths-are-checked-by-fsp-not-an-analyzer-plugin).)

```text
warning: no route matches `/prodcts/2`, so it shows not-found; did you mean `/products/2`? [unknown_path]
  ┌─ lib/screens/home.dart:2:14
  │
2 │   context.go('/prodcts/2');
  │              ^^^^^^^^^^^^
```

**What is checked.** A string literal in one of these places: the first argument of `.go(...)`, `.push(...)`, `.pushReplacement(...)` or `.replace(...)` on anything (`context.go('/x')`, `GoRouter.of(context).push<int>('/x')`, `router..go('/x')`); `RouteLink(uri: Uri.parse('/x'))`; and `initialLocation:` of `AppRoutes.router(...)` or `GoRouter(...)`. Not these: a bare `go('/x')` with no receiver, `goNamed` and `pushNamed`, `Navigator.pushNamed`, the typed routes, `TabOptions(initialLocation:)` (the generator already checks it against the tab), and `AppRoutes.match`, `matchUrl`, `dataAt` and `preload`, which exist to ask about any location. A path that is built (`'/a' + b`) or held in a variable is not a literal and is not read.

**What matches.** The same rules as `AppRoutes.match`: segments and [catch-alls](routing.md#catch-all-segments) (`$$rest` needs one part, `$$$rest` none); [case](routing.md#case-and-trailing-slashes) by the route's own setting; every [localized spelling](routing.md#localized-paths), mixed ones too; non-ASCII paths and `%` escapes decoded, a trailing slash or `//` ignored; a `redirect.dart` is a route, a `not_found.dart` is not; the query and the fragment are not looked at; and the first route that fits the path decides.

Since 0.8.1 segment **types are checked** too, the way the route parses them. `/products/abc` reaches `products/$id`, and with `{required int id}` that route shows not-found, so it is reported (`` `/products/abc` reaches /products/:id, but `abc` is not an int, so it shows not-found [unknown_path] ``). An app with `unknown_path: error` that passed on 0.7.0 can fail on 0.8.1 for a path that always showed not-found.

- `int`, `double`, `num`, `bool`, `DateTime` (its start only) and [enum](routing.md#enum-segments) segments are checked, and each part of a typed [catch-all](routing.md#typed-catch-alls). An enum's message lists its values and suggests the nearest.
- A part with a space or other non-ASCII whitespace is not judged (Dart trims it before parsing).
- The message names the route by its canonical pattern, also for a localized spelling.

**Interpolation.** A path that interpolates is checked up to its first `$`: `'/products/$id'` is fine and `'/prodcts/$id'` is flagged (`no route starts with ...`). The complete segments before the `$` are checked by type too (`'/products/abc/$tab'` is reported), but nothing after a `$` is, since the value can be empty or hold a `/`.

**Skipped.** A path that is not an app path: a relative one (`'details'`), a URL (`'https://...'`), one that starts with an interpolation (`'$base/x'`), one with a `..` or a malformed `%` escape.

**Which files.** Every Dart file under `lib/` (the app folder included), except the generated ones (`*.g.dart`, the `output` and `output_manifest`) and folders that start with a `.`. Not `test/`, `integration_test/` or `bin/`: tests navigate to paths that match nothing on purpose, to try `not_found.dart`, and mount the tree under prefixes the app doesn't use.

**The mount point.** `AppRoutes.mount(at: '/shop')` is read, and a path is checked below it: `/shop/products/2` is looked up as `/products/2`. A path outside the mount point belongs to the host router (`legacyRoutes` beside `...AppRoutes.mount(at: '/shop')`) and is skipped. When `at:` is not a string literal, or two calls give two different values, the check reports nothing for the run. A host router with routes of its own and the tree mounted at `/` gets a warning for those routes' string paths: silence them as below, or turn the lint off.

**Severity.** `lints:` in the `fespalier:` section of `pubspec.yaml`:

```yaml
fespalier:
  lints:
    unknown_path: warning # default; `error` fails `fsp gen` and `fsp check`; `off` skips the check
```

A warning never fails a command, so a false positive can't break a build. With `error`:

- `fsp check` exits 1 (``1 error(s) in string paths (`lints: unknown_path: error`)``).
- So do `fsp gen` and `fsp watch`, after they write the output (`...; lib/app.g.dart is up to date`): a typo in some other file does not stop `watch` from regenerating.
- `fsp new` and `fsp init` report it as a warning at most.
- If the route tree itself has errors, the check doesn't run: a half-resolved tree would make every path look unknown.

**Silencing one.** A comment on the line above, or after the path on its own line:

```dart
TextButton(
  // fsp:ignore unknown_path -- gift cards aren't built yet: not_found.dart shows
  onPressed: () => context.go('/gift-cards'),
  child: const Text('Gift cards'),
),
```

A comment on a line of its own covers the call that starts on the next line, however long it is; one after code covers that line. `// fsp:ignore-file unknown_path` anywhere in a file silences the file. The lint's id, `unknown_path`, is what both and `lints:` name; it is also the last word of the message. Both editor plugins show it in the file it is about, and check again when any Dart file under `lib/` is saved.

## Web chunk sizes (`fsp size`)

Since 0.8.1. A [deferred route](navigation.md#deferred-routes-a-pages-code-on-demand) is a `main.dart.js_N.part.js` on the web, and the chunk files say nothing about which route they belong to. `fsp size` reads that out of the build, reports what each deferred route costs, and can hold the build to byte budgets in CI. Build for the web first (`flutter build web`), then:

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

- **Own** is the bytes of the chunks only this route loads, **shared** the bytes of the chunks it loads that other deferred routes load too, and the **total** is both: what a first visit downloads when nothing else is loaded. dart2js moves code that several deferred pages use into a shared chunk, so one chunk can count for several routes.
- Routes that are not deferred have no line: their code is in `main.dart.js`, which the first line reports. The summary counts them (`6 routes, 2 deferred`).
- A chunk that no route loads is listed as `other`, with the deferred imports that do load it (code of your own that uses `deferred as`).
- **`--json`** prints one object per line on stdout: `{"kind":"main","file":"main.dart.js","bytes":…,"budget":…}`; then `{"kind":"route","pattern","route","file","parts":[…],"own","shared","bytes","budget"}` for each deferred route (`file` is the page, relative to the project; `parts` are in dart2js's order); then `{"kind":"part","file","bytes","routes":[…]}` for every chunk (`routes` is empty for an `other` one). `budget` is `null` without one.

**How it knows.** dart2js writes a table of deferred parts into `main.dart.js`, in every build mode:

```text
deferredLibraryParts:{_i7:[0,1],_i14:[0,2]},deferredPartUris:["main.dart.js_2.part.js","main.dart.js_1.part.js","main.dart.js_3.part.js"],
```

The keys are the import prefixes of the generated `app.g.dart` (`import 'app/checkout/page.dart' deferred as _i7;`), and each value lists indexes into `deferredPartUris` (not the file numbering: index 0 is `_2`). `fsp size` knows each deferred route's prefix from the same tree that wrote the file, and adds up the sizes of the part files on disk. It needs no flag and no special build: it reads the build you deploy.

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

- A size is a number of bytes (an integer of at least 1), or a number with a unit: `B`, `KB` (1,024 bytes) or `MB` (1,048,576 bytes), in capitals, with or without a space, with a fraction if you like: `3 MB`, `1.5 MB`, `64KB`, `900 B`.
- A budget on a route that is not deferred is an error (budget that code with `main`).
- `fsp size --check` reports as above and exits non-zero when anything is over (`2 over budget: /checkout, /products/:id`), and also when there is no budget to check.

In CI:

```yaml
- run: flutter build web --release
- run: fsp size --check
```

dart2js's output is deterministic for one Flutter version and one version of your code, so a budget is a ceiling that holds. A Flutter upgrade moves `main.dart.js` by kilobytes: keep about 30 % headroom on `main` and raise the budgets deliberately, in the commit that bumps Flutter.

**A stale build is caught.** The table is keyed by the routes as they were when you built, so a build older than your routes would be reported against the wrong ones. `fsp size` fails when the keys of the table are not exactly the prefixes the routes defer now (a deferred route added, removed or moved), and it warns when `lib/app.g.dart` is newer than `main.dart.js`:

```text
warning: build/web/main.dart.js is older than lib/app.g.dart; if the routes changed since, run `flutter build web` again
```

Every message `fsp size` can print is quoted in the `fespalier-troubleshooting` skill.

**Limits.**

- Sizes are bytes on disk, **not compressed**: a server's gzip or brotli makes each chunk several times smaller, in about the same proportion for all of them. Use the numbers to compare chunks and to notice growth, not as a download size.
- It reads the JavaScript build. A `--wasm` build also writes a `main.dart.js` (the fallback), which is what is read; the `.wasm` file is not looked at.
- The routes' own import prefixes are the only ones it matches, which is exact for an app whose deferred imports are the generated ones.
- For what is _in_ a chunk, `flutter build web --dump-info` writes `main.dart.js.info.json` (tens of megabytes) that a tool like `dart pub global run dart2js_info` reads; `fsp size` does not use it.

## fsp telemetry

`fsp telemetry` writes a local OpenTelemetry stack to `~/.fespalier/telemetry` and runs it with Docker Compose, with fespalier's dashboards in OpenObserve (and Grafana with `--grafana`). It needs Docker and no project. See [Dashboards on your computer](telemetry-dashboards.md).

## Performance

Measured on synthetic apps (sections of 25 routes with layouts and guards, a `data.dart` on every fifth route, query parameters on every third page; 5,000 routes are 7,400 files and a 5.8 MB `app.g.dart`), a release build, 4 cores, warm file cache; milliseconds, varying by about 15% from run to run ([how to re-run](development.md)):

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

"Output unchanged" is a comment added to a page, which changes the file and not what is generated; "output changed" changes the type of a query parameter. `dart format`, when it is on, dwarfs all of it, because the formatter reads the whole file.

What `watch` does about it:

- **Only the files you changed are parsed** (the parse cache), and the first run parses on all cores.
- **A tree the generator has seen isn't resolved or rendered again**: a run that scans a tree equal to the last one reuses its diagnostics and code, so editing a file under `lib/app/` that isn't a route file, or saving without changes, costs a walk of the folders. The files outside the app folder that were read to find enum declarations are compared on every run, so a renamed or deleted enum is never served stale.
- **`dart format` runs only on code it hasn't formatted before**, so a save that doesn't change the generated code skips it: a save takes the 30 to 270 ms above, not the 1.2 to 13 s that formatting the whole file costs. Code that did change is formatted in full. If that hurts in a huge app, leave `format:` off in `watch` and format in CI.
- Nothing is written when the output is byte-identical to the file on disk.

`watch` does not cache per route: [why](faq.md#why-fsp-watch-doesnt-cache-per-route).
