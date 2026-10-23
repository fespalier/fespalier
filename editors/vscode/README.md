# fespalier for VS Code

Shows what `fsp check` finds in your route tree (`lib/app/`) in the Problems panel, and runs
`fsp gen` from the command palette, and runs the `tasks:` of your `pubspec.yaml` from Run Task (since fespalier 0.22.0). It is a thin layer over the generator's `--json`
diagnostics: nothing is re-implemented in the editor.

- **Problems panel.** Saving a file under the app folder, or any Dart file under `lib/` (string
  paths that match no route, since fespalier 0.7.0), runs `fsp check --json` for that
  project and lists every error and warning against its file, line and column. The app folder
  is `fespalier: app_dir:` in `pubspec.yaml` (`lib/app` by default). Saving `pubspec.yaml`
  checks again. Every project in the workspace is checked once when it opens.
- **fespalier: generate** runs `fsp gen` (saving open files first) and writes `lib/app.g.dart`.
- **fespalier: check** runs the check on demand. Clicking the status bar item does the same.
- **Tasks** (since fespalier 0.22.0). _Terminal | Run Task..._ lists `dev` and each task of `fespalier: tasks:`
  in `pubspec.yaml`, each in its own terminal: `dev` runs `fsp dev`, the others `fsp run <name>`. The list follows
  `pubspec.yaml`. `build` needs a target, so it is a `.vscode/tasks.json` entry with `"type": "fespalier"`,
  `"task": "build"` and a `"target"` such as `"web"`. See [Tasks in your editor](../../docs/cli.md#tasks-in-your-editor).
  A list that could not be read (no `fsp`, or one older than 0.22.0) is not kept: a warning says why and the next
  _Run Task_ asks again. A `tasks.json` entry is checked before it runs (`args` a list of strings, `path` and `target`
  strings, a `pubspec.yaml` in the folder). **UNCHECKED on a device:** the list, the terminals and Terminate Task have
  not run in VS Code; CI runs the task provider against a stand-in for the `vscode` module (the parsing of
  `fsp run --json`, the commands, the warnings, the labels, the `tasks.json` checks), not VS Code.
- **Status bar.** `fespalier` with a check mark, or the number of errors or warnings.
- **`pubspec.yaml`** (since fespalier 0.23.0), with Red Hat's YAML extension (`redhat.vscode-yaml`) installed: the keys
  of the `fespalier:` section complete as you type, show what they do on hover, and an unknown key, a value of the
  wrong type or one off a list is underlined. The extension gives the YAML extension one schema for `pubspec.yaml`,
  the JSON Schema Store's pubspec schema with the `fespalier:` section added, so the checks of the rest of the file
  stay. Without the YAML extension nothing changes: saving `pubspec.yaml` runs `fsp check`, which stops on a mistake in
  the section (the status bar says `fespalier: failed`, and the fespalier output has the message). The schema is the
  one this extension ships, of the fespalier it was built with: a key that a newer fespalier added is reported as
  unknown until the extension is updated, and one an older fespalier does not read yet is offered. **UNCHECKED in VS
  Code:** CI runs the YAML extension's language server on the shipped schema, not VS Code.

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
