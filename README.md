# fespalier

File-tree routing for Flutter, in the spirit of Next.js. An espalier is a tree
trained flat against a frame; here the frame is `lib/app/`.

You write plain widgets and functions in small files under `lib/app/`. There are no
base classes or interfaces to implement: the file name says what a file is, and its
constructor says what it needs. The `fsp` generator reads every file, works out what
each parameter should receive, checks that the files fit together, and writes one
mountable `lib/app.g.dart`. It's built on go_router, Riverpod and flutter_hooks,
with no build_runner.
## Getting started

You need Flutter 3.32 or newer (Dart 3.8) for the package. go_router 18 needs Flutter
3.44 or newer.

**1. Install the CLI.** On Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
```

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION=v0.9.1` <!-- x-release-please-version -->
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
cargo install --git https://github.com/fespalier/fespalier --tag v0.9.1 fespalier
```

<!-- x-release-please-end -->

With Homebrew (macOS, Linux) or Scoop (Windows), from the tap and the bucket that releases push to
(see [Releasing](docs/releasing.md)):

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
      ref: v0.9.1
```

<!-- x-release-please-end -->

It depends on go_router (17 or 18), hooks_riverpod 3 and flutter_hooks, and
`package:fespalier/fespalier.dart` re-exports all three, so you don't add them yourself.
## License

MIT. See [LICENSE](LICENSE).
