# Building the core: Cargokit or Flutter native assets

FRB splits in two ([FRB, integration overview](https://cjycode.com/flutter_rust_bridge/manual/integrate/overview)):
the **core** (the codegen and the runtime: `api/` into bindings) and the **compilation** (building `rust/` for each
target and bundling the library with the app). The integration backend only decides the second. The bindings, `api/`,
`core/`, the Dart seam and every fespalier file are the same with either.

FRB 2.13 offers two backends for `flutter_rust_bridge_codegen create` and `integrate`:

- **Cargokit**, the default (`rust_builder/`).
- **Native assets**, with `--integration-backend native-assets` (`hook/build.dart`; codegen 2.13.0-beta.2 or later).

`examples/frb-cose` uses native assets, and it is the only backend a fespalier test runs. What this page says about
Cargokit is from Cargokit's and FRB's documentation, not from a fespalier build.

## Side by side

|                       | Native assets (`hook/build.dart`)                                                                                                                               | Cargokit (`rust_builder/`)                                                                                                                                   |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| What it is            | A Dart build hook: `FlutterRustBridgeNativeAssetsBuilder` from `flutter_rust_bridge_hooks`, over `native_toolchain_rust`, registers the library as a code asset | A Flutter plugin package (a path dependency of the app) that carries Cargokit and calls its `build_tool` from Gradle, a CocoaPods script phase and CMake     |
| Who runs it           | The Dart and Flutter tools, for every `flutter test`, `run` and `build`                                                                                         | Each platform's build system, so `flutter run` and `flutter build`; **not** `flutter test` on the host                                                       |
| Host tests            | The hook builds the core first; the library is in `build/native_assets/<os>/`                                                                                   | Nothing builds it: run `cargo build` yourself and open the file from `rust/target/`                                                                          |
| Toolchain and targets | `rust-toolchain.toml` must pin a channel and list the targets; the hook refuses an unlisted triple, rustup installs the listed ones                             | Cargokit's `build_tool` uses rustup to install the toolchain and targets of the build (its `cargokit.yaml` can name a toolchain)                             |
| Build mode            | frb-cose's hook builds the core in **release** for every build (a cold `flutter test` took 115 to 135 s on a 4-vCPU Linux machine)                              | Follows the Flutter build mode                                                                                                                               |
| Precompiled binaries  | None: every machine compiles                                                                                                                                    | Yes: `cargokit.yaml`'s `precompiled_binaries` (URL prefix and a public key), used when rustup is missing; `cargokit_options.yaml` in the app can refuse them |
| Dart and Flutter      | An SDK with build hooks and code assets (frb-cose's pubspec: Dart 3.10, hooks 2.x)                                                                              | Older SDKs work; that is why it stays FRB's default                                                                                                          |
| Crate                 | `crate-type = ["staticlib", "cdylib"]` (frb-cose adds `rlib` for `cargo test`)                                                                                  | The same crate; Cargokit builds a static library for Apple targets and a dynamic one for Android, Linux and Windows                                          |
| Web                   | No code assets on the web: the hook builds nothing, so the app needs a fallback core                                                                            | Not Cargokit's job either: FRB's web backend is a separate wasm build                                                                                        |
| Upstream              | Part of FRB (`flutter_rust_bridge_hooks`, published with FRB)                                                                                                   | `irondash/cargokit` was archived on 2026-03-26; FRB carries its own fork for the templates                                                                   |
| Files in the app      | `hook/build.dart`, `flutter_rust_bridge_hooks` in `dependencies:`                                                                                               | `rust_builder/` (with `cargokit/` inside), its path dependency, its exclusion in `analysis_options.yaml`                                                     |

## Which one

**A new fespalier app: native assets.** It is what frb-cose runs on every CI build, so the rest of this skill is checked
against it; a host `flutter test` tests the real core with no extra step; and there is one place that builds Rust,
`hook/build.dart`, instead of four build systems. FRB's own page says the same for a project that can use a recent SDK
([FRB, Cargokit](https://cjycode.com/flutter_rust_bridge/manual/integrate/cargokit)).

**Keep or pick Cargokit** when:

- the app must build on a Flutter whose Dart has no build hooks;
- you ship a **package** that others depend on and they must not need rustup (precompiled binaries, signed);
- an existing app works on it and nothing above is a problem yet. Moving is mechanical, but it changes every
  platform's build, so it needs a device run per platform.

Never both: one of them would build the core a second time, and two copies of a library with the same symbols is a
link or load error at best.

## Moving from Cargokit to native assets

From FRB's guide ([migrate Cargokit to native assets](https://cjycode.com/flutter_rust_bridge/manual/integrate/migrate-cargokit-to-native-assets)),
with what frb-cose adds:

1. In the app root: `flutter_rust_bridge_codegen integrate --integration-backend native-assets`. It writes
   `hook/build.dart`; if one exists it keeps it, warns, and leaves you to add `FlutterRustBridgeNativeAssetsBuilder` to
   it by hand.
2. Check the crate: `[lib] crate-type` has `staticlib` and `cdylib`; `rust-toolchain.toml` pins an exact channel (not
   `stable`) and **lists every target** you build (frb-cose's list is FRB 2.13's template targets without `wasm32`).
3. Remove Cargokit: delete `rust_builder/`, its path dependency in `pubspec.yaml` and its exclusion in
   `analysis_options.yaml` (a package deletes `cargokit/` and the `ffiPlugin` entries that only it needed).
4. Pin `flutter_rust_bridge_hooks` at FRB's exact version, next to `flutter_rust_bridge`.
5. `flutter pub get`, then `flutter_rust_bridge_codegen generate`: the bindings should not change (the backend is
   compilation only). Commit them if they do, and find out why.
6. Host tests: drop the `cargo build` step and load the library from `build/native_assets/<os>/` ([testing](testing.md)).
7. CI: the job that runs `flutter test` now needs rustup and the toolchain file's channel (frb-cose's `dart` job reads
   it from `rust-toolchain.toml`), and a cache of `rust/target` and `.dart_tool/hooks_runner`.
8. Run it on every platform you ship, and write what you did not run as UNCHECKED: the Android ABIs (NDK 27 or later),
   iOS device and simulator, a universal macOS build, Windows.

## Loading the library

`RustLib.init()` with no argument is what the app calls: the library is bundled where the platform loader finds it by
name. A host test cannot rely on that with native assets (frb-cose's `test/support/host_core.dart` opens the file by
path), and with Cargokit there is no bundled library at all in a host test. Whether the bare name resolves on each
device is UNCHECKED in frb-cose ([#271](https://github.com/fespalier/fespalier/issues/271)).

## What to put in the app's notes

Whichever backend: the disk and time a cold build costs (targets, first compile), the targets the toolchain file lists,
what a phone build needs (NDK, Xcode, Visual Studio's C++ tools), and what the web does without the core. frb-cose's
README, "Run it" and "Native assets", is the model.
