# Diagnostics: config, `meta.dart`, `route.dart`, localized paths and the CLI

As of v0.4.0 (`cli/src/config.rs`, `resolve.rs`, `locale.rs`, `manifest.rs`, `main.rs`,
As of v0.4.0 (`cli/src/config.rs`, `resolve.rs`, `locale.rs`, `manifest.rs`, `main.rs`,
`init.rs`, `scaffold.rs`; since 0.7.0 also `lint.rs` and, for the `fsp maestro` section, `maestro.rs`). Messages are quoted as `fsp` prints them.

## The `fespalier:` section of `pubspec.yaml`

These are **not** diagnostics with a code frame: `fsp` prints the pubspec path, then the
message, and exits 1.

| Message                                                                                                                                                                                                                                                                                                                        | Cause and fix                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ``invalid pubspec.yaml: fespalier: unknown field `nope`, expected one of `app_dir`, `output`, `format`, `output_manifest`, `meta`, `meta_unique`, `case_sensitive`, `remount`, `deferred`, `data_retry`, `keep_previous`, `push_updates_url`, `file_style`, `links`, `lints`, `semantics_ids`, `maestro` at line 25 column 3`` | An unknown (or misspelled) key: the section rejects them                                                                                                      |
| ``invalid pubspec.yaml: fespalier.remount: unknown variant `onSegments`, expected one of `never`, `on_segments`, `on_location` at line 25 column 12``                                                                                                                                                                          | `remount` (since 0.6.0) is written in snake case in the pubspec (`on_segments`); in a `route.dart` it is the Dart enum (`Remount.onSegments`)                 |
| ``invalid pubspec.yaml: fespalier.data_retry: unknown variant `maybe`, expected `inherit` or `none` at line 25 column 15``                                                                                                                                                                                                     | Wrong enum value (`file_style`: `snake` or `kebab`)                                                                                                           |
| `` `fespalier.app_dir` must be a path under lib/ (it is imported as package code), got `app` ``                                                                                                                                                                                                                                | `app_dir` and `output` live under `lib/`                                                                                                                      |
| `` `fespalier.output` must be a .dart file, got `lib/x.txt` ``                                                                                                                                                                                                                                                                 |                                                                                                                                                               |
| `` `fespalier.output_manifest` and `fespalier.output` are the same file (`lib/app.g.dart`); leave `output_manifest` out to keep the manifest in `output` ``                                                                                                                                                                    |                                                                                                                                                               |
| `invalid pubspec.yaml: fespalier.push_updates_url: invalid type: string "sometimes", expected a boolean at line 4 column 21`                                                                                                                                                                                                   | A boolean key (`format`, `case_sensitive`, `keep_previous`, `push_updates_url` since 0.6.0, `semantics_ids` since 0.7.0) given anything but `true` or `false` |
| `` `fespalier.meta` must be `required` or `optional`, got `always` ``                                                                                                                                                                                                                                                          |                                                                                                                                                               |
| `` `fespalier.meta_unique` lists argument names of `meta`, e.g. `[code, slug]`; `a-b` is not one ``                                                                                                                                                                                                                            | Names must be identifiers                                                                                                                                     |

## `fsp links` (since 0.5.0)

The `links:` values are checked only by `fsp links` (`fsp gen` and `fsp check` read the section
but never look at its values); an unknown key under `links:` is an `invalid pubspec.yaml: fespalier.links: unknown
field ...` error everywhere, like any other. These are printed without a code frame, and exit 1:

| Message                                                                                                                                                                                                                                                               | Cause and fix                                                                                      |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| ``no `links:` in the `fespalier:` section of pubspec.yaml; add the domains the app opens, e.g. ...``                                                                                                                                                                  | `fsp links` with no `links:` section                                                               |
| `` `fespalier.links.domains` is required: list the host names the app opens, e.g. `domains: [shop.example.com]` ``                                                                                                                                                    | No `domains`, or an empty list                                                                     |
| `` `fespalier.links.domains`: `https://x.com/` is not a host name; write it as `shop.example.com`, with no scheme, port or path (an international name in punycode) ``                                                                                                | A scheme, port or path, one label (`shop`), or characters beyond ASCII                             |
| `` `fespalier.links.domains`: the sitemap's URLs are on the first domain, so it can't be the wildcard `*.example.com`; list a host name first ``                                                                                                                      | A `*.` domain first                                                                                |
| `` `fespalier.links.android_package` needs `android_sha256`: assetlinks.json lists the fingerprints of the certificates the app is signed with (...) `` and `` `fespalier.links.android_sha256` needs `android_package`: the application id assetlinks.json is for `` | One without the other                                                                              |
| `` `fespalier.links.android_package` must be an Android application id like `com.example.shop` (two or more parts separated by dots, each starting with a letter, with letters, digits and `_`), got `shop` ``                                                        | A one-part id, a part starting with a digit, a `-`                                                 |
| `` `fespalier.links.android_sha256`: `AB:CD` is not a SHA-256 fingerprint; write 32 hex pairs separated by `:`, as `keytool -list -v` prints them (`AB:CD:...`) ``                                                                                                    | A SHA-1, a truncated or non-hex value                                                              |
| `` `fespalier.links.ios_app_id` must be the Team ID, a dot and the bundle id, like `ABCDE12345.com.example.shop` (the Team ID is 10 upper-case letters and digits), got `com.example.shop` ``                                                                         | The bundle id alone                                                                                |
| `` `fespalier.links.scheme` must be a custom URL scheme in lower case, like `myshop` (letters, digits, `+`, `-` and `.`, starting with a letter), not `http` or `https`, got `MyShop` ``                                                                              |                                                                                                    |
| `` `fespalier.links.scheme` is written into the Android and iOS files: set `android_package` (with `android_sha256`) or `ios_app_id` too ``                                                                                                                           | A scheme with no platform                                                                          |
| `` `fespalier.links.out` must be a folder inside the project (relative, no `..`), got `../x` ``                                                                                                                                                                       | An absolute path, `..`, or an empty value                                                          |
| `N error(s); no links`                                                                                                                                                                                                                                                | The route tree has errors: `fsp links` prints them first, like `fsp routes`                        |
| `` no route can be linked: the app has no page, or every folder says `const linkable = false;` ``                                                                                                                                                                     | Nothing to list                                                                                    |
| `links/web/sitemap.xml is missing` / `... is out of date` / `... is not wanted by this config`, then `` N file(s) out of date; run `fsp links` ``                                                                                                                     | `fsp links --check`: the files on disk differ from what `fsp links` would write; run it and commit |

## String paths (`lints: unknown_path`, since 0.7.0)

`fsp gen`, `check` and `watch` read the string literals your code gives the router
(`context.go('/x')`, `push`, `pushReplacement`, `replace`, `RouteLink(uri: Uri.parse('/x'))`,
`initialLocation:`) in every Dart file under `lib/`, and report a path that matches **no
route**. The diagnostic has a code frame, in the file it is about (`lib/screens/home.dart`,
or `products/page.dart` for a file in the app folder), is a **warning** by default, and ends
in `[unknown_path]`: the id `// fsp:ignore` and `lints:` take. It does not run when the route
tree itself has errors, so fix those first. The rules are in `fespalier-routing`,
`references/typed-routes-and-extra.md`, "String paths".

| Message                                                                                                                                       | Cause and fix                                                                                                                                                                                                      |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| ``no route matches `/nope/x`, so it shows not-found [unknown_path]``                                                                          | A literal path with no query, no `$`, and no route that fits it (a typo, a renamed or deleted folder, a catch-all that needs a part). Fix the path, use the typed route, or `// fsp:ignore unknown_path`           |
| ``no route matches `/prodcts/2`, so it shows not-found; did you mean `/products/2`? [unknown_path]``                                          | The same, and exactly one **static** segment is within a couple of typos of a route's spelling (any localized one). The suggestion keeps the rest of the literal, query and fragment included. Take it, or silence |
| ``no route starts with `/prodcts/`, so `/prodcts/$id` shows not-found whatever it interpolates [unknown_path]``                               | A path with `$` whose complete segments before the first `$` are the start of no route (`/prodcts/` here). Segments after the `$` are **not** checked: a value can be empty or hold a `/`                          |
| ``1 error(s) in string paths (`lints: unknown_path: error`)``                                                                                 | `lints: unknown_path: error` and `fsp check` found paths (the `N` counts them). They print as `error:`. Fix them, or put the level back to `warning`                                                               |
| ``1 error(s) in string paths (`lints: unknown_path: error`); lib/app.g.dart is up to date``                                                   | The same from `fsp gen` and `fsp watch`: the generated file **was written** (the lint does not stop it, so `watch` keeps regenerating) and the command still exits 1. With `output_manifest` both files are named  |
| ``invalid pubspec.yaml: fespalier.lints.unknown_path: unknown variant `warn`, expected one of `off`, `warning`, `error` at line 4 column 19`` | The level is `off`, `warning` or `error`                                                                                                                                                                           |
| ``invalid pubspec.yaml: fespalier.lints: unknown field `nope`, expected `unknown_path` at line 4 column 5``                                   | Only `unknown_path` is a lint so far                                                                                                                                                                               |
| `invalid pubspec.yaml: fespalier.lints: invalid type: string "error", expected struct LintsConfig at line 3 column 10`                        | `lints:` is a map (`lints: {unknown_path: error}`), not a level                                                                                                                                                    |

**Silencing.** `// fsp:ignore unknown_path` on the line above the path or after it, or above a
multi-line call (a comment on its own line covers the call that starts on the next line; one
after code covers its own line); `// fsp:ignore-file unknown_path` for the whole file. Text
after the id is a free comment (`-- gift cards aren't built yet`). Another id does not silence it.

**Not checked, so no diagnostic and no false comfort:**

- **Segment types.** `/products/abc` matches `products/$id` although `id` is an `int`; it
  shows not-found at run time (`BadSegment`).
- **Anything after the first `$`**, and a path that starts with one (`'$base/x'`), is built
  rather than a literal; a relative path (`'details'`), a URL, a `..` and a malformed `%` are
  skipped.
- **Files outside `lib/`.** `test/`, `integration_test/` and `bin/` are not read (tests go to
  unknown paths on purpose), nor are `*.g.dart` and the generated outputs.
- **A mount point it cannot read.** `AppRoutes.mount(at: base)`, or two different literals,
  turn the whole check **off** for the run, silently. Under `AppRoutes.mount(at: '/shop')`
  only paths below `/shop` are looked at; with the tree at `/` a host router's own string
  paths are reported (silence them or `lints: {unknown_path: off}`).
- **Calls it does not recognise:** a bare `go('/x')`, `goNamed`, `Navigator.pushNamed`,
  `AppRoutes.match`, `matchUrl`, `dataAt`, `preload`, a Dart 3.10 dot shorthand
  (`uri: .parse('/x')`), a path in a variable or built with `+`.

## `fsp maestro` (since 0.7.0)

`fsp maestro` reads the `maestro:` section of `fespalier:` and **checks its values only when it
runs**: `fsp gen` and `fsp check` read the section but never look at its values, though an unknown
key under `maestro:` or a value of the wrong type is an error everywhere, like any other. These are
printed without a code frame and exit 1 (the pubspec path comes first on the serde ones):

| Message                                                                                                                                                                   | Cause and fix                                                                                     |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| ``invalid pubspec.yaml: fespalier.maestro: unknown field `appid`, expected one of `app_id`, `url`, `link`, `out`, `guard_flow`, `timeout`, `samples` at line 5 column 5`` | An unknown key under `maestro:`, checked by every command                                         |
| `invalid pubspec.yaml: fespalier.maestro.timeout: invalid type: string "soon", expected i64 at line 6 column 14`                                                          | `timeout` is a whole number (a decimal says ``invalid type: floating point `1.5`, expected i64``) |
| ``invalid pubspec.yaml: fespalier.maestro.samples: invalid type: integer `3`, expected a map at line 6 column 14``                                                        | `samples` is a map of folder to value                                                             |
| ``invalid pubspec.yaml: fespalier.maestro: invalid type: integer `3`, expected struct MaestroConfig at line 4 column 12``                                                 | `maestro:` is a map                                                                               |

The messages of `fsp maestro` itself, in the order it can raise them:

| Message                                                                                                                                                                     | Cause and fix                                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| ``no `maestro:` in the `fespalier:` section of pubspec.yaml; say what the flows open, e.g. ...``                                                                            | `fsp maestro` with no `maestro:` section; the message goes on with an example block (`semantics_ids: true`, `maestro:`, `app_id: com.example.shop`) |
| `` `fsp maestro` finds each page by its semantics identifier: set `semantics_ids: true` in the `fespalier:` section of pubspec.yaml, then run `fsp gen` ``                  | A `maestro:` section without `semantics_ids: true`: no page has an identifier for a flow to wait for. Set it, run `fsp gen`, then `fsp maestro`     |
| `` `fespalier.maestro` needs `app_id` (Android and iOS) or `url` (the web): what each flow's `appId:` or `url:` is ``                                                       | Neither key (an empty `maestro: {}` too)                                                                                                            |
| `` `fespalier.maestro` takes `app_id` or `url`, not both: a flow is for Android and iOS or for the web ``                                                                   | Both keys: a flow is for one of the two, so keep one                                                                                                |
| `` `fespalier.maestro.app_id` must be an application or bundle id like `com.example.shop`, or a Maestro variable like `${APP_ID}`, got `shop` ``                            | Not two or more dot-separated parts starting with a letter (letters, digits, `_`, `-`), and not a whole `${NAME}` variable                          |
| `` `fespalier.maestro.url` must be an http or https URL like `http://localhost:8080`, or a Maestro variable like `${URL}`, got `localhost` ``                               | No `http://` or `https://`, no host, or whitespace, `?` or `#` in it                                                                                |
| `` `fespalier.maestro.link` must be a URL like `myshop://shop.example.com` or `http://localhost:8080/#`, with no query, or a Maestro variable like `${LINK}`, got `nope` `` | Not `<scheme>://...`, or a query, or a `#` that is not the last character                                                                           |
| `` `fespalier.maestro.link` is required with `app_id` when there is no `links:` section: write what a route's path goes after, e.g. `link: myshop://shop.example.com` ``    | An app target has no `link:` and nothing in `links:` to take one from. (With a `links:` section, its own errors are reported instead)               |
| `` `fespalier.maestro.out` must be a folder inside the project (relative, no `..`), got `../x` ``                                                                           | An absolute path, `..`, a drive letter or an empty value                                                                                            |
| `` `fespalier.maestro.guard_flow` must be a .yaml or .yml file inside the project (relative, no `..`), got `x.json` ``                                                      | Not a `.yaml` or `.yml` file inside the project                                                                                                     |
| `` `fespalier.maestro.timeout` is in milliseconds, from 1000 to 600000, got `5` ``                                                                                          | A whole number outside 1000 to 600000 (a string or a decimal is serde's `invalid type` instead)                                                     |
| `` `fespalier.maestro.samples`: the value of `a` must be a text, a number, a boolean or a list of them ``                                                                   | A sample that is empty (`~`), a map or a nested list                                                                                                |
| `N error(s); no flows`                                                                                                                                                      | The route tree has errors: `fsp maestro` prints them first, like `fsp links`                                                                        |
| `` `fespalier.maestro.guard_flow`: .maestro/sign-in.yaml does not exist ``                                                                                                  | `guard_flow` names a file that is not in the project                                                                                                |
| `` `fespalier.maestro.samples`: `nope/$id` is not a folder of lib/app; write it as `fsp routes` prints it, without `/page.dart` (`products/$id`) ``                         | A key that is not a folder of the app (a typo, the `/page.dart` left on, a localized spelling)                                                      |
| `` `fespalier.maestro.samples`: `about` is not a `$segment` folder; samples give the values of dynamic segments ``                                                          | A key for a static folder or a `(group)`                                                                                                            |
| `` `fespalier.maestro.samples`: `p/$id` is one segment; give one value, not a list ``                                                                                       | A list for a `$id` folder; only a catch-all takes one                                                                                               |
| `` `fespalier.maestro.samples`: `p/$id` is a `int` segment, and `abc` is not one ``                                                                                         | A value the segment's type can't parse (`int`, `double`, `num`, `bool`, or the element of a `List`; for a list the offending part is named)         |
| `` `fespalier.maestro.samples`: `c/$$rest` is a catch-all that needs at least one part ``                                                                                   | `[]` for a `$$rest` (a `$$$rest` may be empty)                                                                                                      |
| `` `fespalier.maestro.samples`: `p/$id` is empty; a segment can't be ``                                                                                                     | An empty string, or an empty part in a catch-all's list                                                                                             |
| `two routes would write .maestro/routes/x_route.yaml: /a and /b`                                                                                                            | Two routes whose class names snake-case to one file (a defensive check; route class names are unique)                                               |
| `no route has a page: there is nothing for a flow to open`                                                                                                                  | Nothing was written and nothing was skipped: no page, and no redirect either                                                                        |

A route that gets no flow is **not** an error. It is printed, on every run and with `--check`, and
the run still succeeds:

| Printed                                                                                                               | Meaning                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `skipped /old: a redirect, with no page to see`                                                                       | A `redirect.dart` route has no page to see. Not an error; no flow                                                         |
| ``skipped /secret: `const linkable = false;`, so `fsp links` does not open the app at it``                            | With `app_id` only: the route is not one the app can be opened at. A `url:` target writes it                              |
| `` skipped /products/:id: no sample for products/$id in `fespalier.maestro.samples` ``                                | Add `products/$id: 1` to `samples`. The folder named is the first without one                                             |
| ``skipped /checkout: guarded by checkout/guard.dart; set `fespalier.maestro.guard_flow` to a flow that gets past it`` | Write a flow that signs in and name it as `guard_flow`. The guards are listed outermost first, relative to the app folder |

What `--check` and a write print:

| Printed                                                                                                                                                                         | Meaning                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `.maestro/routes/home_route.yaml is missing` / `... is out of date` / `... is no longer a route's flow`, then ``1 flow(s) out of date; run `fsp maestro` ``                     | `fsp maestro --check`: a flow on disk differs from what `fsp maestro` would write, or one is left of a route that is gone. Run `fsp maestro` and commit. A skip never fails it |
| `✓ maestro: 5 flows in .maestro/routes are up to date`                                                                                                                          | `--check` passed                                                                                                                                                               |
| `wrote .maestro/routes/home_route.yaml` and `removed ...` (each indented by two spaces), then `✓ maestro: 5 flows in .maestro/routes (5 written, 0 unchanged); 1 route skipped` | `fsp maestro` wrote, and removed the flows it wrote that no route needs. The `; N route(s) skipped` ending is only there when there were skips                                 |

A page that is never found by a flow that the files say should find it is not one of these. Check,
in order: `semantics_ids: true` is in the pubspec **and `fsp gen` ran since** (the identifier is in
`lib/app.g.dart`); the flow's `id:` is `route:<pattern>` and the page is the _top_ one (not a page
underneath, not `loading.dart`, `error.dart` or `not_found.dart`); on the web the app is served at the
flow's `url` and a hash-strategy app has `link: .../#`; and that Maestro's `id:` selector matches
Flutter's `Semantics(identifier:)` on the web and on iOS has **not been verified** in this repository.

## The command line

| Message                                                                                                                                   | Cause and fix                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `no pubspec.yaml here or above; pass --project`                                                                                           | Run inside the project, or `--project <dir>`                                  |
| ``<project>/lib/app not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)``                                            | No app folder yet                                                             |
| ``no pubspec.yaml in <dir>; run `fsp init` inside a Flutter project or pass --project``                                                   | `fsp init` needs a `pubspec.yaml`                                             |
| `` pubspec.yaml has no `name:` ``                                                                                                         | `fsp init` needs the package name for the `main.dart` it prints               |
| `N error(s); lib/app.g.dart left unchanged`                                                                                               | The summary line after the diagnostics above: the **old** file is still there |
| `N error(s); no route table`                                                                                                              | `fsp routes` refuses to print while there are errors                          |
| `nothing to create: a (group) folder has no page; also pass --action, --layout, --loading, --error, --not-found, --guard or --transition` | `fsp new '(group)'` with no flag (or `--no-page` alone)                       |
| ``--name `x` names the route class `xRoute`, so it must be UpperCamelCase (letters, digits, `_`), e.g. `KycShopName` ``                   | `fsp new --function --name`                                                   |
| `a catch-all folder can't have a not_found.dart: it matches every URL below it, so none is unknown`                                       | `fsp new 'docs/[...rest]' --not-found`                                        |
| `nothing to create`                                                                                                                       | Every file `fsp new` would write already exists (`skip  ... (exists)`)        |
| `` `fsp new` created: ... Fix or delete them, then run `fsp gen`. ``                                                                      | The scaffold was written but `gen` then failed: read the errors above it      |

