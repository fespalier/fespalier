# Diagnostics: `fsp create` (since 0.15.0)

As of 0.15.0 (`cli/src/create.rs` for the steps, `cli/src/create/plan.rs` for the checks, `cli/src/create/recipes.rs` for the features).
Messages are quoted as they are printed, to stderr, exit 1 (with `--json`, the same text is also the `message` of an `error` event on
stdout). The user documentation is the docs section
[fsp create](https://github.com/fespalier/fespalier/blob/main/docs/cli.md#fsp-create); the command is in `fespalier`,
`references/cli-and-config.md`.

`fsp create` needs no project and refuses `--project`. Everything in the first two tables is checked before anything is written
(except Flutter's own, which needs the installed Flutter; `--dry-run` does not run it and so skips those).

## Before anything is made

`{dir}` is the folder as you typed it, `{x}` a value you gave.

| Message                                                                                                               | Cause and fix                                                                                                                                                                                                                                                                                                                |
| --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ``fsp create takes the new app's folder as its argument; --project selects an existing app (`fsp init` sets one up)`` | `--project` was passed. Give the new folder as the argument; to set up an existing app run `fsp init`.                                                                                                                                                                                                                       |
| ``{dir} is not empty; `fsp create` makes a new folder (to add fespalier to an existing app, run `fsp init`)``         | The folder has files in it. Pick another, or empty it; `fsp create` never writes into an app that exists.                                                                                                                                                                                                                    |
| `{dir} exists and is a file`                                                                                          | A file has the name. Pick another.                                                                                                                                                                                                                                                                                           |
| `` `{x}` does not make a Dart package name ({why}): pass --project-name <name> ``                                     | The folder's name (`My-App` is made into `my_app` on its own) cannot be a package: it starts with a digit, is a Dart keyword or has other characters.                                                                                                                                                                        |
| `` `{x}` is not a name for a Dart package: {why} ``                                                                   | The same, for a `--project-name`. The reasons: `it is empty`, `a package name starts with a lower case letter`, `... has only lower case letters, digits and underscores`, `` `{x}` is a Dart keyword ``, `` the app depends on a package called `{x}` `` (`flutter`, `flutter_test`, `flutter_lints`, `test`, `fespalier`). |
| ``the app cannot be named `{x}`: it depends on a package of that name ({x})``                                         | A feature adds a dependency called like the app. Rename the app.                                                                                                                                                                                                                                                             |
| ``cannot name the app after `{dir}`: pass --project-name``                                                            | The folder is `/`, `..` or has no name of its own.                                                                                                                                                                                                                                                                           |
| ``unknown platform `{x}`; the platforms are android, ios, linux, macos, web, windows``                                | `--platforms` takes a comma-separated list of those six.                                                                                                                                                                                                                                                                     |
| `` `{x}` is not an organization like `com.example` ``                                                                 | `--org` is empty, starts with `-` or has a space.                                                                                                                                                                                                                                                                            |
| `--description is one line`                                                                                           | A newline in `--description`.                                                                                                                                                                                                                                                                                                |
| ``unknown feature `{x}`: `fsp create` has no optional features yet``                                                  | Only when the table has no feature at all, which no release does; use `--list-features` for the ids.                                                                                                                                                                                                                         |
| ``unknown feature `{x}`; the features are a, b, c (`fsp create --list-features`)``                                    | A misspelled id; the message lists what exists, and `all` for every feature.                                                                                                                                                                                                                                                 |
| `` `{a}` and `{b}` cannot be combined ``                                                                              | Two features whose recipes conflict. Pick one.                                                                                                                                                                                                                                                                               |
| `` `--template minimal` and the `adaptive` feature cannot be combined: `adaptive` is the tabs template ``             | `adaptive` and `--template tabs` are the same app. Drop `--template minimal` or the feature (`--features all` with `--template minimal` is every feature but `adaptive`).                                                                                                                                                    |
| ``note: `{a}` needs `{b}`: added it``                                                                                 | Not an error: a feature that another one needs was added.                                                                                                                                                                                                                                                                    |
| ``note: `{a}` needs Flutter {n} or newer, and this is Flutter {v}: left out of `all` ``                               | Not an error: `--features all` is every feature the installed Flutter runs, and `{a}` (`otel`, which needs Dart 3.9) is above it. Upgrade Flutter to get it; asking for `{a}` by name is refused with the next message.                                                                                                      |
| `--local-packages {p}: no such folder` / `not a checkout of fespalier (no packages/fespalier/pubspec.yaml)`           | The hidden flag for CI and contributors: give the root of a checkout of the fespalier repository.                                                                                                                                                                                                                            |

## Flutter

| Message                                                                                                                 | Cause and fix                                                                                                                                                |
| ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `` `flutter` is not on PATH: install Flutter (https://docs.flutter.dev/get-started/install) and try again ``            | No `flutter` to run. Put its `bin/` on `PATH` (the same for CI: `subosito/flutter-action`).                                                                  |
| `Flutter {v} is too old: fespalier needs Flutter 3.32 or newer (https://docs.flutter.dev/release/upgrade)`              | The floor of the package. Upgrade Flutter.                                                                                                                   |
| `` `{id}` needs Flutter {f} or newer, and this is Flutter {v}; leave it out, or upgrade ``                              | A feature named on the command line with a higher floor than the installed Flutter (`otel` needs 3.35). `--features all` leaves it out instead, with a note. |
| `warning: could not read Flutter's version; not checking it`                                                            | `flutter --version --machine` answered something that is not JSON with a `frameworkVersion`. The version checks are skipped; the rest goes on.               |
| ``could not start `flutter ...` (fsp create): `flutter` is not on PATH`` / `` `flutter create ...` failed (exit {n}) `` | The `flutter create` step failed (flutter printed why above it). Nothing was made: the folder next to the app, `.{dir}.fsp-create-<pid>`, is deleted.        |

## After the app is in place

The folder has been moved, so the app stays. The message is `{step} failed: {why}`, then

```text
The app is in {dir}; fix that and finish with:
  cd {dir}
  flutter pub get && fsp gen && fsp test
```

(the list is what is left: after a failed `fsp gen`, `fsp gen && fsp test`).

| Step              | What failed                                                                                                                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `flutter pub get` | Usually the network, or a version conflict. With the hidden `--local-packages`, a path that is not a checkout. Run it again in the app; `--offline` uses the pub cache.                                                        |
| `fsp gen`         | The generator refused the files, or `fsp test` could not write its file (a `test/routes/routes_test.dart` of yours that `fsp test` did not write: ``was not written by `fsp test` ``). Fix it in the app and run the commands. |

A leftover `.{dir}.fsp-create-<pid>` folder next to where the app should be means `fsp create` was killed before the move (a signal
at the wrong moment, a power cut): delete it.
