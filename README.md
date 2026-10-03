# fespalier

File-tree routing for Flutter, in the spirit of Next.js. An espalier is a tree
trained flat against a frame; here the frame is `lib/app/`.

You write plain widgets and functions in small files under `lib/app/`. There are no
base classes or interfaces to implement: the file name says what a file is, and its
constructor says what it needs. The `fsp` generator reads every file, works out what
each parameter should receive, checks that the files fit together, and writes one
mountable `lib/app.g.dart`. It's built on go_router, Riverpod and flutter_hooks,
with no build_runner.

```text
lib/main.dart            Future<void> main() => AppMain.run();           (the whole main(), since 0.8.1)
lib/app/
  app.dart               App({required GoRouter router})              the MaterialApp.router around the router (root only, optional)
  startup.dart           Future<List<Override>> startup()             before the app: overrides, observers, a zone (root only, optional)
  splash.dart            Splash({Object? error, VoidCallback? retry})   while startup() runs, and when it fails (root only, optional)
  layout.dart            AppLayout({required Widget child})           → ShellRoute
  page.dart              HomePage()                                   → /
  loading.dart           RootLoading()                                  (inherited)
  error.dart             RootError({required Object error, required VoidCallback retry})
  not_found.dart         NotFoundPage({required Uri uri})               (optional, in any folder)
  transition.dart        Page<void> transition(LocalKey key, Widget child)  (inherited)
  route.dart             const caseSensitive = false;                   (inherited: this folder and below match in any case)
  products/
    route.dart           const paths = {'fr': 'produits', 'de': 'produkte'};  (this folder also answers /produits, /produkte)
    data.dart            final data = FutureProvider<List<Product>>(…)
    page.dart            ProductsPage({required List<Product> products})  → /products
    loading.dart         ProductsLoading()
    $id/
      data.dart          Future<Product> data(Ref ref, {required int id})
      page.dart          ProductPage({required Product product})       → /products/:id
      action.dart        Future<void> action(Ref ref, {required int id, required Refund input})   (a write)
      error.dart         ProductError({required int id, required Object error, …})
      meta.dart          const meta = PageMeta(code: 'B04', …)         (this route's facts, any const)
  checkout/
    guard.dart           GuardResult guard(Ref ref)                     (guards this and below)
    page.dart
  old-products/$id/
    redirect.dart        String redirect({required int id})            → /old-products/:id redirects
  greet/$name/page.dart  GreetPage({required String name})
  docs/$$rest/page.dart  DocsPage({required List<String> rest})       → /docs/a, /docs/a/b, …
  compare/$$ids/page.dart  ComparePage({required List<int> ids})       → /compare/3/7 (each part an int)
  (account)/             a group: its layout wraps profile/ and settings/,
    layout.dart            but adds nothing to their URLs (/profile, /settings)
    profile/page.dart
    settings/page.dart
  teams/$teamId/         no page: its layout and data.dart cover the section below
    data.dart            Future<Team> data(Ref ref, {required String teamId})
    layout.dart          TeamLayout({required Team team, required Widget child})
    members/page.dart    MembersPage(this.team)                       → /teams/:teamId/members
    not_found.dart       TeamNotFound({required Uri uri})             (for unknown paths below)
  _components/           private: never routes
```

```dart
// the whole app entry point (since 0.8.1): lib/main.dart runs the main() fsp generates
Future<void> main() => AppMain.run();

// or by hand
MaterialApp.router(routerConfig: AppRoutes.router());

// or inside an existing GoRouter (brownfield)
GoRouter(routes: [...legacyRoutes, ...AppRoutes.mount(at: '/shop')]);

// typed navigation, generated from the tree
ProductRoute(id: 42).go(context);
const SearchRoute(q: 'ap', page: 2).go(context);   // → /search?q=ap&page=2
ProductRoute(id: 42).go(context, locale: 'fr');    // → /produits/42 (`location` stays /products/42)

// each route's data.dart, as a Riverpod provider
ref.watch(ProductRoute.data(42));
ProductRoute.watch(ref, id: 42);             // the same, typed: AsyncValue<Product>
await ProductRoute.read(ref, id: 42);        // Future<Product>
final warm = ProductRoute(id: 42).prefetch(ref);   // start loading before navigating; warm.close() lets go
await const ProductsRoute().refresh(ref);

// each route's action.dart: a write with pending and error state, then the data it made stale reloads
await ProductRoute.submit(ref, id: 42, input: refund);             // Future<Refund>, throws what it threw
final refund = ProductRoute.useAction(ref, id: 42);               // for build(): .state is AsyncValue<Refund?>

// from a location to what it reads (an app's own prefetch queue, tests): no guard runs, no widget is built
AppRoutes.dataAt(Uri.parse('/products/42'));    // [ProductRoute.data(42)]; null when no route fits
AppRoutes.match(Uri.parse('/products/42'));     // RouteMatch: the RouteInfo, the parsed params, the data
```

## Getting started

You need Flutter 3.32 or newer (Dart 3.8) for the package. go_router 18 needs Flutter
3.44 or newer.

**1. Install the CLI.** On Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
```

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION=v0.8.1` <!-- x-release-please-version -->
to pick a release (the default is the latest) and `FSP_INSTALL_DIR=/some/dir` to install
elsewhere. On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/fespalier/fespalier/main/install.ps1 | iex
```

It puts `fsp.exe` in `%LOCALAPPDATA%\fespalier\bin` (tell it otherwise with
`$env:FSP_INSTALL_DIR`, pick a release with `$env:FSP_VERSION`), checks the SHA-256, and
prints how to add that folder to your `PATH` if it isn't there yet. With Rust installed, on
any platform:

<!-- x-release-please-start-version -->

```sh
cargo install --git https://github.com/fespalier/fespalier --tag v0.8.1 fespalier
```

<!-- x-release-please-end -->

With Homebrew (macOS, Linux) or Scoop (Windows), from the tap and the bucket that releases push to
(see [Releasing](#releasing)):

```sh
brew tap fespalier/tap && brew install fsp   # or in one go: brew install fespalier/tap/fsp
scoop bucket add fespalier https://github.com/fespalier/scoop-bucket && scoop install fsp
```

They hold the latest release only once it has pushed to them. Scoop also installs a manifest
straight from a URL, so without the bucket (or before it has the release) the `fsp.json` that
every release attaches does the same, and it names that release's archives and their SHA-256s:

```powershell
scoop install https://github.com/fespalier/fespalier/releases/latest/download/fsp.json
```

To update that one, `scoop uninstall fsp` and run it again. Homebrew has no such fallback:
`brew install` reads formulae from taps only (a path is refused by default, `brew install
./fsp.rb`, see `HOMEBREW_FORBID_PACKAGES_FROM_PATHS`, and a URL is no longer accepted), so
`fsp.rb` is only useful to a tap. Where the tap has no release yet, macOS users use the install
script above.

**Or install nothing.** Once the package is in your `pubspec.yaml` (step 2), `dart run
fespalier <command>` runs `fsp` for you, so use it wherever this README says `fsp`:
`dart run fespalier init`, `dart run fespalier watch`, `dart run fespalier check`. The first
run downloads the `fsp` release that matches the package's version, checks its SHA-256 and
keeps it in your user cache (`~/.cache/fespalier` on Linux, `~/Library/Caches/fespalier` on
macOS, `%LOCALAPPDATA%\fespalier` on Windows; `FSP_CACHE_DIR` moves it), so later runs start
at once. The download is checked against the SHA-256 that this package carries for its own
version, so a tampered release is refused (a package built from a branch has no pins yet; it
then checks the release's `.sha256` file instead and says so). Offline with an empty cache it
stops with one line naming the missing version; with a warm cache it never uses the network.
It needs `tar`, which macOS, Linux and Windows 10+ include. Set `FSP_BINARY=/path/to/fsp`
to run a binary of your own, e.g. a build from source. An `fsp` on your `PATH` is used too when its
version is the package's, so nothing is downloaded when you have both. The package and the
binary are versioned together, and this is what keeps them in step.

**2. Add the package** to your app's `pubspec.yaml`, then run `flutter pub get`:

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
```

<!-- x-release-please-end -->

It depends on go_router (17 or 18), hooks_riverpod 3 and flutter_hooks, and
`package:fespalier/fespalier.dart` re-exports all three, so you don't add them yourself.

**3. Run `fsp init`** in the project root:

```sh
fsp init
```

It creates `lib/app/layout.dart`, `page.dart`, `not_found.dart` (`not-found.dart` with
[`file_style: kebab`](#file-names)), `transition.dart` (every
route animates with the Material transition) and, since 0.8.1, `app.dart` (the `MaterialApp.router`
around the router; not with [`main: manual`](#main-appdart-startupdart-and-splashdart)), and writes
`lib/app.g.dart` and, from `app.dart`, `lib/app.main.g.dart`. It never
overwrites a file that exists: those are reported as `skip`.
It then prints what is left to do (the dependency block above, if `pubspec.yaml` doesn't
have it yet, and this `main.dart`). `not_found.dart` is optional: without it, unknown
paths get a plain "Nothing at /path" view. Other folders can have their own (see
[Not-found views](#not-found-views)).

```dart
import 'package:my_app/app.main.g.dart';

Future<void> main() => AppMain.run();
```

`AppMain` is generated from `lib/app/app.dart` (and `startup.dart` and `splash.dart`, if you
add them): it starts the app inside a `ProviderScope`, builds the router once and runs
`runApp`. See [`main()`: app.dart, startup.dart and splash.dart](#main-appdart-startupdart-and-splashdart).
Before 0.8.1 `fsp init` printed a `main()` that built the `ProviderScope` and the
`MaterialApp.router` itself, and that still works: it is what `main: manual` keeps.

A plain `flutter create` (not `flutter create --empty`) also wrote `test/widget_test.dart`,
which refers to the `MyApp` you just replaced, so `flutter analyze` fails on it. Delete it,
or rewrite it (see [Testing](#testing)).

Already have a `GoRouter`? Mount the tree inside it instead, and set `main: manual` so that `fsp`
writes no `main()` of its own. `at` is the URL prefix:

```dart
GoRouter(
  navigatorKey: rootKey,
  routes: [...yourRoutes, ...AppRoutes.mount(at: '/x', navigatorKey: rootKey)],
)
```

Pass `mount` your `GoRouter`'s own `navigatorKey`: routes that render on the
[root navigator](#the-root-navigator-navigatordart) name it as their `parentNavigatorKey`,
which go_router requires to be an ancestor navigator's. (`AppRoutes.router()` takes a
`navigatorKey:` too, and either way the key is `AppRoutes.rootNavigatorKey`.)

**4. Day to day.**

```sh
fsp dev                                   # the app, regenerated and hot restarted on every save (since 0.9.0)
fsp watch                                 # or next to your own `flutter run`: regenerates when the routing changes
fsp new 'orders/[id]' --data --loading    # scaffold a route, then regenerate app.g.dart
fsp new 'orders/[id]/refund' --action     # a write beside the page (action.dart)
```

`fsp new` runs `gen` right away, so the new route is usable as soon as it returns. See
"The generator" for all flags, and [Running your app](#running-your-app-fsp-dev) for `fsp dev`.

**Two ways to keep `app.g.dart`.** Pick one.

_Commit it_ (the default). `lib/app.g.dart` is plain code, meant to be read, and the app
builds without `fsp` installed. In CI, run `fsp check`. It writes nothing (it never touches
`app.g.dart`) and exits non-zero on routing errors. It does **not** compare the committed file
with what the tree would generate, so it passes when `lib/app.g.dart` is stale; the end of this
section has a check that fails then.

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
```

or, with nothing to install (after `flutter pub get`): `- run: dart run fespalier check`.

_Generate, don't commit._ For projects that never commit generated code (`**/*.g.dart` is
ignored already, and every generator runs before analysis). Add the file to `.gitignore`:

```gitignore
lib/app.g.dart
```

and generate it wherever the app is analyzed, tested or built: on a fresh clone, and in CI
**before** `flutter analyze`, because `app.g.dart` doesn't exist until then:

```yaml
- run: flutter pub get
- run: dart run fespalier gen # writes lib/app.g.dart; fails on routing errors
- run: flutter analyze
- run: flutter test
```

The generator version needs no pin of its own: `dart run fespalier` runs the `fsp` release
that matches the `fespalier` package your `pubspec.lock` resolved, so the generator and the
runtime `app.g.dart` imports can't drift apart, and bumping the package bumps the generator.
The first run downloads it (SHA-256 pinned in the package, see above) into the user cache;
keep `~/.cache/fespalier` (`FSP_CACHE_DIR`) between CI runs with `actions/cache`, keyed on
`pubspec.lock`, to skip that. Set `FSP_BINARY` to use a binary you built. Locally,
`dart run fespalier watch` keeps the file current. `fsp check` still works in this mode
(it checks the routing and writes nothing), and doesn't need the generated file to exist.

_To fail CI on a stale committed file_, regenerate it and fail on any difference. `fsp gen`
follows `format:` in the pubspec, so the result is what you would commit:

```yaml
- run: fsp gen
- run: git diff --exit-code lib/app.g.dart
```

**Config.** `fsp` needs no configuration. To move things, add this optional section to
`pubspec.yaml`. Both paths are relative to the project root and must be under `lib/`, and
`output` must be a `.dart` file. These are the defaults:

```yaml
fespalier:
  app_dir: lib/app
  output: lib/app.g.dart
  format: false
  case_sensitive: true
  remount: never # `on_segments` | `on_location`
  data_retry: inherit
  keep_previous: true
  deferred: false # `true` (since 0.7.0): each page's code loads on demand on the web
  push_updates_url: false # `true` (since 0.6.0): a `push`ed route's URL is in the address bar
  file_style: snake
  lints: # since 0.7.0: see "Checking string paths"
    unknown_path: warning # `error` | `off`: a string path that matches no route
  meta: optional # `required`: every route needs a meta.dart
  # meta_unique: [code]       # no two routes may pass the same literal `code:` to `meta`
  # output_manifest: lib/app.routes.g.dart   # no default: the manifest lives in `output`
  # links:                        # no default: what `fsp links` writes (see below)
  #   domains: [shop.example.com]
  #   scheme: myshop
  #   android_package: com.example.shop
  #   android_sha256: ["AB:CD:..."]
  #   ios_app_id: TEAMID.com.example.shop
  #   out: links                  # default
  semantics_ids: false # `true` (since 0.7.0): every page wears `Semantics(identifier: 'route:/...')`, for Maestro
  scroll_restoration: false # `true` (since 0.8.1): the browser's back and forward bring a page's scroll offsets back
  main: auto # `generated` | `manual` (since 0.8.1): whether `fsp` writes the main() in lib/app.main.g.dart
  telemetry: false # `true` (since 0.8.1): report navigations, guards, data, actions and deferred loads (see "Telemetry")
  # maestro:                      # no default: what `fsp maestro` writes (see below)
  #   url: http://localhost:8080  # the web; or `app_id: com.example.shop` for Android and iOS
  #   link: http://localhost:8080/#
  #   out: .maestro/routes        # default
  #   guard_flow: .maestro/sign-in.yaml
  #   timeout: 20000              # default, in milliseconds
  #   samples:
  #     products/$id: 1
  # size:                         # no default: what `fsp size` checks the web build against (since 0.8.1)
  #   main: 3 MB                  # main.dart.js
  #   routes:
  #     /checkout: 8 KB           # a deferred route's own and shared chunks
  # test:                         # no default, and `fsp test` works without it: see below
  #   out: test/routes            # default; `test`, `integration_test` or a folder below one
  #   setup: test/routes/setup.dart   # default: <out>/setup.dart, used when it exists
  #   timeout: 30000              # default, in milliseconds of the test's fake clock
  #   samples:                    # default: the `maestro:` ones
  #     products/$id: 1
  #   skip: [/admin]              # patterns as `fsp routes` prints them
  # tasks:                        # no default: what `fsp dev`, `fsp build` and `fsp run` run (since 0.9.0)
  #   dev:
  #     before: dart run build_runner build -d
  #     with:
  #       build_runner: dart run build_runner watch -d
  #   codegen: dart run build_runner build -d
```

`format: true` runs `dart format` on the generated file (see [`fsp gen --format`](#the-generator)).
`case_sensitive: false` makes paths match in any case, and a [`route.dart`](#case-and-trailing-slashes) sets that
per folder (see [Case and trailing slashes](#case-and-trailing-slashes)); the same file gives a folder
[other spellings per locale](#localized-paths) with `paths`.
`remount` (since 0.6.0) is `never`, `on_segments` or `on_location`: when a page gets a fresh state
because its URL changed; a `route.dart` sets it per folder (see
[Remounting a page](#remounting-a-page-remount)). Any other value is an error that lists the three.
`deferred` (since 0.7.0) is `true` or `false`: whether each page's code loads on demand (`import ... deferred as`,
a chunk of its own on the web); a `route.dart` sets it per folder (see
[Deferred routes](#deferred-routes-a-pages-code-on-demand)). A value that isn't a bool is an error.
`data_retry` and `keep_previous` are about `data.dart` failures and reloads; see
[Retries and reloads](#retries-and-reloads). `file_style: kebab` makes `fsp init` and `fsp new`
write `not-found.dart` instead of `not_found.dart` (see [File names](#file-names)).
`push_updates_url: true` (since 0.6.0) makes the generated `AppRoutes.router()` set go_router's
`GoRouter.optionURLReflectsImperativeAPIs`, so on the web a typed route's `push` puts its URL in the
address bar (and in the browser's history) as `go` does, and back pops it. The generated code
assigns the flag on every `router()` call, `true` or `false` (the default, go_router's own), so it
is the same in every app and every test, wherever the router is built. go_router warns about the
cost: that URL is all the browser keeps, so a reload or a deep link of it builds that route's
_own_ stack, not the stack it was pushed onto. In fespalier every route is a typed path, so the URL
is always a valid page. Without the key, `push` leaves the address bar on the page below; use
[`go` or `replace`](#the-url-as-state-of-and-copywith) for state that belongs in the URL.
`meta: required` makes a route without a [`meta.dart`](#route-manifest-and-metadart) an error,
`meta_unique` makes a duplicate value in it one, and
`output_manifest` writes the route manifest to a library of its own (same section).
`links:` is what [`fsp links`](#deep-links-and-a-sitemap-fsp-links) reads; only that command checks its values.
`lints:` (since 0.7.0) sets how [a string path that matches no route](#checking-string-paths) is
reported: `unknown_path` is `warning` (the default), `error` or `off`.
`semantics_ids` (since 0.7.0) and `maestro:` are about [Maestro](#maestro-flows-fsp-maestro): the first
changes the generated file, the second is read, and checked, only by `fsp maestro`.
`scroll_restoration` (since 0.8.1) is `true` or `false`: whether each page is wrapped in a `PageStorage` that the
browser's back and forward button hand back (see [Scroll restoration](#scroll-restoration)). A value that isn't a
bool is an error.
`size:` (since 0.8.1) is what [`fsp size`](#web-chunk-sizes-fsp-size) checks the web build against; only that command checks its values.
`test:` (since 0.8.1) is what [`fsp test`](#route-smoke-tests-fsp-test) reads, and only that command checks it.
`tasks:` (since 0.9.0) is what [`fsp dev`, `fsp build` and `fsp run`](#tasks-commands-around-flutter-run) run: commands to run
before, next to and after `flutter run`. Only those commands check it; `fsp gen` never reports a mistake in it.

`main` (since 0.8.1) is `auto`, `generated` or `manual`: whether `fsp` writes [`lib/app.main.g.dart`](#main-appdart-startupdart-and-splashdart),
with `AppMain`. `auto` writes it when the app folder's root has an `app.dart`, `startup.dart` or `splash.dart`,
`generated` always, `manual` never (and then those three files are not read). Any other value is an error that lists
the three: ``unknown variant `always`, expected one of `auto`, `generated`, `manual` ``. The file sits beside
`output`, with `.main.g.dart` in place of `.g.dart` (`lib/router/routes.g.dart` makes `lib/router/routes.main.g.dart`);
there is no key for the path, and `output_manifest` cannot be it.

`telemetry` (since 0.8.1) is `true` or `false`: whether the generated file tells fespalier where each guard,
data provider, action and deferred page is, and follows the router's navigations (see
[Telemetry](#telemetry)). A value that isn't a bool is an error.
The router's [`extraCodec`](#restoring-extra-on-the-web) has no key: `lib/app/extra_codec.dart` is
found by its name, like the other files.

**Platform notes.**

- **Web URLs.** Flutter web uses hash URLs (`/#/products/1`) unless you switch to path
  URLs. Add `flutter_web_plugins: {sdk: flutter}` to `dependencies` and call
  `usePathUrlStrategy()` (from `package:flutter_web_plugins/url_strategy.dart`) before
  `runApp`, or, with the generated `main()` (since 0.8.1), as the first line of `startup()`: the
  router is only built after it. Your web server must also serve `index.html` for unknown paths.
- **go_router 18 and Material.** go_router 18 checks for `MaterialApp` from
  `package:material_ui`, not the one in `package:flutter/material.dart`. With Flutter's
  `MaterialApp`, it treats your app as a plain widgets app: routes without a
  `transition.dart` don't animate at all, and go_router's own error screen is unstyled.
  go_router 17 checks Flutter's `MaterialApp` and has no such problem. There are two ways
  around it:
  - Have a root `lib/app/transition.dart` that says how routes animate, e.g.
    `Page<void> transition(LocalKey key, Widget child) => Transitions.material(key, child);`
    (or `cupertino`). `fsp init` already adds this file. It works with either
    `MaterialApp`, and it's the easy fix.
  - Or use `MaterialApp` from `package:material_ui` (add `material_ui` to `dependencies`).
    It has its own `Theme` and localizations, which widgets from
    `package:flutter/material.dart` don't read, so it only makes sense if you import
    `package:material_ui/material_ui.dart` everywhere. Mixing the two loses your theme.

  Or stay on go_router 17 by adding `go_router: ^17.0.0` to your `dependencies`. The
  examples use Flutter's `MaterialApp` and each has a root `transition.dart` returning
  `Transitions.material`, so their routes animate on both go_router 17 and 18.

## Running your app: `fsp dev`

Since 0.9.0. `fsp dev` is `fsp watch` and `flutter run` in one terminal. It writes `lib/app.g.dart`, starts the
app, and **hot restarts** it whenever the routes change, because a new route needs a restart. Any other save of a
Dart file under `lib/` gets a **hot reload**. It needs no configuration.

```sh
fsp dev                  # pick a device, run the app, keep app.g.dart current
fsp dev -- -d chrome     # anything after -- goes to flutter run
```

![fsp dev: a header with the app, the device and the DevTools link; a tab per process; the flutter log; a status line with the route count, the last generation and the last hot restart; the keys.](docs/images/fsp-dev.svg)

| Key            |                                                                     |
| -------------- | ------------------------------------------------------------------- |
| `r` / `R`      | hot reload / hot restart                                            |
| `d` / `o`      | open DevTools / open the app in the browser (web)                   |
| `t`            | start [`fsp telemetry`](#dashboards-on-your-computer-fsp-telemetry) |
| `Tab`, `1`–`9` | switch between flutter, fsp and your own processes                  |
| `/`            | filter the log; `Esc` clears                                        |
| `?` / `q`      | help / quit                                                         |

The header shows the device, the web address or VM service, and the DevTools link. The status line shows the
route count, the first routing error (clickable in terminals that support links), and how long the last hot
reload took. When flutter stops by itself (a build error, say), the view stays: fix it and press `R`.

`fsp dev` runs `flutter run --machine` and talks to it over flutter's own protocol, so it works the same on macOS,
Linux and Windows. Flutter's other keys (`p`, `w`, ...) live in DevTools (`d`). You can still run `fsp watch` next
to your own `flutter run`, or your editor's.

With several devices, `fsp dev` asks which one (and remembers the answer in `.dart_tool/fespalier/dev.json`); with
one phone or emulator it picks that, as `flutter run` does. Name one yourself after `--`: `fsp dev -- -d chrome`.

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

A command written as a string runs in the shell (`sh` on macOS and Linux, `cmd` on Windows). Written as a list
(`[flutter, test]`) it runs with no shell, the same everywhere. `fsp` at the start of a command is the `fsp`
running the task, even under `dart run fespalier`. A mistake in `tasks:` is reported by `fsp dev`, `fsp build`
and `fsp run`, never by `fsp gen`.

A list under `before` or `after` is a list of commands, so `before: [dart, run, x]` is three shell commands
(`dart`, `run` and `x`); write `before: [[dart, run, x]]` for one command with no shell. A task that is only
`run` can be written as the command itself, as `codegen` is above. A custom `run` gets `--machine` and the
arguments after `--` appended, but not a device: put `-d` in it, or after `--`.

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

Outside a terminal (CI, an IDE's run panel), with `TERM=dumb`, or with `fsp dev --no-tui`, `fsp dev` prints each
line with the name of the process in front (`[flutter]`, `[fsp]`, `[build_runner]`), and you type `r`, `R` or `q`
followed by Enter. With several devices and no terminal to ask in, pass one: `fsp dev -- -d <id>`. Quitting asks
flutter to stop the app, then stops the `with` commands and everything they started. A second `q` or Ctrl-C stops
them at once.

## File kinds

Each view file exports one widget class, of any kind: `StatelessWidget`,
`ConsumerWidget`, `HookConsumerWidget` and so on, or a [top-level function](#function-views)
that returns a widget. Function files export one top-level function. Other public classes may sit
in the file as long as exactly one of them extends a `…Widget` class (a `class Helper {}` beside a
`StatelessWidget` is fine); when `fsp` can't tell which is the view it says "expected one public
widget class" and lists them. Make helpers private (`_Name`) rather than lean on that.

| File               | Exports                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Its constructor / signature can ask for                                                                                                                       |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `page.dart`        | a widget                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | segments; query; what `data.dart` yields; the navigation [`extra`](#typed-extra)                                                                              |
| `data.dart`        | `data(Ref ref, {…})` returning `Future<T>`, `Stream<T>` or `T` — **or** `ProviderListenable<AsyncValue<T>> data({…})` selecting a provider you have — **or** `final data = <Provider>(…)`. Beside a `page.dart` it feeds the page; in a page-less folder with a `layout.dart`, the whole [section](#section-data)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | segments, query (named)                                                                                                                                       |
| `action.dart`      | `action(Ref ref, {…, required Input input})` (any number of functions of that shape) returning `Future<T>`, `FutureOr<T>` or `T`, and optionally `const invalidates = [...]`. Beside a `page.dart` it is that route's [write](#actiondart-typed-writes); in a page-less folder with a `layout.dart`, the [section's](#actiondart-typed-writes)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | segments, query (named), and the one `input`                                                                                                                  |
| `loading.dart`     | a widget, inherited by subfolders                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | segments; query                                                                                                                                               |
| `error.dart`       | a widget, inherited by subfolders                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | segments; query; `error`, `stackTrace`, `retry`                                                                                                               |
| `layout.dart`      | a widget; wraps this folder and below (ShellRoute), or holds its subfolders as tabs. A tab layout can also export a [`container`](#tab-layouts) function                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | `child` or `navigationShell`; segments at or above it; query; the [section data](#section-data) it wraps or is inside; the navigation [`extra`](#typed-extra) |
| `guard.dart`       | `GuardResult guard(Ref ref, {…})`; `GuardResult` is `FutureOr<String?>`: a location to redirect to, or `null` to let the navigation through. Guards every route at and below its folder, and runs again when what it `ref.watch`es changes (since 0.5.0; `ProviderContainer c` first is the older form, read once)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `uri`; segments at or above its folder; query (named); `extra`                                                                                                |
| `redirect.dart`    | `String redirect({…})` in place of `page.dart`: a route that only redirects; may take `Ref ref` first (since 0.5.0), or `ProviderContainer c`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `uri`; segments; query (named); `extra`                                                                                                                       |
| `observe.dart`     | `void onEnter(Ref ref, {…})`, `onLeave` and `onFocus` (any of them): run for every page at and below its folder when it is entered, left and focused (since 0.8.1). See [Route lifecycle](#route-lifecycle-observedart)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | `Ref ref` first; segments at or above its folder; query (named); `uri`; `TypedLocation route`                                                                 |
| `transition.dart`  | `Page<…> transition(…)`; applies to this folder and below, layouts' shells included                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `key`, `child`, `state`, `shell` (a `bool`)                                                                                                                   |
| `present.dart`     | `Page<…> present(…)`: the app builds this route's own page (a sheet, say), on the [root navigator](#presentdart-a-page-of-your-own); this folder only                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `key`, `child`, `state`                                                                                                                                       |
| `navigator.dart`   | `const navigator = RouteNavigator.root;`: this folder and below [render on the root navigator](#the-root-navigator-navigatordart)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | nothing: it is data                                                                                                                                           |
| `not_found.dart`   | a widget, optional, in any folder ([nearest wins](#not-found-views); without one at the root, a plain "Nothing at /path" view); unknown paths and unparsable segments                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `uri`                                                                                                                                                         |
| `meta.dart`        | `const meta = <any const expression>;`, beside a `page.dart` or `redirect.dart`: that route's own facts, passed [untouched into the manifest](#route-manifest-and-metadart)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | nothing: it is data                                                                                                                                           |
| `extra_codec.dart` | at the root of the app folder only: a top-level `extraCodec`, the `Codec<Object?, Object?>` the router saves an [`extra`](#restoring-extra-on-the-web) with                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | nothing: it is data                                                                                                                                           |
| `app.dart`         | at the root of the app folder only (since 0.8.1): a widget (any kind) that gets the `router` and builds the `MaterialApp.router` around it; optionally `GoRouter router()` too. [`AppMain.app`](#main-appdart-startupdart-and-splashdart)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `router` (a `GoRouter`); other parameters must be optional                                                                                                    |
| `startup.dart`     | at the root of the app folder only (since 0.8.1): `startup()` (before the app; may return the `Override`s), `zone()`, `providerObservers`, `routerObservers`, `retry()`; at least one                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | nothing: `startup()` takes no parameters                                                                                                                      |
| `splash.dart`      | at the root of the app folder only (since 0.8.1): a widget shown while an async `startup()` runs, and when it fails                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `error`, `stackTrace`, `retry` (each nullable: null while `startup()` runs)                                                                                   |
| `route.dart`       | `const caseSensitive = <true or false>;` in any folder: whether paths match by case in this folder and below, [the nearest one winning](#case-and-trailing-slashes) over the pubspec's `case_sensitive`; and/or `const paths = {'fr': 'produits'};` in a static folder: [its other spellings per locale](#localized-paths); and/or `const nest = false;` beside a `page.dart` or `redirect.dart`: [its route is a sibling of the page above, not a child](#a-sibling-with-a-compound-path); and/or `const linkable = false;` (since 0.5.0): [`fsp links`](#deep-links-and-a-sitemap-fsp-links) leaves this folder's routes and those below it out, [the nearest one winning](#case-and-trailing-slashes); and/or `const remount = Remount.onSegments;` (since 0.6.0): [when the pages in this folder and below get a fresh state because their URL changed](#remounting-a-page-remount), the nearest one winning over the pubspec's `remount`; and/or `const deferred = true;` (since 0.7.0): [the pages in this folder and below load their code on demand](#deferred-routes-a-pages-code-on-demand), the nearest one winning over the pubspec's `deferred`; and/or `const freshness = Freshness(staleTime: Duration(minutes: 5));` (since 0.8.1): [the default for when the data.dart functions in this folder and below load again](#freshness-staletime-resume-and-reconnect), the nearest one winning, a data.dart's own over all. Read from the source, never imported | nothing: it is data                                                                                                                                           |
| `nav.dart`         | in any folder (since 0.8.1): `const nav = Nav(label: 'Products', order: 1);` — how the folder shows in the generated [menus and breadcrumbs](#menus-and-breadcrumbs-navdart) (`AppMenu`) — and optionally `String label(BuildContext context, {…})`, the label shown, localized. Read from the source (its `order` and the segments `label()` asks for); a folder with no page is a heading                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | nothing: it is data; `label()` takes a `BuildContext` and the segments of its folder and above (named, `required`)                                            |

Since 0.8.1 an `action.dart` may also hold the companions of an action: its [`form()`, `validate()`](#forms-form-and-validate) and [`optimistic()`](#optimistic-updates-optimistic). They are functions in that file, not a file kind.

### Function views

`page.dart`, `loading.dart`, `error.dart`, `layout.dart` and `not_found.dart` can export a
top-level function named after the file, returning a `Widget`, instead of a widget class:

```dart
// lib/app/(kyc)/shop/name/page.dart
import 'package:my_app/screens/kyc/legal_name_screen.dart';

Widget page() => const LegalNameScreen(audience: KycAudience.shop);
```

```dart
// lib/app/(buyer)/orders/$orderId/cancel/page.dart
Widget page({required String orderId, String? back}) =>
    CancelOrderScreen(orderId: orderId, back: back);
```

That is one route per file, however many routes build the same screen, and the screen can
stay where it is (`lib/screens/…`) instead of moving into `lib/app/`. The function's
parameters are filled exactly like a constructor's ([below](#how-parameters-are-filled)):
segments and query parameters by name, `data` by name or by type, `child` or a shell for a
`layout()`, `error`, `stackTrace` and `retry` for an `error()`, `uri` for a `notFound()`.
Named and positional parameters both work, and a binding error points at the parameter.

- **Names.** `page()`, `loading()`, `error()`, `layout()` and `notFound()` (`not_found()`
  too). Other functions in the file are helpers and are ignored.
- **One form per file.** A file with a public widget class _and_ the function is an error that
  names both; the class form is unchanged. To use the function, keep the widget in another
  file (or make it private) and build it from the function.
- **No hooks, no `ref`.** A function view is a plain function: it has no `BuildContext` and no
  `WidgetRef` (asking for one is an error that says so). Hooks and `ref` belong in the
  widget it returns, which is where they were anyway.
- **The route class name.** A class names its route after itself (`ProductPage` →
  `ProductRoute`), but many functions build the same screen, so a `page()` takes the
  folder path, ignoring `(group)` folders and joining the segments in PascalCase:
  `(kyc)/shop/name/page.dart` is `ShopNameRoute`, `orders/$orderId/cancel/page.dart` is
  `OrdersOrderIdCancelRoute` (the root is `RootRoute`). To pick another, put a string
  literal in `page.dart`:

  ```dart
  const routeName = 'KycShopName'; // KycShopNameRoute
  Widget page() => const LegalNameScreen(audience: KycAudience.shop);
  ```

  It must be an UpperCamelCase name (the route class is `<routeName>Route`), and it also
  renames a class-form page's route. The [route manifest](#route-manifest-and-metadart) lists the
  route under this name, and `meta.dart` works beside a function page. Two routes with the same name are an error that
  suggests `routeName`.

- **`export` isn't followed.** `page.dart` has to hold the function itself, so it stays the
  source of truth for the route.

`fsp new 'shop/name' --function` scaffolds the function form (`--name KycShopName` writes the
`routeName`). `examples/features` has two routes, `(plans)/free` and `(plans)/pro`, serving one
screen with different constants.

### File names

The one file kind with two words is `not_found.dart`. Reading takes it in kebab-case too,
`not-found.dart`, whatever the configuration says, so a project that names every Dart file in
kebab-case can keep to that, and a tree that mixes the two still works. Both in one folder
is an error with a code frame for each file. Diagnostics, `fsp routes` and the header of
`app.g.dart` name a file as it is spelled on disk.

`file_style: snake | kebab` (default `snake`) only picks what `fsp init` and `fsp new` write.
The single-word kinds (`page.dart`, `layout.dart`, …) have one spelling.

### How parameters are filled

The generator reads each constructor (named or positional, `this.x` or typed) and fills
every parameter:

1. **By name.** A parameter named like a `$segment` in the path gets that segment.
   `data`, `child`, `navigationShell` (or `shell`), `error`, `stackTrace`, `retry`, `uri`
   and `extra` (in a page, a layout, a guard or a redirect) get what their name says, in the
   files where they make sense.
2. **Query.** An _optional_ parameter that is nullable or a `List` of
   `String`/`int`/`double`/`bool` (or of an [enum](#enum-segments)) is a query parameter:
   `int? page` gets `?page=2`, and `List<String> tags = const []` gets every `?tags=`.
3. **By type.** Otherwise, a page's parameter whose type is what `data.dart` yields gets
   the data, so `required this.product` with `final Product product;` works. (A page or
   layout below a [section](#section-data) can take the section's data the same way.) An error
   view's `Object` gets the error, `StackTrace` the stack trace and `VoidCallback` the
   retry. A layout's `Widget` gets the child, its `StatefulNavigationShell` gets the tab shell, and
   not-found's `Uri` gets the URI.
4. **Otherwise**, a required parameter is a generator error pointing at it. An optional
   one is left to its default.

These names are reserved, so segments can't use them. Parameters bound by name are
type-checked: `uri` must be a `Uri`, `child` a `Widget`, `error` an `Object`, `stackTrace`
a `StackTrace`, `retry` a `VoidCallback`, `navigationShell` a `StatefulNavigationShell`,
and a transition's `key` and `state` a `LocalKey` and a `GoRouterState`. Declaring one as
anything else is an error at that parameter (`Object` and `dynamic` always fit).

### Segment types

A segment's type comes from the parameters that ask for it: `{required int id}` in
`products/$id/data.dart` makes `$id` an `int` everywhere. That covers the typed
`ProductRoute(id: 42)`, the page, and parsing: `/products/abc` goes to `not_found.dart`.
Every file that asks for `$id` must agree on its type. When nobody gives one, a segment
is a `String`. Segments are `String`, `int`, `double`, `bool` or an [enum](#enum-segments) of your
app. (A [catch-all](#catch-all-segments) is a `List` of those, or of `num` or `DateTime`.)

`fsp new` scaffolds every segment as a `String`: `fsp new 'products/[id]' --data` writes
`data(Ref ref, {required String id})`. To make `$id` an `int`, change the parameter type
in each file that asks for it, then run `fsp gen` (or let `fsp watch` do it).

### Enum segments

A segment, a [query parameter](#query-parameters) and the parts of a [catch-all](#catch-all-segments)
can be an enum of your app. The parameter is typed with it, in the file that asks:

```text
shop/$category/page.dart   /shop/shoes              category == Category.shoes
                           /shop/socks              not found: `socks` isn't a Category
browse/$$categories/       /browse/shoes/hats       categories == [Category.shoes, Category.hats]
```

```dart
enum Category { shoes, hats }        // in the file that uses it, or in any file it imports

class ShopPage extends StatelessWidget {
  const ShopPage({super.key, required this.category, this.sort});
  final Category category;           // the segment
  final Sort? sort;                  // the query: /shop/shoes?sort=price
}

const ShopRoute(category: Category.hats, sort: Sort.price).go(context);   // → /shop/hats?sort=price
```

- **Read by name.** A value is the one whose `name` the text spells (`Category.values.byName`).
  A segment or catch-all part that names no value sends the route to `not_found.dart`, like a
  bad `int` (`BadSegment`): the page is never built (and a guard that reads segments or query
  parameters is skipped, see [Guards](#guards)). A query parameter
  that names none is `null`, or left out of a list, like any query parameter that doesn't parse.
- **Case follows the route.** Names match exactly by default. Where the route's paths match in
  any case ([`case_sensitive: false`, or a `route.dart`](#case-and-trailing-slashes)) `/shop/SHOES`
  is `Category.shoes` too (in a query parameter as well). A name that matches exactly always
  wins, so an enum with `a` and `A` still tells them apart.
- **Written by name.** `.location` writes `.name`, for a segment, each part of a catch-all
  (encoded on its own, like any part) and a query parameter, and the typed route's field has the
  enum's type.
- **Finding the enum.** Nothing in a syntax tree says that `Category` is an enum, so `fsp gen`
  reads the declaration: in the file that names the type (`page.dart`, `data.dart`, `guard.dart`,
  …), or in a file it imports, through `export`s too (a barrel file). It reads relative imports and
  `package:` imports of your own package, which are files under `lib/`; `dart:` and other packages
  are not read. A type it doesn't find an enum for (a class, one from another package, one that
  isn't imported) is an error at the parameter that suggests the `String` to take instead and
  parse in the page, and so is a private enum (`_Mode`), which the generated file couldn't name.
  An import prefix (`m.Category`) is followed through that import only.
- **Imports in `app.g.dart`.** The generated file names the type the way it does a
  [typed `extra`](#typed-extra): from the declaring file's own import when the enum is in the
  view file, otherwise through `import '…' show Category;` (or `as _es2_m` for a prefixed one)
  lines that follow the view's imports.
- **The type must agree across files.** `Category` in `page.dart` and `Size` in `data.dart` is
  the error a mismatched `int` is (`` `$category` is Size in data.dart:1 but Category here ``);
  `Category` and `m.Category` are the same type when they name the same enum, and two enums that
  share a name are not.
- **`data.dart` can be keyed by an enum.** An enum is hashable, so `{required Category category}` keys
  the provider by the enum itself, and `ShopRoute.watch(ref, category: Category.hats)` takes it. A
  `List<Category>` catch-all is keyed by its path, like any catch-all, and `data()` gets the list
  back; a `List<Category>` query parameter is keyed by a `QueryList`, as for any list.
  `AppRoutes.match(uri).params` and `AppRoutes.dataAt` have the enum values.
- **The manifest and `fsp routes --json`** show the type by name (`Category`, `List<Category>`,
  `Sort?`), without the prefix or alias it was imported under.

Limits: an enum is read by `name` only (a `static Category? fromSegment(String)` convention to
read another spelling may come later). A parameter that is `Sort sort = Sort.price` (not
nullable) isn't a query parameter, as for `int`, and an _optional_ nullable parameter of a type
that `fsp` finds no enum for is still left to its default rather than being an error, since it may
be plain widget configuration (`Color? color`): it is when a `data.dart`, `guard.dart` or
`redirect.dart` asks for it that the error comes. `fsp watch` also watches the rest of `lib/`, so
adding or editing an enum anywhere under it regenerates (for one outside `lib/`, run `fsp gen`).
`fsp new` below an enum segment writes its type name into the new files, and you add the import.

`examples/features` has `shop/$category` (an enum from `lib/models/`, a `Sort?` query parameter whose enum is
declared in the page's file, and `data.dart` keyed by the category) and `browse/$$categories` (a
`List<Category>` catch-all through an import prefix), with widget tests.

### Catch-all segments

`$$rest` matches **one or more** remaining segments, and `$$$rest` (three `$`) **zero or
more**. The page takes them as a `List<String>` (or a [typed list](#typed-catch-alls)), each part
decoded on its own:

```text
docs/page.dart            /docs                      the index, beside the catch-all
docs/new/page.dart        /docs/new                  a static sibling: tried first
docs/$$rest/page.dart      /docs/guide/setup/linux    rest == ['guide', 'setup', 'linux']
files/$$$path/page.dart   /files, /files/a/b         path == [] or ['a', 'b']
```

```dart
class DocsPage extends StatelessWidget {
  const DocsPage({super.key, required this.rest});
  final List<String> rest;      // `rest` is the segment: a List, of Strings by default
  …
}

const DocsRoute(rest: ['guide', 'a b']).go(context);   // → /docs/guide/a%20b, each part encoded
const FilesRoute().location;                            // '/files'
```

How it works: `go_router` matches a path pattern with a regular expression, and a `:name`
parameter can carry its own (`:rest(.+)`, which may span `/`). A catch-all folder becomes a
route with that pattern, `docs/:rest(.+)`, so deep links, redirects and `go` all use `go_router`'s
normal matching. `$$$rest` is two routes with one builder: the folder's path (`/files`) and
the same with `:path(.+)`. Reading the parts takes `go_router`'s decoded string apart _by the
requested location_, so an encoded slash (`/docs/a%2Fb/c` is `['a/b', 'c']`) survives.

- Siblings are tried in this order: static, then dynamic (`docs/$id`), then the catch-all,
  whatever the folder order. A page that another route always catches first is still
  reported as unreachable, including by a catch-all (`(wiki)/docs/$$rest` behind
  `$a/$$rest`).
- `guard.dart`, `redirect.dart`, `layout.dart`, `loading.dart` and `error.dart` can take the
  parts like any segment (`{required List<String> rest}`).
- `data.dart` can be keyed by them. Lists compare by identity, so the generated provider is
  keyed by the encoded path as one string (`restKey`) and `data()` gets the list back
  (`restParts`). `ref.watch(DocsRoute.data(restKey(rest)))` is what the route does; the
  typed `DocsRoute.watch(ref, rest: [...])` takes the list. A provider you write yourself
  (`final data = FutureProvider.family<…>`) can't be keyed by a catch-all: use the function
  or a [selector](#datadart-a-function-a-selector-or-a-provider), whose `data({required List<String> rest})`
  gets the list back the same way.
- `$$$rest` and a `page.dart` in the folder above would both serve `/docs`: an error. Use
  `$$rest` beside the page.

Limits: a catch-all is always the last segment and a `List`; nothing
can be below its folder, and it can't have a `not_found.dart` (it matches every URL under
it). A catch-all as a tab's first route needs a `tabOptions` `initialLocation`, like any
route with a parameter. A part of `.` or `..` is read as a dot segment by the URL parser, so
`DocsRoute(rest: ['..'])` doesn't reach a `..` part. `fsp new 'docs/[...rest]'` and
`'docs/[[...rest]]'` write the folders, so you don't have to quote `$`.

#### Typed catch-alls

Like a segment, a catch-all takes its type from the parameters that ask for it, and a
`List<String>` is the default. Ask for a `List<int>`, `List<double>`, `List<num>`, `List<bool>`,
`List<DateTime>` or a `List` of an [enum](#enum-segments) and every part is read like one segment of that type:

```text
compare/$$ids/page.dart   /compare/3/7/12           ids == [3, 7, 12]
                          /compare/3/x              not found: `x` isn't an int
```

```dart
class ComparePage extends StatelessWidget {
  const ComparePage({super.key, required this.ids});
  final List<int> ids;
}

const CompareRoute(ids: [3, 7, 12]).go(context);   // → /compare/3/7/12
```

- **A part that doesn't parse** sends the whole route to `not_found.dart`, like a bad `int`
  segment (`/products/abc`): the page is never built (and a guard that reads segments or query
  parameters is skipped, see [Guards](#guards)). `bool` parts are
  `true` and `false`; `num` reads `1` as an int and `2.5` as a double; a `DateTime` part is what
  `DateTime.tryParse` reads, and the typed route writes it as ISO 8601 (`2024-12-31T10:30:00.000Z`,
  colons encoded).
- **`.location` joins the encoded parts**, each on its own (`restPath`), whatever their type.
  `$$$rest` is an empty list when the path has no part, as with strings.
- **The type must agree across files**, as for any segment: a `page.dart` with `List<int> ids`
  and a `data.dart` with `List<String> ids` is an error with a code frame at the second, naming
  the first (`` `$ids` is List<String> in data.dart:1 but List<int> here ``). Anything else
  (`List<Object>`, `List<int?>`, `Set<int>`) is an error that lists what a catch-all can be.
- **`data.dart`** takes the typed list too: the provider is keyed by the encoded path, and
  `data()` gets the list back as a `List<int>`.
- A catch-all can also be a `List` of an [enum](#enum-segments).

`examples/features` has one at `compare/$$ids` (with a `data.dart`), and a widget test.

### Case and trailing slashes

**Trailing slashes.** `/products/` reaches `/products`: go_router drops a trailing slash
before it matches (also in front of a query, `/products/?page=2`), whether it comes from a
deep link, `initialLocation` or `context.go`. There is nothing to configure, and typed
locations never end in one. (Checked against go_router 17.5 and 18.)

**Case.** Paths are case-sensitive, like go_router's default: `/Products` isn't
`/products`. Set `case_sensitive: false` in the pubspec's `fespalier:` section to emit
`caseSensitive: false` on every route:

```yaml
fespalier:
  case_sensitive: false
```

Static parts then match in any case (`/PRODUCTS/Guide` finds `products/guide`), and the
parts you take out of the URL (a `$segment`, a catch-all) keep the case they had.

**Per folder.** A `route.dart` overrides that for its folder and everything below it, and the
nearest one wins over the parent's and over the pubspec:

```dart
// lib/app/files/route.dart: /files/README.md isn't /files/readme.md, whatever the pubspec says
const caseSensitive = true;
```

It works both ways: `false` in one folder of an otherwise exact app, or `true` in one folder
of a `case_sensitive: false` one (`examples/features` does the second). Like `meta.dart` it is
read from the source when the tree is generated, never imported or run, so it must be a `true`
or `false` literal: anything else, a missing `caseSensitive`, or two of them is an error with a
code frame. Unlike `meta.dart` it needs no page beside it, is inherited (`(group)` folders and
folders without a page pass it on) and can sit at the root, where it replaces the pubspec's
value for the whole app. A `route.dart` doesn't add or remove any route (its `paths` spell a
folder's URL more than one way, see [Localized paths](#localized-paths)). The same file can say
`const linkable = false;`, which works the same way (a `true` or `false` literal, the nearest
one wins, inherited by `(group)` folders and folders without a page) and only matters to
[`fsp links`](#deep-links-and-a-sitemap-fsp-links): the routes of that folder and below are not
in the files it writes, and `const remount = Remount.onSegments;` (since 0.6.0), which is the same
kind of declaration for [when a page starts again](#remounting-a-page-remount).
(It's a file of its own because `meta.dart` describes one route and is never inherited,
`transition.dart` is a function, and `layout.dart` only exists where a layout does.)

go_router has one flag per route, and a folder's routes are the whole path down to its page, so
a folder with no page above one that has (`docs/` above `docs/guide/page.dart`) is part of that
route: the flag is the one in effect at the page's folder, for the whole path. The
nearest-`not_found.dart` lookup compares each folder by that folder's own setting, and the mount
point (`AppRoutes.mount(at: '/Shop')`) by the root's.

**The requested case is kept.** go_router matches a case-insensitive route in any case and
leaves the location as it was asked for. Navigating or deep-linking to `/Products/2` leaves
`GoRouterState.uri` and the router's own location (`currentLocation(tester)` in a test) as
`/Products/2`; nothing is lowercased or redirected, and a `$segment` or catch-all keeps what
was typed. Only `state.matchedLocation` is spelled by the route (`/products/2`, with the
parameters as typed). A typed route has no requested case: `ProductRoute(id: 2).location` always
writes the folders' spelling, so `.location` is unchanged by the setting, and if you want the
canonical spelling in the address bar you have to navigate to it yourself. (Checked against
go_router 17.5 and 18.0, in `packages/fespalier/test/paths_test.dart` and `examples/features`.)

### Localized paths

One folder can answer several URL spellings, one per locale, while the typed route, the page and
its data stay single. Give the folder a `route.dart` with a `paths` map from a locale tag to that
folder's name in it:

```dart
// lib/app/products/route.dart: /products also answers /produits (fr) and /produkte (de)
const paths = {'fr': 'produits', 'de': 'produkte'};
```

```text
/products/2    /produits/2    /produkte/2      → the same ProductPage(id: 2), the same data
/products      /produits      /produkte        → the same ProductsPage
```

The folder's name stays the canonical spelling: it is what `.location`, the route table and
`AppManifest.byPath` say, and what a locale with no entry gets. `paths` is read from the source
(like `caseSensitive`), so it must be a map literal of string literals.

- **Only its own segment.** `paths` spells the one static folder it sits in. Folders below have
  their own `route.dart` (or none), and each level is spelled on its own, so `/aide/routing/exemples`
  (`help/` → `aide`, `$topic/examples/` → `exemples`) is a nested child under the localized
  parent. It is an error in the `route.dart` of a `$dynamic`, a `$$catch-all` or a `(group)` folder
  or of the app folder itself (none has a word to spell), and a `route.dart` may hold `paths`
  alone, without a `caseSensitive`.
- **What a spelling can be.** One URL segment: letters and digits, `- _ . ~`, and letters
  beyond ASCII (`'über'`, `'продукты'`, `'製品'`; see [below](#non-ascii-spellings)). A key is a
  locale tag (`fr`, `pt-BR`), and each tag may appear once (`fr` and `FR` are the same tag). A value
  that is empty, `.` or `..`, or has a `/`, `?`, `#`, `%`, whitespace, a control character, or any of
  `: | ( ) [ ] { } ' " $ \ * =`, is an error at the value (a `%` is what a spelling is encoded
  with: write the letter, not its encoding). Two locales may share a spelling, and a spelling may
  equal the folder's own name. An entry with an error is left out, and the rest of the map
  still takes part in the collision check below.
- **Collisions are errors, with a code frame on each side.** A spelling that makes a URL another
  route serves is reported at the entry and at the route it collides with (or at both entries, when
  both are spellings). Two [`not_found.dart`](#not-found-views) files that would cover one URL
  through a spelling collide the same way, at the entry and at the other file:

  ```text
  error: `fr: 'about'` makes /about, which about/page.dart serves too; rename the spelling, or the folder it collides with
    ┌─ lib/app/products/route.dart:2:9
  error: /about is also reached through `fr: 'about'` in products/route.dart:2; rename the spelling, or this folder
    ┌─ lib/app/about/page.dart:1:7
  ```

  The [unreachable-route](#group-folders) check knows the spellings too.

**Typed locations.** `.location` is canonical, `locationFor(locale)` spells the locale, and
`go`, `push` and `replace` take an optional `locale:`:

```dart
ProductRoute(id: 2).location;                 // '/products/2'
ProductRoute(id: 2).locationFor('fr');        // '/produits/2'
ProductRoute(id: 2).locationFor('fr-CA');     // '/produits/2': a region falls back to its language
ProductRoute(id: 2).locationFor('es');        // '/products/2': nobody spells it
ProductRoute(id: 2).go(context, locale: 'de');  // → /produkte/2; also push<T>(…, locale:), pushReplacement<T>(…, locale:) and replace(…, locale:)
```

A level with no spelling for the locale keeps its canonical one, each level on its own (with
`help/` spelled `fr` and `contact/` only `de`, `ContactRoute().locationFor('fr')` is
`/aide/contact`). Tags compare without regard to case and `_` is `-`; an exact tag wins over its
language. Every route has `locationFor` (a route with no localized segment answers `location`), and
`query` parameters are kept.

_Why a parameter and not an `AppRoutes.locale` the typed routes read._ A global would make
`ProductRoute(id: 2).go(context)` and `context.go(ProductRoute(id: 2).location)` different, `.location`
depend on when it is read, and every test depend on what the last one left in a static. A
`locale:` argument keeps a route a value, and the app (which owns its locale: `Localizations`, a
provider, the user's setting) decides where to pass it. An app that wants its locale everywhere can
wrap it once: `extension on TypedLocation { void goHere(BuildContext c) => go(c, locale: currentLocaleTag()); }`.
(A `$locale` folder, `/:locale/products`, is a different way to localize and needs none of this.)

**Every surface knows the spellings.** A deep link, `context.go('/produits/2')`, the router's
location (it stays as it was asked: `/produits/2`, nothing is redirected to the canonical URL),
and the helpers that read a location:

- `AppRoutes.match` / `matchUrl` / `dataAt` and `RouteMatcher` match every spelling and return the
  canonical typed route (`match.route.location` is `/products/2`). `nearestNotFound`, so
  `AppRoutes.notFound(uri)`, treats a localized prefix as all its spellings: a
  [`not_found.dart`](#not-found-views) in `help/` covers `/help/x`, `/aide/x` and `/hilfe/x`.
  Case follows the route's [`caseSensitive`](#case-and-trailing-slashes): with it off, `/AIDE` is `/aide`.
- `AppManifest.of(state)` finds the route at any spelling. The [manifest](#route-manifest-and-metadart)'s
  `RouteInfo` has `paths` (`{'fr': '/produits/:id', 'de': '/produkte/:id'}`, with each level's
  canonical spelling where a locale has none) and `pathFor(locale)`; `path` and `byPath` stay canonical.
- `fsp routes` lists the spellings under the route, and `--json` has a `paths` object for a route that has
  them (the key is left out for the others):

  ```text
  /products/:id  ProductRoute  products/$id/page.dart  (data)
    fr  /produits/:id
    de  /produkte/:id
  ```

**How it is routed.** A localized folder is _one_ `GoRoute`, whose segment is a path parameter with
its own pattern, which go_router supports (like the catch-all's `:rest(.+)`): the route for
`products/$id` is `path: ':_l0(products|produits|produkte)/:id'`, its first alternative the folder's name.
go_router matches the pattern with one regular expression (`patternToRegExp`, identical in 17.5 and 18.0), so a
deep link, a redirect and `go` take any spelling, and everything below the folder, its
nested routes, its layout, its guards and its `not_found.dart`, is the same route as without
`paths`. Because it is one route, `state.pageKey` is the same for every spelling (navigating from
`/products/2` to `/produits/2` updates the page instead of building another), the restoration ids
(made from folders) are unchanged, and there is no second route to keep in order, dedupe or
guard. Two routes with the same builder, or a redirect from each spelling to the canonical
path (which would change the URL the user sees) were the alternatives: see [Design
notes](#design-notes). Things to know:

- The parameter is named `_l<n>` after the segment's place in the URL (`_l0`, `_l1`; a segment can't
  start with `_`, so it never clashes, and go_router refuses a name that repeats down a branch). It
  shows up in `GoRouterState.pathParameters` and `fullPath`, which fespalier's own readers already
  ignore; don't read it. `state.matchedLocation` is spelled as requested (`/produits/2`).
- Spellings are also matched when they are mixed (`/help/routing/exemples`,
  `/aide/routing/examples`): each level is its own alternation. A typed route never writes one; if you
  want mixed URLs refused or redirected, a `guard.dart` can read the `uri`.
- **A tab's first route.** go_router opens a tab on its first route and asserts that it has no path
  parameter, which a localized segment is. `fsp gen` writes the tab's `initialLocation` for you (the
  canonical one, `/search`), unless you gave it one in `tabOptions` (which can be a spelling:
  `'/recherche'`). The one place that can't be written down is a localized first tab route below a
  `:segment` (the location would need a value): that is an error that says so.
- A localized static folder still sorts before dynamic siblings, so `/produits` isn't caught by a `/:slug`.

#### Non-ASCII spellings

`const paths = {'de': 'über', 'ru': 'продукты'};` works. A URL carries only ASCII: `Uri.path` is always
percent-encoded, whether a location was typed `/über`, arrives from the browser as `/%C3%BCber` or as
`/%c3%bcber` (`Uri.parse` normalizes all three to `/%C3%BCber`, and go_router's `router` location,
`GoRouterState.uri` and `currentLocation` are that form). So:

- **The route matches the encoded spelling.** `fsp gen` writes it into go_router's pattern encoded,
  UTF-8 bytes in upper-case hex: `':_l0(shop|%C3%BCber|%D0%BF%D1%80%D0%BE%D0%B4%D1%83%D0%BA%D1%82%D1%8B)'`.
  A deep link raw, encoded or in lower-case hex, `go('/über')` and `go('/%C3%BCber')` all reach it.
- **The runtime helpers compare decoded segments,** so `AppRoutes.match`, `dataAt` and `nearestNotFound`
  (and the manifest, `fsp routes` and diagnostics) have the word as written: `'shop|über|продукты'`.
- **`locationFor` writes it encoded,** as `Uri` would: `ProductsRoute().locationFor('de')` is
  `/%C3%BCber`, the same URL as `Uri.parse('/über')`, so it is safe to compare, store and share.
  `.location` (canonical) is always ASCII.
- **Case and normalization.** With [`caseSensitive: false`](#case-and-trailing-slashes), go_router's
  case-insensitive match is on the encoded text: it folds `A-Z` and the hex digits, but `/ÜBER` is not
  `/über` (they encode to different bytes). `AppRoutes.match` lowercases Unicode, so it may say a
  route fits where go_router's own matching would not; list the capital spelling in `paths` if you need
  it. A letter written two ways (`ü` as one character, or `u` plus a combining diaeresis) is two
  spellings to go_router: fsp compares what you wrote, so write the precomposed form browsers send.

`examples/features` has `help/` (`aide`, `hilfe`) with a dynamic child, a nested localized child, a static
sibling that only one locale spells, a `not_found.dart`, and widget tests for deep links through each
spelling, `locationFor`, `go(locale:)` and the manifest; `examples/tabs` localizes the Search tab.

### `(group)` folders

A folder named in parentheses groups routes without adding to their URLs. Its
`layout.dart`, `loading.dart` and `error.dart` apply to the routes inside it and not to
their siblings, so `(shop)/cart` and `(account)/profile` can have different shells and
still be `/cart` and `/profile`. A group can also hold a `page.dart`: `(marketing)/page.dart`
serves `/` with the marketing layout, as long as nothing else serves `/`.

Two pages that end up at the same URL are an error, and so is a page that another
route always catches first. go_router takes the first route that fully matches, so
fespalier puts static routes before dynamic ones: `/about` comes before `/:slug`. A
group's routes stay together in one ShellRoute, though, so a group holding a dynamic
route can't be sorted around a dynamic sibling outside it:

```text
error: /settings is unreachable: $slug/page.dart (/:slug) comes first and matches it;
       move one of them into or out of its (group)
```

#### A sibling with a compound path

A page is the parent of the routes in the folders below it. With `orders/$id/refund/page.dart`
and `orders/$id/refund/confirm/page.dart`, `confirm` is a `GoRoute` inside the `refund` one, and
a deep link to `/orders/1/refund/confirm` builds the stack `/orders/1`, `/orders/1/refund`,
`/orders/1/refund/confirm` (see [Transitions](#transitions)). That is the right default. A tree
migrated from go_router may have put the two side by side, `GoRoute(path: 'refund')` and
`GoRoute(path: 'refund/confirm')` under `:id`, where the stack of the same link is `/orders/1`,
`/orders/1/refund/confirm`: the page that happens to share the first segment is not built, and
nothing is read for it. There are two ways to write that shape, a group and a declaration.

**With a group.** A group has no page and adds nothing to the URL, so what it holds nests under
the page above the group, not under a page beside it, and its folders may repeat a segment of
that sibling:

```text
lib/app/orders/$id/
  page.dart                                    → /orders/:id
  refund/page.dart                             → /orders/:id/refund
  (refund-confirm)/refund/confirm/page.dart    → /orders/:id/refund/confirm
```

This generates `GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` as two children of
`/orders/:id`: the `refund/` inside the group has no `page.dart`, so it only adds its segment to
the path. It works because of how groups fold away and a test holds it, but a group with no
layout, guard or transition looks like it does nothing; name it for what it is for, or say it
outright with `nest`.

**With `route.dart`.** `const nest = false;` in the folder of the route that must not nest:

```dart
// lib/app/orders/$id/refund/confirm/route.dart
const nest = false;
```

`confirm/` stays where it is: its URL, its typed route (`ConfirmRoute(id: 1).location` is
`/orders/1/refund/confirm`) and its place in the manifest do not change. What changes is the route
fespalier writes for it: it is no longer a child of the page of the folder above (`refund`) but
a sibling of that page, with a compound path,

```dart
GoRoute(path: joinLocation(at, '/orders/:id'), routes: [
  GoRoute(path: 'refund'),
  GoRoute(path: 'refund/confirm'),   // beside it, not inside
])
```

so the stack is `/orders/1`, `/orders/1/refund/confirm`, and the `refund` page is neither built nor
asked for its `data.dart`. `fsp routes` marks the route `(sibling)` (and its `tags` in `--json`
have `"sibling"`).

Like `caseSensitive` it is read from the source, so it must be a `true` or `false` literal. It is
about this folder's route alone and is not inherited: the routes in the folders below `confirm/`
nest under `confirm` as usual. `true` is the default and says nothing. The name is the verb the
README already uses for folders (a page is the parent of what is nested in it), and `false` is the
exception. A declaration in `refund/` saying "my children don't nest under me" would be the same
word read the other way, so there is only this one, in the folder of the route that leaves, where
you can find it from the route.

- **Where it goes.** Beside the nearest page above it; page-less folders and groups in between
  don't count as one. The path joins the segments of the folders it leaves, the
  static ones, the `$param` ones and a [localized](#localized-paths) one as its alternation
  (`:_l2(refund|remboursement)/confirm`): `refund/confirm`, `refund/:step`, `refund/:rest(.+)` for
  a `$$rest`. A `(group)` adds none. If the page above is itself `nest = false`, the route goes
  beside that one: its parent is the nearest route that stays, and the path joins every folder
  between. Beside the root page, a route is at the top: `login/` with `nest = false` is `/login`
  without `/` below it. A `redirect.dart` route can leave too. In a tab layout the route stays in
  its tab, after the page.
- **What it keeps.** Everything comes from the folders, not from where the route is written, so
  the guards of the page it leaves and of the page-less folders in between run first, outermost
  first, then its own (like those of a page-less folder, they are the route's inherited
  guards); the nearest `transition.dart`, `navigator.dart`, `not_found.dart` and `loading.dart` /
  `error.dart` still apply; the segments of the folders it leaves are parsed and typed for it, its
  data and its views, and a segment that doesn't parse is not-found as before; the data of
  the sections above it is the same, so `AppRoutes.match` and `dataAt` list the same providers.
  What the page it leaves builds and reads is not part of it: its page, its `data.dart`, its
  `present.dart`. A dialog or sheet [transition](#transitions) opens over the page that stays
  below it, `orders/$id`.
- **`caseSensitive`.** One go_router path is one flag, so the whole compound path matches by the
  route's own setting: the nearest `route.dart` at or above it, its own included.
- **Order.** go_router takes the first route that matches the whole URL, depth first, and goes on
  to the next sibling when a route's children don't match the rest (`match.dart`, the same in
  go_router 17.5 and 18.0), so `refund` and `refund/confirm` can come in either order. Static
  routes come before `:param` ones and catch-alls as always, and fespalier puts a static
  `refund/confirm` before `refund` when something below `refund` (a `$step`, a `$$rest`) would
  match `confirm` first, as it would nest. Otherwise it follows the page, so a tab still opens on
  it. A route that something earlier still catches is the usual
  [unreachable error](#group-folders).
- **Errors, each with a code frame on the declaration.** `nest = false` where there is nothing to
  leave: in the app folder, in a `(group)` (which has no route of its own; the error names the group
  shape above), in a folder with no `page.dart` or `redirect.dart`, or with no `page.dart` above.
  A `layout.dart` in the page's folder or in a page-less folder between: the route would leave its
  shell, so move the layout above the page, or drop `nest`. A value that isn't a `true` or `false`
  literal, or two of them. A route on the root navigator (`navigator.dart`, `present.dart`) that
  would become a direct child of a layout is the existing
  [root navigator](#the-root-navigator-navigatordart) error.

`examples/features` has `orders/$id/refund/confirm` (and `refund/receipt`, which nests), with a
guard on `refund/` and widget tests for the stack a deep link builds and what back does.

### Tab layouts

A `layout.dart` that asks for a `StatefulNavigationShell` (named `navigationShell` or
`shell`, or by that type) instead of a `Widget child` is a tab layout. It becomes a
go_router `StatefulShellRoute.indexedStack` (or, with a [`container`](#tab-layouts), your own
`navigatorContainerBuilder`), so each tab keeps its own navigation stack
and state while you look at another one. Asking for both a child and a shell is an error.

```dart
// lib/app/(tabs)/layout.dart
const tabs = ['(home)', 'search', 'profile'];

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (i) => navigationShell.goBranch(
            i,
            initialLocation: i == navigationShell.currentIndex,
          ),
          destinations: [ … ],
        ),
      );
}
```

Each tab (a branch) is the layout folder's own `page.dart`, if it has one, and then each
direct subfolder that holds routes: a static or dynamic folder, or a `(group)`. Whatever
is below a subfolder (nested pages, data, guards, transitions, more layouts) stays inside
its tab. Branches follow folder order, which is alphabetical, unless `tabs` lists them.
`tabs` is a top-level `const` list of string literals naming each folder as written, and
`'.'` for the folder's own page. It must list every branch exactly once, and a name that
is unknown, missing or repeated is an error. A tab layout can also ask for segments and
query parameters like any other layout. A tab layout folder without its own `page.dart` has
no route at its own path: link to one of its tabs' routes instead.

Routes outside the layout's folder aren't in any tab, so they cover the whole screen: in
`examples/tabs`, `/settings` has no navigation bar. To cover the screen while the URL stays in
a tab (`/profile/edit`), use [`navigator.dart`](#the-root-navigator-navigatordart). Two things to
know: go_router opens a tab on its first route, which can't have a `:segment` in its own
path, so a tab made only of dynamic routes, or a tab layout placed directly in a
`$folder`, is an error (put the layout in a `(group)` below that folder instead); and `tabs` in a tab layout must be string literals, so name another list of destinations
something else. See `examples/tabs`.

**Nested tab layouts.** A tab layout can sit inside a tab of another one: put a
`layout.dart` that takes a `StatefulNavigationShell` in a folder that is a branch of the
outer layout. Each layout has its own `tabs` list, its own navigation stacks and its own
`StatefulNavigationShell`, and the outer layout keeps the whole inner one alive while you
look at another outer tab, so an inner tab's state survives switching outer tabs. The same
rules apply at each level: an inner tab can't start on a route with a `:segment` in its
path, and a tab layout in a `$folder` is an error.

```text
lib/app/(tabs)/
  layout.dart              const tabs = ['(home)', 'search', 'library']; takes a shell
  (home)/page.dart
  search/page.dart
  library/                 the third outer tab...
    layout.dart            ...is itself a tab layout: const tabs = ['books', 'authors'];
    books/page.dart          /library/books
    authors/page.dart        /library/authors
```

`library/` has no page of its own here, so its inner layout is what the outer tab shows.
Give it a `page.dart` and that page becomes the inner layout's first tab, like any tab
layout's own page. In `examples/tabs` the Library tab is built this way; its tests check
that a counter in an inner tab survives switching inner and outer tabs.

**Tab options.** A tab layout can set go_router's `StatefulShellBranch` options per tab in
a top-level `const tabOptions` map, next to `tabs`. Keys are the tab names `tabs` uses
(`'.'` for the layout's own page), and each value is a `TabOptions` from
`package:fespalier/fespalier.dart`:

```dart
const tabOptions = {
  'search': TabOptions(preload: true),
  'profile': TabOptions(initialLocation: '/profile/edit'),
};
```

- `preload: true` builds the tab as soon as the layout first shows, instead of on its
  first visit.
- `initialLocation` is where the tab opens the first time, and where tapping its current
  tab goes with `goBranch(i, initialLocation: true)`, instead of the tab's first route. It's
  an app location such as `/profile/edit` (with `?query` if you like), written as a
  string literal. It must be a route inside that tab, and `fsp` checks that (dynamic routes
  match any value: `/items/1` for `items/$id`). It also lets a tab that has only dynamic
  routes work, since go_router then doesn't need a first route without a `:segment`. When
  mounted with `AppRoutes.mount(at: '/x')`, the mount point is added for you.

Like `tabs`, `tabOptions` is read from the source, not run: it must be a map literal with
string-literal keys and `TabOptions(...)` values with `true`/`false` and string-literal
arguments. Unknown tabs, repeated tabs, unknown options and other values are errors that
point at the offending entry. Only tabs that need options are listed.

**Container.** By default the tabs' navigators sit in an `IndexedStack`. A tab layout can
export a top-level `container` function to arrange them itself, say to cross-fade or slide
between tabs:

```dart
// lib/app/(tabs)/layout.dart
Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children) =>
    CrossFadeContainer(currentIndex: shell.currentIndex, children: children);
```

The generated route is then `StatefulShellRoute(navigatorContainerBuilder: _i1.container, …)`
instead of `.indexedStack(…)`; a layout without `container` generates exactly what it did
before. The three parameters are positional, and their **types are fixed** (`BuildContext`,
`StatefulNavigationShell`, `List<Widget>`; the names are yours): a wrong type, a missing or an
extra parameter, or a return type that isn't `Widget` is an error at the parameter. `children`
holds one navigator per tab in the layout's tab order, and the container must keep them all in the
tree (`Offstage`, `Opacity` or a `Stack`, as `IndexedStack` does) or the tabs lose their state,
and wrap the ones it doesn't show in `TickerMode(enabled: false)`, as go_router's does: that is how a
[shared element](#shared-elements-heroes) (since 0.8.1) knows its tab is hidden.
A `container` in a layout that isn't a tab layout is ignored with a warning. `examples/tabs`
cross-fades, and its tests check that a tab's state survives.

### Menus and breadcrumbs: `nav.dart`

Since 0.8.1. A drawer, a bottom bar, a tab bar and a breadcrumb row all list the same thing:
the folders of the app and where they go. A `nav.dart` in a folder says how that folder shows
up, and `fsp gen` writes `AppMenu` at the end of `lib/app.g.dart` from all of them, so a menu is
not a second list to keep in step with the routes. An app with no `nav.dart` generates exactly
the file it did before.

```dart
// lib/app/products/nav.dart
import 'package:fespalier/nav.dart';
import 'package:flutter/material.dart';

const nav = Nav(
  label: 'Products', // without a BuildContext (`fsp routes`, tests), and the fallback
  icon: Icons.storefront_outlined,
  selectedIcon: Icons.storefront,
  order: 1, // siblings sort by `order`, then by their place as a tab, then by folder name
);

/// Optional: the label shown, localized. It can ask for the segments of its folder and above.
String label(BuildContext context) => AppLocalizations.of(context)!.products;
```

`Nav` and `NavItem` live in `package:fespalier/nav.dart`, not in the barrel, so they collide
with nothing you have. `nav` must be a `const` `Nav(...)` call and `order` a whole-number
literal: `fsp` reads both from the source. A folder with a `page.dart` or `redirect.dart` is an
entry that goes there; a folder without one is a **heading** that holds the entries of the
folders below it, and is left out (with a warning) when there are none.

```dart
// lib/app/orders/$id/nav.dart: a breadcrumb, not a menu entry
const nav = Nav(label: 'Order', inMenu: false);
String label(BuildContext context, {required int id}) => 'Order #$id';
```

**Reading it.** `AppMenu.watch(ref)` returns the entries at the current location, nested as the
folders are, as `NavItem`s; `AppMenu.breadcrumbs(ref)` the entries from the top down to the
page. Call them in `build`, in a layout or a page: they read the router's location, so the
widget rebuilds when it changes (above the router, in `MaterialApp.builder`, there is none).

```dart
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      for (final item in AppMenu.watch(ref))
        ListTile(
          leading: Icon(item.icon), // selectedIcon while selected
          title: Text(item.label(context)),
          selected: item.selected,
          enabled: item.enabled, // false: its guards refuse it, with `NavRefused.disable`
          onTap: () => item.go(context),
        ),
    ],
  );
}

// a tab bar: AppMenu.watch(ref, under: '(tabs)') lists the entries at or below that folder,
// and each one's `tab` is its index in the tab layout of that folder
final tabs = AppMenu.watch(ref, under: '(tabs)');
NavigationBar(
  selectedIndex: navigationShell.currentIndex,
  onDestinationSelected: (i) => navigationShell.goBranch(i),
  destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.icon), label: t.label(context))],
);

// breadcrumbs
Text(AppMenu.breadcrumbs(ref).map((c) => c.label(context)).join(' › '));
```

**Which entries, and in what order.**

- The app folder's own `nav.dart`, and the one of a tab layout's own `page.dart`, are _flat_:
  they sit beside the entries below them instead of holding them, and are selected on their own
  route only. Any other entry holds the entries of the folders below it (`children`).
- Siblings sort by `order`, then by their index as a tab (see `NavItem.tab`), then by folder
  name.
- `under:` takes a folder (`'(tabs)'`, `r'teams/$teamId'`, `''` for everything) and returns the
  topmost entries at or below it. It is an assertion in debug when no `nav.dart` is there.
- An entry whose folder has segments (`orders/$id`) is listed only at a location that has them
  (`/orders/7`, `/orders/7/refund`): its route is built from that location. Elsewhere it is
  left out, with the entries below it. `inMenu: false` leaves an entry out of `watch` and its
  children with it; the breadcrumbs keep it.
- A selected entry is the one of the page or of a folder above it.

**Guards.** An entry is shown only if the guards that would run for a navigation to it let it
through: those of its folder and the ones above it, asked with the entry's own location. What
the menu does with a refused one is the entry's `whenRefused`: `NavRefused.hide` (the default),
`disable` (listed, `enabled == false`) or `show` (listed, and its guards are not asked at all).

- A guard that answers at once (the usual `ref.watch(session) ? null : '/login'`) is in the
  **first frame** of the widget that asks. A `Ref` guard is followed: when what it `ref.watch`es
  changes, the entry changes in the next frame, with no navigation.
- A guard that returns a `Future` makes the entry **pending**: listed and enabled
  (`NavItem.access == NavAccess.pending`) until the answer is in, then allowed or refused. Nothing
  waits for it, and no timer is used. A guard that throws is reported (`FlutterError.reportError`)
  and the entry stays pending.
- A guard written with `ProviderContainer c` (the older form) is called with the `Ref`'s
  container, and read once when the menu asks, as a navigation does: the menu does not follow
  it.
- The menu **runs your guards**, each once per entry while a menu with it is on screen (and
  again when what they watch changes), so a guard has to be cheap and free of side effects. The
  answers are kept in one provider per entry that goes with the widgets that watch it:
  a menu that leaves the screen lets go of everything its guards watch.

**Labels.** `label()` gets the `BuildContext`, so it can read `AppLocalizations`, the locale or a
provider-backed setting, and the segments it names (`required int id`), typed like any other file
in the folder. It is not given data: a breadcrumb that shows a product's name reads the product
in the widget (`ProductRoute.watch(ref, id: item.params['id'] as int)`).

Not built: more than one menu per app (use `under:` and `inMenu`), labels from `data.dart`.
`fsp new orders --nav` writes a `nav.dart` for a folder, `fsp routes --json` has a `nav` key on
the routes whose folder has one (`file`, `label` when it is a string literal, `order`), and
`examples/features` has a menu, a team sub-menu and breadcrumbs, with tests for each guard case.

### Guards

`guard.dart` exports `GuardResult guard(Ref ref, {…})`. It returns a location to
redirect to, or `null` to let the navigation through, and may be async. It guards every
route at and below its folder, and the folder needs no `page.dart`: put one in a `(group)` or
at the root to cover a whole section of the app.

```dart
// lib/app/(members)/guard.dart: guards /inbox, /admin and everything else in the group
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

- **It runs again when what it watches changes** (since 0.5.0). `ref.watch` a provider in
  the guard and, when that provider changes and the guard's answer is now a different one,
  the router runs the redirects again: signing out moves you to the login page from whatever
  member page you were on, with no refresh code of your own (before 0.5.0 a guard read once,
  when you navigated, so nothing happened until you did). The login page is not under that
  guard, so signing in is the login page's to navigate (`returnTo`), unless it has a guard of
  its own that watches the session.
  Nothing is wired up: it works for `AppRoutes.router()` and for a router of your own built
  from `AppRoutes.mount()`, with no `refreshListenable`. An async guard watches the same way,
  through a provider's `.future`:

  ```dart
  Future<String?> guard(Ref ref, {required Uri uri}) async =>
      await ref.watch(currentUser.future) == null
          ? LoginRoute(from: uri.toString()).location
          : null;
  ```

  `ref.read` is for what must be the current value when you navigate and never changes the
  answer later. A guard that returns the same answer after a change does nothing.
- **What it costs.** Return synchronously when you can. A guard that needs no `await` should
  not be `async`, and not return `Future.value(...)` either: it then answers synchronously, in
  the same frame as the navigation, and the first frame at boot (a cold deep link too) already
  shows the page. Any `Future`, even a completed one, costs the router a frame, and the first
  frame is blank. Each navigation runs the guard in a fresh `autoDispose` provider, so
  what it `ref.watch`es is shared with the rest of the app and fetched once; the guard itself
  runs again after a change and again when the router asks, so keep it cheap. A guard
  signing out therefore runs twice (Riverpod recomputes it, then the router asks), and the
  data providers it watches are not fetched twice.
- **When it stops watching.** The guard of the location the router shows keeps watching.
  It is dropped when a navigation ends on a location that does not run it, and when the
  router or the app goes. A guarded page _under a pushed page_ does not react until you pop
  back to it (the push dropped its subscription; popping runs the guard again). Don't call
  `ref.keepAlive()` in a guard: it keeps one provider alive per navigation.
- **If it throws.** A guard that throws, or whose later run throws, never moves the
  router: an error on a navigation reaches go_router like any redirect's, and an error on a
  later run keeps the page you are on until the next navigation. The guard's provider does not
  retry.
- **The older form.** A guard may still take `ProviderContainer c` first
  (`c.read(session)`): it is read once per navigation, as before 0.5.0, and never runs again by
  itself. Taking a `WidgetRef` is an error ("a guard runs outside the widget tree: take
  `Ref`"), since a guard has no widget.
- **Order.** Guards run outermost first, and the first one to return a location wins. A
  folder with a page and its own guard keeps its guard for that page and everything nested
  in it; guards above it run first. A route with [`nest = false`](#a-sibling-with-a-compound-path)
  is not nested in the page above it, and still gets that page's guard, after the ones above it.
- **Parameters.** The `Ref` comes first, then named parameters: `uri` (the
  requested location, a `Uri`), `extra` (see [Typed `extra`](#typed-extra)), the segments of the guard's own folder and the ones above
  it (`{required String shop}`), and query parameters (optional and nullable, `String? ref`).
  A guard above `$id` can't ask for `id`: that's an error at the parameter. Segments are
  typed like everywhere else. A guard's query parameters stay its own: they don't become
  fields of the typed routes below it (unless the guard sits next to a `page.dart`, where
  they are the page's, as before).
- **What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in order, the
  guards of the page-less folders above it and then its own. A `Ref` guard is called as
  `refGuard(context, 'g8@3', (ref) => _i8.guard(ref, uri: state.uri))` (the string names the
  guard on that route, and is constant; since 0.7.0 each call sits in `traceGuard(state, 'g8@3', ...)`, which
  returns it unchanged, for the [DevTools extension](#devtools-extension)). Nested pages go through their
  parent's `redirect`, so no guard runs twice. (A route that leaves the page above with `nest = false`
  has that page's guard and the ones of the folders between in its own `redirect`, the way a page-less
  folder's guard is, since the page is not its parent.) There's no redirect on `ShellRoute` or
  `StatefulShellRoute`: go_router runs a matched route's redirect for deep links and for
  navigation inside a shell, tabs included, so the page routes are enough (and a page-less
  folder has no route to put one on). When a path has a segment that doesn't parse
  (`/products/abc`), not-found is shown, and a guard that asks for segments or query parameters
  is skipped, since it has nothing to read. A guard that asks for neither (only `uri`,
  `extra`, or nothing) still runs, so it can redirect `/products/abc` to login.
- A `guard.dart` with no `page.dart` or `redirect.dart` at or below its folder is a warning.

### `redirect.dart`

A folder can hold `redirect.dart` instead of `page.dart`. It exports `String redirect({…})`
(or `Future<String>`) returning the location to go to, and the route only redirects: no
widget, no builder.

```dart
// lib/app/old-products/$id/redirect.dart: /old-products/3 → /products/3
String redirect({required int id}) => ProductRoute(id: id).location;

// ...or, reading a provider (a redirect's `ref.watch` runs once, it does not re-run)
String redirect(Ref ref, {required int id}) =>
    ref.read(catalog).contains(id) ? ProductRoute(id: id).location : const HomeRoute().location;
```

It takes the same parameters as a guard, except that the first one is optional: put `Ref ref`
first if you need providers (since 0.5.0; `ProviderContainer c` is the older form). A redirect
runs once per navigation and does not watch: a redirect route never stays on screen, so there is
nothing to run again. Segments are typed like anywhere else, so `/old-products/abc`
shows not-found. It gets a typed route, named after its path (`OldProductsIdRoute(id: 3)`),
so links to the old URL stay typed; query parameters it asks for are its fields. It takes part in
route order and unreachable checks like a page, inherits the guards above it, and can sit
next to a `guard.dart`, which runs first. A folder has a `page.dart` or a `redirect.dart`,
not both, and a tab layout's own folder can't hold a `redirect.dart`. Routes in subfolders
sit beside a redirect route rather than inside it, since anything inside would redirect too.

### Sending people back

A guard that redirects to a login page can pass along where the user was going. Ask for
`Uri uri` (the requested location, query included) and put it in the login route's query:

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent
```

`login/page.dart` takes it as a query parameter (`this.from`, a `String?`), and when the
user is done it calls `returnTo`:

```dart
context.go(returnTo(from));                  // from if it's a location in the app, else '/'
```

`returnTo(from, fallback: '/home')` only lets an absolute path through: `https://…`, `//host`
and the like fall back, so a crafted `?from=` can't send people off your app. Both `uri` and
the typed routes include the mount prefix when the tree is mounted with `at:`.

### Feature flags: fespalier_flags

Since 0.9.0. A feature flag is a value the app asks for by name and that a server, a vendor SDK or a build can
change: show `/labs` to some users, move `checkout` to its second version. fespalier's core has no flag feature and
gains none: no file kind, no `fespalier:` key, no `fsp` command, and `app.g.dart` is the same bytes.
`package:fespalier_flags` is [Guards](#guards) with a source of values: a flag is a provider that answers **at
once** (never an `AsyncValue`, never a `Future`), so a guard that watches one stays synchronous, and a menu entry
behind it follows the flag because [menus run guards](#menus-and-breadcrumbs-navdart). An app that does not depend on
it is unchanged. It adds no dependency beyond fespalier, no timer and no polling.

Add it next to fespalier, with the same `url` and the same `ref` (pub resolves the two to one package only if they are
the same repository dependency; a mismatch fails with `Because every version of fespalier_flags from path depends on
fespalier from git https://github.com/fespalier/fespalier at v0.7.0 in packages/fespalier and demo depends on
fespalier from git https://github.com/fespalier/fespalier at v0.6.0 in packages/fespalier, fespalier_flags from path
is forbidden.`, the form it takes when the first is a path):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_flags:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_flags
      ref: v0.8.1
```

<!-- x-release-please-end -->

Declare each flag once, `const`, gate a route with `flagGuard` in its `guard.dart`, and read a flag anywhere that has a
`Ref` or a `WidgetRef`:

```dart
// lib/flags.dart
const labs = BoolFlag('labs');
const checkoutV2 = BoolFlag('checkout_v2');
const pageSize = IntFlag('page_size', fallback: 20);

// lib/app/labs/guard.dart: /labs is there while the flag is on
GuardResult guard(Ref ref) => flagGuard(ref, labs, orElse: const HomeRoute().location);

// a widget, a provider, a guard: the value is there at once
final size = ref.watch(flag(pageSize));
```

`BoolFlag` is off unless the source says otherwise (its `fallback` is `false`); `StringFlag`, `IntFlag` and
`DoubleFlag` have a required `fallback`. A flag is its **fallback** whenever the source has no value for its key, has
one of another type, throws, or has not started yet, so a flag is never loading. Two declarations with the same type,
key and fallback are the same flag. A `nav.dart` beside the `guard.dart` needs nothing else: while the flag is off
the guard refuses the entry, and a refused entry is hidden (`NavRefused.hide`, the default; `whenRefused:
NavRefused.disable` greys it out instead).

- **A new route behind a flag:** `lib/app/checkout-v2/guard.dart` is `flagGuard(ref, checkoutV2, orElse: const
  CartRoute().location)`. A whole section: the guard goes in a `(group)` or in the section's folder, as any guard.
- **The old URL goes to the new one while the flag is on:** `checkout/guard.dart` is `flagGuard(ref, checkoutV2,
  whenOff: true, orElse: const CheckoutV2Route().location)`.
- **The same URL, two pages:** no guard; the page switches: `ref.watch(flag(checkoutV2)) ? const CheckoutV2() : const
  CheckoutV1()`.
- **A flag and a sign-in:** a folder has one `guard.dart`, so compose with `??`. `flagGuard` returns a `String?`,
  synchronously: `flagGuard(ref, labs, orElse: '/') ?? (ref.watch(session) ? null :
  LoginRoute(from: uri.toString()).location)` (with [`fespalier_auth`](#authentication): `?? requireSignedIn(ref,
  uri, signIn: ...)`).
- **A flow that must not be pulled from under the user** (a checkout): `flagGuard(ref, checkoutV2, orElse: '/',
  follow: false)` reads the flag once per navigation (`ref.read`): the page stays open when the flag turns off, the
  next navigation applies it, and a menu does not follow.

**Live updates.** A source can send an event when values change (`FlagSource.changes`: `FlagsChanged({'labs'})` names
the keys, `FlagsChanged.all()` means any). `fespalier_flags` listens with **one subscription per `ProviderContainer`**,
opened when the first flag is watched and cancelled when the last watched flag goes, and reads again only the watched
flags the event names. A guard, a menu or a widget runs again only when the value it reads **differs**, so a flag that
turns off on `/labs` takes the app to `orElse` in the next frame and a menu entry under it hides, with no navigation.
Nothing in the package polls or starts a timer; a vendor's own streaming or polling runs inside its SDK, by its settings.

**What to know.**

- **A guard that redirected stays subscribed until the next navigation.** fespalier keeps a `ref.watch`ing guard
  while the committed location runs it, and a guard that redirected is kept until the next commit (see
  [Guards](#guards)). So a flag's subscription can outlive the page it gated by one navigation: a cold deep link to
  `/labs` with the flag off lands on `/`, and the flag is still listened to until the user goes somewhere else.
  `packages/fespalier_flags/test/guard_test.dart` pins this, so a change in fespalier's guard lifetime is noticed.
- **A guarded page under a pushed page** does not react until it is uncovered (the rule of every guard).
- **A cold deep link before the source is ready** sees the fallback, so a guard sends it to `orElse`: await the
  vendor's local load in `startup()` (below).
- **Never call a vendor's async API in a guard.** PostHog's `isFeatureEnabled` is a `Future`: the guard answers a
  `Future`, the menu entry turns pending and the first frame is blank. Copy the value into a
  [`FlagSource`](#where-flag-values-come-from) and read that.
- **`follow: true` (the default) takes a user off a page** when the flag turns off mid-flow. Use `follow: false` for a
  flow.
- **Each change re-reads the watched flags the event names.** Vendors that count evaluations (LaunchDarkly) or track
  exposures (GrowthBook) see those reads; a keyed `FlagsChanged` keeps them to the keys that changed.

**Not built.** A `route.dart` constant (`const flag = 'checkout_v2'`): it would be a second gating mechanism, with
binding rules, diagnostics and an order to define against `guard.dart`, `nest = false` and menus, to save one line.
Vendor **packages**: each bridge is 15 to 40 lines of mapping, so they are recipes, below. A DevTools panel for flag
values.

#### Where flag values come from

`startup()` returns the source, once: `flagSource.overrideWithValue(source)`. Without one, `flagSource` is
`const ConstFlags()`: every flag is its fallback.

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  flagSource.overrideWithValue(const ConstFlags({'labs': bool.fromEnvironment('LABS')})),
];
```

A `FlagSource` is four synchronous typed reads (`boolValue(key, fallback)`, `stringValue`, `intValue`,
`doubleValue`) and `Stream<FlagsChanged>? get changes`. The typed reads are what OpenFeature's static-context client
and LaunchDarkly's variations are, so a bridge to a vendor is a line per method. Every read must answer **from
memory**: guards and menus call it, so never from the network, a file or a platform channel. A read that throws is the
flag's fallback (printed in debug).

| Source               | What it is                                                                                                                                      |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `ConstFlags({...})`  | Fixed values, or `--dart-define`d ones. `changes` is `null`. A bool reads a `bool`, a double any `num`; a value of another type is the fallback |
| `AsyncFlags(future)` | A source that is not ready at start: reads come from `meanwhile` until the future completes, then one `FlagsChanged.all()`                      |
| A vendor bridge      | Your own `FlagSource` over the vendor's SDK: a recipe, below                                                                                    |
| `FakeFlags({...})`   | For tests: [Testing flagged routes](#testing-flagged-routes)                                                                                    |

**Initial values, with no timer.** `startup()` awaits only what is **local**: Remote Config's `ensureInitialized()`
and `activate()` (the values the previous session fetched), LaunchDarkly's construction, PostHog's `setup()` and a read
of the app's keys from the native SDK's cache. From the first frame every read is a synchronous call into the vendor's
memory. A vendor whose start waits for the network (GrowthBook past its cache's TTL, LaunchDarkly's `start()` on a first
launch, which "may not complete until ... the device leaves airplane mode") goes in `AsyncFlags(start(), meanwhile:
...)`: the fallbacks (or the app's last known values) until the `Future` completes, then one `FlagsChanged.all()`. An
app that must see remote values before its first frame awaits the vendor in `startup()` with a `.timeout()` of its own
if it wants one: that timer is the app's choice, and fespalier's tests never reach it (tests override `flagSource`).

**Recipes.** Firebase Remote Config, LaunchDarkly, PostHog and GrowthBook have a recipe, compiled by `just
skill-samples`, in [`skills/fespalier-guards/references/flag-sources.md`](skills/fespalier-guards/references/flag-sources.md): about 15 to 40 lines each, a class
that `implements FlagSource` and a `startup()` that returns it. They are not packages because there is no fespalier
logic left in them, and a package per vendor would cost a release, a CI entry that resolves the vendor's SDK and a
fake of its singleton for 20 lines. A recipe becomes a package when its glue grows fespalier-specific logic or past
about 60 lines. **OpenFeature** is the common interface to converge on, but is not adopted: its Dart SDK is a beta. A
bridge over it is about 25 lines, and `FlagSource` mirrors its typed reads and its configuration-changed event.

#### Testing flagged routes

`FakeFlags` (in `package:fespalier_flags/testing.dart`) is a `FlagSource` that holds values in memory. Give it to
`pumpRouter` as an override, or to the setup file of `fsp test`:

```dart
testWidgets('labs is there with the flag on, and goes with it', (tester) async {
  final flags = FakeFlags({'labs': true});
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/labs'),
    overrides: [flagSource.overrideWithValue(flags)],
  );
  expect(currentLocation(tester), '/labs');

  flags.set('labs', false);   // delivered synchronously
  await tester.pump();        // one frame: the guard ran again, the router moved
  expect(currentLocation(tester), '/');
});
```

```dart
// test/routes/setup.dart: `fsp test` tests a flagged route instead of skipping it
List<Override> overrides(String pattern) => [
  flagSource.overrideWithValue(FakeFlags({'labs': pattern == '/labs'})),
];
```

- **`set(key, value)`** sends `FlagsChanged({key})` before it returns, `setAll({...})` one event for several keys, and
  a `null` value removes the key. Call them from the test body, not while a widget builds.
- **`FakeFlags.strict({...})`** throws a `StateError` for a key it lacks or a value of another type, and reports it
  to `FlutterError.reportError`, so a typo in a key fails a `testWidgets` instead of reading the fallback.
- **`listenerCount`** is how many listen to its changes: `0` once nothing watches a flag.
- Without an override, every flag is its fallback, so existing tests of an app that adds a flag see the flag off.

### Route lifecycle: `observe.dart`

Since 0.8.1, an `observe.dart` runs code when a page becomes the one the user sees, when it is on
top again, and when it is gone: analytics, logging, a window title. It observes and cannot veto
(blocking a leave is go_router's `GoRoute.onExit`, which fespalier does not wrap).

```dart
// lib/app/observe.dart: every page of the app
import 'package:fespalier/fespalier.dart';
import 'package:my_app/analytics.dart';
import 'package:my_app/app.g.dart';

void onEnter(Ref ref, {required TypedLocation route}) =>
    ref.read(analytics).screenView(AppManifest.byType[route.runtimeType]?.path ?? '?');

// lib/app/products/$id/observe.dart: /products/:id and everything below it
void onEnter(Ref ref, {required int id}) => ref.read(recent.notifier).add(id);
void onFocus({required int id}) => setDocumentTitle('Product $id');
void onLeave(Ref ref, {required int id}) => ref.read(log).info('left product $id');
```

**The functions.** Any of `onEnter`, `onLeave` and `onFocus`, at least one, each a public top-level
function that returns `void` (written out). Other functions in the file are helpers and are ignored.

**The parameters.** An optional positional `Ref ref` first, then named parameters bound like a
[guard's](#guards): the segments of its folder and the folders above it, typed (`required int id`);
query parameters, optional and nullable (they belong to the folder's route when it has a `page.dart`,
and otherwise to the hook alone); `Uri uri`, the page's location (the mount prefix included); and
`TypedLocation route`, the typed route of the page the hook runs for (`ProductRoute(id: 3)`), bound by
its type. `extra`, `ProviderContainer` and `WidgetRef` are errors. The `Ref` is a throwaway provider's,
closed as soon as the hook returns: `ref.read` works, and so does changing another provider
(`ref.read(views.notifier).add(...)`); `ref.watch` watches nothing that lasts.

**Which pages, and in which order.** An `observe.dart` applies to every page (`page.dart`) at and
below its folder, `nest = false` routes included. A `redirect.dart` route never stays on screen, so it
never enters. For one page, the hooks of all the files that apply run outermost folder first for
`onEnter` and `onFocus`, and innermost first for `onLeave`.

**When.** Hooks run at the end of the first frame that shows the change (a post-frame callback, never
during `build`), by comparing what the router committed with what it showed before. A page instance is
one page on a navigator: a tree page is told apart by its route and its matched location, so another
segment value is another page (`/products/1` leaves, `/products/2` enters, whatever
[`remount`](#remounting-a-page-remount) says) and a query change is no transition at all. The page the
user sees is the top one: the last pushed page, else the leaf of the router's location.

- `onEnter`: the first time a page instance is the page the user sees.
- `onFocus`: an entered page is on top again (a page above it was popped, or its tab was shown).
- `onLeave`: an entered page is on no navigator any more. A page in a tab that is not the current one is
  _parked_, not gone: its tab keeps its stack, and it leaves when it is gone from its branch or the whole
  tab layout leaves.

`onEnter` and `onLeave` come in pairs, and `onFocus` only falls between them. On one frame the `onLeave`s
run first, newest first, then the `onEnter` or `onFocus` of the page on top.

| Navigation                             | Events                                                               |
| -------------------------------------- | -------------------------------------------------------------------- |
| boot at `/a`                           | enter `/a`                                                           |
| `go('/a/1')`, a nested page            | enter `/a/:id`; `/a` is covered, not left                            |
| `go('/a/2')` from there                | leave `/a/1`, enter `/a/2`                                           |
| `refresh()`, a rebuild, a query change | nothing                                                              |
| switch to another tab, and back        | enter its page (the first tab's page is parked), then focus          |
| `push('/x')`, then `pop()`             | enter `/x`; then leave `/x`, focus the page below                    |
| `replace('/y')` on a pushed page       | leave the old, enter the new                                         |
| a `go` that a guard redirects          | only the final location's events: the redirected-from one never ran  |
| a `go` out of a tab layout             | leave every entered page of every tab, newest first, then enter      |
| a deep link to `/products/1`           | enter `/products/1` only; `/products` enters the first time it shows |
| a location with no route               | no hooks; the previous page leaves                                   |

**Errors.** A hook that throws is caught and reported with `FlutterError.reportError` (library
`fespalier`, context `while running onEnter of products/$id/observe.dart`, the hook and the file filled
in), and the hooks after it still run. In a widget test that fails the test. **Hooks fire after the
frame**, not at `context.go()`: a test pumps first (`await tester.pump()`). No hook runs when the router
is disposed or the app is killed, and layouts and sections have none. A hook may navigate, and it is
looked at at the end of the next frame; to redirect, use a [guard](#guards) instead. `fsp new
'orders/[id]' --observe` writes the file. An `observe.dart` with no `page.dart` at or below its folder is
a warning, and one with none of the three functions an error.

### Not-found views

A `not_found.dart` at the root is the app-wide one. Any other folder can have one too, and
the nearest wins, for two things:

- **Unknown paths.** An unknown URL shows the `not_found.dart` of the deepest folder it is
  under (a `$dynamic` folder matches any value), or the root's. With `teams/$teamId/not_found.dart`
  and `teams/$teamId/members/not_found.dart`, `/teams/a/members/1/x` shows the members one,
  `/teams/a/x` the team one, and `/nope` the root's. This is what `AppRoutes.notFound(uri)`
  does, and the router's `errorBuilder` calls it. The view shows without any layout, as ever.
- **Unparsable segments.** `/teams/a/members/abc`, where a member's id is an `int`, shows the
  nearest `not_found.dart` above that route (a `(group)`'s counts here).

**What it gets.** `Uri uri`, and the segments of its own path as `String`s, as the URL spells
them (`teams/$teamId/not_found.dart` can take `String teamId`). They are raw on purpose: a
segment that didn't parse (`abc` where an id is an `int`) is often the reason you are here, so
a not_found.dart can't ask for it typed, and one that declares `int teamId` is an error that says
so. The value is the decoded path part: `/teams/Acme%20Co/members/x` gives `Acme Co`. It gets
no query parameters and no data. `fsp new members --not-found` scaffolds one (with the segments
it can take).

A `(group)` folder adds nothing to the URL, so its
`not_found.dart` can't be picked for unknown URLs: only for its own routes' bad segments.
Two folders with the same URL (`(a)/x` and `(b)/x`) can't both have one; that's an error.
When the tree is mounted under a prefix (`mount(at: '/shop')`), the prefix is skipped when
looking for the folder, and a URL outside it gets the root's.

### Transitions

`transition.dart` says how a route animates in. It applies to its folder's route and
every route below it, and the nearest one wins. A `transition.dart` at the root is the
app-wide default; any folder or `(group)` folder can override it for its own routes.

The function returns a `Page`, and takes the page's key as `LocalKey key`, the page
itself as `Widget child`, and optionally `GoRouterState state`. `Transitions` has
ready-made ones: `fade`, `slide`, `none`, `material`, `cupertino`, and `dialog`, `sheet`
and `fullscreenDialog` (below). Every one but `dialog` and `sheet` takes `heroes:`
([shared elements](#shared-elements-heroes), since 0.8.1).

```dart
// lib/app/transition.dart: every route fades in, unless a folder overrides it
Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);
```

The `key` is go_router's `state.pageKey` (the path template) for a route's page, unless the route
[remounts](#remounting-a-page-remount) (since 0.6.0): then it is a key that changes with the URL, and
a change makes the page a new one, which this transition plays for.

**A layout's shell is a page too.** The `ShellRoute` a `layout.dart` makes, and a tab layout's
`StatefulShellRoute`, take the nearest `transition.dart` (the layout folder's own included) as
their `pageBuilder`, so a layout moves like any other page when a route on the
[root navigator](#the-root-navigator-navigatordart) opens over it. The shell's page key is
`ValueKey<String>('layout:(tabs)/')`, made from the layout's folder: it is the same on every
launch (its restoration id, see [State restoration](#state-restoration)) and while you
switch routes inside the shell, so **only entering or leaving the shell animates it**, not going
from one page of the layout to another. A layout with no `transition.dart` above it keeps
`layoutPage(…)`. Since `fsp init` writes a root `transition.dart`, that means most apps' shells now
have a `pageBuilder` of their transition's making: regenerate and check your layouts.

A `transition()` that needs to tell a shell from a route (to wrap a route's page in something
its shell shouldn't get) can take `bool shell` (or `isShell`): `true` for a layout's shell, `false`
for a route's page. It is the only extra parameter besides `key`, `child` and `state`.

**Dialogs and sheets.** `Transitions.dialog`, `Transitions.sheet` and
`Transitions.fullscreenDialog` make a route open over the previous page instead of
replacing it. The page's widget is what shows up: for `dialog` it is the dialog itself
(an `AlertDialog`, a `Dialog` or your own card, as in `showDialog`'s builder), for `sheet`
the sheet's content (wrapped in a `Material`), and `fullscreenDialog` is a Material page
that slides up, with a close button in its `AppBar`.

```dart
// lib/app/photos/$id/transition.dart: /photos/:id is a dialog over /photos
Page<void> transition(LocalKey key, Widget child) => Transitions.dialog(key, child);

// lib/app/photos/sort/transition.dart
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.sheet(key, child, showDragHandle: true);
```

They are real Navigator routes (a `DialogRoute` and a `ModalBottomSheetRoute` made by the
page), so everything works as it does for `showDialog`: `context.pop()`, the back button
and the barrier pop the route, and `dialog` and `sheet` take options such as
`barrierDismissible`, `isScrollControlled` and `enableDrag`. A few things to know:

- **Put the route below a page.** The page underneath stays built and visible. go_router
  builds a deep link's stack from the parents that have a page, so with `photos/page.dart`
  above `photos/$id/`, `/photos/7` opens the dialog over `/photos`. Without a parent page,
  the dialog opens over an empty screen. (A route with
  [`nest = false`](#a-sibling-with-a-compound-path) is not below the page of the folder above it,
  so it opens over the page above that one.)
- **They cover their own navigator only.** Inside a tab, a dialog covers that tab's
  navigator, not the tab layout's navigation bar; the same goes for a `layout.dart`'s
  body. Put the route outside the layout's folder to cover the whole screen, or give it a
  [`present.dart`](#presentdart-a-page-of-your-own) (which puts it on the root navigator) or a
  [`navigator.dart`](#the-root-navigator-navigatordart) beside its `transition.dart`.
- **They need `MaterialLocalizations`,** like `showDialog` and `showModalBottomSheet`: a
  `MaterialApp` (or a `Localizations` with the Material delegate) above the router.
- The route's `transition.dart` also covers routes below it, so give a dialog route its own
  folder.

Routes with no `transition.dart` above them keep go_router's default for your app type:
the platform transition under a Material or Cupertino app, none otherwise (see the go_router
18 note in [Getting started](#getting-started)). Scaffold one with `fsp new … --transition`.

#### Shared elements (heroes)

Since 0.8.1, a shared element that flies from a list to a detail page is one line on each side:
`route.hero(name, child: ...)` on every typed route.

```dart
// lib/app/products/page.dart: in the row of each product
leading: ProductRoute(id: p.id).hero('avatar', child: CircleAvatar(child: Text(p.name[0]))),

// lib/app/products/$id/page.dart
ProductRoute(id: product.id).hero('avatar', child: CircleAvatar(radius: 40, child: Text(product.name[0]))),
```

The tag is the route's path (its location without the query, mount prefix included) and the name,
so both sides agree when they name the same route and the same element, and `ProductsRoute()` and
`ProductsRoute(sort: Sort.name)` share theirs. `hero` is an extension (`RouteHeroes`) of the typed
routes, not a member, so a route with a query parameter called `hero` still compiles (it shadows the
extension; `RouteHeroes(route).hero(...)` still reaches it). `route.heroTag(name)` is the tag alone
(a `RouteHeroTag`), for a `Hero` of your own. A name is any object: an app's own `enum` keeps it
typo-proof. Nothing is generated: `app.g.dart` doesn't change.

`hero` builds a `RouteHero`, which is Flutter's `Hero` with one difference: it stays out of flights
while its tab is not shown (`TickerMode` is off for it, as go_router's tab container and
`examples/tabs`' set it on the tabs they hide). Two tabs can then show the same tag, and a route on
the [root navigator](#the-root-navigator-navigatordart) that opens over the tab bar flies from the
tab that is shown. With a plain `Hero`, that is Flutter's _"There are multiple heroes that share the
same tag within a subtree"_ assertion in debug.

**The flight style** is declared in `transition.dart`: `Transitions.fade`, `slide`, `none`,
`material`, `cupertino` and `fullscreenDialog` take `heroes:`, a `Heroes` with three options.

```dart
// lib/app/transition.dart: iOS-style pages, and heroes that follow the back swipe
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.cupertino(key, child, heroes: const Heroes(onBackGesture: true));
```

| `Heroes` option | What it does                                                                                                          |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| `onBackGesture` | heroes also fly while the user swipes back (`Hero.transitionOnUserGestures`); `false` by default                      |
| `path`          | `HeroFlightPath.platform` (the navigator's: an arc in a Material app, a line in a Cupertino one), `arc` or `straight` |
| `shuttle`       | what is shown while flying (`Hero.flightShuttleBuilder`); the destination's child by default                          |

`heroes:` wraps the page's child in a `RouteHeroScope`, which every `RouteHero` below it reads; the
nearest `transition.dart` that passes `heroes:` decides, and one that doesn't leaves the tree as it was
before 0.8.1. A layout's shell takes it too, so the scope covers every page inside the layout. A
`RouteHero`'s own `onBackGesture:`, `path:` and `shuttle:` override it for that hero. A
[`present.dart`](#presentdart-a-page-of-your-own) page, or a `Page` of your own, wraps its child in a
`RouteHeroScope(heroes: ..., child: ...)` itself.

What flies, and what doesn't:

| Situation                                                                                                                                              | What happens                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| List to detail in one navigator (the app, a `layout.dart`, a tab)                                                                                      | flies on push and on pop                                                                                                                                                                                     |
| A route on the root navigator (`navigator.dart`, a `present.dart` that builds a `PageRoute`, a route outside the layout) over a page in a shell or tab | flies from the tab that is shown                                                                                                                                                                             |
| A hero in a tab that is not shown                                                                                                                      | out of flights. A custom tab [`container`](#tab-layouts) must wrap the tabs it doesn't show in `TickerMode(enabled: false)`, as go_router's and `examples/tabs`' do                                          |
| Switching tabs (`goBranch`)                                                                                                                            | nothing flies: no route is pushed, the `container` is the tab animation                                                                                                                                      |
| `Transitions.dialog`, `sheet`, or a `present.dart` that builds a `PopupRoute`                                                                          | nothing flies: Flutter flies heroes between page routes only. Use `fullscreenDialog`, `material` or a `PageRoute`                                                                                            |
| A [remounted](#remounting-a-page-remount) page                                                                                                         | it is a new route: a tag made from the segments differs between the two pages, so nothing flies, while a tag that is the same on both pages flies                                                            |
| A page with [`data.dart`](#datadart-a-function-a-selector-or-a-provider) or a [deferred](#deferred-routes-a-pages-code-on-demand) one                  | flies when the page is in the destination's first frame: [preload it](#preloading-the-data-behind-a-link) (`RouteLink(preload: Preload.intent)`, `route.preload`), or `loading.dart` shows and nothing flies |
| A back swipe or predictive back                                                                                                                        | flies only with `onBackGesture: true` on **both** pages (Flutter checks each side): set it in the root `transition.dart`                                                                                     |
| One tag twice on one page                                                                                                                              | Flutter's assertion: give the second one another name, or wrap it in `HeroMode(enabled: false)`                                                                                                              |

A hero name declared in a deferred `page.dart` would make the list page import that page and load
it eagerly (and the [deferred](#deferred-routes-a-pages-code-on-demand) type rule applies to enums),
so keep an enum of names in a file of its own. `examples/shop` (the product avatar, list to detail)
and `examples/tabs` (the profile avatar, over the tab bar) use it.

### The root navigator (`navigator.dart`)

A route's URL and the navigator it renders on are two decisions. A tab layout puts every route
in its folder on a tab's navigator, under the navigation bar. `navigator.dart` says that a
folder renders on the **root** navigator instead, above every layout and tab bar, without
moving its URL:

```dart
// lib/app/(tabs)/profile/edit/navigator.dart
const navigator = RouteNavigator.root;
```

`/profile/edit` is still under `/profile` (a deep link builds the Profile tab beneath it, and back
returns to it, with its state), and the page covers the whole screen. The declaration applies to
its folder's routes and to **every folder below it**, and the nearest one wins, like
`transition.dart`; a page-less `(group)` folder can hold it too, for the routes inside. `fsp gen`
emits `parentNavigatorKey: rootNavigatorKey` on the route and on all its descendants (`go_router` puts a
route on its enclosing shell's navigator unless it says otherwise, so a child pushed from the page
would land _under_ it), and the route table marks them `(root)`.

The generated file owns the key: `AppRoutes.rootNavigatorKey` is a `GlobalKey<NavigatorState>` the
app can read (the last `router()` or `mount()` call's: a call that is given no key makes a fresh one
rather than keeping an earlier call's, since 0.5.0); `AppRoutes.router(navigatorKey: …)` uses one you supply; and
`AppRoutes.mount(at:, navigatorKey: …)` takes the **host** `GoRouter`'s own key, since a
`parentNavigatorKey` must name an ancestor navigator.

- `fsp` reads the file from the source, like `tabs`: a `const navigator` that is
  `RouteNavigator.root` or `RouteNavigator.shell`, spelled out; anything else is an error at it.
- **A layout is a navigator of its own.** A `layout.dart` below a root folder becomes a
  `ShellRoute(parentNavigatorKey: rootNavigatorKey, …)` (or the `StatefulShellRoute`); the routes
  inside it sit on its own navigator, since go_router doesn't allow a key other than the shell's
  there. Below a layout nothing is inherited, and `RouteNavigator.shell` is what a folder says to
  be explicit about it. Below a root route with **no** layout in between, `.shell` is an error:
  go_router only lets a descendant use the root navigator or a navigator above it.
- **A root route can't be a direct child of a shell.** go_router lifts a route out of its shell
  only from below another route, so a root route that is the first route of a tab, or sits beside
  others directly in a layout, is an error (put it below a `page.dart` that stays in the layout, or
  move its folder out of the layout's folder).
- The typed route is unchanged: `EditProfileRoute().push(context)` and `.go(context)` as before.

`examples/tabs` does this for `/profile/edit`; its tests check that there is no `NavigationBar`, that
back returns to the tab, and that a deep link builds the tab underneath.

### `present.dart`: a page of your own

`present.dart` builds **this route's own `Page`**. It is for a sheet (or a dialog, or any page
class the app owns) with a URL: `/products/:id/buy` opens a sheet over `/products/:id`, from a
link or a deep link.

```dart
// lib/app/products/$productId/buy/present.dart
Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);
```

It is bound like `transition.dart` (`key`, `child`, `state`), and what it returns is used
**verbatim**: fespalier adds no scrim, handle or shape, and ships no sheet widget. Unlike
`transition.dart`:

- it applies to **its own folder only**: a folder below keeps the nearest `transition.dart` for
  its own page;
- it puts the route on the **root navigator**, over a tab bar and any `layout.dart`, and its
  descendants too (the [`navigator.dart`](#the-root-navigator-navigatordart) rules, so a child of
  a sheet renders above it, never under it, and go_router never builds the shell twice). A
  `navigator.dart` in the same folder overrides that (`RouteNavigator.shell` keeps a sheet in
  a tab);
- it needs a `page.dart` (a warning and no effect otherwise), and, to have a parent underneath on a
  deep link, the sheet's folder should sit below the parent page's folder.

The route table marks it `(present, root)`, and the manifest's `presentation` is
`RoutePresentation.custom` (fespalier can't know it is a sheet: say so in a `meta.dart` if you want
to). `examples/features` has `/photos/share`, with an app-owned `SheetPage` in `lib/`, a
child page above it, and tests for the deep link, the parent's state after popping, and the root
navigator.

### Query parameters

A query parameter's type comes from the parameters that ask for it, like a segment's:
`T?` for a single value, `List<T>` for repeated ones. Every file of a route that asks
for `?page` must agree on its type. A missing or unparsable value is `null` (or left out
of a list); unlike a bad segment, it never leads to not-found. The typed route takes
query parameters as optional arguments and writes them into `.location`, leaving out
nulls and empty lists. A query parameter can be an [enum](#enum-segments) too (`Sort? sort`,
`List<Sort> sorts`): a value that names none is `null`, and `.location` writes `.name`.

`data.dart` can take query parameters too, and its provider is then keyed by them, so
`/search?page=2` and `?page=3` load separately. A `List` works as a key too: lists
compare by identity, so the generated provider is keyed by a `QueryList` (a `List` with value
equality, exported by fespalier) holding the same elements, and `?tags=a&tags=b` is one provider
however many times the page builds a new list. Your `data()` still takes and receives a plain
`List<String>`, and the typed helpers take one (`SearchRoute.watch(ref, tags: ['a', 'b'])`).
Order counts: `[a, b]` and `[b, a]` are different keys. (A provider you write yourself can't
be keyed by a query parameter, only by segments.)

To change one query parameter of the current location from a widget, see
[the URL as state](#the-url-as-state-of-and-copywith): `SearchRoute.of(context).copyWith(page: 2).go(context)`.

```dart
// search/data.dart
Future<List<Hit>> data(Ref ref, {String? q, int? page, List<String> tags = const []}) => …;

// search/page.dart
class SearchPage extends StatelessWidget {
  const SearchPage({super.key, required this.hits, this.q, this.tags = const []});
  final List<Hit> hits;        // required, and data.dart's type → the data
  final String? q;             // optional and nullable → ?q=
  final List<String> tags;     // optional List → every ?tags=
  …
}
```

### The URL as state: `of` and `copyWith`

_Since 0.5.0._ A filtered, sorted, paginated list that keeps its state in the query is a link
someone can send, and back and forward move between its views. Every typed route has two ways in
and one way to change a part of it:

```dart
final route = SearchRoute.of(context);          // the typed route at the current location
final maybe = SearchRoute.maybeOf(context);     // null instead of throwing

route.copyWith(page: (route.page ?? 1) + 1).go(context);          // a history entry
route.copyWith(sort: Sort.name, page: null).go(context);           // null clears a query parameter
SearchRoute(q: 'ap').copyWith(page: 2).location;                   // '/search?q=ap&page=2': a value, no widget
```

- **`XRoute.of(context)`** parses the location the widget belongs to, with the parsers
  [`AppRoutes.match`](#from-a-location-to-its-data) uses (it calls `AppRoutes.matchUrl`): the
  mount point is taken off, a [localized spelling](#localized-paths) is the route it spells, and the
  [case setting](#case-and-trailing-slashes), [enums](#enum-segments), lists and
  [catch-alls](#catch-all-segments) read as they do for the page. It throws a `StateError` that
  names the location when it is another route; `XRoute.maybeOf(context)` returns `null`. Use `of`
  in a widget below the page that wasn't handed the parameters; the page itself already has them
  as constructor arguments and rebuilds when they change. (A `const` route stays `const`:
  `of` and `copyWith` are members, not constructor parameters.)
- **Which location.** It is `GoRouterState.of(context)`'s: the route around the widget, not
  whichever page is on top. A page reads the part of the URL its own route matched, with the URL's
  query, so `/products/42?ref=mail` leaves the page of `/products` below it reading
  `ProductsRoute(ref: 'mail')`, and a page under a pushed one, a tab that is built but not shown
  (`preload`) read their own. A layout (a shell, a tab layout) is above any
  one page and reads the whole location. Outside any route (`MaterialApp(home: ...)`) `of`
  throws go_router's `GoError`, `maybeOf` returns `null`. A widget that calls it depends on its
  route's state and rebuilds when it changes, as with `GoRouterState.of`; call it in `build` or in
  a handler of a mounted widget, not after it is disposed.
- **`copyWith`** takes every segment and every query parameter of the route, by name and with the
  field's own type. One left out keeps its value; **`null` clears an optional query parameter**
  (`page: null` leaves `?page=` out of the location), which is not the same as leaving it out. A
  segment, and a `List` (a repeated query parameter or a catch-all), is not nullable, so
  `copyWith(id: null)` doesn't compile: clear a list with an empty one (`tags: const []`). It
  returns the same route class, so `.go`, `.push`, `.replace` and `.location` follow. What isn't a
  parameter isn't carried: an `extra` is given again to `go(context, extra: ...)`, and the
  localized spelling is chosen where the route is used (`go(context, locale: 'de')`), not by the
  copy.
- **How null differs from omitted.** `copyWith` is a getter whose type is a function with the
  fields' types (`SearchRoute Function({String? q, int? page, Sort? sort})`), and the function
  behind it has the parameters as `Object?` with a private `const` sentinel as the default. The
  caller sees the clean signature; the sentinel is only visible in `app.g.dart`, and nobody can
  pass it. See [Design notes](#design-notes).
- **`go`, `push`, `replace`.** `go` follows the URL: on the web it adds a history entry, and back
  and forward restore each view. `replace` (since 0.6.0) shows its location in the address bar too
  and replaces the history entry instead of adding one, so it is the one for a change that
  shouldn't pile up in the back stack (typing in a search box). When the page on top is part of the
  declarative stack it is `go` inside Flutter's `Router.neglect`, on every platform: the stack
  becomes the one the new location has by itself, and a page with the same path template keeps its
  state. When the top was `push`ed, `replace` is go_router's own, which swaps that page and keeps the
  stack below it. `push` stays out of the address bar and the history unless `push_updates_url: true`
  is set in [the pubspec](#getting-started) (since 0.6.0). On 0.5.0 `replace` was go_router's in
  every case: the address bar followed it only when no page was below it (as a new history entry),
  and showed the page below's URL otherwise, so use `go` for URL state there.
- **`pushReplacement`** (since 0.7.0) is go_router's own, typed like `push`: the page on top leaves
  and a new one is pushed, with a new page key, and the future completes with what that page pops
  with. Use it where `replace` is wrong because the page's state or transition must not carry over:
  a sheet that hands over to a full page, or the reverse. `replace` over a pushed page keeps its key (go_router's `replace`); over a page of the declarative stack it is a `go`, which keeps it only for the same path template. The replaced page's own
  future never completes, and when it was the only page, neither does this one (go_router's
  behaviour). Both take `locale:`, and `extra:` where the route has one.
- **Reserved names.** `of`, `maybeOf` and `copyWith` are members of the route class, so
  they can't be segment or query names (see
  [Typed helpers on the route](#typed-helpers-on-the-route)).
- **Cost.** Both are synchronous and use no timer or microtask. `of` matches the location with the
  generated matchers and builds one route; `copyWith` builds one (plus the small function it returns).
- **The page's own state.** A `copyWith` that only changes query parameters keeps the page and its
  widget state under `never` (the default) and `onSegments`, and starts the page again under
  `onLocation`. To keep that state across `page: 2` and still start fresh for another product,
  say `Remount.onSegments`: see [Remounting a page](#remounting-a-page-remount).

`examples/shop` keeps the list's sort and page this way (`products/page.dart`, and
`test/url_state_test.dart` with back and forward); `examples/features` has the enum, list,
catch-all and localized cases and `examples/tabs` the tabs.

### Remounting a page: `remount`

_Since 0.6.0._ A page keeps its widget state when only its URL parameters change. go_router keys a
page by its path template, so `/products/1` to `/products/2` is the same page: its widget is built
again with the new `id`, but its `State` (a scroll position, a text field, a hook's `useState`)
lives on. Some apps want that, others want a fresh page, and it depends on the app, so it is a
setting. `Remount` is an enum fespalier exports, with three values:

| Value                     | The page starts again (a fresh state) when                    | It keeps its state when                         |
| ------------------------- | ------------------------------------------------------------- | ----------------------------------------------- |
| `never` (the default)     | never: what fespalier generated before 0.6.0                  | anything changes in the URL                     |
| `onSegments`              | the value of a segment changes (`/products/1` to `/2`)        | only the query changes (`?page=2`)              |
| `onLocation`              | anything changes in the location, the query included          | the location is the same                        |

`onSegments` is the one that fits [the URL as state](#the-url-as-state-of-and-copywith): the page
keeps its state across `XRoute.of(context).copyWith(page: 2)`, and starts again on another product.

**Where to say it.** For the whole app, in the pubspec's `fespalier:` section, with `never`,
`on_segments` or `on_location`:

```yaml
fespalier:
  remount: on_segments
```

For a folder, in its `route.dart`, which then covers that folder and everything below it, the
nearest one winning over the parent's and over the pubspec, like
[`caseSensitive`](#case-and-trailing-slashes):

```dart
// lib/app/products/route.dart
import 'package:fespalier/fespalier.dart';

const remount = Remount.onSegments;
```

It is read from the source when the tree is generated, never imported or run, so it must be
`const` and one of `Remount.never`, `Remount.onSegments` and `Remount.onLocation`, written out
(an import prefix, `fsp.Remount.onSegments`, is fine), and declared once; anything else is an
error with a code frame, and so is a pubspec value that isn't one of the three (the message lists
them). Like `caseSensitive` it is inherited by `(group)` folders and folders without a page, needs
no page beside it, and a folder can say `Remount.never` to go back to the default under a parent
that remounts. `fsp routes` tags such a page `remount`, and `--json` says which in a `remount` key.

**What it keys.** Only the page of a route. The generated code gives the page a key that changes
with the URL where it used to use go_router's `state.pageKey`:

- `onSegments`: the template plus the values of the route's own path parameters, those of the
  folders above it included (`/teams/:teamId/members/:member` starts again when either changes),
  as the URL spells them. The static parts of the path (their
  [case](#case-and-trailing-slashes), a [localized spelling](#localized-paths)) are not in it. A
  route with no segment has nothing to watch, and is generated as if it were `never`.
- `onLocation`: the template, the path matched down to this route and the whole query. The fragment
  (`#top`) is not in it. A page below which another is pushed (`/orders/1` under `/orders/1/refund`)
  keeps its key and state, because the path is the route's own, not the whole location's.

A layout is not remounted, whatever its folder says: its page is keyed by its folder so that it and
its [sections](#section-data) outlive a change of the URL (the pages inside it start again by their
own `remount`). Give a widget in a layout a `ValueKey` of your own if it should start again.

**A new key is a new page.** go_router treats a page with another key as another page, not an
update of the one it had: the navigator replaces the old page with the new one, so the page's
transition may play, and the old page leaves with its own. How it looks is the page's
[`transition.dart`](#transitions) (or [`present.dart`](#presentdart-a-page-of-your-own)), which
receives the key as its `LocalKey key` parameter, as before; pass it on to the `Page` you build,
as `Transitions.fade` does. A `transition.dart` that takes no key can't give the new page one, so
`remount` has nothing to act on there, and the generator warns that `remount` has no effect there.
Without a `transition.dart` the page is a Material page, or a Cupertino one inside a
`CupertinoApp`, built like a layout's page is (`remountPage`). Use `Transitions.none` for a page
that should start again without animating.

**Not what it is for.** It restarts the page's widgets, not its data: a `data.dart` provider is
keyed by the segments and the query already, and reloads (see
[Retries and reloads](#retries-and-reloads)) whether the page remounts or not. And it does not
change which route matches or what `XRoute.of(context)` reads.

`examples/features` has all three, under `remount/` (`never/` and `segments/` override the
`onLocation` of `remount/route.dart`), with a widget test that presses a button, changes the URL
and reads the count; `packages/fespalier/test/remount_test.dart` has the runtime.

### Typed `extra`

go_router can carry an object with a navigation, `context.go(location, extra: product)`,
that isn't part of the URL. A page asks for it with a parameter called `extra`, and the
typed route takes it as an optional argument:

```dart
// notes/$id/page.dart
class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, this.extra});
  final int id;
  final Note? extra;      // nullable: the URL alone can't produce it
  …
}

NoteRoute(id: 3).go(context, extra: note);      // also push<T>(…, extra:), pushReplacement<T>(…, extra:) and replace(…, extra:)
NoteRoute(id: 3).go(context, extra: 'oops');    // compile error: a String isn't a Note?
```

The parameter **must be nullable** (`Note?`, `Object?` or `dynamic`; anything else is an
error at that parameter). The object isn't in the URL, so a deep link, a page opened from
`context.go('/notes/3')` and (without an [`extraCodec`](#restoring-extra-on-the-web)) a
reload or a restored state all get `null`: build the page from the URL (`id`) and treat
`extra` as a shortcut, not the source of truth. Passing an object of the wrong type around
the typed route (a plain `context.go(location, extra: …)`) is an assertion error in debug
builds and reads as `null` in release builds.

`extra` is a reserved name: a segment can't be called `extra`, and a query parameter of
that name is the extra, not `?extra=`. The generated file has to name the type for the
typed arguments, which is the one place it copies from your imports: it imports the type
`show`ing that name from each of the file's imports (a library that doesn't export it is
ignored; a type declared in the file itself, or under an import prefix, is found too),
so the type must be reachable from the file's own imports. The built-in `dart:core`
types need nothing.

**Layouts, guards and redirects take it too.** A `layout.dart`, a `guard.dart` or a
`redirect.dart` can ask for `extra` the same way (a nullable type; a guard and a redirect take
it as a named parameter). Each gets the extra of the location it is at now, `state.extra`:

```dart
// notes/layout.dart: the frame above every note
class NotesLayout extends StatelessWidget {
  const NotesLayout({super.key, required this.child, this.extra});
  final Widget child;
  final Note? extra;
  …
}

// notes/$id/guard.dart: a draft isn't shown yet
GuardResult guard(Ref ref, {Note? extra}) =>
    extra?.title == 'draft' ? const HomeRoute().location : null;
```

A layout or a guard sees the extra of _every_ route it covers, so its type has to fit theirs,
or it's an error at its parameter, with a code frame that lists the routes:

- A guard or layout takes `Object?` (or `dynamic`) to accept anything, or **the type of the
  routes it covers**: `Note?` above pages that take `Note?`. Nullability aside, the names have
  to match. A route that takes no extra puts no condition on it.
- So a layout above routes with different extra types must take `Object?`; otherwise the
  routes that don't fit are listed:

  ```text
  error: `extra` is `Note?` here, but the routes it covers take other types: `/notes/:id/print`
         (notes/$id/print/page.dart takes `Receipt?`); a layout sees the extra of every route it
         covers, so declare it as `Object?` to accept any of them, or as their type when they share one
    ┌─ lib/app/notes/layout.dart:3:53
  ```

  A page's or redirect's own type decides for a route; on a route without one, the guards and
  layouts above it must agree with each other. A layout isn't compared with a `redirect.dart`
  route below it, which never shows it.

- A route that takes no extra of its own gets the type its guards and layouts agree on, so
  `NoteRoute(...).go(context, extra: note)` is typed even if the page ignores it.
  `Object?` says nothing about a type: it adds no typed argument.
- **A wrong type never crashes them.** A layout, a guard or a redirect sees extras meant for
  other routes, so an object that isn't a `Note` reads as `null` (`extraOrNull`), and so does an
  extra that isn't there. Only a page asserts, as above. The type is nullable so that `null`
  always fits.

#### Restoring `extra` on the web

go_router keeps a navigation's `extra` next to its location, for the browser's history and for
state restoration, but can only save what is JSON. Without help, an object with a `toJson()`
comes back as the JSON `jsonEncode` made of it (a `Map`), and any other object is dropped
(and go_router logs a warning): neither is your type, so a page that asks for a `Note?` gets
`null` in release builds and, for the `Map`, an assertion in debug builds. To get the object
back, give the router an `extraCodec`.

Put a top-level `extraCodec` in `lib/app/extra_codec.dart`, at the root of the app folder (a
`const`, a `final` or a getter; `fsp` only looks for the name). The generated
`AppRoutes.router()` passes it as `GoRouter(extraCodec: …)`:

```dart
// lib/app/extra_codec.dart
import 'package:fespalier/fespalier.dart';

final extraCodec = ExtraCodec({
  Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
  Mode: (toJson: (Mode m) => m.name, fromJson: Mode.values.byName),
});
```

`ExtraCodec` takes each type and how it becomes JSON and back (annotate the parameter of
`toJson`; a constructor tear-off does for `fromJson`), and saves an object under its type's
name. `null`, strings, numbers, booleans and plain JSON lists and maps need no entry. It
never breaks navigation: an object whose type isn't registered is saved as `null`, and saved
data that no longer reads (the type was removed, or `fromJson` throws) comes back as `null`,
so a page falls back to what the URL says. Pass `strict: true` to throw instead, in a test that
checks you registered every type.

- The type is looked up by its exact runtime type: register each subclass of a sealed class.
- The name is `Type.toString()`, which a release build for the web minifies (stable within a
  build, different in the next). To keep saved data readable across deployments, name the types:
  `ExtraCodec({...}, names: {Note: 'note'})`.
- Write your own `Codec<Object?, Object?>` instead if you like (`const extraCodec = MyCodec();`).
- `AppRoutes.mount()` doesn't take it: a router you build yourself passes
  `extraCodec: extraCodec` (imported from that file) to `GoRouter`. A router restores only what
  it is given a `restorationScopeId` for (see [State restoration](#state-restoration)).
- `extra_codec.dart` in a subfolder is a warning, and a file without an `extraCodec` is an
  error.

`examples/tabs` does this for a `ProfileDraft` passed to its edit page, and its restoration test
restarts the app and checks the draft is still there (and, for contrast, what a router without the
codec restores). `examples/features` has a layout and a guard that read a `Note?` extra.

### `data.dart`: a function, a selector or a provider

`data.dart` has three forms, told apart by what it exports:

| You write                                                                                                                                | fespalier                                                                     | Use it when                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `Future<T> data(Ref ref, {…})` (or `Stream<T>`, or `T`)                                                                                  | wraps it in an autoDispose `FutureProvider` (`StreamProvider` for a `Stream`) | the data is fetched for this route only: the function is the fetch                                       |
| `ProviderListenable<AsyncValue<T>> data({…}) => productProvider(id)`                                                                     | calls it and uses the provider it returns; nothing is wrapped                 | a provider for it already exists, above all a `riverpod_generator` one                                   |
| `final data = FutureProvider<T>(…)` (or `StreamProvider`, `AsyncNotifierProvider`, `StreamNotifierProvider`), type arguments spelled out | uses it as-is                                                                 | you want to write the provider yourself (a notifier, `keepAlive`, `retry:`) and it belongs to this route |

**Selecting a provider.** Don't write `Future<Product> data(Ref ref, …) => ref.watch(productProvider(id).future)`
for a provider you have: that puts a second provider in front of the real one, and awaiting
`.future` in it drops the error the real provider holds while it retries, so the route
can't show `error.dart` during the retry window. Select the provider instead:

```dart
// lib/app/products/$productId/data.dart
ProviderListenable<AsyncValue<ProductView>> data({required String productId}) =>
    productProvider(productId);   // a generated family, a FutureProvider.family, ...
```

- **The return type is what says so.** `ProviderListenable<AsyncValue<T>>` with no `Ref`
  parameter (the function returns the provider, it doesn't read one). `T` is what the
  page's parameter is matched to by type, as with `Future<T>`. It's a syntax-only read of the
  return type: a generated provider's own type, like `ProductFamily`, isn't resolved.
  `ProviderListenable` comes from `package:fespalier/fespalier.dart`.
- **Parameters are the function form's.** Named parameters are segments and query
  parameters, keyed and typed exactly as in `data(Ref ref, {…})` below; any other parameter is
  an error at that parameter. Positional parameters and a `Ref` are errors too.
- **`XRoute.data` is the selected provider** (`ProductDetailRoute.data('x') ==
productProvider('x')`), and `watch`, `read`, `prefetch` and `refresh` all go to it. The
  generated `DataView` watches it directly: no wrapper, no `.future` hop, one fetch per
  navigation. `refresh` (and `error.dart`'s `retry`) invalidates the selected provider, and
  `refresh` reads it again, so it runs once.
- **The app's provider keeps its own `retry`, `keepAlive` and dependencies**, so
  [`data_retry`](#retries-and-reloads) doesn't apply to it: it only configures the providers
  fespalier creates. `keep_previous` does (it is about what the view shows). The app's
  `ProviderScope(retry: …)` applies unless the provider sets its own.
- **Refresh needs a provider, not just a listenable.** Watching only needs a
  `ProviderListenable`, but invalidating needs the provider itself. The declared type stays
  `ProviderListenable<AsyncValue<T>>`, the same for every kind of provider, and the runtime
  checks what it gets (a `ProviderOrFamily` with a `.future`, which every
  `FutureProvider`, `StreamProvider` and generated async provider is). Returning
  something else, say `productProvider(id).select(…)`, builds and watches fine, but
  `refresh` and `retry` throw a `StateError` that says to return the provider itself.
- A section's `data.dart` can be a selector too, and takes segments and query parameters
  like a page's.

The other two: write a function and fespalier wraps it in an autoDispose
`FutureProvider` (or `StreamProvider` for a `Stream`). Or export a provider named `data` yourself:
`FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or `StreamNotifierProvider`,
with its type arguments spelled out. It's used as-is.

In all three forms the route exposes it as `XRoute.data`, keyed by the segments and query
parameters `data.dart` uses:

| Parameters used | Provider                              | Watch it with                                   |
| --------------- | ------------------------------------- | ----------------------------------------------- |
| none            | plain                                 | `ref.watch(ProductsRoute.data)`                 |
| one             | `.family<T, int>`                     | `ref.watch(ProductRoute.data(42))`              |
| several         | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

A family provider you write yourself follows the same rule, for segments: with several
of them, its argument is a record naming the ones it uses, e.g. `({String shop, int id})`.
It can't be keyed by a query parameter (a record field that isn't a segment is an error).
To key by one, write the function form (`Future<T> data(Ref ref, {int? page})`) or select your
provider with a `data()` that takes it (see above).

To see a scaffolded `error.dart` and its retry, throw from `data.dart`, e.g.
`throw Exception('offline')`.

#### Retries and reloads

Two settings in the `fespalier:` section of `pubspec.yaml` decide what a route shows while
its `data.dart` fails or loads again:

```yaml
fespalier:
  data_retry: inherit # inherit | none
  keep_previous: true # true | false
```

**`keep_previous: true` (the default).** `loading.dart` is only for the first load. Once
the provider has a value or an error, a reload (`ref.invalidate`, `refresh`, the section's
dependencies changing) keeps rendering it: the old page stays until the new value arrives,
instead of blinking to `loading.dart` and back. `error.dart`'s `retry` still invalidates the
provider; the error stays up until the new run has an answer. Off, `loading.dart` shows
whenever the provider is loading (a refresh included), except while a write whose
[`optimistic()`](#optimistic-updates-optimistic) patched the data settles (since 0.8.1). This is `skipLoadingOnReload` and
`skipLoadingOnRefresh` on Riverpod's `AsyncValue.when`. It applies to a route's `data.dart` and
to a section's, including a provider you write yourself.

**`data_retry: inherit` (the default).** Riverpod 3 retries a failed provider on its own,
with backoff, and the app's `ProviderScope(retry: ...)` or `ProviderContainer(retry: ...)`
decides how. The providers fespalier generates for `data()` functions don't set their own
policy, so the app's applies. An app that wants a failure to settle into `error.dart` after
a few attempts writes:

```dart
ProviderScope(
  retry: (retryCount, error) => retryCount < 3 ? const Duration(seconds: 1) : null,
  child: …,
)
```

Riverpod's own default (10 retries with doubling delays, none for an `Error`) applies when the
app sets none. A provider you write yourself always follows the app's policy, or its own `retry:`.

Together the two make `error.dart` show as soon as `data.dart` fails, retrying or not:
a provider that failed and is being retried is `AsyncLoading` with its error still held, and
with `keep_previous` on `DataView` shows that error, not `loading.dart`, for the whole retry
window. It goes to the data when a retry succeeds, and stays on the error when the policy gives up.
With `keep_previous: false` a retry shows `loading.dart` again.

**`data_retry: none`.** Every generated `data()` provider gets
`retry: (retryCount, error) => null`, whatever the app's policy is: a failure is final until
`error.dart`'s `retry` runs it again, which is how 0.1.1 behaved.

**A route with a `freshness` or a `dataCache`** (since 0.8.1) keeps its data when a reload fails,
whatever `keep_previous` says: `error.dart` only shows when there is nothing to show (see
[Freshness](#freshness-staletime-resume-and-reconnect)). And `DataView` shows a value that
Riverpod's offline persistence restored (`isFromCache`) while the fresh one loads, with
`keep_previous: false` too.

#### Freshness: `staleTime`, resume and reconnect

Since 0.8.1 a `data.dart` can say when its value is old enough to load again. It is opt in: a
route without the declaration below loads once and keeps the value for as long as something
watches it, as before.

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

/// Fresh for a minute; loaded again when the app comes back to the foreground.
const freshness = Freshness(
  staleTime: Duration(minutes: 1),
  refetchOnResume: true,
);

Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
```

`freshness` is a top-level variable of exactly that name, `const` or `final`, whose initializer is
a `Freshness(...)` call (`const Freshness(...)` and `prefix.Freshness(...)` are fine). fsp does not
read the duration: the generated file refers to `_i13.freshness`, and the Dart analyzer checks it.
It applies to the **function form** that returns a `Future<T>`, a `FutureOr<T>` or a plain `T`. In
a `data.dart` that returns a `Stream`, selects a provider or exports its own `data` provider it is
an error that says what to do instead (below).

**A folder's default.** The same constant in a `route.dart` is the default of every `data()`
function at and below that folder (a [section's](#section-data) included): the nearest
`route.dart` wins, and a `data.dart`'s own `freshness` wins over all of them. A root
`lib/app/route.dart` is the app-wide default.

```dart
// lib/app/teams/$teamId/route.dart
import 'package:fespalier/fespalier.dart';

/// Every data() function at and below /teams/:teamId is fresh for 30 seconds.
const freshness = Freshness(staleTime: Duration(seconds: 30));
```

The cascade is a default, not a demand: a selector, a provider form or a `Stream` below is skipped
without a word. A `route.dart` whose `freshness` applies to no `data.dart` is a warning. There is no
`fespalier:` key for it: a Dart constant is type-checked, and needs no duration grammar in YAML.

**What "stale" means.** A value is stale once it has been in memory for `staleTime` since it
_arrived_ (the `Future` completed; for a synchronous `data()`, the microtask after it was built).
A value that is still loading, or an error, is never stale; Riverpod's retry and `error.dart`'s
retry handle those. Nothing polls: no timer starts, and data on screen that goes stale stays as
it is until something reads it. A stale value is loaded again **when something reads it**:

1. **A new listener.** A page opening on it (`DataView`), a `SectionView` of a page that opens
   below a section, `XRoute.watch` in a widget that mounts, `prefetch` / `preload` /
   `AppRoutes.preload`, a [`RouteLink`](#preloading-the-data-behind-a-link) preloading on hover,
   `XRoute.read`.
2. **A listener coming back.** A page uncovered by a pop, a tab shown again: Flutter turns
   `TickerMode` back on, and Riverpod resumes the subscription.
3. **A signal**, with `refetchOnResume` or `refetchOnReconnect` (below).

The stale value shows **at once** (no `Future`, no blank frame), and the new one replaces it
(stale-while-revalidate). With `keep_previous: true` (the default) the old page stays until the new
value arrives; with `keep_previous: false` `loading.dart` shows while it loads, as for any refresh.
If the load fails, the page **keeps its data** (see `keepDataOnError`, below), the error is in
`XRoute.watch(ref).error`, and `XRoute.refresh(ref)` completes with it.

Things to know:

- **Every new reader counts.** With a small `staleTime`, a section's data loads again each time a
  page below it opens, because that page's `SectionView` is a new listener. `Duration.zero` loads
  on every open, and a prefetch is then only a head start for the first paint.
- **`read` returns what is in memory**, stale or not, and starts the reload. Use `refresh` for a
  value that is surely fresh: it waits for the network.
- **An invalidation is not a read.** `ref.invalidate`, `XRoute.refresh` and an
  [`action.dart`](#actiondart-typed-writes)'s `invalidates` load at once, whatever the `staleTime`:
  `staleTime` is for reads only.
- **`keepFor` is another thing.** `prefetch(ref, keepFor: …)` is how long a handle keeps a value in
  memory with nothing on screen; `staleTime` is how long it counts as fresh. With a ten minute
  `keepFor` and a one minute `staleTime`, opening the page five minutes later shows the kept value
  at once and loads it again. A handle that is still alive across an app resume loads under
  `refetchOnResume` too (it is alive, so it listens); `staleTime` bounds that.

**Resume and reconnect.** `refetchOnResume: true` loads the value again when the app comes back to
the foreground (`AppLifecycleListener.onResume`), and `refetchOnReconnect: true` when
`reconnectSignal` fires. Both use the threshold `staleTime ?? Duration.zero`: without a
`staleTime`, every signal loads again, so set one with `refetchOnResume` unless every focus should
reload (an iOS notification shade or a browser window regaining focus is a resume too). Each is a
Riverpod provider holding a count, a `RefetchSignal`, that the data provider listens to:

- `appResumeSignal` fires on resume. It is created only while a provider with `refetchOnResume`
  listens to it, and its `AppLifecycleListener` goes with it.
- `reconnectSignal` **never fires by itself**: Flutter has no API for "the network is back". Override it with
  a `RefetchSignal` of your own that listens to your connectivity source, or call
  `ref.read(reconnectSignal.notifier).fire()` where you know. `fespalier_connectivity` (since 0.9.0,
  [below](#reconnects-fespalier_connectivity)) is that signal from `connectivity_plus`, tested:
  `reconnectSignal.overrideWith(ConnectivitySignal.new)` in `startup()`.

**Your own provider.** `freshData(ref, const Freshness(...), value)` is what the generated provider
wraps its value in. It returns `value` itself (a `Future` stays the `Future`, a value stays a
value), so a selector's target or a provider-form `data.dart` can give itself the same rules:
`Future<Product> build() => freshData(ref, const Freshness(…), _fetch());`.

**A failed reload keeps the page.** A route whose `data.dart` has a `freshness` or a `dataCache`
(or inherits one) gets `keepDataOnError: true` on its `DataView`: a reload that fails (a stale
value loaded again, a start offline) leaves the page on its data, and `error.dart` only shows
when there is nothing to show. The cost is that a failed `refresh()` is hidden behind the old
page: `refresh()` completes with the error (show a snackbar), and `XRoute.watch(ref).hasError`
is there for a banner.

**Testing.** `testWidgets` runs in fake async and ages data by `clock.now()`, so
`await tester.pump(const Duration(minutes: 6))` makes a value stale without waiting and without a
timer. A resume is `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive)`
and then `.resumed`, or `container.read(appResumeSignal.notifier).fire()` (the container is what
`pumpRouter` returns); a reconnect is `container.read(reconnectSignal.notifier).fire()`. A test
that builds a `refetchOnResume` provider in a bare `ProviderContainer`, with no binding, throws
when the signal is built: use `testWidgets`, or override
`appResumeSignal.overrideWith(RefetchSignal.new)`. Two things need a frame or two to show: a
reload starts on a frame and its value shows on the next, so `pump()` a few times (or
`pumpAndSettle` when nothing waits on a real delay).

`examples/shop` carries `freshness` on `products/$id/data.dart`, `examples/features` the
`route.dart` default on `teams/$teamId/`; each has a `test/freshness_test.dart`.

**Diagnostics.** A `freshness` that is not a `Freshness(...)` call, a second one, one in a
`data.dart` that returns a `Stream`, selects a provider or exports its own `data` provider, and a
`dataCache` in a `route.dart`, are errors that say what to write instead; their messages are in the
[troubleshooting skill](skills/fespalier-troubleshooting/references/diagnostics-data-and-hooks.md).
`freshness` and `dataCache` are names fsp now reads in a `data.dart`, so an app with a public
top-level variable of one of those names and another type gets the first error: rename it (a
private `_freshness` is never read).

#### Reconnects: fespalier_connectivity

Since 0.9.0. `refetchOnReconnect: true` waits for [`reconnectSignal`](#freshness-staletime-resume-and-reconnect), which
never fires by itself. `package:fespalier_connectivity` is that signal, from `connectivity_plus`, tested, with the two
platform repairs below and a `hasNetwork` provider for an offline banner. fespalier's core depends on neither the plugin nor
this package, the generated code is the same bytes, and an app that does not depend on it pays nothing for it.

Add it next to fespalier, with the same `url` and the same `ref` (as for [`fespalier_flags`](#feature-flags-fespalier_flags)):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_connectivity:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_connectivity
      ref: v0.8.1
```

<!-- x-release-please-end -->

It needs Dart 3.8 and Flutter 3.32 or newer, and takes `connectivity_plus` `>=6.0.0 <8.0.0`. One line in `startup()`, which
stays synchronous (no first-frame cost):

```dart
// lib/app/startup.dart
List<Override> startup() => [reconnectSignal.overrideWith(ConnectivitySignal.new)];

// lib/app/teams/$teamId/route.dart: every data() at and below is loaded again when the device gets a network back,
// if its value is at least 30 seconds old
const freshness = Freshness(staleTime: Duration(seconds: 30), refetchOnReconnect: true);
```

**What fires and what does not.** `ConnectivitySignal` fires when the device goes **from no network to a network**
(`[none]` to anything else). It does not fire on the first answer, and not on a Wi-Fi to mobile switch. Every data provider
that listens loads again if its value is at least `staleTime` old (stale-while-revalidate: the old value stays on screen,
and `keepDataOnError` keeps the page if the reload fails); within `staleTime` nothing loads. A reload already under way is
not repeated (a value that is loading is never stale), so a flapping network needs no debounce timer: it fires each time and
loads once. The signal exists while a `data.dart` with `refetchOnReconnect` is alive, and so does its subscription to
`connectivity_plus`: an app with no such data subscribes to nothing.

**A banner.** `hasNetwork` is a `bool` provider: `false` only once the device has said "no network", and `true` before the
first answer, so nothing flashes offline at start. It pairs with `XRoute.watch(ref).isFromCache` ("offline copy"):

```dart
if (!ref.watch(hasNetwork)) const Text('No network')
```

`networkConnectivity` is the `List<ConnectivityResult>?` behind it (null until the first answer), for an app that shows the
kind of network.

**Connectivity versus reachability.** This package, like `navigator.onLine` on the web, answers "is a network interface up?".
That is local, instant and event-driven. Reachability answers "does the server I need answer?", and only a request can tell:

- Connected but unreachable: a captive portal (hotel Wi-Fi before its login page), a router with no uplink, a VPN that is
  down, a firewall, the server down. Reachable over a link the OS reports oddly: a VPN reported as `other` on iOS, the iOS
  simulator's missed Wi-Fi events.
- So `refetchOnReconnect` on connectivity can fire on a captive portal: the reload fails and `keepDataOnError` keeps the
  page. `hasNetwork == false` is reliable ("no network at all"); `true` promises nothing. An offline banner should say "No
  network", and a failed load should show its own error.
- fespalier does not ship reachability: it needs a request to **your** server (not a third party's: privacy, and a third
  party answering says nothing about yours), and any polling is a timer. A compiled recipe in
  [`skills/fespalier-data/references/reconnect-and-network.md`](skills/fespalier-data/references/reconnect-and-network.md) asks
  your own API once per connectivity change and per resume, never on a timer, and turns that into a `RefetchSignal`.

**Two platform repairs.** The web sends nothing when a stream starts listening (only `online` and `offline` events), so the
first state is asked with `check()` (which reads `navigator.onLine`); an event that arrives before that answer wins over it.
And iOS drops connectivity events while the app is in the background (the plugin resyncs "on the next listen or check"), so
`networkConnectivity` asks `check()` again on each resume, through fespalier's own `appResumeSignal`: an offline banner does
not stay up after the network came back in the background. Neither starts a timer.

**Testing.** `package:fespalier_connectivity/testing.dart` has `FakeConnectivity`, a `ConnectivitySource` whose `set`, `offline()`
and `online([via])` deliver a change **synchronously**, whose `check()` answers `now`, and which sends nothing on listen
(like the web). Override `connectivitySource` with it (and `reconnectSignal` with `ConnectivitySignal.new`, as `startup()`
does; `pumpRouter` does not run `startup()`):

```dart
final fake = FakeConnectivity();
await pumpRouter(
  tester,
  AppRoutes.router(initialLocation: '/teams/acme/members/7'),
  overrides: [
    connectivitySource.overrideWithValue(fake),
    reconnectSignal.overrideWith(ConnectivitySignal.new),
  ],
);
await tester.pump(const Duration(seconds: 31)); // the team is stale now (the fake clock)
fake.offline();
fake.online(); // a reconnect: the team loads again, once
await tester.pumpAndSettle();
```

A widget test that reaches the plugin without that override **fails**, with Flutter's report
`while activating platform stream on channel dev.fluttercommunity.plus/connectivity_status` and
`MissingPluginException(No implementation found for method listen on channel dev.fluttercommunity.plus/connectivity_status)`
(a test that shows `hasNetwork`, or builds a `refetchOnReconnect` provider with the package's signal, and no
`FakeConnectivity`). `examples/features` carries it: `teams/$teamId/route.dart` has `refetchOnReconnect: true`,
`startup.dart` overrides `reconnectSignal`, and `test/offline_test.dart` flaps the network.

In debug (`debugPrint`, nothing in a release build):

- `fespalier_connectivity: the connectivity stream reported an error: <error>`
- `fespalier_connectivity: checking connectivity failed: <error>`

Both leave the state as it was. Their causes are in the
[troubleshooting skill](skills/fespalier-troubleshooting/references/diagnostics-flags-storage-network.md).

#### A cache that survives a restart: `dataCache`

Since 0.8.1 a `data.dart` can save its last value, and show it at the next start while the fresh one
loads. It is built on Riverpod 3's **experimental** offline persistence (`persist()` and its
`Storage` interface), isolated in one runtime file, and it is opt in twice: the `data.dart` declares
how its value is saved, and the app gives a place to save it.

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:shop/api.dart';

final dataCache = DataCache<Product>.json(
  toJson: (p) => p.toJson(),
  fromJson: (j) => Product.fromJson(j! as Map<String, Object?>),
);

Future<Product> data(Ref ref, {required int id}) =>
    ref.watch(apiProvider).product(id);
```

`dataCache` is a top-level variable of exactly that name, `const` or `final`, whose initializer is
`DataCache(...)`, `DataCache<T>(...)`, `DataCache.json(...)` or `DataCache<T>.json(...)`. `.json`
saves `jsonEncode(toJson(value))` and reads back `fromJson(jsonDecode(saved))`; the plain
constructor takes `encode` and `decode` between your value and a `String`. `maxAge` (default two
days) is how long a saved value may be shown at a start, and `version` is a string you change when
what `encode` writes changes shape: values saved under another version are dropped, not decoded.
Like `freshness` it applies to the function form that loads once, and a `route.dart` can't have
one (each data type has its own encode and decode).

**Where it is saved.** `dataCacheStorage` is a provider that is `null` by default, so **nothing is
saved** until the app gives one in its `ProviderScope`:

```dart
ProviderScope(
  overrides: [dataCacheStorage.overrideWithValue(MemoryDataStorage())],
  child: const ShopApp(),
)
```

- `MemoryDataStorage` keeps values while the app runs: a page that is disposed and opened again
  shows its last value at once. For the web, examples and tests; it does not survive a restart.
- A `Storage<String, String>` on disk survives one. `fespalier_storage` (since 0.9.0,
  [below](#a-cache-on-disk-fespalier_storage)) is a tested one on shared_preferences or Hive, with a size
  budget; `riverpod_sqflite`'s `JsonSqFliteStorage` plugs in as it is. To write your own, import
  `package:fespalier/persist.dart` (it re-exports `Storage`, `PersistedData`, `StorageOptions` and
  `StorageCacheTime`, so the app needn't depend on `hooks_riverpod` directly); `read` returns a
  `PersistedData<String>?`.

A storage whose `read` is synchronous gives the saved value on the first frame. A `Future<Storage>`
is fine too: there is one `loading.dart` frame, then the saved value.

**What happens.**

1. The first time a route's provider is built (and each time after it was disposed), a saved value
   that has not expired and has the same `version` is the state: `AsyncLoading(value: saved)` with
   `isFromCache == true`, and the fetch starts at the same time. `DataView` shows such a value
   whatever `keep_previous` says, because the cache is pointless otherwise. Read `isFromCache` from
   `XRoute.watch(ref)` for an "offline copy" banner.
2. The fetch succeeds: the state is the fresh `AsyncData`, and it is saved.
3. The fetch fails: the page keeps the saved value (`keepDataOnError`), **and the saved value is
   kept**. Riverpod's `persist` deletes it on any error, so an offline start would lose the cache
   for the next one; fespalier guards that. An offline cold start shows the last data, and so does
   the next one, until `maxAge`.
4. A saved value that does not decode is dropped, not reported as an error, and the load goes on.
   In debug a line says so (below). A storage that throws never becomes the route's error either.
5. A cold start always loads again, whatever the `staleTime` is. Nothing the storage answers after
   the load has finished replaces the fresh value.

In debug (`debugPrint`, nothing in a release build):

- `fespalier: dataCache of <name> could not read a saved value, dropped it: <error>`
- `fespalier: dataCache of <name> could not save: <error>`

The key a value is saved under is `fespalier:<folder>` plus the route's keys in path order as JSON,
e.g. `fespalier:products/$id[42]`. The folder is the `data.dart`'s folder relative to the app folder,
so it is stable across `fsp gen`. An enum key is saved by its `name`, a `DateTime` as ISO 8601, a list
as a list, and anything else by its `toString()`, which is how a custom segment type is spelled in
a URL: keep that stable (a web release build that minifies class names would change it).

Don't write an optimistic value with `state =` on this provider's notifier: Riverpod saves every
`AsyncData` it sets, so the guess would be saved. Keep optimistic values in a layer above the data
provider.

**Testing.** With no `dataCacheStorage` override, nothing is saved. To test the cache, share a
`MemoryDataStorage` between two `pumpRouter` calls, which stands in for a restart:

```dart
final storage = MemoryDataStorage();
await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/1'),
    overrides: [dataCacheStorage.overrideWithValue(storage)]);
await tester.pumpWidget(const SizedBox());
await pumpRouter(tester, AppRoutes.router(initialLocation: '/products/1'),
    overrides: [dataCacheStorage.overrideWithValue(storage), apiProvider.overrideWithValue(OfflineApi())]);
expect(find.text('Coffee beans, 500 g'), findsOneWidget); // the saved product, not error.dart
```

`MemoryDataStorage` is synchronous, so a test leaves no pending future, and
`await tester.pump(const Duration(days: 3))` expires a value under the fake clock. `examples/shop`
has the two tests (`test/freshness_test.dart`).

#### A cache on disk: fespalier_storage

Since 0.9.0. `package:fespalier_storage` is a tested `Storage<String, String>` for the [`dataCache`](#a-cache-that-survives-a-restart-datacache)
above, on **shared_preferences** (`PrefsDataStorage`) or **Hive** (`HiveDataStorage`), with a size budget. A route's
value is saved when it loads, and at the next start it is **on the first frame** while the fresh one loads. fespalier's
core depends on neither plugin, the generated code is the same bytes, and an app that does not depend on this package
pays nothing for it.

Add it next to fespalier, with the same `url` and the same `ref` (pub resolves the two to one package only if they are
the same repository dependency, as for [`fespalier_flags`](#feature-flags-fespalier_flags)):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_storage:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_storage
      ref: v0.8.1
```

<!-- x-release-please-end -->

It needs Dart 3.8 and Flutter 3.32 or newer. Open a storage in `startup()` and give it to `dataCacheStorage`:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
];
```

`open()` is awaited there, so the first frame is the app: `startup()` costs one frame behind `splash.dart` (or the native
splash), and no more. `read()` is then a synchronous map lookup and a header parse, so Riverpod's `persist` gives the saved
value to the first `build`. A `startup()` that prefers no extra frame can pass the `Future` itself
(`dataCacheStorage.overrideWithValue(PrefsDataStorage.open())`): one `loading.dart` frame, then the saved value. `open()`
returns `null` (and prints a debug line) when the store cannot open, and `dataCacheStorage` takes `null` as "save
nothing": a cache never stops an app from starting.

| What                 | `PrefsDataStorage`                                                                      | `HiveDataStorage`                                                                     |
| -------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Backend              | `SharedPreferencesWithCache`; localStorage on the web                                   | a `hive_ce` `Box<String>`; IndexedDB on the web                                       |
| Reads                | synchronous                                                                             | synchronous once the box is open                                                      |
| Default budget       | 1,000,000 characters, 200 entries                                                       | 4,000,000 characters, 1,000 entries                                                   |
| Plugins              | `shared_preferences` (most apps have it)                                                | none: `hive_ce` is pure Dart; `path_provider` for the cache directory                 |
| Where on disk        | the platform's preferences, beside the app's own keys                                   | `getApplicationCacheDirectory()` (OS-purgeable, not backed up), none on the web       |
| Pick it when         | a few small values; on the web localStorage is about 5 MB per origin, shared            | more or larger values; opening reads the whole box, so `maxSize` also bounds startup  |

**The budget.** `maxSize` is in `String.length` units (UTF-16 code units, what browsers count localStorage in), keys and
headers included, and `maxEntries` is a count. Over either, the entries **written longest ago** go first, ties by key
(deterministic: a function of the store and `clock.now()`, with no timer and no background sweep). A route's value is
written each time it is fetched fresh, so what is read is rewritten; reads never write. A value too large for `maxSize`
is not saved: it fails with `DataEntryTooLarge`, which fespalier prints after `could not save`, and the route works.
Expired and unreadable entries are deleted once, when the storage is made. A web `localStorage` that is full is a
`QuotaExceededError` on the write: the entry is dropped and fespalier prints "could not save"; keep `maxSize` well below,
or use Hive.

**Versioning, corrupt entries, sign-out.**

- `DataCache(version: '2')` is Riverpod's `destroyKey`: stored in the entry's header and compared on read, so another
  version is deleted, not decoded. The format of the storage itself is versioned by the entry's first line, `fsc1`; a
  later format is read as unreadable, which for a cache means "dropped and loaded again". To drop everything on an app
  update, call `clear()` (the app knows its build number); there is no storage-wide version key.
- **An unreadable entry** (not written by this storage, a truncated one, a value of another type under its key) is dropped
  at start and counted, and at a read it is a `FormatException` that fespalier prints (`dropped it`) and deletes. Hive
  also truncates a corrupt frame when it opens a box.
- **`clear()` is what a sign-out does**: the next start shows nothing from the previous user. It deletes every entry
  this storage saved, indexed or not, and nothing else. Values in memory are the app's to invalidate (watch
  [`authUserId`](#the-session) in a `data.dart` that belongs to the user).
- **One writer per store.** A background isolate that writes the same store makes the in-memory index stale until the
  next start; the index is never saved, so it cannot disagree with the store across a crash.

In debug (`debugPrint`, nothing in a release build), next to fespalier's two lines above:

- `fespalier_storage: dropped <n> saved entries that could not be read`, at start
- `fespalier_storage: could not open shared preferences, so nothing is saved: <error>` and
  `fespalier_storage: could not open the Hive box <name>, so nothing is saved: <error>`, when `open()` returns `null`
- a value over the budget, after fespalier's `could not save:`:
  `fespalier_storage: the value saved under <key> is <size> characters, more than maxSize (<maxSize>), so it was not saved`

A budget of 0 or less throws an `ArgumentError` (`Invalid argument (maxSize): must be more than 0: 0`), and so does a
`SharedPreferencesWithCache` with an allowList given to `PrefsDataStorage(prefs)`: the keys of a `dataCache` are not known
in advance, so use `PrefsDataStorage.open()`. The messages are in the
[troubleshooting skill](skills/fespalier-troubleshooting/references/diagnostics-flags-storage-network.md).

**Testing.** `package:fespalier_storage/testing.dart` has `fakePrefsStore([values])`, which makes shared_preferences an
in-memory store for the test, and `memoryBox()`, a Hive box in memory (no file, no plugin) for
`HiveDataStorage(await memoryBox())`. Two `open()`s in one test share the store: that is a restart.

```dart
setUp(fakePrefsStore); // also before a test that boots AppMain.run() or AppMain.root(): startup() opens a storage

testWidgets('the saved team is on the first frame of the next start', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/teams/acme/members'),
    overrides: [dataCacheStorage.overrideWithValue(await PrefsDataStorage.open())],
  );
  await tester.pumpWidget(const SizedBox()); // the restart
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/teams/acme/members'),
    overrides: [dataCacheStorage.overrideWithValue(await PrefsDataStorage.open())],
    settle: false, // one frame, no more
  );
  expect(find.text('Team ACME'), findsOneWidget); // the saved team, not loading.dart
});
```

Without `fakePrefsStore()`, `open()` finds no platform and returns `null` (a debug line says
`Bad state: The SharedPreferencesAsyncPlatform instance must be set.`): the cache is silently off. `examples/features`
carries it: `teams/$teamId/data.dart` has a `dataCache`, `startup.dart` opens a `PrefsDataStorage`, and
`test/offline_test.dart` is this test.

**Not built.** A storage-wide version key; a byte-exact size (units are `String.length`); multi-isolate safety;
encryption (open your own Hive box with a cipher and pass it to `HiveDataStorage(box)`). `riverpod_sqflite` still plugs in as
it is.

### Typed helpers on the route

A route with a `data.dart` has three more helpers next to `.data` and `.refresh` (and every
route below a [section](#section-data) with data has `preload`, below):

```dart
final product = ProductRoute.watch(ref, id: 42);   // AsyncValue<Product>, for build()
final p = await ProductRoute.read(ref, id: 42);    // Future<Product>, for callbacks
final warm = ProductRoute(id: 42).prefetch(ref);   // a PrefetchHandle, before navigating
final all = ProductRoute(id: 42).preload(ref);     // the same, for everything the page reads
```

`watch` includes the patches of an [`optimistic()`](#optimistic-updates-optimistic) when the data
has any (since 0.8.1).

`watch` and `read` are _static_, and take the keys the provider uses as named arguments
(`ItemRoute.watch(ref, shop: 'a', id: 1)`, `SearchRoute.watch(ref, q: 'ap', page: 2)`;
none for a route without keys). They can't be instance methods: `ProductRoute(id: 42).watch(ref)`
would have to write `AsyncValue<Product>` into the generated file, and the generator never
copies your imports. A static function value takes its type from the provider by
inference, so `Product` flows through and is never `dynamic`. (More in
[Design notes](#design-notes).)

`read` keeps the provider alive until it completes, which a plain `ref.read(p.future)`
doesn't for an `autoDispose` provider. Don't call it from `build`. On a route with a
[`freshness`](#freshness-staletime-resume-and-reconnect) (since 0.8.1) `read` returns the value in
memory even if it is stale, and starts the reload; `refresh` waits for the network.

`prefetch(ref)` starts the load and returns a `PrefetchHandle` that **keeps the provider alive
until you call `close()`** on it, so the page you navigate to next shows the value at once. The
generated providers are `autoDispose`, so a prefetch nobody watches would be dropped in the same
frame; the handle is what holds it, and how long is yours to decide: an app's prefetch queue
holds one per lease and closes it when the lease ends. `keepFor:` is an optional auto-close
(`prefetch(ref, keepFor: Duration(seconds: 30))` closes the handle after that long). A failed
load isn't kept (the handle closes itself): the page starts a fresh one instead. Call it before
`go`, e.g. on hover:

```dart
MouseRegion(
  onEnter: (_) => _warm = ProductRoute(id: p.id).prefetch(ref),
  onExit: (_) => _warm?.close(),
  child: ListTile(onTap: () => ProductRoute(id: p.id).go(context), …),
)
```

A few things to know: closing twice is fine, and `handle.isClosed` tells; the subscription
also ends when the widget whose `ref` you pass is disposed, and since 0.5.0 that closes the
handle and cancels its `keepFor` timer with it, so no timer outlives the widget; while the
widget is alive `keepFor` holds a timer, so a widget test that uses it should `pump` past it (or
pass `Duration.zero`, which starts the load and keeps nothing); and _the default changed_: a prefetch used to lapse after 30 seconds without a
`keepFor`, and now lasts until closed (a `prefetch(ref)` whose handle is dropped lasts as
long as the widget behind `ref`). `prefetchKeepAlive` is gone.
`prefetch` warms the route's _own_ `data.dart`. `preload(ref)` (since 0.5.0) warms _everything the
page reads_: the data of each [section](#section-data) above it, then its own, the list
`AppRoutes.dataAt` gives for its location, behind one handle that closes them all
(see [Links](#links-routelink)). A route with no data at all returns a closed handle; one whose page is
[deferred](#deferred-routes-a-pages-code-on-demand) (since 0.7.0) also starts loading its code.
Because these are members of the route class, `watch`, `read`, `prefetch`, `preload`, `refresh`,
`ref` and `keepFor` can't be segment or query names (`preload` is reserved since 0.5.0), nor
(since 0.5.0) can `of`, `maybeOf` and `copyWith` (see
[the URL as state](#the-url-as-state-of-and-copywith)), and neither
can the helpers of an [`action.dart`](#actiondart-typed-writes) (`submit`, `useAction`, or an
action's own name).

### From a location to its data

An app's own prefetch layer often starts from a _location_ (the next page a list points at),
not from a route it built by hand. Two generated functions on `AppRoutes` answer that from the
tree, without a table of your own:

```dart
final providers = AppRoutes.dataAt(Uri.parse('/products/42'));
// [ProductRoute.data(42)]: the provider the page watches, so warming it warms the page.
final handle = ref.prefetchAll(providers ?? const []);   // one PrefetchHandle for them all
// ... later, when your queue's lease ends:
handle.close();
```

`dataAt(uri)` is a `List<ProviderListenable<AsyncValue<Object?>>>?`, **outermost first**: the
`data.dart` of each [section](#section-data) above the route, then its own. It is:

- `null` when no route fits the location, or when a segment doesn't parse (`/products/abc`
  where the id is an `int`): the rule that shows `not_found.dart`;
- empty for a route without data (a page, or a catch-all with nothing behind it): a match, with
  nothing to warm.

The key is built by the same parser the route uses, so `dataAt(Uri.parse('/products/42')).single
== ProductRoute.data(42)`, and for a `data.dart` that [selects a provider](#datadart-a-function-a-selector-or-a-provider)
it is the selected provider itself (your own `productProvider('42')`). Query-keyed data is keyed by
the query of the location (`/search?q=ap&page=2` is `SearchRoute.data((q: 'ap', page: 2, …))`,
lists as the `QueryList` the page's key uses), a [catch-all](#catch-all-segments) by its decoded
path. The mount point (`AppRoutes.mount(at: '/shop')`) is taken off first, a location outside it
is `null`, and each route matches its path by its own case setting (`case_sensitive: false`, or its folder's `route.dart`). A [typed catch-all](#catch-all-segments) (`List<int>`) parses each part like the page does, so one that fails is no match. Nothing else runs: no
`guard.dart`, no `redirect.dart`, no widget. (A guard may well send the user somewhere else
when they arrive; prefetching what they asked for is your queue's call, and never
triggers it.)

`AppRoutes.preload(ref, uri)` (since 0.5.0) is `ref.prefetchAll(dataAt(uri) ?? const [])`: one
handle for everything the page at `uri` reads, a closed one when nothing fits or there is nothing
to warm. It never navigates and runs no guard. In an app with a [deferred route](#deferred-routes-a-pages-code-on-demand)
(since 0.7.0) it is `matchUrl(uri)?.route.preload(ref)` instead, which also starts the page's code.

`AppRoutes.match(uri)` is what `dataAt` is a shortcut for (`match(uri)?.data`, over the same
matching, so it isn't written twice). It returns a `RouteMatch`, or `null` under the same rules:

```dart
final m = AppRoutes.match(Uri.parse('/shops/acme/items/7'))!;
m.info;      // the RouteInfo from the manifest: path '/shops/:shop/items/:id', folder, meta, ...
m.params;    // {'shop': 'acme', 'id': 7}: the segments and query parameters, parsed
m.route;     // ItemRoute(shop: 'acme', id: 7), typed; m.route.location is its canonical spelling
m.data;      // the providers, as dataAt returns them
m.uri;       // the location it was given
```

Routes are tried most specific first (static parts, then `:param`s, then catch-alls), the order
go_router uses. `match` lives on the manifest (`AppManifest.match`, forwarded by `AppRoutes`,
like `all`), so with [`output_manifest:`](#route-manifest-and-metadart) it is in the manifest
library; `AppRoutes.dataAt` and `AppRoutes.matchUrl` (a `UrlMatch`: the route, params and data
without the `RouteInfo`) stay in `app.g.dart`, which never imports a `meta.dart`.
`RouteMatch` is fespalier's: `package:fespalier/fespalier.dart` hides go_router's own
`RouteMatch` (an internal of its parser) to make room for it, so import
`package:go_router/go_router.dart` if you need that one.

### Section data

A folder with a `layout.dart` and no `page.dart` (a `(group)`, or a plain folder that only
holds routes) can have a `data.dart` too. It is then the data of the whole section: the
layout waits for it, and the layout and the pages below can take it.

```dart
// lib/app/teams/$teamId/data.dart
Future<Team> data(Ref ref, {required String teamId}) => …;

// lib/app/teams/$teamId/layout.dart: by type (or a parameter named `data`)
class TeamLayout extends StatelessWidget {
  const TeamLayout({super.key, required this.team, required this.child});
  final Team team;
  final Widget child;
  …
}

// lib/app/teams/$teamId/members/page.dart: the page takes it by type as well
class MembersPage extends StatelessWidget {
  const MembersPage(this.team, {super.key});
  final Team team;
  …
}
```

- **Loading and errors.** While the section loads, the nearest `loading.dart` (inherited as
  usual) replaces the layout _and_ the pages inside it, and a failure shows the nearest
  `error.dart` with its `retry`. Nothing below is built until the data is there.
- **Sharing.** The layout watches the provider and the pages below read the same one, so
  `data()` runs once however many of them take it, and moving between the section's pages
  doesn't load it again. When the data reloads (`retry`, an invalidation), the section keeps
  showing what it has (`keep_previous`; with `keep_previous: false` it shows loading again).
- **Which one.** A parameter called `data` gets the nearest data: the route's own
  `data.dart`, then the section's, then the next section up. By type, a parameter gets the
  data.dart that yields that type, and it is an error if two do (a page's own and a
  section's, or two sections'): name the parameter `data` for the nearest, or give one of
  them another type. A page can have its own `data.dart` and take a section's by type.
- **Keys.** A section's `data()` takes segments (at or above its folder) and, like a page's,
  query parameters: `Future<Report> data(Ref ref, {String? period})` keys the section by
  `?period=` of the location. The layout reads it from the URL like any layout query parameter.
  Every route below the section is then keyed by it too: `period` becomes a query parameter of
  each of their typed routes (`MonthlyReportRoute(period: '2026-01')` writes
  `/reports/monthly?period=2026-01`), so the pages below read the same provider the layout
  loaded. A page that declares the same name with another type is an error, as anywhere.
- **Typed handle.** A section has no route of its own, so it gets a class named after its
  folder, with `Section` on the end (`teams/$teamId` is `TeamsTeamIdSection`, `(shop)` is
  `ShopSection`, the app folder `RootSection`; two folders that name the same class are an
  error). Its members are static and take the section's keys as named arguments, like a route's:

  ```dart
  TeamsTeamIdSection.data('acme');                         // the provider
  TeamsTeamIdSection.watch(ref, teamId: 'acme');           // AsyncValue<Team>
  await TeamsTeamIdSection.read(ref, teamId: 'acme');      // Future<Team>
  final h = TeamsTeamIdSection.prefetch(ref, teamId: 'acme');   // PrefetchHandle
  await TeamsTeamIdSection.refresh(ref, teamId: 'acme');
  ```

  A key can't be called `ref`, `keepFor` or another of the handle's members.

- **Where it applies.** A layout of any kind can be a section's, tab layouts included. A
  `data.dart` beside a `page.dart` keeps feeding that page, so the folder that holds the
  section's layout mustn't have a page.

### `action.dart`: typed writes

`data.dart` is the read side of a route. `action.dart` is the write side: a submit, a save, a
delete, a "mark as paid". It sits beside a `page.dart`, and it takes the same segments and query
parameters, plus the value being written, `input`:

```dart
// lib/app/orders/$id/refund/action.dart
Future<Refund> action(Ref ref, {required int id, required RefundInput input}) =>
    ref.read(apiProvider).refund(id, input);
```

fespalier turns it into a provider with pending and error state, and into helpers on the typed
route. After a success it invalidates the data the write made stale, so the page shows what the
server says now: no `isSubmitting` field, no `try`/`catch`, and no `ref.invalidate` to forget.

```dart
// in a HookConsumerWidget (or any ConsumerWidget): the state of the write, and a way to run it
final refund = RefundRoute.useAction(ref, id: id);
FilledButton(
  onPressed: refund.isPending ? null : () => refund.call(RefundInput(amount: 10)),
  child: Text(refund.isPending ? 'Refunding...' : 'Refund'),
),
if (refund.hasError) Text('${refund.state.error}'),            // the page stays; error.dart is not used
if (refund.state.value case final done?) Text('Refunded ${done.amount}'),

// in a callback or a test: run it once, get the result, or the exception it threw
final Refund done = await RefundRoute.submit(ref, id: 1, input: input);
```

- **Parameters.** Segments and query parameters bind exactly as in
  [`data.dart`](#datadart-a-function-a-selector-or-a-provider): the same names, the same types
  and the same errors. The one other parameter is `input`: **named, `required`**, of any type
  (`RefundInput`, `String`, a record, a `List`, `Object?`). Its type is read from the source like
  a typed [`extra`](#typed-extra)'s, imports and a type declared in the file included, so the
  generated `submit` is typed. A `Ref ref` comes first, positional.
- **Return type.** `Future<T>`, `FutureOr<T>` or a plain `T` (`Future<void>` is fine). It is
  spelled out. **The helpers keep what the function is**: a sync action's `submit` returns its
  value at once, with no `Future` and no extra frame, a `FutureOr<T>` one's returns what the
  function returned, and a `Future<T>` one's returns a `Future<T>`. A `Stream` is an error: a
  write has one result.
- **Several actions per file.** Every public top-level function that takes a `Ref` first is an
  action, and its name is the name of its helpers. A function called `action` gets the plain ones:

  | Function  | Provider (`XRoute.…`) | Runs it once                  | Hook for `build`         |
  | --------- | --------------------- | ----------------------------- | ------------------------ |
  | `action`  | `action(keys)`        | `submit(ref, keys…, input:)`  | `useAction(ref, keys…)`  |
  | `approve` | `approveAction(keys)` | `approve(ref, keys…, input:)` | `useApprove(ref, keys…)` |

  A helper can't be named like a member of the route (`go`, `refresh`, `watch`, `data`, …), a
  segment or query parameter of it, or another action's helper (a function called `submit` next to
  `action`): the generator says which.
- **The provider** is a generated `Notifier` family, `XRoute.action(id)` (`XRoute.action` when
  there are no keys), whose state is `AsyncValue<T?>`: `AsyncData(null)` while idle, then
  `AsyncLoading`, then `AsyncError` or `AsyncData` of the result. It works without a widget:
  `container.read(RefundRoute.action(1).notifier).call(input)`, which is what a test can do. Each
  key has a state of its own, and an `autoDispose` provider is dropped when nothing watches it,
  except while a write is in flight.
- **`useAction`** takes the keys and returns a handle: `state` (the same `AsyncValue<T?>`),
  `isPending`, `hasError`, `fieldErrors` (the [`FieldErrors`](#forms-form-and-validate) the last
  run failed with, since 0.8.1, or null), `reset()`, and `call(input)`. `call` runs the action and completes with
  the result, or with `null` when it failed, because the error is in `state`: an `onPressed:
  () => refund.call(input)` can't leave an unhandled error behind. `submit` is the other way: it
  throws what the action threw, for code that wants to handle it (and the error is in `state` too).
  Neither navigates, and neither is for `build`'s own body: call them from an event handler.
  (`useAction` is a hook by name only: it needs a `WidgetRef`, not hooks, and works in any
  `ConsumerWidget`.)
- **`submit`, `useAction` and the provider are static**, like [`watch` and `read`](#typed-helpers-on-the-route):
  `RefundRoute(id: 1).submit(...)` would have to name `Refund`, which the generated file can't (see
  [Design notes](#design-notes)). The types are inferred from the provider, never `dynamic`. The
  input is the one type that is spelled out, and it is read from your file.

**After a success.** The data the write made stale is invalidated, and loads again (with
[`keep_previous`](#retries-and-reloads), what the page shows stays until the new value is there):

- by default the route's own `data.dart` and the [section data](#section-data) above it: the set
  [`AppRoutes.dataAt`](#from-a-location-to-its-data) lists for the route, for the keys the action
  was called with;
- or what `const invalidates = [...]` lists, which **replaces** that set. Name typed routes and
  section handles (`RefundRoute`, `OrderRoute`, `TeamsTeamIdSection`): providers aren't `const`,
  and the generator knows which provider each one is. `const invalidates = <Object>[];`
  invalidates nothing. Anything else the write touches, a provider of your own, can be
  invalidated by the action itself, which has a `ref`.

```dart
// lib/app/orders/$id/refund/action.dart
import 'package:my_app/app.g.dart';

/// The quote on this page, and the order page above it, are stale after a refund.
const invalidates = [RefundRoute, OrderRoute];

Future<Refund> action(Ref ref, {required int id, required RefundInput input}) => …;
```

A listed route's `data.dart` is keyed by something, and the action has to take it, with that type,
to say which one to invalidate (`OrderRoute`'s `data.dart` takes `int id`, so the action takes
`id`; a `String? q` of a search page's data is one the action takes too). When it can't tell,
that's an error that says so.

**Errors.** A failed write is `AsyncError` in the state, and it is **not** the page's: the nearest
[`error.dart`](#datadart-a-function-a-selector-or-a-provider) is not used, because a failed refund
shouldn't replace the form that started it. **A write is never retried**: the generated provider
doesn't use Riverpod's [retry](#retries-and-reloads), whatever `ProviderScope(retry:)` says, and
nothing else runs it again. A failed write invalidates nothing. Trying again is the user's call:
the next `call` or `submit` replaces the error, and `reset()` clears it.

**Concurrent runs, and a page that goes away.** Nothing stops a second `call` while one is pending:
both run, each invalidates after its own success, and the state follows the last one started (a
late result of the first doesn't replace it). Disable the button while `isPending` when a double
write is wrong. The provider is kept alive until the write completes, even if its page is popped
meanwhile, so the write still finishes and still refreshes the data; the state is only written
while the provider is alive, so a submission that finishes after the page, or the whole container,
is gone doesn't throw. After an `await` in a callback, check `context.mounted` before navigating.

**Navigation is the caller's.** An action returns what it wrote, and doesn't navigate:

```dart
final done = await RefundRoute.submit(ref, id: id, input: input);
if (context.mounted) ReceiptRoute(id: id).go(context);
```

**In a section's folder.** An `action.dart` in a folder with a `layout.dart` and no `page.dart`
writes to the section. Its helpers are on the section's handle (`TeamsTeamIdSection.addMember(ref,
teamId: 'acme', input: 'carol')`), and what it invalidates by default is the section's own data and
the sections above it. A section with no `data.dart` gets a handle for its actions alone
(`ShopSection`), named like [any section's](#section-data).

Since 0.5.0. Forms and optimistic updates (since 0.8.1) are in the two subsections after the list
below; without them, `state` plus `invalidates` cover most pages.

`fsp new 'orders/[id]/refund' --action` scaffolds one, with the path's segments and an `Object?`
input to replace with your own type. `fsp routes` tags the route `action` (also in the `tags` of
`--json`, which only gains the value). The generator reports, with a code frame:

- an `action.dart` with no `page.dart`, and no `layout.dart` of a page-less folder, beside it, or
  with no function in it that takes a `Ref` first;
- a missing `input`, or one that is positional, not `required` or untyped;
- a parameter that is neither a segment, a query parameter nor `input`, a missing return type, a
  `Stream`, a `Future` with no type argument;
- an `invalidates` that is not a `const` list literal of names, a name that is neither a typed
  route nor a section handle or has no `data.dart`, and a key of the data it invalidates that the
  action doesn't take;
- helper names that collide;
- since 0.8.1, a `form()`, `validate()` or `optimistic()` that doesn't fit its action (see below).

#### Forms: `form()` and `validate()`

Since 0.8.1. A form is the UI of one write, so it is not a file kind: `form()`, `validate()` and
`optimistic()` are _companion functions_ in the `action.dart` of the action they belong to, found
by name. For the action called `action` the companion is the role itself; for any other action,
say `approve`, it is `approveForm`, `approveValidate` and `approveOptimistic`. A companion is never
read as an action, even when it takes a `Ref` (that is an error). An app that writes none of them
generates exactly what 0.7.0 did.

```dart
// lib/app/(account)/nickname/action.dart
/// The input of the action, and so the fields of its form: a record with named fields.
typedef NicknameFields = ({String nickname, int? age, bool newsletter});

/// The form starts from the data the page passes (the profile it shows).
NicknameFields form(Profile profile) =>
    (nickname: profile.nickname, age: profile.age, newsletter: profile.newsletter);

/// Checked on the device before the action runs, and live in the form after a first submit.
FieldErrors? validate(NicknameFields input) => FieldErrors({
  if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname',
  if (input.age case final age? when age < 13) 'age': 'You must be 13 or older',
});

/// The server has the last word: it can throw `FieldErrors({'nickname': 'That nickname is taken'})`.
Future<Profile> action(Ref ref, {required NicknameFields input}) => …;
```

```dart
// the page: a HookConsumerWidget, because useForm is a real hook
final form = NicknameRoute.useForm(ref, data: profile);
final f = form.fields;                         // a record of typed fields
TextField(
  controller: f.nickname.controller,
  decoration: InputDecoration(errorText: f.nickname.error),
),
CheckboxListTile(value: f.newsletter.value, onChanged: f.newsletter.didChange, …),
if (form.error case final e?) Text('$e'),      // what is not one field's
FilledButton(onPressed: form.onSubmit, child: …),  // null while the action runs: disabled
TextButton(onPressed: form.isDirty ? form.reset : null, child: …),
```

- **The input is a record with named fields**, written inline (`required ({int amount, String
  note}) input`) or as a `typedef` declared in the same `action.dart`; the generator reads the
  field names and types from there and from nothing else. `form()` returns exactly the input's
  type (as written) and takes no `Ref`: it takes the data the form starts from, or nothing.
- **`useForm`** is the generated member (`useApproveForm` for `approve`). It takes the action's
  keys, `data:` (only when `form()` takes a parameter, then required and of that type), and
  `validation:`, `resetOnSuccess:` and `messages:`. It returns an `ActionForm` with `fields`,
  `state`, `isPending`, `isDirty`, `isValid`, `error`, `onSubmit`, `submit()` and `reset()`.
  **It is a real hook**: call it from a `HookConsumerWidget`'s `build`. (`useAction` is not.) A
  key of the action can't be called `data`, `validation`, `resetOnSuccess` or `messages`.
- **Fields** are typed by the record's field types. `String`, `int`, `double`, `num` and their
  nullable forms are text fields with a `controller` that the form owns and disposes; an empty
  nullable one is `null`, an empty non-nullable number is `Required`, a bad number is `Enter a
  whole number` or `Enter a number` (pass `messages: ActionFormMessages(...)` to translate them).
  Any other type (`bool`, an enum, a `DateTime`, a list) is a value field: bind it with `value` and
  `didChange(v)`, which ignores `null` for a non-nullable type so it fits `Checkbox.onChanged`.
- **Submit.** `onSubmit` (or `submit()`) first reads the text fields, then asks `validate()`; if
  anything is wrong it stops there and **the action is not called**. Otherwise it runs the action
  with the record the fields make. A sync action stays sync: `submit()` returns its value at once.
  `onSubmit` is `null` while the action runs, so `FilledButton(onPressed: form.onSubmit)`
  disables itself.
- **Errors per field.** A field shows, in this order, its own parse error, the `FieldErrors` the
  action threw for its name (until that field is edited), and what `validate()` says of it.
  `validation: ActionFormValidation.afterSubmit` (the default) shows nothing before the first
  submit and every field as it changes after; `onChange` shows a field once the user has changed
  it. `form.error` is what is not one field's: `FieldErrors.message`, the messages of keys that are
  no field, or the error of an action that failed otherwise.
- **`validate()`** is `FieldErrors? validate(Input input)`: it takes no `Ref`, so it is a check
  the device can make. It does not need a record input. It also runs **inside the action's
  provider, before the action**, so `submit`, `useAction`'s `call` and a test through the provider
  are refused the same way: the write never starts, there is no loading state, and the error
  (`FieldErrors`) is in `state` and `fieldErrors`. A check that needs the server belongs in the
  action, which throws `FieldErrors({'nickname': 'That nickname is taken'})`.
- **Initial values and new data.** The form starts from `form(data)`. When the page gets another
  data object (the action invalidated the data, or it was refreshed), the fields the user has not
  changed follow it and the changed ones keep what was typed. While the form's own action is
  running the data is not read again: during an optimistic write the page gets the patched value,
  and a rollback would otherwise wipe what was typed. `reset()` goes back to the data the form was
  last given and clears the errors and the action's state. After a success the fields become the
  new baseline (`isDirty` is false); `resetOnSuccess: true` restarts them from `form(data)`
  instead.

#### Optimistic updates: `optimistic()`

Since 0.8.1. `T optimistic(T current, Input input)` is what the page shows of one `data.dart` from
the moment a write starts, until the server's answer is in:

```dart
// lib/app/teams/$teamId/action.dart
Team addMemberOptimistic(Team team, String input) =>
    Team(team.name, [...team.members, input]);

Future<void> addMember(Ref ref, {required String teamId, required String input}) async => …;
```

- **The target** is the `data.dart` the action invalidates whose type is `T`. When several match,
  the folder's own data comes first, then the sections above it (innermost first), then the rest
  of `invalidates` in the order listed. The action has to invalidate it (the default set does; an
  explicit `invalidates` must list it). If it doesn't, that is an error: a patch over data that
  never loads again would have no end. Only the target is patched; other invalidated data just
  reloads.
- **The sequence.** The patch is shown from the start of the write. On a failure it is removed
  (the rollback). On a success it **stays over the old value until the invalidated data has loaded
  again**, then the server's value replaces it: no frame shows the old value in between. This
  holds with `keep_previous: false` too: while a write that patched the data settles, `DataView`
  does not show `loading.dart`, because the page has already shown the result. A reload that is not
  settling a write still shows it as configured.
- **Concurrent writes** apply oldest first; a failure removes only its own patch.
- **Which reads are patched.** `DataView`, `SectionView` (the layout and every page that takes the
  section's data by type) and the typed `XRoute.watch` / `XSection.watch` show the patched value.
  `XRoute.data` (the provider), `read`, `refresh`, `prefetch`, `preload` and `AppRoutes.dataAt`
  are the server's value. A dependency-triggered reload (`AsyncLoading` with a value) is returned
  unpatched by `watch`, and still patched in `DataView`.
- **The patch holds until the data loads again, even to an equal value**, because it is the
  reload that ends it, not a comparison. A patch that throws is reported through
  `FlutterError.reportError` (context `while applying an optimistic() patch`) and skipped; it
  never turns into `error.dart`.
- If the page leaves in the middle of a write, the write still finishes and still invalidates.

### Links: `RouteLink`

`RouteLink` (since 0.5.0) is a link to a route: a real `<a href>` on the web, a plain widget
everywhere else, and a click that goes through go_router either way.

```dart
RouteLink(
  to: ProductRoute(id: p.id),     // any typed route; or `uri: Uri.parse('/products/2')`
  preload: Preload.intent,        // none (default) | intent | visible
  method: LinkMethod.go,          // go (default) | push | replace
  builder: (context, follow) => ListTile(title: Text(p.name), onTap: follow),
)
```

`builder` gets `follow`, which navigates; give it to the child's `onTap` or `onPressed`. The child
is exposed to accessibility services as a link with its URL, and `const RouteLink(...)` works when
the route and the builder are constant.

- **On the web** it is built on `url_launcher`'s `Link`, which lays an invisible anchor over the
  child. The browser shows the URL in its status bar, the context menu offers "open in a new
  tab", and a middle click, or a click with Ctrl, Cmd, Shift or Alt, opens it in a new tab or
  window. A plain click or a keyboard activation never reaches the anchor: `follow` calls
  `GoRouter.go`, `push` or `replace` (the `method`), the page doesn't reload, and the anchor's own
  navigation is cancelled. With `method: LinkMethod.push` a plain click pushes and a Ctrl-click
  opens a tab. The `href` is the route's `location`, so it carries the mount prefix
  (`AppRoutes.mount(at: '/shop')` gives `/shop/products/2`) and, with `locale: 'fr'`, the
  localized spelling `locationFor('fr')` writes. Under a hash URL strategy the browser prefixes
  it with `#`, as for any link.
- **Elsewhere** there is no anchor; `follow` navigates the same way.
- **`uri:`** is for a location you only have as a string (a notification payload, a CMS
  field). It is a path of this app with the mount prefix, not an external URL. In a debug build a
  `uri:` that no route matches throws when the link builds, saying so: it asks the router above
  it (`GoRouter.configuration.findMatch`), or `RouteLinkScope.match` below. It can't see a segment
  that doesn't parse (`/products/abc`), which only the generated matcher does. `fsp` also warns
  about a `Uri.parse` literal that matches no route when it builds (since 0.7.0, see
  [Checking string paths](#checking-string-paths)).
- **No `extra`.** An `extra` is not part of the URL, so a link has none. For a route that takes
  one, call `route.go(context, extra: ...)` from the child's own `onTap`.

`RouteLinkScope` sets the defaults for every link below it, once, and needs no generated code:

```dart
MaterialApp.router(
  routerConfig: router,
  builder: (context, child) => RouteLinkScope(
    preload: Preload.intent,       // for links that don't say
    match: AppRoutes.matchUrl,     // lets a `uri:` link preload, and checks it exactly
    child: child!,
  ),
)
```

#### Preloading the data behind a link

A link's `preload` starts the data of the page it points at before it is followed, so the page
shows at once instead of `loading.dart`. It starts **every** provider the page reads, the
data of each [section](#section-data) above it and its own, through `route.preload(ref)` (or
`AppRoutes.preload(ref, uri)` for a `uri:` link, given the scope's `match`), and the link owns the
`PrefetchHandle` it gets back.

- `Preload.none` (the default): nothing; the page loads when it is reached.
- `Preload.intent`: when the pointer enters the link, the link or something inside it takes
  focus, or a pointer goes down on it (a touch, before the finger lifts). Held until the link is
  disposed, so coming back to the list is still warm.
- `Preload.visible`: when the link is on screen: inside the view and the viewport of every
  scrollable around it, on a route or tab that is showing. Released when it scrolls out or a page
  covers it, started again when it comes back, and closed when the link is disposed. It is
  checked after a frame in which the link was built, its scrollable moved or its route went
  under another, so a long list costs one comparison per scroll frame for the links it has
  built, and no timer.

What it never does: navigate, run `guard.dart` or `redirect.dart` (a guard runs when the link
is followed; preloading is only the load), keep a failure (a provider that throws closes the
handle, and no page is left with an error nobody asked for), or load twice for repeated
hovering (a link holds one handle, and a provider that several links start is loaded once). A link
that failed to preload tries again on its next intent, but not on every scroll tick of a visible
one. Changing the link's route or `preload` releases what it held.

A link to a [deferred route](#deferred-routes-a-pages-code-on-demand) (since 0.7.0) starts the page's _code_ too, in the same
moment, through the same `route.preload(ref)`; the code, once loaded, stays loaded, so a link
releasing its handle drops the data only.

The same call is there without a widget, for your own queue: `ProductRoute(id: 2).preload(ref)`
and `AppRoutes.preload(ref, uri)` return one `PrefetchHandle`; close it when the lease ends.

`RouteLink` needs the app's `ProviderScope` above it, like every fespalier page, even when it
preloads nothing. It depends on `package:url_launcher` (only its `Link`; nothing is launched,
though pub resolves url_launcher's platform packages).

### Deferred routes: a page's code on demand

_Since 0.7.0._ A Flutter web app is one JavaScript bundle: every page's code is downloaded before the
first frame, however few the visitor opens. Dart can split it: a library imported `deferred as` is
compiled to a file of its own that the browser fetches when `loadLibrary()` is called. fespalier
does that for a route's `page.dart`, and loads the code the way it loads data: when the page is
built, or ahead of time (see [Preloading](#preloading-the-data-behind-a-link)).

**Turn it on.** It is off by default, and a route that isn't deferred generates exactly the code it did
before 0.7.0. For a folder, in its `route.dart`, which covers that folder and everything below it,
the nearest one winning over the parent's and over the pubspec, like
[`remount`](#remounting-a-page-remount):

```dart
// lib/app/checkout/route.dart
const deferred = true;
```

For the whole app, in the pubspec's `fespalier:` section (a `route.dart` says `const deferred = false;`
to opt a folder out, the landing page for one):

```yaml
fespalier:
  deferred: true
```

The value is read from the source when the tree is generated, never imported or run, so it must be
a `true` or `false` literal and declared once; anything else is an error with a code frame, and a
pubspec value that isn't a bool is serde's own error: ``invalid pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13``. Like
`caseSensitive` it is inherited by `(group)` folders and folders without a page, and needs no page
beside it. `fsp routes` tags such a route `deferred`, `--json` has `"deferred":true` (only there for
a deferred route), `--graph` marks it, and `AppManifest`'s `RouteInfo.deferred` says so at runtime.

**Only `page.dart` is deferred**, the page of a route (a tab layout's own page included). The rest is
needed before a page exists, and stays in the main bundle:

| Stays eager                                    | Why                                                                                                             |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `layout.dart`                                  | It wraps a `Navigator` (a `StatefulNavigationShell` for tabs): a placeholder would unmount them and their state |
| `loading.dart`, `error.dart`                   | They are what shows while the code loads, or when loading it fails                                              |
| `guard.dart`, `redirect.dart`                  | They run synchronously, before any build, and decide before a byte of code is fetched                           |
| `data.dart`, `action.dart`                     | The typed routes, `matchUrl`, `dataAt` and `preload` name their providers synchronously                         |
| `meta.dart`, `transition.dart`, `present.dart` | Used in a `const` list, or build the `Page` itself                                                              |

A `redirect.dart` route has no page, so it is never deferred.

**What shows while it loads.** Navigation completes at once, as ever. The route's `Page` is built,
its transition plays, the layout and the tab bar around it are there, and the page's place shows the
nearest [`loading.dart`](#datadart-a-function-a-selector-or-a-provider) (a centred spinner without one)
until the code arrives. If it can't be fetched (offline, a stale deploy), the nearest `error.dart` shows
with what `loadLibrary()` threw (a `DeferredLoadException` on the web), and its `retry` loads the code again. dart2js already tries a chunk
three times before it gives up. Turning `deferred` on therefore binds the nearest `loading.dart` and
`error.dart` to the route, as `data.dart` does, with the same rule: an inherited view must fit every
route it covers (an `error.dart` that asks for a segment fails the route that has none, and one that
asks for a query parameter adds it to the typed route).

**Once the code is loaded, the page is built synchronously**, with no `Future` and no extra frame:
a second visit, or a visit after a preload, costs nothing. The page's state survives the load.

**Data and code load in parallel.** A deferred page with a `data.dart` starts its code at the first
build, beside the data (`DataView(library: ...)`), and shows the page when both are there; `loading.dart`
covers both waits, `keep_previous` is unchanged, and a data error still gets the data's `retry`.

**Guards run first.** A guard that redirects means the page's code is never requested. Preloading
never runs a guard and never navigates; it may download the code of a guarded page (code, not data),
and the guard still decides when the page is reached. An unparsable segment shows `not_found.dart`,
and loads no code.

**Preloading the code.** It goes with the data:

- `XRoute(...).preload(ref)` (and so a [`RouteLink`](#links-routelink) with `preload`, and
  `AppRoutes.preload(ref, uri)`) also starts the page's code. A route that reads no data returns a
  closed handle; the code, once loaded, stays loaded, so closing a handle only drops the data.
  `AppRoutes.preload` goes through `matchUrl(uri)?.route.preload(ref)` when the app has a deferred
  route. A typed route preloads its own page's code, not the pages `go` stacks under it.
- `AppRoutes.deferred` lists the `DeferredLibrary` of each deferred route, and
  `AppRoutes.loadDeferred()` loads them all, which is the "once the app is idle" strategy: call it
  after the first frame. There is no `const preload = true;`, and no limit on how many load at once
  (each loads once, and the browser dedups).
- `RouteLink` with a `uri:` and a `RouteLinkScope.match` preloads through the matched route's `preload`
  (a hand-built `UrlMatch` whose route doesn't override `preload` no longer preloads its data).

**Platforms.** On the web each deferred page is a `main.dart.js_N.part.js`. Elsewhere the code is in the
binary already, but `loadLibrary()` still takes a turn of the event loop, so a page shows its
`loading.dart` for about a frame on its first visit unless it was preloaded. Load them before
`runApp` there: it costs no I/O, and keeps a deferred page's restorable state working on Android and iOS.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) await AppRoutes.loadDeferred();
  runApp(const ProviderScope(child: MyApp()));
}
```

Android deferred components (a Play Store feature) are not tried: `loadDeferred` would download all of
them. `--wasm` compiles, and whether it splits is not verified; correctness doesn't depend on it.
`examples/shop` defers `/checkout` and `/products/:id`, and `just web-chunks` builds it for the web,
checks that their strings are in chunks of their own, and holds the build to the budgets in its
pubspec with [`fsp size`](#web-chunk-sizes-fsp-size), which reports what each chunk costs per route.

**A type declared in a deferred `page.dart` is an error.** The generated file names the types of
segments, query parameters and `extra` outside the page, and Dart can't use a deferred library's
type there (`type_annotation_deferred_class`). An enum (`enum Sort { name, price }`) or an `extra`
class declared in the page's own file is therefore reported, at the page, with what to do:

```text
error: `Sort` is declared in this page.dart, which is deferred, and the generated code names it outside the page (as the type of a segment, a query parameter or an `extra`): Dart can't use a deferred library's types there. Move `Sort` to a file of its own and import it here, or say `const deferred = false;` in this folder's route.dart
```

Move the type to a file of its own (`lib/models/sort.dart`) and import it in the page ([enum segments](#enum-segments) can be declared in any file the page imports), or leave
that folder eager. A type
declared in a page that is _not_ deferred is fine for a deferred child.

**Testing.** A deferred library's `loadLibrary()` completes only on the real event loop, which a
widget test's `pump` never runs, so a test would show `loading.dart` for ever or end with "A Timer is
still pending". `pumpRouter` therefore loads every deferred route's code first, in `runAsync`, and a
deferred page is in the first settled frame like an eager one. A test that pumps a router of its own
does the same itself, before `pumpWidget`:

```dart
await tester.runAsync(AppRoutes.loadDeferred);
```

Forgetting it is a `FlutterError` in a debug build, not a hang: _"The code of products/$id/page.dart
is not loaded, and a widget test can't load it while it pumps."_ The loading state of a real deferred
page can't be seen in a widget test; test your own `loading.dart`, or
`DeferredLibrary(() => completer.future, 'x/page.dart', loadsInFakeAsync: true)` with a `DeferredView`
(that is how the package tests it).

**Not built:** deferring a `layout.dart`, a `const preload = true;` strategy, a cap on parallel
loads, and a `deferred: auto` mode (dart2js already makes a chunk of each deferred import, and moves
shared code into shared chunks: `deferred: true` in the pubspec and `const deferred = false;` on
the landing page is "everything split"). Don't defer the landing page: it would show `loading.dart`
before its first paint.

`packages/fespalier/lib/src/deferred.dart` has the runtime (`DeferredLibrary`, `DeferredView`);
`examples/shop/test/deferred_test.dart` and `packages/fespalier/test/deferred_test.dart` test it.

### Route manifest and `meta.dart`

The generator knows a lot about every route (its typed route, path, folder, groups and
layouts, parameters), and only a person can write the rest (a stable review code, a page title,
an analytics name). The manifest puts the first at runtime, next to the second.

```dart
final info = AppRoutes.byType[ProductRoute]!;   // or AppRoutes.byPath['/products/:id']
info.path;      // '/products/:id'
info.folder;    // r'(buyer)/products/$id'
info.groups;    // ['(buyer)']
info.meta;      // whatever lib/app/(buyer)/products/$id/meta.dart declares
AppRoutes.all;  // every route, in the order of the table at the top of app.g.dart
```

`AppRoutes.all`, `byType` (typed-route class → info) and `byPath` (path template → info) are
generated as `AppManifest`, a `const` list of `RouteInfo`s, and forwarded by `AppRoutes`.
`AppManifest.match(uri)` finds the entry for a _location_ ([From a location to its
data](#from-a-location-to-its-data)).
Each `RouteInfo<M>` has:

| Field               |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `type`              | the typed-route class: `ProductRoute`                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `path`              | the path template, without the mount point: `/products/:id`; a [catch-all](#catch-all-segments) is `/docs/*rest`, or `/files/*path?` when optional (as in `fsp routes`). Case-insensitive paths (`case_sensitive: false`) don't change it                                                                                                                                                                                                                                            |
| `paths`             | the path in each locale its folders spell it in, `{'fr': '/produits/:id'}` (a level with no spelling for a locale keeps its own); empty without [localized paths](#localized-paths). `pathFor(locale)` picks one, falling back to `path`                                                                                                                                                                                                                                             |
| `folder`            | the route's folder relative to the app folder: `(buyer)/products/$id` (empty for the app folder itself)                                                                                                                                                                                                                                                                                                                                                                              |
| `presentation`      | `RoutePresentation.page`; `.redirect` for a `redirect.dart` (`isRedirect`); `.root` for a page on the [root navigator](#the-root-navigator-navigatordart) through `navigator.dart`; `.custom` for a page a [`present.dart`](#presentdart-a-page-of-your-own) builds (it is on the root navigator too, unless a `navigator.dart` beside it says otherwise). Whether a page opens as a dialog or sheet is up to its `transition.dart` or `present.dart` at runtime, so it isn't listed |
| `sibling`           | `true` for a route declared [`nest = false`](#a-sibling-with-a-compound-path) (since 0.7.0): a sibling of the page above it, with a compound path, not its child (the `sibling` tag of `fsp routes`); `false` otherwise                                                                                                                                                                                                                                                              |
| `groups`            | the `(group)` folders above it, outermost first, parentheses included                                                                                                                                                                                                                                                                                                                                                                                                                |
| `layouts`           | the folders of the layouts that wrap it, outermost first (`''` is the app folder's own layout)                                                                                                                                                                                                                                                                                                                                                                                       |
| `segments`, `query` | `RouteParam(name, type)`: `('id', 'int')`, `('page', 'int?')`, `('tags', 'List<String>')`. A catch-all is the last segment, a `List<String>` (or the `List` type it is typed with) with `catchAll: true`                                                                                                                                                                                                                                                                             |
| `tabs`              | the tabs it sits in, outermost first: `RouteTab(layout, index, branch)`, where `branch` is the name `tabs` and `tabOptions` use (`.` for the layout's own page); empty outside tab layouts                                                                                                                                                                                                                                                                                           |
| `dataKeys`          | what its `data.dart` is keyed by; `null` without one                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `meta`              | its `meta.dart`, as declared                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

**`meta.dart`.** Put `const meta = <any const expression>;` next to a `page.dart` (or
`redirect.dart`), and the generator copies it into the manifest _by reference_
(`meta: _i7.meta`), never re-spelling it. fespalier doesn't interpret it; use any type:

```dart
// lib/app/(buyer)/products/$id/meta.dart
import 'package:my_app/page_meta.dart';

const meta = PageMeta(code: 'B04', slug: 'product-detail', title: 'Product');
```

- **It is per route, not inherited.** A route gets its own folder's `meta.dart` or none, so
  `photos/sort/` doesn't see `photos/meta.dart`. To share something (a role, say), keep it in
  the group: `info.groups` already lists it.
- **It must be `const`.** The manifest is a `const` list. A `meta` that is `final`, `var` or a
  getter is an error at its declaration, and so is a `meta.dart` that declares no `meta`.
  A `meta.dart` in a folder with no `page.dart` or `redirect.dart` is a warning: it describes no route.
- **It can be required.** With `fespalier: { meta: required }` in `pubspec.yaml`, a route without a
  `meta.dart` is an error that names its folder:
  `` `products/$id/` has no meta.dart ``. fespalier never numbers, derives or defaults
  anything in it: a review code is yours.
- **Its values can be unique.** `meta_unique: [code, slug]` in the same section makes a
  duplicate an error: it reads the _literal_ named arguments of `meta`'s constructor call
  (`const meta = PageMeta(code: 'B04', slug: 'product-detail')`, a string, number or bool) in
  every route's `meta.dart` and reports a value that two routes share, naming both files
  (`` `code: 'B04'` is also in products/meta.dart ``). An argument that is an expression, or
  that a route leaves out, is skipped (nothing is compared for it), and a listed name no
  `meta.dart` gives a literal is a warning, in case it is a typo. Anything more (a pattern for
  the code, unique across tabs only) is a few lines in a test over `AppRoutes.all` and `metaAs`.
- **Read it typed** with `info.metaAs<PageMeta>()` (null when the route has none, or it is
  another type), or check `info.meta is PageMeta`. The list holds `RouteInfo<Object?>`.

**A library of its own.** `meta.dart` files pull whatever they import into `app.g.dart`, and so into
your app. To keep review-only metadata out of production code, write the manifest to a second
file:

```yaml
fespalier:
  output_manifest: lib/app.routes.g.dart
```

`app.g.dart` then has no manifest and no `meta.dart` import, and `lib/app.routes.g.dart` (which
imports `app.g.dart` for the typed routes) holds `AppManifest` with the same `all`, `byType`
and `byPath`. Import it only where you need it (tests, a review screen), and production code
that imports `app.g.dart` alone never sees a `meta.dart`. `AppManifest` is the same name in both
modes, so code that uses it doesn't change when you move the file; `AppRoutes.byType` exists
only when the manifest is in `app.g.dart`. `fsp gen` writes both files, `fsp check` checks what
either would say, `fsp watch` regenerates both, and both are committed like `app.g.dart` is
(see `examples/tabs`).

**Web tab titles.** A layout can read the route it is showing with
`AppManifest.of(GoRouterState.of(context))` (null in a not-found view), and set the title of the
browser tab with Flutter's `Title` widget. No meta schema is baked in: whatever your type
calls it works.

```dart
// lib/app/layout.dart
class AppLayout extends StatelessWidget {
  const AppLayout({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final info = AppManifest.of(GoRouterState.of(context));
    return Title(
      title: info?.metaAs<PageMeta>()?.title ?? 'My app',
      color: Theme.of(context).colorScheme.primary,
      child: Scaffold(body: child),
    );
  }
}
```

`AppManifest.of` looks the path up in `byPath` after taking `AppRoutes.base` off, so it also
works under `AppRoutes.mount(at: '/shop')`, and for catch-all routes (go_router's `:rest(.+)` is
matched to `*rest`, and an optional catch-all's bare path to its route). See `examples/features`, which does this and tests it.
The same lookup gives analytics screen names (`info.path`, or a name in your meta) from a
`NavigatorObserver`.

**`fsp routes --json`** prints the same data, one object per route. Besides `pattern`, `route`,
`file`, `tags` and `params` it has the manifest's fields, in this order (paths in `file` and `meta`
are relative to the project root; `folder`, `layouts` and `tabs[].layout` to the app folder):

```json
{
  "pattern": "/products/:id",
  "route": "ProductRoute",
  "file": "lib/app/(buyer)/products/$id/page.dart",
  "tags": ["data"],
  "params": [
    { "name": "id", "type": "int", "in": "path" },
    { "name": "tab", "type": "String?", "in": "query" }
  ],
  "folder": "(buyer)/products/$id",
  "presentation": "page",
  "groups": ["(buyer)"],
  "layouts": ["(buyer)"],
  "tabs": [],
  "data_keys": ["id"],
  "meta": "lib/app/(buyer)/products/$id/meta.dart",
  "catch_all": null
}
```

`presentation` is `page`, `redirect`, `root` or `custom` (see the table above); `tabs` is `[{"layout":"(tabs)","index":0,"branch":"search"}]`
for a route in a tab; `data_keys` and `meta` are `null` when the route has no `data.dart` or
`meta.dart`. The meta itself is Dart, so JSON only says where it is. `catch_all` is
`{"name":"rest","optional":false}` for a route that ends in a `$$rest` (or `$$$rest`, `"optional":true`)
catch-all, else `null`; the catch-all is also in `params` as a path parameter of its `List` type. A route
with [localized paths](#localized-paths) has one more key after `catch_all`, `"paths":{"fr":"/produits/:id"}`
(the manifest's `paths`); the other routes have none. A route that [remounts](#remounting-a-page-remount)
(since 0.6.0) has `"remount":"on_segments"` or `"remount":"on_location"` before `paths`, and the other
routes have none; it is in `fsp routes --json` only, not in the manifest. A route whose page is
[deferred](#deferred-routes-a-pages-code-on-demand) (since 0.7.0) has `"deferred":true` after `remount`, and the other
routes have none; the manifest says it as `RouteInfo.deferred`. A route whose own `data.dart` has a
[`freshness`](#freshness-staletime-resume-and-reconnect) (since 0.8.1) has `"freshness":"lib/app/teams/$teamId/route.dart"`
after `deferred`: the file whose `Freshness` applies (the `data.dart` itself, or the nearest `route.dart` above it, relative to the
project root like `file`); and one whose `data.dart` has a [`dataCache`](#a-cache-that-survives-a-restart-datacache) has
`"cache":true` after it. The other routes have neither, and the manifest does not carry them.

### State restoration

Pass a scope id to the router, and give the app one too, and Flutter saves what the user was
doing when the OS kills the app, and puts it back on the next launch:

```dart
MaterialApp.router(
  restorationScopeId: 'app',
  routerConfig: AppRoutes.router(restorationScopeId: 'router'),
);
```

Without the ids nothing changes. With them, the location comes back (also for routes deep in
a stack), and so does everything below:

- **Tabs.** Each tab layout and each of its tabs gets a stable `restorationScopeId` from its
  folder (`layout:(tabs)/`, `tab:(tabs)/search`; `.` is the layout's own page), so the selected
  tab _and_ the stack of every tab you visited are restored, nested tab layouts included.
- **Layouts.** A plain layout's Navigator gets one too (`layout:(account)/`).
- **Pages.** What a page keeps in a `RestorationMixin` (a `RestorableInt` for a form field or a
  scroll offset) comes back if the page has a `restorationId`. go_router's own pages have
  one; the ones `Transitions.*` build take it from the page key; a `Page` you build in a
  `transition.dart` should pass `restorationId: key.value` too (or its state won't be restored).
  A page that [remounts](#remounting-a-page-remount) has the segments or the location in its key,
  so each URL it starts again at restores its own state.

The reason layouts need generated pages: go_router keys the page of a `ShellRoute` or
`StatefulShellRoute` by the route object's `hashCode` and uses it as the restoration id, which
changes on every launch, so nothing under it can be found again. The generated router builds
these pages with an id from the layout's folder instead: with a [`transition.dart`](#transitions)
above the layout, its `Page` under a `ValueKey` made of that id (the `Transitions.*` pages take
their restoration id from the key); otherwise `layoutPage(...)`, a Material page (a Cupertino one
inside a `CupertinoApp`) with the id, under the same `ValueKey` (since 0.5.0; it used to use
go_router's key, the route object's hash code, so a router built again by a hot reload or a test
replaced the layout and lost its state).

- **`extra`.** An object passed with `context.go(…, extra: …)` is saved with the location if the
  router has an [`extraCodec`](#restoring-extra-on-the-web) that knows its type (the same one
  the browser's history uses on the web).

Ids come from folder names, so renaming a folder drops what was saved under the old one, once.
`examples/tabs/test/restoration_test.dart` restores the selected tab, a background tab's stack,
a page's `RestorableInt` and a page's `extra` with `tester.restartAndRestore()`. Build the router in a
`State`, not a `final`, in such a test: a router remembers where it went.

### `main()`: app.dart, startup.dart and splash.dart

Since 0.8.1 the framework can own `main()`. You write what is yours, in up to three files at the
**root** of the app folder (a copy below it is ignored, with a warning), and `fsp` writes
`lib/app.main.g.dart`, whose `AppMain` runs them. `lib/main.dart` stays yours, and is one line:

```dart
// lib/main.dart
import 'package:my_app/app.main.g.dart';

Future<void> main() => AppMain.run();
```

```text
lib/app/
  app.dart       the widget around the router: MaterialApp.router, theme, title, locales
  startup.dart   what runs before the app: startup(), zone(), providerObservers, routerObservers, retry()
  splash.dart    shown while an async startup() runs, and when it fails
```

All three are optional. With none of them, `main: auto` (the default) writes nothing and your own
`main()` keeps working; any one of them makes `fsp` write `lib/app.main.g.dart`. `app.g.dart` is
the same bytes whether or not they exist.

**`app.dart`** is a view file: one public widget class (of any kind: a `ConsumerWidget` to read a
theme-mode provider is the point) or a function `Widget app({required GoRouter router})`. It
gets the router as a parameter named `router`, or the one typed `GoRouter` (`RouterConfig<Object>`
works too); every other parameter has to be optional:

```dart
// lib/app/app.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class App extends StatelessWidget {
  const App({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Shop',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    routerConfig: router,
  );
}

/// Optional: how the router is built. Called once, after startup(). Call AppRoutes.router().
GoRouter router() => AppRoutes.router(restorationScopeId: 'router');
```

Without `router()` the router is `AppRoutes.router()`, with the `routerObservers` of
startup.dart if it has any. Without an `app.dart` (with `main: generated`) the app is
`MaterialApp.router(routerConfig: router)`.

**`startup.dart`** exports, by name, any of:

| Export                                | What it is                                                                                                                                                                  |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `startup()`                           | No parameters. Returns `void`, `Future<void>` or `FutureOr<void>`; or the providers to override: `List<Override>`, `Future<List<Override>>`, `FutureOr<List<Override>>`     |
| `zone(Future<void> Function() body)`  | Wraps **all** of `main()`: the binding, `startup()` and `runApp` run inside `body`. Returns `Future<void>` or `FutureOr<void>`; call `body()` in it                         |
| `providerObservers`                   | A list (a variable or a getter) of `ProviderObserver`s for the `ProviderScope`; read after `startup()`                                                                      |
| `routerObservers`                     | A list of `NavigatorObserver`s for the router; read after `startup()`. Not with a `router()` in app.dart: pass them there                                                   |
| `retry(int retryCount, Object error)` | `Duration?`: the `ProviderScope`'s retry policy                                                                                                                             |

```dart
// lib/app/startup.dart
import 'dart:async';

import 'package:fespalier/startup.dart'; // Override, ProviderObserver, NavigatorObserver
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runs once, before the app. The providers it returns are overridden in the app's ProviderScope.
Future<List<Override>> startup() async {
  usePathUrlStrategy(); // web: before the router reads the URL, which happens after startup()
  final prefs = await SharedPreferences.getInstance();
  return [prefsProvider.overrideWithValue(prefs)];
}

/// Optional: wraps all of main().
Future<void> zone(Future<void> Function() body) async {
  await runZonedGuarded(body, (error, stack) => reportCrash(error, stack));
}

/// Optional: read after startup().
List<ProviderObserver> get providerObservers => [];
List<NavigatorObserver> get routerObservers => [];
Duration? retry(int retryCount, Object error) => null;
```

At least one of them has to be there. `startup()` runs **before the router exists**: the router is
built once, after `startup()`, and disposed with the app. That is also why `usePathUrlStrategy()`
belongs in `startup()` (checked in a release web build with a 300 ms async `startup()`: a deep link
`/items/2?qty=3` opened the item page, and tapping a link put `/about` in the address bar, with no `#`).

**`splash.dart`** is a view file too (a class or `Widget splash({...})`), built **before** the
app: there is no `Theme`, `Localizations` or `ProviderScope` above it, only a text direction
(from the platform locale), so use plain widgets. It can ask for `error`, `stackTrace` and
`retry`, by name; each is nullable, because they are null while `startup()` runs and set only after
a failure (`retry` runs `startup()` again):

```dart
// lib/app/splash.dart
import 'package:flutter/widgets.dart';

class Splash extends StatelessWidget {
  const Splash({super.key, this.error, this.retry});

  final Object? error;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => Center(
    child: error == null
        ? const Text('Starting…')
        : GestureDetector(
            onTap: retry,
            child: Text("Couldn't start: $error. Tap to try again"),
          ),
  );
}
```

**Sync stays sync.** A `startup()` that returns no `Future` (a `void`, a `List<Override>`) is done
before the first frame, and the first frame is the app. A `Future` costs a frame: with a `splash.dart`
it is shown meanwhile; without one, the first frame is deferred
(`WidgetsBinding.deferFirstFrame`), so the platform's native splash (the Android and iOS launch screen,
the web's loading page) stays until the app is ready. No timer is involved. A `startup()` that
throws is reported with `FlutterError.reportError` (so `FlutterError.onError`, and anything listening
to it, sees it) and shows the splash with `error` and `retry`, or, without a `splash.dart`, a plain
"Couldn't start the app." with the error (in debug builds) and "Try again".

**`zone()` has to work on the web.** It runs on every platform, so a zone implementation that
needs `dart:io` or an isolate (a crash reporter's `runGuarded`, say) must behave on the web as well.
The telemetry SDK `otel_zone` is one that does not yet: its `runGuarded` never runs its body in a
browser, which leaves the app blank. Until that is fixed, write
`Future<void> zone(Future<void> Function() body) => kIsWeb ? body() : observability.runGuarded(body);`
(`kIsWeb` is in `package:flutter/foundation.dart`).

**`main:` in the pubspec** (see [Config](#getting-started)) is `auto`, `generated` or `manual`.
With `manual`, `fsp` writes no `main()` and reads none of the three files (each one that is
there gets a warning saying so): use it for an app that keeps its own `main()` or its own
`GoRouter`, or when a file called `app.dart` at the root of the app folder is something else.

**What is generated.** `AppMain` has three members:

- `AppMain.run()`: what `lib/main.dart` calls. Inside `zone()` (if any): the binding, the code of the
  [deferred routes](#deferred-routes-a-pages-code-on-demand) (loaded before the first frame, off the web,
  as a hand-written `main()` did with `AppRoutes.loadDeferred()`), then `runApp(root())`.
- `AppMain.root({router})`: the widget `runApp` gets, a `StartupGate` from `package:fespalier/startup.dart`:
  `startup()`, `splash.dart`, then a `ProviderScope` with the overrides, observers and retry around
  `app.dart`. `router` builds the router (default: app.dart's `router()`, else `AppRoutes.router`).
- `AppMain.app(router)`: `app.dart`'s widget around a router, for tests (see [Testing](#testing)).

**From a 0.7 app.** Nothing changes until you opt in. To move the code of a hand-written `main()`:

| Today, in `lib/main.dart`                                                 | 0.8.1                                                                                         |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `MaterialApp.router(title:, theme:, builder:, routerConfig: _router)`     | the same widget in `lib/app/app.dart`, with `routerConfig: router`                            |
| `final _router = AppRoutes.router(restorationScopeId: …, observers: …)`   | `GoRouter router() => AppRoutes.router(…)` in app.dart, or `routerObservers` in startup.dart  |
| `await Firebase.initializeApp(…)`, `usePathUrlStrategy()` before `runApp` | `startup()`                                                                                   |
| `ProviderScope(overrides: [x.overrideWithValue(v)])`                      | `startup()` returns `[x.overrideWithValue(v)]`                                                |
| `ProviderScope(retry: …, observers: …)`                                   | `retry()` and `providerObservers` in startup.dart                                             |
| `runZonedGuarded(…)`                                                      | `zone()` in startup.dart                                                                      |
| `if (!kIsWeb) await AppRoutes.loadDeferred();`                            | generated: delete it                                                                          |
| `void main() => runApp(…)`                                                | `Future<void> main() => AppMain.run();`                                                       |

A bad root file is an error with the way out in its message: an `app.dart` without a `router`
parameter says "the app's widget gets the router: add `required this.router` (a `GoRouter`) … If this
file is not the app around the router, move it out of the app folder's root or set `main: manual`".
`examples/minimal`, `shop` and `features` use the generated `main()` (`features` has all three
files and a `zone()`), and `examples/tabs` keeps a `main()` of its own.

### Scroll restoration

Since 0.8.1. Flutter builds a page from nothing when the browser's back or forward button brings it
back, so a long list starts at the top again. `scroll_restoration: true` in the `fespalier:` section of
`pubspec.yaml` (off by default) gives each page's scroll offsets back:

```yaml
fespalier:
  scroll_restoration: true
```

```dart
// lib/app/products/page.dart
ListView.builder(
  key: const PageStorageKey<String>('products'), // without this key, nothing is restored
  itemBuilder: (context, i) => ...,
)
```

**Only a scrollable under a `PageStorageKey` is restored.** Flutter keeps an offset in the nearest
`PageStorage`, by key, and stores nothing for a scrollable that has none; fespalier does not make keys up. It
also means two scrollables on one page can't swap offsets: give each its own key (a carousel in a list,
`PageStorageKey('featured')` and `PageStorageKey('feed')`). A `PageView` and an `ExpansionTile` keep their
position in the same place, so the same key restores them.

What the generated router does with the key on is wrap the page's own view, inside its transition and under
its layouts, in `RouteScrollMemory`:

```dart
GoRoute(
  path: 'about',
  builder: (context, state) => RouteScrollMemory(
    state: state,
    child: _i4.page(),
  ),
),
```

(`data.dart`, `deferred`, `remount` and segment pages are wrapped the same way; layouts, redirects and
not-found views are not.) `RouteScrollMemory` gives the page a `PageStorage` bucket of its own per history
entry, and what it does with it depends on how the page was reached:

- **The browser brought the entry back** (back, forward, or a reload of the tab): the page gets the bucket the
  entry had, so its keyed scrollables return to where they were. fespalier tells from go_router: it keeps the
  history state the platform hands over, and replaces it with a marker of its own for every navigation the app
  starts.
- **Anything the app starts** (`go`, `push`, `replace`, a `RouteLink`, the first route) gets a fresh bucket, so
  the page starts at the top, and the bucket replaces the one kept for that location.
- **A location the platform reports without history state** (a link opened from outside) counts as the app's,
  so it starts at the top too.

An entry is its matched location, plus the query for the page that is the top of the location
(`/search?q=a` and `/search?q=b` are two entries; `/products` below `/products/42` is `/products`).

Things to know:

- **A page that stays mounted keeps its live scroll.** The page below a child route, a tab, and a page whose URL
  changes in place (`remount: never`, `/c/1` to `/c/2`, or `?page=2` through `copyWith`) are the same widgets
  throughout, so nothing is restored for them; the bucket just moves to the new location. On Android and iOS
  back is a pop and the page below is still mounted.
- **The memory is in memory.** A router keeps the buckets of its 64 most recent entries (the oldest is
  forgotten first), each router has its own, and a reload of the browser tab starts empty. The same location
  twice in the history is one entry: A, B, A, B and back twice restores the second A's offset.
- **A list that grows as it scrolls** (infinite scroll) is rebuilt with its first items only, and Flutter
  clamps the saved offset to what is there. A list that waits for `data.dart` is fine: its offset is applied
  when the list is first built, after `loading.dart`.
- Off, the generated file has no `RouteScrollMemory` at all.

To test it, play the browser: the entry has to come back with the history state the app gave the platform
(`routeInformationUpdated`), as it does in a browser. A `pushRouteInformation` with a location alone is a
location from outside, and starts at the top. `examples/features/test/scroll_restoration_test.dart` records the
state with a mock handler on `SystemChannels.navigation` and sends it back:

```dart
await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
  'flutter/navigation',
  const JSONMethodCodec().encodeMethodCall(
    MethodCall('pushRouteInformation', {'location': '/feed', 'state': saved.state}),
  ),
  (_) {},
);
await tester.pumpAndSettle();
```

`examples/features` has `/feed` with two keyed lists, a horizontal one and a vertical one, and tests for back,
forward, a `go` that starts at the top, and the two lists keeping their own offsets.

## The generator

`cli/` is a Rust binary, `fsp`. A full scan, check and emit of an example runs in a few
milliseconds, fast enough to run on every save.

`fsp` installs as described in [Getting started](#getting-started). To build it from a
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
`fsp gen`, `check` and `watch` also look at the string paths in `lib/` (see
[Checking string paths](#checking-string-paths)). `fsp new` writes `page.dart` (plus the kinds you ask for with flags), skips files that
already exist, and takes its class names from `--name` (default: from the path, e.g.
`ProductsId`). With `--function` it writes [function views](#function-views) instead of classes,
and `--name` becomes the `routeName` (an UpperCamelCase name). A segment that already has a
type elsewhere in the tree keeps it. Pass
`--no-page` to leave `page.dart` out, and `--not-found` to add a `not_found.dart` that takes the
segments of its path as `String`s (see [Not-found views](#not-found-views)). A `(group)` target (like `'(account)'`) gets no
`page.dart` either, since a group has no URL of its own; write one by hand if you want the
group to serve its parent's URL. It then regenerates `lib/app.g.dart` and prints the
result line; if that fails, it lists the files it created. After `fsp new '(account)'
--layout`, the generator warns "folder has no page.dart and no routes below it; skipped"
until you add a route inside the group. That's expected.

`fsp routes` prints what the header of `lib/app.g.dart` lists: each route's URL pattern, its typed
route class, its `page.dart` and its tags (`redirect`, `data`, `action`, `guard`, `layout`, `transition`,
`present`, `observe` (a page with an [`observe.dart`](#route-lifecycle-observedart) at or above it, since 0.8.1), `root`, `sibling` for a route with [`nest = false`](#a-sibling-with-a-compound-path), and
`remount` for a page that [starts again when its URL changes](#remounting-a-page-remount), and last `deferred` for a page whose
[code loads on demand](#deferred-routes-a-pages-code-on-demand), since 0.7.0). Since 0.8.1 `fresh` follows `data` for a route whose data has a
[`freshness`](#freshness-staletime-resume-and-reconnect), and `cached` for one with a [`dataCache`](#a-cache-that-survives-a-restart-datacache).

```text
/products/:id  ProductRoute   products/$id/page.dart  (data, transition)
```

A route with [localized paths](#localized-paths) lists each spelling under its row (`fr  /produits/:id`).

**`--graph`** (since 0.5.0) prints the route _tree_ instead, to paste into a README, a pull request
or an issue: `fsp routes --graph` (or `--graph mermaid`) writes a Mermaid `flowchart TD`, which
GitHub renders in Markdown, and `--graph dot` a Graphviz `digraph` (`fsp routes --graph dot | dot -Tsvg`).
It draws what `app.g.dart` gives go_router, not the folders:

- **Nodes** are routes: the URL pattern, the route class, each spelling of a
  [localized path](#localized-paths) and the markers (`redirect`, `data`, `fresh`, `cached`, `action`, `guard`,
  `observe`, `present`, `root`, `sibling`, and `deferred`, as in the tags above). A `redirect.dart` route is dashed.
- **Edges** are nesting: a page is the parent of the routes in the folders below it, and a route with
  [`nest = false`](#a-sibling-with-a-compound-path) hangs from the page above its parent instead.
  A shell's routes hang from the route above the shell.
- **Boxes** are navigators: the root navigator, a [layout](#file-kinds)'s shell (`layout.dart`, with
  `data` for a [section](#section-data) and `guard` for its folder's guard) and each branch of a
  [tab layout](#tab-layouts).

The output has no timestamp and a fixed order, so a graph committed to a doc changes only when the
routes do. `--graph` and `--json` cannot be combined.

**`--graph json`** (since 0.7.0) prints the same tree as JSON, with each guard, `redirect.dart`,
`data.dart` and `action.dart` as a _site_ the generated code names. It is what the
[DevTools extension](#devtools-extension) reads, and `app.g.dart` embeds it. Every route has its URL
pattern, its route class, its file and folder (relative to the app folder), its markers, its typed parameters and
each other spelling of a localized path; layouts and tab layouts are items of their own.

```text
flowchart TD
  subgraph rootnav["root navigator"]
    subgraph b0["layout layout.dart"]
      n0["/<br/>HomeRoute"]
      n1["/cart<br/>CartRoute"]
      n2["/checkout<br/>CheckoutRoute<br/>(guard)"]
      ...
```

With `--json` it prints one JSON object per line, for scripts and editors, with each
route's parameters and the [manifest](#route-manifest-and-metadart)'s fields; `file` is relative to
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

**`--json` diagnostics.** `fsp gen --json` and `fsp check --json` print each diagnostic to
stdout as one JSON object per line, instead of the rendering below, so an editor can turn them
into squiggles. The success and failure lines still go to stderr, and stdout is empty when
there is nothing to report:

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

**Editor support.** Two editor plugins sit on top of the JSON diagnostics. Neither is on a
marketplace yet, so you build them from source. Both use `fsp` from your `PATH`, or `dart run
fespalier` when there is none, and both check again when you save a file under the app folder
(`fespalier: app_dir:` in `pubspec.yaml`, `lib/app` by default).

- **VS Code:** `editors/vscode/` puts the diagnostics in the Problems panel, with a
  `fespalier: generate` command and a status bar item. Build it with `npm install && npm test
&& npx @vscode/vsce package` in that folder and install the `.vsix` (see
  `editors/vscode/README.md`). `fespalier.runner` chooses the runner.
- **IntelliJ IDEA and Android Studio:** `editors/intellij/` (Kotlin) underlines the problems
  in the editor, with their severity, in the files under the app folder, and adds
  _Tools | fespalier: Generate_ and _fespalier: Check_; a notification says when `fsp` could
  not run. Settings | Tools | fespalier chooses the runner (auto, `fsp`, or `dart run
fespalier`) and the path to `fsp`. It works on platform 252 (2025.2) and later; the
  highlighting of route files needs the Dart plugin, which Android Studio includes. Build it
  with JDK 21:

  ```sh
  cd editors/intellij
  ./gradlew build buildPlugin      # tests, then build/distributions/fespalier-intellij-<version>.zip
  ```

  Then _Settings | Plugins | gear icon | Install Plugin from Disk..._ and pick the zip.
  `./gradlew runIde` starts a sandbox IDE with the plugin instead. See
  `editors/intellij/README.md`.

**Formatting.** The generated file is not formatted by default, so a committed
`app.g.dart` doesn't depend on which Dart SDK ran `fsp`. `fsp gen --format`, or `format: true` in
the pubspec section, pipes it through `dart format` (which needs `dart` on your `PATH`; without
it `fsp` warns and writes the unformatted code). It uses your package's language version
and `analysis_options.yaml` (`formatter: page_width`), like `dart format lib/`, and
`fsp gen` compares the formatted text with the file on disk, so a formatted file that is up
to date stays "unchanged". `fsp watch`, `fsp new` and `fsp init` follow `format:` in the
pubspec. `fsp check` writes and compares nothing, so it never runs `dart`.

What the commands print:

- `fsp gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged`
  when the output didn't change (with `output_manifest`, or a [generated `main()`](#main-appdart-startupdart-and-splashdart)
  since 0.8.1, every file is named: `✓ 12 routes → lib/app.g.dart, lib/app.main.g.dart`).
- `fsp check`: `✓ 12 routes, no errors`.
- `fsp dev` (since 0.9.0): the same `gen` line, then the [full-screen view](#running-your-app-fsp-dev), or with `--no-tui`
  the lines of each process with its name in front, `[fsp] ✓ 12 routes → lib/app.g.dart (3.1ms)`.
- `fsp watch`: the `gen` line once at startup, then a line each time a save changes
  `lib/app.g.dart`. An edit that doesn't (a widget's `build` method, say) prints nothing.
  It ignores its own output and file reads, so it doesn't loop while idle. It keeps the parse
  results of files that didn't change, so a save parses only the file you saved; a save that
  leaves everything the generator reads as it was (a colocated widget, say) doesn't resolve or
  render again, and `dart format` (with `format: true`) only runs on generated code it hasn't
  formatted before. It also watches the rest of `lib/` (Dart files and folders only), because the
  enum a segment names is declared there: editing `lib/models/category.dart` regenerates. See
  [Performance](#performance).

Errors point at the parameter or declaration at fault, and `app.g.dart` is left
untouched while there are any. A file that can't be fully parsed gets a warning instead
(the Dart compiler reports the exact error), and the generator works with what it could
read:

```text
error: can't fill `label`: it isn't a segment of this path ($shop, $id) or data.dart's String
  ┌─ lib/app/shops/$shop/items/$id/page.dart:6:18
  │
6 │   const ItemPage(this.label, {super.key});
  │                  ^^^^^^^^^^

error: `$id` is int in products/$id/data.dart:6 but String here
```

It's built on existing libraries rather than hand-rolled parts:

- [tree-sitter](https://tree-sitter.github.io/) with
  [tree-sitter-dart](https://github.com/nielsenko/tree-sitter-dart) parses Dart.
- [minijinja](https://github.com/mitsuhiko/minijinja) renders the output. The shape of
  `app.g.dart` and of every scaffolded file lives in `cli/templates/`.
- [codespan-reporting](https://github.com/brendanzab/codespan) renders diagnostics.
- [clap](https://github.com/clap-rs/clap) handles the command line, and
  [notify](https://github.com/notify-rs/notify) drives `watch`.

`lib/app.g.dart` is plain go_router + Riverpod code that's meant to be read and committed.
It opens with a route table (see `examples/shop/lib/app.g.dart`). Some details:

- **Types are never re-spelled.** The generator doesn't copy your imports. Values flow
  through inference, and each route's provider is a `static final` whose type is inferred.
  The exceptions are a page's (or a layout's, guard's or redirect's) [typed `extra`](#typed-extra)
  and an [enum segment or query parameter](#enum-segments), whose types the typed route has to
  name; it imports those types by name from the file's imports.
- **Segments and query parameters are parsed into a record** (`({int id, int? page})`).
  Records compare by value, so providers are keyed by them directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
  `(group)` folders fold away completely, apart from the ShellRoute their layout adds.
- **Static routes come first** among siblings, then dynamic ones, then a
  [catch-all](#catch-all-segments), so go_router's first match is the most specific one.
- **`AppRoutes.mount(at:)`** only changes the root path (and, with `navigatorKey:`, the
  root navigator's key). Typed routes read `AppRoutes.base`, so `.location` stays correct when
  mounted under `/shop`.

### Deep links and a sitemap (`fsp links`)

Since 0.5.0. The URLs your app opens are its routes, so the lists the platforms want of them can be
written from the route tree instead of kept by hand: the `<intent-filter>`s of Android App Links and
`assetlinks.json`, the `apple-app-site-association` file and the entitlement of iOS Universal Links,
and a `sitemap.xml`. Say where the app lives in `pubspec.yaml`:

```yaml
fespalier:
  links:
    domains: [shop.example.com]       # required; the first one is the sitemap's
    scheme: myshop                    # optional custom scheme: myshop://shop.example.com/products/2
    android_package: com.example.shop # with android_sha256: the Android files
    android_sha256: ["AB:CD:...:EF"]  # the signing certificates' fingerprints, 32 hex pairs each
    ios_app_id: ABCDE12345.com.example.shop   # Team ID, a dot, the bundle id: the iOS files
    out: links                        # default: where the files go, relative to the project
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

The Android files are written when `android_package` is set (it needs `android_sha256`, and the
reverse), the iOS ones when `ios_app_id` is, and the sitemap always. A key that is missing, a
fingerprint or package that isn't one and the like are errors that name the key (only `fsp links`
checks them: a mistake there never stops `fsp gen`). A file the config no longer asks for is
removed by `fsp links` and reported by `--check`.

**What is listed.** Each route's path, in each spelling of its [localized paths](#localized-paths),
and every route in a folder that doesn't say [`const linkable = false;`](#case-and-trailing-slashes)
(a `route.dart`, inherited down the tree, the nearest one wins). Redirects are opened by the app,
so they are in the Android and iOS lists; a sitemap leaves them out.

| Route                              | Android                                    | iOS (`components`)             | Sitemap                   |
| ---------------------------------- | ------------------------------------------ | ------------------------------ | ------------------------- |
| `/about` (static)                  | `android:path="/about"`                    | `/about`                       | listed                    |
| `/products/:id`                    | `pathPattern="/products/..*"`              | `/products/?*`                 | left out                  |
| `/docs/*rest`                      | `pathPrefix="/docs/"`                      | `/docs/?*`                     | left out                  |
| `/files/*path?`                    | `path="/files"` and `pathPrefix="/files/"` | `/files` and `/files/*`        | left out                  |
| `help/` with `{'fr': 'aide'}`      | one entry per spelling                     | one entry per spelling         | one `<url>` per spelling  |

- **A `$dynamic` segment is a wildcard.** Android's `pathPattern` can't say "one segment", so
  `/products/..*` also lets `/products/2/extra` through; the app's router has the last word and shows
  its not-found view. iOS's `?*` is the same. `linkable = false` removes a route's own entries; it
  can't carve a hole out of the wildcard a dynamic sibling makes (a `$slug` at the root lets every
  one-segment path in).
- **Localized spellings.** Android gets the characters as written, which it compares with the decoded
  path (`/führer`), iOS and the sitemap the percent-encoded form (`/f%C3%BChrer`). The sitemap gives
  each spelling its own `<url>` with `xhtml:link` `hreflang` alternates for every locale (the
  canonical path is `x-default`).
- **iOS case.** A route that is [case-insensitive](#case-and-trailing-slashes) gets
  `"caseSensitive": false` in its component. Android always matches by case.
- **The sitemap lists static routes only.** Dynamic routes and catch-alls have no URL to write down
  without data fespalier doesn't have; a way to list them at runtime is not part of this. Guards
  aren't looked at either: a route behind a guard is listed, so mark it `linkable = false` if a
  crawler shouldn't see it.
- **Mounting.** The paths are the routes' own. An app that mounts its routes under a
  prefix (`AppRoutes.mount(at: '/shop')`) has to put the prefix in front itself.

**Using the files.** `fsp links` never edits `AndroidManifest.xml`, `Runner.entitlements` or
`Info.plist`. Paste `android/intent-filters.xml` into the `<activity>` of
`android/app/src/main/AndroidManifest.xml` that has the `MAIN`/`LAUNCHER` filter (replace what you
pasted last time), add the `applinks:` lines of `ios/associated-domains.entitlements` to
`ios/Runner/Runner.entitlements`, and the entry of `ios/info-url-types.xml` to `Info.plist`. Copy
`links/web/` into your Flutter project's `web/` folder (`flutter build web` ships `.well-known/`
as it ships the rest), or serve it from wherever the domain's server keeps its files. Android only
verifies a domain when `assetlinks.json` is served over HTTPS at `/.well-known/assetlinks.json`
with no redirect.

**Staying current.** The output is a function of the tree and the pubspec (a fixed order, no dates),
so the same input gives the same bytes. `fsp links --check` writes nothing and exits non-zero when
a file is missing, out of date or no longer wanted, and names it; run it in CI next to `fsp check`.
`fsp routes --json` is unchanged.

### Checking string paths

Since 0.7.0. The typed routes (`ProductRoute(id: 2).go(context)`) can't be misspelled, but a string
path is sometimes the right thing (a CMS link, a notification payload), and `context.go('/prodcts/2')`
compiles, runs and shows `not_found.dart`. So `fsp gen`, `check` and `watch` read the string paths
your code gives the router and warn about one that **matches no route**. A path that matches is
fine: typed routes are preferred, not forced.

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

**What matches.** The same rules as `AppRoutes.match`: segments, [catch-alls](#catch-all-segments)
(`$$rest` needs one part, `$$$rest` none), [case](#case-and-trailing-slashes) by the route's own
setting, every [localized spelling](#localized-paths) (mixed spellings too), non-ASCII paths and `%`
escapes decoded, and a trailing slash or `//` ignored. A `redirect.dart` is a route; a
`not_found.dart` is not. The query and the fragment are not looked at (`go_router` ignores
parameters it doesn't know). Since 0.8.1 segment **types are checked** too, the way the route
parses them: `/products/abc` reaches `products/$id`, and with `{required int id}` that route shows
not-found, so it is reported (``` `/products/abc` reaches /products/:id, but `abc` is not an int, so it shows not-found [unknown_path] ```).
As in `AppRoutes.match`, the first route that fits the path decides: a later route that would take
the text is never tried. `int`, `double`, `num`, `bool`, `DateTime` (its start only) and
[enum](#enum-segments) segments are checked, and each part of a typed
[catch-all](#typed-catch-alls). An enum's message lists its values and suggests the nearest. A part
with a space or other non-ASCII whitespace is not judged (Dart trims it before parsing). The message
names the route by its canonical pattern, also for a [localized](#localized-paths) spelling. An app
with `unknown_path: error` that passed on 0.7.0 can fail on 0.8.1 for a path that always showed
not-found. A path that interpolates is checked up to its first `$`: `'/products/$id'` is fine and
`'/prodcts/$id'` is flagged (`no route starts with ...`), and the complete segments before the `$`
are checked by type too (`'/products/abc/$tab'` is reported), but nothing after a `$` is, since the
value can be empty or hold a `/`. A path that is not an app path is skipped: a relative one
(`'details'`), a URL (`'https://...'`), one that starts with an interpolation (`'$base/x'`), one
with a `..` or a malformed `%` escape.

**Which files.** Every Dart file under `lib/` (the app folder included), except the generated ones
(`*.g.dart`, the `output` and `output_manifest`) and folders that start with a `.`. Not `test/`,
`integration_test/` or `bin/`: tests navigate to paths that match nothing on purpose, to try
`not_found.dart`, and mount the tree under prefixes the app doesn't use.

**The mount point.** `AppRoutes.mount(at: '/shop')` is read, and a path is checked below it:
`/shop/products/2` is looked up as `/products/2`. A path outside the mount point belongs to the host
router (`legacyRoutes` beside `...AppRoutes.mount(at: '/shop')`) and is skipped. When `at:` is not a
string literal, or two calls give two different values, `fsp` can't know where the tree is, and the
check reports nothing for the run. A host router with routes of its own and the tree mounted at `/`
gets a warning for those routes' string paths: silence them as below, or turn the lint off.

**Severity.** `lints:` in the `fespalier:` section of `pubspec.yaml`:

```yaml
fespalier:
  lints:
    unknown_path: warning # default; `error` fails `fsp gen` and `fsp check`; `off` skips the check
```

A warning never fails a command, so a false positive can't break a build. With `error`, `fsp check`
exits 1 (``1 error(s) in string paths (`lints: unknown_path: error`)``), and so do `fsp gen` and
`fsp watch` after they write the output (``...; lib/app.g.dart is up to date``): the generated file
doesn't depend on the lint, so a typo in some other file does not stop `watch` from regenerating.
`fsp new` and `fsp init` report it as a warning at most. If the route tree itself has errors, the
check doesn't run: a half-resolved tree would make every path look unknown.

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
plugins show, and `fsp check` in CI and `fsp watch` next to `flutter run` get the lint with nothing
for an app to add. An analyzer plugin would have to be loaded through `analysis_options.yaml`, which
takes a package from pub.dev or a `path:` and not a git dependency (fespalier is one), pins an
`analyzer` major that moves several times a year, and would need its own copy of the matcher. The
cost of a syntax tree is that `fsp` can't know that `context` is a `BuildContext`: it only reads
string literals in the call shapes above.

`examples/shop` has a string path that matches (`context.go('/products?sort=expensive')`), one
that is silenced, and `unknown_path: error`, so `just check-examples` fails if it gains a bad one.

### Maestro flows (`fsp maestro`)

Since 0.7.0. [Maestro](https://docs.maestro.dev) drives an app from the outside, through the
platform's accessibility tree, so it cannot see a Flutter `Key`. It finds text, a `Semantics` label
and a `Semantics(identifier:)`, which its `id:` selector matches. `fsp` gives every page one, and
writes a smoke flow for each route that opens the route's URL and waits for that page.

**`semantics_ids: true`** in the `fespalier:` section of `pubspec.yaml` wraps each page's own widget in

```dart
Semantics(identifier: 'route:/products/:id', container: true, child: ProductPage(id: v.id))
```

The identifier is `route:` and the pattern `fsp routes` prints (`route:/`, `route:/products/:id`,
`route:/docs/*rest`, `route:/files/*path?`). It depends only on the folder path, so it is the same for
every [localized spelling](#localized-paths) and every mount prefix, and it does not change when you
rename a class. It is in the widget tree **if and only if the route's own page is built**:

- The wrapper sits on the innermost call, inside `DataView`, `DeferredView` and `SectionView`, so `loading.dart`,
  `error.dart` and `not_found.dart` do not carry it. A flow cannot pass while a spinner or an error shows,
  nor while a [deferred](#deferred-routes-a-pages-code-on-demand) page's code is loading.
- go_router builds the whole matched stack, but the pages underneath the top one are off screen and
  out of the semantics tree: `/products/1` has `route:/products/:id` and not `route:/products`.
- Only a `page.dart` gets one: not a layout, a shell, a redirect or a not-found view.
- `Semantics` has no `const` constructor, so the wrapper is never `const`; a page that was `const`
  keeps its own `const` inside it, and the generated code passes the `const` lints. The `container: true`
  node adds a node boundary and no label or action, so a screen reader has nothing to read from it. With the key off (the default), the
  generated file is exactly what it was without the feature.

On the web Flutter builds no semantics tree until a screen reader asks for one, so a driver that reads
the page from outside finds nothing. With `semantics_ids: true` the generated `AppRoutes.mount()`
(which `router()` calls, so an app that embeds the routes is covered too) first calls
`ensureWebSemantics()` from `package:fespalier`. On the web it calls
`SemanticsBinding.instance.ensureSemantics()` once and keeps the handle for the life of the app;
anywhere else, and in every widget test (which runs on the VM), it does nothing. **That is not free:
the tree stays on in the web build for every user of it,** which costs frame time and DOM nodes, and
there is no key that narrows it to a test build. Weigh it before you turn the key on in an app
whose web build you ship.

**`maestro:`** says what the flows open. These are all the keys:

```yaml
fespalier:
  semantics_ids: true              # required by `fsp maestro`
  maestro:
    app_id: com.example.shop       # Android and iOS: each flow's `appId:`   } exactly one
    url: http://localhost:8080     # the web: each flow's `url:`             } of the two
    link: myshop://shop.example.com   # what a route's path is appended to; default below
    out: .maestro/routes           # default; a folder inside the project, no `..`
    guard_flow: .maestro/sign-in.yaml   # optional: runs before the link of a guarded route
    timeout: 20000                 # default; how long a flow waits for the page, 1000 to 600000 ms
    samples:                       # the value of each dynamic folder, inherited by the routes below it
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
  `(members)/notes/$id`), and each must be a `$x`, `$$x` or `$$$x` folder. A value is text, a number, a
  boolean or, for a catch-all, a list of them; it is percent-encoded and checked against the segment's
  type (`int`, `double`, `num`, `bool`, and `List` of them; a `String`, a `DateTime` or an enum is taken as
  written, because the generator doesn't know an enum's values). The sample is for the _folder_, so
  every route below `products/$id` opens `/products/2/...`. An optional catch-all (`$$$path`) with no
  sample is the bare path. Quote a value that must stay text (`'1.10'`).

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

`launchApp` starts the app afresh, so every flow begins from the same state. `openLink` opens the
route's sample URL (the long form with `autoVerify: true` for an Android app whose link is `https`,
which skips Android's "Open with" dialog), and `extendedWaitUntil` returns the moment the identifier is
on the screen, or fails after `timeout`. The route's guards ran, its data loaded and its page was built.
A guarded route's flow also has `- runFlow: "../sign-in.yaml"` between `launchApp` and `openLink`
(the path is relative to the flow, as Maestro wants it) and a comment naming the `guard.dart` files.

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
`home_route.yaml` (the `_route` ending keeps a file from being Maestro's `config.yaml`). Every file
`fsp maestro` writes starts with ``# Written by `fsp maestro` ``. In `out`, a `*.yaml` file with that first
line is `fsp`'s: `fsp maestro` deletes it when no route needs it any more, and `--check` reports it. Any
other file there (a flow you wrote, a `config.yaml`) is never read or touched, so hand-written
journeys live beside the generated ones. The output is a function of the tree and the pubspec (a
fixed order, no dates), so `fsp maestro --check` writes nothing and exits non-zero when a flow is
missing, out of date or no longer a route's, and names it; run it next to `fsp check`. It does not check that
`lib/app.g.dart` is current: that is `fsp check`'s job. The values of `maestro:` are checked only by
`fsp maestro`, so a mistake there never stops `fsp gen`.

**Running them.** `maestro test .maestro/routes`. Pass the folder, not `.maestro`: Maestro runs only the
top-level flows of the folder it is given, and skips subfolders unless a `config.yaml` there lists them
(`flows: ["routes/*"]`). `maestro test -e APP_ID=... -e URL=...` fills in variables.

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

**In CI.** Since 0.8.1 this repository's `web-routes` job builds `examples/shop` for the web (a release
build with `--no-web-resources-cdn`, in a throwaway copy: the examples have no `web/` folder), serves it,
and replays every committed flow in Chromium, with every request that is not to the local server blocked.
It reads the very same YAML: `launchApp`, `openLink`, then it waits for the element whose
`flt-semantics-identifier` is the flow's `id:`, within the flow's `timeout`. That is not Maestro (the
browser is the Chromium that a pinned [Playwright](https://playwright.dev) installs, and Maestro's own
driver is out of the picture), so it can gate a pull request: what it proves is what fespalier answers
for (the identifier reaches the web DOM, `ensureWebSemantics()` ran, the link opens the route, its
guards, data and deferred chunk let the page build in time). `just web-routes` runs it (Flutter and Node
needed, about two minutes, not part of `just ci`), and `scripts/check-web-routes.sh <example>` with
`ci/web-routes/` is a template for an app's own CI.

To run Maestro itself, build and serve the web app, then run the flows and `fsp maestro --check`.
Maestro's web driver follows Chrome and has broken on Chrome upgrades before (its changelog has
Chrome-version fixes in 2.1.0, 2.2.0 and 2.9.0), so pin the Maestro version, check the download's sha256, and do not make it
the only gate. This repository runs it weekly and on demand (`maestro-web.yml`, Maestro 2.11.0), and a
red run there is not a failed pull request.

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

### Web chunk sizes (`fsp size`)

Since 0.8.1. A [deferred route](#deferred-routes-a-pages-code-on-demand) is a
`main.dart.js_N.part.js` on the web, and the chunk files say nothing about which route they belong
to. `fsp size` reads that out of the build and reports what each deferred route costs, and it can hold
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
- **`--json`** prints one object per line on stdout: `{"kind":"main","file":"main.dart.js","bytes":…,"budget":…}`,
  then `{"kind":"route","pattern","route","file","parts":[…],"own","shared","bytes","budget"}` for each deferred route
  (`file` is the page, relative to the project, as in `fsp routes --json`; `parts` are
  in dart2js's order), then `{"kind":"part","file","bytes","routes":[…]}` for every chunk (`routes` is empty for an
  `other` one). `budget` is `null` without one.

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
    build: build/web      # default; the `flutter build web` output, inside the project
    main: 3 MB            # main.dart.js
    route: 64 KB          # each deferred route's total (own + shared)
    routes:               # per route, by pattern as `fsp routes` prints it; wins over `route`
      /checkout: 8 KB
```

A size is a number of bytes (an integer of at least 1), or a number with a unit: `B`, `KB` (1,024
bytes) or `MB` (1,048,576 bytes), spelled in capitals, with or without a space, and with a fraction if you
like: `3 MB`, `1.5 MB`, `64KB`, `900 B`. A budget on a route that is not deferred is an error (budget
that code with `main`). `fsp size --check` reports as above and exits non-zero when anything is over
(`2 over budget: /checkout, /products/:id`), and also when there is no budget to check. In CI:

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

### Route smoke tests (`fsp test`)

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

**The file and who owns it.** The file's first line is
``// Written by `fsp test` from lib/app/: don't edit it, run `fsp test` again.`` and `fsp test` writes only
that file. It never overwrites a file of that name that does not start with the marker: it fails and says so
(move your file, or set `out`). The output is a function of the tree and the pubspec (route-table order, no
dates), so `fsp test --check` writes nothing and exits non-zero when the file is missing or out of date.
The second line is `// dart format off`. The file is laid out to need no formatting: a call is split one argument
to a line, each with a trailing comma, which is what `dart format` leaves alone under an SDK older than 3.7
(the short style, which does not read the marker); under 3.7 and later the marker holds the formatter off.
Either way `dart format --set-exit-if-changed` is clean on it, in every style.

**`test:`** has these keys, all optional. `fsp test` works with no `test:` section at all:

```yaml
fespalier:
  test:
    out: test/routes               # default; `test`, `integration_test` or a folder below one
    setup: test/routes/setup.dart  # default: <out>/setup.dart, used when it exists
    timeout: 30000                 # default; milliseconds of the fake clock a test waits for its page, 1000 to 600000
    samples:                       # default: `maestro.samples`; same format
      products/$id: 1
    skip: [/admin]                 # patterns as `fsp routes` prints them
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

### Performance

Measured on synthetic apps (`cli/src/bench.rs`: sections of 25 routes with layouts and guards,
a `data.dart` on every fifth route, query parameters on every third page, dynamic segments;
5,000 routes are 7,400 files and a 5.8 MB `app.g.dart`), a release build, 4 cores, warm file
cache. Re-run them with `cd cli && cargo test --release bench -- --ignored --nocapture
--test-threads=1`. Milliseconds, before → after this change (run to run they vary by about
15%; the 500-route cold run is within that):

| Routes | `gen` cold | `watch`: a save, output unchanged | `watch`: a save, output changed | `watch`: a file `fsp` doesn't read |
| -----: | ---------: | --------------------------------: | ------------------------------: | ---------------------------------: |
|    500 |    53 → 56 |                           31 → 28 |                         37 → 22 |                             36 → 7 |
|  2,000 |  284 → 156 |                         121 → 113 |                       132 → 108 |                           107 → 28 |
|  5,000 |  626 → 429 |                         405 → 263 |                       403 → 279 |                           424 → 77 |

With `format: true` (`dart format` of the generated file):

| Routes |      `gen` cold | `watch`: a save, output unchanged | `watch`: a save, output changed | `watch`: a file `fsp` doesn't read |
| -----: | --------------: | --------------------------------: | ------------------------------: | ---------------------------------: |
|    500 | 1.27 s → 1.41 s |                    1.24 s → 29 ms |                 1.24 s → 1.27 s |                      1.25 s → 8 ms |
|  2,000 | 4.96 s → 5.05 s |                   4.84 s → 104 ms |                 5.11 s → 4.93 s |                     4.83 s → 30 ms |
|  5,000 | 13.4 s → 13.4 s |                   12.7 s → 274 ms |                 13.3 s → 14.1 s |                     12.9 s → 77 ms |

"Output unchanged" is a comment added to a page, which changes the file and not what is
generated; "output changed" changes the type of a query parameter. Where the time goes at
5,000 routes, cold: walking the folders and reading the files 82, parsing 208 (now spread
over the cores), resolving 29, emitting 153 (the model 50, `minijinja` 105), writing 6.
Emitting was 277 before: the check that a `/:slug` doesn't hide a page compared every page
with every earlier one, 125 ms of it at 5,000 routes. And `dart format`, when it is on,
dwarfs all of it: 1.4 s at 500 routes, 5.3 s at 2,000, 14 s at 5,000, because the formatter
reads the whole file.

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
  the generated code (a `build` method, most of the time) skips it: the 1.2 to 13 s above
  become the 30 to 270 ms of a run without `format:`. Code that did change is formatted in full, because the
  formatter needs the whole file. If that hurts in a huge app, leave `format:` off in
  `watch` and format in CI.
- Nothing is written when the output is byte-identical to the file on disk (it always was so).

What it doesn't do, and why: per-route caching of resolved results, and re-scanning only the
changed folders. A full resolve is 30 ms at 5,000 routes, a tenth of a save that changes
output, and resolving one route reads the folders above it and shares state with the others
(names claimed, query types settled), so a per-route cache would have to replay those effects
for a saving smaller than its bookkeeping. The walk is 80 ms at 5,000 routes, and reading the
files a small part of it; a cache keyed on modification times would save less than it risks
(an edit in the same timestamp tick, a file replaced by one with the same size and time).

## Authentication

Since 0.9.0. fespalier's core has no auth feature, and gains none: no file kind, no `fespalier:` key, no `fsp`
command, and `app.g.dart` is the same bytes. `package:fespalier_auth` is the pattern of
[Guards](#guards) packaged: a session provider, guards for `guard.dart`, token storage, lazy refresh with a
single flight and an authenticated HTTP client, behind one `AuthBackend` interface. An app that does not
depend on it is unchanged, and it adds no timer and no listener to one that does.

- **The session** is a provider, `authSession`, whose state is sealed: `SessionRestoring`,
  `SignedOut(reason)` and `SignedIn(session)`.
- **`restoreAuth(config)`** in `startup()` reads the stored session before the first frame, and never touches
  the network.
- **The guard helpers** (`requireSignedIn`, `requireRole`, `requireUser`, `redirectIfSignedIn`) are plain
  Dart over a `Ref`, so a guard stays synchronous, and signing in navigates back by itself.
- **`authHttpClient`** is a `package:http` client that attaches the session to your API's requests, refreshes
  once when the token has expired and sends a request again after a 401.
- **`package:fespalier_auth/testing.dart`** has `fakeAuth(...)`: a signed-in or signed-out test in one line.

### Installing fespalier_auth

Add it next to fespalier, with the same `url` and the same `ref` (pub resolves the two to one package only if
they are the same repository dependency; a mismatch fails with `Because every version of fespalier_auth from
path depends on fespalier from git https://github.com/fespalier/fespalier at v0.7.0 in packages/fespalier and
demo depends on fespalier from git https://github.com/fespalier/fespalier at v0.6.0 in packages/fespalier,
fespalier_auth from path is forbidden.`, the form it takes when the first is a path):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_auth:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_auth
      ref: v0.8.1
```

<!-- x-release-please-end -->

The package needs Dart 3.8 and Flutter 3.32 or newer. Its one plugin is `flutter_secure_storage` (the token
store; its Android minSdk is 24, and `>=10.0.0 <12.0.0` is accepted), so it is in an app that imports this
package whichever backend it uses. A backend that is an SDK of its own (Firebase, Supabase) keeps its own
session and does not use the store.

### The session

```dart
final state = ref.watch(authSession); // SessionRestoring | SignedOut | SignedIn
```

| Provider                         | What it is                                                                                                                            |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `authSession`                    | The `SessionState`, and `ref.read(authSession.notifier)` for `signIn`, `adopt`, `signOut` and `tokens()`. Not auto-disposed           |
| `isSignedIn` (a `bool`)          | What a guard watches: a token refresh does not change it                                                                              |
| `authUser` (`AuthUser?`)         | The user: `id`, `roles`, `claims`, `email`, `name`. Changes when the user or their roles do, never on a refresh that changes nothing  |
| `authUserId` (`String?`)         | Watch it in a `data.dart` whose data belongs to the user: another user loads it again, a token refresh does not                       |
| `authConfig`, `authInitialState` | The app's `AuthConfig`, and what `restoreAuth` read. Reading `authConfig` with no override throws a `StateError` that says what to do |

There is **no `refreshing` state**: a refresh keeps `SignedIn` and swaps the tokens, so a guard that watches
the session never runs again, and a request is never bounced to the sign-in page in the middle of one. When
the server refuses the refresh token, the state becomes `SignedOut(reason: SignOutReason.expired)` (the
sign-in page can say "your session expired"); `SignOutReason.user` is a sign-out, and `keyLost` is a session
bound to a device key that is gone (see below). `AuthTokens`, `AuthUser`, `AuthSession` and `PasswordSignIn`
print without a token, an id, an e-mail or a password (`AuthUser(roles: {admin})`), so a log line is safe.
`unverifiedJwtClaims(token)` reads a JWT's payload for display and routing; it does not verify it, and the
server still decides.

### Restoring at startup

```dart
// lib/app/startup.dart
FutureOr<List<Override>> startup() => restoreAuth(authSetup());

// lib/auth_setup.dart
AuthConfig authSetup() => AuthConfig(
  backend: ApiBackend(Uri.parse('https://api.example.com')), // an AuthBackend
  apiOrigins: [Uri.parse('https://api.example.com')],        // where the session is sent: nothing else
);
```

`restoreAuth` returns the overrides for the app's `ProviderScope` (the generated `main()` calls
[`startup()`](#main-appdart-startupdart-and-splashdart) and passes them), so every guard is synchronous from
the first navigation: a cold deep link to a signed-in page has no blank frame and no redirect. It is
**synchronous** when the store answers synchronously (`MemoryTokenStore`, a backend that keeps its own
session) and one keychain read otherwise (`SecureTokenStore`, the default), shown behind `splash.dart`, or the
native splash when there is none. It does **no network**: an expired access token is refreshed by the first
request that needs it, so an offline start works. It drops what it cannot trust, without a request:

| Stored session                                                                                  | Result                                                                                                      |
| ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| none                                                                                            | `SignedOut()`                                                                                               |
| another backend's (`AuthBackend.name` differs)                                                  | deleted, `SignedOut()`                                                                                      |
| refresh token expired (`refresh_expires_in`), or the access token expired with no refresh token | deleted, `SignedOut(reason: SignOutReason.expired)`                                                         |
| bound to a DPoP key that is gone, or another                                                    | deleted, `SignedOut(reason: SignOutReason.keyLost)`                                                         |
| corrupt                                                                                         | reported (`FlutterError.reportError`, context `while restoring the stored session`), deleted, `SignedOut()` |

A store that cannot be read at all (a locked keychain) makes `startup()` fail, which the generated `main()`
shows with a retry. `AuthConfig` has `backend`, `store`, `apiOrigins` and `leeway` (30 seconds before expiry
an access token counts as expired). A stored session is `AuthSession.toJson` under one key
(`fespalier_auth.session`): the Keychain with `first_unlock_this_device` (not in backups, not on another device),
Android's encrypted storage, and on the web encrypted `localStorage`, which a script on the page can read: use
`MemoryTokenStore` there (a reload signs out) for anything that matters. Install the telemetry sink first in
`startup()` to see the restore as a span.

An app with no `startup.dart` still works: add `authConfig.overrideWithValue(config)` to the `ProviderScope`,
and the session restores itself at the first read. The state is `SessionRestoring` meanwhile, and the guard
helpers return a `Future` for that long, which costs a frame.

### Guarding signed-in routes

```dart
// lib/app/(signed-in)/guard.dart: every route under the group needs a session
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));

// lib/app/(signed-in)/admin/guard.dart: and this one an admin
GuardResult guard(Ref ref, {required Uri uri}) => requireRole(
  ref, uri, 'admin',
  signIn: (from) => SignInRoute(from: from),
  forbidden: const ForbiddenRoute(),
);

// lib/app/sign-in/guard.dart: the sign-in page's own guard, beside the group
GuardResult guard(Ref ref, {String? from}) => redirectIfSignedIn(ref, from: from);
```

- **`requireSignedIn(ref, uri, signIn:)`** returns `null` when signed in, else `signIn(uri.toString()).location`:
  a typed call the compiler checks, with the requested location (query included) as `from`. It watches only
  the session's phase, so it runs again on sign-out (the user is moved in that frame) and never on a refresh.
  It answers **synchronously**, unless the session is still being restored.
- **`requireRole(ref, uri, role, signIn:, forbidden:)`** is `requireSignedIn`, then `forbidden` when the user
  lacks the role. **`requireUser(ref, uri, test, ...)`** takes a function of the `AuthUser` instead. They
  watch only their own answer, so a role gained or lost runs the guard again, and a refresh does not.
- **`redirectIfSignedIn(ref, from:)`** is for the **sign-in route's own** `guard.dart`: when there is a
  session it returns `returnTo(from)`. It watches the session, so **signing in on that page sends the user
  back to `from` by itself**, and the page has no navigation code. Without it, signing in changes the state
  and nothing moves. `returnTo` refuses `//host`, `https://…` and `/\`, so a crafted `?from=` cannot send
  the user elsewhere.
- **The sign-in page sits beside the guarded group**, never inside it: a guard on the sign-in page would send
  the user to the sign-in page. A guard under a **pushed** page reacts only when you pop back to it (see
  [Guards](#guards)), so a sign-out button over a pushed page should navigate too:
  `const HomeRoute().go(context)`.
- A guard is not access control: the server decides what a token may do.

### Signing in and out

The sign-in page is a [form on an action](#forms-form-and-validate), and the backend throws
`FieldErrors` for wrong credentials, which the form shows under its field:

```dart
// lib/app/sign-in/action.dart
typedef SignInFields = ({String username, String password});

SignInFields form() => (username: '', password: '');

FieldErrors? validate(SignInFields input) => FieldErrors({
  if (input.username.trim().isEmpty) 'username': 'Enter your user name',
  if (input.password.isEmpty) 'password': 'Enter your password',
});

Future<void> action(Ref ref, {required SignInFields input}) async {
  await ref
      .read(authSession.notifier)
      .signIn(PasswordSignIn(username: input.username.trim(), password: input.password));
}
```

`signIn(request)` asks the backend, **stores the session, then** sets `SignedIn`, and rethrows what the
backend threw with the state unchanged: `AuthCancelled` (the user closed a browser sign-in), `FieldErrors`
(wrong credentials), `AuthRejected` (the server refused), or any other error (it could not ask). A sign-in
overtaken by another one, or by a sign-out, throws `NotSignedIn` and changes nothing. The request is typed:
`PasswordSignIn`, `BrowserSignIn`, or a subclass of `SignInRequest` of your own, so a page is the same
whichever backend is configured, and a test swaps in `FakeAuthBackend`. `adopt(session)` signs in with a
session the app obtained itself (a deep-link callback, a multi-step SDK flow), and throws an `ArgumentError`
when it comes from another backend than the configured one.

`signOut()` sets `SignedOut(reason: SignOutReason.user)` **synchronously**, so the guards move the user in that
frame, then clears the store, runs the backend's `signOut` (best effort: its errors are swallowed, the user is
out anyway) and resets the proof of possession. It does nothing when nobody is signed in.

A backend is `AuthBackend`: `name` (a short constant, `oidc`, `firebase`, `api`: what a stored session is
tied to, and telemetry's `fespalier.auth.backend`), `signIn`, `refresh` and `signOut`. `refresh` throws
`AuthRejected` when the server refused (the session is over) and anything else when it could not ask (the
session stays). The starter in `skills/fespalier-guards/references/auth-package.md` is a complete one over
a JSON API: a `POST /auth/login` and `/auth/refresh`.

### Calling your API

```dart
// lib/app/(signed-in)/orders/data.dart
Future<List<Order>> data(Ref ref) async {
  ref.watch(authUserId); // another user: load again; a token refresh: nothing
  final response = await ref.watch(authHttpClient).get(Uri.parse('https://api.example.com/orders'));
  if (response.statusCode != 200) throw ApiError(response.statusCode);
  return Order.listFromJson(response.body);
}
```

`authHttpClient` is a `SessionClient` on `authBaseClient` (override it with a `MockClient` in a test). A request
to an origin in `AuthConfig.apiOrigins` carries `Authorization: Bearer <token>`; any other origin gets nothing,
so a token cannot leak to a third party, and `apiOrigins` empty is an error the first time `authorizer` is read.

- **Refresh is lazy and single-flight, with no timer.** `ref.read(authSession.notifier).tokens()` returns the
  tokens **synchronously** while the access token is good, and starts one shared refresh when it has expired
  (`expiresAt` less `leeway`, against `clock.now()`), after a 401 to the token in use, or when forced. Any number
  of requests that find it expired wait for the same `Future`: with refresh-token rotation (Keycloak's "Revoke
  Refresh Token"), a second refresh with the same token would sign the user out. The new tokens are stored
  before the state publishes them, so a kill between the two leaves the store on the token the server accepts.
- **A refresh the server refuses** (`AuthRejected`, an OAuth `invalid_grant`) signs the user out with `expired`
  and clears the store. **One that could not run** (offline, a 5xx: `AuthUnavailable`, a `ClientException`)
  keeps the session, and the next request asks again.
- **At most three sends per request**: the first, one after a DPoP nonce challenge, and one after a 401 and a
  refresh. Only a request that can be sent again (what `get`, `post`, `put`, `patch` and `delete` make) is:
  a multipart or streamed body is sent once, and its caller gets the 401, after the refresh, so its next
  attempt works. A second 401 is returned as it is.
- **For a client of your own**, `ref.watch(authorizer)` has `authorize(method, uri)` (the headers) and
  `retry(attempt, statusCode:, headers:)` (send again?).
- **One container.** The single flight is per `ProviderContainer`: a second isolate or a second web tab that
  refreshes the same rotating token gets `invalid_grant`. Refresh in one place, or do not turn rotation on.
- **A replay is marked, and keeps its abort trigger.** A request that is sent again (after a 401 and a refresh, or after a DPoP nonce challenge) is `isAuthReplay(request)`
  for `SessionClient` and `options.extra[authReplayKey]` (`'fespalier.auth.replay'`) for `SessionInterceptor`, so
  a guard that refuses re-sends of writes can let that one through; the first send is not a replay. A request made
  with `http.AbortableRequest(..., abortTrigger: future)` is copied with the same trigger (`package:http` 1.5.0 and
  later), so aborting still cancels the replay when the page that wanted it goes away.
- **Do not put `RetryClient` under the session.** `package:http`'s `RetryClient` sends the same headers again, so
  under a client that signs requests it re-sends the same signature. With DPoP that is the same proof, and the server
  refuses a reused `jti` (Keycloak answers `invalid_request` with `DPoP proof has already been used`). Wrap the
  session client in a `RetryClient` instead, `RetryClient(ref.watch(authHttpClient))`, so each attempt asks the
  authorizer for a proof of its own, and do not override `authBaseClient` with a `RetryClient` when the backend uses
  DPoP.
- **User data across users.** A `dataCache` keeps the previous user's data until it loads again: watch
  `authUserId` in user-owned data and clear the cache storage on sign-out.

### OpenID Connect and Keycloak

`package:fespalier_auth/oidc.dart` (a separate library: an app that signs in some other way links none of
it) has `OidcBackend`: the authorization code flow with PKCE (S256) for a **public** client, in pure Dart over
`package:http`, with Keycloak's defaults. It owns the token exchange and the refresh, which is what makes the
single flight, refresh-token rotation and [DPoP](#device-bound-tokens-dpop-with-fespalier_sign_keypair) on the
token endpoint possible. The browser step is a function you give it, so the package links no plugin:
`flutter_web_auth_2` (MIT; Android, iOS, macOS, web, Windows and Linux) is the usual one.

```dart
// lib/auth_setup.dart
final issuer = Uri.parse('https://sso.example.com/realms/shop');

AuthConfig authSetup() => AuthConfig(
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(issuer), // no discovery request
    openBrowser: openBrowser,
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);

Future<Uri> openBrowser(Uri url, Uri redirect) async {
  try {
    return Uri.parse(
      await FlutterWebAuth2.authenticate(
        url: url.toString(),
        callbackUrlScheme: redirect.scheme,
        options: const FlutterWebAuth2Options(preferEphemeral: true),
      ),
    );
  } on PlatformException catch (e) {
    if (e.code == 'CANCELED') throw const AuthCancelled();
    rethrow;
  }
}
```

The sign-in button calls `ref.read(authSession.notifier).signIn(const BrowserSignIn())` straight from its
`onPressed` (a web popup is blocked when `signIn` runs later), and catches `AuthCancelled`. The sign-in guard
moves the user. `BrowserSignIn` has `loginHint`, `prompt` (`login` shows the form over a single-sign-on cookie,
`none` fails with `login_required`) and `parameters` (`{'kc_idp_hint': 'google'}`).

- **What it checks.** The redirect: its `state`, its `error` (`access_denied` is `AuthCancelled`, anything
  else an `OidcException`), its `iss` when present (RFC 9207, which Keycloak sends) and its `code`. Then the ID
  token's `iss`, `aud` and `nonce`. The ID token's signature is **not** verified (OpenID Connect Core 3.1.3.7: it
  came straight from the token endpoint over TLS). Every message is in the troubleshooting skill.
- **Roles** come from the access token: `realm_access.roles` and `resource_access.<clientId>.roles`
  (`keycloakRoles(clientId)`, the default; pass `roles:` to read another claim). Keycloak does not put them in
  the ID token unless a mapper does.
- **Discovery.** `OidcEndpoints.keycloak(issuer)` spells Keycloak's four endpoints, and
  `OidcEndpoints.discover(issuer)` reads `<issuer>/.well-known/openid-configuration` and refuses a document whose
  `issuer` is another one. Leave `endpoints:` out and discovery runs at the first sign-in or refresh, once.
- **Sign-out** revokes the refresh token (RFC 7009), which makes Keycloak end the whole session, best effort.
  `endBrowserSession(session)` also ends the browser's single-sign-on session through the end-session endpoint;
  with `preferEphemeral: true` there is none to end.
- **No timeout of its own** (that would be a timer): pass `client:` an `http.Client` that times out if you want one.
  A confidential client (a `client_secret`) is out of scope: a mobile or web app is a public client.

**Keycloak settings and traps**, read from a live Keycloak 26.8.0 (`examples/auth/keycloak/realm-fespalier.json`
is a realm exported from it, and `packages/fespalier_auth/test/keycloak_live_test.dart` runs `OidcBackend`
against it):

- A **public client** with Standard flow on, Direct access grants off, and the client attribute
  `pkce.code.challenge.method` set to `S256` (without a challenge the authorization endpoint answers
  `error=invalid_request&error_description=Missing+parameter%3A+code_challenge_method`). Its **valid redirect
  URIs** must list `redirectUri` exactly.
- **"Revoke Refresh Token"** makes a refresh token good once: a second refresh with the same one answers
  `invalid_grant` with `Maximum allowed refresh token reuse exceeded`, **and the whole session is then gone**.
  That is why the refresh is a single flight, and why two isolates or two web tabs that share a session sign each
  other out.
- **The refresh token lives as long as the SSO session's idle timeout** (30 minutes by default; the token
  response's `refresh_expires_in` says): a user who is away longer gets `invalid_grant` with `Token is not active`.
  For longer sessions ask for the `offline_access` scope
  (`OidcBackend(scopes: ['openid', 'profile', 'email', 'offline_access'])`).
- **The issuer is Keycloak's configured hostname.** With `--hostname=http://10.0.2.2:8080` every token says
  `http://10.0.2.2:8080/realms/...`, so an app that reaches the same Keycloak as `localhost` gets `the ID token was
  issued by ..., not ...`. On an Android emulator, use `adb reverse tcp:8080 tcp:8080` and `localhost`, or give
  Keycloak the `10.0.2.2` hostname.
- **A single-sign-on cookie signs the user in again silently** after a sign-out, unless the browser session is
  ephemeral (`preferEphemeral: true`) or the sign-in asks `BrowserSignIn(prompt: 'login')`.
- `examples/auth` has the Docker command and the `--dart-define=OIDC_ISSUER=...` that runs the example against it.

### Firebase, Supabase and your own API

Firebase's and Supabase's SDKs keep the session and refresh it themselves, so their backends say
`keepsOwnSession`: the token store is not used, `currentSession()` is read once at start-up (a one-shot read of the
SDK, so the framework holds no listener), and `refresh` asks the SDK for new tokens. They are **recipes, not
packages**: a first-party package for each would add a heavy SDK to every app and a release surface, and most of
what `fespalier_auth` does would go unused there. The code, compiled by `just skill-samples`, is in
`skills/fespalier-guards/references/auth-backends.md`:

- **Firebase** (`firebase_auth`, no Linux): `signIn(PasswordSignIn)` is `signInWithEmailAndPassword`, whose
  `wrong-password`, `invalid-credential` and `user-not-found` become `FieldErrors`; `refresh` is
  `getIdTokenResult(true)`, and `user-disabled` or `user-token-expired` become `AuthRejected`. Initialise Firebase in
  `startup()` before `restoreAuth`.
- **Supabase** (`supabase_flutter`): its client **auto-refreshes with a timer by default**, so initialise it with
  `authOptions: FlutterAuthClientOptions(autoRefreshToken: false)` and refresh lazily with `refreshSession()`.
  Import it with a prefix: `gotrue` exports `AuthState`, `Session` and `User`.
- **Your own API** (a username and a password): `examples/auth/lib/demo/demo_backend.dart`, which is tested. A wrong
  password is a `FieldErrors`, a refused refresh token is `AuthRejected`, and a socket error or a 5xx keeps the session.

`package:fespalier_auth/dio.dart` has `SessionInterceptor(authorizer, dio)`, the policy of `authHttpClient` on dio's
types: `dio.interceptors.add(SessionInterceptor(ref.watch(authorizer), dio))`. `FormData` bodies are not sent again,
and a refresh that could not run is a `DioException` whose `error` is the `AuthUnavailable`. dio is a dependency of
`fespalier_auth`, and is tree-shaken when that library is not imported.

### Device-bound tokens: DPoP with fespalier_sign_keypair

`package:fespalier_sign_keypair` (a separate package, since 0.9.0) is **DPoP**
([RFC 9449](https://www.rfc-editor.org/rfc/rfc9449)) for `OidcBackend`: every token request, refresh and API call
carries a proof, a JWT signed by a key that lives in the Secure Enclave (iOS, macOS) or the AndroidKeyStore
(StrongBox or the TEE), through [flutter-sign-keypair](https://github.com/vaam-apps/flutter-sign-keypair). The server
binds the access and refresh tokens to that key (`cnf.jkt`), so a token copied off the device is useless without the
device. It implements `fespalier_auth`'s `ProofOfPossession`, so nothing else in the app changes:

```dart
// lib/auth_setup.dart
AuthConfig authSetup() => AuthConfig(
  backend: OidcBackend(
    issuer: issuer,
    clientId: 'shop-app',
    redirectUri: Uri.parse('com.example.shop:/callback'),
    endpoints: OidcEndpoints.keycloak(issuer),
    openBrowser: openBrowser,
    proof: DpopProof.device(), // throws DpopUnavailable on the web unless a fallback is given
  ),
  apiOrigins: [Uri.parse('https://api.example.com')],
);
```

Install it next to `fespalier` and `fespalier_auth`, with the same `url` and `ref` for the three (its README has the
block). It needs Dart 3.12 and Flutter 3.44, Android minSdk 24, iOS 15 and macOS 10.15, and it depends on
flutter-sign-keypair **by git, pinned to a commit** (the repository is not on pub.dev), so `flutter pub get` clones
`github.com/vaam-apps/flutter-sign-keypair`.

- **What is sent.** A proof is `{typ: dpop+jwt, alg: ES256, jwk}` and `{jti, htm, htu, iat, ath?, nonce?}`, ES256
  signed: `jti` is new for every send (retries included), `htu` has no query or fragment, `ath` is only on requests
  that carry an access token, and the authorization request carries `dpop_jkt`, so the code is bound to the key too.
  One signature per request, made by the secure element; nothing is cached (a proof is single-use), and no timer or
  listener is started.
- **Nonces and the clock.** A `DPoP-Nonce` from any response is kept per origin, and a `use_dpop_nonce` challenge
  (an authorization server's `400`, a resource server's `401`) is answered once. When a server refuses a proof as not
  active and its `Date` header says the device clock is more than 5 seconds off, the difference is applied to every
  later `iat` and the request is sent once more. **Keycloak sends neither a nonce nor a `Date`**, so a wrong clock
  there is `invalid_request` / `DPoP proof is not active`: set the clock.
- **The key.** An *ambient* key (it never prompts), made on first use under the key id `fespalier_dpop`. Sign-out
  deletes it (`rotateKeyOnSignOut`), so the next sign-in makes a new one and an old refresh token, even a stolen one,
  is useless. `restoreAuth` signs the user out (`SignedOut(reason: SignOutReason.keyLost)`) when the key a stored
  session is bound to is gone: a restored backup, a wiped keychain.
- **Where there is no secure element** (the web, Windows, Linux, Fuchsia) `DpopFallback.refuse`, the default, throws
  `DpopUnavailable`: a library that promises tokens bound to a device must not quietly give you tokens bound to
  nothing. `DpopFallback.software` is a key in memory (its scalar is in the process; on the web it does not survive a
  reload, so the session is signed out, unless you pass a `softwareStore`), and `DpopFallback.bearer` is no DPoP
  (`device()` returns null; the client must not require DPoP-bound tokens). `requireHardware: true` makes a device
  without a secure element fail instead (the iOS simulator has only the keychain).
- **Keycloak** supports DPoP since 26.4. Switch on **Require DPoP bound tokens** on the client (the attribute
  `dpop.bound.access.tokens`; `examples/auth/keycloak/` has a realm with such a client,
  `fespalier-auth-example-dpop`). Read from Keycloak 26.8.0: errors are `invalid_request` with descriptions
  (`DPoP proof is missing`, `DPoP proof is not active`, `DPoP proof has already been used`), a refresh token bound to
  another key is `invalid_grant` / `DPoP confirmation doesn't match DPoP proof`, and a resource server's 401 is
  `WWW-Authenticate: DPoP ... error="invalid_token"` for every problem with the proof.
- **`RetryClient` goes over the session client**, never under it: it would send the same proof again, and the
  server refuses a reused `jti` (see Calling your API).
- **Tests.** `package:fespalier_sign_keypair/testing.dart` has `FakeDpopSigner` (a software key from a fixed scalar:
  the same key and signature on every run) and `verifyDpopProof`, which a fake server checks every proof with and
  which names the first check that failed. `examples/auth` runs a DPoP-checking demo server.

### Testing signed-in routes

`package:fespalier_auth/testing.dart` has `fakeAuth(...)`, the overrides for `pumpRouter`: signed in as the
`AuthUser` you give, or signed out, on a `FakeAuthBackend` and a `MemoryTokenStore`, with no `startup()` and no
network:

```dart
testWidgets('a member sees the orders', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/orders'),
    overrides: fakeAuth(signedInAs: const AuthUser(id: 'ada', roles: {'admin'})),
  );
  expect(currentLocation(tester), '/orders');
});
```

Call it inside the test body, where the fake clock starts. Pass `backend:` to read its counters
(`signIns`, `refreshes`, `signOuts`), to make it fail (`signInError`, `refreshError`) or to hold a call open
(`gate`, a `Completer<void>`: a pending state to look at), `tokenLifetime:` to age the session with
`tester.pump(const Duration(minutes: 6))`, `apiOrigins:` and `client:` (a `MockClient`) to test an API call.
Signed out, a guarded route lands on `/sign-in?from=%2Forders`. In [`fsp test`](#route-smoke-tests-fsp-test),
the setup file returns `fakeAuth(signedInAs: …)` from `overrides`, so guarded routes render:

```dart
// test/routes/setup.dart
List<Override> overrides(String pattern) => fakeAuth(signedInAs: const AuthUser(id: 'ada'));
```

`FakeProof` stands in for a proof of possession, and `RecordingTelemetry` sees the `auth` spans (`#2 start auth
refresh backend=fake trigger=expired`); [Telemetry conventions](#telemetry-conventions) lists their attributes.

## Telemetry

Since 0.8.1, fespalier reports what it does while it routes: each navigation, guard and
`redirect.dart` decision, `data.dart` load, action run and deferred-page load, with the pages that
entered, were focused or left. fespalier has no OpenTelemetry dependency: it tells a
`FespalierTelemetry` sink, and `package:fespalier_otel` is the sink that turns it into spans on the SDK
that [`otel_zone`](https://github.com/vaam-apps/flutter-otel-zone) starts. A test installs a
`RecordingTelemetry` instead.

### Turning it on

Telemetry is opt-in, in two steps. In `pubspec.yaml`:

```yaml
fespalier:
  telemetry: true
```

`fsp gen` then passes a `const TelemetrySite('products/$id/data.dart', route: '/products/:id')` to each
guard, `data.dart` provider and action, gives each deferred library its page's pattern, and has
`AppRoutes.attach` follow the router (`AppRoutes.router()` calls it; an app that mounts the tree in a
`GoRouter` of its own calls `AppRoutes.attach(router)` once with that router). A value that is not a bool
is an error. Without the key, the generated file is exactly what it was before 0.8.1.

At run time nothing is reported until the app installs a sink, before `runApp` and before the router is
built, so the first navigation is reported too:

```dart
FespalierTelemetry.install(sink); // null uninstalls
```

A sink is called synchronously from the router, a provider or an action: it must return at once, must not
throw (fespalier catches what it throws and prints `fespalier telemetry: <error> (not shown again)`
once), and must not navigate or read a provider.

### OpenTelemetry with otel_zone

`otel_zone` is not on pub.dev: depend on it by git, pinned to a commit. Add `fespalier_otel` next to
fespalier, with the same `url` and the same `ref` (pub resolves the two to one package only if they are the
same repository dependency; a mismatch fails with `Because every version of fespalier_otel from path
depends on fespalier from git https://github.com/fespalier/fespalier at v0.7.0 in packages/fespalier and
demo depends on fespalier from git https://github.com/fespalier/fespalier at v0.6.0 in packages/fespalier,
fespalier_otel from path is forbidden.`, the form it takes when the second is a path):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
  fespalier_otel:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_otel
      ref: v0.8.1
```

<!-- x-release-please-end -->

```yaml
  otel_zone:
    git:
      url: https://github.com/vaam-apps/flutter-otel-zone
      ref: a9648533f6f8f0a6bfb341b368e8be0747b7dc21 # a commit, not a tag
```

`otel_zone` depends on `otel_go_router`, which declares `go_router: ^17.0.0`, so an app with it resolves
go_router 17 (fespalier accepts 17 and 18). An app that needs 18 adds `dependency_overrides: go_router:
^18.0.0`, as `otel_zone`'s README says. `examples/telemetry` is the one example on go_router 17.

The wiring, in `main.dart` (`examples/telemetry` is this):

```dart
final observability = OtelZone(
  OtelZoneConfig(serviceName: 'shop', endpoint: FespalierOtel.endpoint()),
);

Future<void> main() => guarded(() async {
  WidgetsFlutterBinding.ensureInitialized();
  await observability.start(
    serviceVersion: '1.4.0',
    resourceAttributes: {...FespalierOtel.resourceAttributes},
  );
  FespalierTelemetry.install(FespalierOtel(isReady: () => observability.isReady));
  runApp(ProviderScope(
    observers: [?observability.riverpodObserver()],
    child: MaterialApp.router(
      routerConfig: AppRoutes.router(observers: [?observability.routeObserver()]),
    ),
  ));
});

Future<void> guarded(Future<void> Function() body) =>
    kIsWeb ? body() : observability.runGuarded(body);
```

`otel_zone` owns the zone that `WidgetsFlutterBinding.ensureInitialized()` and `runApp` run in, so both
go inside `runGuarded`. `FespalierOtel(isReady:)` emits nothing until the SDK is up, and an app that
starts the SDK itself leaves it out; `recordLocations: true` adds the committed location and a guard's
redirect target to the spans (segment and query values are app data, so it is off).
`FespalierOtel.endpoint()` is the `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` value when there is
one; without it a debug build exports to `http://10.0.2.2:4318` on Android (the emulator's address for its
host) and `http://localhost:4318` elsewhere, and a release build gets `''`, which `otel_zone` takes as
"telemetry off", so a store build never sends to a developer's computer. A failure while the app
starts arrives through `FlutterError.reportError`.

Since 0.8.1, known limitation: otel_zone `runGuarded` on web. On the web `OtelZone.runGuarded` never runs
its body, so the app stays blank: it builds a `ReceivePort` first, which `dart:isolate` does not support
there. `start()` itself works on the web. Until `otel_zone` guards that call, run the body as it is on the
web, as `guarded` above does; the error hooks `runGuarded` installs are then not installed there.

### Telemetry conventions

This section is **contract version 1**: dashboards and alerts are built on it. Within version 1 a change
may only add (a new attribute, a new event, a new value of an enum-like attribute, announced in the
changelog); renaming or removing a name or a value, or changing the meaning or unit of an attribute, is
version 2, which bumps `fespalier.telemetry.version` and is a breaking release.
`packages/fespalier_otel/test/conventions_test.dart` holds every name below as a string literal, so a
rename fails a test before it ships. The names follow OpenTelemetry's semantic conventions where they
exist (`service.*`, `url.*`, `error.type`, `exception.*`, span status) and use the `fespalier.` prefix
for the rest.

**Resource attributes**, fixed when the SDK starts:

| Key                           | Value                                            | Set by                                     |
| ----------------------------- | ------------------------------------------------ | ------------------------------------------ |
| `service.name`                | the app's name                                   | `OtelZoneConfig.serviceName`               |
| `service.version`             | the app's version                                | `otel_zone` `start(serviceVersion:)`       |
| `app.build_id`                | the build number                                 | `otel_zone` `start(buildId:)`              |
| `deployment.environment.name` | e.g. `production`                                | `OtelZoneConfig.deploymentEnvironmentName` |
| `fespalier.version`           | the fespalier release, e.g. `0.8.1`              | `FespalierOtel.resourceAttributes`         |
| `fespalier.telemetry.version` | `1` (a string): the version of these conventions | `FespalierOtel.resourceAttributes`         |

**Scope.** Every span is made by the instrumentation scope `fespalier`, whose version is the fespalier
release. To pick fespalier's spans out of a service's, filter on `fespalier.operation` (a backend that
does not keep the scope on spans, like OpenObserve, has no scope column to filter on).

**Spans.** Every span is `SpanKind.internal` and carries `fespalier.operation`. A span's duration is its
own (end minus start), so no attribute repeats it; for `navigate` it is _requested to first frame_:
redirects, async guards, the build of the new page and its first-frame loads.

| `fespalier.operation` | Span name                                                              | Starts                                                                                                                                      | Ends                                                                                                              | Parent                                           |
| --------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `navigate`            | `navigate {route}`; `navigate (not found)`; `navigate` when superseded | a location is requested (`go`, `push`, `replace`, a tab switch, a deep link), a pop or a guard's refresh commits, or the router is attached | the end of the first frame rendered after the commit, or when a newer navigation starts before this one committed | none (a root span)                               |
| `guard`               | `guard {file}`, e.g. `guard (members)/guard.dart`                      | the guard returned                                                                                                                          | the answer is known (sync: at once; async: when its `Future` settles)                                             | the pending `navigate`, else the current context |
| `redirect`            | `redirect {file}`                                                      | as `guard`                                                                                                                                  | as `guard`                                                                                                        | as `guard`                                       |
| `data`                | `data {file}`, e.g. `data products/$id/data.dart`                      | the provider of a `data.dart` runs `data()`                                                                                                 | the value is there, its `Future` settles, or the provider is disposed first; a `Stream` ends at once              | the pending `navigate`, else the current context |
| `action`              | `action {file}#{name}`                                                 | `ActionNotifier.call`                                                                                                                       | the result is there, or its `Future` settles                                                                      | the current context (usually none)               |
| `deferred`            | `deferred {file}`                                                      | `DeferredLibrary.load()` starts a load (not one that joins a load in flight)                                                                | the load completes or fails                                                                                       | the pending `navigate`, else the current context |
| `auth`                | `auth {operation}`, e.g. `auth refresh` (since 0.9.0)                  | `restoreAuth`, `signIn` or `adopt`, a refresh, `signOut` (`fespalier_auth`)                                                                 | the outcome is known                                                                                              | the current context (usually none)               |

A span's status is `Error` (with the exception's text) exactly when its outcome attribute is `error`; a
`not_found` navigation is not an error, and neither is an `auth` span that ends `rejected` or `cancelled`.
An `auth` span that ends `error` has the status and `error.type`, but never the exception's text, which
can name a host.

**Events.** On one `navigate` span the order is every `leave`, most recently entered first, then one
`enter` or `focus`. The page events fire whether or not the app has an `observe.dart`.

| Event                  | On                                                                              | When                                                       | Attributes                                                    |
| ---------------------- | ------------------------------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------- |
| `fespalier.page.enter` | the `navigate` span that caused it                                              | a page instance became the visible page for the first time | `fespalier.route`                                             |
| `fespalier.page.focus` | the same                                                                        | an entered page is the visible page again                  | `fespalier.route`                                             |
| `fespalier.page.leave` | the same                                                                        | an entered page is gone                                    | `fespalier.route`, `fespalier.page.duration_ms`               |
| `exception` (semconv)  | a `guard`, `redirect`, `data`, `action` or `deferred` span with outcome `error` | the operation threw or its `Future` failed                 | `exception.type`, `exception.message`, `exception.stacktrace` |

**Attributes on every span:**

| Key                   | Type   | Values and meaning                                                                                                                                                                                      |
| --------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.operation` | string | `navigate`, `guard`, `redirect`, `data`, `action`, `deferred` or `auth`                                                                                                                                 |
| `fespalier.route`     | string | the route pattern, as `fsp routes` prints it and `AppManifest.byPath` keys it: `/`, `/products/:id`, `/docs/*rest`. Absent when not found. For a section's data or action, the section folder's pattern |
| `fespalier.file`      | string | the app file, relative to the app folder, as spelled on disk: `products/$id/data.dart`. Absent on `navigate`                                                                                            |
| `fespalier.async`     | bool   | whether the operation returned a `Future` (`guard`, `redirect`, `data`, `action`, `auth`)                                                                                                               |
| `error.type`          | string | semconv: on an error, the exception's class (minified on a release web build)                                                                                                                           |

**On a `navigate` span:**

| Key (`navigate`)                  | Type   | Values and meaning                                                                                                 |
| --------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------ |
| `fespalier.navigation.kind`       | string | `initial`, `go`, `push`, `pop`, `replace` or `refresh` (the classification DevTools shows); absent when superseded |
| `fespalier.navigation.outcome`    | string | `ok`, `not_found` or `superseded`                                                                                  |
| `fespalier.navigation.from`       | string | the pattern of the page that was on top before (absent at the start)                                               |
| `fespalier.navigation.redirected` | bool   | the committed path differs from the requested one: a guard or a `redirect.dart` sent it elsewhere                  |
| `fespalier.navigation.depth`      | int    | how many pushed pages the stack holds after the commit (0 for a plain `go`)                                        |
| `url.path`, `url.query`           | string | semconv: the committed location, mount prefix included. Only with `recordLocations: true`                          |

**On the other spans and events:**

| Key                                                      | Type   | Values and meaning                                                                                                                                                   |
| -------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.guard.decision` (`guard`, `redirect`)         | string | `pass`, `redirect`, `error` or `skipped` (a segment it asks for did not parse, so it did not run); a `redirect` span is `redirect` or `error`                        |
| `fespalier.guard.location`                               | string | where it redirected to. Only with `recordLocations: true`                                                                                                            |
| `fespalier.data.state` (`data`)                          | string | `data`, `error`, `stream` (a `Stream` was returned: not listened to, so the span ends at once) or `disposed` (the provider was disposed before its `Future` settled) |
| `fespalier.data.keyed`                                   | bool   | the provider is a family; the key itself is never recorded                                                                                                           |
| `fespalier.action.name` (`action`)                       | string | the function's name in `action.dart`                                                                                                                                 |
| `fespalier.action.result`                                | string | `ok` or `error`                                                                                                                                                      |
| `fespalier.deferred.result` (`deferred`)                 | string | `ok` or `error`                                                                                                                                                      |
| `fespalier.page.duration_ms` (on `fespalier.page.leave`) | int    | milliseconds from that instance's enter to its leave, covered time included                                                                                          |

**On an `auth` span** (since 0.9.0; `fespalier_auth`; no new contract version, as a new operation and its
attributes only add):

| Key                        | Type   | Values and meaning                                                                                                                                                                                                                                                                                   |
| -------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier.auth.operation` | string | `restore` (the stored session was read at start-up), `sign_in` (also a session the app adopted), `refresh` or `sign_out`                                                                                                                                                                             |
| `fespalier.auth.result`    | string | `ok`; `none` (restore: nothing was stored); `expired` (restore: the stored refresh token had expired, or the device key is gone); `rejected` (the server refused: wrong credentials, or a refresh token it no longer accepts); `cancelled` (the user closed the sign-in); `error` (it could not run) |
| `fespalier.auth.backend`   | string | the backend's short constant name: `oidc`, `firebase`, `fake`, or an app's own                                                                                                                                                                                                                       |
| `fespalier.auth.trigger`   | string | refresh only: `expired` (before a request), `unauthorized` (after a 401) or `forced`                                                                                                                                                                                                                 |
| `fespalier.auth.dpop`      | bool   | the backend binds its tokens with DPoP                                                                                                                                                                                                                                                               |

**Metrics.** fespalier emits none: `otel_zone` turns metrics off on purpose (a periodic reader is a timer
that keeps the radio busy), and rates and latencies are on the wire as spans already. Derive metrics in the
collector with the `spanmetrics` connector, with `fespalier.operation`, `fespalier.route`,
`fespalier.navigation.kind`, `fespalier.navigation.outcome`, `fespalier.guard.decision`,
`fespalier.data.state`, `fespalier.action.name`, `fespalier.action.result`, `fespalier.deferred.result`
and `fespalier.file` as dimensions, next to the resource's `service.name`, `service.version` and
`fespalier.version`. A data attempt, a data source, an action rolled back and an action rejected by
validation are not recorded in 0.8.1. The `fespalier.auth.*` attributes are not dimensions of the
collector `fsp telemetry` starts yet (since 0.9.0): its dashboards label an `auth` span as a
session operation, and nothing more.

**Never recorded.** Segment and query values (unless `recordLocations: true`), family keys, `extra`, action
inputs and results, data values and guard inputs; and, from `fespalier_auth`, tokens, user ids, claims, user
names, e-mails, issuer and endpoint URLs, DPoP proofs and key thumbprints. What is recorded is a route pattern, a file path, a
function name or an enum-like value, all fixed when the app is built, and exception text, which
`otel_zone` scrubs (`redact`) as it scrubs every span string.

### Testing telemetry

`package:fespalier/testing.dart` has `RecordingTelemetry`, a sink that keeps what it is told as lines to
compare. Install it in `setUp` and uninstall it in `tearDown`:

```dart
setUp(() {
  recording = RecordingTelemetry();
  FespalierTelemetry.install(recording);
});
tearDown(() => FespalierTelemetry.install(null));

testWidgets('opens an order', (tester) async {
  final router = AppRoutes.router();
  await pumpRouter(tester, router);
  recording.log.clear();
  router.go('/orders/1');
  await tester.pumpAndSettle();
  expect(recording.log, contains('#3 end data data async'));
});
```

Each operation is `#n`, which ties its `start` line to its `end` line and names the navigation it ran
under (`parent=#2`). To see real spans, initialise the SDK in `setUpAll` with `SimpleSpanProcessor` and
`InMemorySpanExporter` from `package:dartastic_opentelemetry/testing.dart`, install `FespalierOtel()`, and
read the exporter after a `pump()`: a span is exported when it ends. `OTel.initialize` runs once per
isolate, so once per test file. `examples/telemetry/test/` does both.

### What it costs

**Off, nothing.** An app without `telemetry: true` and without an `observe.dart` generates the same file
as before, and its release build carries none of it: no call site passes a site, so the telemetry
parameter of each wrapper is null and the code behind it is not compiled in (CI greps a release web build
for the line `fespalier telemetry`, which only that code prints). **Sync stays sync.** fespalier never
creates a `Future`, a microtask or a timer for telemetry: a sync guard, `data()` or action is reported with
its start and its end in the same call stack, an async one through a side listener on the very `Future`
(which handles its own error, so it cannot make an unhandled one), and the wrappers return the very object
they were given. What does schedule microtasks is the OpenTelemetry SDK itself, whose span processors are
`async` methods: they run when a span starts or ends, never in the path of a value the app gets. A
backgrounded app draws no frames, so a navigation made in the background ends its span at the next frame
after the app resumes.

### Dashboards on your computer: `fsp telemetry`

Since 0.8.1. fespalier's telemetry (spans for navigations, guards, `data.dart` loads, actions and deferred loads) is only useful when someone looks at it. `fsp telemetry` starts a stack on your computer that receives it and shows four ready-made dashboards, written as the questions an app developer asks ("Do screens open quickly?", "How often do actions fail?") rather than as metrics: an OpenTelemetry collector, [OpenObserve](https://openobserve.ai), and, with `--grafana`, [Grafana](https://grafana.com) with the same dashboards. It needs [Docker](https://docs.docker.com/get-docker/) with Compose 2.20 or later, and runs in any folder, with or without a project: the stack belongs to you, not to one app.

![fespalier's App health dashboard in OpenObserve: eight tiles answer whether screens open and load quickly and whether loads, actions or the app fail, coloured green, amber or red, above a table of verdicts in words.](docs/images/telemetry/openobserve-app-health.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

```sh
fsp telemetry            # the first run pulls about 1.2 GB of images; later runs take a few seconds
flutter run              # any device: an emulator, a simulator, desktop, Chrome
```

```text
✓ telemetry stack running: 4 dashboards in OpenObserve, folder fespalier; start with fespalier · App health
  OpenObserve  http://localhost:5080  dev@fespalier.local / Fespalier-local-1
  OTLP         http://localhost:4318 (HTTP), localhost:4317 (gRPC)
  The app      FespalierOtel.endpoint() reaches it from an emulator, a simulator, desktop and the web
```

Printing the password is deliberate: the stack is local, the password is the documented default, and the web UIs listen on `127.0.0.1` only.

#### The app side

The only telemetry-specific value in the app is where it sends to. `FespalierOtel.endpoint()` (in `package:fespalier_otel`) is that value for a development build:

```dart
final observability = OtelZone(
  OtelZoneConfig(serviceName: 'shop', endpoint: FespalierOtel.endpoint()),
);
```

It returns, in this order:

1. what `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` (or `--dart-define-from-file`) says, when it says anything;
2. `''` in a release build, so `otel_zone` leaves telemetry off and a store build never sends to a developer's laptop;
3. `http://10.0.2.2:4318` on Android (not the web), the emulator's name for its host;
4. `http://localhost:4318` everywhere else: the iOS simulator, desktop and the web.

| Where the app runs      | What reaches the stack                                                                                               |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Android emulator        | Nothing to do: `10.0.2.2`.                                                                                           |
| iOS simulator           | Nothing to do: `localhost`.                                                                                          |
| Desktop                 | Nothing to do: `localhost`.                                                                                          |
| Chrome                  | Nothing to do: `localhost`, with CORS ([The web](#the-web-and-otel_zone)).                                           |
| A phone on your Wi-Fi   | `fsp telemetry --lan`, then `flutter run --dart-define-from-file=~/.fespalier/telemetry/dart-defines.json`.          |
| An Android phone on USB | `adb reverse tcp:4318 tcp:4318`, then `flutter run --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318`. |

The port in `endpoint()` is 4318. If you changed `FSP_OTLP_HTTP_PORT`, pass the define.

#### The dashboards

Each has an **App** variable (the resource's `service.name`, so apps are told apart in one stack; it starts on the first app) and shows the last hour. They are in OpenObserve's folder `fespalier`, and in Grafana's, where **App health** is the home page. Every title is a question, every panel has an ⓘ (Grafana: (i)) that says what it shows, what good looks like and which file to open when it is not, and every tile is green, amber or red ([Reading the colours](#reading-the-colours)).

| Dashboard                | Answers                                                                                                                                                                                                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fespalier · App health` | Start here. Eight tiles: Do screens open quickly? Does content load quickly? Do actions finish quickly? How many screens were viewed? How often does content fail to load? How often do actions fail? Did anything throw an uncaught error? Did the app crash or freeze? Then the same checks in words, the slowest screens, and what fails most. |
| `fespalier · Screens`    | Where people go and how fast each screen opens: its checks (`guard.dart` and `redirect.dart`), its content (`data.dart`) and its code (deferred pages), which screens are busiest, where people go next, and how often a link leads nowhere.                                                                                                      |
| `fespalier · Actions`    | What people do (each function in an `action.dart`): how many runs, how often they fail, how long they take, and when.                                                                                                                                                                                                                             |
| `fespalier · Errors`     | What broke, where and with which error: failed checks, loads, actions and code downloads, uncaught errors, and native crashes and ANRs.                                                                                                                                                                                                           |

![The Screens dashboard in OpenObserve: each route with its typical and slowest open and content-load times, the slowest cells coloured, and open time over time with the good and bad lines.](docs/images/telemetry/openobserve-screens.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

![The Errors dashboard in OpenObserve: counts of failed operations, uncaught errors and crashes, and a table of what failed by kind, screen, file and error type.](docs/images/telemetry/openobserve-errors.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

![The Actions dashboard in OpenObserve: how many actions ran, how often they failed, how long they took, and a table with each action's runs, failure rate and times.](docs/images/telemetry/openobserve-actions.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

Click a row of a table in OpenObserve, or a tile in Grafana, to open the dashboard that explains it (the App and the time range come along). Every query uses only the names of the [telemetry conventions](#telemetry-conventions), which `scripts/telemetry/build_dashboards.py` reads from `packages/fespalier_otel/lib/src/conventions.dart`, and a test (`scripts/test_telemetry.py`) fails when a query names anything else. Nothing is charted that fespalier does not emit.

#### Reading the colours

Since 0.8.1. A tile is **green** when the answer is good, **amber** when it needs attention and **red** when it is bad. "Slowest 5 %" is the time that 19 of 20 are faster than, so one slow outlier does not turn a tile red. The same limits colour the cells of the tables and draw the dashed lines in _Are screens getting slower?_. They are defaults for a mobile app, with a reason each:

| Measure                                               | Good      | Needs attention | Bad       | Why                                                                                                                                                                                                                  |
| ----------------------------------------------------- | --------- | --------------- | --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Opening a screen (`screen_open`)                      | < 300 ms  | 300–999 ms      | ≥ 1000 ms | The span ends at the first frame, so it is the wait before anything moves. 300 ms is Material's screen-transition duration and the edge of "instant"; 1 s is Nielsen's limit for keeping the user's flow of thought. |
| Loading a screen's content (`content_load`)           | < 1000 ms | 1000–2999 ms    | ≥ 3000 ms | The screen already shows loading.dart, so the user is waiting knowingly. 1 s keeps the flow; at 3 s more than half of mobile visitors give up.                                                                       |
| Finishing an action (`action_time`)                   | < 1000 ms | 1000–2999 ms    | ≥ 3000 ms | The same reasoning for a tap that saves: past 1 s it needs a spinner, and past 3 s people tap again.                                                                                                                 |
| A check before a screen (`guard_wait`)                | < 100 ms  | 100–299 ms      | ≥ 300 ms  | A check runs before the screen appears and adds to every open. 100 ms is "instant", and 300 ms would by itself spend the whole budget for opening a screen.                                                          |
| A deferred page's code (`code_download`)              | < 500 ms  | 500–1999 ms     | ≥ 2000 ms | Downloading a deferred page's code on the web: it should fit in a screen transition, and more than 2 s is a visible stall.                                                                                           |
| A load or action that fails (`failure_rate`)          | < 1 %     | 1–4.9 %         | ≥ 5 %     | A 99 % success rate is the usual floor for user-facing calls, and Android's bad-behaviour line for crashes is about 1 %. At 5 %, one attempt in 20 fails.                                                            |
| A link that leads nowhere (`not_found_rate`)          | < 1 %     | 1–4.9 %         | ≥ 5 %     | Typed routes cannot miss, so not-found comes from hand-built links, old deep links and typing on the web. A few are normal; 5 % is a broken link.                                                                    |
| Uncaught errors and failed operations (`error_count`) | 0         | 1–9             | ≥ 10      | While you develop, every uncaught error is worth a look, but a single one should not turn the page red.                                                                                                              |
| Native crashes and freezes (`crash_count`)            | 0         | —               | ≥ 1       | A native crash or an "app not responding" freeze is always bad.                                                                                                                                                      |

**A tile that rests on fewer than 20 samples is grey and says _Not enough data yet_** (and its row in _Verdicts, in words_ says _Too few to judge_): below 20, a "slowest 5 %" is just the biggest value and a percentage jumps 5 % per event. Use the app a little longer, or widen the time range. Colour is never the only signal: OpenObserve's _Verdicts, in words_ says each answer in words (Grafana cannot, because PromQL returns numbers), and each dashboard opens with a legend. To change a limit, edit the dashboard in OpenObserve (the importer then leaves it alone) or keep your own copy ([Your own copy](#your-own-copy)). The limits live in `[thresholds]` of `scripts/telemetry/dashboards.toml`, and a test fails when this table and that spec disagree.

#### The flags

| Command                     | What it does                                                                                                                                                                     |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fsp telemetry`             | Writes the stack's files, runs `docker compose up -d`, waits for the dashboard importer to finish, and prints the addresses.                                                     |
| `fsp telemetry --grafana`   | Also starts Grafana at `http://localhost:3000` (`admin` and the password in `.env`; anonymous visitors can view).                                                                |
| `fsp telemetry --lan`       | For phones: binds the OTLP ports (4317 and 4318) to every interface, for this run, and writes `dart-defines.json` with this computer's address. The web UIs stay on `127.0.0.1`. |
| `fsp telemetry --report`    | Prints how each app is doing, in plain words, and exits: the stack must be running ([A summary in the terminal](#a-summary-in-the-terminal---report)).                           |
| `fsp telemetry --stop`      | Stops the stack and keeps its data.                                                                                                                                              |
| `fsp telemetry --reset`     | Stops the stack and deletes its data (the OpenObserve and Grafana volumes). Use it after changing the OpenObserve password.                                                      |
| `fsp telemetry --dir <DIR>` | Uses `<DIR>` instead of `~/.fespalier/telemetry` (or `FSP_TELEMETRY_DIR`).                                                                                                       |
| `fsp telemetry --no-start`  | Writes the files and prints the command that starts them; does not run Docker.                                                                                                   |

Run from inside an app (or with `--project`), a start also checks that app: when its `fespalier:` section has `telemetry` off, which is the default, `fsp telemetry` prints ``⚠ this app sends no fespalier spans yet: set `telemetry: true` under `fespalier:` in pubspec.yaml and install FespalierOtel (README, "Telemetry")`` after the import and before the summary, and still exits 0. It says nothing outside a project, and not for `--no-start`, `--stop` or `--reset`.

The files go to one folder per user, `~/.fespalier/telemetry` (`%USERPROFILE%` on Windows), not into the app: `flutter clean` cannot delete them, and the Docker project name is fixed (`fespalier-telemetry`), so every app on your computer shares one stack. Running `fsp telemetry` again rewrites any file that differs (an upgrade of `fsp` upgrades the stack) and never touches `.env`.

**Settings** go in `.env` in that folder, written from `env.example` on the first run and never overwritten. Every value has the same default in `compose.yaml`, so the stack also runs with no `.env` at all, as `docker compose up -d` in that folder:

| Key                                        | Default                                                          |
| ------------------------------------------ | ---------------------------------------------------------------- |
| `FSP_O2_EMAIL`, `FSP_O2_PASSWORD`          | `dev@fespalier.local`, `Fespalier-local-1`                       |
| `FSP_GRAFANA_PASSWORD`                     | `Fespalier-local-1`                                              |
| `FSP_OTLP_HTTP_PORT`, `FSP_OTLP_GRPC_PORT` | `4318`, `4317`                                                   |
| `FSP_O2_PORT`, `FSP_GRAFANA_PORT`          | `5080`, `3000`                                                   |
| `FSP_OTLP_BIND`                            | `127.0.0.1` (`--lan` sets `0.0.0.0` for one run)                 |
| `FSP_OTLP_CORS_ORIGIN`                     | `http://localhost`: one more browser origin allowed to send OTLP |
| `FSP_O2_WAIT`                              | `180`: seconds the dashboard importer waits for OpenObserve      |

OpenObserve refuses a weak root password and restarts forever: it needs 8 to 128 characters with a lowercase letter, an uppercase letter, a digit and a symbol. The root user is created on the first start only, so change the password in `.env` and then run `fsp telemetry --reset`. A port that is taken is `FSP_O2_PORT` and the like in `.env`.

#### A summary in the terminal: `--report`

Since 0.8.1. `fsp telemetry --report` answers "how is my app doing?" without opening a browser. It runs inside the stack (the host needs no Python), asks OpenObserve the very questions App health asks, and prints one block per app that sent fespalier spans in the last hour:

```text
fespalier · telemetry-example · last hour
  ✓ good               Do screens open quickly?                     240 ms
  ! needs attention    Does content load quickly?                   1.4 s
  ✓ good               Do actions finish quickly?                   310 ms
  ✓ good               Do checks slow screens down?                 60 ms
  … too few to judge   Does a deferred page's code arrive quickly?  4 samples
  ! needs attention    How often does content fail to load?         2.5 %
  ✗ bad                How often do actions fail?                   6.2 %
  ✓ good               How often does a link lead nowhere?          0.4 %
  ✓ good               Did anything throw an uncaught error?        none
  ✓ good               Did the app crash or freeze?                 none
  Slowest screen: /orders/:id, 1.2 s to open and 2.3 s for its content (slowest 5 %, 412 views)
  Fails most: Action (action.dart) orders/$id/action.dart on /orders/:id, 3 × StateError
  Details: http://localhost:5080, Dashboards, folder fespalier, fespalier · App health
```

The mark and the word are the colour, in words. The SQL is read from the generated App health dashboard, so the report and the dashboard cannot disagree, and the limits are [the same](#reading-the-colours). `none` stands for a count of zero, and with nothing failed the "Fails most" line is `Nothing failed.`. Three messages:

- ``fsp telemetry --report needs the stack running: start it with `fsp telemetry` `` when OpenObserve is not running.
- `no fespalier spans in the last hour: is the app running, with telemetry: true and FespalierOtel installed? (README, "Telemetry")` when no app sent a span (exit code 0).
- `fespalier: the report's query failed: HTTP <status>: <body>` when OpenObserve answered with an error (exit code 1), and `the report failed (exit <n>); the lines above say why` when the report stopped for another reason.

#### The web and `otel_zone`

A web app posts OTLP/HTTP to the collector from another origin (`http://localhost:<port>` to `http://localhost:4318`), which needs CORS: the collector allows `http://localhost:*` and `http://127.0.0.1:*`, plus `FSP_OTLP_CORS_ORIGIN`. A page served over `https` cannot post to `http://localhost` (mixed content); use `flutter run -d chrome` in development.

**`otel_zone`'s `runGuarded` does not run its body on the web** (checked with `otel_zone` v0.5.0): inside the zone, before the body, it opens a `ReceivePort` from `dart:isolate`, which the web does not have, and the zone's own handler swallows the error. The app stays blank and nothing is printed. `start()` itself works on the web. Until `otel_zone` guards that call, do not use the zone on the web:

```dart
Future<void> zone(Future<void> Function() body) =>
    kIsWeb ? body() : observability.runGuarded(body);
```

#### OpenObserve and Grafana show the same numbers

One spec, `scripts/telemetry/dashboards.toml`, generates both: `fsp` embeds the results, and CI fails when they are stale. OpenObserve's panels are SQL over the raw spans and logs; Grafana's are PromQL over metrics that the collector derives from the same spans (and Grafana reads them from OpenObserve, so there is no Prometheus, Tempo or Loki). **Counts are identical**, which the smoke test asserts. These differ:

- Grafana's percentiles are interpolated within histogram buckets (1, 2, 5, 10, 16, 33, 50, 100, 250, 500 ms, 1, 2.5, 5, 10 s); OpenObserve's are computed from the raw durations.
- Span metrics are stamped when the collector receives a span. A batch that a phone replays later counts at the time it arrives in Grafana, and at its own time in OpenObserve.
- Grafana has no error messages or trace ids: its _What failed last?_ is a count table with a link to OpenObserve, and _What was uncaught last?_ exists in OpenObserve only. _Verdicts, in words_ and _Where do people go next?_ exist in OpenObserve only too.
- The percentage tiles agree (the smoke test compares them within 0.05), and a tile that rests on fewer than 20 samples says _Not enough data yet_ in both.
- Grafana shows no words for the colours, because PromQL cannot return a sentence.

![The same App health tiles in Grafana, with the same colours and numbers.](docs/images/telemetry/grafana-app-health.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

![Grafana's Screens dashboard, opened from an App health tile.](docs/images/telemetry/grafana-screens.png)

_Sample data from `scripts/telemetry/seed.py --showcase`._

#### Your own copy

`fsp telemetry --no-start --dir ops/telemetry` writes the stack where you want it, for a team that wants to commit or change it. The folder `cli/templates/telemetry/` in the fespalier repository is the same stack and runs as it is (`docker compose up -d` in it). A dashboard that someone edited in OpenObserve is left alone when a new `fsp` brings a new version (the importer says so; delete the dashboard to get ours back), and Grafana's are read-only (provisioned): save a copy to change one. A dashboard that a newer `fsp` no longer ships is deleted from OpenObserve when nobody edited it, and Grafana drops its file; `fsp telemetry` deletes the stale files in its folder too. The collector file's `span_metrics` and `count` blocks are what to copy into a production collector.

Images are pinned by tag and digest (collector `0.161.0`, OpenObserve `v1.0.4`, Grafana `13.2.3`), for `amd64` and `arm64`.

## DevTools extension

Since 0.7.0, fespalier has an extension for [Flutter DevTools](https://docs.flutter.dev/tools/devtools): a
`fespalier` tab that shows, in a running app, what the router is doing and which file each route comes
from. It answers:

- **Which file serves this URL?** The _Location_ tab names the route and its `page.dart`. The _Routes_
  tab is the whole tree with the route the router is at highlighted, and its **Match** button says
  which route any location is, without going there.
- **Why is this page's parameter null?** The parameters are shown with their declared type and the
  value the app's own parser made of the URL, and the query and the `extra` beside them. A location no
  route has shows go_router's error.
- **What is on the stack?** The _Stack_ tab lists the pages, the layouts and tab layouts around them, and
  the pages that were pushed, each with its route and file.
- **How did I get here?** The history under _Location_ lists every location the router committed,
  newest first, with whether it was a `go`, a `push`, a `pop`, a `replace` or a refresh.
- **Can I try a URL?** The go-to bar above the tabs takes a location and a `go`, `push` or `replace`,
  and has a **Pop** button. It asks the app's router, so guards and redirects run as they do for a
  link.
- **Which guard redirected me?** The _Guards_ tab lists every guard and `redirect.dart` that answered,
  newest first: the location it was asked about, its file and route, and its result: `pass`, `redirect`
  (with where to), `pending` (an async guard that has not answered), `error`, or `skipped` (a segment
  did not parse, so the guard did not run and the page shows not-found). Chips filter by result. A
  redirect chain (`/admin` to `/login`) is one entry in the history, and the badge on it opens the
  decisions behind it.
- **Is this data loading or cached?** The _Data_ tab lists the provider of every `data.dart` that was
  built: its file and route, the key (the segments and query it is keyed by), its state (`loading`,
  `data`, `error`, `stream` or `disposed`), how often it was built, when, and what it holds. **Invalidate**
  builds one again. Since 0.8.1 a provider fespalier built also shows how many listeners it has, and
  **Holders** lists who keeps it: the page's view, a section's view, a `prefetch` / `preload` handle (and
  for how long), a `RouteLink` preload, and how many other listeners there are (`ref.watch` or `listen`
  in your code, or another provider). A `data.dart` that returns or selects the app's own provider is
  shown too, marked `app provider`, with the state the page saw (since 0.8.1).
- **What did that action do?** The _Actions_ tab lists the runs of the `action.dart` functions, newest
  first: the function, its key and input, `running`, `done` or `error`, how long it took and what it
  returned or threw.
- **Open in IDE.** A route's details under _Routes_ (and each guard, data and action file listed there)
  have a button that asks the IDE to open the file.

**How to see it.** Run the app in debug or profile mode and open DevTools: the `fespalier` tab is there
when the app is connected. DevTools asks once per project before it loads an extension (the Extensions
button), or you commit a `devtools_options.yaml` next to the `pubspec.yaml`:

```yaml
description: This file stores settings for Dart & Flutter DevTools.
documentation: https://docs.flutter.dev/tools/devtools/extensions#configure-extension-enablement-states
extensions:
  - fespalier: true
```

DevTools finds the extension in every package the app depends on, a git or a path dependency included.
`AppRoutes.router()` hands its router to the extension itself. An app that
[mounts](#getting-started) the routes into a `GoRouter` of its own attaches it once:

```dart
final router = GoRouter(routes: [...yourRoutes, ...AppRoutes.mount()]);
if (kFespalierDevTools) devToolsAttach(router);
```

**What it costs.** Nothing in a release build: `kFespalierDevTools` is a `const` that is false there, the
generated `app.g.dart` calls the extension's code only under `if (kFespalierDevTools)`, and
the compiler removes the service extensions, the route tree and the code that serves them. The calls
that follow the guards, the data and the views are wrappers that return what they are given
(`traceGuard(state, 'g5@6', guard(...))`, `traceData(ref, 'd37', id, data(...))`,
`watchData(ref, 'd37', provider)`); in a release build they are the identity (`watchData` is exactly
`ref.watch`) and the compiler inlines them away. CI builds an app with a guard, a `data.dart` and an
action for profile and for release and checks that the release build has none of it. What stays in a
release build is one short string per action (its site, an argument of the generated action provider).

In a debug or profile build it adds one listener to the router's delegate, an `onDispose`, an
`onAddListener` and an `onRemoveListener` callback per build of a `data.dart` provider (the last two count
its listeners; since 0.8.1), and lists of what happened that stop at 100 locations, 200 guard
decisions, 100 action runs, and the providers that are alive plus the last 50 disposed. The views, the
prefetch handles and the `RouteLink` preloads it lists as holders are held weakly. There is no
timer, no frame, no read of a provider, no listener on a provider, and nothing that answers unless
DevTools asks. (`ProviderContainer.exists`, which reads nothing, is asked of a container for an app's own
provider only when DevTools asks for a snapshot or for holders, and before the 101st live one is recorded.
`_devToolsProviders` in `app.g.dart` is a function that is called once, when DevTools first needs it.) **A guard or a data function that answers at once still does:** the wrapper returns the very
object it was given, so a synchronous guard stays synchronous, a `Future` is the `Future` go_router or
Riverpod awaits, and the only thing added to one is a side `then` that records how it ended and handles
its own errors. A `Stream` is not listened to. A bug in any of it is printed once and dropped; it never
changes what a navigation, a guard, a provider or an action does.
`--dart-define=fespalier.devtools=false` takes it out of a debug build too.

**Limits.**

- The tab loads Flutter's CanvasKit from `gstatic.com`, as a Flutter web app does by default, so it
  needs a network connection.
- It follows one router, the last one attached. Locations and the stack are the router's own, so a
  page that a `Navigator` of the app (not go_router) opened is not in them.
- A hot reload changes the route tree and says nothing about it: press the refresh button. A hot restart
  is a new app and reloads by itself.
- The route class a location is matched to is the class's `runtimeType` name. A profile build on the web
  minifies class names, so the tab finds the route by its path template instead, which a
  [localized path](#localized-paths) may not match.
- An app provider (a `data.dart` that returns or selects one) is seen through fespalier's views: its
  state is what the last page or section that watched it got, it has no build count, and its other
  listeners are not visible. A `.select(...)` can't be invalidated or checked for being alive. Until a
  page, a section or a preload watches it, its file is listed under _Not watched yet_ (since 0.8.1). The
  same goes for a guard or a data function that throws before it returns anything: go_router or Riverpod
  get the error as they always did, and the tab shows nothing for it.
- **Holders** are the ones fespalier creates (views, prefetches, `RouteLink` preloads); anything else is
  counted, for a provider fespalier built, as other listeners, and not named. Riverpod 3.4 does not
  export who listens to a provider (`ProviderElement` and its dependents are internal); its own DevTools
  tab reads them through internals. fespalier does not add a `ProviderObserver` either: it does not own
  your `ProviderScope`. A prefetch made before any page watched a selector's provider with parameters is
  attached when a page first does.
- A provider that returns a `Stream` shows the state `stream` and no value: nothing listens to it on the
  tab's behalf.
- **Open in IDE** posts a `navigate` event on the `ToolEvent` stream with a `package:` URI of the file, the
  way Riverpod's DevTools extension opens a file. Whether VS Code and IntelliJ open a `package:` URI
  from it is **unverified**; it needs the IDE's DevTools integration to be listening.

**For tool authors.** The extension and the app talk through `dart:developer`'s service extensions and
events, protocol 1. Every response and event has `"protocol": 1` and an `"event"` number on events (one counter
for all kinds: a number that skips means events were missed, and `snapshot` has the state). A change that only adds is not a
new protocol: a reader ignores keys it does not know, and `hello` lists what the app can answer in
`features`. A user value, like an `extra`, is never sent as it is but as `{"type", "text"}`, its runtime
type and its text cut to 200 characters. The records are in
[`packages/fespalier/lib/src/devtools/protocol.dart`](packages/fespalier/lib/src/devtools/protocol.dart),
which imports nothing.

| Service extension          | Parameters                                                               | Answers                                                                                   |
| -------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `ext.fespalier.hello`      | none                                                                     | the protocol, whether the app registered and attached a router, and its `features`        |
| `ext.fespalier.tree`       | none                                                                     | the route tree, as `fsp routes --graph json` prints it                                    |
| `ext.fespalier.snapshot`   | none                                                                     | the location, the stack, the history and the number of the last event                     |
| `ext.fespalier.match`      | `location`                                                               | the route a location is and its parsed parameters; it runs no guard and builds nothing    |
| `ext.fespalier.navigate`   | `mode` (`go`, `push`, `replace` or `pop`) and `location` (not for `pop`) | `{"ok": true}` once the router has been asked                                             |
| `ext.fespalier.clear`      | `what` (`history`, `guards`, `actions` or `all`)                         | `{"ok": true}`; what was named is emptied and the event counter goes on                   |
| `ext.fespalier.invalidate` | `id` (a data record's)                                                   | `{"ok": true}` when that provider was alive and was invalidated, `{"ok": false}` when not |
| `ext.fespalier.open`       | `file` (one of the tree's, relative to the app folder)                   | `{"ok": true}` once the IDE was asked, with a `package:` URI                              |
| `ext.fespalier.holders`    | `id` (a data record's)                                                   | who holds that provider now (since 0.8.1): `{found, alive, listeners, others, holders}`   |

| Event                  | Posted when                                                                          | Carries                                     |
| ---------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------- |
| `fespalier:registered` | the app registers, or a router is attached                                           | the number of the event                     |
| `fespalier:navigation` | the router commits a location                                                        | the number and the `record` of the entry    |
| `fespalier:guard`      | a guard or `redirect.dart` answers, and again (same `seq`) when an async one settles | the number and the `record` of the decision |
| `fespalier:data`       | a `data.dart` provider is built, settles, fails, is built again or is disposed       | the number and the `record` of the provider |
| `fespalier:action`     | an action starts and when it ends                                                    | the number and the `record` of the run      |

`hello`'s `features` lists what the app can answer: `navigation`, `match`, `navigate`, `guards`, `data`,
`actions`, `open`, `holders` and `watched` (the last two since 0.8.1). The `snapshot` has a `guards`, a `data` and an `actions` list, and a navigation record
names the `guards` behind it; a reader that finds one of the features missing finds those empty. A guard record is
`{seq, at, site, uri, fullPath, result, location, async, ms, error}`, a data record
`{id, site, key, container, state, builds, created, updated, value, error, via, provider, listeners}` and an action record
`{seq, site, key, input, state, started, ms, result, error}`; a `site` is a key of the tree's `sites`.
Since 0.8.1 a data record's `via` is `build` (fespalier built the provider) or `watch` (the app's own provider,
seen through a view; its `provider` is the provider's text and its `listeners` is null), and `holders` answers
`{found, alive, listeners, others, holders: [{kind, since, keepFor}]}`: `kind` is `view`, `section`, `prefetch`
or `link`, `keepFor` is milliseconds (null for until closed), `alive` is null when it can't be known, and
`others` is `listeners` minus the holders. `found` is false for an id that is not tracked.

An error is a JSON-RPC error with the code `-32602` for a missing or bad parameter and `-32000` otherwise,
and its detail says what was wrong. Events are posted only while a tool listens.

## Run the examples

Start with [`examples/minimal`](examples/minimal): `flutter create` + `fsp init` and three pages
(a class page, a function page and a `$id` page with a query parameter and a `data.dart`), with
a README that goes through each file and a few widget tests. Then:

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

Try `/products/13`: it fails once, so you see `error.dart` and **Retry**. Try `/products/abc`
(the int parse fails → `not_found.dart`), `/checkout` with an empty cart (the guard redirects
to `/cart`), and `/greet/you`.

`examples/features` covers the rest: an `(account)` group next to a catch-all `$slug`
page, per-route transitions (the group fades in, `/ticks` doesn't animate), data keyed
by two segments, query parameters (in a page, `data.dart` and a layout), a page and error
view bound by type, a layout and guard that take segments, a user-written
`AsyncNotifierProvider`, `Stream` data, and a `teams/$teamId` section whose `data.dart` feeds
its layout and pages, with a `not_found.dart` at two levels (which takes the team's id), a `reports` section keyed by a
query parameter, enum segments, query parameters and catch-alls (`shop/$category`, `browse/$$categories`), and
`AppRoutes.dataAt` / `match` and the prefetch handle in `test/data_at_test.dart`.

`examples/telemetry` (since 0.8.1) is the route lifecycle and OpenTelemetry: three tabs, an order page with a
`data.dart`, an `action.dart` and an `observe.dart`, a guarded and deferred settings page, `telemetry: true`,
and a `main.dart` that wires `otel_zone` (on go_router 17, which `otel_zone` requires). Its tests read the
hooks' log and the spans from an in-memory exporter.

`examples/features` also has `orders/$id/refund/confirm`, a route that is a sibling of the `refund`
page instead of a child of it (`nest = false`; `refund/receipt` next to it nests), with a guard on
`refund/` that still guards it and widget tests for the stack a deep link builds.

`examples/features` also has writes: `orders/$id/refund/action.dart` is a refund form (the page
is a `HookConsumerWidget` on `RefundRoute.useAction`: a pending state, the error of a declined
refund, and the quote beside it, `data.dart`, loads again after a success), and
`teams/$teamId/action.dart` adds a member to the section, whose data reloads for the layout and the
page. `test/action_test.dart` holds a refund pending on a `Completer`, so nothing waits for time.

Since 0.8.1 it also has a form and an optimistic update: `(account)/nickname/` is a `HookConsumerWidget` on
`NicknameRoute.useForm` (a `form()`, `validate()` and `optimistic()` beside its `action()`: errors per field,
a save button that disables itself, a title that shows the new nickname at once and ends on the server's
spelling, and fields that follow a reload unless the user changed them), and `teams/$teamId/action.dart` has an
`addMemberOptimistic()` that puts the member on the page before the section reloads. `test/forms_test.dart` and
`test/teams_test.dart` hold the save pending on a `Completer`.

`examples/features` also has localized paths: `help/` answers `/aide` and `/hilfe` too, with a dynamic
child, a nested child that is localized itself, and a `not_found.dart` that covers every spelling; `guide/`, with
spellings beyond ASCII (`/führer`, `/руководство`); and `shop/`, a page-less folder spelled `boutique` and
`laden` with an enum segment below it.

`examples/tabs` is a bottom navigation bar built as a tab layout: four tabs (one with nested
pages, and a Library tab that is a tab layout of its own, with two inner tabs), a
counter that survives switching tabs, `tabOptions`, a cross-fading `container`, a Search tab that also answers `/recherche` (`route.dart` with `paths`), a full-screen route
outside them (`/settings`), one that stays under `/profile` but renders on the root navigator
(`/profile/edit`, `navigator.dart`), and a Cupertino `transition.dart` that also moves the tab layout
itself aside when one of those opens over it.

`examples/features` also has a guard in a page-less `(members)` group (with a login page that
returns to where you were), a second guard below it that runs after the first, two
`redirect.dart` routes (`/old-shops/:shop`, `/old-search`), and `/photos`, with a dialog
route (`/photos/:id`), a bottom sheet (`/photos/sort`), a full-screen dialog
(`/photos/upload`) and an app-owned sheet with a URL (`/photos/share`, `present.dart`, with a page
on top of it at `/photos/share/terms`) opening over it. Some of its routes have a `meta.dart` (`PageMeta`), which
its root layout reads through the route manifest to set the page title, and its tests join a
review-code check on `AppRoutes.all`. It sets `scroll_restoration: true` (since 0.8.1): `/feed` has two
lists under `PageStorageKey`s, and its tests play the browser's back and forward.

Since 0.9.0 `examples/features` has `/labs`, a route behind a feature flag ([`fespalier_flags`](#feature-flags-fespalier_flags)):
`lib/app/labs/guard.dart` is one `flagGuard`, and the menu entry is hidden while the flag is off. It is off by default;
run with `--dart-define=FEATURES_LABS=true` to see it. `test/flags_test.dart` turns the flag on and off with a
`FakeFlags` while the menu is open and while the app is on `/labs`.

Since 0.9.0 it also keeps its team in shared preferences ([`fespalier_storage`](#a-cache-on-disk-fespalier_storage)):
`teams/$teamId/data.dart` has a `dataCache`, `startup.dart` opens a `PrefsDataStorage`, and `test/offline_test.dart`
restarts the app over the same store: the first frame of the second start is the saved team, not `loading.dart`, and a
start that cannot load it shows the saved one.

Since 0.9.0 the team also loads again when the device gets a network back
([`fespalier_connectivity`](#reconnects-fespalier_connectivity)): `teams/$teamId/route.dart` has
`refetchOnReconnect: true`, `startup.dart` overrides `reconnectSignal`, and `test/offline_test.dart` flaps a
`FakeConnectivity` (within the 30 seconds nothing loads, a Wi-Fi to mobile switch is not a reconnect, and a network that
flaps loads once).

`examples/tabs` also keeps its manifest in a library of its own (`output_manifest:
lib/app.routes.g.dart`, with `Review` metas that `lib/main.dart` never imports), and its tests
restore the selected tab, a background tab's stack and a page's state after a simulated
restart.

`examples/auth` (since 0.9.0) is [`fespalier_auth`](packages/fespalier_auth): a sign-in form on an action, a
`requireSignedIn` guard that comes back to where the user was going, a `requireRole` one for `/admin`, orders
pages whose two `data.dart` files call an API through `authHttpClient` (an expired token is refreshed once), and
a first frame that is the app, not a splash, because `startup()` restores the session with no network. The
API is an in-process server, so it runs and is tested with no network; run against Keycloak with
`--dart-define=OIDC_ISSUER=...` and the realm in `examples/auth/keycloak/`. With
`--dart-define=OIDC_ISSUER=demo --dart-define=DPOP=true` it signs in against the demo server's own provider with
device-bound tokens (DPoP), and its tests check every proof the way a server does.

## Development

```text
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
editors/vscode/      the VS Code extension (TypeScript): fsp diagnostics in the Problems panel
editors/intellij/    the IntelliJ / Android Studio plugin (Kotlin): fsp diagnostics in the editor
scripts/             packaging.py renders the Homebrew formula and Scoop manifest for a release;
                     pin_checksums.py writes the release's checksums into the Dart package
scripts/telemetry/   the dashboards' one spec (dashboards.toml) and build_dashboards.py, which writes
                     the OpenObserve and Grafana JSON; seed.py and smoke.py run the stack in Docker
cli/templates/telemetry/   the stack `fsp telemetry` writes (compose file, collector, importer,
                     dashboards); runs as it is with `docker compose up -d`
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation),
                     testing.dart, and bin/fespalier.dart, the `dart run fespalier` launcher for `fsp`
packages/fespalier_auth/   signed-in routes: session provider, guards, authenticated client, OpenID Connect
packages/fespalier_sign_keypair/   DPoP proofs for fespalier_auth, signed by a device key (Secure Enclave, AndroidKeyStore)
packages/fespalier_flags/   feature flags: FlagSource, flag() providers that guards watch, flagGuard (since 0.9.0)
packages/fespalier_storage/   dataCache storages on shared_preferences and Hive, with a size budget (since 0.9.0)
packages/fespalier_connectivity/   reconnectSignal from connectivity_plus, and hasNetwork for offline banners (since 0.9.0)
packages/fespalier_devtools/   the DevTools extension's source (a Flutter web app, tested on the VM)
packages/fespalier/extension/devtools/   what DevTools loads: config.yaml (its version is release-please's)
                     and build/, the extension's release build, committed
examples/minimal/    the smallest app: `flutter create` + `fsp init` + three pages, with widget tests
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, section data and nested not_found.dart, with widget tests
examples/tabs/       a tab layout (StatefulShellRoute), with widget tests
examples/auth/       fespalier_auth: sign-in, guards, refresh and Keycloak, with widget tests
skills/              agent skills: how to write lib/app/ and read fsp's errors (skills/README.md);
                     scripts/skills/ checks them against the code
```

```sh
just ci          # everything CI runs on the code, locally (needs Flutter, Node, just, cargo-deny)
just --list      # the individual steps: fmt, lint, test, deny, examples, flutter, devtools, packaging, telemetry, skills
just telemetry-dashboards   # regenerate the dashboards after editing scripts/telemetry/dashboards.toml
just telemetry-smoke        # run the telemetry stack in Docker and check every dashboard query (needs Docker)
just devtools-build   # rebuild the DevTools extension after touching its source (see below)
just web-routes  # the shop's Maestro flows open their routes in Chromium (needs Flutter and Node; not in `just ci`)
just dev-e2e     # fsp dev against the real flutter in headless Chrome (needs Flutter and Chrome; CI's scaffold job runs it)
```

[AGENTS.md](AGENTS.md) is the contributor and agent guide: the layout, the gate commands,
how to run each suite, and the conventions (Conventional Commit PR titles, squash merges,
SHA-pinned actions, regenerating the examples).

CI (`.github/workflows/ci.yml`) runs `just ci`'s steps: `cargo fmt --check`, clippy and the
tests, `cargo deny check`, `fsp check` on the examples, and `dart format`, `flutter analyze`
and `flutter test` on the package, the DevTools extension and every example. A `devtools` job builds the
extension again and fails when the committed build in `packages/fespalier/extension/devtools/build` is not
what its source builds to, then runs `devtools_extensions validate`
(`scripts/build-devtools-extension.sh --check`; after touching `packages/fespalier_devtools`,
`lib/src/devtools/protocol.dart` or the Flutter version in `ci.yml`, run `just devtools-build` and commit the
result). It also scaffolds every file kind
with `fsp new` and `fsp init`, checks the result with `flutter analyze` and `dart format`,
gives that app a guarded route with a `data.dart` and an `action.dart`, builds it for profile and for release
and checks that the release build holds none of the DevTools code (the `traceGuard`, `traceData` and `watchData`
wrappers included), runs `dart run fespalier` against a
freshly built `fsp`, compiles and tests the VS Code extension, tests the Homebrew and Scoop
rendering, checksum pinning and release staging (`python3 scripts/test_packaging.py`,
`python3 scripts/test_pin_checksums.py`, `python3 scripts/test_verify_staged.py`,
`python3 scripts/test_release_assets.py`),
checks the telemetry stack's files and dashboards (`python3 scripts/test_telemetry.py`: the generated dashboards are
fresh, every query uses only the telemetry conventions, `compose.yaml` pins its images, and the dashboard importer runs
against a fake OpenObserve; the `telemetry-smoke` job runs the whole stack in Docker, sends a seeded session and runs every
panel's query in OpenObserve and Grafana, `just telemetry-smoke`; after touching `scripts/telemetry/dashboards.toml` run
`just telemetry-dashboards`, and to bump an image pin edit the tag, resolve the digest with
`docker buildx imagetools inspect <image>:<tag>` and run `just telemetry-smoke`),
checks that the agent skills in `skills/` cover every README section, file kind, config key and
`fsp` command (`node scripts/skills/verify-coverage.mjs`; see [skills/README.md](skills/README.md)),
and checks that the version agrees everywhere it is spelled out
(`cli/tests/versions.rs`: `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`,
`packages/fespalier/extension/devtools/config.yaml`, `.release-please-manifest.json`, the `ref:` that `fsp init` prints, and the READMEs' and the
skills' `ref:`, `--tag` and `FSP_VERSION`; that each of them is annotated for release-please and listed in
`release-please-config.json`; that the release workflows' own version readers,
`scripts/read-version.sh`, still find each one; and that `release_checksums.dart` pins nothing
or a version no newer than the package's). You do not bump any of them: release-please does
(see [Releasing](#releasing)). After changing the emitter or a
template, regenerate with `cargo run -- gen --project ../examples/<name>`. A test fails if
a committed `app.g.dart` is stale.

Two more jobs build `examples/shop` for the web in a throwaway copy (`scripts/web-copy.sh`), outside
`just ci`: `web` checks that each deferred page is a chunk of its own (`just web-chunks`), and
`web-routes` replays the committed Maestro flows in a pinned Chromium, with every request that is
not to the local server blocked (`just web-routes`; `ci/web-routes/`). `maestro-web.yml` runs real
Maestro on the same build weekly; it is not a required check.

### Releasing

Maintainers only. Releases are cut with release-please, the convention of every repository in
the vaam-apps organization (its guide, `docs/releasing.md` in `vaam-apps/.github`, lists the
ways this has failed silently and is worth reading before changing anything here). Nobody
bumps a version by hand, edits `.release-please-manifest.json`, or runs a workflow to publish.

**The flow.**

1. **Land conventional commits.** The repository squash-merges and the pull request _title_
   becomes the commit subject, which is all release-please reads: `feat:`, `fix:`, `docs:`,
   `ci:` and the other conventional types (`pr-title` refuses anything else; a subject it cannot
   read is ignored, and no release PR appears). `feat` and `fix` decide the bump (before 1.0 a
   breaking change bumps the minor); every other visible type is a patch. To force a version,
   put a `Release-As: X.Y.Z` footer in a commit.
2. **The release PR.** Every push to `main` updates one standing pull request from the branch
   `release-please--branches--main`. It bumps the version in `cli/Cargo.toml`,
   `packages/fespalier/pubspec.yaml`, the `ref:` that `fsp init` prints, both READMEs'
   install snippets and `.release-please-manifest.json` (every spelled-out version carries a
   release-please annotation and is listed in `release-please-config.json`; the trailing comment
   is why every reader of those files must tolerate one, see `scripts/read-version.sh`), and it
   writes the root `CHANGELOG.md` above the hand-written history. The `release-please` workflow
   refreshes `cli/Cargo.lock` on the branch, because the build is `--locked`.
3. **Pins, on the PR.** The `Release pins` workflow builds `fsp` for the five targets on the PR
   branch, stages the archives, and commits their SHA-256s to the branch as
   `chore: pin fsp X.Y.Z checksums` (`packages/fespalier/lib/src/release_checksums.dart`,
   `scripts/pin_checksums.py`). release-please force-pushes the branch whenever `main` moves,
   which removes that commit; the workflow then runs again on the new head. It recognises its own
   commit and does not loop. The `fsp` build reads only `cli/`, never `release_checksums.dart`,
   so the pin commit does not change the binaries. Wait for the `Release pins gate` check before
   merging (make it required in the `main` ruleset; other pull requests pass it by skipping).
   The archives wait in a _staging_ draft release named `fsp-staging` (visible to maintainers,
   replaced by every build, deleted after the release), not in workflow artifacts, which expire.
4. **Merge the release PR.** release-please (as the org's GitHub App, so that the tag raises a
   workflow event) creates the tag `vX.Y.Z` at the merge commit and a _draft_ GitHub Release.
   The `Release` workflow, triggered by the tag, then
   - checks that the tag equals the Cargo, pubspec, manifest and lockfile versions;
   - fetches the staged archives and **refuses anything that is not the pinned build**
     (`scripts/verify-staged.sh`): they must be this version, built from the `cli/` tree that is
     tagged, and every archive's SHA-256 must equal the pin in the tagged tree. It never
     rebuilds: builds are not reproducible, so a rebuild could not match the pins;
   - regenerates the `.sha256` files and renders `fsp.rb` (Homebrew) and `fsp.json` (Scoop) from
     the verified archives (`scripts/packaging.py`), attaches all of it to the draft Release,
     publishes it (only now is it public and the latest release), and deletes the staging draft;
   - if the repository variable `HOMEBREW_TAP` is set (`owner/repo`), pushes `fsp.rb` to that Homebrew
     tap, and if `SCOOP_BUCKET` is set, pushes `fsp.json` to that Scoop bucket. Each is its own job
     and optional: unset, it is skipped and the release is complete, with `fsp.rb` and `fsp.json`
     still attached as assets.
     A git dependency on the new tag therefore carries the pins, and `dart run fespalier` refuses
     any download that does not match them (a checksum served next to the binary can be replaced
     together with it; one in the package cannot).

0.8.0 was tagged but never published (its binaries were built before the last change); the wave it
carried ships as 0.8.1.

Between releases, `main` still carries the last release's pins, and on an open release PR, before
its pin commit, the pubspec is ahead of them; the launcher then falls back to the release's
`.sha256` with a warning, as for any development build. `cli/tests/versions.rs` accepts pins for
the current or an older version, never a newer one.

**If something fails.** A failed `Release` run leaves the release a draft (nobody sees it, and
`latest` does not move): fix the cause and re-run the failed jobs. The usual causes are a
`cli/` change that reached `main` after the last build (the release PR was merged before its
head was rebuilt: make `Release pins gate` required and the branch up to date before merging),
or staged binaries that were replaced or deleted. If the merged commit cannot be made to match,
delete the draft and the tag and fix forward with the next release. A manual run of `Release`
(_Run workflow_) only builds the five targets and renders the Homebrew and Scoop files as a
smoke test; it publishes nothing.

**Repository settings** (not enforceable from a workflow): squash merging only, with the
squash commit title set to the pull request title and the message to the commit messages;
merge commits and rebase merges off. The release-please GitHub App must be installed on this
repository, and on the tap and the bucket if you set `HOMEBREW_TAP` or `SCOOP_BUCKET`.

**The Homebrew tap and the Scoop bucket are optional.** A release publishes without them, with
`fsp.rb` and `fsp.json` attached as assets. Each is its own job in the `Release` workflow, gated
on a repository variable holding `owner/repo`, so either alone works:

- `HOMEBREW_TAP` = `fespalier/homebrew-tap`. The job writes `Formula/fsp.rb`. The `homebrew-`
  prefix is what lets `brew tap fespalier/tap` and `brew install fespalier/tap/fsp` find it.
- `SCOOP_BUCKET` = `fespalier/scoop-bucket`. The job writes `bucket/fsp.json`. The manifest's
  `checkver` and `autoupdate` let Scoop's own tooling keep the bucket current too.

To set them up, once: create the two repositories, install the release-please App on them with
`contents: write`, and set the variables under _Settings_, _Secrets and variables_, _Actions_,
_Variables_ here. The repositories may be brand new with only a README: the job checks out the
repository's **default branch** (`main` for a new repository; it never assumes `master`: it
pushes back to whichever branch the checkout is on), creates `Formula/` or `bucket/` when it is
missing, and commits `fsp X.Y.Z`. A repository with no commit at all cannot be checked out, so
give it that README first. If the variable is set but the App is not installed on the
repository, the job fails at the token step after the release is already published; install
the App and re-run that job. A release that went out before the variables were set can be copied
by hand from its `fsp.rb` and `fsp.json` assets. Unset, the job is skipped.

**By hand, per release** (the editor plugins are versioned on their own and not part of the
release PR):

- **JetBrains Marketplace (IntelliJ plugin).** Build the plugin from the tag with
  `cd editors/intellij && ./gradlew buildPlugin` (JDK 21) and upload
  `build/distributions/fespalier-intellij-<version>.zip` on the plugin's page in the
  JetBrains Marketplace, or run `PUBLISH_TOKEN=<token> ./gradlew publishPlugin`. Bump
  `version` in `editors/intellij/build.gradle.kts` first. The first upload needs a vendor
  account and a manual review; later ones can use a permanent token from the Marketplace's
  _My Tokens_ page.
- **VS Code extension.** Not published to a marketplace: build the `.vsix` from source (see
  `editors/vscode/README.md`). Bump `version` in `editors/vscode/package.json` first if you
  distribute a build.

### Testing

`package:fespalier/testing.dart` has two helpers for widget tests (and `RecordingTelemetry`, see [Testing
telemetry](#testing-telemetry)). `observe.dart` hooks run after the frame, so `await tester.pump()` before
looking at what they did. Boot the app at a
location with `pumpRouter`, and read where it is with `currentLocation` (it follows `go`, `pop` and
`push`: after a push it is the pushed location, the top of the stack):

```dart
import 'package:fespalier/testing.dart';

testWidgets('shows a product', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/products/2'),
    overrides: [apiProvider.overrideWithValue(FakeApi())],
  );
  expect(find.byType(ProductPage), findsOneWidget);

  // navigate with the typed routes, from any widget under the router
  ProductsRoute().go(tester.element(find.byType(ProductPage)));
  await tester.pumpAndSettle();
  expect(currentLocation(tester), '/products');
});
```

`pumpRouter(tester, router, {overrides, container, settle, retry, disposeRouter, app})` wraps the router in a
`ProviderScope` and Flutter's `MaterialApp.router` (or the widget `app` builds, see below), and returns the `ProviderContainer`
(for `container.read(...)`). `settle` (on by default) pumps until nothing is scheduled: turn
it off to look at a loading view, then `pump` the time you want. Pass your own `container`
instead of `overrides` to share one with code outside the widget tree; it's yours to
dispose. `retry` is the container's Riverpod retry policy, and it defaults to **no retries**,
unlike a real app, whose generated providers keep Riverpod's automatic retry unless
`data_retry: none` says otherwise: a failing `data.dart` shows its `error.dart` at once and
leaves no timer behind. To test what the app's policy does, pass
`retry: ProviderContainer.defaultRetry` (or your own function). A policy that keeps retrying
leaves a timer pending when the test ends, so dispose the returned container first. Make a new
router per test, since a router remembers where it went. `pumpRouter` disposes the router when
the test ends (since 0.5.0), so `LeakTesting` finds nothing left behind. A test that disposes it
itself with an `addTearDown` registered before the call, as tests written for 0.4.x do, passes
`disposeRouter: false` (since 0.6.0): those teardowns run after `pumpRouter`'s, and a second
`dispose` throws. Don't share a router between tests. The generated `AppRoutes` remembers the last
`router()` or `mount()` (its `base` and `rootNavigatorKey`), and a call without a `navigatorKey`
makes a fresh one (since 0.5.0), so a test that mounts under a prefix restores the defaults with
`addTearDown(AppRoutes.mount)`, and no test depends on the order they run in. Return
synchronously from a guard when you can (see [Guards](#guards)): any `Future`, even
`Future.value(...)`, costs a frame, so a test sees a blank first frame before the page, where a
synchronous guard shows the page at once. If a widget
hangs on to its own `WidgetRef` (to call `prefetch` from a test, say), take it from an
element: `tester.element(find.byType(AppLayout)) as WidgetRef`.

**The app around the router** (since 0.8.1). `app:` is a `Widget Function(GoRouter router)` that builds
what goes around the router in place of the plain `MaterialApp.router`. With the
[generated `main()`](#main-appdart-startupdart-and-splashdart), `app: AppMain.app` boots a page in
`lib/app/app.dart`'s theme, localizations and `builder:`, as it runs. `startup()` does not run in
`pumpRouter`: pass what it would override as `overrides`. To boot everything, startup and splash
included, pump `AppMain.root()`:

```dart
testWidgets('starts, then shows the home page', (tester) async {
  await pumpRouter(tester, AppRoutes.router(initialLocation: '/about'), app: AppMain.app);

  // or the whole boot: splash.dart while startup() runs, then the app
  await tester.pumpWidget(AppMain.root(router: () => AppRoutes.router(initialLocation: '/about')));
  await tester.pumpAndSettle(); // a startup() that awaits a fake settles here; real I/O needs tester.runAsync
});
```

A `startup()` that throws is reported to `FlutterError.onError`, which a widget test fails on:
call `tester.takeException()` before you look at the splash. A test that runs `AppMain.run()`
itself (to check a `zone()`) pumps afterwards; `examples/features/test/startup_test.dart` does
all of these.

`pumpRouter` also takes `app:` (since 0.8.1), a function from the router to the app widget around it
(the default is `MaterialApp.router(routerConfig: router)`), and `package:fespalier/testing.dart` exports
riverpod's `Override`. `findRoutePage(pattern)` finds a page by its `semantics_ids` identifier, and
`smokeTestRoute` is what [`fsp test`](#route-smoke-tests-fsp-test) runs for each route; the shop's generated
smoke tests are checked by `just check-examples`.

`pumpRouter` loads the code of every [deferred route](#deferred-routes-a-pages-code-on-demand) first, on the real event loop
(since 0.7.0): a widget test's `pump` never runs `loadLibrary()`, so without that a deferred page would
show `loading.dart` for ever. A test that pumps a router of its own calls
`await tester.runAsync(AppRoutes.loadDeferred);` before `pumpWidget`; forgetting it is a `FlutterError` in
a debug build ("The code of products/$id/page.dart is not loaded, and a widget test can't load it while it
pumps."), not a hang.

The library is separate from `package:fespalier/fespalier.dart`, so your app never imports
`flutter_test`. It's a regular `flutter_test: sdk: flutter` dependency of `fespalier`
(pub allows the Flutter SDK's own packages), which your app has as a dev dependency
anyway and doesn't ship. The helper uses Flutter's `MaterialApp`; with go_router 18 the
note under [Getting started](#getting-started) applies: with a root `transition.dart`,
which `fsp init` writes, routes animate and no nested `material_ui` app is needed in tests.

To import a file from a `$segment` folder, escape the `$`: an unescaped `$id` in an import
is a Dart interpolation error ("URIs can't use string interpolation").

```dart
import 'package:my_app/app/products/\$id/page.dart';
```

go_router builds the whole matched stack, so a deep link like `/products/2` also runs
`/products`' `data.dart` underneath. If your fakes use `Future.delayed`, pump long enough
for the delays in both (or use `pumpAndSettle`), or the test ends with "A Timer is still
pending". `examples/*/test/` has working tests for every file kind. For tests on a device or in a browser, and
journeys across routes, see [Maestro flows](#maestro-flows-fsp-maestro).

## Design notes

**Why `watch` and `read` are static.** `ProductRoute(id: 42).watch(ref)` would be nicer than
`ProductRoute.watch(ref, id: 42)`, and it can't be had for what it costs. An instance member has to
say what it returns, `AsyncValue<Product>`, so the generated file would have to _name_ `Product`,
and it doesn't import what your `data.dart` imports (it can't tell which of its imports a name
comes from, and it may be a private, aliased or record type). The other ways out don't work: a
`late final watch = (ref) => ...` field, whose type Dart would infer from the provider, is refused
in a class with a `const` constructor, and typed routes are `const` (`const SearchRoute(q: 'ap')`);
an `extension type` or a getter still has to be typed; and returning `AsyncValue<Object?>` would
lose the very type that is the point. A static function value takes its type from the provider
by inference, which is why the helpers that return your data are static, and the ones that
don't (`prefetch`, `refresh`, `go`, `location`) are instance methods. If Dart macros, or naming a
type through the import machinery that `extra` already uses, become an option, this can be
reopened; today the trade is a `const` route and a type that is never `dynamic`.

**Why forms are companions of `action.dart`, not a `form.dart`.** A form is the UI of one write, and
`action.dart` already owns what that needs: the keys, the input type, the pending and error state,
the invalidation set and the DevTools site. A `form.dart` would bind all of that again and need a
rule for which action it submits. Validation also has to guard every path to the write (the form,
`submit`, another page, a test), and only code the action's own provider calls can promise that. An
`optimistic()` is about the write's effect on data, which is what `invalidates` is about, so the two
are checked against each other. A new file kind would cost a scan rule, a scaffold, editor support
and orphan diagnostics; companions are a convention like `invalidates`. And the thing a `form.dart`
would invite, a form with no write (search filters), is what URL state (`copyWith`) is for.

**Why `copyWith` is a getter of a function type.** `route.copyWith(page: null)` has to mean "clear
the page" and `route.copyWith()` "keep it", so `null` can't be the default of an `int? page`
parameter. The usual answers each cost something visible. A method with `Object? page = _keep`
accepts anything (`copyWith(page: 'x')` compiles and fails at run time), and its signature in the
IDE says `Object?`. A wrapper for the argument (`copyWith(page: Some(null))`) makes every call site noisier than
the hand-written copy it replaces. Dart has no overload and no way to give an
`int?` parameter a default that isn't an `int?`. What does work is to split what the caller sees
from what runs: the public `copyWith` is a getter whose type is `SearchRoute Function({String? q, int?
page, Sort? sort})`, the fields' own types, and what it returns is a private method that takes
`Object?` with a private `const` sentinel (`_keep`) as each default. A caller passes a `String?` or
nothing; calling the function through its type, an argument that is left out takes the private
default and one that is `null` is `null`. Nothing is `dynamic`, a segment is not nullable
(`copyWith(id: null)` doesn't compile), the route constructors stay `const`, and the sentinel
is one `const` object. Costs: `copyWith` shows in the IDE as a getter whose value is a function (the analyzer
still checks every named parameter and its type), and each call allocates the function (a
tear-off of the private method). If Dart gets a way to tell an omitted optional parameter from a
passed one, this reduces to an ordinary method.

**Why an action's `submit` is static, and its input is typed.** `RefundRoute(id: 1).submit(ref,
input: form)` has the problem `ProductRoute(id: 42).watch(ref)` has: an instance member has to say
what it returns, so the generated file would have to name `Refund`. A static function value takes
its result type from the provider by inference, so it is never `dynamic`. The `input` is the one
type that has to be written out (a function value's parameters can't be inferred), and that one
`fespalier` can name: it reads it from `action.dart` the way it reads the type of an `extra`, which
is how the file's own imports reach `app.g.dart`. A write is also kept apart from the read it
changes on purpose: it has its own provider, with its own state, instead of being a mode of
`data.dart`'s, so a failed write can never put `error.dart` where the form was.

**Why a localized path is one route with an alternation.** `products/` answering `/produits` could be
done three ways in go_router, and only one keeps the URL and the route one thing.

1. _A redirect from each spelling to the canonical path._ It changes the URL the user came for
   (`/produits/2` turns into `/products/2` in the address bar and in shared links), which is the
   opposite of a localized path, and every nested route would need its own redirect.
2. _A sibling `GoRoute` per spelling sharing the builder._ The URL stays, but the subtree is copied
   per spelling (nested routes, layouts, guards), the copies have different page keys (navigating
   from one spelling to another rebuilds the page), restoration ids and a tab's branch would see
   several routes, and the order and duplicate checks multiply.
3. _One `GoRoute`, the segment a path parameter with its own pattern_, `:_l0(products|produits)`.
   go_router matches a route with a regular expression made from its `path`, where `:name(pattern)`
   is a parameter with a pattern of its own (`path_utils.dart`, `patternToRegExp`, the same in go_router
   17.5 and 18.0; the catch-all's `:rest(.+)` is one). A deep link, `go`, a redirect and the tab
   stack all see one route, and its subtree is written once. The costs are small and all handled:
   the parameter shows up in `pathParameters` and `fullPath` (fespalier's readers skip it and
   `routeTemplate` turns it back into the canonical path), a spelling is escaped for the regular
   expression, and go_router's rule that a tab opens on a route without parameters needs an
   `initialLocation`, which `fsp gen` writes.

And the typed side takes the locale as an argument (`locationFor(locale)`, `go(context, locale:)`) rather
than from a global, so that a route stays a value: see [Localized paths](#localized-paths).

## Status

This is an early version.

- **Generator:** 1084 tests (1010 unit, 59 CLI integration, 15 version checks) cover parsing, every binding rule and contract error, query
  parameters, `(group)` folders and route order, tab layouts, navigators and shells, transitions, all three data
  forms, section data, nested `not_found.dart`, the typed helpers, guards and redirects, `extra` for pages, layouts and guards and `extra_codec.dart`,
  scaffolding, the generated `main()` (which files make it, every shape of `lib/app.main.g.dart`, every diagnostic of the three root files), the route manifest, meta.dart (and `meta_unique`) and restoration ids, `match` / `dataAt`, typed catch-alls, enum segments, per-folder case, localized paths (spellings, non-ASCII, collisions, and `route.dart` `paths` edits in the incremental test), routes that leave the page above (`nest = false`), deferred routes (the `route.dart` switch and what it inherits, the `deferred as` imports and views, `preload`, the type rule), string paths that match no route (the lint, its matching, mount point and ignore comments), `fsp size` (dart2js's table of deferred parts read from a real build's `main.dart.js`, own and shared bytes, the stale-build checks and the `size:` budgets), that the committed outputs are up to date, and that `watch`'s incremental runs equal a from-scratch `gen` after random edits (enum files outside the app folder included). Clippy is clean.
- **Runtime + examples:** `flutter analyze` is clean on Flutter 3.47 (go_router 17 and 18,
  hooks_riverpod 3, flutter_hooks 0.21). 1361 Flutter tests (the package 741, the DevTools extension 189, the OpenTelemetry adapter 34, `shop` 78, `features` 258, `tabs` 40, `minimal` 9, `telemetry` 12); the example tests drive the generated router through every
  file kind.
- **Types are compared by spelling, not resolved.** The generator reads a syntax tree,
  not the Dart analyzer, so `Product` and a `typedef` of it count as different types. The
  Dart compiler still catches real mismatches in the generated code. (An enum is the one type
  it does look up: it reads the declaration, and compares enums by it.)

Things to know:

- Pages render below their `layout.dart`, so a layout's `Scaffold` is not their nearest
  `Material` during page transitions. Wrap `ListTile`-heavy pages in
  `Material(type: MaterialType.transparency, …)`, as `products/page.dart` does.
- In a route file, any optional nullable parameter of a primitive type (or of an enum) becomes a
  query parameter, including one you meant as widget configuration (`String? title`). Keep such
  parameters on inner widgets instead of the file's exported one.
- go_router builds the whole matched stack, so `/products/abc` also loads `/products`
  underneath the not-found view.

## License

MIT. See [LICENSE](LICENSE).