`fsp init` and `fsp new` **never overwrite**: they print `skip  lib/app/page.dart (exists)`.
`format: true` without `dart` on `PATH` is a **warning** (``warning: not formatting ...: `dart` is not
on PATH``) and the unformatted code is written.

## `dart run fespalier`

The launcher's messages start `fespalier:`.

| Message                                                                                                                       | Cause and fix                                                                                        |
| ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `fsp <version> isn't cached and the download failed (offline?); run once online or set FSP_BINARY`                            | Nothing cached and no network; run once online, or build `fsp` and set `FSP_BINARY`                  |
| `<url> answered HTTP 404 (does this release exist?)`                                                                          | The package's version has no release (a branch build)                                                |
| `checksum mismatch for <archive>: expected ..., got ...`                                                                      | The download does not match the pin inside the package: do not bypass it; retry, or use `FSP_BINARY` |
| `warning: this package has no pinned checksums for fsp <v> (a development build); checking the release's own .sha256 instead` | A package built from a branch                                                                        |
| `FSP_BINARY is set to <path>, which does not exist`                                                                           |                                                                                                      |
| ``need `tar` on PATH to unpack <archive>``                                                                                    |                                                                                                      |
| ``cannot locate package:fespalier (run `flutter pub get`?)``                                                                  | No resolved package                                                                                  |
| ``no fsp binary is published for <abi>. Build it with `cargo install ...` and point FSP_BINARY at it.``                       |                                                                                                      |

