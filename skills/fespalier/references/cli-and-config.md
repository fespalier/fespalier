# The `fsp` CLI, its config, and how to run it

As of v0.4.0 (`fsp --version` prints `fsp` and the version, e.g. `fsp 0.4.0`).

## Commands

Every command takes `--project <dir>`; the default is the nearest folder, at or
above the current one, with a `pubspec.yaml` (none: `no pubspec.yaml here or
above; pass --project`).

| Command                       | What it does                                                                                                                                                                 |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fsp init`                    | Writes `layout.dart`, `page.dart`, `not_found.dart`, `transition.dart` under `lib/app/` (never overwrites: `skip  ... (exists)`), then `gen`, then prints what is left to do |
| `fsp gen [--format] [--json]` | Checks `lib/app/` and writes `lib/app.g.dart`; `--format` pipes it through `dart format`                                                                                     |
| `fsp check [--json]`          | The same checks; **writes nothing** and never runs `dart`; non-zero exit on errors. What CI runs                                                                             |
| `fsp watch`                   | `gen` once, then again on every relevant change; keep it next to `flutter run`                                                                                               |
| `fsp routes [--json]`         | Prints the route table (errors: `N error(s); no route table`)                                                                                                                |
| `fsp links [--check]`         | Writes App Links, Universal Links and a sitemap files from the route tree and the `links:` config; `--check` writes nothing and fails when they are stale (since 0.5.0)      |
| `fsp routes --graph [FORMAT]` | Prints the route tree as a Mermaid `flowchart TD` (`mermaid`, the default) or a Graphviz `digraph` (`dot`), since 0.5.0                                                      |
| `fsp new <path> [flags]`      | Scaffolds a route, skips files that exist, then runs `gen`                                                                                                                   |

What they print, to stderr unless noted:

- `gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged`
  (with `output_manifest`, both files are named). On errors:
  `N error(s); lib/app.g.dart left unchanged` and exit code 1.
- `check`: `✓ 12 routes, no errors`.
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
  since 0.4.0) and `remount` (a page that starts again when its URL changes, since 0.6.0), in that order. `routes --json` prints, per line, in
  this order: `pattern`, `route`, `file`, `tags`, `params` (`{name, type, in}`
  with `in` of `path` or `query`), `folder`, `presentation` (`page`, `redirect`,
  `root`, `custom`), `groups`, `layouts`, `tabs`, `data_keys`, `meta`,
  `catch_all`, then `remount` (`on_segments` or `on_location`, since 0.6.0) **only** for a route
  that remounts, and `paths` **only** for a route with localized segments.

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
committed. `--graph` cannot be combined with `--json`, and a value other than `mermaid`
or `dot` is a usage error that lists both.

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

### `fsp new`

```sh
fsp new 'products/[id]' --name Product --data --action --loading --error --layout --guard --transition
fsp new '(account)' --layout        # a group: no page.dart
fsp new 'kyc/shop/name' --function --name KycShopName
fsp new 'shop' --not-found
fsp new 'docs/[...rest]'            # $$rest; 'docs/[[...rest]]' is $$$rest
```

Flags: `--name`, `--function`, `--data`, `--action` (`action.dart`, since 0.5.0),
`--loading`, `--error`, `--layout`, `--not-found`, `--guard`, `--transition`, `--no-page`. A `(group)` target gets no
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
  data_retry: inherit
  keep_previous: true
  push_updates_url: false   # since 0.6.0
  file_style: snake
  meta: optional
  # meta_unique: [code]
  # output_manifest: lib/app.routes.g.dart
  # links: {domains: [shop.example.com]}   # see `fsp links` above
```

| Key                | Values                                  | Effect                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------ | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `app_dir`          | a path under `lib/`                     | Where the tree is. Not under `lib/`: `` `fespalier.app_dir` must be a path under lib/ (it is imported as package code) ``                                                                                                                                                                                                                                                      |
| `output`           | a `.dart` path under `lib/`             | Where `app.g.dart` goes: `` `fespalier.output` must be a .dart file ``                                                                                                                                                                                                                                                                                                         |
| `format`           | `true` / `false`                        | Run `dart format` on the output (needs `dart` on `PATH`; without it `fsp` warns and writes the unformatted code)                                                                                                                                                                                                                                                               |
| `case_sensitive`   | `true` / `false`                        | `false` emits `caseSensitive: false` on every route; a `route.dart` overrides it per folder                                                                                                                                                                                                                                                                                    |
| `remount`          | `never` / `on_segments` / `on_location` | When a page gets a fresh state because its URL changed (since 0.6.0): `on_segments` when a segment's value changes, `on_location` on any change, the query included; a `route.dart` overrides it per folder. See `fespalier-routing`. Another value: `` invalid pubspec.yaml: fespalier.remount: unknown variant `x`, expected one of `never`, `on_segments`, `on_location` `` |
| `data_retry`       | `inherit` / `none`                      | `none` gives generated `data()` providers `retry: (retryCount, error) => null`. See `fespalier-data`                                                                                                                                                                                                                                                                           |
| `keep_previous`    | `true` / `false`                        | `false` shows `loading.dart` on every reload. See `fespalier-data`                                                                                                                                                                                                                                                                                                             |
| `push_updates_url` | `true` / `false`                        | Since 0.6.0. `true` puts a `push`ed route's URL in the browser's address bar: `router()` sets `GoRouter.optionURLReflectsImperativeAPIs = true` (`false` otherwise, on every call). See `fespalier-routing`                                                                                                                                                                    |
| `file_style`       | `snake` / `kebab`                       | What `fsp init` and `fsp new` write: `not_found.dart` or `not-found.dart`. Reading accepts both                                                                                                                                                                                                                                                                                |
| `meta`             | `optional` / `required`                 | `required`: a route without `meta.dart` is an error                                                                                                                                                                                                                                                                                                                            |
| `meta_unique`      | list of argument names                  | No two routes may pass the same **literal** for that named argument of `meta`'s constructor call                                                                                                                                                                                                                                                                               |
| `output_manifest`  | a `.dart` path under `lib/`             | Writes `AppManifest` to a library of its own (it may not equal `output`)                                                                                                                                                                                                                                                                                                       |
| `links`            | a map (keys above)                      | What `fsp links` writes; only that command checks the values (since 0.5.0)                                                                                                                                                                                                                                                                                                     |

There is no key for `extraCodec`: `lib/app/extra_codec.dart` is found by name.

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
  `runApp`, and a server that serves `index.html` for unknown paths.
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
  `PATH`, else `dart run fespalier`.
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
