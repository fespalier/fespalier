# fespalier

File-tree routing for Flutter, in the spirit of Next.js. An espalier is a tree
trained flat against a frame; here the frame is `lib/app/`.

You write plain widgets and functions in small files under `lib/app/`. There are no
base classes or interfaces to implement: the file name says what a file is, and its
constructor says what it needs. The `fsp` generator reads every file, works out what
each parameter should receive, checks that the files fit together, and writes one
mountable `lib/app.g.dart`. It's built on go_router, Riverpod and flutter_hooks,
with no build_runner.

```
lib/app/
  layout.dart            AppLayout({required Widget child})           → ShellRoute
  page.dart              HomePage()                                   → /
  loading.dart           RootLoading()                                  (inherited)
  error.dart             RootError({required Object error, required VoidCallback retry})
  not_found.dart         NotFound({required Uri uri})
  transition.dart        Page<void> transition(LocalKey key, Widget child)  (inherited)
  products/
    data.dart            final data = FutureProvider<List<Product>>(…)
    page.dart            ProductsPage({required List<Product> products})  → /products
    loading.dart         ProductsLoading()
    $id/
      data.dart          Future<Product> data(Ref ref, {required int id})
      page.dart          ProductPage({required Product product})       → /products/:id
      error.dart         ProductError({required int id, required Object error, …})
  checkout/
    guard.dart           GuardResult guard(ProviderContainer c)
    page.dart
  greet/$name/page.dart  GreetPage({required String name})
  (account)/             a group: its layout wraps profile/ and settings/,
    layout.dart            but adds nothing to their URLs (/profile, /settings)
    profile/page.dart
    settings/page.dart
  _components/           private: never routes
```

```dart
// the whole app entry point
MaterialApp.router(routerConfig: AppRoutes.router());

// or inside an existing GoRouter (brownfield)
GoRouter(routes: [...legacyRoutes, ...AppRoutes.mount(at: '/shop')]);

// typed navigation, generated from the tree
ProductRoute(id: 42).go(context);
const SearchRoute(q: 'ap', page: 2).go(context);   // → /search?q=ap&page=2

// each route's data.dart, as a Riverpod provider
ref.watch(ProductRoute.data(42));
await const ProductsRoute().refresh(ref);
```

## Getting started

You need Flutter 3.32 or newer (Dart 3.8) for the package. go_router 18 needs Flutter
3.44 or newer.