## `meta.dart`

| Message                                                                                                                                                                                       | Cause and fix                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `` expected `const meta = <a const expression>;` ``                                                                                                                                           | The file has no `meta` variable                                                         |
| `` `meta` is declared twice ``                                                                                                                                                                |                                                                                         |
| `` `meta` must be `const` (the route manifest lists it in a const list): write `const meta = ...;` ``                                                                                         | `final meta` or a getter                                                                |
| warning `meta.dart describes a route, but this folder has no page.dart or redirect.dart; it is ignored`                                                                                       |                                                                                         |
| `` `a/` has no meta.dart, and `fespalier: meta: required` in pubspec.yaml wants one per route: `const meta = ...;` ``                                                                         | `meta: required` in the pubspec (the root route says `the app folder has no meta.dart`) |
| `` `code: 'X'` is also in a/meta.dart; `meta_unique: [code, slug]` in pubspec.yaml wants every route's `code` to differ ``                                                                    | Two routes pass the same **literal**; expressions and omitted arguments are skipped     |
| warning `` `meta_unique` in pubspec.yaml lists `slug`, but no meta.dart passes a literal `slug:` to its constructor call (`const meta = Meta(slug: 'x');`), so there is nothing to compare `` | A typo in `meta_unique`, or no literals                                                 |

