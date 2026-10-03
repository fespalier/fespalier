# fespalier for IntelliJ IDEA and Android Studio

Shows what `fsp check` finds in your route tree (`lib/app/`) as errors and warnings in the
editor, and runs `fsp gen` from the Tools menu. It is a thin layer over the generator's
`--json` diagnostics: nothing is re-implemented in the IDE. It is the counterpart of
`editors/vscode/`.

- **Inline diagnostics.** A file under the app folder (`fespalier: app_dir:` in
  `pubspec.yaml`, `lib/app` by default), or any other Dart file under `lib/` (a string path
  that matches no route, since fespalier 0.7.0), is highlighted with the problems
  `fsp check --json` reports for it, at the reported line and column, as an error or a
  warning. Saving a file under the app folder, any Dart file under `lib/`, or `pubspec.yaml`,
  checks again. The open files of a project share
  one `fsp` run. A project is a folder whose `pubspec.yaml` lists `fespalier` as a dependency
  or has a `fespalier:` section.
- **Tools | fespalier: Generate** runs `fsp gen` (saving open files first) and writes
  `lib/app.g.dart`. **Tools | fespalier: Check** runs the check on demand. Both run for the
  project of the file in the editor, or for every fespalier project when there is none, and
  end with a notification: the generator's summary line, the first problems (with _Open first
  problem_), and a _Settings_ link when `fsp` could not be run at all.
- Problems on a folder rather than a file (a folder named `[id]`, say) have no place in an
  editor; they show in the notification of _fespalier: Check_.

## Requirements

- IntelliJ IDEA or Android Studio on platform 252 (2025.2) or later. The plugin depends only
  on the platform. Highlighting Dart files needs the Dart plugin (Android Studio has it;
  install it in IDEA). `pubspec.yaml` is highlighted through the bundled YAML support.
- `fsp` on your `PATH` ([install it](https://github.com/fespalier/fespalier#getting-started)),
  or a project that has the `fespalier` package, in which case the plugin runs
  `dart run fespalier`, which downloads the matching `fsp` on first use (that run can take a
  while; it is allowed five minutes). The IDE's shell environment is used, so a `PATH` set in
  `.zshrc` is seen even when the IDE was started from the Dock.

## Settings

Settings | Tools | fespalier:

| Setting                                                                   | Default |                                                                                                                    |
| ------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------ |
| Runner                                                                    | Auto    | Auto: `fsp` when it is on PATH, otherwise `dart run fespalier`. `fsp` or `dart run fespalier` always use that one. |
| fsp executable                                                            | `fsp`   | The `fsp` executable, by name or full path.                                                                        |
| Check when a file under the app folder or a Dart file under lib/ is saved | on      | Off: only _fespalier: Check_ and _Generate_ update the highlights.                                                 |

## Build and install from source

Needs JDK 21 (the 2025.2 platform is compiled for it). Gradle is the wrapper in this folder;
the first build downloads the IntelliJ Platform (a 1.7 GB archive, cached by Gradle).

```sh
cd editors/intellij
./gradlew build          # compiles, then runs the tests
./gradlew buildPlugin    # writes build/distributions/fespalier-intellij-<version>.zip
./gradlew runIde         # starts a sandbox IDE with the plugin, to try it
```

To install the zip: _Settings | Plugins | gear icon | Install Plugin from Disk..._.

The tests are plain JUnit for the parts that don't need an IDE (`core/`: the JSON to
highlight mapping, the pubspec reading, the command line), and one test that starts a
headless IDE and checks that a stand-in `fsp` printing two diagnostics ends up as two
highlights.

## Code map

|                                                    |                                                                                                      |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `core/Findings.kt`, `core/MiniJson.kt`             | Parses the JSON lines; maps a line and column (code points) to the text range to underline.          |
| `core/Pubspec.kt`                                  | Whether a pubspec uses fespalier, `app_dir`, whether a path is under it.                             |
| `core/Runner.kt`                                   | The `fsp` / `dart run fespalier` command line; reading the outcome of a run.                         |
| `FespalierService.kt`                              | Starts the process, keeps the last check per project, drops it when a file it depends on is written. |
| `FespalierAnnotator.kt`                            | The external annotator: shows the findings of the shared check on a file.                            |
| `FespalierActions.kt`, `FespalierNotifier.kt`      | The Tools menu actions and the notifications.                                                        |
| `FespalierSettings.kt`, `FespalierConfigurable.kt` | The settings and their page.                                                                         |
