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
  not_found.dart         NotFoundPage({required Uri uri})               (optional)
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
    guard.dart           GuardResult guard(ProviderContainer c)         (guards this and below)
    page.dart
  old-products/$id/
    redirect.dart        String redirect({required int id})            → /old-products/:id redirects
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

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION=v0.1.1`
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
cargo install --git https://github.com/vaam-apps/fespalier --tag v0.1.1 fespalier
```

**Or install nothing.** Once the package is in your `pubspec.yaml` (step 2), `dart run
fespalier <command>` runs `fsp` for you, so use it wherever this README says `fsp`:
`dart run fespalier init`, `dart run fespalier watch`, `dart run fespalier check`. The first
run downloads the `fsp` release that matches the package's version, checks its SHA-256 and
keeps it in your user cache (`~/.cache/fespalier` on Linux, `~/Library/Caches/fespalier` on
macOS, `%LOCALAPPDATA%\fespalier` on Windows; `FSP_CACHE_DIR` moves it), so later runs start
at once. It needs `tar`, which macOS, Linux and Windows 10+ include. Set `FSP_BINARY=/path/to/fsp`
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
      ref: v0.1.1
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
paths get a plain "Nothing at /path" view.

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

Commit `lib/app.g.dart`: it's plain code, meant to be read, and the app builds without
`fsp` installed. In CI, run `fsp check`. It writes nothing and exits non-zero on errors:

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
```

or, with nothing to install (after `flutter pub get`): `- run: dart run fespalier check`.

**Config.** `fsp` needs no configuration. To move things, add this optional section to
`pubspec.yaml`. Both paths are relative to the project root and must be under `lib/`, and
`output` must be a `.dart` file. These are the defaults:

```yaml
fespalier:
  app_dir: lib/app
  output: lib/app.g.dart
  format: false
```

`format: true` runs `dart format` on the generated file (see [`fsp gen --format`](#the-generator)).

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
| `guard.dart` | `GuardResult guard(ProviderContainer c, {…})`; `GuardResult` is `FutureOr<String?>`: a location to redirect to, or `null` to let the navigation through. Guards every route at and below its folder | `uri`; segments at or above its folder; query (named) |
| `redirect.dart` | `String redirect({…})` in place of `page.dart`: a route that only redirects; may take `ProviderContainer c` first | `uri`; segments; query (named) |
| `transition.dart` | `Page<…> transition(…)`; applies to this folder and below | `key`, `child`, `state` |
| `not_found.dart` | a widget, root only, optional (without it, a plain "Nothing at /path" view); unknown paths and unparsable segments | `uri` |

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

**Retries.** Riverpod 3 retries a failed provider with backoff by default. The generated
`data()` providers turn that off (`retry: (retryCount, error) => null`), so `error.dart`
shows as soon as `data.dart` fails, and its `retry` callback is the retry path. A
provider you write yourself keeps Riverpod's default unless you pass `retry:` to it.

To see a scaffolded `error.dart` and its retry, throw from `data.dart`, e.g.
`throw Exception('offline')`.

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

With `--json` it prints one JSON object per line, for scripts and editors, and adds each
route's parameters; `file` is relative to the project root:

```json
{"pattern":"/products/:id","route":"ProductRoute","file":"lib/app/products/$id/page.dart","tags":["data","transition"],"params":[{"name":"id","type":"int","in":"path"}]}
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
  when the output didn't change.
- `fsp check`: `✓ 12 routes, no errors`.
- `fsp watch`: the `gen` line once at startup, then a line each time a save changes
  `lib/app.g.dart`. An edit that doesn't (a widget's `build` method, say) prints nothing.
  It ignores its own output and file reads, so it doesn't loop while idle.

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

`examples/tabs` is a bottom navigation bar built as a tab layout: four tabs (one with a
nested page, and a Library tab that is a tab layout of its own, with two inner tabs), a
counter that survives switching tabs, `tabOptions`, and a full-screen route outside them.

`examples/features` also has a guard in a page-less `(members)` group (with a login page that
returns to where you were), a second guard below it that runs after the first, two
`redirect.dart` routes (`/old-shops/:shop`, `/old-search`), and `/photos`, with a dialog
route (`/photos/:id`), a bottom sheet (`/photos/sort`) and a full-screen dialog
(`/photos/upload`) opening over it.

## Development

```
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation),
                     and bin/fespalier.dart, the `dart run fespalier` launcher for `fsp`
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, with widget tests
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
freshly built `fsp`, and checks that the version agrees everywhere it is spelled out
(`cli/tests/versions.rs`: `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`, the `ref:` that
`fsp init` prints, and the READMEs' `ref:`, `--tag` and `FSP_VERSION`; the launcher reads its
version from the pubspec). To release, bump those together. After changing the emitter or a
template, regenerate with `cargo run -- gen --project ../examples/<name>`. A test fails if
a committed `app.g.dart` is stale.

### Testing

Boot the app in a widget test by giving the router an initial location:

```dart
testWidgets('shows a product', (tester) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp.router(
      routerConfig: AppRoutes.router(initialLocation: '/products/2'),
    ),
  ));
  await tester.pumpAndSettle();
  expect(find.byType(ProductPage), findsOneWidget);

  // navigate with the typed routes, from any widget under the router
  final context = tester.element(find.byType(ProductPage));
  const ProductsRoute().go(context);
  await tester.pumpAndSettle();
});
```

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

- **Generator:** 133 tests (116 unit, 13 CLI integration, 4 version checks) cover parsing, every binding rule and contract error, query
  parameters, `(group)` folders and route order, tab layouts, transitions, both data
  forms, guards and redirects, scaffolding, and that the committed outputs are up to date. Clippy is clean.
- **Runtime + examples:** `flutter analyze` is clean on Flutter 3.47 (go_router 17 and 18,
  hooks_riverpod 3, flutter_hooks 0.21). 105 Flutter tests (the package 47, `shop` 12,
  `features` 34, `tabs` 12); the example tests drive the generated router through every
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

