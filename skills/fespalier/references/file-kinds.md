# The file kinds

Twenty-one kinds, as of 0.13.0 (`Kind::ALL` in `cli/src/scan.rs`; `action.dart` is new in 0.5.0, `nav.dart`, `app.dart`, `startup.dart`, `splash.dart` and `observe.dart` in 0.8.1, and `leave.dart` in 0.11.0). `fsp` reads a
file by its **name**; nothing else marks a route. Each view file exports one
public widget class, **or** one top-level function named after the file, never
both.

| File               | Applies to                                                                                                   | Can ask for                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `page.dart`        | its own folder's URL                                                                                         | segments; query; `data`; `extra`                                                                                   |
| `data.dart`        | the page beside it, or a section                                                                             | segments; query (a section's: segments and query too since 0.3.0)                                                  |
| `action.dart`      | the page beside it, or a section (since 0.5.0)                                                               | segments; query; the one `input`                                                                                   |
| `loading.dart`     | its folder and below (inherited, nearest wins)                                                               | segments; query                                                                                                    |
| `error.dart`       | its folder and below (inherited, nearest wins)                                                               | segments; query; `error`, `stackTrace`, `retry`                                                                    |
| `layout.dart`      | its folder and below                                                                                         | `child` or `navigationShell`; segments at or above; query; section data; `extra`                                   |
| `guard.dart`       | every route at and below its folder                                                                          | `uri`; segments at or above; query; `extra`                                                                        |
| `redirect.dart`    | its own folder's URL, in place of `page.dart`                                                                | `uri`; segments; query; `extra`; optional `Ref ref` first (or `ProviderContainer c`)                               |
| `observe.dart`     | every page at and below its folder (since 0.8.1)                                                             | `Ref ref`; segments at or above; query; `uri`; `TypedLocation route`; `RouteScope scope` (`onEnter`, since 0.11.0) |
| `leave.dart`       | its own folder's page only, not inherited (since 0.11.0); beside a flow section's `layout.dart`, each step's | `BuildContext`, `Ref`; segments at or above; query; `uri`; `extra`; `PageLeave page`                               |
| `transition.dart`  | its folder and below; layout shells too                                                                      | `key`, `child`, `state`, `shell` (a `bool`)                                                                        |
| `present.dart`     | its own folder only                                                                                          | `key`, `child`, `state`                                                                                            |
| `navigator.dart`   | its folder and below (nearest wins)                                                                          | nothing: it is data                                                                                                |
| `not_found.dart`   | unknown URLs under its folder; bad segments                                                                  | `uri`; its own path's segments, as `String`s                                                                       |
| `meta.dart`        | its own route only (not inherited)                                                                           | nothing: it is data                                                                                                |
| `route.dart`       | `caseSensitive`, `linkable`, `remount`, `deferred`, `freshness`: folder and below; `paths`: its own segment  | nothing: it is data                                                                                                |
| `extra_codec.dart` | the app root only                                                                                            | nothing: it is data                                                                                                |
| `app.dart`         | the app root only (since 0.8.1)                                                                              | `router` (a `GoRouter`); everything else optional                                                                  |
| `startup.dart`     | the app root only (since 0.8.1)                                                                              | nothing: `startup()` takes no parameters                                                                           |
| `splash.dart`      | the app root only (since 0.8.1)                                                                              | `error`, `stackTrace`, `retry`, each nullable                                                                      |
| `nav.dart`         | its own folder's menu entry (since 0.8.1)                                                                    | `label()`: a `BuildContext` and the segments at or above (named, `required`)                                       |

`not_found.dart` also reads as `not-found.dart` (kebab), whatever `file_style`
says; `file_style` only picks what `fsp init` and `fsp new` write.

## One public widget class, or one function

A view file (`page`, `loading`, `error`, `layout`, `not_found`) exports **one
public widget class**, or a top-level function named after the file returning a
`Widget` (`page()`, `loading()`, `error()`, `layout()`, `notFound()` or
`not_found()`). Other functions in the file are helpers and are ignored.

- A file with a public widget class **and** the function is an error naming
  both. Keep the class, or move the widget to its own file and build it from the
  function.
- Other public classes may sit in a view file: `fsp` accepts it when **exactly one of them extends a
  `*Widget`** class. It errors when it cannot pick one (see
  `fespalier-troubleshooting`). Make helpers private (`_Name`) and you never
  depend on that.
- A function view is a plain function: no `BuildContext`, no `ref`, no hooks.
  Asking for one is an error that says so. Put hooks and `ref` in the widget it
  returns.
- A page class names its typed route after itself (`ProductPage` becomes
  `ProductRoute`; a `Page`, `Screen` or `View` suffix is dropped). A page
  function takes the folder path in PascalCase, ignoring `(group)` folders
  (`orders/$orderId/cancel/page.dart` is `OrdersOrderIdCancelRoute`, the root is
  `RootRoute`). `const routeName = 'KycShopName';` in `page.dart` overrides
  either (UpperCamelCase; the class is `<routeName>Route`).

## Per kind

**`page.dart`** serves its folder's URL. A folder has a `page.dart` **or** a
`redirect.dart`, not both. A page-less folder folds into its children's paths
(`greet/$name/page.dart` alone makes `greet/:name`).

**`data.dart`** has three forms (function, selector, provider) and is covered
by `fespalier-data`. Beside a `page.dart` it feeds the page. In a folder with a
`layout.dart` and **no** page it is the data of the whole section. With neither,
it is an error.

**`action.dart`** (since 0.5.0) is the write side of a route: every public top-level
function with a `Ref` first, `Future<T> action(Ref ref, {...segments, required Input
input})`, is an action, and a file may hold several. Beside a `page.dart` it belongs to
that route (`XRoute.submit`, `XRoute.useAction`); in a folder with a `layout.dart` and no
page, to the section (`XSection`). After a success the route's own `data.dart` and the
sections' above it are invalidated, or what `const invalidates = [...]` lists. Covered by
`fespalier-data` (`references/actions.md`). With no page or layout beside it, it is an error.
Since 0.8.1 the file may also hold the action's companions, `form()`, `validate()` and
`optimistic()` (`approveForm`... beside `approve`): they are not actions and not a file kind
(`fespalier-data`, `references/forms.md` and `references/optimistic.md`). Since 0.11.0 a `form()`
needs the `fespalier_forms` package.

**`loading.dart`** and **`error.dart`** show while `data.dart` first loads and
when it fails. They are inherited by every folder below, bound separately for
each route they cover. Without any, `DefaultLoading` (a centred adaptive
spinner) and `DefaultError` (the error text and a Retry button) are used.

**`layout.dart`** asks for `Widget child` (a `ShellRoute`) or a
`StatefulNavigationShell` (tabs). Asking for both is an error. Covered by
`fespalier-layouts`.

**`guard.dart`** is `GuardResult guard(Ref ref, {...})`; `GuardResult` is
`FutureOr<String?>`. The return type may also be written `FutureOr<String?>`,
`Future<String?>` or `String?`, and a sync guard stays sync. It runs again when what it
`ref.watch`es changes (since 0.5.0); `ProviderContainer c` first is the older form, read
once per navigation. Covered by `fespalier-guards`.

**`redirect.dart`** is `String redirect({...})` (or `Future<String>`), with an optional
first `Ref ref` (since 0.5.0) or `ProviderContainer c`, and gets a typed route named after
its path (`OldProductsIdRoute`). A tab layout's own folder cannot hold one.

**`observe.dart`** (since 0.8.1) is any of `void onEnter(Ref ref, {...})`, `void onFocus(...)` and
`void onLeave(...)`: hooks that run, after the frame, when a page at or below its folder becomes the one on
screen, is on top again and is gone. They bind like a guard's parameters, plus `Uri uri`,
`TypedLocation route` and, for `onEnter` only (since 0.11.0), `RouteScope scope`. Covered by `fespalier-observability`.

**`leave.dart`** (since 0.11.0) is `LeaveResult leave(BuildContext context, Ref ref, {...})`, asked before its
folder's page goes: `true` lets it go, `false` keeps it. It is the `onExit` of the folder's `GoRoute`, and the page is wrapped
so the Android back and the iOS swipe ask too. It needs a `page.dart` (the one exception: beside the `layout.dart` of a
flow section, a multi-page form, where it is each step's) and is not inherited. Covered by
`fespalier-routing` (`references/leaving-a-page.md`).

**`transition.dart`** and **`present.dart`** return a `Page`. See
`fespalier-layouts` (transitions) and `fespalier-routing` (`present.dart`).

**`navigator.dart`** is `const navigator = RouteNavigator.root;` (or `.shell`),
written out: `fsp` reads the source, it never runs it.

**`not_found.dart`**: the root's is the app-wide view, any other folder's covers
unknown URLs under it and unparsable segments in its routes. It gets `Uri uri`
and its own path's segments as raw `String`s, and **no** query and **no** data.
Two folders with the same URL cannot both have one, and a catch-all folder
cannot have one at all.

**`meta.dart`**: `const meta = <any const expression>;`, beside a `page.dart`
or `redirect.dart`. Copied into the manifest by reference.

**`route.dart`**: `const caseSensitive = false;` and/or
`const paths = {'fr': 'produits'};` and/or `const nest = false;` and/or
`const linkable = false;` (0.5.0) and/or `const remount = Remount.onSegments;`
(0.6.0: when a page starts again because its URL changed) and/or `const deferred = true;`
(0.7.0: the pages in this folder and below load their code on demand; only `page.dart` is
deferred, never a layout) and/or `const freshness = Freshness(...);` (0.8.1: when the data of
this folder and below loads again). Each must be a literal, except `freshness`, a `Freshness(...)`
call:
`fsp` reads the source. A `route.dart` with none of them is an error.

**`nav.dart`** (since 0.8.1) is `const nav = Nav(label: 'Products', order: 1);` and, optionally,
`String label(BuildContext context, {required int id})`: how the folder shows in the menus and
breadcrumbs `fsp gen` writes as `AppMenu`. A folder without `page.dart` or `redirect.dart` is a
heading. `Nav` is in `package:fespalier/nav.dart`. See
[`fespalier-layouts`](../../fespalier-layouts/references/menus-and-breadcrumbs.md).

**`extra_codec.dart`**: a top-level `extraCodec` (a `const`, a `final` or a
getter). In a subfolder it is ignored with a warning.

**`app.dart`**, **`startup.dart`** and **`splash.dart`** (since 0.8.1) are read **at the app
root only**: below it they are ignored with a warning (`app.dart is only read at the root of the
app folder, so this one is ignored`). They make `fsp` write `lib/app.main.g.dart` (class `AppMain`)
unless `main: manual` is set, in which case they are not read at all. `app.dart` and `splash.dart`
are view files (a class or `Widget app(...)` / `Widget splash(...)`); `startup.dart` exports
`startup()`, `zone()`, `providerObservers`, `routerObservers`, `retry()` and, since 0.12.0, `ready()` and `attach()` by name. All of it is in
[`app-main.md`](app-main.md).

## Folder names

| Folder        | Segment                                                                 |
| ------------- | ----------------------------------------------------------------------- |
| `products`    | static; ASCII letters, digits and `- _ . ~` only                        |
| `$id`         | dynamic; a lowerCamel Dart identifier; not a [reserved name][reserved]  |
| `$$rest`      | catch-all, **one or more** remaining segments (a `List`)                |
| `$$$rest`     | catch-all, **zero or more**                                             |
| `(account)`   | group: adds nothing to the URL; the same characters inside the brackets |
| `_name`, `.x` | skipped entirely: colocated code, never a route                         |

`fsp new` accepts `[id]` and `:id` for `$id`, `[...rest]` for `$$rest` and
`[[...rest]]` for `$$$rest`, so you need not quote `$` in a shell. A folder with
an invalid name is an error (see `fespalier-troubleshooting`).

[reserved]: binding-rules.md
