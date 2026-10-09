# Installation and setup

The [README](../README.md#getting-started) has the 60-second path: install `fsp`, then `fsp create` (a new app) or add the package and run `fsp init` (an app you have). This page has the rest: every way to install `fsp`, the companion packages, what `fsp create` and `fsp init` write, how to keep `app.g.dart` in CI, and platform notes.

## Requirements

- Flutter 3.32 or newer (Dart 3.8). go_router 18 needs Flutter 3.44 or newer.
- `flutter analyze` is clean on Flutter 3.47 with go_router 17 and 18, hooks_riverpod 3 and flutter_hooks 0.21.
- The package depends on go_router (17 or 18), hooks_riverpod 3 and flutter_hooks.
  `package:fespalier/fespalier.dart` re-exports all three, so you don't add them yourself.

## Install fsp

### Linux and macOS

```sh
curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
```

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION` to a release tag
(the default is the latest) and `FSP_INSTALL_DIR=/some/dir` to install elsewhere.

### Windows

```powershell
irm https://raw.githubusercontent.com/fespalier/fespalier/main/install.ps1 | iex
```

It puts `fsp.exe` in `%LOCALAPPDATA%\fespalier\bin` (change it with `$env:FSP_INSTALL_DIR`, pick a
release with `$env:FSP_VERSION`), checks the SHA-256, and prints how to add that folder to your `PATH`
if it isn't there yet.

### With Rust

`cargo install` builds `fsp` from the release tag on any platform. The command, with the current tag, is
in the [README](../README.md#getting-started).

### Homebrew and Scoop

Homebrew (macOS, Linux) and Scoop (Windows) install from the tap and the bucket that releases push to:

```sh
brew tap fespalier/tap && brew install fsp   # or in one go: brew install fespalier/tap/fsp
scoop bucket add fespalier https://github.com/fespalier/scoop-bucket && scoop install fsp
```

They hold the latest release only once it has pushed to them. Until then, or without the bucket, Scoop can install the `fsp.json` that every release attaches (it names that release's archives and their SHA-256s):

```powershell
scoop install https://github.com/fespalier/fespalier/releases/latest/download/fsp.json
```

To update that one, `scoop uninstall fsp` and run it again.

Homebrew has no such fallback (`brew install` reads formulae from taps only, and refuses a path or URL), so where the tap has no release yet, macOS users use the install script above.

### Without installing: dart run fespalier

Once the package is in your `pubspec.yaml` (step 2), `dart run fespalier <command>` runs `fsp` for you.
Use it wherever these docs say `fsp`:

```sh
dart run fespalier init
dart run fespalier watch
dart run fespalier check
```

- **First run.** It downloads the `fsp` release that matches the package's version and keeps it in your user cache (`~/.cache/fespalier` on Linux, `~/Library/Caches/fespalier` on macOS, `%LOCALAPPDATA%\fespalier` on Windows; `FSP_CACHE_DIR` moves it). Later runs start at once.
- **Checksum.** The download is checked against the SHA-256 that the package carries for its own version,
  so a tampered release is refused. A package built from a branch has no pins yet: it checks the
  release's `.sha256` file instead and says so.
- **Offline.** With an empty cache it stops with one line naming the missing version; with a warm cache it never uses the network. It needs `tar`, which macOS, Linux and Windows 10+ include.
- **Your own binary.** Set `FSP_BINARY=/path/to/fsp`, for example a build from source. An `fsp` on your `PATH` is used too when its version is the package's.

The package and the binary are versioned together, and this is what keeps them in step.

### Upgrading fsp

`fsp upgrade` (since 0.15.0) upgrades the `fsp` you are running the way you installed it, and needs no project:

```sh
fsp upgrade --check     # is there a newer release? exit 0 (up to date), 3 (yes), 1 (could not tell)
fsp upgrade --dry-run   # what it would run, and nothing else
fsp upgrade             # upgrade
```

It reads the latest release from GitHub with the system `curl` (so `HTTPS_PROXY` and your certificate store apply), works out how this `fsp` was installed from where the binary is, and hands the upgrade to that installer:

| Installed with             | `fsp upgrade`                                                                                                                     |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Homebrew                   | runs `brew upgrade fespalier/tap/fsp` (run `brew update` first when the tap has no newer release yet)                             |
| Scoop                      | prints `scoop update` and `scoop update fsp`                                                                                      |
| `cargo install`            | prints the `cargo install --git ... --tag <tag> --locked fespalier` line for the latest release                                   |
| The install script         | replaces the binary in place, after checking the download (below); `--version vX.Y.Z` picks another release, a downgrade included |
| `dart run fespalier`       | refuses: see below                                                                                                                |
| A build of the source tree | refuses; update the checkout                                                                                                      |

`fsp upgrade --check --json` prints one object (`current`, `latest`, `target`, `method`, `command`, `upToDate`) for scripts. `FSP_RELEASES_URL` (where the latest release is looked up) and `FSP_BASE_URL` (where archives are downloaded from) point it at a mirror.

**What replacing in place does.** It downloads `fsp-<target>.tar.gz` (`.zip` on Windows) into the folder the binary is in, with the system `curl`, and only installs it when its SHA-256 equals both the release's `.sha256` and the checksum that the release's tag pins in `release_checksums.dart` (the file `dart run fespalier` trusts too; the pins must be those of the same release). A mismatch stops with both values and changes nothing; so does a release without pins (set `FSP_UPGRADE_ALLOW_UNPINNED=1` only for a release you staged yourself). It unpacks with the system `tar`, runs the new `fsp --version` and requires `fsp <release>`, then renames it over the old one. On Windows the running `fsp.exe` is renamed to `fsp.exe.old` first (the next run of any `fsp` command deletes it, silently), and moved back if the new one cannot take its place. Temporary files are removed on every path. When the folder is not writable, `fsp upgrade` says so and shows the install script with `FSP_INSTALL_DIR` for a folder you own; it never uses `sudo`. On success it prints `✓ fsp X → Y (path)`; asking for an older release with `--version` prints a downgrade notice first.

The `fsp` that `dart run fespalier` keeps in its cache is not upgraded by `fsp upgrade`: it is the one for the version your `pubspec.yaml` pins, and it changes when you change that `ref:`. Move the `ref:` of fespalier and of every companion package to the release you want, then `flutter pub get`.

### Environment variables

| Variable           | Used by                     | What it does                                                                                                                         |
| ------------------ | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `FSP_VERSION`      | `install.sh`, `install.ps1` | A release tag to install (the default is the latest). In PowerShell it is `$env:FSP_VERSION`.                                        |
| `FSP_INSTALL_DIR`  | `install.sh`, `install.ps1` | Where `fsp` is installed (`~/.local/bin`, or `%LOCALAPPDATA%\fespalier\bin` on Windows).                                             |
| `FSP_CACHE_DIR`    | `dart run fespalier`        | Where the launcher keeps the `fsp` it downloaded (`~/.cache/fespalier`, `~/Library/Caches/fespalier`, `%LOCALAPPDATA%\fespalier`).   |
| `FSP_BINARY`       | `dart run fespalier`        | The path of an `fsp` of your own to run, for example a build from source.                                                            |
| `FSP_RELEASES_URL` | `fsp upgrade`               | Where the latest release is looked up (default: GitHub's `/releases/latest`, which redirects to the tag). Any `http` or `https` URL. |
| `FSP_BASE_URL`     | `install.sh`, `fsp upgrade` | Where release archives are downloaded from (default: GitHub's `releases/download`).                                                  |

## Companion packages

`fespalier_otel`, `fespalier_sentry`, `fespalier_auth`, `fespalier_sign_keypair`, `fespalier_flags`, `fespalier_storage`, `fespalier_connectivity`, `fespalier_adaptive`, `fespalier_image`, `fespalier_http` (since 0.15.0), `fespalier_dio`, `fespalier_cratestack`, `fespalier_tolgee` (since 0.10.0), `fespalier_forms` (since 0.11.0), `fespalier_maps`, `fespalier_download` (since 0.15.0), `fespalier_push`, `fespalier_biometrics`, `fespalier_analytics`, `fespalier_frb` and `fespalier_riverpod` (since 0.13.0) are not published to a registry: an app uses each as a git dependency at the same release tag as `fespalier`. None of them changes the `fespalier:` keys, and an app that does not depend on one pays nothing for it. `fespalier_forms` is the one companion that changes `fsp` (a diagnostic and an import): an app with a `form()` in an `action.dart` needs it, and `app.g.dart` imports it only then ([Forms](forms.md)). Each package's own section shows the block to copy, and the package's README links back here.

Add a companion next to `fespalier`, with the same `url` and the same `ref`: pub resolves the two to one
package only if they are the same repository dependency. A mismatch fails like this (the form it takes
when the first is a path; when the second is a path, the two halves swap places; the package named is the
companion you added):

```text
Because every version of fespalier_flags from path depends on fespalier from git https://github.com/fespalier/fespalier at v0.7.0 in packages/fespalier and demo depends on fespalier from git https://github.com/fespalier/fespalier at v0.6.0 in packages/fespalier, fespalier_flags from path is forbidden.
```

## fsp create

Since 0.15.0. For a new app, `fsp create` does what `flutter create`, adding the dependency, `fsp init` and `fsp gen` do by hand:

```sh
fsp create my_app
cd my_app
fsp dev
```

It needs Flutter 3.32 or newer on `PATH`, and it makes the folder `my_app` with the platform folders, a `pubspec.yaml` that depends on `fespalier` at the release tag of the `fsp` you ran, `lib/main.dart`, the starter files of `fsp init` under `lib/app/` with a second page, the generated `lib/app.g.dart` and `lib/app.main.g.dart`, and a smoke test per route in `test/routes/`. `flutter pub get` has run. `--features storage,connectivity` (or `all`) adds optional features, each with its companion package where it has one, its lines in `lib/app/startup.dart` and a test: `storage` is a [`dataCache` on disk](data.md#a-cache-on-disk-fespalier_storage), `connectivity` is [`reconnectSignal` and `hasNetwork`](data.md#reconnects-fespalier_connectivity), `devtools` is a [`devtools_options.yaml`](devtools.md#how-to-see-it), `forms` is a [form on an action](forms.md), `flags` is a [flagged route](guards.md#feature-flags-fespalier_flags), `adaptive` is [tabs as a bar, a rail or a drawer](layouts.md#a-bar-a-rail-or-a-drawer-fespalier_adaptive), which `--template tabs` asks for too, `otel` is [OpenTelemetry spans](observability.md#opentelemetry-with-otel_zone) (it needs Flutter 3.35), and `sentry` is [errors in Sentry](observability.md#wiring-sentry), which compose when you ask for both; `fsp create --list-features` lists them. The flags (`--org`, `--platforms`, `--project-name`, `--dry-run`, `--json`) and what happens when a step fails are in [`fsp create`](cli.md#fsp-create) of the CLI reference.

## fsp init

For an app that already exists, run `fsp init` in the project root:

```sh
fsp init
```

It creates:

- `lib/app/layout.dart`, `page.dart` and `not_found.dart` (`not-found.dart` with
  [`file_style: kebab`](file-kinds.md#file-names)). `not_found.dart` is optional: without it, unknown
  paths get a plain "Nothing at /path" view. Other folders can have their own (see
  [Not-found views](routing.md#not-found-views)).
- `transition.dart`: every route animates with the Material transition.
- Since 0.8.1, `app.dart`: the `MaterialApp.router` around the router (not with
  [`main: manual`](app-startup.md)).

It then writes `lib/app.g.dart` and, from `app.dart`, `lib/app.main.g.dart`. It never overwrites a file
that exists: those are reported as `skip`. Last, it prints what is left to do: the dependency block above
(if `pubspec.yaml` doesn't have it yet) and this `main.dart`:

```dart
import 'package:my_app/app.main.g.dart';

Future<void> main() => AppMain.run();
```

`AppMain` is generated from `lib/app/app.dart` (and `startup.dart` and `splash.dart`, if you add them):
it starts the app inside a `ProviderScope`, builds the router once and runs `runApp`. See
[`main()`: app.dart, startup.dart and splash.dart](app-startup.md). `main: manual` keeps a `main()` that
builds the `ProviderScope` and the `MaterialApp.router` itself.

A plain `flutter create` (not `--empty`) also wrote `test/widget_test.dart`, which refers to the `MyApp` you just replaced, so `flutter analyze` fails on it: delete it, or rewrite it (see [Testing](testing.md)).

## Day to day

```sh
fsp dev                                   # the app, regenerated and hot restarted on every save (since 0.9.0)
fsp watch                                 # or next to your own `flutter run`: regenerates when the routing changes
fsp new 'orders/[id]' --data --loading    # scaffold a route, then regenerate app.g.dart
fsp new 'orders/[id]/refund' --action     # a write beside the page (action.dart)
```

`fsp new` runs `gen` right away, so the new route is usable as soon as it returns. All the flags are in [The generator](cli.md#the-generator), and `fsp dev` in [Running your app](cli.md#running-your-app-fsp-dev).

## Keeping app.g.dart

There are two ways to keep `app.g.dart`. Pick one.

### Commit it

This is the default. `lib/app.g.dart` is plain code, meant to be read, and the app builds without `fsp`
installed. In CI, run `fsp check`:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
```

Or, with nothing to install (after `flutter pub get`): `- run: dart run fespalier check`.

`fsp check` writes nothing (it never touches `app.g.dart`) and exits non-zero on routing errors. It does
**not** compare the committed file with what the tree would generate, so it passes when `lib/app.g.dart`
is stale. To fail on that, see [Failing CI on a stale file](#failing-ci-on-a-stale-file).

### Generate, don't commit

For projects that never commit generated code (`**/*.g.dart` is ignored already, and every generator
runs before analysis). Add the file to `.gitignore`:

```gitignore
lib/app.g.dart
```

Generate it wherever the app is analyzed, tested or built: on a fresh clone, and in CI **before**
`flutter analyze`, because `app.g.dart` doesn't exist until then:

```yaml
- run: flutter pub get
- run: dart run fespalier gen # writes lib/app.g.dart; fails on routing errors
- run: flutter analyze
- run: flutter test
```

- **No version pin.** `dart run fespalier` runs the `fsp` release that matches the `fespalier` package your `pubspec.lock` resolved, so the generator and the runtime `app.g.dart` imports can't drift apart.
- **Caching.** The first run downloads it (SHA-256 pinned in the package, see
  [above](#without-installing-dart-run-fespalier)) into the user cache. To skip that, keep
  `~/.cache/fespalier` (`FSP_CACHE_DIR`) between CI runs with `actions/cache`, keyed on `pubspec.lock`.
- **Your own binary.** Set `FSP_BINARY` to use one you built. Locally, `dart run fespalier watch` keeps the file current; `fsp check` still works in this mode and doesn't need the generated file to exist.

### Failing CI on a stale file

To fail CI on a stale committed file, regenerate it and fail on any difference. `fsp gen` follows
`format:` in the pubspec, so the result is what you would commit:

```yaml
- run: fsp gen
- run: git diff --exit-code lib/app.g.dart
```

## Platform notes

### Web URLs

Flutter web uses hash URLs (`/#/products/1`) unless you switch to path URLs:

1. Add `flutter_web_plugins: {sdk: flutter}` to `dependencies`.
2. Call `usePathUrlStrategy()` (from `package:flutter_web_plugins/url_strategy.dart`) before `runApp`.
   With the generated `main()` (since 0.8.1), make it the first line of `startup()`: the router is only
   built after it.
3. Make your web server serve `index.html` for unknown paths.

### go_router 18 and Material

go_router 18 checks for `MaterialApp` from `package:material_ui`, not the one in
`package:flutter/material.dart`. With Flutter's `MaterialApp` it treats your app as a plain widgets app:
routes without a `transition.dart` don't animate at all, and go_router's own error screen is unstyled.
go_router 17 checks Flutter's `MaterialApp` and has no such problem. Three ways around it:

- **Add a root `lib/app/transition.dart`** that says how routes animate, e.g.
  `Page<void> transition(LocalKey key, Widget child) => Transitions.material(key, child);` (or
  `cupertino`). `fsp init` already adds this file. It works with either `MaterialApp`, and it's the easy
  fix. The examples each have one, so their routes animate on both go_router 17 and 18.
- **Use `MaterialApp` from `package:material_ui`** (add `material_ui` to `dependencies`). It has its own
  `Theme` and localizations, which widgets from `package:flutter/material.dart` don't read, so it only
  makes sense if you import `package:material_ui/material_ui.dart` everywhere. Mixing the two loses your
  theme.
- **Stay on go_router 17** by adding `go_router: ^17.0.0` to your `dependencies`.
