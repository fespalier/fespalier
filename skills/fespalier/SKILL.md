---
name: fespalier
description: "Orientation for working with fespalier — Next.js-style file-tree routing for Flutter: the Rust generator fsp turns small files under lib/app/ into one typed go_router entry point, lib/app.g.dart, and package:fespalier is the runtime that file imports. Load this before any task in a Flutter app that uses fespalier (or in the fespalier repository): it carries what the project is, the file-kinds table, how to install and run fsp, the golden rules about the generated file, and which of the other fespalier-* skills to load."
---

# fespalier

> **Verified against fespalier `122cb07f` (2026-10-01), release v0.4.0.**
> These skills ship in the fespalier repository, and CI checks them against its code
> on every change. Version-sensitive claims say the release they became true in; if
> your app pins another fespalier, trust that release's code over this page. See
> [Versions](https://github.com/fespalier/fespalier/blob/main/skills/README.md#versions).

fespalier routes a Flutter app from a folder tree. You write plain widgets and
functions in small files under `lib/app/`; **the file name says what a file is,
and its constructor says what it needs.** The Rust CLI `fsp` reads the tree,
works out what each parameter should receive, checks that the files fit
together, and writes one readable `lib/app.g.dart`. It sits on go_router,
Riverpod and flutter_hooks, with no `build_runner`. There are no base classes or
interfaces to implement.

```text
lib/app/
  layout.dart              AppLayout({required Widget child})     -> ShellRoute
  page.dart                HomePage()                             -> /
  not_found.dart           NotFoundPage({required Uri uri})       (optional)
  transition.dart          Page<void> transition(LocalKey key, Widget child)
  products/
    data.dart              final data = FutureProvider<List<Product>>(...)
    page.dart              ProductsPage({required List<Product> products})
    $id/
      data.dart            Future<Product> data(Ref ref, {required int id})
      page.dart            ProductPage({required Product product})  -> /products/:id
  (account)/               a group: shares a layout, adds nothing to the URL
  _components/             private: never routes
```

Two packages: the **`fsp` binary** (generator, `cli/`) and the **Dart runtime
`package:fespalier`** (`packages/fespalier/`) that `app.g.dart` imports. They are
versioned together, and `dart run fespalier <command>` runs the `fsp` that
matches the package your `pubspec.lock` resolved.

## Golden rules

1. **Never edit `lib/app.g.dart`.** Its first line says so. Change `lib/app/`
   and regenerate; an edit is lost on the next run.
2. **Regenerate after every change under `lib/app/`** (`fsp gen`, or leave
   `fsp dev` running, or `fsp watch` next to `flutter run`). Also after editing an enum that a
   segment names (it lives outside `lib/app/`; `fsp watch` sees `lib/` too, as of
   0.3.0), and **after bumping the `fespalier` package** — the upgrade notes of
   0.1.1 through 0.3.0 each say "regenerate".
3. **Commit the generated file** (the default), so the app builds without `fsp`,
   and run `fsp check` in CI. The alternative is to git-ignore it and run
   `dart run fespalier gen` before `flutter analyze` everywhere.
4. **Errors leave `app.g.dart` untouched.** While `fsp` reports an error the old
   file stays, so a stale `app.g.dart` with a red `fsp gen` is a generator
   error to fix in `lib/app/`, not a file to patch.
5. **The generator reads syntax, not types.** `Product` and a `typedef` of it are
   different types to `fsp`; the Dart compiler still has the last word on the
   generated code. An enum is the one type it looks up.
6. **Typed routes are preferred, string paths are allowed.** `context.go('/products/2')` is
   fine when a route matches it; since 0.7.0 `fsp gen`, `check` and `watch` warn about a
   string path in `lib/` that matches **no** route:
   ``no route matches `/prodcts/2`, so it shows not-found [unknown_path]``. Fix the path, use
   the typed route, or silence one with `// fsp:ignore unknown_path`; see `fespalier-routing`.

## The file kinds

| File               | What it is                                                                         |
| ------------------ | ---------------------------------------------------------------------------------- |
| `page.dart`        | A widget (or `Widget page()`): serves the folder's URL                             |
| `data.dart`        | What the page (or a whole section) loads: function, selector, provider             |
| `action.dart`      | A write: `action(Ref ref, {..., required Input input})` (since 0.5.0)              |
| `loading.dart`     | Shown while `data.dart` first loads; inherited by folders below                    |
| `error.dart`       | Shown when `data.dart` fails, with `retry`; inherited                              |
| `layout.dart`      | Wraps this folder and below (`child`), or holds tabs (`navigationShell`)           |
| `guard.dart`       | `GuardResult guard(Ref ref, {...})`: redirect or `null`; re-runs on watch          |
| `redirect.dart`    | In place of a page: a route that only redirects                                    |
| `observe.dart`     | `void onEnter(Ref ref, {...})`, `onFocus`, `onLeave`: hooks per page (since 0.8.1) |
| `transition.dart`  | `Page<void> transition(...)`: how routes (and layout shells) animate               |
| `present.dart`     | `Page<void> present(...)`: the app builds this route's own page                    |
| `navigator.dart`   | `const navigator = RouteNavigator.root;`: render above every layout                |
| `not_found.dart`   | Unknown URLs and unparsable segments; nearest folder wins                          |
| `meta.dart`        | `const meta = ...;` this route's own facts, into the manifest                      |
| `route.dart`       | `caseSensitive`, `paths`, `nest`, `linkable`, `remount`, `deferred`, `freshness`   |
| `extra_codec.dart` | At the app root only: `extraCodec`, to restore `extra` after a restart             |
| `app.dart`         | App root only (since 0.8.1): the widget around the router (`MaterialApp`)          |
| `startup.dart`     | App root only (since 0.8.1): `startup()`, `zone()`, observers, `retry()`           |
| `splash.dart`      | App root only (since 0.8.1): shown while an async `startup()` runs                 |
| `nav.dart`         | `const nav = Nav(...)`: how a folder shows in the generated menus (0.8.1)          |

Folder names: `products` is a static segment; `$id` a dynamic one; `$$rest` one
or more remaining segments and `$$$rest` zero or more; `(account)` a group that
adds nothing to the URL; a name starting `_` or `.` is skipped. Everything
about each kind, what it can ask for and where it applies is in
[`references/file-kinds.md`](references/file-kinds.md).

## Install and run

<!-- x-release-please-start-version -->

```yaml
# in pubspec.yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.8.1
```

<!-- x-release-please-end -->

The package is not published to pub.dev (`publish_to: 'none'` since 0.4.0): this git
dependency, pinned to a release tag, is the install. It needs
Flutter 3.32+ (Dart 3.8); go_router 18 needs Flutter 3.44+. It depends
on go_router 17 or 18, hooks_riverpod 3 and flutter_hooks, and
`package:fespalier/fespalier.dart` re-exports all three, so you do not add them.

What the generated file contains (`AppRoutes`, `AppManifest`, the typed route classes) is in
[`references/generated-code.md`](references/generated-code.md).

Get `fsp` one of these ways (details in
[`references/cli-and-config.md`](references/cli-and-config.md)):

<!-- x-release-please-start-version -->

```sh
curl -fsSL https://raw.githubusercontent.com/fespalier/fespalier/main/install.sh | sh
dart run fespalier <command>      # installs nothing: downloads the matching release, SHA-256 pinned
cargo install --git https://github.com/fespalier/fespalier --tag v0.8.1 fespalier
```

<!-- x-release-please-end -->

```sh
fsp init                                   # starter layout/page/not_found/transition, then gen
fsp gen                                    # check lib/app/, write lib/app.g.dart
fsp watch                                  # regenerate on every change
fsp dev [-- <flutter run args>]            # the app, regenerated and hot restarted on every save (0.9.0)
fsp build <target> [-- <args>]             # fsp gen, then flutter build <target>, with the hooks of `tasks: build:` (0.9.0)
fsp run [task]                             # a task of `tasks:` in pubspec.yaml, or the list of them (0.9.0)
fsp check                                  # CI: non-zero on errors, writes nothing
fsp routes [--json | --graph [dot | json]]  # the route table, or the tree as Mermaid / DOT / JSON
fsp links [--check]                        # App Links, Universal Links, sitemap from the routes (0.5.0)
fsp maestro [--check]                      # Maestro smoke flows, one per route (0.7.0)
fsp size [--json] [--check]                # the web build's JavaScript per deferred route, and budgets (0.8.1)
fsp test [--check]                         # a widget smoke test per route, test/routes/routes_test.dart (0.8.1)
fsp telemetry [--grafana | --lan | --stop | --reset]   # a local OpenTelemetry stack and dashboards, in Docker (0.8.1)
fsp new 'orders/[id]' --data --loading     # scaffold a route, then gen
```

`fsp init` then prints the `main.dart` you need. Since 0.8.1 it is
`Future<void> main() => AppMain.run();`, with the generated `lib/app.main.g.dart` running
`lib/app/app.dart` (and `startup.dart`, `splash.dart`); see
[`references/app-main.md`](references/app-main.md). Before 0.8.1, and with `main: manual`, it prints
`MaterialApp.router(routerConfig: AppRoutes.router())` inside a `ProviderScope`. To add the tree to an
existing `GoRouter`, use `AppRoutes.mount(at: '/x')` (see `fespalier-migration`).

## How parameters are filled

A constructor parameter is filled **by name** (a `$segment` of the path, or the
reserved `data`, `child`, `navigationShell`, `error`, `stackTrace`, `retry`,
`uri`, `extra`), then **as a query parameter** (optional and nullable, or an
optional `List`), then **by type** (what `data.dart` yields). A required
parameter nothing fills is a generator error that points at it. The segment's
type comes from the parameters that ask for it: `{required int id}` makes `$id` an `int`
everywhere, and `/products/abc` goes to `not_found.dart`.
[`references/binding-rules.md`](references/binding-rules.md) has the full rules
and the reserved names.

## Which skill to load

| The work                                                                                                                     | Load                                            |
| ---------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| Folders, segments, catch-alls, enums, typed routes, `RouteLink`, `route.dart`, `extra`, `present.dart`                       | `fespalier-routing`                             |
| `data.dart`, loading and error views, retries, prefetch, sections, `dataAt`                                                  | `fespalier-data`                                |
| `layout.dart`, tabs, `container`, shell transitions, restoration, `fespalier_adaptive` (since 0.9.0)                         | `fespalier-layouts`                             |
| `guard.dart`, `redirect.dart`, `returnTo`, sign-in flows, `fespalier_auth` and `fespalier_sign_keypair` (DPoP) (since 0.9.0) | `fespalier-guards`                              |
| `observe.dart` hooks, telemetry, OpenTelemetry with `otel_zone`, the telemetry conventions (since 0.8.1)                     | `fespalier-observability`                       |
| Network images, an image CDN, signing image URLs, image heroes (since 0.9.0)                                                 | `fespalier-images`                              |
| `app.dart`, `startup.dart`, `splash.dart`, `main: manual`, `AppMain` (the generated `main()`)                                | this skill: `references/app-main.md`            |
| Widget tests: `pumpRouter`, `currentLocation`, deep links, data states                                                       | `fespalier-testing`                             |
| An `fsp` error, a stale `app.g.dart`, a route that does not show                                                             | `fespalier-troubleshooting`                     |
| Looking at a running app in Flutter DevTools (the `fespalier` tab, since 0.7.0)                                              | `fespalier-troubleshooting` (its DevTools page) |
| Upgrading 0.2 to 0.3, or adopting fespalier in a go_router app                                                               | `fespalier-migration`                           |
| Upgrading 0.2 to 0.3 or 0.7 to 0.8, or adopting fespalier in a go_router app                                                 | `fespalier-migration`                           |

## Where the truth is

The README in `fespalier/fespalier` is long and exact as far as anyone has checked;
where it and the code disagree, the `.rs` and `.dart` files win, and
[`fespalier-troubleshooting`](../fespalier-troubleshooting/) lists the disagreements
found so far and the release that fixed each. `examples/minimal` is the smallest real app (read it
first); `examples/features` exercises nearly every rule, with widget tests; what each example
shows is in [`references/examples.md`](references/examples.md).
