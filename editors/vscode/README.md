# fespalier for VS Code

Shows what `fsp check` finds in your route tree (`lib/app/`) in the Problems panel, and runs
`fsp gen` from the command palette. It is a thin layer over the generator's `--json`
diagnostics: nothing is re-implemented in the editor.

- **Problems panel.** Saving a file under the app folder, or any Dart file under `lib/` (string
  paths that match no route, since fespalier 0.7.0), runs `fsp check --json` for that
  project and lists every error and warning against its file, line and column. The app folder
  is `fespalier: app_dir:` in `pubspec.yaml` (`lib/app` by default). Saving `pubspec.yaml`
  checks again. Every project in the workspace is checked once when it opens.
- **fespalier: generate** runs `fsp gen` (saving open files first) and writes `lib/app.g.dart`.
- **fespalier: check** runs the check on demand. Clicking the status bar item does the same.
- **Status bar.** `fespalier` with a check mark, or the number of errors or warnings.

## Requirements

`fsp` on your `PATH` ([install it](https://github.com/fespalier/fespalier#getting-started)),
or a project that has the `fespalier` package, in which case the extension runs
`dart run fespalier`, which downloads the matching `fsp` on first use.

## Settings

| Setting                 | Default |                                                                                                        |
| ----------------------- | ------- | ------------------------------------------------------------------------------------------------------ |
| `fespalier.runner`      | `auto`  | `auto`: `fsp` when it is on PATH, otherwise `dart run fespalier`. `fsp` or `dart` always use that one. |
| `fespalier.fspPath`     | `fsp`   | The `fsp` executable, by name or full path.                                                            |
| `fespalier.checkOnSave` | `true`  | Check when a file under the app folder, or a Dart file under `lib/`, is saved.                         |

## Build and install from source

```sh
cd editors/vscode
npm install
npm test                 # compiles, then runs the unit tests
npx @vscode/vsce package # writes fespalier-<version>.vsix
code --install-extension fespalier-*.vsix
```

To try it without installing, run `code --extensionDevelopmentPath=editors/vscode <your app>`
from the repository root.