**1. Install the CLI.** On Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
```

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION=v0.1.0`
to pick a release (the default is the latest) and `FSP_INSTALL_DIR=/some/dir` to install
elsewhere. On Windows, download `fsp-x86_64-pc-windows-msvc.zip` from the
[Releases page](https://github.com/vaam-apps/fespalier/releases) and put `fsp.exe` on your
`PATH`. With Rust installed, on any platform:

```sh
cargo install --git https://github.com/vaam-apps/fespalier --tag v0.1.0 fespalier
```

**2. Add the package** to your app's `pubspec.yaml`, then run `flutter pub get`:

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/vaam-apps/fespalier
      path: packages/fespalier
      ref: v0.1.0
```

It depends on go_router (17 or 18), hooks_riverpod 3 and flutter_hooks, and
`package:fespalier/fespalier.dart` re-exports all three, so you don't add them yourself.

**3. Run `fsp init`** in the project root:

```sh
fsp init
```

It creates `lib/app/layout.dart`, `page.dart`, `not_found.dart` and `transition.dart` (every
route animates with the Material transition), and writes `lib/app.g.dart`. It never
overwrites a file that exists: those are reported as `skip`.
It then prints what is left to do (the dependency block above, if `pubspec.yaml` doesn't
have it yet, and this `main.dart`):

```dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

void main() => runApp(
      ProviderScope(
        child: MaterialApp.router(routerConfig: AppRoutes.router()),
      ),
    );
```

Already have a `GoRouter`? Mount the tree inside it instead. `at` is the URL prefix:

```dart
GoRouter(routes: [...yourRoutes, ...AppRoutes.mount(at: '/x')])
```

**4. Day to day.**

```sh
fsp watch                                 # next to `flutter run`: regenerates on every save
fsp new 'orders/[id]' --data --loading    # scaffold a route; see "The generator" for all flags
```

Commit `lib/app.g.dart`: it's plain code, meant to be read, and the app builds without
`fsp` installed. In CI, run `fsp check`. It writes nothing and exits non-zero on errors:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
```

**Config.** `fsp` needs no configuration. To move things, add this optional section to
`pubspec.yaml`. Both paths are relative to the project root and must be under `lib/`, and
`output` must be a `.dart` file. These are the defaults:

```yaml
fespalier:
  app_dir: lib/app
  output: lib/app.g.dart
```

**Platform notes.**

- **Web URLs.** Flutter web uses hash URLs (`/#/products/1`) unless you switch to path
  URLs. Add `flutter_web_plugins: {sdk: flutter}` to `dependencies` and call
  `usePathUrlStrategy()` (from `package:flutter_web_plugins/url_strategy.dart`) before
  `runApp`. Your web server must also serve `index.html` for unknown paths.
- **go_router 18 and Material.** go_router 18 checks for `MaterialApp` from
  `package:material_ui`, not the one in `package:flutter/material.dart`. With Flutter's
  `MaterialApp`, it treats your app as a plain widgets app: routes without a
  `transition.dart` don't animate at all, and go_router's own error screen is unstyled.
  go_router 17 checks Flutter's `MaterialApp` and has no such problem. There are two ways
  around it:
  - Have a root `lib/app/transition.dart` that says how routes animate, e.g.
    `Page<void> transition(LocalKey key, Widget child) => Transitions.material(key, child);`
    (or `cupertino`). `fsp init` already adds this file. It works with either
    `MaterialApp`, and it's the easy fix.
  - Or use `MaterialApp` from `package:material_ui` (add `material_ui` to `dependencies`).
    It has its own `Theme` and localizations, which widgets from
    `package:flutter/material.dart` don't read, so it only makes sense if you import
    `package:material_ui/material_ui.dart` everywhere. Mixing the two loses your theme.

  Or stay on go_router 17 by adding `go_router: ^17.0.0` to your `dependencies`. The
  examples use Flutter's `MaterialApp` and each has a root `transition.dart` returning
  `Transitions.material`, so their routes animate on both go_router 17 and 18.

## File kinds

Each view file exports one public widget class, of any kind: `StatelessWidget`,
`ConsumerWidget`, `HookConsumerWidget` and so on. Function files export one
top-level function.

| File | Exports | Its constructor / signature can ask for |
|---|---|---|
| `page.dart` | a widget | segments; query; what `data.dart` yields |
| `data.dart` | `data(Ref ref, {…})` returning `Future<T>`, `Stream<T>` or `T` — **or** `final data = <Provider>(…)` | segments, query (named) |
| `loading.dart` | a widget, inherited by subfolders | segments; query |
| `error.dart` | a widget, inherited by subfolders | segments; query; `error`, `stackTrace`, `retry` |
| `layout.dart` | a widget; wraps this folder and below (ShellRoute), or holds its subfolders as tabs | `child` or `navigationShell`; segments at or above it; query |
| `guard.dart` | `GuardResult guard(ProviderContainer c, {…})` | segments, query (named) |
| `transition.dart` | `Page<…> transition(…)`; applies to this folder and below | `key`, `child`, `state` |
| `not_found.dart` | a widget, root only; unknown paths and unparsable segments | `uri` |

### How parameters are filled

The generator reads each constructor (named or positional, `this.x` or typed) and fills
every parameter:

1. **By name.** A parameter named like a `$segment` in the path gets that segment.
   `data`, `child`, `navigationShell` (or `shell`), `error`, `stackTrace`, `retry` and `uri`
   get what their name says, in the files where they make sense.
2. **Query.** An *optional* parameter that is nullable or a `List` of
   `String`/`int`/`double`/`bool` is a query parameter: `int? page` gets `?page=2`, and
   `List<String> tags = const []` gets every `?tags=`.
3. **By type.** Otherwise, a page's parameter whose type is what `data.dart` yields gets
   the data, so `required this.product` with `final Product product;` works. An error
   view's `Object` gets the error, `StackTrace` the stack trace and `VoidCallback` the
   retry. A layout's `Widget` gets the child, its `StatefulNavigationShell` gets the tab shell, and
   not-found's `Uri` gets the URI.
4. **Otherwise**, a required parameter is a generator error pointing at it. An optional
   one is left to its default.

These names are reserved, so segments can't use them.

### Segment types

A segment's type comes from the parameters that ask for it: `{required int id}` in
`products/$id/data.dart` makes `$id` an `int` everywhere. That covers the typed
`ProductRoute(id: 42)`, the page, and parsing: `/products/abc` goes to `not_found.dart`.
Every file that asks for `$id` must agree on its type. When nobody gives one, a segment
is a `String`. Segments are `String`, `int`, `double` or `bool`.

### `(group)` folders

A folder named in parentheses groups routes without adding to their URLs. Its
`layout.dart`, `loading.dart` and `error.dart` apply to the routes inside it and not to
their siblings, so `(shop)/cart` and `(account)/profile` can have different shells and
still be `/cart` and `/profile`. A group can also hold a `page.dart`: `(marketing)/page.dart`
serves `/` with the marketing layout, as long as nothing else serves `/`.

Two pages that end up at the same URL are an error, and so is a page that another
route always catches first. go_router takes the first route that fully matches, so
fespalier puts static routes before dynamic ones: `/about` comes before `/:slug`. A
group's routes stay together in one ShellRoute, though, so a group holding a dynamic
route can't be sorted around a dynamic sibling outside it:

```
error: /settings is unreachable: $slug/page.dart (/:slug) comes first and matches it;
       move one of them into or out of its (group)
```

### Tab layouts

A `layout.dart` that asks for a `StatefulNavigationShell` (named `navigationShell` or
`shell`, or by that type) instead of a `Widget child` is a tab layout. It becomes a
go_router `StatefulShellRoute.indexedStack`, so each tab keeps its own navigation stack
and state while you look at another one. Asking for both a child and a shell is an error.

```dart
// lib/app/(tabs)/layout.dart
const tabs = ['(home)', 'search', 'profile'];

class TabsLayout extends StatelessWidget {
  const TabsLayout({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (i) => navigationShell.goBranch(
            i,
            initialLocation: i == navigationShell.currentIndex,
          ),
          destinations: [ … ],
        ),
      );
}
```

Each tab (a branch) is the layout folder's own `page.dart`, if it has one, and then each
direct subfolder that holds routes: a static or dynamic folder, or a `(group)`. Whatever
is below a subfolder (nested pages, data, guards, transitions, more layouts) stays inside
its tab. Branches follow folder order, which is alphabetical, unless `tabs` lists them.
`tabs` is a top-level `const` list of string literals naming each folder as written, and
`'.'` for the folder's own page. It must list every branch exactly once, and a name that
is unknown, missing or repeated is an error. A tab layout can also ask for segments and
query parameters like any other layout.

Routes outside the layout's folder aren't in any tab, so they cover the whole screen: in
`examples/tabs`, `/settings` has no navigation bar and `/profile/edit` does. Two things to
know: go_router opens a tab on its first route, which can't have a `:segment` in its own
path, so a tab made only of dynamic routes, or a tab layout placed directly in a
`$folder`, is an error (put the layout in a `(group)` below that folder instead); and `tabs` in a tab layout must be string literals, so name another list of destinations
something else. See `examples/tabs`.

### Transitions

`transition.dart` says how a route animates in. It applies to its folder's route and
every route below it, and the nearest one wins. A `transition.dart` at the root is the
app-wide default; any folder or `(group)` folder can override it for its own routes.

The function returns a `Page`, and takes the page's key as `LocalKey key`, the page
itself as `Widget child`, and optionally `GoRouterState state`. `Transitions` has
ready-made ones: `fade`, `slide`, `none`, `material` and `cupertino`.

```dart
// lib/app/transition.dart: every route fades in, unless a folder overrides it
Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);
```

Routes with no `transition.dart` above them keep go_router's default for your app type:
the platform transition under a Material or Cupertino app, none otherwise (see the go_router
18 note in [Getting started](#getting-started)). Scaffold one with `fsp new … --transition`.

### Query parameters

A query parameter's type comes from the parameters that ask for it, like a segment's:
`T?` for a single value, `List<T>` for repeated ones. Every file of a route that asks
for `?page` must agree on its type. A missing or unparsable value is `null` (or left out
of a list); unlike a bad segment, it never leads to not-found. The typed route takes
query parameters as optional arguments and writes them into `.location`, leaving out
nulls and empty lists.

`data.dart` can take query parameters too, and its provider is then keyed by them, so
`/search?page=2` and `?page=3` load separately. It can't take a `List`: lists compare by
identity, so they can't key a provider. Take a `String?` and split it instead.

```dart
// search/data.dart
Future<List<Hit>> data(Ref ref, {String? q, int? page}) => …;

// search/page.dart
class SearchPage extends StatelessWidget {
  const SearchPage({super.key, required this.hits, this.q, this.tags = const []});
  final List<Hit> hits;        // required, and data.dart's type → the data
  final String? q;             // optional and nullable → ?q=
  final List<String> tags;     // optional List → every ?tags=
  …
}
```

### `data.dart`: a function or a provider

Write a function and fespalier wraps it in an autoDispose `FutureProvider` (or
`StreamProvider` for a `Stream`). Or export a provider named `data` yourself:
`FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or `StreamNotifierProvider`,
with its type arguments spelled out. It's used as-is.

Either way, the route exposes it as `XRoute.data`, keyed by the segments and query
parameters `data.dart` uses:

| Parameters used | Provider | Watch it with |
|---|---|---|
| none | plain | `ref.watch(ProductsRoute.data)` |
| one | `.family<T, int>` | `ref.watch(ProductRoute.data(42))` |
| several | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

A family provider you write yourself follows the same rule. With several parameters, or
with query parameters, its argument is a record naming the ones it uses, e.g.
`({int id, int? page})`.

## The generator

`cli/` is a Rust binary, `fsp`. A full scan, check and emit of an example runs in a few
milliseconds, fast enough to run on every save.

`fsp` installs as described in [Getting started](#getting-started). To build it from a
checkout, run `cd cli && cargo build --release` (→ `cli/target/release/fsp`). Commands:

```sh
fsp init                # first-time setup: starter files, then gen
fsp gen                 # check lib/app/, write lib/app.g.dart
fsp watch               # same, on every change (keep it next to `flutter run`)
fsp check               # CI: non-zero exit on errors, writes nothing
fsp new 'products/[id]' --name Product --data --loading --error --layout --guard --transition
                        # [id] or :id both mean $id, so no shell quoting of $
```

All commands take `--project <dir>` (default: the nearest folder with a `pubspec.yaml`).
`fsp new` always writes `page.dart` (plus the kinds you ask for with flags), skips files
that already exist, and takes its class names from `--name` (default: from the path, e.g.
`ProductsId`). A segment that already has a type elsewhere in the tree keeps it.

Errors point at the parameter or declaration at fault, and `app.g.dart` is left
untouched while there are any:

```
error: can't fill `label`: it isn't a segment of this path ($shop, $id) or data.dart's String
  ┌─ lib/app/shops/$shop/items/$id/page.dart:6:18
  │
6 │   const ItemPage(this.label, {super.key});
  │                  ^^^^^^^^^^

error: `$id` is int in products/$id/data.dart:6 but String here
```

It's built on existing libraries rather than hand-rolled parts:

- [tree-sitter](https://tree-sitter.github.io/) with
  [tree-sitter-dart](https://github.com/nielsenko/tree-sitter-dart) parses Dart.
- [minijinja](https://github.com/mitsuhiko/minijinja) renders the output. The shape of
  `app.g.dart` and of every scaffolded file lives in `cli/templates/`.
- [codespan-reporting](https://github.com/brendanzab/codespan) renders diagnostics.
- [clap](https://github.com/clap-rs/clap) handles the command line, and
  [notify-debouncer-mini](https://github.com/notify-rs/notify) drives `watch`.

`lib/app.g.dart` is plain go_router + Riverpod code that's meant to be read and committed.
It opens with a route table (see `examples/shop/lib/app.g.dart`). Some details:

- **Types are never re-spelled.** The generator doesn't copy your imports. Values flow
  through inference, and each route's provider is a `static final` whose type is inferred.
- **Segments and query parameters are parsed into a record** (`({int id, int? page})`).
  Records compare by value, so providers are keyed by them directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
  `(group)` folders fold away completely, apart from the ShellRoute their layout adds.
- **Static routes come first** among siblings, so go_router's first match is the most
  specific one.
- **`AppRoutes.mount(at:)`** only changes the root path. Typed routes read `AppRoutes.base`,
  so `.location` stays correct when mounted under `/shop`.

## Run the examples

```sh
cd examples/shop
flutter create . --platforms=android,ios,web   # adds platform folders only
flutter pub get
flutter run
```

Try `/products/13`: it fails once, so you see `error.dart` and **Retry**. Try `/products/abc`
(the int parse fails → `not_found.dart`), `/checkout` with an empty cart (the guard redirects
to `/cart`), and `/greet/you`.

`examples/features` covers the rest: an `(account)` group next to a catch-all `$slug`
page, per-route transitions (the group fades in, `/ticks` doesn't animate), data keyed
by two segments, query parameters (in a page, `data.dart` and a layout), a page and error
view bound by type, a layout and guard that take segments, a user-written
`AsyncNotifierProvider`, and `Stream` data.

`examples/tabs` is a bottom navigation bar built as a tab layout: three tabs (one with a
nested page), a counter that survives switching tabs, and a full-screen route outside
them.

## Development

```
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation)
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, with widget tests
examples/tabs/       a tab layout (StatefulShellRoute), with widget tests
```

```sh
(cd cli && cargo test && cargo clippy --all-targets)
(cd cli && cargo run -- check --project ../examples/shop)
(cd cli && cargo run -- check --project ../examples/tabs)
(cd packages/fespalier && flutter pub get && flutter analyze && flutter test)
(cd examples/shop && flutter pub get && flutter analyze && flutter test)
(cd examples/features && flutter pub get && flutter analyze && flutter test)
(cd examples/tabs && flutter pub get && flutter analyze && flutter test)
```

CI (`.github/workflows/ci.yml`) runs all of the above. It also scaffolds every file kind
with `fsp new` and runs `flutter analyze` on the result. After changing the emitter or a
template, regenerate with `cargo run -- gen --project ../examples/<name>`. A test fails if
a committed `app.g.dart` is stale.

## Status

This is an early version.

- **Generator:** 65 tests cover parsing, every binding rule and contract error, query
  parameters, `(group)` folders and route order, tab layouts, transitions, both data
  forms, scaffolding, and that the committed outputs are up to date. Clippy is clean.
- **Runtime + examples:** `flutter analyze` is clean on Flutter 3.47 (go_router 17 and 18,
  hooks_riverpod 3, flutter_hooks 0.21). The widget tests in the examples drive the
  generated router through every file kind.
- **Types are compared by spelling, not resolved.** The generator reads a syntax tree,
  not the Dart analyzer, so `Product` and a `typedef` of it count as different types. The
  Dart compiler still catches real mismatches in the generated code.

Things to know:

- Pages render below their `layout.dart`, so a layout's `Scaffold` is not their nearest
  `Material` during page transitions. Wrap `ListTile`-heavy pages in
  `Material(type: MaterialType.transparency, …)`, as `products/page.dart` does.
- In a route file, any optional nullable parameter of a primitive type becomes a query
  parameter, including one you meant as widget configuration (`String? title`). Keep such
  parameters on inner widgets instead of the file's exported one.
- go_router builds the whole matched stack, so `/products/abc` also loads `/products`
  underneath the not-found view.