## `route.dart`

| Message                                                                                                                                                                                                                                                                              | Cause and fix                                                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `` expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;`, `const deferred = true;` or `const freshness = Freshness(staleTime: Duration(minutes: 5));` `` | A `route.dart` with none of the seven (0.7.0 named six, without `freshness`; 0.6.0 named five, without `deferred`; 0.5.0 named four, before it the first two only) |
| `` `caseSensitive` is declared twice ``                                                                                                                                                                                                                                              |                                                                                                                                                                    |
| `` `caseSensitive` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it ``                                                                                                                                                                           | `final caseSensitive = flag;`                                                                                                                                      |

`const linkable = false;` (since 0.5.0) keeps a folder out of `fsp links`: `` `linkable` is declared twice ``
and `` `linkable` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it ``
(`const linkable = flag;`), each at the declaration.

`const remount = Remount.onSegments;` (since 0.6.0) says when the pages in a folder and below start
again because their URL changed (`fespalier-routing`, `references/route-dart.md`). Each error points at
the declaration, with a code frame:

| Message                                                                                                                                                                                              | Cause and fix                                                                                                                             |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `` `remount` is declared twice ``                                                                                                                                                                    | Two `const remount` in one `route.dart`; the error is at the second                                                                       |
| `` `remount` must be `const`: write `const remount = Remount.onSegments;` ``                                                                                                                         | `final remount = ...`, `var`, or a getter: `fsp` can't read a value it would have to run                                                  |
| `` `remount` must be `Remount.never`, `Remount.onSegments` or `Remount.onLocation`, written out: fsp reads it from the source, it doesn't run it ``                                                  | Any other value: a variable, `'onSegments'`, `true`, `Remount.on_segments`. An import prefix is fine                                      |
| warning `` `remount` has no effect here: the `transition()` that builds this page doesn't take its key; add a `LocalKey key` parameter and give it to the page `` (`present()` for a `present.dart`) | The page's `transition.dart` has no `key` parameter, so the new key never reaches the `Page`: take it and pass it on (`Transitions.*` do) |

`const deferred = true;` (since 0.7.0) makes the `page.dart` of a folder and below load its code on demand
(`fespalier-routing`, `references/route-dart.md`). Its errors point at the declaration, with a code frame:

| Message                                                                                               | Cause and fix                                                        |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `` `deferred` is declared twice ``                                                                    | Two `const deferred` in one `route.dart`; the error is at the second |
| `` `deferred` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it `` | `const deferred = flag;`, `'true'`, `1`: write `true` or `false`     |

A type declared in a deferred `page.dart` is an error **on the page** (G4), at the class that is the page,
once for each type:

| Message                                                                                                                                                                                                                                                                                                                                         | Cause and fix                                                                                                                                                                                                         |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `Sort` is declared in this page.dart, which is deferred, and the generated code names it outside the page (as the type of a segment, a query parameter or an `extra`): Dart can't use a deferred library's types there. Move `Sort` to a file of its own and import it here, or say `const deferred = false;` in this folder's route.dart `` | An enum (a segment or query type) or an `extra` class declared in the page's own file. Move it to `lib/models/sort.dart` and import it in the page, or opt the folder out. One in a page that is not deferred is fine |

A pubspec value that is not a bool is serde's error, not ours (see the table at the top): `invalid
pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13`.
Turning `deferred` on also binds the nearest `loading.dart` and `error.dart` to a route without data, so an
inherited `error.dart` that asks for a segment the route lacks fails with the existing
``can't fill `id` for /: ...`` error (`diagnostics-binding.md`).

`const freshness = Freshness(...)` (since 0.8.0) is the default of when the data of a folder and below loads again
(`fespalier-data`, `references/freshness-and-cache.md`). Its errors point at the declaration, with a code frame; the first
two are the `data.dart` ones (`diagnostics-data-and-hooks.md`) and are the same here:

| Message                                                                                                                                                                              | Cause and fix                                                                                                                     |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `` `freshness` must be a `Freshness(...)`: write `const freshness = Freshness(staleTime: Duration(minutes: 5));` ``                                                                  | `const freshness = Duration(minutes: 5);` or any other initializer                                                                |
| `` `freshness` is declared twice ``                                                                                                                                                  | Two `freshness` in one `route.dart`; the error is at the second                                                                   |
| `` `dataCache` belongs in the data.dart whose value it saves, not in a route.dart: each data type has its own encode and decode ``                                                   | A `dataCache` in a `route.dart`. Move it to the `data.dart` it saves                                                              |
| warning `` `freshness` here applies to no data.dart: none at or below this folder is a data() function that returns a Future or a value without a `freshness` of its own; drop it `` | Nothing below is a function-form, non-`Stream` `data()` that lacks a `freshness` of its own: drop it, or put it where the data is |

`const nest = false;` (since 0.4.0) makes a folder's route a sibling of the page above it
instead of a child (`fespalier-routing`, `references/route-dart.md`). Each error points at
the declaration:

| Message                                                                                                                                                                                                                        | Cause and fix                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `` `nest = false` takes a route out of the page above it, and the app folder has nothing above it; drop it ``                                                                                                                  | `nest` in the app folder's own `route.dart`                                                                                   |
| `` `nest = false` is about a folder's own route, and a `(group)` has none: ... repeat the segment under a group: `(group)/refund/confirm/page.dart` ``                                                                         | `nest` in a `(group)`. Put it in the folder of the route that must not nest, or use the group shape the message names         |
| `` `nest = false` is about this folder's own route, and it has no page.dart or redirect.dart; put it in the route.dart of each folder whose route should not nest ``                                                           | It is not inherited: put it beside each `page.dart` or `redirect.dart` that should leave                                      |
| `` `nest = false` takes this route out of the page above it, and there is no page.dart above this folder: it is not nested under anything, so drop it ``                                                                       | Nothing above to leave                                                                                                        |
| `` `nest = false` takes this route out of `a/page.dart`, and `a/layout.dart` sits in the folders it leaves, so the route would escape that layout's shell. Move the layout above that page's folder, or drop `nest = false` `` | A `layout.dart` in the page's folder or a page-less folder between. Move it above the page's folder, or keep the route nested |
| `` `nest` is declared twice `` / `` `nest` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it ``                                                                                             | Like `caseSensitive`: one literal                                                                                             |

## Localized `paths`

| Message                                                                                                                                                                                                                             | Cause and fix                                                                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `paths` gives a static folder's name more spellings, but `$x` is a dynamic segment: it takes whatever the URL has, so there is no word to spell; put `paths` in the route.dart of the folder that has the word ``                | `paths` in a `$dynamic`, `$$catch-all` (`it takes whatever is left of the URL`), `(group)` (`it adds nothing to the URL`) or the app folder (`has no URL segment of its own`) |
| `` `paths` must be a map literal from a locale tag to one spelling, e.g. `const paths = {'fr': 'produits', 'de': 'produkte'};`: fsp reads it from the source, it doesn't run it ``                                                  | A variable, a function call                                                                                                                                                   |
| ``a key of `paths` must be a string literal naming a locale, e.g. `'fr'`: fsp reads it from the source`` / ``a value of `paths` must be a plain string literal, e.g. `'produits'`: fsp reads it from the source``                   | Interpolation, constants                                                                                                                                                      |
| `` `zz!` isn't a locale tag: use a language, with a region if you like, e.g. `'fr'` or `'pt-BR'` ``                                                                                                                                 |                                                                                                                                                                               |
| `` `paths` has `fr` twice (the first is on line 3) ``                                                                                                                                                                               | `fr` and `FR` are one tag                                                                                                                                                     |
| `` `about us` is not a valid URL segment for `fr`: it may have letters (accented or not), digits and - _ . ~, but no `?`, `#`, `%`, `:`, `\|`, quotes, brackets, `$`, `\`, whitespace or control characters ``                      | Also `it is one URL segment, so it has no / in it` and `it can't be empty`                                                                                                    |
| `` `fr: 'about'` makes /about, which about/page.dart serves too; rename the spelling, or the folder it collides with `` and ``/about is also reached through `fr: 'about'` in c/route.dart:1; rename the spelling, or this folder`` | A spelling makes a URL another route (or another `not_found.dart`) serves: reported on **both** files                                                                         |
| warning `` `paths` is empty, so it adds no spelling ``                                                                                                                                                                              |                                                                                                                                                                               |
| `` `paths` is declared twice ``                                                                                                                                                                                                     |                                                                                                                                                                               |

An entry with an error is left out of the map; the rest still takes part in the collision
check, so you may get a collision error while you fix another entry.

## `extra_codec.dart`

| Message                                                                                                                                                               | Cause and fix                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `` expected a top-level `extraCodec`: `final extraCodec = ExtraCodec({...});`, `const extraCodec = MyCodec();` or `Codec<Object?, Object?> get extraCodec => ...;` `` | The file does not declare `extraCodec` |
| warning `extra_codec.dart is only read at the root of the app folder, so this one is ignored`                                                                         | A copy in a subfolder                  |

Runtime, from `ExtraCodec`: `` two types are saved as `X`: give one of them another name with
`names:` `` (an `ArgumentError` at construction); with `strict: true`, `a Foo isn't registered in
the ExtraCodec`.
