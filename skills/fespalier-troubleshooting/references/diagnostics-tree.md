# Diagnostics: the tree, the files and the routes

As of v0.4.0. Every message below is the text `fsp` prints (from `cli/src/scan.rs`,
`resolve.rs` and `emit.rs`, and run against small trees with `fsp check --json`),
followed by the cause and the fix. Errors leave `lib/app.g.dart` untouched; warnings
do not stop generation. In the rendered output a message is preceded by
`error:` or `warning:` and a code frame at the file and line; with `--json` it is
the `message` field.

## Folder names (`scan.rs`)

These are reported against the folder, with no line.

| Message                                                                                                                                           | Cause and fix                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `` `Hello World` is not a valid URL segment (use a-z, A-Z, 0-9, - _ . ~; `$name` for params, `(name)` for groups, `_name` for private folders) `` | A static folder has a character outside ASCII letters, digits and `- _ . ~` (uppercase ASCII is accepted in fact). Rename it, or prefix it with `_` to make it private                                                                                                                                                       |
| `` `$Bad`: a dynamic segment must be a lowerCamel Dart identifier, e.g. `$productId` ``                                                           | `$` folders start with a lowercase letter and use letters, digits and `_`. `$1st` and `$Bad` fail                                                                                                                                                                                                                            |
| `` `$$Rest`: a catch-all segment must be a lowerCamel Dart identifier, e.g. `$$rest` (one or more segments) or `$$$rest` (zero or more) ``        | Same rule for `$$` and `$$$` folders                                                                                                                                                                                                                                                                                         |
| `` `$data` is reserved (fespalier fills parameters called `data` itself); pick another name ``                                                    | A segment cannot be any of the 25 reserved names (`data`, `child`, `navigationShell`, `shell`, `error`, `stackTrace`, `retry`, `uri`, `key`, `location`, `go`, `push`, `replace`, `refresh`, `watch`, `read`, `prefetch`, `ref`, `keepFor`, `hashCode`, `runtimeType`, `extra`, and since 0.5.0 `of`, `maybeOf`, `copyWith`) |
| `` `(my group)`: a group name uses a-z, A-Z, 0-9, - _ . ~, e.g. `(shop)` ``                                                                       | No spaces in a group name                                                                                                                                                                                                                                                                                                    |
| `` `$id` is already a segment higher up this path ``                                                                                              | `p/$id/q/$id`: one name cannot repeat down a path; rename the inner one                                                                                                                                                                                                                                                      |
| `` `not_found.dart` and `not-found.dart` are the same view and both are in this folder; keep one ``                                               | Reported once against each file. Delete one                                                                                                                                                                                                                                                                                  |

A folder starting `_` or `.` is skipped silently; a **file** not named like a kind is
ignored silently (`Page.dart`, `page.dartt`): if a route does not appear, check the
spelling in `fsp routes`.

## View files (`resolve.rs`)

| Message                                                                                                                                                                 | Cause and fix                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `expected a public widget class`                                                                                                                                        | The file has no public class and no view function. Name the class without a leading `_`                  |
| ``expected one public widget class, found BPage, Other; make the others private (`_Name`)``                                                                             | Two public widget classes (or two public classes and none extends a `*Widget`). Make the helper private  |
| ``found the widget class APage and the function `page()`; a view file has one or the other. Keep the class, or move it to its own file and build it from the function`` | A view file with both. Keep one form                                                                     |
| `` `page()` must return a Widget, not Future<Widget> `` (or `void`)                                                                                                     | A view function is synchronous; load data in `data.dart`                                                 |
| ``both `not_found()` and `notFound()` are here; keep one``                                                                                                              | Two spellings of the not-found function in one file                                                      |
| warning `couldn't fully parse this file; if it doesn't compile, the Dart compiler will say where`                                                                       | The tree-sitter grammar could not read all of it. `fsp` worked with what it could; run `flutter analyze` |
| `a folder has a page.dart or a redirect.dart, not both`                                                                                                                 | Delete one, or move the redirect to its own folder                                                       |
| `data.dart has no page.dart to feed; with a layout.dart beside it, it would be the data of the section below that layout`                                               | Add a `page.dart`, or a `layout.dart` (making it section data), or delete `data.dart`                    |
| warning `folder has no page.dart and no routes below it; skipped`                                                                                                       | An empty or only-decorative folder. Expected right after `fsp new '(group)' --layout`                    |
| `a catch-all folder can't have a not_found.dart: it matches every URL below it, so none is unknown`                                                                     | Put `not_found.dart` in the parent folder                                                                |
| `/x already has (a)/x/not_found.dart; (group) folders don't add to the URL, so move or rename one`                                                                      | Two `not_found.dart` for one URL through groups                                                          |

## URLs and route names

| Message                                                                                                                                                                    | Cause and fix                                                                                                                                                       |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/x is served by both (a)/x/page.dart and (b)/x/page.dart; (group) folders don't add to the URL, so move or rename one`                                                    | Two pages at one URL, usually through `(group)` folders. Rename a folder, or move a page out of its group                                                           |
| ``route name `ThingRoute` is already taken by a/page.dart; rename the class``                                                                                              | Two page classes with one name (or one function-page path). Rename the class, or set `const routeName = 'Name';` in `page.dart`, or change the existing `routeName` |
| `` `routeName` must be a plain string literal, e.g. `const routeName = 'KycShopName';` ``                                                                                  | `routeName` is read from the source: a string literal                                                                                                               |
| `` `routeName` is `x`; it names the route class `xRoute`, so it must be UpperCamelCase (letters, digits, `_`), e.g. `KycShopName` ``                                       | Start with a capital                                                                                                                                                |
| `/settings is unreachable: $a/page.dart (/:a) comes first and matches it; move one of them into or out of its (group)`                                                     | A route another always catches first; see below                                                                                                                     |
| `/docs/*rest/child is unreachable: docs/$$rest/page.dart (/docs/*rest) comes first and matches it; ...`                                                                    | Something below a catch-all (also reported as `a catch-all matches the rest of the path, so no route can go below it; move the routes beside it`)                   |
| `/files is served by both files/page.dart and files/$$$path/page.dart: an optional catch-all also matches the path without it; use $$rest instead, or drop the page above` | `$$$rest` and a page in the folder above both serve the bare path                                                                                                   |

### Reading an "unreachable" error

go_router takes the first route that fully matches. `fsp` sorts **static, then dynamic,
then catch-all** at each level, so `/about` beats `/:slug` on its own. The error appears
when a **group** holds a dynamic route: a group's routes stay together in one
`ShellRoute`, so they cannot be sorted around a dynamic sibling **outside** the group.

```text
$a/page.dart                   -> /:a
(g)/layout.dart
(g)/$b/page.dart               -> /:b       unreachable behind /:a
(g)/settings/page.dart         -> /settings unreachable behind /:a
```

Fix: move `settings/` (or the dynamic folder) out of the group, into it, or give the
dynamic route a static prefix (`u/$a`). A static route next to a catch-all is fine
(`about/` and `$$rest/` in one folder: static first). The fix for a catch-all behind a
dynamic sibling is the same.

## Reading a "served by both" error with localized paths

A `paths` entry can make two folders serve one URL; that error is reported at the
entry **and** at the other route (see `diagnostics-config-and-meta.md`).
