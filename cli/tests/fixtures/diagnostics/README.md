# Broken trees

Each folder here is the smallest app folder (a `pubspec.yaml` and a few files under `lib/app/`)
that makes `fsp check` report **one** diagnostic. They are wrong on purpose: nothing compiles
them, and no formatter or linter should touch them (the org lint excludes
`cli/tests/fixtures/diagnostics/<case>/`; see `filter-regex-exclude` in
`.github/workflows/quality.yml`).

`expected.txt` in each folder is the golden: the exit status, the diagnostics `fsp check --json`
prints (one JSON object per line, sorted) and its stderr, with the project path written
`<project>`. `cli/tests/diagnostics.rs` runs the built `fsp` on every folder and compares. It also
checks that the message contains the text the troubleshooting skill's reference page quotes, and
that the page still quotes it, so a reworded message and an edited page cannot drift apart.

They are also the example of the [troubleshooting skill](../../../../skills/fespalier-troubleshooting/SKILL.md):
copy a folder, run `fsp check --project <folder>`, and read the message next to the page that
explains it.

| Case                         | What is wrong                                                           | Page (`skills/fespalier-troubleshooting/references/`) |
| ---------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------- |
| `folder-name-invalid`        | a route folder called `Hello World`                                     | `diagnostics-tree.md`                                 |
| `two-public-widgets`         | two public widget classes in one `page.dart`                            | `diagnostics-tree.md`                                 |
| `page-and-redirect`          | a `page.dart` and a `redirect.dart` in one folder (`old/`)              | `diagnostics-tree.md`                                 |
| `unreachable-in-group`       | `$a` outside a `(group)`, `$b` and `settings` inside it                 | `diagnostics-tree.md`                                 |
| `cant-fill-param`            | a required page parameter that is no segment                            | `diagnostics-binding.md`                              |
| `segment-type-mismatch`      | `$id` is a `String` in `data.dart` and an `int` in `page.dart`          | `diagnostics-binding.md`                              |
| `unknown-segment-type`       | a `Uri` segment                                                         | `diagnostics-binding.md`                              |
| `extra-not-nullable`         | `extra` declared non-nullable                                           | `diagnostics-binding.md`                              |
| `data-without-page`          | a `data.dart` with no `page.dart` or `layout.dart`                      | `diagnostics-data-and-hooks.md`                       |
| `data-without-ref`           | `data()` without `Ref ref` first                                        | `diagnostics-data-and-hooks.md`                       |
| `guard-wrong-return`         | `guard()` returns `int`                                                 | `diagnostics-data-and-hooks.md`                       |
| `form-without-forms-package` | a `form()` and no `fespalier_forms` under `dependencies:`               | `diagnostics-data-and-hooks.md`                       |
| `config-unknown-field`       | an unknown key in the `fespalier:` section (reported on stderr)         | `diagnostics-config-and-meta.md`                      |
| `app-without-router`         | an `app.dart` widget with no `router` parameter                         | `diagnostics-app-main.md`                             |
| `tabs-missing-branch`        | `tabs` leaves a branch out                                              | `diagnostics-layouts-and-navigators.md`               |

Run-time messages (`fespalier_auth`, `fespalier_tolgee`, `fespalier_cratestack`, ...) are not
`fsp` output and have no tree here. Some diagnostics have a page but no tree yet; add one the way
below.

## Regenerate

```sh
cd cli
FSP_UPDATE_GOLDEN=1 cargo test --test diagnostics   # rewrites every expected.txt
git diff tests/fixtures/diagnostics                 # read what changed
```

A changed message is a changed golden **and** a changed page: edit the page in the same commit.

## Add a case

1. Make `<case>/pubspec.yaml` and the files under `<case>/lib/app/` that trigger one diagnostic.
   (`name: demo` is enough; a `dependencies:` mapping matters only to the checks that read it, like
   the `fespalier_forms` one.)
2. Add it to `CASES` in `cli/tests/diagnostics.rs` with the reference page and the text it quotes.
3. Run the command above, and commit the new `expected.txt`.
