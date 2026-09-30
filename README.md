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
  not_found.dart         NotFoundPage({required Uri uri})               (optional, in any folder)
  transition.dart        Page<void> transition(LocalKey key, Widget child)  (inherited)
  products/
    data.dart            final data = FutureProvider<List<Product>>(…)
    page.dart            ProductsPage({required List<Product> products})  → /products
    loading.dart         ProductsLoading()
    $id/
      data.dart          Future<Product> data(Ref ref, {required int id})
      page.dart          ProductPage({required Product product})       → /products/:id
      error.dart         ProductError({required int id, required Object error, …})
      meta.dart          const meta = PageMeta(code: 'B04', …)         (this route's facts, any const)
  checkout/
    guard.dart           GuardResult guard(ProviderContainer c)         (guards this and below)
    page.dart
  old-products/$id/
    redirect.dart        String redirect({required int id})            → /old-products/:id redirects
  greet/$name/page.dart  GreetPage({required String name})
  docs/$$rest/page.dart  DocsPage({required List<String> rest})       → /docs/a, /docs/a/b, …
  (account)/             a group: its layout wraps profile/ and settings/,
    layout.dart            but adds nothing to their URLs (/profile, /settings)
    profile/page.dart
    settings/page.dart
  teams/$teamId/         no page: its layout and data.dart cover the section below
    data.dart            Future<Team> data(Ref ref, {required String teamId})
    layout.dart          TeamLayout({required Team team, required Widget child})
    members/page.dart    MembersPage(this.team)                       → /teams/:teamId/members
    not_found.dart       TeamNotFound({required Uri uri})             (for unknown paths below)
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
ProductRoute.watch(ref, id: 42);             // the same, typed: AsyncValue<Product>
await ProductRoute.read(ref, id: 42);        // Future<Product>
ProductRoute(id: 42).prefetch(ref);          // start loading before navigating
await const ProductsRoute().refresh(ref);
```

## Getting started

You need Flutter 3.32 or newer (Dart 3.8) for the package. go_router 18 needs Flutter
3.44 or newer.

**1. Install the CLI.** On Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
```

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION=v0.2.0`
to pick a release (the default is the latest) and `FSP_INSTALL_DIR=/some/dir` to install
elsewhere. On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.ps1 | iex
```

It puts `fsp.exe` in `%LOCALAPPDATA%\fespalier\bin` (tell it otherwise with
`$env:FSP_INSTALL_DIR`, pick a release with `$env:FSP_VERSION`), checks the SHA-256, and
prints how to add that folder to your `PATH` if it isn't there yet. With Rust installed, on
any platform:

```sh
cargo install --git https://github.com/vaam-apps/fespalier --tag v0.2.0 fespalier
```

With Homebrew (macOS, Linux) or Scoop (Windows), once the maintainers have set up the tap and
bucket (see [Releasing](#releasing)):

```sh
brew install vaam-apps/tap/fsp
scoop bucket add vaam-apps https://github.com/vaam-apps/scoop-bucket && scoop install fsp
```

**Or install nothing.** Once the package is in your `pubspec.yaml` (step 2), `dart run
fespalier <command>` runs `fsp` for you, so use it wherever this README says `fsp`:
`dart run fespalier init`, `dart run fespalier watch`, `dart run fespalier check`. The first
run downloads the `fsp` release that matches the package's version, checks its SHA-256 and
keeps it in your user cache (`~/.cache/fespalier` on Linux, `~/Library/Caches/fespalier` on
macOS, `%LOCALAPPDATA%\fespalier` on Windows; `FSP_CACHE_DIR` moves it), so later runs start
at once. The download is checked against the SHA-256 that this package carries for its own
version, so a tampered release is refused (a package built from a branch has no pins yet; it
then checks the release's `.sha256` file instead and says so). Offline with an empty cache it
stops with one line naming the missing version; with a warm cache it never uses the network.
It needs `tar`, which macOS, Linux and Windows 10+ include. Set `FSP_BINARY=/path/to/fsp`
to run a binary of your own, e.g. a build from source. An `fsp` on your `PATH` is used too when its
version is the package's, so nothing is downloaded when you have both. The package and the
binary are versioned together, and this is what keeps them in step.

**2. Add the package** to your app's `pubspec.yaml`, then run `flutter pub get`:

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/vaam-apps/fespalier
      path: packages/fespalier
      ref: v0.2.0
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
have it yet, and this `main.dart`). `not_found.dart` is optional: without it, unknown
paths get a plain "Nothing at /path" view. Other folders can have their own (see
[Not-found views](#not-found-views)).

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

`flutter create` also wrote `test/widget_test.dart`, which refers to the `MyApp` you just
replaced, so `flutter analyze` fails on it. Delete it, or rewrite it (see
[Testing](#testing)).

Already have a `GoRouter`? Mount the tree inside it instead. `at` is the URL prefix:

```dart
GoRouter(routes: [...yourRoutes, ...AppRoutes.mount(at: '/x')])
```

**4. Day to day.**

```sh
fsp watch                                 # next to `flutter run`: regenerates when the routing changes
fsp new 'orders/[id]' --data --loading    # scaffold a route, then regenerate app.g.dart
```

`fsp new` runs `gen` right away, so the new route is usable as soon as it returns. See
"The generator" for all flags.

**Two ways to keep `app.g.dart`.** Pick one.

*Commit it* (the default). `lib/app.g.dart` is plain code, meant to be read, and the app
builds without `fsp` installed. In CI, run `fsp check`. It writes nothing (it never touches
`app.g.dart`) and exits non-zero on routing errors:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
```

or, with nothing to install (after `flutter pub get`): `- run: dart run fespalier check`.

*Generate, don't commit.* For projects that never commit generated code (`**/*.g.dart` is
ignored already, and every generator runs before analysis). Add the file to `.gitignore`:

```gitignore
lib/app.g.dart
```

and generate it wherever the app is analyzed, tested or built: on a fresh clone, and in CI
**before** `flutter analyze`, because `app.g.dart` doesn't exist until then:

```yaml
- run: flutter pub get
- run: dart run fespalier gen   # writes lib/app.g.dart; fails on routing errors
- run: flutter analyze
- run: flutter test
```

The generator version needs no pin of its own: `dart run fespalier` runs the `fsp` release
that matches the `fespalier` package your `pubspec.lock` resolved, so the generator and the
runtime `app.g.dart` imports can't drift apart, and bumping the package bumps the generator.
The first run downloads it (SHA-256 pinned in the package, see above) into the user cache;
keep `~/.cache/fespalier` (`FSP_CACHE_DIR`) between CI runs with `actions/cache`, keyed on
`pubspec.lock`, to skip that. Set `FSP_BINARY` to use a binary you built. Locally,
`dart run fespalier watch` keeps the file current. `fsp check` still works in this mode
(it checks the routing and writes nothing), and doesn't need the generated file to exist.

**Config.** `fsp` needs no configuration. To move things, add this optional section to
`pubspec.yaml`. Both paths are relative to the project root and must be under `lib/`, and
`output` must be a `.dart` file. These are the defaults:

```yaml
fespalier:
  app_dir: lib/app
  output: lib/app.g.dart
  format: false
  case_sensitive: true
  data_retry: inherit
  keep_previous: true
  meta: optional            # `required`: every route needs a meta.dart
  # output_manifest: lib/app.routes.g.dart   # no default: the manifest lives in `output`
```

`format: true` runs `dart format` on the generated file (see [`fsp gen --format`](#the-generator)).
`case_sensitive: false` makes paths match in any case (see [Case and trailing slashes](#case-and-trailing-slashes)).
`data_retry` and `keep_previous` are about `data.dart` failures and reloads; see
[Retries and reloads](#retries-and-reloads).
`meta: required` makes a route without a [`meta.dart`](#route-manifest-and-metadart) an error, and
`output_manifest` writes the route manifest to a library of its own (same section).

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
| `page.dart` | a widget | segments; query; what `data.dart` yields; the navigation [`extra`](#typed-extra) |
| `data.dart` | `data(Ref ref, {…})` returning `Future<T>`, `Stream<T>` or `T` — **or** `ProviderListenable<AsyncValue<T>> data({…})` selecting a provider you have — **or** `final data = <Provider>(…)`. Beside a `page.dart` it feeds the page; in a page-less folder with a `layout.dart`, the whole [section](#section-data) | segments, query (named; a section's takes segments only) |
| `loading.dart` | a widget, inherited by subfolders | segments; query |
| `error.dart` | a widget, inherited by subfolders | segments; query; `error`, `stackTrace`, `retry` |
| `layout.dart` | a widget; wraps this folder and below (ShellRoute), or holds its subfolders as tabs | `child` or `navigationShell`; segments at or above it; query; the [section data](#section-data) it wraps or is inside |
| `guard.dart` | `GuardResult guard(ProviderContainer c, {…})`; `GuardResult` is `FutureOr<String?>`: a location to redirect to, or `null` to let the navigation through. Guards every route at and below its folder | `uri`; segments at or above its folder; query (named) |
| `redirect.dart` | `String redirect({…})` in place of `page.dart`: a route that only redirects; may take `ProviderContainer c` first | `uri`; segments; query (named) |
| `transition.dart` | `Page<…> transition(…)`; applies to this folder and below | `key`, `child`, `state` |
| `not_found.dart` | a widget, optional, in any folder ([nearest wins](#not-found-views); without one at the root, a plain "Nothing at /path" view); unknown paths and unparsable segments | `uri` |
| `meta.dart` | `const meta = <any const expression>;`, beside a `page.dart` or `redirect.dart`: that route's own facts, passed [untouched into the manifest](#route-manifest-and-metadart) | nothing: it is data |

### How parameters are filled

The generator reads each constructor (named or positional, `this.x` or typed) and fills
every parameter:

1. **By name.** A parameter named like a `$segment` in the path gets that segment.
   `data`, `child`, `navigationShell` (or `shell`), `error`, `stackTrace`, `retry`, `uri`
   and, in a page, `extra` get what their name says, in the files where they make sense.
2. **Query.** An *optional* parameter that is nullable or a `List` of
   `String`/`int`/`double`/`bool` is a query parameter: `int? page` gets `?page=2`, and
   `List<String> tags = const []` gets every `?tags=`.
3. **By type.** Otherwise, a page's parameter whose type is what `data.dart` yields gets
   the data, so `required this.product` with `final Product product;` works. (A page or
   layout below a [section](#section-data) can take the section's data the same way.) An error
   view's `Object` gets the error, `StackTrace` the stack trace and `VoidCallback` the
   retry. A layout's `Widget` gets the child, its `StatefulNavigationShell` gets the tab shell, and
   not-found's `Uri` gets the URI.
4. **Otherwise**, a required parameter is a generator error pointing at it. An optional
   one is left to its default.

These names are reserved, so segments can't use them. Parameters bound by name are
type-checked: `uri` must be a `Uri`, `child` a `Widget`, `error` an `Object`, `stackTrace`
a `StackTrace`, `retry` a `VoidCallback`, `navigationShell` a `StatefulNavigationShell`,
and a transition's `key` and `state` a `LocalKey` and a `GoRouterState`. Declaring one as
anything else is an error at that parameter (`Object` and `dynamic` always fit).

### Segment types

A segment's type comes from the parameters that ask for it: `{required int id}` in
`products/$id/data.dart` makes `$id` an `int` everywhere. That covers the typed
`ProductRoute(id: 42)`, the page, and parsing: `/products/abc` goes to `not_found.dart`.
Every file that asks for `$id` must agree on its type. When nobody gives one, a segment
is a `String`. Segments are `String`, `int`, `double` or `bool`.

`fsp new` scaffolds every segment as a `String`: `fsp new 'products/[id]' --data` writes
`data(Ref ref, {required String id})`. To make `$id` an `int`, change the parameter type
in each file that asks for it, then run `fsp gen` (or let `fsp watch` do it).

### Catch-all segments

`$$rest` matches **one or more** remaining segments, and `$$$rest` (three `$`) **zero or
more**. The page takes them as a `List<String>`, each part decoded on its own:

```
docs/page.dart            /docs                      the index, beside the catch-all
docs/new/page.dart        /docs/new                  a static sibling: tried first
docs/$$rest/page.dart      /docs/guide/setup/linux    rest == ['guide', 'setup', 'linux']
files/$$$path/page.dart   /files, /files/a/b         path == [] or ['a', 'b']
```

```dart
class DocsPage extends StatelessWidget {
  const DocsPage({super.key, required this.rest});
  final List<String> rest;      // `rest` is the segment: a List<String>, nothing else
  …
}

const DocsRoute(rest: ['guide', 'a b']).go(context);   // → /docs/guide/a%20b, each part encoded
const FilesRoute().location;                            // '/files'
```

How it works: go_router matches a path pattern with a regular expression, and a `:name`
parameter can carry its own (`:rest(.+)`, which may span `/`). A catch-all folder becomes a
route with that pattern, `docs/:rest(.+)`, so deep links, redirects and `go` all use go_router's
normal matching. `$$$rest` is two routes with one builder: the folder's path (`/files`) and
the same with `:path(.+)`. Reading the parts takes go_router's decoded string apart *by the
requested location*, so an encoded slash (`/docs/a%2Fb/c` is `['a/b', 'c']`) survives.

- Siblings are tried in this order: static, then dynamic (`docs/$id`), then the catch-all,
  whatever the folder order. A page that another route always catches first is still
  reported as unreachable, including by a catch-all (`(wiki)/docs/$$rest` behind
  `$a/$$rest`).
- `guard.dart`, `redirect.dart`, `layout.dart`, `loading.dart` and `error.dart` can take the
  parts like any segment (`{required List<String> rest}`).
- `data.dart` can be keyed by them. Lists compare by identity, so the generated provider is
  keyed by the encoded path as one string (`restKey`) and `data()` gets the list back
  (`restParts`). `ref.watch(DocsRoute.data(restKey(rest)))` is what the route does; the
  typed `DocsRoute.watch(ref, rest: [...])` takes the list. A provider you write yourself
  (`final data = FutureProvider.family<…>`) can't be keyed by a catch-all: use the function
  or a [selector](#datadart-a-function-a-selector-or-a-provider), whose `data({required List<String> rest})`
  gets the list back the same way.
- `$$$rest` and a `page.dart` in the folder above would both serve `/docs`: an error. Use
  `$$rest` beside the page.

Limits: a catch-all is always the last segment and a `List<String>` (no `List<int>`); nothing
can be below its folder, and it can't have a `not_found.dart` (it matches every URL under
it). A catch-all as a tab's first route needs a `tabOptions` `initialLocation`, like any
route with a parameter. A part of `.` or `..` is read as a dot segment by the URL parser, so
`DocsRoute(rest: ['..'])` doesn't reach a `..` part. `fsp new 'docs/[...rest]'` and
`'docs/[[...rest]]'` write the folders, so you don't have to quote `$`.

### Case and trailing slashes

**Trailing slashes.** `/products/` reaches `/products`: go_router drops a trailing slash
before it matches (also in front of a query, `/products/?page=2`), whether it comes from a
deep link, `initialLocation` or `context.go`. There is nothing to configure, and typed
locations never end in one. (Checked against go_router 17.5 and 18.)

**Case.** Paths are case-sensitive, like go_router's default: `/Products` isn't
`/products`. Set `case_sensitive: false` in the pubspec's `fespalier:` section to emit
`caseSensitive: false` on every route:

```yaml
fespalier:
  case_sensitive: false
```

Static parts then match in any case (`/PRODUCTS/Guide` finds `products/guide`), and the
parts you take out of the URL (a `$segment`, a catch-all) keep the case they had. The
nearest-`not_found.dart` lookup compares folder names the same way. Typed routes still write
the paths as the folders spell them. The option is global; there is no per-folder setting.

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
query parameters like any other layout. A tab layout folder without its own `page.dart` has
no route at its own path: link to one of its tabs' routes instead.

Routes outside the layout's folder aren't in any tab, so they cover the whole screen: in
`examples/tabs`, `/settings` has no navigation bar and `/profile/edit` does. Two things to
know: go_router opens a tab on its first route, which can't have a `:segment` in its own
path, so a tab made only of dynamic routes, or a tab layout placed directly in a
`$folder`, is an error (put the layout in a `(group)` below that folder instead); and `tabs` in a tab layout must be string literals, so name another list of destinations
something else. See `examples/tabs`.

**Nested tab layouts.** A tab layout can sit inside a tab of another one: put a
`layout.dart` that takes a `StatefulNavigationShell` in a folder that is a branch of the
outer layout. Each layout has its own `tabs` list, its own navigation stacks and its own
`StatefulNavigationShell`, and the outer layout keeps the whole inner one alive while you
look at another outer tab, so an inner tab's state survives switching outer tabs. The same
rules apply at each level: an inner tab can't start on a route with a `:segment` in its
path, and a tab layout in a `$folder` is an error.

```
lib/app/(tabs)/
  layout.dart              const tabs = ['(home)', 'search', 'library']; takes a shell
  (home)/page.dart
  search/page.dart
  library/                 the third outer tab...
    layout.dart            ...is itself a tab layout: const tabs = ['books', 'authors'];
    books/page.dart          /library/books
    authors/page.dart        /library/authors
```

`library/` has no page of its own here, so its inner layout is what the outer tab shows.
Give it a `page.dart` and that page becomes the inner layout's first tab, like any tab
layout's own page. In `examples/tabs` the Library tab is built this way; its tests check
that a counter in an inner tab survives switching inner and outer tabs.

**Tab options.** A tab layout can set go_router's `StatefulShellBranch` options per tab in
a top-level `const tabOptions` map, next to `tabs`. Keys are the tab names `tabs` uses
(`'.'` for the layout's own page), and each value is a `TabOptions` from
`package:fespalier/fespalier.dart`:

```dart
const tabOptions = {
  'search': TabOptions(preload: true),
  'profile': TabOptions(initialLocation: '/profile/edit'),
};
```

- `preload: true` builds the tab as soon as the layout first shows, instead of on its
  first visit.
- `initialLocation` is where the tab opens the first time, and where tapping its current
  tab goes with `goBranch(i, initialLocation: true)`, instead of the tab's first route. It's
  an app location such as `/profile/edit` (with `?query` if you like), written as a
  string literal. It must be a route inside that tab, and `fsp` checks that (dynamic routes
  match any value: `/items/1` for `items/$id`). It also lets a tab that has only dynamic
  routes work, since go_router then doesn't need a first route without a `:segment`. When
  mounted with `AppRoutes.mount(at: '/x')`, the mount point is added for you.

Like `tabs`, `tabOptions` is read from the source, not run: it must be a map literal with
string-literal keys and `TabOptions(...)` values with `true`/`false` and string-literal
arguments. Unknown tabs, repeated tabs, unknown options and other values are errors that
point at the offending entry. Only tabs that need options are listed.

### Guards

`guard.dart` exports `GuardResult guard(ProviderContainer c, {…})`. It returns a location to
redirect to, or `null` to let the navigation through, and may be async. It guards every
route at and below its folder, and the folder needs no `page.dart`: put one in a `(group)` or
at the root to cover a whole section of the app.

```dart
// lib/app/(members)/guard.dart: guards /inbox, /admin and everything else in the group
GuardResult guard(ProviderContainer c, {required Uri uri}) =>
    c.read(session) ? null : LoginRoute(from: uri.toString()).location;
```

- **Order.** Guards run outermost first, and the first one to return a location wins. A
  folder with a page and its own guard keeps its guard for that page and everything nested
  in it; guards above it run first.
- **Parameters.** The `ProviderContainer` comes first, then named parameters: `uri` (the
  requested location, a `Uri`), the segments of the guard's own folder and the ones above
  it (`{required String shop}`), and query parameters (optional and nullable, `String? ref`).
  A guard above `$id` can't ask for `id`: that's an error at the parameter. Segments are
  typed like everywhere else. A guard's query parameters stay its own: they don't become
  fields of the typed routes below it (unless the guard sits next to a `page.dart`, where
  they are the page's, as before).
- **What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in order, the
  guards of the page-less folders above it and then its own. Nested pages go through their
  parent's `redirect`, so no guard runs twice. There's no redirect on `ShellRoute` or
  `StatefulShellRoute`: go_router runs a matched route's redirect for deep links and for
  navigation inside a shell, tabs included, so the page routes are enough (and a page-less
  folder has no route to put one on). When a path has a segment that doesn't parse
  (`/products/abc`), guards are skipped and not-found is shown.
- A `guard.dart` with no `page.dart` or `redirect.dart` at or below its folder is a warning.

### `redirect.dart`

A folder can hold `redirect.dart` instead of `page.dart`. It exports `String redirect({…})`
(or `Future<String>`) returning the location to go to, and the route only redirects: no
widget, no builder.

```dart
// lib/app/old-products/$id/redirect.dart: /old-products/3 → /products/3
String redirect({required int id}) => ProductRoute(id: id).location;
```

It takes the same parameters as a guard, except that `ProviderContainer c` is optional (put
it first if you need providers). Segments are typed like anywhere else, so `/old-products/abc`
shows not-found. It gets a typed route, named after its path (`OldProductsIdRoute(id: 3)`),
so links to the old URL stay typed; query parameters it asks for are its fields. It takes part in
route order and unreachable checks like a page, inherits the guards above it, and can sit
next to a `guard.dart`, which runs first. A folder has a `page.dart` or a `redirect.dart`,
not both, and a tab layout's own folder can't hold a `redirect.dart`. Routes in subfolders
sit beside a redirect route rather than inside it, since anything inside would redirect too.

### Sending people back

A guard that redirects to a login page can pass along where the user was going. Ask for
`Uri uri` (the requested location, query included) and put it in the login route's query:

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent
```

`login/page.dart` takes it as a query parameter (`this.from`, a `String?`), and when the
user is done it calls `returnTo`:

```dart
context.go(returnTo(from));                  // from if it's a location in the app, else '/'
```

`returnTo(from, fallback: '/home')` only lets an absolute path through: `https://…`, `//host`
and the like fall back, so a crafted `?from=` can't send people off your app. Both `uri` and
the typed routes include the mount prefix when the tree is mounted with `at:`.

### Not-found views

A `not_found.dart` at the root is the app-wide one. Any other folder can have one too, and
the nearest wins, for two things:

- **Unknown paths.** An unknown URL shows the `not_found.dart` of the deepest folder it is
  under (a `$dynamic` folder matches any value), or the root's. With `teams/$teamId/not_found.dart`
  and `teams/$teamId/members/not_found.dart`, `/teams/a/members/1/x` shows the members one,
  `/teams/a/x` the team one, and `/nope` the root's. This is what `AppRoutes.notFound(uri)`
  does, and the router's `errorBuilder` calls it. The view shows without any layout, as ever.
- **Unparsable segments.** `/teams/a/members/abc`, where a member's id is an `int`, shows the
  nearest `not_found.dart` above that route (a `(group)`'s counts here).

It still only gets `Uri uri`. A `(group)` folder adds nothing to the URL, so its
`not_found.dart` can't be picked for unknown URLs: only for its own routes' bad segments.
Two folders with the same URL (`(a)/x` and `(b)/x`) can't both have one; that's an error.
When the tree is mounted under a prefix (`mount(at: '/shop')`), the prefix is skipped when
looking for the folder, and a URL outside it gets the root's.

### Transitions

`transition.dart` says how a route animates in. It applies to its folder's route and
every route below it, and the nearest one wins. A `transition.dart` at the root is the
app-wide default; any folder or `(group)` folder can override it for its own routes.

The function returns a `Page`, and takes the page's key as `LocalKey key`, the page
itself as `Widget child`, and optionally `GoRouterState state`. `Transitions` has
ready-made ones: `fade`, `slide`, `none`, `material`, `cupertino`, and `dialog`, `sheet`
and `fullscreenDialog` (below).

```dart
// lib/app/transition.dart: every route fades in, unless a folder overrides it
Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);
```

**Dialogs and sheets.** `Transitions.dialog`, `Transitions.sheet` and
`Transitions.fullscreenDialog` make a route open over the previous page instead of
replacing it. The page's widget is what shows up: for `dialog` it is the dialog itself
(an `AlertDialog`, a `Dialog` or your own card, as in `showDialog`'s builder), for `sheet`
the sheet's content (wrapped in a `Material`), and `fullscreenDialog` is a Material page
that slides up, with a close button in its `AppBar`.

```dart
// lib/app/photos/$id/transition.dart: /photos/:id is a dialog over /photos
Page<void> transition(LocalKey key, Widget child) => Transitions.dialog(key, child);

// lib/app/photos/sort/transition.dart
Page<void> transition(LocalKey key, Widget child) =>
    Transitions.sheet(key, child, showDragHandle: true);
```

They are real Navigator routes (a `DialogRoute` and a `ModalBottomSheetRoute` made by the
page), so everything works as it does for `showDialog`: `context.pop()`, the back button
and the barrier pop the route, and `dialog` and `sheet` take options such as
`barrierDismissible`, `isScrollControlled` and `enableDrag`. A few things to know:

- **Put the route below a page.** The page underneath stays built and visible. go_router
  builds a deep link's stack from the parents that have a page, so with `photos/page.dart`
  above `photos/$id/`, `/photos/7` opens the dialog over `/photos`. Without a parent page,
  the dialog opens over an empty screen.
- **They cover their own navigator only.** Inside a tab, a dialog covers that tab's
  navigator, not the tab layout's navigation bar; the same goes for a `layout.dart`'s
  body. Put the route outside the layout's folder to cover the whole screen.
- **They need `MaterialLocalizations`,** like `showDialog` and `showModalBottomSheet`: a
  `MaterialApp` (or a `Localizations` with the Material delegate) above the router.
- The route's `transition.dart` also covers routes below it, so give a dialog route its own
  folder.

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
`/search?page=2` and `?page=3` load separately. A `List` works as a key too: lists
compare by identity, so the generated provider is keyed by a `QueryList` (a `List` with value
equality, exported by fespalier) holding the same elements, and `?tags=a&tags=b` is one provider
however many times the page builds a new list. Your `data()` still takes and receives a plain
`List<String>`, and the typed helpers take one (`SearchRoute.watch(ref, tags: ['a', 'b'])`).
Order counts: `[a, b]` and `[b, a]` are different keys. (A provider you write yourself can't
be keyed by a query parameter, only by segments.)

```dart
// search/data.dart
Future<List<Hit>> data(Ref ref, {String? q, int? page, List<String> tags = const []}) => …;

// search/page.dart
class SearchPage extends StatelessWidget {
  const SearchPage({super.key, required this.hits, this.q, this.tags = const []});
  final List<Hit> hits;        // required, and data.dart's type → the data
  final String? q;             // optional and nullable → ?q=
  final List<String> tags;     // optional List → every ?tags=
  …
}
```

### Typed `extra`

go_router can carry an object with a navigation, `context.go(location, extra: product)`,
that isn't part of the URL. A page asks for it with a parameter called `extra`, and the
typed route takes it as an optional argument:

```dart
// notes/$id/page.dart
class NotePage extends StatelessWidget {
  const NotePage({super.key, required this.id, this.extra});
  final int id;
  final Note? extra;      // nullable: the URL alone can't produce it
  …
}

NoteRoute(id: 3).go(context, extra: note);      // also push<T>(…, extra:) and replace(…, extra:)
NoteRoute(id: 3).go(context, extra: 'oops');    // compile error: a String isn't a Note?
```

The parameter **must be nullable** (`Note?`, `Object?` or `dynamic`; anything else is an
error at that parameter). The object isn't in the URL, so a deep link, a reload, a page
opened from `context.go('/notes/3')` and a restored state all get `null`: build the page
from the URL (`id`) and treat `extra` as a shortcut, not the source of truth. Passing an
object of the wrong type around the typed route (a plain `context.go(location, extra: …)`)
is an assertion error in debug builds and reads as `null` in release builds.

`extra` is a page-only name: a segment can't be called `extra`, and a query parameter of
that name is the extra, not `?extra=`. The generated file has to name the type for the
typed arguments, which is the one place it copies from your imports: it imports the type
`show`ing that name from each of `page.dart`'s imports (a library that doesn't export it is
ignored; a type declared in `page.dart` itself, or under an import prefix, is found too),
so the type must be reachable from `page.dart`'s own imports. The built-in `dart:core`
types need nothing. Only pages take an `extra`; go_router's `extra` isn't restored on web
reloads unless you give the router an `extraCodec`.

### `data.dart`: a function, a selector or a provider

`data.dart` has three forms, told apart by what it exports:

| You write | fespalier | Use it when |
|---|---|---|
| `Future<T> data(Ref ref, {…})` (or `Stream<T>`, or `T`) | wraps it in an autoDispose `FutureProvider` (`StreamProvider` for a `Stream`) | the data is fetched for this route only: the function is the fetch |
| `ProviderListenable<AsyncValue<T>> data({…}) => productProvider(id)` | calls it and uses the provider it returns; nothing is wrapped | a provider for it already exists, above all a `riverpod_generator` one |
| `final data = FutureProvider<T>(…)` (or `StreamProvider`, `AsyncNotifierProvider`, `StreamNotifierProvider`), type arguments spelled out | uses it as-is | you want to write the provider yourself (a notifier, `keepAlive`, `retry:`) and it belongs to this route |

**Selecting a provider.** Don't write `Future<Product> data(Ref ref, …) => ref.watch(productProvider(id).future)`
for a provider you have: that puts a second provider in front of the real one, and awaiting
`.future` in it drops the error the real provider holds while it retries, so the route
can't show `error.dart` during the retry window. Select the provider instead:

```dart
// lib/app/products/$productId/data.dart
ProviderListenable<AsyncValue<ProductView>> data({required String productId}) =>
    productProvider(productId);   // a generated family, a FutureProvider.family, ...
```

- **The return type is what says so.** `ProviderListenable<AsyncValue<T>>` with no `Ref`
  parameter (the function returns the provider, it doesn't read one). `T` is what the
  page's parameter is matched to by type, as with `Future<T>`. It's a syntax-only read of the
  return type: a generated provider's own type, like `ProductFamily`, isn't resolved.
  `ProviderListenable` comes from `package:fespalier/fespalier.dart`.
- **Parameters are the function form's.** Named parameters are segments and query
  parameters, keyed and typed exactly as in `data(Ref ref, {…})` below; any other parameter is
  an error at that parameter. Positional parameters and a `Ref` are errors too.
- **`XRoute.data` is the selected provider** (`ProductDetailRoute.data('x') ==
  productProvider('x')`), and `watch`, `read`, `prefetch` and `refresh` all go to it. The
  generated `DataView` watches it directly: no wrapper, no `.future` hop, one fetch per
  navigation. `refresh` (and `error.dart`'s `retry`) invalidates the selected provider, and
  `refresh` reads it again, so it runs once.
- **The app's provider keeps its own `retry`, `keepAlive` and dependencies**, so
  [`data_retry`](#retries-and-reloads) doesn't apply to it: it only configures the providers
  fespalier creates. `keep_previous` does (it is about what the view shows). The app's
  `ProviderScope(retry: …)` applies unless the provider sets its own.
- **Refresh needs a provider, not just a listenable.** Watching only needs a
  `ProviderListenable`, but invalidating needs the provider itself. The declared type stays
  `ProviderListenable<AsyncValue<T>>`, the same for every kind of provider, and the runtime
  checks what it gets (a `ProviderOrFamily` with a `.future`, which every
  `FutureProvider`, `StreamProvider` and generated async provider is). Returning
  something else, say `productProvider(id).select(…)`, builds and watches fine, but
  `refresh` and `retry` throw a `StateError` that says to return the provider itself.
- A section's `data.dart` can be a selector too (segments only).

The other two: write a function and fespalier wraps it in an autoDispose
`FutureProvider` (or `StreamProvider` for a `Stream`). Or export a provider named `data` yourself:
`FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or `StreamNotifierProvider`,
with its type arguments spelled out. It's used as-is.

In all three forms the route exposes it as `XRoute.data`, keyed by the segments and query
parameters `data.dart` uses:

| Parameters used | Provider | Watch it with |
|---|---|---|
| none | plain | `ref.watch(ProductsRoute.data)` |
| one | `.family<T, int>` | `ref.watch(ProductRoute.data(42))` |
| several | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

A family provider you write yourself follows the same rule. With several parameters, or
with query parameters, its argument is a record naming the ones it uses, e.g.
`({int id, int? page})`.

To see a scaffolded `error.dart` and its retry, throw from `data.dart`, e.g.
`throw Exception('offline')`.

#### Retries and reloads

Two settings in the `fespalier:` section of `pubspec.yaml` decide what a route shows while
its `data.dart` fails or loads again:

```yaml
fespalier:
  data_retry: inherit   # inherit | none
  keep_previous: true   # true | false
```

**`keep_previous: true` (the default).** `loading.dart` is only for the first load. Once
the provider has a value or an error, a reload (`ref.invalidate`, `refresh`, the section's
dependencies changing) keeps rendering it: the old page stays until the new value arrives,
instead of blinking to `loading.dart` and back. `error.dart`'s `retry` still invalidates the
provider; the error stays up until the new run has an answer. Off, `loading.dart` shows
whenever the provider is loading (a refresh included). This is `skipLoadingOnReload` and
`skipLoadingOnRefresh` on Riverpod's `AsyncValue.when`. It applies to a route's `data.dart` and
to a section's, including a provider you write yourself.

**`data_retry: inherit` (the default).** Riverpod 3 retries a failed provider on its own,
with backoff, and the app's `ProviderScope(retry: ...)` or `ProviderContainer(retry: ...)`
decides how. The providers fespalier generates for `data()` functions don't set their own
policy, so the app's applies. An app that wants a failure to settle into `error.dart` after
a few attempts writes:

```dart
ProviderScope(
  retry: (retryCount, error) => retryCount < 3 ? const Duration(seconds: 1) : null,
  child: …,
)
```

Riverpod's own default (10 retries with doubling delays, none for an `Error`) applies when the
app sets none. A provider you write yourself always follows the app's policy, or its own `retry:`.

Together the two make `error.dart` show as soon as `data.dart` fails, retrying or not:
a provider that failed and is being retried is `AsyncLoading` with its error still held, and
with `keep_previous` on `DataView` shows that error, not `loading.dart`, for the whole retry
window. It goes to the data when a retry succeeds, and stays on the error when the policy gives up.
With `keep_previous: false` a retry shows `loading.dart` again.

**`data_retry: none`.** Every generated `data()` provider gets
`retry: (retryCount, error) => null`, whatever the app's policy is: a failure is final until
`error.dart`'s `retry` runs it again, which is how 0.1.1 behaved.

### Typed helpers on the route

A route with a `data.dart` has three more helpers next to `.data` and `.refresh`:

```dart
final product = ProductRoute.watch(ref, id: 42);   // AsyncValue<Product>, for build()
final p = await ProductRoute.read(ref, id: 42);    // Future<Product>, for callbacks
ProductRoute(id: 42).prefetch(ref);                // void, before navigating
```

`watch` and `read` are *static*, and take the keys the provider uses as named arguments
(`ItemRoute.watch(ref, shop: 'a', id: 1)`, `SearchRoute.watch(ref, q: 'ap', page: 2)`;
none for a route without keys). They can't be instance methods: `ProductRoute(id: 42).watch(ref)`
would have to write `AsyncValue<Product>` into the generated file, and the generator never
copies your imports. A static function value takes its type from the provider by
inference, so `Product` flows through and is never `dynamic`.

`read` keeps the provider alive until it completes, which a plain `ref.read(p.future)`
doesn't for an `autoDispose` provider. Don't call it from `build`.

`prefetch(ref, {keepFor})` starts the load and keeps the result for `keepFor` (30 seconds
by default), so the page you navigate to next shows it at once. The generated providers
are `autoDispose`, so a prefetch nobody watches would be dropped in the same frame; this is
why it holds on to it, and it lets go when the time is up. A failed load isn't kept:
the page starts a fresh one instead. Call it before `go`, e.g. on hover:

```dart
MouseRegion(
  onEnter: (_) => ProductRoute(id: p.id).prefetch(ref),
  child: ListTile(onTap: () => ProductRoute(id: p.id).go(context), …),
)
```

Two things to know: it lives as long as the widget whose `ref` you pass (a widget that is
disposed ends it), and it holds a timer, so a widget test that prefetches should `pump`
past `keepFor` (or pass `keepFor: Duration.zero`, which starts the load and keeps nothing).
Because these are members of the route class, `watch`, `read`, `prefetch`, `refresh`, `ref`
and `keepFor` can't be segment or query names.

### Section data

A folder with a `layout.dart` and no `page.dart` (a `(group)`, or a plain folder that only
holds routes) can have a `data.dart` too. It is then the data of the whole section: the
layout waits for it, and the layout and the pages below can take it.

```dart
// lib/app/teams/$teamId/data.dart
Future<Team> data(Ref ref, {required String teamId}) => …;

// lib/app/teams/$teamId/layout.dart: by type (or a parameter named `data`)
class TeamLayout extends StatelessWidget {
  const TeamLayout({super.key, required this.team, required this.child});
  final Team team;
  final Widget child;
  …
}

// lib/app/teams/$teamId/members/page.dart: the page takes it by type as well
class MembersPage extends StatelessWidget {
  const MembersPage(this.team, {super.key});
  final Team team;
  …
}
```

- **Loading and errors.** While the section loads, the nearest `loading.dart` (inherited as
  usual) replaces the layout *and* the pages inside it, and a failure shows the nearest
  `error.dart` with its `retry`. Nothing below is built until the data is there.
- **Sharing.** The layout watches the provider and the pages below read the same one, so
  `data()` runs once however many of them take it, and moving between the section's pages
  doesn't load it again. When the data reloads (`retry`, an invalidation), the section keeps
  showing what it has (`keep_previous`; with `keep_previous: false` it shows loading again).
- **Which one.** A parameter called `data` gets the nearest data: the route's own
  `data.dart`, then the section's, then the next section up. By type, a parameter gets the
  data.dart that yields that type, and it is an error if two do (a page's own and a
  section's, or two sections'): name the parameter `data` for the nearest, or give one of
  them another type. A page can have its own `data.dart` and take a section's by type.
- **Keys.** A section's `data()` takes segments only (at or above its folder), not query
  parameters: the pages below have to compute the same key. It has no typed route class of
  its own; write `final data = FutureProvider…` yourself if you need to reach it elsewhere.
- **Where it applies.** A layout of any kind can be a section's, tab layouts included. A
  `data.dart` beside a `page.dart` keeps feeding that page, so the folder that holds the
  section's layout mustn't have a page.

### Route manifest and `meta.dart`

The generator knows a lot about every route (its typed route, path, folder, groups and
layouts, parameters), and only a person can write the rest (a stable review code, a page title,
an analytics name). The manifest puts the first at runtime, next to the second.

```dart
final info = AppRoutes.byType[ProductRoute]!;   // or AppRoutes.byPath['/products/:id']
info.path;      // '/products/:id'
info.folder;    // r'(buyer)/products/$id'
info.groups;    // ['(buyer)']
info.meta;      // whatever lib/app/(buyer)/products/$id/meta.dart declares
AppRoutes.all;  // every route, in the order of the table at the top of app.g.dart
```

`AppRoutes.all`, `byType` (typed-route class → info) and `byPath` (path template → info) are
generated as `AppManifest`, a `const` list of `RouteInfo`s, and forwarded by `AppRoutes`.
Each `RouteInfo<M>` has:

| Field | |
|---|---|
| `type` | the typed-route class: `ProductRoute` |
| `path` | the path template, without the mount point: `/products/:id`; a [catch-all](#catch-all-segments) is `/docs/*rest`, or `/files/*path?` when optional (as in `fsp routes`). Case-insensitive paths (`case_sensitive: false`) don't change it |
| `folder` | the route's folder relative to the app folder: `(buyer)/products/$id` (empty for the app folder itself) |
| `presentation` | `RoutePresentation.page`, or `.redirect` for a `redirect.dart` (`isRedirect`). Whether a page opens as a dialog or sheet is up to its `transition.dart` at runtime, so it isn't listed |
| `groups` | the `(group)` folders above it, outermost first, parentheses included |
| `layouts` | the folders of the layouts that wrap it, outermost first (`''` is the app folder's own layout) |
| `segments`, `query` | `RouteParam(name, type)`: `('id', 'int')`, `('page', 'int?')`, `('tags', 'List<String>')`. A catch-all is the last segment, a `List<String>` with `catchAll: true` |
| `tabs` | the tabs it sits in, outermost first: `RouteTab(layout, index, branch)`, where `branch` is the name `tabs` and `tabOptions` use (`.` for the layout's own page); empty outside tab layouts |
| `dataKeys` | what its `data.dart` is keyed by; `null` without one |
| `meta` | its `meta.dart`, as declared |

**`meta.dart`.** Put `const meta = <any const expression>;` next to a `page.dart` (or
`redirect.dart`), and the generator copies it into the manifest *by reference*
(`meta: _i7.meta`), never re-spelling it. fespalier doesn't interpret it; use any type:

```dart
// lib/app/(buyer)/products/$id/meta.dart
import 'package:my_app/page_meta.dart';

const meta = PageMeta(code: 'B04', slug: 'product-detail', title: 'Product');
```

- **It is per route, not inherited.** A route gets its own folder's `meta.dart` or none, so
  `photos/sort/` doesn't see `photos/meta.dart`. To share something (a role, say), keep it in
  the group: `info.groups` already lists it.
- **It must be `const`.** The manifest is a `const` list. A `meta` that is `final`, `var` or a
  getter is an error at its declaration, and so is a `meta.dart` that declares no `meta`.
  A `meta.dart` in a folder with no `page.dart` or `redirect.dart` is a warning: it describes no route.
- **It can be required.** With `fespalier: { meta: required }` in `pubspec.yaml`, a route without a
  `meta.dart` is an error that names its folder:
  `` `products/$id/` has no meta.dart ``. fespalier never numbers, derives or defaults
  anything in it: a review code is yours, and finding a duplicate is a few lines in a test over
  `AppRoutes.all` and `metaAs`.
- **Read it typed** with `info.metaAs<PageMeta>()` (null when the route has none, or it is
  another type), or check `info.meta is PageMeta`. The list holds `RouteInfo<Object?>`.

**A library of its own.** `meta.dart` files pull whatever they import into `app.g.dart`, and so into
your app. To keep review-only metadata out of production code, write the manifest to a second
file:

```yaml
fespalier:
  output_manifest: lib/app.routes.g.dart
```

`app.g.dart` then has no manifest and no `meta.dart` import, and `lib/app.routes.g.dart` (which
imports `app.g.dart` for the typed routes) holds `AppManifest` with the same `all`, `byType`
and `byPath`. Import it only where you need it (tests, a review screen), and production code
that imports `app.g.dart` alone never sees a `meta.dart`. `AppManifest` is the same name in both
modes, so code that uses it doesn't change when you move the file; `AppRoutes.byType` exists
only when the manifest is in `app.g.dart`. `fsp gen` writes both files, `fsp check` checks what
either would say, `fsp watch` regenerates both, and both are committed like `app.g.dart` is
(see `examples/tabs`).

**Web tab titles.** A layout can read the route it is showing with
`AppManifest.of(GoRouterState.of(context))` (null in a not-found view), and set the title of the
browser tab with Flutter's `Title` widget. No meta schema is baked in: whatever your type
calls it works.

```dart
// lib/app/layout.dart
class AppLayout extends StatelessWidget {
  const AppLayout({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final info = AppManifest.of(GoRouterState.of(context));
    return Title(
      title: info?.metaAs<PageMeta>()?.title ?? 'My app',
      color: Theme.of(context).colorScheme.primary,
      child: Scaffold(body: child),
    );
  }
}
```

`AppManifest.of` looks the path up in `byPath` after taking `AppRoutes.base` off, so it also
works under `AppRoutes.mount(at: '/shop')`, and for catch-all routes (go_router's `:rest(.+)` is
matched to `*rest`, and an optional catch-all's bare path to its route). See `examples/features`, which does this and tests it.
The same lookup gives analytics screen names (`info.path`, or a name in your meta) from a
`NavigatorObserver`.

**`fsp routes --json`** prints the same data, one object per route. Besides `pattern`, `route`,
`file`, `tags` and `params` it has the manifest's fields, in this order (paths in `file` and `meta`
are relative to the project root; `folder`, `layouts` and `tabs[].layout` to the app folder):

```json
{"pattern":"/products/:id","route":"ProductRoute","file":"lib/app/(buyer)/products/$id/page.dart","tags":["data"],"params":[{"name":"id","type":"int","in":"path"},{"name":"tab","type":"String?","in":"query"}],"folder":"(buyer)/products/$id","presentation":"page","groups":["(buyer)"],"layouts":["(buyer)"],"tabs":[],"data_keys":["id"],"meta":"lib/app/(buyer)/products/$id/meta.dart","catch_all":null}
```

`presentation` is `page` or `redirect`; `tabs` is `[{"layout":"(tabs)","index":0,"branch":"search"}]`
for a route in a tab; `data_keys` and `meta` are `null` when the route has no `data.dart` or
`meta.dart`. The meta itself is Dart, so JSON only says where it is. `catch_all` is
`{"name":"rest","optional":false}` for a route that ends in a `$$rest` (or `$$$rest`, `"optional":true`)
catch-all, else `null`; the catch-all is also in `params` as a `List<String>` path parameter.

### State restoration

Pass a scope id to the router, and give the app one too, and Flutter saves what the user was
doing when the OS kills the app, and puts it back on the next launch:

```dart
MaterialApp.router(
  restorationScopeId: 'app',
  routerConfig: AppRoutes.router(restorationScopeId: 'router'),
);
```

Without the ids nothing changes. With them, the location comes back (also for routes deep in
a stack), and so does everything below:

- **Tabs.** Each tab layout and each of its tabs gets a stable `restorationScopeId` from its
  folder (`layout:(tabs)/`, `tab:(tabs)/search`; `.` is the layout's own page), so the selected
  tab *and* the stack of every tab you visited are restored, nested tab layouts included.
- **Layouts.** A plain layout's Navigator gets one too (`layout:(account)/`).
- **Pages.** What a page keeps in a `RestorationMixin` (a `RestorableInt` for a form field or a
  scroll offset) comes back if the page has a `restorationId`. go_router's own pages have
  one; the ones `Transitions.*` build take it from the page key; a `Page` you build in a
  `transition.dart` should pass `restorationId: key.value` too (or its state won't be restored).

The reason layouts need generated pages: go_router keys the page of a `ShellRoute` or
`StatefulShellRoute` by the route object's `hashCode` and uses it as the restoration id, which
changes on every launch, so nothing under it can be found again. The generated router builds
these pages with `layoutPage(...)`, with an id from the layout's folder instead. It's a
Material page (a Cupertino one inside a `CupertinoApp`); a layout's page is not where a
route transition happens, so this changes nothing you see.

Ids come from folder names, so renaming a folder drops what was saved under the old one, once.
`examples/tabs/test/restoration_test.dart` restores the selected tab, a background tab's stack
and a page's `RestorableInt` with `tester.restartAndRestore()`. Build the router in a
`State`, not a `final`, in such a test: a router remembers where it went.

## The generator

`cli/` is a Rust binary, `fsp`. A full scan, check and emit of an example runs in a few
milliseconds, fast enough to run on every save.

`fsp` installs as described in [Getting started](#getting-started). To build it from a
checkout, run `cd cli && cargo build --release` (→ `cli/target/release/fsp`). Commands:

```sh
fsp init                # first-time setup: starter files, then gen
fsp gen                 # check lib/app/, write lib/app.g.dart
fsp gen --format        # ...and run `dart format` on it
fsp routes              # print the route table (--json: one object per route)
fsp watch               # same, whenever the routing changes (keep it next to `flutter run`)
fsp check               # CI: non-zero exit on errors, writes nothing
fsp new 'products/[id]' --name Product --data --loading --error --layout --guard --transition
                        # [id] or :id both mean $id, so no shell quoting of $
fsp new '(account)' --layout    # a (group) folder: layout only, no page.dart
```

All commands take `--project <dir>` (default: the nearest folder with a `pubspec.yaml`).
`fsp new` writes `page.dart` (plus the kinds you ask for with flags), skips files that
already exist, and takes its class names from `--name` (default: from the path, e.g.
`ProductsId`). A segment that already has a type elsewhere in the tree keeps it. Pass
`--no-page` to leave `page.dart` out. A `(group)` target (like `'(account)'`) gets no
`page.dart` either, since a group has no URL of its own; write one by hand if you want the
group to serve its parent's URL. It then regenerates `lib/app.g.dart` and prints the
result line; if that fails, it lists the files it created. After `fsp new '(account)'
--layout`, the generator warns "folder has no page.dart and no routes below it; skipped"
until you add a route inside the group. That's expected.

`fsp routes` prints what the header of `lib/app.g.dart` lists: each route's URL pattern, its typed
route class, its `page.dart` and its tags (`data`, `guard`, `layout`, `transition`).

```
/products/:id  ProductRoute   products/$id/page.dart  (data, transition)
```

With `--json` it prints one JSON object per line, for scripts and editors, with each
route's parameters and the [manifest](#route-manifest-and-metadart)'s fields; `file` is relative to
the project root:

```json
{"pattern":"/products/:id","route":"ProductRoute","file":"lib/app/products/$id/page.dart","tags":["data","transition"],"params":[{"name":"id","type":"int","in":"path"}],"folder":"products/$id","presentation":"page","groups":[],"layouts":[],"tabs":[],"data_keys":["id"],"meta":null,"catch_all":null}
```

**`--json` diagnostics.** `fsp gen --json` and `fsp check --json` print each diagnostic to
stdout as one JSON object per line, instead of the rendering below, so an editor can turn them
into squiggles. The success and failure lines still go to stderr, and stdout is empty when
there is nothing to report:

```json
{"file":"lib/app/shops/$shop/items/$id/page.dart","line":6,"column":18,"severity":"error","message":"can't fill `label`: ..."}
```

`line` and `column` count from 1 (the column counts characters, not bytes) and are `null` for
a diagnostic that isn't about a place in a file. `severity` is `error` or `warning`.

**Editor support.** `editors/vscode/` is a VS Code extension that runs `fsp check --json` when
you save a file under the app folder and puts the diagnostics in the Problems panel, with a
`fespalier: generate` command and a status bar item. It is not on the Marketplace yet: build
it with `npm install && npm test && npx @vscode/vsce package` in that folder and install the
`.vsix` (see `editors/vscode/README.md`). It uses `fsp` from your `PATH`, or `dart run
fespalier` when there is none (`fespalier.runner` chooses).

**Formatting.** The generated file is not formatted by default, so a committed
`app.g.dart` doesn't depend on which Dart SDK ran `fsp`. `fsp gen --format`, or `format: true` in
the pubspec section, pipes it through `dart format` (which needs `dart` on your `PATH`; without
it `fsp` warns and writes the unformatted code). It uses your package's language version
and `analysis_options.yaml` (`formatter: page_width`), like `dart format lib/`, and
`fsp gen` compares the formatted text with the file on disk, so a formatted file that is up
to date stays "unchanged". `fsp watch`, `fsp new` and `fsp init` follow `format:` in the
pubspec. `fsp check` writes and compares nothing, so it never runs `dart`.

What the commands print:

- `fsp gen`: `✓ 12 routes → lib/app.g.dart`, or `✓ 12 routes, lib/app.g.dart unchanged`
  when the output didn't change (with `output_manifest`, both files are named).
- `fsp check`: `✓ 12 routes, no errors`.
- `fsp watch`: the `gen` line once at startup, then a line each time a save changes
  `lib/app.g.dart`. An edit that doesn't (a widget's `build` method, say) prints nothing.
  It ignores its own output and file reads, so it doesn't loop while idle. It keeps the parse
  results of files that didn't change, so a save parses only the file you saved.

Errors point at the parameter or declaration at fault, and `app.g.dart` is left
untouched while there are any. A file that can't be fully parsed gets a warning instead
(the Dart compiler reports the exact error), and the generator works with what it could
read:

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
  [notify](https://github.com/notify-rs/notify) drives `watch`.

`lib/app.g.dart` is plain go_router + Riverpod code that's meant to be read and committed.
It opens with a route table (see `examples/shop/lib/app.g.dart`). Some details:

- **Types are never re-spelled.** The generator doesn't copy your imports. Values flow
  through inference, and each route's provider is a `static final` whose type is inferred.
  The one exception is a page's [typed `extra`](#typed-extra), whose type the typed route
  has to name; it imports that type by name from `page.dart`'s imports.
- **Segments and query parameters are parsed into a record** (`({int id, int? page})`).
  Records compare by value, so providers are keyed by them directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
  `(group)` folders fold away completely, apart from the ShellRoute their layout adds.
- **Static routes come first** among siblings, then dynamic ones, then a
  [catch-all](#catch-all-segments), so go_router's first match is the most specific one.
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
`AsyncNotifierProvider`, `Stream` data, and a `teams/$teamId` section whose `data.dart` feeds
its layout and pages, with a `not_found.dart` at two levels.

`examples/tabs` is a bottom navigation bar built as a tab layout: four tabs (one with a
nested page, and a Library tab that is a tab layout of its own, with two inner tabs), a
counter that survives switching tabs, `tabOptions`, and a full-screen route outside them.

`examples/features` also has a guard in a page-less `(members)` group (with a login page that
returns to where you were), a second guard below it that runs after the first, two
`redirect.dart` routes (`/old-shops/:shop`, `/old-search`), and `/photos`, with a dialog
route (`/photos/:id`), a bottom sheet (`/photos/sort`) and a full-screen dialog
(`/photos/upload`) opening over it. Some of its routes have a `meta.dart` (`PageMeta`), which
its root layout reads through the route manifest to set the page title, and its tests join a
review-code check on `AppRoutes.all`.

`examples/tabs` also keeps its manifest in a library of its own (`output_manifest:
lib/app.routes.g.dart`, with `Review` metas that `lib/main.dart` never imports), and its tests
restore the selected tab, a background tab's stack and a page's state after a simulated
restart.

## Development

```
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
editors/vscode/      the VS Code extension (TypeScript): fsp diagnostics in the Problems panel
scripts/             packaging.py renders the Homebrew formula and Scoop manifest for a release;
                     pin_checksums.py writes the release's checksums into the Dart package
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation),
                     testing.dart, and bin/fespalier.dart, the `dart run fespalier` launcher for `fsp`
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, section data and nested not_found.dart, with widget tests
examples/tabs/       a tab layout (StatefulShellRoute), with widget tests
```

```sh
(cd cli && cargo test && cargo clippy --all-targets -- -D warnings)
(cd cli && cargo run -- check --project ../examples/shop)
(cd cli && cargo run -- check --project ../examples/tabs)
(cd packages/fespalier && flutter pub get && flutter analyze && flutter test)
(cd examples/shop && flutter pub get && flutter analyze && flutter test)
(cd examples/features && flutter pub get && flutter analyze && flutter test)
(cd examples/tabs && flutter pub get && flutter analyze && flutter test)
```

CI (`.github/workflows/ci.yml`) runs all of the above. It also scaffolds every file kind
with `fsp new` and runs `flutter analyze` on the result, runs `dart run fespalier` against a
freshly built `fsp`, compiles and tests the VS Code extension, tests the Homebrew and Scoop
rendering and checksum pinning (`python3 scripts/test_packaging.py`,
`python3 scripts/test_pin_checksums.py`), runs `flutter pub publish --dry-run` on the
package, and checks that the version agrees everywhere it is spelled out
(`cli/tests/versions.rs`: `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`, the `ref:` that
`fsp init` prints, and the READMEs' `ref:`, `--tag` and `FSP_VERSION`; the launcher reads its
version from the pubspec, and `release_checksums.dart` pins nothing or this version). To release, bump those together. After changing the emitter or a
template, regenerate with `cargo run -- gen --project ../examples/<name>`. A test fails if
a committed `app.g.dart` is stale.

### Releasing

Maintainers only. Bump the version everywhere (see the version checks above), update
`CHANGELOG.md`, and merge. Then:

1. **GitHub Release and binaries.** Run the *Release* workflow with `publish` ticked (or
   push the tag `v<version>`). It builds `fsp` for five targets and attaches
   `fsp-<target>.tar.gz` / `.zip` with their `.sha256` files. It also renders `fsp.rb`
   (Homebrew formula) and `fsp.json` (Scoop manifest) from those checksums with
   `scripts/packaging.py` and attaches them to the release.

   **Checksum pinning.** A manual publish runs in two phases. It builds the five targets from
   the commit you dispatched it on (which must be the default branch); then a `pin` job writes
   their SHA-256s to `packages/fespalier/lib/src/release_checksums.dart`
   (`scripts/pin_checksums.py`), commits it to `main` as `Pin fsp <version> checksums`, and the
   `v<version>` tag and the Release are created at *that* commit. A git dependency on
   the `v<version>` tag, and the package published to pub.dev from the tag, therefore carry the
   pins, and `dart run fespalier` refuses any download that doesn't match them (a checksum
   served next to the binary can be replaced together with it; one in the package can't). The
   binaries were built from the parent commit; the two commits differ only by that file, which
   the `fsp` build doesn't read, so the code is identical. The workflow needs `contents:
   write` and pushes with `GITHUB_TOKEN`: if `main` requires pull requests or status checks,
   let the `github-actions` bot bypass them, or the `pin` job fails and nothing is published.
   If `main` moved during the run, the push is rejected and you run it again. That push doesn't
   start CI. Pushing a `v*` tag by hand still publishes, but the tag can't hold pins, so that
   release's `dart run fespalier` falls back to its `.sha256` file with a warning.
   After bumping the version for the next release, run `python3 scripts/pin_checksums.py
   --reset` (`cli/tests/versions.rs` fails while the file pins another version); a version with
   no pins is what development builds have.
2. **pub.dev.** Run the *Publish to pub.dev* workflow from that tag: *Run workflow*, then
   *Use workflow from* > *Tag* > `v<version>`. It publishes `packages/fespalier` through
   pub.dev's GitHub OIDC automated publishing, with no stored token. It refuses to run from
   a branch or when the tag isn't `v` plus the pubspec version. After the first release on
   pub.dev, change the install snippets in the READMEs from the Git dependency to
   `fespalier: ^<version>` (and `cli/tests/versions.rs`, which checks them).
3. **Homebrew and Scoop.** Copy `fsp.rb` from the release into the `Formula/` folder of a tap
   repository and `fsp.json` into the `bucket/` folder of a bucket repository, or let the
   workflow do it (below).

One-time setup:

- **pub.dev.** Automated publishing only works for an existing package, so publish the first
  version by hand: `cd packages/fespalier && flutter pub publish`. Then, on the package's
  *Admin* tab under *Automated publishing*, enable *Publishing from GitHub Actions*,
  repository `vaam-apps/fespalier`, tag pattern `v{{version}}`. Optionally tick *Require
  GitHub Actions environment*, create an environment named `pub.dev` in the repository's
  settings (add required reviewers there), and uncomment `environment: pub.dev` in
  `.github/workflows/publish.yml`. Check what will be uploaded any time with
  `flutter pub publish --dry-run` (CI does).
- **Homebrew tap.** Create the repository `vaam-apps/homebrew-tap` (the `homebrew-` prefix
  is what lets `brew install vaam-apps/tap/fsp` find it) with a `Formula/` folder.
- **Scoop bucket.** Create `vaam-apps/scoop-bucket` with a `bucket/` folder. The manifest's
  `checkver` and `autoupdate` let Scoop's own tooling keep it current too.
- **Automatic updates (optional).** Create a fine-grained personal access token with
  *Contents: read and write* on those two repositories and save it as the
  `PACKAGING_TOKEN` secret of this repository. Each published release then commits
  `Formula/fsp.rb` and `bucket/fsp.json` to them. Without the secret the step is skipped.
  Different repository names go in the `HOMEBREW_TAP_REPO` and `SCOOP_BUCKET_REPO`
  repository variables.

### Testing

`package:fespalier/testing.dart` has two helpers for widget tests. Boot the app at a
location with `pumpRouter`, and read where it is with `currentLocation`:

```dart
import 'package:fespalier/testing.dart';

testWidgets('shows a product', (tester) async {
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/products/2'),
    overrides: [apiProvider.overrideWithValue(FakeApi())],
  );
  expect(find.byType(ProductPage), findsOneWidget);

  // navigate with the typed routes, from any widget under the router
  ProductsRoute().go(tester.element(find.byType(ProductPage)));
  await tester.pumpAndSettle();
  expect(currentLocation(tester), '/products');
});
```

`pumpRouter(tester, router, {overrides, container, settle})` wraps the router in a
`ProviderScope` and Flutter's `MaterialApp.router`, and returns the `ProviderContainer`
(for `container.read(...)`). `settle` (on by default) pumps until nothing is scheduled: turn
it off to look at a loading view, then `pump` the time you want. Pass your own `container`
instead of `overrides` to share one with code outside the widget tree; it's yours to
dispose. Make a new router per test, since a router remembers where it went. If a widget
hangs on to its own `WidgetRef` (to call `prefetch` from a test, say), take it from an
element: `tester.element(find.byType(AppLayout)) as WidgetRef`.

The library is separate from `package:fespalier/fespalier.dart`, so your app never imports
`flutter_test`. It's a regular `flutter_test: sdk: flutter` dependency of `fespalier`
(pub allows the Flutter SDK's own packages), which your app has as a dev dependency
anyway and doesn't ship. The helper uses Flutter's `MaterialApp`; with go_router 18 the
note under [Getting started](#getting-started) applies: with a root `transition.dart`,
which `fsp init` writes, routes animate and no nested `material_ui` app is needed in tests.

To import a file from a `$segment` folder, escape the `$`: an unescaped `$id` in an import
is a Dart interpolation error ("URIs can't use string interpolation").

```dart
import 'package:my_app/app/products/\$id/page.dart';
```

go_router builds the whole matched stack, so a deep link like `/products/2` also runs
`/products`' `data.dart` underneath. If your fakes use `Future.delayed`, pump long enough
for the delays in both (or use `pumpAndSettle`), or the test ends with "A Timer is still
pending". `examples/*/test/` has working tests for every file kind.

## Status

This is an early version.

- **Generator:** 231 tests (210 unit, 16 CLI integration, 5 version checks) cover parsing, every binding rule and contract error, query
  parameters, `(group)` folders and route order, tab layouts, transitions, all three data
  forms, section data, nested `not_found.dart`, the typed helpers, guards and redirects,
  scaffolding, the route manifest, meta.dart and restoration ids, and that the committed outputs are up to date. Clippy is clean.
- **Runtime + examples:** `flutter analyze` is clean on Flutter 3.47 (go_router 17 and 18,
  hooks_riverpod 3, flutter_hooks 0.21). 227 Flutter tests (the package 100, `shop` 23, `features` 87, `tabs` 17); the example tests drive the generated router through every
  file kind.
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

