# Diagnostics: config, `meta.dart`, `route.dart`, localized paths and the CLI

As of v0.4.0 (`cli/src/config.rs`, `resolve.rs`, `locale.rs`, `manifest.rs`, `main.rs`,
`init.rs`, `scaffold.rs`). Messages are quoted as `fsp` prints them.

## The `fespalier:` section of `pubspec.yaml`

These are **not** diagnostics with a code frame: `fsp` prints the pubspec path, then the
message, and exits 1.

| Message                                                                                                                                                                                                                               | Cause and fix                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| ``invalid pubspec.yaml: fespalier: unknown field `nope`, expected one of `app_dir`, `output`, `format`, `output_manifest`, `meta`, `meta_unique`, `case_sensitive`, `data_retry`, `keep_previous`, `file_style`, `links` at line 25 column 3`` | An unknown (or misspelled) key: the section rejects them |
| ``invalid pubspec.yaml: fespalier.data_retry: unknown variant `maybe`, expected `inherit` or `none` at line 25 column 15``                                                                                                            | Wrong enum value (`file_style`: `snake` or `kebab`)      |
| `` `fespalier.app_dir` must be a path under lib/ (it is imported as package code), got `app` ``                                                                                                                                       | `app_dir` and `output` live under `lib/`                 |
| `` `fespalier.output` must be a .dart file, got `lib/x.txt` ``                                                                                                                                                                        |                                                          |
| `` `fespalier.output_manifest` and `fespalier.output` are the same file (`lib/app.g.dart`); leave `output_manifest` out to keep the manifest in `output` ``                                                                           |                                                          |
| `` `fespalier.meta` must be `required` or `optional`, got `always` ``                                                                                                                                                                 |                                                          |
| `` `fespalier.meta_unique` lists argument names of `meta`, e.g. `[code, slug]`; `a-b` is not one ``                                                                                                                                   | Names must be identifiers                                |

## `fsp links` (since 0.5.0)

The `links:` values are checked only by `fsp links` (`fsp gen` and `fsp check` read the section
but never look at its values); an unknown key under `links:` is an `invalid pubspec.yaml: fespalier.links: unknown
field ...` error everywhere, like any other. These are printed without a code frame, and exit 1:

| Message | Cause and fix |
| --- | --- |
| `` no `links:` in the `fespalier:` section of pubspec.yaml; add the domains the app opens, e.g. ... `` | `fsp links` with no `links:` section |
| `` `fespalier.links.domains` is required: list the host names the app opens, e.g. `domains: [shop.example.com]` `` | No `domains`, or an empty list |
| `` `fespalier.links.domains`: `https://x.com/` is not a host name; write it as `shop.example.com`, with no scheme, port or path (an international name in punycode) `` | A scheme, port or path, one label (`shop`), or characters beyond ASCII |
| `` `fespalier.links.domains`: the sitemap's URLs are on the first domain, so it can't be the wildcard `*.example.com`; list a host name first `` | A `*.` domain first |
| `` `fespalier.links.android_package` needs `android_sha256`: assetlinks.json lists the fingerprints of the certificates the app is signed with (...) `` and `` `fespalier.links.android_sha256` needs `android_package`: the application id assetlinks.json is for `` | One without the other |
| `` `fespalier.links.android_package` must be an Android application id like `com.example.shop` (two or more parts separated by dots, each starting with a letter, with letters, digits and `_`), got `shop` `` | A one-part id, a part starting with a digit, a `-` |
| `` `fespalier.links.android_sha256`: `AB:CD` is not a SHA-256 fingerprint; write 32 hex pairs separated by `:`, as `keytool -list -v` prints them (`AB:CD:...`) `` | A SHA-1, a truncated or non-hex value |
| `` `fespalier.links.ios_app_id` must be the Team ID, a dot and the bundle id, like `ABCDE12345.com.example.shop` (the Team ID is 10 upper-case letters and digits), got `com.example.shop` `` | The bundle id alone |
| `` `fespalier.links.scheme` must be a custom URL scheme in lower case, like `myshop` (letters, digits, `+`, `-` and `.`, starting with a letter), not `http` or `https`, got `MyShop` `` | |
| `` `fespalier.links.scheme` is written into the Android and iOS files: set `android_package` (with `android_sha256`) or `ios_app_id` too `` | A scheme with no platform |
| `` `fespalier.links.out` must be a folder inside the project (relative, no `..`), got `../x` `` | An absolute path, `..`, or an empty value |
| `` N error(s); no links `` | The route tree has errors: `fsp links` prints them first, like `fsp routes` |
| `` no route can be linked: the app has no page, or every folder says `const linkable = false;` `` | Nothing to list |
| `` links/web/sitemap.xml is missing `` / `` ... is out of date `` / `` ... is not wanted by this config ``, then `` N file(s) out of date; run `fsp links` `` | `fsp links --check`: the files on disk differ from what `fsp links` would write; run it and commit |

## The command line

| Message                                                                                                                         | Cause and fix                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `no pubspec.yaml here or above; pass --project`                                                                                 | Run inside the project, or `--project <dir>`                                  |
| ``<project>/lib/app not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)``                                  | No app folder yet                                                             |
| ``no pubspec.yaml in <dir>; run `fsp init` inside a Flutter project or pass --project``                                         | `fsp init` needs a `pubspec.yaml`                                             |
| `` pubspec.yaml has no `name:` ``                                                                                               | `fsp init` needs the package name for the `main.dart` it prints               |
| `N error(s); lib/app.g.dart left unchanged`                                                                                     | The summary line after the diagnostics above: the **old** file is still there |
| `N error(s); no route table`                                                                                                    | `fsp routes` refuses to print while there are errors                          |
| `nothing to create: a (group) folder has no page; also pass --layout, --loading, --error, --not-found, --guard or --transition` | `fsp new '(group)'` with no flag (or `--no-page` alone)                       |
| ``--name `x` names the route class `xRoute`, so it must be UpperCamelCase (letters, digits, `_`), e.g. `KycShopName` ``         | `fsp new --function --name`                                                   |
| `a catch-all folder can't have a not_found.dart: it matches every URL below it, so none is unknown`                             | `fsp new 'docs/[...rest]' --not-found`                                        |
| `nothing to create`                                                                                                             | Every file `fsp new` would write already exists (`skip  ... (exists)`)        |
| `` `fsp new` created: ... Fix or delete them, then run `fsp gen`. ``                                                            | The scaffold was written but `gen` then failed: read the errors above it      |

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

| Message                                                                                                    | Cause and fix                 |
| ---------------------------------------------------------------------------------------------------------- | ----------------------------- |
| `` expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;` or `const linkable = false;` `` | A `route.dart` with none of the four (before 0.5.0 the text named the first two only) |
| `` `caseSensitive` is declared twice ``                                                                    |                               |
| `` `caseSensitive` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it `` | `final caseSensitive = flag;` |

`const linkable = false;` (since 0.5.0) keeps a folder out of `fsp links`: `` `linkable` is declared twice ``
and `` `linkable` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it ``
(`const linkable = flag;`), each at the declaration.

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
