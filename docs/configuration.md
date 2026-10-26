# Configuration

`fsp` needs no configuration. Everything below is optional, and lives in the `fespalier:` section of your
`pubspec.yaml`. Your app's own values (an API address per environment) are not here: they are `config/app.yaml`
([App configuration and profiles](app-config.md), since 0.24.0).

## The fespalier: section

These are the defaults, with the optional blocks commented out. `app_dir` and `output` are relative to
the project root and must be under `lib/`, and `output` must be a `.dart` file.

```yaml
fespalier:
  app_dir: lib/app
  output: lib/app.g.dart # a .g.dart: build_runner can delete it beside a lib/app.dart (since 0.17.0 fsp warns)
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
  # links:                        # no default: what `fsp links` writes (see below); `domains` is also AppRoutes.urlOf's host (since 0.16.0)
  #   domains: [shop.example.com]
  #   scheme: myshop
  #   scheme_host: true           # since 0.11.0; `false`: myshop:///path, no host
  #   paths: [/, /orders/*]       # since 0.11.0; default: every linkable route
  #   android_package: com.example.shop
  #   android_sha256: ["AB:CD:..."]
  #   ios_app_id: TEAMID.com.example.shop
  #   android_manifest: android/app/src/main/AndroidManifest.xml   # since 0.11.0; `fsp links` edits it
  #   ios_entitlements: ios/Runner/Runner.entitlements            # since 0.11.0; `fsp links` edits it
  #   flavors: {prod: {android_package: ..., android_sha256: [...], ios_app_id: ..., ios_entitlements: ...}}   # since 0.11.0, instead of the keys for one app above
  #   out: links                  # default; `false` (since 0.12.0): no sitemap and no .well-known, only the platform files (then android_sha256 is optional)
  semantics_ids: false # `true` (since 0.7.0): every page wears `Semantics(identifier: 'route:/...')`, for Maestro
  scroll_restoration: false # `true` (since 0.8.1): the browser's back and forward bring a page's scroll offsets back
  main: auto # `generated` | `manual` (since 0.8.1): whether `fsp` writes the main() in lib/app.main.g.dart
  telemetry: false # `true` (since 0.8.1): report navigations, guards, data, actions and deferred loads (see "Telemetry")
  otel: false # `true` (since 0.19.0): the generated main() starts otel_zone and installs FespalierOtel (see "otel")
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
  #   a11y: true                  # since 0.16.0; default false. Or a list: [tap_targets, labels, contrast]
  # tasks:                        # no default: what `fsp dev`, `fsp build` and `fsp run` run (since 0.9.0)
  #   dev:
  #     before: dart run build_runner build
  #     with:
  #       build_runner: dart run build_runner watch
  #   codegen: dart run build_runner build
  # adapters: [my_tools]         # no default: packages that plug into the generated main() (since 0.9.0)
  # adapters: auto               # since 0.23.0: every first-party adapter package under dependencies:
```

