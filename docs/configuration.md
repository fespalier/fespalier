# Configuration

`fsp` needs no configuration. Everything below is optional, and lives in the `fespalier:` section of your
`pubspec.yaml`.

## The fespalier: section

These are the defaults, with the optional blocks commented out. `app_dir` and `output` are relative to
the project root and must be under `lib/`, and `output` must be a `.dart` file.

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
  # adapters: [my_tools]         # no default: packages that plug into the generated main() (since 0.9.0)
```

## Keys

| Key                  | Default                               | Values                                | Since | What it does                                                        | Read more                                                                            |
| -------------------- | ------------------------------------- | ------------------------------------- | ----- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `app_dir`            | `lib/app`                             | a path under `lib/`                   |       | the folder `fsp` reads                                              | [The fespalier: section](#the-fespalier-section)                                     |
| `output`             | `lib/app.g.dart`                      | a `.dart` path under `lib/`           |       | where `fsp gen` writes                                              | [The fespalier: section](#the-fespalier-section)                                     |
| `format`             | `false`                               | `true`, `false`                       |       | run `dart format` on the generated file                             | [format](#format)                                                                    |
| `output_manifest`    | none (the manifest lives in `output`) | a `.dart` path                        |       | write the route manifest to a library of its own                    | [meta, meta_unique and output_manifest](#meta-meta_unique-and-output_manifest)       |
| `meta`               | `optional`                            | `optional`, `required`                |       | whether every route needs a `meta.dart`                             | [meta, meta_unique and output_manifest](#meta-meta_unique-and-output_manifest)       |
| `meta_unique`        | none                                  | a list of `meta` fields               |       | no two routes may pass the same literal value                       | [meta, meta_unique and output_manifest](#meta-meta_unique-and-output_manifest)       |
| `case_sensitive`     | `true`                                | `true`, `false`                       |       | whether paths match by case                                         | [case_sensitive](#case_sensitive)                                                    |
| `remount`            | `never`                               | `never`, `on_segments`, `on_location` | 0.6.0 | when a page gets a fresh state because its URL changed              | [remount](#remount)                                                                  |
| `deferred`           | `false`                               | `true`, `false`                       | 0.7.0 | each page's code loads on demand                                    | [deferred](#deferred)                                                                |
| `data_retry`         | `inherit`                             | `inherit`, `none`                     |       | retries of a failed `data.dart`                                     | [data_retry, keep_previous and file_style](#data_retry-keep_previous-and-file_style) |
| `keep_previous`      | `true`                                | `true`, `false`                       |       | keep the previous value while a reload runs                         | [data_retry, keep_previous and file_style](#data_retry-keep_previous-and-file_style) |
| `push_updates_url`   | `false`                               | `true`, `false`                       | 0.6.0 | a `push`ed route's URL is in the address bar                        | [push_updates_url](#push_updates_url)                                                |
| `file_style`         | `snake`                               | `snake`, `kebab`                      |       | how `fsp init` and `fsp new` spell file names                       | [data_retry, keep_previous and file_style](#data_retry-keep_previous-and-file_style) |
| `links`              | none                                  | a map                                 | 0.5.0 | what `fsp links` writes                                             | [links](#links)                                                                      |
| `lints`              | `unknown_path: warning`               | `warning`, `error`, `off`             | 0.7.0 | how a string path that matches no route is reported                 | [lints](#lints)                                                                      |
| `semantics_ids`      | `false`                               | `true`, `false`                       | 0.7.0 | every page wears `Semantics(identifier: 'route:/...')`, for Maestro | [semantics_ids and maestro](#semantics_ids-and-maestro)                              |
| `scroll_restoration` | `false`                               | `true`, `false`                       | 0.8.1 | the browser's back and forward bring a page's scroll offsets back   | [scroll_restoration](#scroll_restoration)                                            |
| `telemetry`          | `false`                               | `true`, `false`                       | 0.8.1 | report navigations, guards, data, actions and deferred loads        | [telemetry](#telemetry)                                                              |
| `maestro`            | none                                  | a map                                 | 0.7.0 | what `fsp maestro` writes                                           | [semantics_ids and maestro](#semantics_ids-and-maestro)                              |
| `size`               | none                                  | a map                                 | 0.8.1 | what `fsp size` checks the web build against                        | [size](#size)                                                                        |
| `test`               | none                                  | a map                                 | 0.8.1 | what `fsp test` reads                                               | [test](#test)                                                                        |
| `main`               | `auto`                                | `auto`, `generated`, `manual`         | 0.8.1 | whether `fsp` writes the `main()` in `lib/app.main.g.dart`          | [main](#main)                                                                        |
| `tasks`              | none                                  | a map                                 | 0.9.0 | what `fsp dev`, `fsp build` and `fsp run` run                       | [tasks](#tasks)                                                                      |
| `adapters`           | none                                  | a list of package names               | 0.9.0 | packages that plug into the generated `main()`                      | [adapters](#adapters)                                                                |

### format

`format: true` runs `dart format` on the generated file (see [`fsp gen --format`](cli.md#the-generator)).

### case_sensitive

`case_sensitive: false` makes paths match in any case. A [`route.dart`](routing.md#case-and-trailing-slashes)
sets it per folder (see [Case and trailing slashes](routing.md#case-and-trailing-slashes)), and the same file
gives a folder [other spellings per locale](routing.md#localized-paths) with `paths`.

### remount

`remount` (since 0.6.0) is `never`, `on_segments` or `on_location`: when a page gets a fresh state
because its URL changed. A `route.dart` sets it per folder (see
[Remounting a page](navigation.md#remounting-a-page-remount)). Any other value is an error that lists the three.

### deferred

`deferred` (since 0.7.0) is `true` or `false`: whether each page's code loads on demand (`import ... deferred as`,
a chunk of its own on the web). A `route.dart` sets it per folder (see
[Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand)). A value that isn't a bool is an error.

### data_retry, keep_previous and file_style

`data_retry` and `keep_previous` are about `data.dart` failures and reloads; see
[Retries and reloads](data.md#retries-and-reloads). `file_style: kebab` makes `fsp init` and `fsp new`
write `not-found.dart` instead of `not_found.dart` (see [File names](file-kinds.md#file-names)).

### push_updates_url

`push_updates_url: true` (since 0.6.0) makes the generated `AppRoutes.router()` set go_router's
`GoRouter.optionURLReflectsImperativeAPIs`. On the web, a typed route's `push` then puts its URL in the
address bar (and in the browser's history) as `go` does, and back pops it.

- The generated code assigns the flag on every `router()` call, `true` or `false` (the default, go_router's
  own), so it is the same in every app and every test, wherever the router is built.
- go*router warns about the cost: that URL is all the browser keeps, so a reload or a deep link of it
  builds that route's \_own* stack, not the stack it was pushed onto. In fespalier every route is a typed
  path, so the URL is always a valid page.
- Without the key, `push` leaves the address bar on the page below; use
  [`go` or `replace`](navigation.md#the-url-as-state-of-and-copywith) for state that belongs in the URL.

### meta, meta_unique and output_manifest

- `meta: required` makes a route without a [`meta.dart`](routing.md#route-manifest-and-metadart) an error.
- `meta_unique` makes a duplicate value in it an error.
- `output_manifest` writes the route manifest to a library of its own (same section).

### links

`links:` is what [`fsp links`](cli.md#deep-links-and-a-sitemap-fsp-links) reads; only that command checks its values.

### lints

`lints:` (since 0.7.0) sets how [a string path that matches no route](cli.md#checking-string-paths) is
reported: `unknown_path` is `warning` (the default), `error` or `off`.

### semantics_ids and maestro

`semantics_ids` (since 0.7.0) and `maestro:` are about [Maestro](cli.md#maestro-flows-fsp-maestro): the first
changes the generated file, the second is read, and checked, only by `fsp maestro`.

### scroll_restoration

`scroll_restoration` (since 0.8.1) is `true` or `false`: whether each page is wrapped in a `PageStorage` that the
browser's back and forward buttons hand back (see [Scroll restoration](layouts.md#scroll-restoration)). A value
that isn't a bool is an error.

### size

`size:` (since 0.8.1) is what [`fsp size`](cli.md#web-chunk-sizes-fsp-size) checks the web build against; only that command checks its values.

### test

`test:` (since 0.8.1) is what [`fsp test`](cli.md#route-smoke-tests-fsp-test) reads, and only that command checks it.

### tasks

`tasks:` (since 0.9.0) is what [`fsp dev`, `fsp build` and `fsp run`](cli.md#tasks-commands-around-flutter-run) run: commands to run
before, next to and after `flutter run`. Only those commands check it; `fsp gen` never reports a mistake in it.

### main

`main` (since 0.8.1) is `auto`, `generated` or `manual`: whether `fsp` writes [`lib/app.main.g.dart`](app-startup.md),
with `AppMain`.

- `auto` writes it when the app folder's root has an `app.dart`, `startup.dart` or `splash.dart` (or, since
  0.9.0, when `adapters:` lists a package).
- `generated` always writes it.
- `manual` never writes it (and then those three files are not read).

Any other value is an error that lists the three:
``unknown variant `always`, expected one of `auto`, `generated`, `manual` ``. The file sits beside
`output`, with `.main.g.dart` in place of `.g.dart` (`lib/router/routes.g.dart` makes
`lib/router/routes.main.g.dart`); there is no key for the path, and `output_manifest` cannot be it.

### adapters

`adapters` (since 0.9.0) is a list of Dart package names that plug into the generated `main()`; see
[Adapters in the generated `main()`](adapters.md). The key makes `main: auto` write
`lib/app.main.g.dart`, and `main: manual` with it is an error.

### telemetry

`telemetry` (since 0.8.1) is `true` or `false`: whether the generated file tells fespalier where each guard,
data provider, action and deferred page is, and follows the router's navigations (see
[Telemetry](observability.md#telemetry)). A value that isn't a bool is an error.

The router's [`extraCodec`](navigation.md#restoring-extra-on-the-web) has no key: `lib/app/extra_codec.dart` is
found by its name, like the other files.

## Per-folder settings: route.dart

A `route.dart` in any folder sets, for that folder and below, what the pubspec sets for the whole app. It is read
from the source, never imported. Its constants:

- `const caseSensitive = <true or false>;`: whether paths match by case, [the nearest one winning](routing.md#case-and-trailing-slashes) over the pubspec's `case_sensitive`. See [Case and trailing slashes](routing.md#case-and-trailing-slashes).
- `const paths = {'fr': 'produits'};` in a static folder: its other spellings per locale. See [Localized paths](routing.md#localized-paths).
- `const nest = false;` beside a `page.dart` or `redirect.dart`: its route is a sibling of the page above, not a child. See [A sibling with a compound path](routing.md#a-sibling-with-a-compound-path).
- `const linkable = false;` (since 0.5.0): `fsp links` leaves this folder's routes and those below it out. See [Deep links and a sitemap](cli.md#deep-links-and-a-sitemap-fsp-links).
- `const remount = Remount.onSegments;` (since 0.6.0): when the pages in this folder and below get a fresh state because their URL changed. See [Remounting a page](navigation.md#remounting-a-page-remount).
- `const deferred = true;` (since 0.7.0): the pages in this folder and below load their code on demand. See [Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand).
- `const freshness = Freshness(staleTime: Duration(minutes: 5));` (since 0.8.1): the default for when the `data.dart` functions in this folder and below load again, a `data.dart`'s own over all. See [Freshness](data.md#freshness-staletime-resume-and-reconnect).

The full table of file kinds, with this row, is in [File kinds](file-kinds.md).