`output` is a `.g.dart` file by default, which `build_runner` can delete when a `lib/app.dart` is beside it (since 0.17.0: `fsp` warns, and `output: lib/routes.g.dart` is the way out; see [The generator](cli.md#the-generator)).

## Keys

| Key                  | Default                               | Values                                | Since  | What it does                                                                                                                      | Read more                                                                            |
| -------------------- | ------------------------------------- | ------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `app_dir`            | `lib/app`                             | a path under `lib/`                   |        | the folder `fsp` reads                                                                                                            | [The fespalier: section](#the-fespalier-section)                                     |
| `output`             | `lib/app.g.dart`                      | a `.dart` path under `lib/`           |        | where `fsp gen` writes                                                                                                            | [The fespalier: section](#the-fespalier-section)                                     |
| `format`             | `false`                               | `true`, `false`                       |        | run `dart format` on the generated file                                                                                           | [format](#format)                                                                    |
| `output_manifest`    | none (the manifest lives in `output`) | a `.dart` path                        |        | write the route manifest to a library of its own                                                                                  | [meta, meta_unique and output_manifest](#meta-meta_unique-and-output_manifest)       |
| `meta`               | `optional`                            | `optional`, `required`                |        | whether every route needs a `meta.dart`                                                                                           | [meta, meta_unique and output_manifest](#meta-meta_unique-and-output_manifest)       |
| `meta_unique`        | none                                  | a list of `meta` fields               |        | no two routes may pass the same literal value                                                                                     | [meta, meta_unique and output_manifest](#meta-meta_unique-and-output_manifest)       |
| `case_sensitive`     | `true`                                | `true`, `false`                       |        | whether paths match by case                                                                                                       | [case_sensitive](#case_sensitive)                                                    |
| `remount`            | `never`                               | `never`, `on_segments`, `on_location` | 0.6.0  | when a page gets a fresh state because its URL changed                                                                            | [remount](#remount)                                                                  |
| `deferred`           | `false`                               | `true`, `false`                       | 0.7.0  | each page's code loads on demand                                                                                                  | [deferred](#deferred)                                                                |
| `data_retry`         | `inherit`                             | `inherit`, `none`                     |        | retries of a failed `data.dart`                                                                                                   | [data_retry, keep_previous and file_style](#data_retry-keep_previous-and-file_style) |
| `keep_previous`      | `true`                                | `true`, `false`                       |        | keep the previous value while a reload runs                                                                                       | [data_retry, keep_previous and file_style](#data_retry-keep_previous-and-file_style) |
| `push_updates_url`   | `false`                               | `true`, `false`                       | 0.6.0  | a `push`ed route's URL is in the address bar                                                                                      | [push_updates_url](#push_updates_url)                                                |
| `file_style`         | `snake`                               | `snake`, `kebab`                      |        | how `fsp init` and `fsp new` spell file names                                                                                     | [data_retry, keep_previous and file_style](#data_retry-keep_previous-and-file_style) |
| `links`              | none                                  | a map                                 | 0.5.0  | what `fsp links` writes                                                                                                           | [links](#links)                                                                      |
| `lints`              | `unknown_path: warning`               | `warning`, `error`, `off`             | 0.7.0  | how a string path that matches no route is reported                                                                               | [lints](#lints)                                                                      |
| `semantics_ids`      | `false`                               | `true`, `false`                       | 0.7.0  | every page wears `Semantics(identifier: 'route:/...')`, for Maestro                                                               | [semantics_ids and maestro](#semantics_ids-and-maestro)                              |
| `scroll_restoration` | `false`                               | `true`, `false`                       | 0.8.1  | the browser's back and forward bring a page's scroll offsets back                                                                 | [scroll_restoration](#scroll_restoration)                                            |
| `telemetry`          | `false`                               | `true`, `false`                       | 0.8.1  | report navigations, guards, data, actions and deferred loads                                                                      | [telemetry](#telemetry)                                                              |
| `otel`               | `false`                               | `true`, `false`                       | 0.19.0 | the generated `main()` starts OpenTelemetry and installs `FespalierOtel`                                                          | [otel](#otel)                                                                        |
| `maestro`            | none                                  | a map                                 | 0.7.0  | what `fsp maestro` writes                                                                                                         | [semantics_ids and maestro](#semantics_ids-and-maestro)                              |
| `size`               | none                                  | a map                                 | 0.8.1  | what `fsp size` checks the web build against                                                                                      | [size](#size)                                                                        |
| `test`               | none                                  | a map                                 | 0.8.1  | what `fsp test` reads                                                                                                             | [test](#test)                                                                        |
| `main`               | `auto`                                | `auto`, `generated`, `manual`         | 0.8.1  | whether `fsp` writes the `main()` in `lib/app.main.g.dart`                                                                        | [main](#main)                                                                        |
| `tasks`              | none                                  | a map                                 | 0.9.0  | what `fsp dev`, `fsp build` and `fsp run` run                                                                                     | [tasks](#tasks)                                                                      |
| `adapters`           | none                                  | a list of package names, or `auto`    | 0.9.0  | packages that plug into the generated `main()`, or (`auto`, since 0.23.0) every first-party adapter package under `dependencies:` | [adapters](#adapters)                                                                |

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
Since 0.16.0 `fsp gen` also reads `domains`: the first one is the host of
[`AppRoutes.urlOf`](cli.md#urls-to-share-approutesurlof), and one that is not usable is a warning, never an error.
Since 0.11.0 it also takes `flavors:` (one app per build flavour, [Flavours](cli.md#flavours)), `scheme_host`
and `paths:` ([Host-less schemes and path patterns](cli.md#host-less-schemes-and-path-patterns)).
`android_manifest` (top level only) and `ios_entitlements` (per flavour, or flat for one app) make `fsp links` edit those files
([Editing AndroidManifest.xml and the entitlements](cli.md#editing-androidmanifestxml-and-the-entitlements));
`fsp links --check` in CI is [Links in CI](cli.md#links-in-ci).

### lints

`lints:` (since 0.7.0) sets how [a string path that matches no route](cli.md#checking-string-paths) is
reported: `unknown_path` is `warning` (the default), `error` or `off`.

### semantics_ids and maestro

`semantics_ids` (since 0.7.0) and `maestro:` are about [Maestro](route-tests.md#maestro-flows-fsp-maestro): the first
changes the generated file, the second is read, and checked, only by `fsp maestro`.

### scroll_restoration

`scroll_restoration` (since 0.8.1) is `true` or `false`: whether each page is wrapped in a `PageStorage` that the
browser's back and forward buttons hand back (see [Scroll restoration](layouts.md#scroll-restoration)). A value
that isn't a bool is an error.

### size

`size:` (since 0.8.1) is what [`fsp size`](cli.md#web-chunk-sizes-fsp-size) checks the web build against; only that command checks its values.

### test

`test:` (since 0.8.1) is what [`fsp test`](route-tests.md#route-smoke-tests-fsp-test) reads, and only that command checks it.
`a11y` (since 0.16.0) is `true`, `false` or a list of `tap_targets`, `labels` and `contrast`: whether each test also
checks [Flutter's accessibility guidelines](route-tests.md#route-smoke-tests-fsp-test) once its page is on screen.

### tasks

`tasks:` (since 0.9.0) is what [`fsp dev`, `fsp build` and `fsp run`](cli.md#tasks-commands-around-flutter-run) run: commands to run
before, next to and after `flutter run`. Only those commands check it; `fsp gen` never reports a mistake in it. Since 0.22.0 the editor plugins list and run them ([Tasks in your editor](cli.md#tasks-in-your-editor)). Since 0.24.0 `fsp dev` and `fsp build` also give their commands `FSP_PROFILE` and `FSP_CONFIG_*` ([App configuration: tasks](app-config.md#tasks-and-the-configuration)).

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
`lib/app.main.g.dart`. Since 0.11.0 it also puts `AppAdapters` in `lib/app.g.dart`, whatever `main:` says, so
`main: manual` with it is fine (it was an error before): your own `main()` calls `AppAdapters`
([With `main: manual`](adapters.md#with-main-manual-appadapters)).

`adapters: auto` (since 0.23.0) is the list of every first-party adapter package under `dependencies:`, in place of one you write: `fespalier_analytics`, `fespalier_download`, `fespalier_launch` and `fespalier_push`, in the order `dependencies:` lists them (the first is the outermost, and only `launch()`'s first answer depends on the order). A package of your own is never taken, because `fsp` reads no package to find out: list it. It is opt-in, because each of these needs its `configure` call in `main()` ([Adapters that need your code](adapters.md#adapters-that-need-your-code)), and an unconfigured one reports an error. With none of them in `dependencies:`, `auto` is no adapters at all. `auto` written inside a list is an error with its own message: `` `fespalier.adapters` lists `auto`, which is not a package: write `adapters: auto` on its own (since 0.23.0) for every first-party adapter package under `dependencies:`, or list the packages ``. `fsp doctor` prints what `auto` found, one row per adapter, so you can see it and paste it into a list.

### telemetry

`telemetry` (since 0.8.1) is `true` or `false`: whether the generated file tells fespalier where each guard,
data provider, action and deferred page is, and follows the router's navigations (see
[Telemetry](observability.md#telemetry)). A value that isn't a bool is an error.

The router's [`extraCodec`](navigation.md#restoring-extra-on-the-web) has no key: `lib/app/extra_codec.dart` is
found by its name, like the other files.

### otel

`otel` (since 0.19.0) is `true` or `false`: whether the generated `main()` starts `otel_zone` and installs `FespalierOtel`, so the app writes no OpenTelemetry code ([the generated wiring](observability.md#opentelemetry-from-the-generated-main)). It needs `telemetry: true`, `fespalier_otel` and `otel_zone` under `dependencies:`, and `main` not `manual`. `fsp` checks each one, and a pubspec that breaks one of these is refused with its message (every command that reads the config stops):

- `` `fespalier.otel` starts OpenTelemetry for what `telemetry: true` reports, and `telemetry` is not `true`; set `telemetry: true` too ``
- `` `fespalier.otel` makes the generated main() start otel_zone, and `main: manual` writes no main(); wire otel_zone in your own main() (docs/observability.md) and remove `otel: true`, or set `main: auto` ``
- `` `fespalier.otel` needs `fespalier_otel` under `dependencies:` in pubspec.yaml (next to fespalier, at the same git ref): the generated main() imports it ``
- `` `fespalier.otel` needs `otel_zone` under `dependencies:` in pubspec.yaml (a git dependency pinned to a commit, v0.8.1 or later: docs/observability.md has the lines): the generated main() imports it ``

An app that does not set it keeps its own wiring, as [OpenTelemetry with otel_zone](observability.md#opentelemetry-with-otel_zone) shows.

## Completion and checks in your editor

Since 0.23.0 the editor plugins complete and check the `fespalier:` section of `pubspec.yaml`: its keys, the values each takes, a description on hover, and a mistake highlighted in the file. Each plugin gives the editor one schema for the whole file, the output of [`fsp schema --pubspec`](cli.md#fsp-schema). An editor applies one schema to a file, so a schema for the section alone would replace the one the JSON Schema Store gives `pubspec.yaml`, and with it the store's checks on the rest of the file (the dependencies, the SDK constraints). The schema is the one of the `fsp` the plugin was built with, so a key that a newer `fsp` added reads as unknown in the editor until the plugin is rebuilt.

- **VS Code** completes and checks the section through the [YAML extension](https://marketplace.visualstudio.com/items?itemName=redhat.vscode-yaml) (`redhat.vscode-yaml`), which the fespalier extension adds its schema to. The store's checks stay on the rest of the file. Without the YAML extension nothing is completed, and nothing changes: saving `pubspec.yaml` still runs `fsp check`, which stops on an unknown key or a value of the wrong type in the section (the status bar shows `fespalier: failed`, and the message is in the fespalier output). It does not read `tasks:`, nor the values inside `links:`, `maestro:`, `size:` and `test:`: only their own commands do, and [`fsp doctor`](cli.md#fsp-doctor) checks them all.
- **IntelliJ IDEA and Android Studio** complete and check the section through the JSON support the IDE bundles (its JSON plugin), so there is nothing to install. A schema you map by hand for `pubspec.yaml` still wins over the plugin's.
- **Offline**, the YAML extension cannot load the store's schema, which the fespalier schema refers to: it shows one warning at the top of `pubspec.yaml` (`Problems loading reference 'https://www.schemastore.org/pubspec.json'`), and it validates nothing in the file. Turning the store off (`yaml.schemaStore.enable: false`) does not avoid it, because the reference is the fespalier schema's own (UNCHECKED, below). In IntelliJ the section should still complete with remote schemas off (UNCHECKED, below).
- **Other editors** (Neovim, Helix, Zed, or any editor that runs the YAML language server): write the schema beside the project, and map it to `pubspec.yaml` in the server's `yaml.schemas` setting:

  ```sh
  fsp schema --pubspec > .fespalier-pubspec.schema.json
  ```

  ```json
  { "yaml.schemas": { "./.fespalier-pubspec.schema.json": "pubspec.yaml" } }
  ```

  A `yaml-language-server: $schema=` modeline at the top of the file works the same way, if it points at the `--pubspec` output (a path or a URL of it). Never point one at the output of `fsp schema` without `--pubspec`: it is a schema for the section alone, and it would replace the store's for the whole file.

- **Two readings are stricter than `fsp`'s**, on purpose. An empty key is a type error in the editor: `app_dir:` with no value. `fsp` reads it as not set, but it is almost always unfinished typing, so the schema refuses it (`fespalier:` on its own, with no keys under it, is accepted). And a number or a boolean where text is expected (`meta_unique: [true]`, `skip: [404]`) is a type error: `fsp` reads the scalar's text, which is almost always a mistake. Everything else `fsp` takes, the schema takes.

**UNCHECKED:** the completion, the hover and the squiggles in a real VS Code or IntelliJ window, and the offline warning with the store turned off. CI runs the YAML language server that VS Code uses, and a headless IntelliJ; it does not run either editor.

## Per-folder settings: route.dart

A `route.dart` in any folder sets, for that folder and below, what the pubspec sets for the whole app. Each constant is optional:

- `const caseSensitive = <true or false>;`: whether paths match by case. See [Case and trailing slashes](routing.md#case-and-trailing-slashes).
- `const paths = {'fr': 'produits'};` in a static folder: its other spellings per locale. See [Localized paths](routing.md#localized-paths).
- `const nest = false;` beside a `page.dart` or `redirect.dart`: its route is a sibling of the page above, not a child. See [A sibling with a compound path](routing.md#a-sibling-with-a-compound-path).
- `const linkable = false;` (since 0.5.0): `fsp links` leaves this folder's routes and those below it out. See [Deep links and a sitemap](cli.md#deep-links-and-a-sitemap-fsp-links).
- `const remount = Remount.onSegments;` (since 0.6.0): when the pages in this folder and below get a fresh state because their URL changed. See [Remounting a page](navigation.md#remounting-a-page-remount).
- `const deferred = true;` (since 0.7.0): the pages in this folder and below load their code on demand. See [Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand).
- `const freshness = Freshness(staleTime: Duration(minutes: 5));` (since 0.8.1): the default for when the `data.dart` functions in this folder and below load again, a `data.dart`'s own over all. See [Freshness](data.md#freshness-staletime-resume-and-reconnect).

**Rules for every constant.**

- The file is read from the source, never imported or run, so a value must be a literal (`true` or `false`, a map literal of string literals, `Remount.…` written out, a `Freshness(...)` call). Anything else, or the same constant twice, is an error with a code frame.
- The nearest `route.dart` wins over the parent's and over the pubspec. `(group)` folders and folders without a page pass a value on, and the file needs no page beside it (unlike `meta.dart`, which is per route and never inherited).
- It can sit at the root of the app folder, where it replaces the pubspec's value for the whole app.
- It adds or removes no route: `paths` only spells a folder's URL more than one way.

The full table of file kinds, with this row, is in [File kinds](file-kinds.md).
