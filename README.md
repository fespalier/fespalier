# fespalier

File-tree routing for Flutter, in the spirit of Next.js. An espalier is a tree
trained flat against a frame; here the frame is `lib/app/`.

You write plain widgets and functions in small files under `lib/app/`. There are no
base classes or interfaces to implement: the file name says what a file is, and its
constructor says what it needs. The `fsp` generator reads every file, works out what
each parameter should receive, checks that the files fit together, and writes one
mountable `lib/app.g.dart`. It's built on go_router, Riverpod and flutter_hooks,
with no build_runner.

```text
lib/app/
  layout.dart            AppLayout({required Widget child})           → ShellRoute
  page.dart              HomePage()                                   → /
  loading.dart           RootLoading()                                  (inherited)
  error.dart             RootError({required Object error, required VoidCallback retry})
  not_found.dart         NotFoundPage({required Uri uri})               (optional, in any folder)
  transition.dart        Page<void> transition(LocalKey key, Widget child)  (inherited)
  route.dart             const caseSensitive = false;                   (inherited: this folder and below match in any case)
  products/
    route.dart           const paths = {'fr': 'produits', 'de': 'produkte'};  (this folder also answers /produits, /produkte)
    data.dart            final data = FutureProvider<List<Product>>(…)
    page.dart            ProductsPage({required List<Product> products})  → /products
    loading.dart         ProductsLoading()
    $id/
      data.dart          Future<Product> data(Ref ref, {required int id})
      page.dart          ProductPage({required Product product})       → /products/:id
      action.dart        Future<void> action(Ref ref, {required int id, required Refund input})   (a write)
      error.dart         ProductError({required int id, required Object error, …})
      meta.dart          const meta = PageMeta(code: 'B04', …)         (this route's facts, any const)
  checkout/
    guard.dart           GuardResult guard(Ref ref)                     (guards this and below)
    page.dart
  old-products/$id/
    redirect.dart        String redirect({required int id})            → /old-products/:id redirects
  greet/$name/page.dart  GreetPage({required String name})
  docs/$$rest/page.dart  DocsPage({required List<String> rest})       → /docs/a, /docs/a/b, …
  compare/$$ids/page.dart  ComparePage({required List<int> ids})       → /compare/3/7 (each part an int)
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
ProductRoute(id: 42).go(context, locale: 'fr');    // → /produits/42 (`location` stays /products/42)

// each route's data.dart, as a Riverpod provider
ref.watch(ProductRoute.data(42));
ProductRoute.watch(ref, id: 42);             // the same, typed: AsyncValue<Product>
await ProductRoute.read(ref, id: 42);        // Future<Product>
final warm = ProductRoute(id: 42).prefetch(ref);   // start loading before navigating; warm.close() lets go
await const ProductsRoute().refresh(ref);

// each route's action.dart: a write with pending and error state, then the data it made stale reloads
await ProductRoute.submit(ref, id: 42, input: refund);             // Future<Refund>, throws what it threw
final refund = ProductRoute.useAction(ref, id: 42);               // for build(): .state is AsyncValue<Refund?>

// from a location to what it reads (an app's own prefetch queue, tests): no guard runs, no widget is built
AppRoutes.dataAt(Uri.parse('/products/42'));    // [ProductRoute.data(42)]; null when no route fits
AppRoutes.match(Uri.parse('/products/42'));     // RouteMatch: the RouteInfo, the parsed params, the data
```

## Getting started

You need Flutter 3.32 or newer (Dart 3.8) for the package. go_router 18 needs Flutter
3.44 or newer.

**1. Install the CLI.** On Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
```

It puts `fsp` in `~/.local/bin` and checks the download's SHA-256. Set `FSP_VERSION=v0.4.1` <!-- x-release-please-version -->
to pick a release (the default is the latest) and `FSP_INSTALL_DIR=/some/dir` to install
elsewhere. On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.ps1 | iex
```

It puts `fsp.exe` in `%LOCALAPPDATA%\fespalier\bin` (tell it otherwise with
`$env:FSP_INSTALL_DIR`, pick a release with `$env:FSP_VERSION`), checks the SHA-256, and
prints how to add that folder to your `PATH` if it isn't there yet. With Rust installed, on
any platform:

<!-- x-release-please-start-version -->

```sh
cargo install --git https://github.com/vaam-apps/fespalier --tag v0.4.1 fespalier
```

<!-- x-release-please-end -->

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

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/vaam-apps/fespalier
      path: packages/fespalier
      ref: v0.4.1
```

<!-- x-release-please-end -->

It depends on go_router (17 or 18), hooks_riverpod 3 and flutter_hooks, and
`package:fespalier/fespalier.dart` re-exports all three, so you don't add them yourself.

**3. Run `fsp init`** in the project root:

```sh
fsp init
```

It creates `lib/app/layout.dart`, `page.dart`, `not_found.dart` (`not-found.dart` with
[`file_style: kebab`](#file-names)) and `transition.dart` (every
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

A plain `flutter create` (not `flutter create --empty`) also wrote `test/widget_test.dart`,
which refers to the `MyApp` you just replaced, so `flutter analyze` fails on it. Delete it,
or rewrite it (see [Testing](#testing)).

Already have a `GoRouter`? Mount the tree inside it instead. `at` is the URL prefix:

```dart
GoRouter(
  navigatorKey: rootKey,
  routes: [...yourRoutes, ...AppRoutes.mount(at: '/x', navigatorKey: rootKey)],
)
```

Pass `mount` your `GoRouter`'s own `navigatorKey`: routes that render on the
[root navigator](#the-root-navigator-navigatordart) name it as their `parentNavigatorKey`,
which go_router requires to be an ancestor navigator's. (`AppRoutes.router()` takes a
`navigatorKey:` too, and either way the key is `AppRoutes.rootNavigatorKey`.)

**4. Day to day.**

```sh
fsp watch                                 # next to `flutter run`: regenerates when the routing changes
fsp new 'orders/[id]' --data --loading    # scaffold a route, then regenerate app.g.dart
fsp new 'orders/[id]/refund' --action     # a write beside the page (action.dart)
```

`fsp new` runs `gen` right away, so the new route is usable as soon as it returns. See
"The generator" for all flags.

**Two ways to keep `app.g.dart`.** Pick one.

_Commit it_ (the default). `lib/app.g.dart` is plain code, meant to be read, and the app
builds without `fsp` installed. In CI, run `fsp check`. It writes nothing (it never touches
`app.g.dart`) and exits non-zero on routing errors. It does **not** compare the committed file
with what the tree would generate, so it passes when `lib/app.g.dart` is stale; the end of this
section has a check that fails then.

```yaml
- run: curl -fsSL https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.sh | sh
- run: echo "$HOME/.local/bin" >> "$GITHUB_PATH"
- run: fsp check
```

or, with nothing to install (after `flutter pub get`): `- run: dart run fespalier check`.

_Generate, don't commit._ For projects that never commit generated code (`**/*.g.dart` is
ignored already, and every generator runs before analysis). Add the file to `.gitignore`:

```gitignore
lib/app.g.dart
```

and generate it wherever the app is analyzed, tested or built: on a fresh clone, and in CI
**before** `flutter analyze`, because `app.g.dart` doesn't exist until then:

```yaml
- run: flutter pub get
- run: dart run fespalier gen # writes lib/app.g.dart; fails on routing errors
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

_To fail CI on a stale committed file_, regenerate it and fail on any difference. `fsp gen`
follows `format:` in the pubspec, so the result is what you would commit:

```yaml
- run: fsp gen
- run: git diff --exit-code lib/app.g.dart
```

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
  file_style: snake
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
```

`format: true` runs `dart format` on the generated file (see [`fsp gen --format`](#the-generator)).
`case_sensitive: false` makes paths match in any case, and a [`route.dart`](#case-and-trailing-slashes) sets that
per folder (see [Case and trailing slashes](#case-and-trailing-slashes)); the same file gives a folder
[other spellings per locale](#localized-paths) with `paths`.
`data_retry` and `keep_previous` are about `data.dart` failures and reloads; see
[Retries and reloads](#retries-and-reloads). `file_style: kebab` makes `fsp init` and `fsp new`
write `not-found.dart` instead of `not_found.dart` (see [File names](#file-names)).
`meta: required` makes a route without a [`meta.dart`](#route-manifest-and-metadart) an error,
`meta_unique` makes a duplicate value in it one, and
`output_manifest` writes the route manifest to a library of its own (same section).
`links:` is what [`fsp links`](#deep-links-and-a-sitemap-fsp-links) reads; only that command checks its values.
The router's [`extraCodec`](#restoring-extra-on-the-web) has no key: `lib/app/extra_codec.dart` is
found by its name, like the other files.

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

Each view file exports one widget class, of any kind: `StatelessWidget`,
`ConsumerWidget`, `HookConsumerWidget` and so on, or a [top-level function](#function-views)
that returns a widget. Function files export one top-level function. Other public classes may sit
in the file as long as exactly one of them extends a `…Widget` class (a `class Helper {}` beside a
`StatelessWidget` is fine); when `fsp` can't tell which is the view it says "expected one public
widget class" and lists them. Make helpers private (`_Name`) rather than lean on that.

| File               | Exports                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Its constructor / signature can ask for                                                                                                                       |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `page.dart`        | a widget                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | segments; query; what `data.dart` yields; the navigation [`extra`](#typed-extra)                                                                              |
| `data.dart`        | `data(Ref ref, {…})` returning `Future<T>`, `Stream<T>` or `T` — **or** `ProviderListenable<AsyncValue<T>> data({…})` selecting a provider you have — **or** `final data = <Provider>(…)`. Beside a `page.dart` it feeds the page; in a page-less folder with a `layout.dart`, the whole [section](#section-data)                                                                                                                                                                                                                                                                                                                                                                                                                              | segments, query (named)                                                                                                                                       |
| `action.dart`      | `action(Ref ref, {…, required Input input})` (any number of functions of that shape) returning `Future<T>`, `FutureOr<T>` or `T`, and optionally `const invalidates = [...]`. Beside a `page.dart` it is that route's [write](#actiondart-typed-writes); in a page-less folder with a `layout.dart`, the [section's](#actiondart-typed-writes)                                                                                                                                                                                                                                                                                                                                                                                                 | segments, query (named), and the one `input`                                                                                                                  |
| `loading.dart`     | a widget, inherited by subfolders                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | segments; query                                                                                                                                               |
| `error.dart`       | a widget, inherited by subfolders                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | segments; query; `error`, `stackTrace`, `retry`                                                                                                               |
| `layout.dart`      | a widget; wraps this folder and below (ShellRoute), or holds its subfolders as tabs. A tab layout can also export a [`container`](#tab-layouts) function                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | `child` or `navigationShell`; segments at or above it; query; the [section data](#section-data) it wraps or is inside; the navigation [`extra`](#typed-extra) |
| `guard.dart`       | `GuardResult guard(Ref ref, {…})`; `GuardResult` is `FutureOr<String?>`: a location to redirect to, or `null` to let the navigation through. Guards every route at and below its folder, and runs again when what it `ref.watch`es changes (since 0.5.0; `ProviderContainer c` first is the older form, read once)                                                                                                                                                                                                                                                                                                                                                                                                                             | `uri`; segments at or above its folder; query (named); `extra`                                                                                                |
| `redirect.dart`    | `String redirect({…})` in place of `page.dart`: a route that only redirects; may take `Ref ref` first (since 0.5.0), or `ProviderContainer c`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `uri`; segments; query (named); `extra`                                                                                                                       |
| `transition.dart`  | `Page<…> transition(…)`; applies to this folder and below, layouts' shells included                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | `key`, `child`, `state`, `shell` (a `bool`)                                                                                                                   |
| `present.dart`     | `Page<…> present(…)`: the app builds this route's own page (a sheet, say), on the [root navigator](#presentdart-a-page-of-your-own); this folder only                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `key`, `child`, `state`                                                                                                                                       |
| `navigator.dart`   | `const navigator = RouteNavigator.root;`: this folder and below [render on the root navigator](#the-root-navigator-navigatordart)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | nothing: it is data                                                                                                                                           |
| `not_found.dart`   | a widget, optional, in any folder ([nearest wins](#not-found-views); without one at the root, a plain "Nothing at /path" view); unknown paths and unparsable segments                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `uri`                                                                                                                                                         |
| `meta.dart`        | `const meta = <any const expression>;`, beside a `page.dart` or `redirect.dart`: that route's own facts, passed [untouched into the manifest](#route-manifest-and-metadart)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | nothing: it is data                                                                                                                                           |
| `extra_codec.dart` | at the root of the app folder only: a top-level `extraCodec`, the `Codec<Object?, Object?>` the router saves an [`extra`](#restoring-extra-on-the-web) with                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | nothing: it is data                                                                                                                                           |
| `route.dart`       | `const caseSensitive = <true or false>;` in any folder: whether paths match by case in this folder and below, [the nearest one winning](#case-and-trailing-slashes) over the pubspec's `case_sensitive`; and/or `const paths = {'fr': 'produits'};` in a static folder: [its other spellings per locale](#localized-paths); and/or `const nest = false;` beside a `page.dart` or `redirect.dart`: [its route is a sibling of the page above, not a child](#a-sibling-with-a-compound-path); and/or `const linkable = false;` (since 0.5.0): [`fsp links`](#deep-links-and-a-sitemap-fsp-links) leaves this folder's routes and those below it out, [the nearest one winning](#case-and-trailing-slashes). Read from the source, never imported | nothing: it is data                                                                                                                                           |

### Function views

`page.dart`, `loading.dart`, `error.dart`, `layout.dart` and `not_found.dart` can export a
top-level function named after the file, returning a `Widget`, instead of a widget class:

```dart
// lib/app/(kyc)/shop/name/page.dart
import 'package:my_app/screens/kyc/legal_name_screen.dart';

Widget page() => const LegalNameScreen(audience: KycAudience.shop);
```

```dart
// lib/app/(buyer)/orders/$orderId/cancel/page.dart
Widget page({required String orderId, String? back}) =>
    CancelOrderScreen(orderId: orderId, back: back);
```

That is one route per file, however many routes build the same screen, and the screen can
stay where it is (`lib/screens/…`) instead of moving into `lib/app/`. The function's
parameters are filled exactly like a constructor's ([below](#how-parameters-are-filled)):
segments and query parameters by name, `data` by name or by type, `child` or a shell for a
`layout()`, `error`, `stackTrace` and `retry` for an `error()`, `uri` for a `notFound()`.
Named and positional parameters both work, and a binding error points at the parameter.

- **Names.** `page()`, `loading()`, `error()`, `layout()` and `notFound()` (`not_found()`
  too). Other functions in the file are helpers and are ignored.
- **One form per file.** A file with a public widget class _and_ the function is an error that
  names both; the class form is unchanged. To use the function, keep the widget in another
  file (or make it private) and build it from the function.
- **No hooks, no `ref`.** A function view is a plain function: it has no `BuildContext` and no
  `WidgetRef` (asking for one is an error that says so). Hooks and `ref` belong in the
  widget it returns, which is where they were anyway.
- **The route class name.** A class names its route after itself (`ProductPage` →
  `ProductRoute`), but many functions build the same screen, so a `page()` takes the
  folder path, ignoring `(group)` folders and joining the segments in PascalCase:
  `(kyc)/shop/name/page.dart` is `ShopNameRoute`, `orders/$orderId/cancel/page.dart` is
  `OrdersOrderIdCancelRoute` (the root is `RootRoute`). To pick another, put a string
  literal in `page.dart`:

  ```dart
  const routeName = 'KycShopName'; // KycShopNameRoute
  Widget page() => const LegalNameScreen(audience: KycAudience.shop);
  ```

  It must be an UpperCamelCase name (the route class is `<routeName>Route`), and it also
  renames a class-form page's route. The [route manifest](#route-manifest-and-metadart) lists the
  route under this name, and `meta.dart` works beside a function page. Two routes with the same name are an error that
  suggests `routeName`.

- **`export` isn't followed.** `page.dart` has to hold the function itself, so it stays the
  source of truth for the route.

`fsp new 'shop/name' --function` scaffolds the function form (`--name KycShopName` writes the
`routeName`). `examples/features` has two routes, `(plans)/free` and `(plans)/pro`, serving one
screen with different constants.

### File names

The one file kind with two words is `not_found.dart`. Reading takes it in kebab-case too,
`not-found.dart`, whatever the configuration says, so a project that names every Dart file in
kebab-case can keep to that, and a tree that mixes the two still works. Both in one folder
is an error with a code frame for each file. Diagnostics, `fsp routes` and the header of
`app.g.dart` name a file as it is spelled on disk.

`file_style: snake | kebab` (default `snake`) only picks what `fsp init` and `fsp new` write.
The single-word kinds (`page.dart`, `layout.dart`, …) have one spelling.

### How parameters are filled

The generator reads each constructor (named or positional, `this.x` or typed) and fills
every parameter:

1. **By name.** A parameter named like a `$segment` in the path gets that segment.
   `data`, `child`, `navigationShell` (or `shell`), `error`, `stackTrace`, `retry`, `uri`
   and `extra` (in a page, a layout, a guard or a redirect) get what their name says, in the
   files where they make sense.
2. **Query.** An _optional_ parameter that is nullable or a `List` of
   `String`/`int`/`double`/`bool` (or of an [enum](#enum-segments)) is a query parameter:
   `int? page` gets `?page=2`, and `List<String> tags = const []` gets every `?tags=`.
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
is a `String`. Segments are `String`, `int`, `double`, `bool` or an [enum](#enum-segments) of your
app. (A [catch-all](#catch-all-segments) is a `List` of those, or of `num` or `DateTime`.)

`fsp new` scaffolds every segment as a `String`: `fsp new 'products/[id]' --data` writes
`data(Ref ref, {required String id})`. To make `$id` an `int`, change the parameter type
in each file that asks for it, then run `fsp gen` (or let `fsp watch` do it).

### Enum segments

A segment, a [query parameter](#query-parameters) and the parts of a [catch-all](#catch-all-segments)
can be an enum of your app. The parameter is typed with it, in the file that asks:

```text
shop/$category/page.dart   /shop/shoes              category == Category.shoes
                           /shop/socks              not found: `socks` isn't a Category
browse/$$categories/       /browse/shoes/hats       categories == [Category.shoes, Category.hats]
```

```dart
enum Category { shoes, hats }        // in the file that uses it, or in any file it imports

class ShopPage extends StatelessWidget {
  const ShopPage({super.key, required this.category, this.sort});
  final Category category;           // the segment
  final Sort? sort;                  // the query: /shop/shoes?sort=price
}

const ShopRoute(category: Category.hats, sort: Sort.price).go(context);   // → /shop/hats?sort=price
```

- **Read by name.** A value is the one whose `name` the text spells (`Category.values.byName`).
  A segment or catch-all part that names no value sends the route to `not_found.dart`, like a
  bad `int` (`BadSegment`): the page is never built (and a guard that reads segments or query
  parameters is skipped, see [Guards](#guards)). A query parameter
  that names none is `null`, or left out of a list, like any query parameter that doesn't parse.
- **Case follows the route.** Names match exactly by default. Where the route's paths match in
  any case ([`case_sensitive: false`, or a `route.dart`](#case-and-trailing-slashes)) `/shop/SHOES`
  is `Category.shoes` too (in a query parameter as well). A name that matches exactly always
  wins, so an enum with `a` and `A` still tells them apart.
- **Written by name.** `.location` writes `.name`, for a segment, each part of a catch-all
  (encoded on its own, like any part) and a query parameter, and the typed route's field has the
  enum's type.
- **Finding the enum.** Nothing in a syntax tree says that `Category` is an enum, so `fsp gen`
  reads the declaration: in the file that names the type (`page.dart`, `data.dart`, `guard.dart`,
  …), or in a file it imports, through `export`s too (a barrel file). It reads relative imports and
  `package:` imports of your own package, which are files under `lib/`; `dart:` and other packages
  are not read. A type it doesn't find an enum for (a class, one from another package, one that
  isn't imported) is an error at the parameter that suggests the `String` to take instead and
  parse in the page, and so is a private enum (`_Mode`), which the generated file couldn't name.
  An import prefix (`m.Category`) is followed through that import only.
- **Imports in `app.g.dart`.** The generated file names the type the way it does a
  [typed `extra`](#typed-extra): from the declaring file's own import when the enum is in the
  view file, otherwise through `import '…' show Category;` (or `as _es2_m` for a prefixed one)
  lines that follow the view's imports.
- **The type must agree across files.** `Category` in `page.dart` and `Size` in `data.dart` is
  the error a mismatched `int` is (`` `$category` is Size in data.dart:1 but Category here ``);
  `Category` and `m.Category` are the same type when they name the same enum, and two enums that
  share a name are not.
- **`data.dart` can be keyed by an enum.** An enum is hashable, so `{required Category category}` keys
  the provider by the enum itself, and `ShopRoute.watch(ref, category: Category.hats)` takes it. A
  `List<Category>` catch-all is keyed by its path, like any catch-all, and `data()` gets the list
  back; a `List<Category>` query parameter is keyed by a `QueryList`, as for any list.
  `AppRoutes.match(uri).params` and `AppRoutes.dataAt` have the enum values.
- **The manifest and `fsp routes --json`** show the type by name (`Category`, `List<Category>`,
  `Sort?`), without the prefix or alias it was imported under.

Limits: an enum is read by `name` only (a `static Category? fromSegment(String)` convention to
read another spelling may come later). A parameter that is `Sort sort = Sort.price` (not
nullable) isn't a query parameter, as for `int`, and an _optional_ nullable parameter of a type
that `fsp` finds no enum for is still left to its default rather than being an error, since it may
be plain widget configuration (`Color? color`): it is when a `data.dart`, `guard.dart` or
`redirect.dart` asks for it that the error comes. `fsp watch` also watches the rest of `lib/`, so
adding or editing an enum anywhere under it regenerates (for one outside `lib/`, run `fsp gen`).
`fsp new` below an enum segment writes its type name into the new files, and you add the import.

`examples/features` has `shop/$category` (an enum from `lib/models/`, a `Sort?` query parameter whose enum is
declared in the page's file, and `data.dart` keyed by the category) and `browse/$$categories` (a
`List<Category>` catch-all through an import prefix), with widget tests.

### Catch-all segments

`$$rest` matches **one or more** remaining segments, and `$$$rest` (three `$`) **zero or
more**. The page takes them as a `List<String>` (or a [typed list](#typed-catch-alls)), each part
decoded on its own:

```text
docs/page.dart            /docs                      the index, beside the catch-all
docs/new/page.dart        /docs/new                  a static sibling: tried first
docs/$$rest/page.dart      /docs/guide/setup/linux    rest == ['guide', 'setup', 'linux']
files/$$$path/page.dart   /files, /files/a/b         path == [] or ['a', 'b']
```

```dart
class DocsPage extends StatelessWidget {
  const DocsPage({super.key, required this.rest});
  final List<String> rest;      // `rest` is the segment: a List, of Strings by default
  …
}

const DocsRoute(rest: ['guide', 'a b']).go(context);   // → /docs/guide/a%20b, each part encoded
const FilesRoute().location;                            // '/files'
```

How it works: `go_router` matches a path pattern with a regular expression, and a `:name`
parameter can carry its own (`:rest(.+)`, which may span `/`). A catch-all folder becomes a
route with that pattern, `docs/:rest(.+)`, so deep links, redirects and `go` all use `go_router`'s
normal matching. `$$$rest` is two routes with one builder: the folder's path (`/files`) and
the same with `:path(.+)`. Reading the parts takes `go_router`'s decoded string apart _by the
requested location_, so an encoded slash (`/docs/a%2Fb/c` is `['a/b', 'c']`) survives.

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

Limits: a catch-all is always the last segment and a `List`; nothing
can be below its folder, and it can't have a `not_found.dart` (it matches every URL under
it). A catch-all as a tab's first route needs a `tabOptions` `initialLocation`, like any
route with a parameter. A part of `.` or `..` is read as a dot segment by the URL parser, so
`DocsRoute(rest: ['..'])` doesn't reach a `..` part. `fsp new 'docs/[...rest]'` and
`'docs/[[...rest]]'` write the folders, so you don't have to quote `$`.

#### Typed catch-alls

Like a segment, a catch-all takes its type from the parameters that ask for it, and a
`List<String>` is the default. Ask for a `List<int>`, `List<double>`, `List<num>`, `List<bool>`,
`List<DateTime>` or a `List` of an [enum](#enum-segments) and every part is read like one segment of that type:

```text
compare/$$ids/page.dart   /compare/3/7/12           ids == [3, 7, 12]
                          /compare/3/x              not found: `x` isn't an int
```

```dart
class ComparePage extends StatelessWidget {
  const ComparePage({super.key, required this.ids});
  final List<int> ids;
}

const CompareRoute(ids: [3, 7, 12]).go(context);   // → /compare/3/7/12
```

- **A part that doesn't parse** sends the whole route to `not_found.dart`, like a bad `int`
  segment (`/products/abc`): the page is never built (and a guard that reads segments or query
  parameters is skipped, see [Guards](#guards)). `bool` parts are
  `true` and `false`; `num` reads `1` as an int and `2.5` as a double; a `DateTime` part is what
  `DateTime.tryParse` reads, and the typed route writes it as ISO 8601 (`2024-12-31T10:30:00.000Z`,
  colons encoded).
- **`.location` joins the encoded parts**, each on its own (`restPath`), whatever their type.
  `$$$rest` is an empty list when the path has no part, as with strings.
- **The type must agree across files**, as for any segment: a `page.dart` with `List<int> ids`
  and a `data.dart` with `List<String> ids` is an error with a code frame at the second, naming
  the first (`` `$ids` is List<String> in data.dart:1 but List<int> here ``). Anything else
  (`List<Object>`, `List<int?>`, `Set<int>`) is an error that lists what a catch-all can be.
- **`data.dart`** takes the typed list too: the provider is keyed by the encoded path, and
  `data()` gets the list back as a `List<int>`.
- A catch-all can also be a `List` of an [enum](#enum-segments).

`examples/features` has one at `compare/$$ids` (with a `data.dart`), and a widget test.

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
parts you take out of the URL (a `$segment`, a catch-all) keep the case they had.

**Per folder.** A `route.dart` overrides that for its folder and everything below it, and the
nearest one wins over the parent's and over the pubspec:

```dart
// lib/app/files/route.dart: /files/README.md isn't /files/readme.md, whatever the pubspec says
const caseSensitive = true;
```

It works both ways: `false` in one folder of an otherwise exact app, or `true` in one folder
of a `case_sensitive: false` one (`examples/features` does the second). Like `meta.dart` it is
read from the source when the tree is generated, never imported or run, so it must be a `true`
or `false` literal: anything else, a missing `caseSensitive`, or two of them is an error with a
code frame. Unlike `meta.dart` it needs no page beside it, is inherited (`(group)` folders and
folders without a page pass it on) and can sit at the root, where it replaces the pubspec's
value for the whole app. A `route.dart` doesn't add or remove any route (its `paths` spell a
folder's URL more than one way, see [Localized paths](#localized-paths)). The same file can say
`const linkable = false;`, which works the same way (a `true` or `false` literal, the nearest
one wins, inherited by `(group)` folders and folders without a page) and only matters to
[`fsp links`](#deep-links-and-a-sitemap-fsp-links): the routes of that folder and below are not
in the files it writes.
(It's a file of its own because `meta.dart` describes one route and is never inherited,
`transition.dart` is a function, and `layout.dart` only exists where a layout does.)

go_router has one flag per route, and a folder's routes are the whole path down to its page, so
a folder with no page above one that has (`docs/` above `docs/guide/page.dart`) is part of that
route: the flag is the one in effect at the page's folder, for the whole path. The
nearest-`not_found.dart` lookup compares each folder by that folder's own setting, and the mount
point (`AppRoutes.mount(at: '/Shop')`) by the root's.

**The requested case is kept.** go_router matches a case-insensitive route in any case and
leaves the location as it was asked for. Navigating or deep-linking to `/Products/2` leaves
`GoRouterState.uri` and the router's own location (`currentLocation(tester)` in a test) as
`/Products/2`; nothing is lowercased or redirected, and a `$segment` or catch-all keeps what
was typed. Only `state.matchedLocation` is spelled by the route (`/products/2`, with the
parameters as typed). A typed route has no requested case: `ProductRoute(id: 2).location` always
writes the folders' spelling, so `.location` is unchanged by the setting, and if you want the
canonical spelling in the address bar you have to navigate to it yourself. (Checked against
go_router 17.5 and 18.0, in `packages/fespalier/test/paths_test.dart` and `examples/features`.)

### Localized paths

One folder can answer several URL spellings, one per locale, while the typed route, the page and
its data stay single. Give the folder a `route.dart` with a `paths` map from a locale tag to that
folder's name in it:

```dart
// lib/app/products/route.dart: /products also answers /produits (fr) and /produkte (de)
const paths = {'fr': 'produits', 'de': 'produkte'};
```

```text
/products/2    /produits/2    /produkte/2      → the same ProductPage(id: 2), the same data
/products      /produits      /produkte        → the same ProductsPage
```

The folder's name stays the canonical spelling: it is what `.location`, the route table and
`AppManifest.byPath` say, and what a locale with no entry gets. `paths` is read from the source
(like `caseSensitive`), so it must be a map literal of string literals.

- **Only its own segment.** `paths` spells the one static folder it sits in. Folders below have
  their own `route.dart` (or none), and each level is spelled on its own, so `/aide/routing/exemples`
  (`help/` → `aide`, `$topic/examples/` → `exemples`) is a nested child under the localized
  parent. It is an error in the `route.dart` of a `$dynamic`, a `$$catch-all` or a `(group)` folder
  or of the app folder itself (none has a word to spell), and a `route.dart` may hold `paths`
  alone, without a `caseSensitive`.
- **What a spelling can be.** One URL segment: letters and digits, `- _ . ~`, and letters
  beyond ASCII (`'über'`, `'продукты'`, `'製品'`; see [below](#non-ascii-spellings)). A key is a
  locale tag (`fr`, `pt-BR`), and each tag may appear once (`fr` and `FR` are the same tag). A value
  that is empty, `.` or `..`, or has a `/`, `?`, `#`, `%`, whitespace, a control character, or any of
  `: | ( ) [ ] { } ' " $ \ * =`, is an error at the value (a `%` is what a spelling is encoded
  with: write the letter, not its encoding). Two locales may share a spelling, and a spelling may
  equal the folder's own name. An entry with an error is left out, and the rest of the map
  still takes part in the collision check below.
- **Collisions are errors, with a code frame on each side.** A spelling that makes a URL another
  route serves is reported at the entry and at the route it collides with (or at both entries, when
  both are spellings). Two [`not_found.dart`](#not-found-views) files that would cover one URL
  through a spelling collide the same way, at the entry and at the other file:

  ```text
  error: `fr: 'about'` makes /about, which about/page.dart serves too; rename the spelling, or the folder it collides with
    ┌─ lib/app/products/route.dart:2:9
  error: /about is also reached through `fr: 'about'` in products/route.dart:2; rename the spelling, or this folder
    ┌─ lib/app/about/page.dart:1:7
  ```

  The [unreachable-route](#group-folders) check knows the spellings too.

**Typed locations.** `.location` is canonical, `locationFor(locale)` spells the locale, and
`go`, `push` and `replace` take an optional `locale:`:

```dart
ProductRoute(id: 2).location;                 // '/products/2'
ProductRoute(id: 2).locationFor('fr');        // '/produits/2'
ProductRoute(id: 2).locationFor('fr-CA');     // '/produits/2': a region falls back to its language
ProductRoute(id: 2).locationFor('es');        // '/products/2': nobody spells it
ProductRoute(id: 2).go(context, locale: 'de');  // → /produkte/2; also push<T>(…, locale:) and replace(…, locale:)
```

A level with no spelling for the locale keeps its canonical one, each level on its own (with
`help/` spelled `fr` and `contact/` only `de`, `ContactRoute().locationFor('fr')` is
`/aide/contact`). Tags compare without regard to case and `_` is `-`; an exact tag wins over its
language. Every route has `locationFor` (a route with no localized segment answers `location`), and
`query` parameters are kept.

_Why a parameter and not an `AppRoutes.locale` the typed routes read._ A global would make
`ProductRoute(id: 2).go(context)` and `context.go(ProductRoute(id: 2).location)` different, `.location`
depend on when it is read, and every test depend on what the last one left in a static. A
`locale:` argument keeps a route a value, and the app (which owns its locale: `Localizations`, a
provider, the user's setting) decides where to pass it. An app that wants its locale everywhere can
wrap it once: `extension on TypedLocation { void goHere(BuildContext c) => go(c, locale: currentLocaleTag()); }`.
(A `$locale` folder, `/:locale/products`, is a different way to localize and needs none of this.)

**Every surface knows the spellings.** A deep link, `context.go('/produits/2')`, the router's
location (it stays as it was asked: `/produits/2`, nothing is redirected to the canonical URL),
and the helpers that read a location:

- `AppRoutes.match` / `matchUrl` / `dataAt` and `RouteMatcher` match every spelling and return the
  canonical typed route (`match.route.location` is `/products/2`). `nearestNotFound`, so
  `AppRoutes.notFound(uri)`, treats a localized prefix as all its spellings: a
  [`not_found.dart`](#not-found-views) in `help/` covers `/help/x`, `/aide/x` and `/hilfe/x`.
  Case follows the route's [`caseSensitive`](#case-and-trailing-slashes): with it off, `/AIDE` is `/aide`.
- `AppManifest.of(state)` finds the route at any spelling. The [manifest](#route-manifest-and-metadart)'s
  `RouteInfo` has `paths` (`{'fr': '/produits/:id', 'de': '/produkte/:id'}`, with each level's
  canonical spelling where a locale has none) and `pathFor(locale)`; `path` and `byPath` stay canonical.
- `fsp routes` lists the spellings under the route, and `--json` has a `paths` object for a route that has
  them (the key is left out for the others):

  ```text
  /products/:id  ProductRoute  products/$id/page.dart  (data)
    fr  /produits/:id
    de  /produkte/:id
  ```

**How it is routed.** A localized folder is _one_ `GoRoute`, whose segment is a path parameter with
its own pattern, which go_router supports (like the catch-all's `:rest(.+)`): the route for
`products/$id` is `path: ':_l0(products|produits|produkte)/:id'`, its first alternative the folder's name.
go_router matches the pattern with one regular expression (`patternToRegExp`, identical in 17.5 and 18.0), so a
deep link, a redirect and `go` take any spelling, and everything below the folder, its
nested routes, its layout, its guards and its `not_found.dart`, is the same route as without
`paths`. Because it is one route, `state.pageKey` is the same for every spelling (navigating from
`/products/2` to `/produits/2` updates the page instead of building another), the restoration ids
(made from folders) are unchanged, and there is no second route to keep in order, dedupe or
guard. Two routes with the same builder, or a redirect from each spelling to the canonical
path (which would change the URL the user sees) were the alternatives: see [Design
notes](#design-notes). Things to know:

- The parameter is named `_l<n>` after the segment's place in the URL (`_l0`, `_l1`; a segment can't
  start with `_`, so it never clashes, and go_router refuses a name that repeats down a branch). It
  shows up in `GoRouterState.pathParameters` and `fullPath`, which fespalier's own readers already
  ignore; don't read it. `state.matchedLocation` is spelled as requested (`/produits/2`).
- Spellings are also matched when they are mixed (`/help/routing/exemples`,
  `/aide/routing/examples`): each level is its own alternation. A typed route never writes one; if you
  want mixed URLs refused or redirected, a `guard.dart` can read the `uri`.
- **A tab's first route.** go_router opens a tab on its first route and asserts that it has no path
  parameter, which a localized segment is. `fsp gen` writes the tab's `initialLocation` for you (the
  canonical one, `/search`), unless you gave it one in `tabOptions` (which can be a spelling:
  `'/recherche'`). The one place that can't be written down is a localized first tab route below a
  `:segment` (the location would need a value): that is an error that says so.
- A localized static folder still sorts before dynamic siblings, so `/produits` isn't caught by a `/:slug`.

#### Non-ASCII spellings

`const paths = {'de': 'über', 'ru': 'продукты'};` works. A URL carries only ASCII: `Uri.path` is always
percent-encoded, whether a location was typed `/über`, arrives from the browser as `/%C3%BCber` or as
`/%c3%bcber` (`Uri.parse` normalizes all three to `/%C3%BCber`, and go_router's `router` location,
`GoRouterState.uri` and `currentLocation` are that form). So:

- **The route matches the encoded spelling.** `fsp gen` writes it into go_router's pattern encoded,
  UTF-8 bytes in upper-case hex: `':_l0(shop|%C3%BCber|%D0%BF%D1%80%D0%BE%D0%B4%D1%83%D0%BA%D1%82%D1%8B)'`.
  A deep link raw, encoded or in lower-case hex, `go('/über')` and `go('/%C3%BCber')` all reach it.
- **The runtime helpers compare decoded segments,** so `AppRoutes.match`, `dataAt` and `nearestNotFound`
  (and the manifest, `fsp routes` and diagnostics) have the word as written: `'shop|über|продукты'`.
- **`locationFor` writes it encoded,** as `Uri` would: `ProductsRoute().locationFor('de')` is
  `/%C3%BCber`, the same URL as `Uri.parse('/über')`, so it is safe to compare, store and share.
  `.location` (canonical) is always ASCII.
- **Case and normalization.** With [`caseSensitive: false`](#case-and-trailing-slashes), go_router's
  case-insensitive match is on the encoded text: it folds `A-Z` and the hex digits, but `/ÜBER` is not
  `/über` (they encode to different bytes). `AppRoutes.match` lowercases Unicode, so it may say a
  route fits where go_router's own matching would not; list the capital spelling in `paths` if you need
  it. A letter written two ways (`ü` as one character, or `u` plus a combining diaeresis) is two
  spellings to go_router: fsp compares what you wrote, so write the precomposed form browsers send.

`examples/features` has `help/` (`aide`, `hilfe`) with a dynamic child, a nested localized child, a static
sibling that only one locale spells, a `not_found.dart`, and widget tests for deep links through each
spelling, `locationFor`, `go(locale:)` and the manifest; `examples/tabs` localizes the Search tab.

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

```text
error: /settings is unreachable: $slug/page.dart (/:slug) comes first and matches it;
       move one of them into or out of its (group)
```

#### A sibling with a compound path

A page is the parent of the routes in the folders below it. With `orders/$id/refund/page.dart`
and `orders/$id/refund/confirm/page.dart`, `confirm` is a `GoRoute` inside the `refund` one, and
a deep link to `/orders/1/refund/confirm` builds the stack `/orders/1`, `/orders/1/refund`,
`/orders/1/refund/confirm` (see [Transitions](#transitions)). That is the right default. A tree
migrated from go_router may have put the two side by side, `GoRoute(path: 'refund')` and
`GoRoute(path: 'refund/confirm')` under `:id`, where the stack of the same link is `/orders/1`,
`/orders/1/refund/confirm`: the page that happens to share the first segment is not built, and
nothing is read for it. There are two ways to write that shape, a group and a declaration.

**With a group.** A group has no page and adds nothing to the URL, so what it holds nests under
the page above the group, not under a page beside it, and its folders may repeat a segment of
that sibling:

```text
lib/app/orders/$id/
  page.dart                                    → /orders/:id
  refund/page.dart                             → /orders/:id/refund
  (refund-confirm)/refund/confirm/page.dart    → /orders/:id/refund/confirm
```

This generates `GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` as two children of
`/orders/:id`: the `refund/` inside the group has no `page.dart`, so it only adds its segment to
the path. It works because of how groups fold away and a test holds it, but a group with no
layout, guard or transition looks like it does nothing; name it for what it is for, or say it
outright with `nest`.

**With `route.dart`.** `const nest = false;` in the folder of the route that must not nest:

```dart
// lib/app/orders/$id/refund/confirm/route.dart
const nest = false;
```

`confirm/` stays where it is: its URL, its typed route (`ConfirmRoute(id: 1).location` is
`/orders/1/refund/confirm`) and its place in the manifest do not change. What changes is the route
fespalier writes for it: it is no longer a child of the page of the folder above (`refund`) but
a sibling of that page, with a compound path,

```dart
GoRoute(path: joinLocation(at, '/orders/:id'), routes: [
  GoRoute(path: 'refund'),
  GoRoute(path: 'refund/confirm'),   // beside it, not inside
])
```

so the stack is `/orders/1`, `/orders/1/refund/confirm`, and the `refund` page is neither built nor
asked for its `data.dart`. `fsp routes` marks the route `(sibling)` (and its `tags` in `--json`
have `"sibling"`).

Like `caseSensitive` it is read from the source, so it must be a `true` or `false` literal. It is
about this folder's route alone and is not inherited: the routes in the folders below `confirm/`
nest under `confirm` as usual. `true` is the default and says nothing. The name is the verb the
README already uses for folders (a page is the parent of what is nested in it), and `false` is the
exception. A declaration in `refund/` saying "my children don't nest under me" would be the same
word read the other way, so there is only this one, in the folder of the route that leaves, where
you can find it from the route.

- **Where it goes.** Beside the nearest page above it; page-less folders and groups in between
  don't count as one. The path joins the segments of the folders it leaves, the
  static ones, the `$param` ones and a [localized](#localized-paths) one as its alternation
  (`:_l2(refund|remboursement)/confirm`): `refund/confirm`, `refund/:step`, `refund/:rest(.+)` for
  a `$$rest`. A `(group)` adds none. If the page above is itself `nest = false`, the route goes
  beside that one: its parent is the nearest route that stays, and the path joins every folder
  between. Beside the root page, a route is at the top: `login/` with `nest = false` is `/login`
  without `/` below it. A `redirect.dart` route can leave too. In a tab layout the route stays in
  its tab, after the page.
- **What it keeps.** Everything comes from the folders, not from where the route is written, so
  the guards of the page it leaves and of the page-less folders in between run first, outermost
  first, then its own (like those of a page-less folder, they are the route's inherited
  guards); the nearest `transition.dart`, `navigator.dart`, `not_found.dart` and `loading.dart` /
  `error.dart` still apply; the segments of the folders it leaves are parsed and typed for it, its
  data and its views, and a segment that doesn't parse is not-found as before; the data of
  the sections above it is the same, so `AppRoutes.match` and `dataAt` list the same providers.
  What the page it leaves builds and reads is not part of it: its page, its `data.dart`, its
  `present.dart`. A dialog or sheet [transition](#transitions) opens over the page that stays
  below it, `orders/$id`.
- **`caseSensitive`.** One go_router path is one flag, so the whole compound path matches by the
  route's own setting: the nearest `route.dart` at or above it, its own included.
- **Order.** go_router takes the first route that matches the whole URL, depth first, and goes on
  to the next sibling when a route's children don't match the rest (`match.dart`, the same in
  go_router 17.5 and 18.0), so `refund` and `refund/confirm` can come in either order. Static
  routes come before `:param` ones and catch-alls as always, and fespalier puts a static
  `refund/confirm` before `refund` when something below `refund` (a `$step`, a `$$rest`) would
  match `confirm` first, as it would nest. Otherwise it follows the page, so a tab still opens on
  it. A route that something earlier still catches is the usual
  [unreachable error](#group-folders).
- **Errors, each with a code frame on the declaration.** `nest = false` where there is nothing to
  leave: in the app folder, in a `(group)` (which has no route of its own; the error names the group
  shape above), in a folder with no `page.dart` or `redirect.dart`, or with no `page.dart` above.
  A `layout.dart` in the page's folder or in a page-less folder between: the route would leave its
  shell, so move the layout above the page, or drop `nest`. A value that isn't a `true` or `false`
  literal, or two of them. A route on the root navigator (`navigator.dart`, `present.dart`) that
  would become a direct child of a layout is the existing
  [root navigator](#the-root-navigator-navigatordart) error.

`examples/features` has `orders/$id/refund/confirm` (and `refund/receipt`, which nests), with a
guard on `refund/` and widget tests for the stack a deep link builds and what back does.

### Tab layouts

A `layout.dart` that asks for a `StatefulNavigationShell` (named `navigationShell` or
`shell`, or by that type) instead of a `Widget child` is a tab layout. It becomes a
go_router `StatefulShellRoute.indexedStack` (or, with a [`container`](#tab-layouts), your own
`navigatorContainerBuilder`), so each tab keeps its own navigation stack
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
`examples/tabs`, `/settings` has no navigation bar. To cover the screen while the URL stays in
a tab (`/profile/edit`), use [`navigator.dart`](#the-root-navigator-navigatordart). Two things to
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

```text
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

**Container.** By default the tabs' navigators sit in an `IndexedStack`. A tab layout can
export a top-level `container` function to arrange them itself, say to cross-fade or slide
between tabs:

```dart
// lib/app/(tabs)/layout.dart
Widget container(BuildContext context, StatefulNavigationShell shell, List<Widget> children) =>
    CrossFadeContainer(currentIndex: shell.currentIndex, children: children);
```

The generated route is then `StatefulShellRoute(navigatorContainerBuilder: _i1.container, …)`
instead of `.indexedStack(…)`; a layout without `container` generates exactly what it did
before. The three parameters are positional, and their **types are fixed** (`BuildContext`,
`StatefulNavigationShell`, `List<Widget>`; the names are yours): a wrong type, a missing or an
extra parameter, or a return type that isn't `Widget` is an error at the parameter. `children`
holds one navigator per tab in the layout's tab order, and the container must keep them all in the
tree (`Offstage`, `Opacity` or a `Stack`, as `IndexedStack` does) or the tabs lose their state.
A `container` in a layout that isn't a tab layout is ignored with a warning. `examples/tabs`
cross-fades, and its tests check that a tab's state survives.

### Guards

`guard.dart` exports `GuardResult guard(Ref ref, {…})`. It returns a location to
redirect to, or `null` to let the navigation through, and may be async. It guards every
route at and below its folder, and the folder needs no `page.dart`: put one in a `(group)` or
at the root to cover a whole section of the app.

```dart
// lib/app/(members)/guard.dart: guards /inbox, /admin and everything else in the group
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

- **It runs again when what it watches changes** (since 0.5.0). `ref.watch` a provider in
  the guard and, when that provider changes and the guard's answer is now a different one,
  the router runs the redirects again: signing out moves you to the login page from whatever
  member page you were on, with no refresh code of your own (before 0.5.0 a guard read once,
  when you navigated, so nothing happened until you did). The login page is not under that
  guard, so signing in is the login page's to navigate (`returnTo`), unless it has a guard of
  its own that watches the session.
  Nothing is wired up: it works for `AppRoutes.router()` and for a router of your own built
  from `AppRoutes.mount()`, with no `refreshListenable`. An async guard watches the same way,
  through a provider's `.future`:

  ```dart
  Future<String?> guard(Ref ref, {required Uri uri}) async =>
      await ref.watch(currentUser.future) == null
          ? LoginRoute(from: uri.toString()).location
          : null;
  ```

  `ref.read` is for what must be the current value when you navigate and never changes the
  answer later. A guard that returns the same answer after a change does nothing.
- **What it costs.** Return synchronously when you can. A guard that needs no `await` should
  not be `async`, and not return `Future.value(...)` either: it then answers synchronously, in
  the same frame as the navigation, and the first frame at boot (a cold deep link too) already
  shows the page. Any `Future`, even a completed one, costs the router a frame, and the first
  frame is blank. Each navigation runs the guard in a fresh `autoDispose` provider, so
  what it `ref.watch`es is shared with the rest of the app and fetched once; the guard itself
  runs again after a change and again when the router asks, so keep it cheap. A guard
  signing out therefore runs twice (Riverpod recomputes it, then the router asks), and the
  data providers it watches are not fetched twice.
- **When it stops watching.** The guard of the location the router shows keeps watching.
  It is dropped when a navigation ends on a location that does not run it, and when the
  router or the app goes. A guarded page _under a pushed page_ does not react until you pop
  back to it (the push dropped its subscription; popping runs the guard again). Don't call
  `ref.keepAlive()` in a guard: it keeps one provider alive per navigation.
- **If it throws.** A guard that throws, or whose later run throws, never moves the
  router: an error on a navigation reaches go_router like any redirect's, and an error on a
  later run keeps the page you are on until the next navigation. The guard's provider does not
  retry.
- **The older form.** A guard may still take `ProviderContainer c` first
  (`c.read(session)`): it is read once per navigation, as before 0.5.0, and never runs again by
  itself. Taking a `WidgetRef` is an error ("a guard runs outside the widget tree: take
  `Ref`"), since a guard has no widget.
- **Order.** Guards run outermost first, and the first one to return a location wins. A
  folder with a page and its own guard keeps its guard for that page and everything nested
  in it; guards above it run first. A route with [`nest = false`](#a-sibling-with-a-compound-path)
  is not nested in the page above it, and still gets that page's guard, after the ones above it.
- **Parameters.** The `Ref` comes first, then named parameters: `uri` (the
  requested location, a `Uri`), `extra` (see [Typed `extra`](#typed-extra)), the segments of the guard's own folder and the ones above
  it (`{required String shop}`), and query parameters (optional and nullable, `String? ref`).
  A guard above `$id` can't ask for `id`: that's an error at the parameter. Segments are
  typed like everywhere else. A guard's query parameters stay its own: they don't become
  fields of the typed routes below it (unless the guard sits next to a `page.dart`, where
  they are the page's, as before).
- **What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in order, the
  guards of the page-less folders above it and then its own. A `Ref` guard is called as
  `refGuard(context, 'g8@3', (ref) => _i8.guard(ref, uri: state.uri))` (the string names the
  guard on that route, and is constant). Nested pages go through their
  parent's `redirect`, so no guard runs twice. (A route that leaves the page above with `nest = false`
  has that page's guard and the ones of the folders between in its own `redirect`, the way a page-less
  folder's guard is, since the page is not its parent.) There's no redirect on `ShellRoute` or
  `StatefulShellRoute`: go_router runs a matched route's redirect for deep links and for
  navigation inside a shell, tabs included, so the page routes are enough (and a page-less
  folder has no route to put one on). When a path has a segment that doesn't parse
  (`/products/abc`), not-found is shown, and a guard that asks for segments or query parameters
  is skipped, since it has nothing to read. A guard that asks for neither (only `uri`,
  `extra`, or nothing) still runs, so it can redirect `/products/abc` to login.
- A `guard.dart` with no `page.dart` or `redirect.dart` at or below its folder is a warning.

### `redirect.dart`

A folder can hold `redirect.dart` instead of `page.dart`. It exports `String redirect({…})`
(or `Future<String>`) returning the location to go to, and the route only redirects: no
widget, no builder.

```dart
// lib/app/old-products/$id/redirect.dart: /old-products/3 → /products/3
String redirect({required int id}) => ProductRoute(id: id).location;

// ...or, reading a provider (a redirect's `ref.watch` runs once, it does not re-run)
String redirect(Ref ref, {required int id}) =>
    ref.read(catalog).contains(id) ? ProductRoute(id: id).location : const HomeRoute().location;
```

It takes the same parameters as a guard, except that the first one is optional: put `Ref ref`
first if you need providers (since 0.5.0; `ProviderContainer c` is the older form). A redirect
runs once per navigation and does not watch: a redirect route never stays on screen, so there is
nothing to run again. Segments are typed like anywhere else, so `/old-products/abc`
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

**What it gets.** `Uri uri`, and the segments of its own path as `String`s, as the URL spells
them (`teams/$teamId/not_found.dart` can take `String teamId`). They are raw on purpose: a
segment that didn't parse (`abc` where an id is an `int`) is often the reason you are here, so
a not_found.dart can't ask for it typed, and one that declares `int teamId` is an error that says
so. The value is the decoded path part: `/teams/Acme%20Co/members/x` gives `Acme Co`. It gets
no query parameters and no data. `fsp new members --not-found` scaffolds one (with the segments
it can take).

A `(group)` folder adds nothing to the URL, so its
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

**A layout's shell is a page too.** The `ShellRoute` a `layout.dart` makes, and a tab layout's
`StatefulShellRoute`, take the nearest `transition.dart` (the layout folder's own included) as
their `pageBuilder`, so a layout moves like any other page when a route on the
[root navigator](#the-root-navigator-navigatordart) opens over it. The shell's page key is
`ValueKey<String>('layout:(tabs)/')`, made from the layout's folder: it is the same on every
launch (its restoration id, see [State restoration](#state-restoration)) and while you
switch routes inside the shell, so **only entering or leaving the shell animates it**, not going
from one page of the layout to another. A layout with no `transition.dart` above it keeps
`layoutPage(…)`. Since `fsp init` writes a root `transition.dart`, that means most apps' shells now
have a `pageBuilder` of their transition's making: regenerate and check your layouts.

A `transition()` that needs to tell a shell from a route (to wrap a route's page in something
its shell shouldn't get) can take `bool shell` (or `isShell`): `true` for a layout's shell, `false`
for a route's page. It is the only extra parameter besides `key`, `child` and `state`.

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
  the dialog opens over an empty screen. (A route with
  [`nest = false`](#a-sibling-with-a-compound-path) is not below the page of the folder above it,
  so it opens over the page above that one.)
- **They cover their own navigator only.** Inside a tab, a dialog covers that tab's
  navigator, not the tab layout's navigation bar; the same goes for a `layout.dart`'s
  body. Put the route outside the layout's folder to cover the whole screen, or give it a
  [`present.dart`](#presentdart-a-page-of-your-own) (which puts it on the root navigator) or a
  [`navigator.dart`](#the-root-navigator-navigatordart) beside its `transition.dart`.
- **They need `MaterialLocalizations`,** like `showDialog` and `showModalBottomSheet`: a
  `MaterialApp` (or a `Localizations` with the Material delegate) above the router.
- The route's `transition.dart` also covers routes below it, so give a dialog route its own
  folder.

Routes with no `transition.dart` above them keep go_router's default for your app type:
the platform transition under a Material or Cupertino app, none otherwise (see the go_router
18 note in [Getting started](#getting-started)). Scaffold one with `fsp new … --transition`.

### The root navigator (`navigator.dart`)

A route's URL and the navigator it renders on are two decisions. A tab layout puts every route
in its folder on a tab's navigator, under the navigation bar. `navigator.dart` says that a
folder renders on the **root** navigator instead, above every layout and tab bar, without
moving its URL:

```dart
// lib/app/(tabs)/profile/edit/navigator.dart
const navigator = RouteNavigator.root;
```

`/profile/edit` is still under `/profile` (a deep link builds the Profile tab beneath it, and back
returns to it, with its state), and the page covers the whole screen. The declaration applies to
its folder's routes and to **every folder below it**, and the nearest one wins, like
`transition.dart`; a page-less `(group)` folder can hold it too, for the routes inside. `fsp gen`
emits `parentNavigatorKey: rootNavigatorKey` on the route and on all its descendants (`go_router` puts a
route on its enclosing shell's navigator unless it says otherwise, so a child pushed from the page
would land _under_ it), and the route table marks them `(root)`.

The generated file owns the key: `AppRoutes.rootNavigatorKey` is a `GlobalKey<NavigatorState>` the
app can read (the last `router()` or `mount()` call's: a call that is given no key makes a fresh one
rather than keeping an earlier call's, since 0.5.0); `AppRoutes.router(navigatorKey: …)` uses one you supply; and
`AppRoutes.mount(at:, navigatorKey: …)` takes the **host** `GoRouter`'s own key, since a
`parentNavigatorKey` must name an ancestor navigator.

- `fsp` reads the file from the source, like `tabs`: a `const navigator` that is
  `RouteNavigator.root` or `RouteNavigator.shell`, spelled out; anything else is an error at it.
- **A layout is a navigator of its own.** A `layout.dart` below a root folder becomes a
  `ShellRoute(parentNavigatorKey: rootNavigatorKey, …)` (or the `StatefulShellRoute`); the routes
  inside it sit on its own navigator, since go_router doesn't allow a key other than the shell's
  there. Below a layout nothing is inherited, and `RouteNavigator.shell` is what a folder says to
  be explicit about it. Below a root route with **no** layout in between, `.shell` is an error:
  go_router only lets a descendant use the root navigator or a navigator above it.
- **A root route can't be a direct child of a shell.** go_router lifts a route out of its shell
  only from below another route, so a root route that is the first route of a tab, or sits beside
  others directly in a layout, is an error (put it below a `page.dart` that stays in the layout, or
  move its folder out of the layout's folder).
- The typed route is unchanged: `EditProfileRoute().push(context)` and `.go(context)` as before.

`examples/tabs` does this for `/profile/edit`; its tests check that there is no `NavigationBar`, that
back returns to the tab, and that a deep link builds the tab underneath.

### `present.dart`: a page of your own

`present.dart` builds **this route's own `Page`**. It is for a sheet (or a dialog, or any page
class the app owns) with a URL: `/products/:id/buy` opens a sheet over `/products/:id`, from a
link or a deep link.

```dart
// lib/app/products/$productId/buy/present.dart
Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);
```

It is bound like `transition.dart` (`key`, `child`, `state`), and what it returns is used
**verbatim**: fespalier adds no scrim, handle or shape, and ships no sheet widget. Unlike
`transition.dart`:

- it applies to **its own folder only**: a folder below keeps the nearest `transition.dart` for
  its own page;
- it puts the route on the **root navigator**, over a tab bar and any `layout.dart`, and its
  descendants too (the [`navigator.dart`](#the-root-navigator-navigatordart) rules, so a child of
  a sheet renders above it, never under it, and go_router never builds the shell twice). A
  `navigator.dart` in the same folder overrides that (`RouteNavigator.shell` keeps a sheet in
  a tab);
- it needs a `page.dart` (a warning and no effect otherwise), and, to have a parent underneath on a
  deep link, the sheet's folder should sit below the parent page's folder.

The route table marks it `(present, root)`, and the manifest's `presentation` is
`RoutePresentation.custom` (fespalier can't know it is a sheet: say so in a `meta.dart` if you want
to). `examples/features` has `/photos/share`, with an app-owned `SheetPage` in `lib/`, a
child page above it, and tests for the deep link, the parent's state after popping, and the root
navigator.

### Query parameters

A query parameter's type comes from the parameters that ask for it, like a segment's:
`T?` for a single value, `List<T>` for repeated ones. Every file of a route that asks
for `?page` must agree on its type. A missing or unparsable value is `null` (or left out
of a list); unlike a bad segment, it never leads to not-found. The typed route takes
query parameters as optional arguments and writes them into `.location`, leaving out
nulls and empty lists. A query parameter can be an [enum](#enum-segments) too (`Sort? sort`,
`List<Sort> sorts`): a value that names none is `null`, and `.location` writes `.name`.

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
error at that parameter). The object isn't in the URL, so a deep link, a page opened from
`context.go('/notes/3')` and (without an [`extraCodec`](#restoring-extra-on-the-web)) a
reload or a restored state all get `null`: build the page from the URL (`id`) and treat
`extra` as a shortcut, not the source of truth. Passing an object of the wrong type around
the typed route (a plain `context.go(location, extra: …)`) is an assertion error in debug
builds and reads as `null` in release builds.

`extra` is a reserved name: a segment can't be called `extra`, and a query parameter of
that name is the extra, not `?extra=`. The generated file has to name the type for the
typed arguments, which is the one place it copies from your imports: it imports the type
`show`ing that name from each of the file's imports (a library that doesn't export it is
ignored; a type declared in the file itself, or under an import prefix, is found too),
so the type must be reachable from the file's own imports. The built-in `dart:core`
types need nothing.

**Layouts, guards and redirects take it too.** A `layout.dart`, a `guard.dart` or a
`redirect.dart` can ask for `extra` the same way (a nullable type; a guard and a redirect take
it as a named parameter). Each gets the extra of the location it is at now, `state.extra`:

```dart
// notes/layout.dart: the frame above every note
class NotesLayout extends StatelessWidget {
  const NotesLayout({super.key, required this.child, this.extra});
  final Widget child;
  final Note? extra;
  …
}

// notes/$id/guard.dart: a draft isn't shown yet
GuardResult guard(Ref ref, {Note? extra}) =>
    extra?.title == 'draft' ? const HomeRoute().location : null;
```

A layout or a guard sees the extra of _every_ route it covers, so its type has to fit theirs,
or it's an error at its parameter, with a code frame that lists the routes:

- A guard or layout takes `Object?` (or `dynamic`) to accept anything, or **the type of the
  routes it covers**: `Note?` above pages that take `Note?`. Nullability aside, the names have
  to match. A route that takes no extra puts no condition on it.
- So a layout above routes with different extra types must take `Object?`; otherwise the
  routes that don't fit are listed:

  ```text
  error: `extra` is `Note?` here, but the routes it covers take other types: `/notes/:id/print`
         (notes/$id/print/page.dart takes `Receipt?`); a layout sees the extra of every route it
         covers, so declare it as `Object?` to accept any of them, or as their type when they share one
    ┌─ lib/app/notes/layout.dart:3:53
  ```

  A page's or redirect's own type decides for a route; on a route without one, the guards and
  layouts above it must agree with each other. A layout isn't compared with a `redirect.dart`
  route below it, which never shows it.

- A route that takes no extra of its own gets the type its guards and layouts agree on, so
  `NoteRoute(...).go(context, extra: note)` is typed even if the page ignores it.
  `Object?` says nothing about a type: it adds no typed argument.
- **A wrong type never crashes them.** A layout, a guard or a redirect sees extras meant for
  other routes, so an object that isn't a `Note` reads as `null` (`extraOrNull`), and so does an
  extra that isn't there. Only a page asserts, as above. The type is nullable so that `null`
  always fits.

#### Restoring `extra` on the web

go_router keeps a navigation's `extra` next to its location, for the browser's history and for
state restoration, but can only save what is JSON. Without help, an object with a `toJson()`
comes back as the JSON `jsonEncode` made of it (a `Map`), and any other object is dropped
(and go_router logs a warning): neither is your type, so a page that asks for a `Note?` gets
`null` in release builds and, for the `Map`, an assertion in debug builds. To get the object
back, give the router an `extraCodec`.

Put a top-level `extraCodec` in `lib/app/extra_codec.dart`, at the root of the app folder (a
`const`, a `final` or a getter; `fsp` only looks for the name). The generated
`AppRoutes.router()` passes it as `GoRouter(extraCodec: …)`:

```dart
// lib/app/extra_codec.dart
import 'package:fespalier/fespalier.dart';

final extraCodec = ExtraCodec({
  Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
  Mode: (toJson: (Mode m) => m.name, fromJson: Mode.values.byName),
});
```

`ExtraCodec` takes each type and how it becomes JSON and back (annotate the parameter of
`toJson`; a constructor tear-off does for `fromJson`), and saves an object under its type's
name. `null`, strings, numbers, booleans and plain JSON lists and maps need no entry. It
never breaks navigation: an object whose type isn't registered is saved as `null`, and saved
data that no longer reads (the type was removed, or `fromJson` throws) comes back as `null`,
so a page falls back to what the URL says. Pass `strict: true` to throw instead, in a test that
checks you registered every type.

- The type is looked up by its exact runtime type: register each subclass of a sealed class.
- The name is `Type.toString()`, which a release build for the web minifies (stable within a
  build, different in the next). To keep saved data readable across deployments, name the types:
  `ExtraCodec({...}, names: {Note: 'note'})`.
- Write your own `Codec<Object?, Object?>` instead if you like (`const extraCodec = MyCodec();`).
- `AppRoutes.mount()` doesn't take it: a router you build yourself passes
  `extraCodec: extraCodec` (imported from that file) to `GoRouter`. A router restores only what
  it is given a `restorationScopeId` for (see [State restoration](#state-restoration)).
- `extra_codec.dart` in a subfolder is a warning, and a file without an `extraCodec` is an
  error.

`examples/tabs` does this for a `ProfileDraft` passed to its edit page, and its restoration test
restarts the app and checks the draft is still there (and, for contrast, what a router without the
codec restores). `examples/features` has a layout and a guard that read a `Note?` extra.

### `data.dart`: a function, a selector or a provider

`data.dart` has three forms, told apart by what it exports:

| You write                                                                                                                                | fespalier                                                                     | Use it when                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `Future<T> data(Ref ref, {…})` (or `Stream<T>`, or `T`)                                                                                  | wraps it in an autoDispose `FutureProvider` (`StreamProvider` for a `Stream`) | the data is fetched for this route only: the function is the fetch                                       |
| `ProviderListenable<AsyncValue<T>> data({…}) => productProvider(id)`                                                                     | calls it and uses the provider it returns; nothing is wrapped                 | a provider for it already exists, above all a `riverpod_generator` one                                   |
| `final data = FutureProvider<T>(…)` (or `StreamProvider`, `AsyncNotifierProvider`, `StreamNotifierProvider`), type arguments spelled out | uses it as-is                                                                 | you want to write the provider yourself (a notifier, `keepAlive`, `retry:`) and it belongs to this route |

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
- A section's `data.dart` can be a selector too, and takes segments and query parameters
  like a page's.

The other two: write a function and fespalier wraps it in an autoDispose
`FutureProvider` (or `StreamProvider` for a `Stream`). Or export a provider named `data` yourself:
`FutureProvider`, `StreamProvider`, `AsyncNotifierProvider` or `StreamNotifierProvider`,
with its type arguments spelled out. It's used as-is.

In all three forms the route exposes it as `XRoute.data`, keyed by the segments and query
parameters `data.dart` uses:

| Parameters used | Provider                              | Watch it with                                   |
| --------------- | ------------------------------------- | ----------------------------------------------- |
| none            | plain                                 | `ref.watch(ProductsRoute.data)`                 |
| one             | `.family<T, int>`                     | `ref.watch(ProductRoute.data(42))`              |
| several         | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

A family provider you write yourself follows the same rule, for segments: with several
of them, its argument is a record naming the ones it uses, e.g. `({String shop, int id})`.
It can't be keyed by a query parameter (a record field that isn't a segment is an error).
To key by one, write the function form (`Future<T> data(Ref ref, {int? page})`) or select your
provider with a `data()` that takes it (see above).

To see a scaffolded `error.dart` and its retry, throw from `data.dart`, e.g.
`throw Exception('offline')`.

#### Retries and reloads

Two settings in the `fespalier:` section of `pubspec.yaml` decide what a route shows while
its `data.dart` fails or loads again:

```yaml
fespalier:
  data_retry: inherit # inherit | none
  keep_previous: true # true | false
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
final warm = ProductRoute(id: 42).prefetch(ref);   // a PrefetchHandle, before navigating
```

`watch` and `read` are _static_, and take the keys the provider uses as named arguments
(`ItemRoute.watch(ref, shop: 'a', id: 1)`, `SearchRoute.watch(ref, q: 'ap', page: 2)`;
none for a route without keys). They can't be instance methods: `ProductRoute(id: 42).watch(ref)`
would have to write `AsyncValue<Product>` into the generated file, and the generator never
copies your imports. A static function value takes its type from the provider by
inference, so `Product` flows through and is never `dynamic`. (More in
[Design notes](#design-notes).)

`read` keeps the provider alive until it completes, which a plain `ref.read(p.future)`
doesn't for an `autoDispose` provider. Don't call it from `build`.

`prefetch(ref)` starts the load and returns a `PrefetchHandle` that **keeps the provider alive
until you call `close()`** on it, so the page you navigate to next shows the value at once. The
generated providers are `autoDispose`, so a prefetch nobody watches would be dropped in the same
frame; the handle is what holds it, and how long is yours to decide: an app's prefetch queue
holds one per lease and closes it when the lease ends. `keepFor:` is an optional auto-close
(`prefetch(ref, keepFor: Duration(seconds: 30))` closes the handle after that long). A failed
load isn't kept (the handle closes itself): the page starts a fresh one instead. Call it before
`go`, e.g. on hover:

```dart
MouseRegion(
  onEnter: (_) => _warm = ProductRoute(id: p.id).prefetch(ref),
  onExit: (_) => _warm?.close(),
  child: ListTile(onTap: () => ProductRoute(id: p.id).go(context), …),
)
```

A few things to know: closing twice is fine, and `handle.isClosed` tells; the subscription
also ends when the widget whose `ref` you pass is disposed, and since 0.5.0 that closes the
handle and cancels its `keepFor` timer with it, so no timer outlives the widget; while the
widget is alive `keepFor` holds a timer, so a widget test that uses it should `pump` past it (or
pass `Duration.zero`, which starts the load and keeps nothing); and _the default changed_: a prefetch used to lapse after 30 seconds without a
`keepFor`, and now lasts until closed (a `prefetch(ref)` whose handle is dropped lasts as
long as the widget behind `ref`). `prefetchKeepAlive` is gone.
Because these are members of the route class, `watch`, `read`, `prefetch`, `refresh`, `ref`
and `keepFor` can't be segment or query names, and neither can the helpers of an
[`action.dart`](#actiondart-typed-writes) (`submit`, `useAction`, or an action's own name).

### From a location to its data

An app's own prefetch layer often starts from a _location_ (the next page a list points at),
not from a route it built by hand. Two generated functions on `AppRoutes` answer that from the
tree, without a table of your own:

```dart
final providers = AppRoutes.dataAt(Uri.parse('/products/42'));
// [ProductRoute.data(42)]: the provider the page watches, so warming it warms the page.
final handle = ref.prefetchAll(providers ?? const []);   // one PrefetchHandle for them all
// ... later, when your queue's lease ends:
handle.close();
```

`dataAt(uri)` is a `List<ProviderListenable<AsyncValue<Object?>>>?`, **outermost first**: the
`data.dart` of each [section](#section-data) above the route, then its own. It is:

- `null` when no route fits the location, or when a segment doesn't parse (`/products/abc`
  where the id is an `int`): the rule that shows `not_found.dart`;
- empty for a route without data (a page, or a catch-all with nothing behind it): a match, with
  nothing to warm.

The key is built by the same parser the route uses, so `dataAt(Uri.parse('/products/42')).single
== ProductRoute.data(42)`, and for a `data.dart` that [selects a provider](#datadart-a-function-a-selector-or-a-provider)
it is the selected provider itself (your own `productProvider('42')`). Query-keyed data is keyed by
the query of the location (`/search?q=ap&page=2` is `SearchRoute.data((q: 'ap', page: 2, …))`,
lists as the `QueryList` the page's key uses), a [catch-all](#catch-all-segments) by its decoded
path. The mount point (`AppRoutes.mount(at: '/shop')`) is taken off first, a location outside it
is `null`, and each route matches its path by its own case setting (`case_sensitive: false`, or its folder's `route.dart`). A [typed catch-all](#catch-all-segments) (`List<int>`) parses each part like the page does, so one that fails is no match. Nothing else runs: no
`guard.dart`, no `redirect.dart`, no widget. (A guard may well send the user somewhere else
when they arrive; prefetching what they asked for is your queue's call, and never
triggers it.)

`AppRoutes.match(uri)` is what `dataAt` is a shortcut for (`match(uri)?.data`, over the same
matching, so it isn't written twice). It returns a `RouteMatch`, or `null` under the same rules:

```dart
final m = AppRoutes.match(Uri.parse('/shops/acme/items/7'))!;
m.info;      // the RouteInfo from the manifest: path '/shops/:shop/items/:id', folder, meta, ...
m.params;    // {'shop': 'acme', 'id': 7}: the segments and query parameters, parsed
m.route;     // ItemRoute(shop: 'acme', id: 7), typed; m.route.location is its canonical spelling
m.data;      // the providers, as dataAt returns them
m.uri;       // the location it was given
```

Routes are tried most specific first (static parts, then `:param`s, then catch-alls), the order
go_router uses. `match` lives on the manifest (`AppManifest.match`, forwarded by `AppRoutes`,
like `all`), so with [`output_manifest:`](#route-manifest-and-metadart) it is in the manifest
library; `AppRoutes.dataAt` and `AppRoutes.matchUrl` (a `UrlMatch`: the route, params and data
without the `RouteInfo`) stay in `app.g.dart`, which never imports a `meta.dart`.
`RouteMatch` is fespalier's: `package:fespalier/fespalier.dart` hides go_router's own
`RouteMatch` (an internal of its parser) to make room for it, so import
`package:go_router/go_router.dart` if you need that one.

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
  usual) replaces the layout _and_ the pages inside it, and a failure shows the nearest
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
- **Keys.** A section's `data()` takes segments (at or above its folder) and, like a page's,
  query parameters: `Future<Report> data(Ref ref, {String? period})` keys the section by
  `?period=` of the location. The layout reads it from the URL like any layout query parameter.
  Every route below the section is then keyed by it too: `period` becomes a query parameter of
  each of their typed routes (`MonthlyReportRoute(period: '2026-01')` writes
  `/reports/monthly?period=2026-01`), so the pages below read the same provider the layout
  loaded. A page that declares the same name with another type is an error, as anywhere.
- **Typed handle.** A section has no route of its own, so it gets a class named after its
  folder, with `Section` on the end (`teams/$teamId` is `TeamsTeamIdSection`, `(shop)` is
  `ShopSection`, the app folder `RootSection`; two folders that name the same class are an
  error). Its members are static and take the section's keys as named arguments, like a route's:

  ```dart
  TeamsTeamIdSection.data('acme');                         // the provider
  TeamsTeamIdSection.watch(ref, teamId: 'acme');           // AsyncValue<Team>
  await TeamsTeamIdSection.read(ref, teamId: 'acme');      // Future<Team>
  final h = TeamsTeamIdSection.prefetch(ref, teamId: 'acme');   // PrefetchHandle
  await TeamsTeamIdSection.refresh(ref, teamId: 'acme');
  ```

  A key can't be called `ref`, `keepFor` or another of the handle's members.

- **Where it applies.** A layout of any kind can be a section's, tab layouts included. A
  `data.dart` beside a `page.dart` keeps feeding that page, so the folder that holds the
  section's layout mustn't have a page.

### `action.dart`: typed writes

`data.dart` is the read side of a route. `action.dart` is the write side: a submit, a save, a
delete, a "mark as paid". It sits beside a `page.dart`, and it takes the same segments and query
parameters, plus the value being written, `input`:

```dart
// lib/app/orders/$id/refund/action.dart
Future<Refund> action(Ref ref, {required int id, required RefundInput input}) =>
    ref.read(apiProvider).refund(id, input);
```

fespalier turns it into a provider with pending and error state, and into helpers on the typed
route. After a success it invalidates the data the write made stale, so the page shows what the
server says now: no `isSubmitting` field, no `try`/`catch`, and no `ref.invalidate` to forget.

```dart
// in a HookConsumerWidget (or any ConsumerWidget): the state of the write, and a way to run it
final refund = RefundRoute.useAction(ref, id: id);
FilledButton(
  onPressed: refund.isPending ? null : () => refund.call(RefundInput(amount: 10)),
  child: Text(refund.isPending ? 'Refunding...' : 'Refund'),
),
if (refund.hasError) Text('${refund.state.error}'),            // the page stays; error.dart is not used
if (refund.state.value case final done?) Text('Refunded ${done.amount}'),

// in a callback or a test: run it once, get the result, or the exception it threw
final Refund done = await RefundRoute.submit(ref, id: 1, input: input);
```

- **Parameters.** Segments and query parameters bind exactly as in
  [`data.dart`](#datadart-a-function-a-selector-or-a-provider): the same names, the same types
  and the same errors. The one other parameter is `input`: **named, `required`**, of any type
  (`RefundInput`, `String`, a record, a `List`, `Object?`). Its type is read from the source like
  a typed [`extra`](#typed-extra)'s, imports and a type declared in the file included, so the
  generated `submit` is typed. A `Ref ref` comes first, positional.
- **Return type.** `Future<T>`, `FutureOr<T>` or a plain `T` (`Future<void>` is fine). It is
  spelled out. **The helpers keep what the function is**: a sync action's `submit` returns its
  value at once, with no `Future` and no extra frame, a `FutureOr<T>` one's returns what the
  function returned, and a `Future<T>` one's returns a `Future<T>`. A `Stream` is an error: a
  write has one result.
- **Several actions per file.** Every public top-level function that takes a `Ref` first is an
  action, and its name is the name of its helpers. A function called `action` gets the plain ones:

  | Function  | Provider (`XRoute.…`) | Runs it once                  | Hook for `build`         |
  | --------- | --------------------- | ----------------------------- | ------------------------ |
  | `action`  | `action(keys)`        | `submit(ref, keys…, input:)`  | `useAction(ref, keys…)`  |
  | `approve` | `approveAction(keys)` | `approve(ref, keys…, input:)` | `useApprove(ref, keys…)` |

  A helper can't be named like a member of the route (`go`, `refresh`, `watch`, `data`, …), a
  segment or query parameter of it, or another action's helper (a function called `submit` next to
  `action`): the generator says which.
- **The provider** is a generated `Notifier` family, `XRoute.action(id)` (`XRoute.action` when
  there are no keys), whose state is `AsyncValue<T?>`: `AsyncData(null)` while idle, then
  `AsyncLoading`, then `AsyncError` or `AsyncData` of the result. It works without a widget:
  `container.read(RefundRoute.action(1).notifier).call(input)`, which is what a test can do. Each
  key has a state of its own, and an `autoDispose` provider is dropped when nothing watches it,
  except while a write is in flight.
- **`useAction`** takes the keys and returns a handle: `state` (the same `AsyncValue<T?>`),
  `isPending`, `hasError`, `reset()`, and `call(input)`. `call` runs the action and completes with
  the result, or with `null` when it failed, because the error is in `state`: an `onPressed:
  () => refund.call(input)` can't leave an unhandled error behind. `submit` is the other way: it
  throws what the action threw, for code that wants to handle it (and the error is in `state` too).
  Neither navigates, and neither is for `build`'s own body: call them from an event handler.
  (`useAction` is a hook by name only: it needs a `WidgetRef`, not hooks, and works in any
  `ConsumerWidget`.)
- **`submit`, `useAction` and the provider are static**, like [`watch` and `read`](#typed-helpers-on-the-route):
  `RefundRoute(id: 1).submit(...)` would have to name `Refund`, which the generated file can't (see
  [Design notes](#design-notes)). The types are inferred from the provider, never `dynamic`. The
  input is the one type that is spelled out, and it is read from your file.

**After a success.** The data the write made stale is invalidated, and loads again (with
[`keep_previous`](#retries-and-reloads), what the page shows stays until the new value is there):

- by default the route's own `data.dart` and the [section data](#section-data) above it: the set
  [`AppRoutes.dataAt`](#from-a-location-to-its-data) lists for the route, for the keys the action
  was called with;
- or what `const invalidates = [...]` lists, which **replaces** that set. Name typed routes and
  section handles (`RefundRoute`, `OrderRoute`, `TeamsTeamIdSection`): providers aren't `const`,
  and the generator knows which provider each one is. `const invalidates = <Object>[];`
  invalidates nothing. Anything else the write touches, a provider of your own, can be
  invalidated by the action itself, which has a `ref`.

```dart
// lib/app/orders/$id/refund/action.dart
import 'package:my_app/app.g.dart';

/// The quote on this page, and the order page above it, are stale after a refund.
const invalidates = [RefundRoute, OrderRoute];

Future<Refund> action(Ref ref, {required int id, required RefundInput input}) => …;
```

A listed route's `data.dart` is keyed by something, and the action has to take it, with that type,
to say which one to invalidate (`OrderRoute`'s `data.dart` takes `int id`, so the action takes
`id`; a `String? q` of a search page's data is one the action takes too). When it can't tell,
that's an error that says so.

**Errors.** A failed write is `AsyncError` in the state, and it is **not** the page's: the nearest
[`error.dart`](#datadart-a-function-a-selector-or-a-provider) is not used, because a failed refund
shouldn't replace the form that started it. **A write is never retried**: the generated provider
doesn't use Riverpod's [retry](#retries-and-reloads), whatever `ProviderScope(retry:)` says, and
nothing else runs it again. A failed write invalidates nothing. Trying again is the user's call:
the next `call` or `submit` replaces the error, and `reset()` clears it.

**Concurrent runs, and a page that goes away.** Nothing stops a second `call` while one is pending:
both run, each invalidates after its own success, and the state follows the last one started (a
late result of the first doesn't replace it). Disable the button while `isPending` when a double
write is wrong. The provider is kept alive until the write completes, even if its page is popped
meanwhile, so the write still finishes and still refreshes the data; the state is only written
while the provider is alive, so a submission that finishes after the page, or the whole container,
is gone doesn't throw. After an `await` in a callback, check `context.mounted` before navigating.

**Navigation is the caller's.** An action returns what it wrote, and doesn't navigate:

```dart
final done = await RefundRoute.submit(ref, id: id, input: input);
if (context.mounted) ReceiptRoute(id: id).go(context);
```

**In a section's folder.** An `action.dart` in a folder with a `layout.dart` and no `page.dart`
writes to the section. Its helpers are on the section's handle (`TeamsTeamIdSection.addMember(ref,
teamId: 'acme', input: 'carol')`), and what it invalidates by default is the section's own data and
the sections above it. A section with no `data.dart` gets a handle for its actions alone
(`ShopSection`), named like [any section's](#section-data).

Not in this version: optimistic updates. `state` plus `invalidates` cover most pages. Since 0.5.0.

`fsp new 'orders/[id]/refund' --action` scaffolds one, with the path's segments and an `Object?`
input to replace with your own type. `fsp routes` tags the route `action` (also in the `tags` of
`--json`, which only gains the value). The generator reports, with a code frame:

- an `action.dart` with no `page.dart`, and no `layout.dart` of a page-less folder, beside it, or
  with no function in it that takes a `Ref` first;
- a missing `input`, or one that is positional, not `required` or untyped;
- a parameter that is neither a segment, a query parameter nor `input`, a missing return type, a
  `Stream`, a `Future` with no type argument;
- an `invalidates` that is not a `const` list literal of names, a name that is neither a typed
  route nor a section handle or has no `data.dart`, and a key of the data it invalidates that the
  action doesn't take;
- helper names that collide.

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
`AppManifest.match(uri)` finds the entry for a _location_ ([From a location to its
data](#from-a-location-to-its-data)).
Each `RouteInfo<M>` has:

| Field               |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `type`              | the typed-route class: `ProductRoute`                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `path`              | the path template, without the mount point: `/products/:id`; a [catch-all](#catch-all-segments) is `/docs/*rest`, or `/files/*path?` when optional (as in `fsp routes`). Case-insensitive paths (`case_sensitive: false`) don't change it                                                                                                                                                                                                                                            |
| `paths`             | the path in each locale its folders spell it in, `{'fr': '/produits/:id'}` (a level with no spelling for a locale keeps its own); empty without [localized paths](#localized-paths). `pathFor(locale)` picks one, falling back to `path`                                                                                                                                                                                                                                             |
| `folder`            | the route's folder relative to the app folder: `(buyer)/products/$id` (empty for the app folder itself)                                                                                                                                                                                                                                                                                                                                                                              |
| `presentation`      | `RoutePresentation.page`; `.redirect` for a `redirect.dart` (`isRedirect`); `.root` for a page on the [root navigator](#the-root-navigator-navigatordart) through `navigator.dart`; `.custom` for a page a [`present.dart`](#presentdart-a-page-of-your-own) builds (it is on the root navigator too, unless a `navigator.dart` beside it says otherwise). Whether a page opens as a dialog or sheet is up to its `transition.dart` or `present.dart` at runtime, so it isn't listed |
| `groups`            | the `(group)` folders above it, outermost first, parentheses included                                                                                                                                                                                                                                                                                                                                                                                                                |
| `layouts`           | the folders of the layouts that wrap it, outermost first (`''` is the app folder's own layout)                                                                                                                                                                                                                                                                                                                                                                                       |
| `segments`, `query` | `RouteParam(name, type)`: `('id', 'int')`, `('page', 'int?')`, `('tags', 'List<String>')`. A catch-all is the last segment, a `List<String>` (or the `List` type it is typed with) with `catchAll: true`                                                                                                                                                                                                                                                                             |
| `tabs`              | the tabs it sits in, outermost first: `RouteTab(layout, index, branch)`, where `branch` is the name `tabs` and `tabOptions` use (`.` for the layout's own page); empty outside tab layouts                                                                                                                                                                                                                                                                                           |
| `dataKeys`          | what its `data.dart` is keyed by; `null` without one                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `meta`              | its `meta.dart`, as declared                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

**`meta.dart`.** Put `const meta = <any const expression>;` next to a `page.dart` (or
`redirect.dart`), and the generator copies it into the manifest _by reference_
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
  anything in it: a review code is yours.
- **Its values can be unique.** `meta_unique: [code, slug]` in the same section makes a
  duplicate an error: it reads the _literal_ named arguments of `meta`'s constructor call
  (`const meta = PageMeta(code: 'B04', slug: 'product-detail')`, a string, number or bool) in
  every route's `meta.dart` and reports a value that two routes share, naming both files
  (`` `code: 'B04'` is also in products/meta.dart ``). An argument that is an expression, or
  that a route leaves out, is skipped (nothing is compared for it), and a listed name no
  `meta.dart` gives a literal is a warning, in case it is a typo. Anything more (a pattern for
  the code, unique across tabs only) is a few lines in a test over `AppRoutes.all` and `metaAs`.
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
{
  "pattern": "/products/:id",
  "route": "ProductRoute",
  "file": "lib/app/(buyer)/products/$id/page.dart",
  "tags": ["data"],
  "params": [
    { "name": "id", "type": "int", "in": "path" },
    { "name": "tab", "type": "String?", "in": "query" }
  ],
  "folder": "(buyer)/products/$id",
  "presentation": "page",
  "groups": ["(buyer)"],
  "layouts": ["(buyer)"],
  "tabs": [],
  "data_keys": ["id"],
  "meta": "lib/app/(buyer)/products/$id/meta.dart",
  "catch_all": null
}
```

`presentation` is `page`, `redirect`, `root` or `custom` (see the table above); `tabs` is `[{"layout":"(tabs)","index":0,"branch":"search"}]`
for a route in a tab; `data_keys` and `meta` are `null` when the route has no `data.dart` or
`meta.dart`. The meta itself is Dart, so JSON only says where it is. `catch_all` is
`{"name":"rest","optional":false}` for a route that ends in a `$$rest` (or `$$$rest`, `"optional":true`)
catch-all, else `null`; the catch-all is also in `params` as a path parameter of its `List` type. A route
with [localized paths](#localized-paths) has one more key after `catch_all`, `"paths":{"fr":"/produits/:id"}`
(the manifest's `paths`); the other routes have none.

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
  tab _and_ the stack of every tab you visited are restored, nested tab layouts included.
- **Layouts.** A plain layout's Navigator gets one too (`layout:(account)/`).
- **Pages.** What a page keeps in a `RestorationMixin` (a `RestorableInt` for a form field or a
  scroll offset) comes back if the page has a `restorationId`. go_router's own pages have
  one; the ones `Transitions.*` build take it from the page key; a `Page` you build in a
  `transition.dart` should pass `restorationId: key.value` too (or its state won't be restored).

The reason layouts need generated pages: go_router keys the page of a `ShellRoute` or
`StatefulShellRoute` by the route object's `hashCode` and uses it as the restoration id, which
changes on every launch, so nothing under it can be found again. The generated router builds
these pages with an id from the layout's folder instead: with a [`transition.dart`](#transitions)
above the layout, its `Page` under a `ValueKey` made of that id (the `Transitions.*` pages take
their restoration id from the key); otherwise `layoutPage(...)`, a Material page (a Cupertino one
inside a `CupertinoApp`) with the id, under the same `ValueKey` (since 0.5.0; it used to use
go_router's key, the route object's hash code, so a router built again by a hot reload or a test
replaced the layout and lost its state).

- **`extra`.** An object passed with `context.go(…, extra: …)` is saved with the location if the
  router has an [`extraCodec`](#restoring-extra-on-the-web) that knows its type (the same one
  the browser's history uses on the web).

Ids come from folder names, so renaming a folder drops what was saved under the old one, once.
`examples/tabs/test/restoration_test.dart` restores the selected tab, a background tab's stack,
a page's `RestorableInt` and a page's `extra` with `tester.restartAndRestore()`. Build the router in a
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
fsp routes --graph      # the route tree as a Mermaid graph (--graph dot: Graphviz)
fsp links               # App Links, Universal Links, assetlinks.json and a sitemap from the routes
fsp links --check       # CI: non-zero exit when those files are stale
fsp watch               # same, whenever the routing changes (keep it next to `flutter run`)
fsp check               # CI: non-zero exit on errors, writes nothing
fsp new 'products/[id]' --name Product --data --action --loading --error --layout --guard --transition
                        # [id] or :id both mean $id, so no shell quoting of $
fsp new '(account)' --layout    # a (group) folder: layout only, no page.dart
fsp new 'kyc/shop/name' --function --name KycShopName
                        # views as functions (`Widget page()`), with a routeName
fsp new 'shop' --not-found      # not_found.dart (not-found.dart with `file_style: kebab`)
```

All commands take `--project <dir>` (default: the nearest folder with a `pubspec.yaml`).
`fsp new` writes `page.dart` (plus the kinds you ask for with flags), skips files that
already exist, and takes its class names from `--name` (default: from the path, e.g.
`ProductsId`). With `--function` it writes [function views](#function-views) instead of classes,
and `--name` becomes the `routeName` (an UpperCamelCase name). A segment that already has a
type elsewhere in the tree keeps it. Pass
`--no-page` to leave `page.dart` out, and `--not-found` to add a `not_found.dart` that takes the
segments of its path as `String`s (see [Not-found views](#not-found-views)). A `(group)` target (like `'(account)'`) gets no
`page.dart` either, since a group has no URL of its own; write one by hand if you want the
group to serve its parent's URL. It then regenerates `lib/app.g.dart` and prints the
result line; if that fails, it lists the files it created. After `fsp new '(account)'
--layout`, the generator warns "folder has no page.dart and no routes below it; skipped"
until you add a route inside the group. That's expected.

`fsp routes` prints what the header of `lib/app.g.dart` lists: each route's URL pattern, its typed
route class, its `page.dart` and its tags (`redirect`, `data`, `action`, `guard`, `layout`, `transition`,
`present`, `root`, and `sibling` for a route with [`nest = false`](#a-sibling-with-a-compound-path)).

```text
/products/:id  ProductRoute   products/$id/page.dart  (data, transition)
```

A route with [localized paths](#localized-paths) lists each spelling under its row (`fr  /produits/:id`).

**`--graph`** (since 0.5.0) prints the route _tree_ instead, to paste into a README, a pull request
or an issue: `fsp routes --graph` (or `--graph mermaid`) writes a Mermaid `flowchart TD`, which
GitHub renders in Markdown, and `--graph dot` a Graphviz `digraph` (`fsp routes --graph dot | dot -Tsvg`).
It draws what `app.g.dart` gives go_router, not the folders:

- **Nodes** are routes: the URL pattern, the route class, each spelling of a
  [localized path](#localized-paths) and the markers (`redirect`, `data`, `action`, `guard`,
  `present`, `root`, `sibling`, as in the tags above). A `redirect.dart` route is dashed.
- **Edges** are nesting: a page is the parent of the routes in the folders below it, and a route with
  [`nest = false`](#a-sibling-with-a-compound-path) hangs from the page above its parent instead.
  A shell's routes hang from the route above the shell.
- **Boxes** are navigators: the root navigator, a [layout](#file-kinds)'s shell (`layout.dart`, with
  `data` for a [section](#section-data) and `guard` for its folder's guard) and each branch of a
  [tab layout](#tab-layouts).

The output has no timestamp and a fixed order, so a graph committed to a doc changes only when the
routes do. `--graph` and `--json` cannot be combined.

```text
flowchart TD
  subgraph rootnav["root navigator"]
    subgraph b0["layout layout.dart"]
      n0["/<br/>HomeRoute"]
      n1["/cart<br/>CartRoute"]
      n2["/checkout<br/>CheckoutRoute<br/>(guard)"]
      ...
```

With `--json` it prints one JSON object per line, for scripts and editors, with each
route's parameters and the [manifest](#route-manifest-and-metadart)'s fields; `file` is relative to
the project root:

```json
{
  "pattern": "/products/:id",
  "route": "ProductRoute",
  "file": "lib/app/products/$id/page.dart",
  "tags": ["data", "transition"],
  "params": [{ "name": "id", "type": "int", "in": "path" }],
  "folder": "products/$id",
  "presentation": "page",
  "groups": [],
  "layouts": [],
  "tabs": [],
  "data_keys": ["id"],
  "meta": null,
  "catch_all": null
}
```

**`--json` diagnostics.** `fsp gen --json` and `fsp check --json` print each diagnostic to
stdout as one JSON object per line, instead of the rendering below, so an editor can turn them
into squiggles. The success and failure lines still go to stderr, and stdout is empty when
there is nothing to report:

```json
{
  "file": "lib/app/shops/$shop/items/$id/page.dart",
  "line": 6,
  "column": 18,
  "severity": "error",
  "message": "can't fill `label`: ..."
}
```

`line` and `column` count from 1 (the column counts characters, not bytes) and are `null` for
a diagnostic that isn't about a place in a file. `severity` is `error` or `warning`.

**Editor support.** Two editor plugins sit on top of the JSON diagnostics. Neither is on a
marketplace yet, so you build them from source. Both use `fsp` from your `PATH`, or `dart run
fespalier` when there is none, and both check again when you save a file under the app folder
(`fespalier: app_dir:` in `pubspec.yaml`, `lib/app` by default).

- **VS Code:** `editors/vscode/` puts the diagnostics in the Problems panel, with a
  `fespalier: generate` command and a status bar item. Build it with `npm install && npm test
&& npx @vscode/vsce package` in that folder and install the `.vsix` (see
  `editors/vscode/README.md`). `fespalier.runner` chooses the runner.
- **IntelliJ IDEA and Android Studio:** `editors/intellij/` (Kotlin) underlines the problems
  in the editor, with their severity, in the files under the app folder, and adds
  _Tools | fespalier: Generate_ and _fespalier: Check_; a notification says when `fsp` could
  not run. Settings | Tools | fespalier chooses the runner (auto, `fsp`, or `dart run
fespalier`) and the path to `fsp`. It works on platform 252 (2025.2) and later; the
  highlighting of route files needs the Dart plugin, which Android Studio includes. Build it
  with JDK 21:

  ```sh
  cd editors/intellij
  ./gradlew build buildPlugin      # tests, then build/distributions/fespalier-intellij-<version>.zip
  ```

  Then _Settings | Plugins | gear icon | Install Plugin from Disk..._ and pick the zip.
  `./gradlew runIde` starts a sandbox IDE with the plugin instead. See
  `editors/intellij/README.md`.

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
  results of files that didn't change, so a save parses only the file you saved; a save that
  leaves everything the generator reads as it was (a colocated widget, say) doesn't resolve or
  render again, and `dart format` (with `format: true`) only runs on generated code it hasn't
  formatted before. It also watches the rest of `lib/` (Dart files and folders only), because the
  enum a segment names is declared there: editing `lib/models/category.dart` regenerates. See
  [Performance](#performance).

Errors point at the parameter or declaration at fault, and `app.g.dart` is left
untouched while there are any. A file that can't be fully parsed gets a warning instead
(the Dart compiler reports the exact error), and the generator works with what it could
read:

```text
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
  The exceptions are a page's (or a layout's, guard's or redirect's) [typed `extra`](#typed-extra)
  and an [enum segment or query parameter](#enum-segments), whose types the typed route has to
  name; it imports those types by name from the file's imports.
- **Segments and query parameters are parsed into a record** (`({int id, int? page})`).
  Records compare by value, so providers are keyed by them directly.
- **Page-less folders** fold into their children's paths (`greet/$name` → `'greet/:name'`).
  `(group)` folders fold away completely, apart from the ShellRoute their layout adds.
- **Static routes come first** among siblings, then dynamic ones, then a
  [catch-all](#catch-all-segments), so go_router's first match is the most specific one.
- **`AppRoutes.mount(at:)`** only changes the root path (and, with `navigatorKey:`, the
  root navigator's key). Typed routes read `AppRoutes.base`, so `.location` stays correct when
  mounted under `/shop`.

### Deep links and a sitemap (`fsp links`)

Since 0.5.0. The URLs your app opens are its routes, so the lists the platforms want of them can be
written from the route tree instead of kept by hand: the `<intent-filter>`s of Android App Links and
`assetlinks.json`, the `apple-app-site-association` file and the entitlement of iOS Universal Links,
and a `sitemap.xml`. Say where the app lives in `pubspec.yaml`:

```yaml
fespalier:
  links:
    domains: [shop.example.com]       # required; the first one is the sitemap's
    scheme: myshop                    # optional custom scheme: myshop://shop.example.com/products/2
    android_package: com.example.shop # with android_sha256: the Android files
    android_sha256: ["AB:CD:...:EF"]  # the signing certificates' fingerprints, 32 hex pairs each
    ios_app_id: ABCDE12345.com.example.shop   # Team ID, a dot, the bundle id: the iOS files
    out: links                        # default: where the files go, relative to the project
```

`fsp links` then writes, below `out` (`links/` unless you say otherwise; commit it, like `app.g.dart`):

```text
links/
  android/intent-filters.xml                  one <intent-filter android:autoVerify="true"> per domain, one for `scheme`
  ios/associated-domains.entitlements         the applinks:<domain> entries
  ios/info-url-types.xml                      CFBundleURLTypes, with `scheme` and `ios_app_id`
  web/.well-known/assetlinks.json             serve it at https://<domain>/.well-known/assetlinks.json
  web/.well-known/apple-app-site-association  serve it at the same place, as application/json, without a redirect
  web/sitemap.xml                             every static route, on the first domain
```

The Android files are written when `android_package` is set (it needs `android_sha256`, and the
reverse), the iOS ones when `ios_app_id` is, and the sitemap always. A key that is missing, a
fingerprint or package that isn't one and the like are errors that name the key (only `fsp links`
checks them: a mistake there never stops `fsp gen`). A file the config no longer asks for is
removed by `fsp links` and reported by `--check`.

**What is listed.** Each route's path, in each spelling of its [localized paths](#localized-paths),
and every route in a folder that doesn't say [`const linkable = false;`](#case-and-trailing-slashes)
(a `route.dart`, inherited down the tree, the nearest one wins). Redirects are opened by the app,
so they are in the Android and iOS lists; a sitemap leaves them out.

| Route                              | Android                                    | iOS (`components`)             | Sitemap                   |
| ---------------------------------- | ------------------------------------------ | ------------------------------ | ------------------------- |
| `/about` (static)                  | `android:path="/about"`                    | `/about`                       | listed                    |
| `/products/:id`                    | `pathPattern="/products/..*"`              | `/products/?*`                 | left out                  |
| `/docs/*rest`                      | `pathPrefix="/docs/"`                      | `/docs/?*`                     | left out                  |
| `/files/*path?`                    | `path="/files"` and `pathPrefix="/files/"` | `/files` and `/files/*`        | left out                  |
| `help/` with `{'fr': 'aide'}`      | one entry per spelling                     | one entry per spelling         | one `<url>` per spelling  |

- **A `$dynamic` segment is a wildcard.** Android's `pathPattern` can't say "one segment", so
  `/products/..*` also lets `/products/2/extra` through; the app's router has the last word and shows
  its not-found view. iOS's `?*` is the same. `linkable = false` removes a route's own entries; it
  can't carve a hole out of the wildcard a dynamic sibling makes (a `$slug` at the root lets every
  one-segment path in).
- **Localized spellings.** Android gets the characters as written, which it compares with the decoded
  path (`/führer`), iOS and the sitemap the percent-encoded form (`/f%C3%BChrer`). The sitemap gives
  each spelling its own `<url>` with `xhtml:link` `hreflang` alternates for every locale (the
  canonical path is `x-default`).
- **iOS case.** A route that is [case-insensitive](#case-and-trailing-slashes) gets
  `"caseSensitive": false` in its component. Android always matches by case.
- **The sitemap lists static routes only.** Dynamic routes and catch-alls have no URL to write down
  without data fespalier doesn't have; a way to list them at runtime is not part of this. Guards
  aren't looked at either: a route behind a guard is listed, so mark it `linkable = false` if a
  crawler shouldn't see it.
- **Mounting.** The paths are the routes' own. An app that mounts its routes under a
  prefix (`AppRoutes.mount(at: '/shop')`) has to put the prefix in front itself.

**Using the files.** `fsp links` never edits `AndroidManifest.xml`, `Runner.entitlements` or
`Info.plist`. Paste `android/intent-filters.xml` into the `<activity>` of
`android/app/src/main/AndroidManifest.xml` that has the `MAIN`/`LAUNCHER` filter (replace what you
pasted last time), add the `applinks:` lines of `ios/associated-domains.entitlements` to
`ios/Runner/Runner.entitlements`, and the entry of `ios/info-url-types.xml` to `Info.plist`. Copy
`links/web/` into your Flutter project's `web/` folder (`flutter build web` ships `.well-known/`
as it ships the rest), or serve it from wherever the domain's server keeps its files. Android only
verifies a domain when `assetlinks.json` is served over HTTPS at `/.well-known/assetlinks.json`
with no redirect.

**Staying current.** The output is a function of the tree and the pubspec (a fixed order, no dates),
so the same input gives the same bytes. `fsp links --check` writes nothing and exits non-zero when
a file is missing, out of date or no longer wanted, and names it; run it in CI next to `fsp check`.
`fsp routes --json` is unchanged.

### Performance

Measured on synthetic apps (`cli/src/bench.rs`: sections of 25 routes with layouts and guards,
a `data.dart` on every fifth route, query parameters on every third page, dynamic segments;
5,000 routes are 7,400 files and a 5.8 MB `app.g.dart`), a release build, 4 cores, warm file
cache. Re-run them with `cd cli && cargo test --release bench -- --ignored --nocapture
--test-threads=1`. Milliseconds, before → after this change (run to run they vary by about
15%; the 500-route cold run is within that):

| Routes | `gen` cold | `watch`: a save, output unchanged | `watch`: a save, output changed | `watch`: a file `fsp` doesn't read |
| -----: | ---------: | --------------------------------: | ------------------------------: | ---------------------------------: |
|    500 |    53 → 56 |                           31 → 28 |                         37 → 22 |                             36 → 7 |
|  2,000 |  284 → 156 |                         121 → 113 |                       132 → 108 |                           107 → 28 |
|  5,000 |  626 → 429 |                         405 → 263 |                       403 → 279 |                           424 → 77 |

With `format: true` (`dart format` of the generated file):

| Routes |      `gen` cold | `watch`: a save, output unchanged | `watch`: a save, output changed | `watch`: a file `fsp` doesn't read |
| -----: | --------------: | --------------------------------: | ------------------------------: | ---------------------------------: |
|    500 | 1.27 s → 1.41 s |                    1.24 s → 29 ms |                 1.24 s → 1.27 s |                      1.25 s → 8 ms |
|  2,000 | 4.96 s → 5.05 s |                   4.84 s → 104 ms |                 5.11 s → 4.93 s |                     4.83 s → 30 ms |
|  5,000 | 13.4 s → 13.4 s |                   12.7 s → 274 ms |                 13.3 s → 14.1 s |                     12.9 s → 77 ms |

"Output unchanged" is a comment added to a page, which changes the file and not what is
generated; "output changed" changes the type of a query parameter. Where the time goes at
5,000 routes, cold: walking the folders and reading the files 82, parsing 208 (now spread
over the cores), resolving 29, emitting 153 (the model 50, `minijinja` 105), writing 6.
Emitting was 277 before: the check that a `/:slug` doesn't hide a page compared every page
with every earlier one, 125 ms of it at 5,000 routes. And `dart format`, when it is on,
dwarfs all of it: 1.4 s at 500 routes, 5.3 s at 2,000, 14 s at 5,000, because the formatter
reads the whole file.

What `watch` does about it:

- **Only the files you changed are parsed** (the parse cache), and the first run parses on all cores.
- **A tree the generator has seen isn't resolved or rendered again.** Resolve and emit depend
  on nothing but the scanned folders and their sources, so a run that scans a tree equal to
  the last one reuses its diagnostics and code. Editing a file under `lib/app/` that isn't
  a route file, or saving without changes, costs a walk of the folders. The one input beside
  the folders is the set of files outside the app folder that were read to find enum
  declarations (`enums.rs`); their contents are compared on every run, so an enum renamed or
  deleted there is never served stale.
- **`dart format` runs only on code it hasn't formatted before**, so a save that doesn't change
  the generated code (a `build` method, most of the time) skips it: the 1.2 to 13 s above
  become the 30 to 270 ms of a run without `format:`. Code that did change is formatted in full, because the
  formatter needs the whole file. If that hurts in a huge app, leave `format:` off in
  `watch` and format in CI.
- Nothing is written when the output is byte-identical to the file on disk (it always was so).

What it doesn't do, and why: per-route caching of resolved results, and re-scanning only the
changed folders. A full resolve is 30 ms at 5,000 routes, a tenth of a save that changes
output, and resolving one route reads the folders above it and shares state with the others
(names claimed, query types settled), so a per-route cache would have to replay those effects
for a saving smaller than its bookkeeping. The walk is 80 ms at 5,000 routes, and reading the
files a small part of it; a cache keyed on modification times would save less than it risks
(an edit in the same timestamp tick, a file replaced by one with the same size and time).

## Run the examples

Start with [`examples/minimal`](examples/minimal): `flutter create` + `fsp init` and three pages
(a class page, a function page and a `$id` page with a query parameter and a `data.dart`), with
a README that goes through each file and a few widget tests. Then:

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
its layout and pages, with a `not_found.dart` at two levels (which takes the team's id), a `reports` section keyed by a
query parameter, enum segments, query parameters and catch-alls (`shop/$category`, `browse/$$categories`), and
`AppRoutes.dataAt` / `match` and the prefetch handle in `test/data_at_test.dart`.

`examples/features` also has `orders/$id/refund/confirm`, a route that is a sibling of the `refund`
page instead of a child of it (`nest = false`; `refund/receipt` next to it nests), with a guard on
`refund/` that still guards it and widget tests for the stack a deep link builds.

`examples/features` also has writes: `orders/$id/refund/action.dart` is a refund form (the page
is a `HookConsumerWidget` on `RefundRoute.useAction`: a pending state, the error of a declined
refund, and the quote beside it, `data.dart`, loads again after a success), and
`teams/$teamId/action.dart` adds a member to the section, whose data reloads for the layout and the
page. `test/action_test.dart` holds a refund pending on a `Completer`, so nothing waits for time.

`examples/features` also has localized paths: `help/` answers `/aide` and `/hilfe` too, with a dynamic
child, a nested child that is localized itself, and a `not_found.dart` that covers every spelling; `guide/`, with
spellings beyond ASCII (`/führer`, `/руководство`); and `shop/`, a page-less folder spelled `boutique` and
`laden` with an enum segment below it.

`examples/tabs` is a bottom navigation bar built as a tab layout: four tabs (one with nested
pages, and a Library tab that is a tab layout of its own, with two inner tabs), a
counter that survives switching tabs, `tabOptions`, a cross-fading `container`, a Search tab that also answers `/recherche` (`route.dart` with `paths`), a full-screen route
outside them (`/settings`), one that stays under `/profile` but renders on the root navigator
(`/profile/edit`, `navigator.dart`), and a Cupertino `transition.dart` that also moves the tab layout
itself aside when one of those opens over it.

`examples/features` also has a guard in a page-less `(members)` group (with a login page that
returns to where you were), a second guard below it that runs after the first, two
`redirect.dart` routes (`/old-shops/:shop`, `/old-search`), and `/photos`, with a dialog
route (`/photos/:id`), a bottom sheet (`/photos/sort`), a full-screen dialog
(`/photos/upload`) and an app-owned sheet with a URL (`/photos/share`, `present.dart`, with a page
on top of it at `/photos/share/terms`) opening over it. Some of its routes have a `meta.dart` (`PageMeta`), which
its root layout reads through the route manifest to set the page title, and its tests join a
review-code check on `AppRoutes.all`.

`examples/tabs` also keeps its manifest in a library of its own (`output_manifest:
lib/app.routes.g.dart`, with `Review` metas that `lib/main.dart` never imports), and its tests
restore the selected tab, a background tab's stack and a page's state after a simulated
restart.

## Development

```text
cli/                 the generator (Rust): scan → resolve/check → emit
cli/templates/       minijinja templates for app.g.dart and `fsp new`
editors/vscode/      the VS Code extension (TypeScript): fsp diagnostics in the Problems panel
editors/intellij/    the IntelliJ / Android Studio plugin (Kotlin): fsp diagnostics in the editor
scripts/             packaging.py renders the Homebrew formula and Scoop manifest for a release;
                     pin_checksums.py writes the release's checksums into the Dart package
packages/fespalier/  the runtime app.g.dart imports (DataView, segment parsing, TypedLocation),
                     testing.dart, and bin/fespalier.dart, the `dart run fespalier` launcher for `fsp`
examples/minimal/    the smallest app: `flutter create` + `fsp init` + three pages, with widget tests
examples/shop/       end-to-end example; its lib/app.g.dart is committed
examples/features/   every binding rule, section data and nested not_found.dart, with widget tests
examples/tabs/       a tab layout (StatefulShellRoute), with widget tests
skills/              agent skills: how to write lib/app/ and read fsp's errors (skills/README.md);
                     scripts/skills/ checks them against the code
```

```sh
just ci          # everything CI runs on the code, locally (needs Flutter, Node, just, cargo-deny)
just --list      # the individual steps: fmt, lint, test, deny, examples, flutter, packaging, skills
```

[AGENTS.md](AGENTS.md) is the contributor and agent guide: the layout, the gate commands,
how to run each suite, and the conventions (Conventional Commit PR titles, squash merges,
SHA-pinned actions, regenerating the examples).

CI (`.github/workflows/ci.yml`) runs `just ci`'s steps: `cargo fmt --check`, clippy and the
tests, `cargo deny check`, `fsp check` on the examples, and `dart format`, `flutter analyze`
and `flutter test` on the package and every example. It also scaffolds every file kind
with `fsp new` and `fsp init`, checks the result with `flutter analyze` and `dart format`,
runs `dart run fespalier` against a
freshly built `fsp`, compiles and tests the VS Code extension, tests the Homebrew and Scoop
rendering, checksum pinning and release staging (`python3 scripts/test_packaging.py`,
`python3 scripts/test_pin_checksums.py`, `python3 scripts/test_verify_staged.py`,
`python3 scripts/test_release_assets.py`),
checks that the agent skills in `skills/` cover every README section, file kind, config key and
`fsp` command (`node scripts/skills/verify-coverage.mjs`; see [skills/README.md](skills/README.md)),
and checks that the version agrees everywhere it is spelled out
(`cli/tests/versions.rs`: `cli/Cargo.toml`, `packages/fespalier/pubspec.yaml`,
`.release-please-manifest.json`, the `ref:` that `fsp init` prints, and the READMEs' and the
skills' `ref:`, `--tag` and `FSP_VERSION`; that each of them is annotated for release-please and listed in
`release-please-config.json`; that the release workflows' own version readers,
`scripts/read-version.sh`, still find each one; and that `release_checksums.dart` pins nothing
or a version no newer than the package's). You do not bump any of them: release-please does
(see [Releasing](#releasing)). After changing the emitter or a
template, regenerate with `cargo run -- gen --project ../examples/<name>`. A test fails if
a committed `app.g.dart` is stale.

### Releasing

Maintainers only. Releases are cut with release-please, the convention of every repository in
the vaam-apps organization (its guide, `docs/releasing.md` in `vaam-apps/.github`, lists the
ways this has failed silently and is worth reading before changing anything here). Nobody
bumps a version by hand, edits `.release-please-manifest.json`, or runs a workflow to publish.

**The flow.**

1. **Land conventional commits.** The repository squash-merges and the pull request _title_
   becomes the commit subject, which is all release-please reads: `feat:`, `fix:`, `docs:`,
   `ci:` and the other conventional types (`pr-title` refuses anything else; a subject it cannot
   read is ignored, and no release PR appears). `feat` and `fix` decide the bump (before 1.0 a
   breaking change bumps the minor); every other visible type is a patch. To force a version,
   put a `Release-As: X.Y.Z` footer in a commit.
2. **The release PR.** Every push to `main` updates one standing pull request from the branch
   `release-please--branches--main`. It bumps the version in `cli/Cargo.toml`,
   `packages/fespalier/pubspec.yaml`, the `ref:` that `fsp init` prints, both READMEs'
   install snippets and `.release-please-manifest.json` (every spelled-out version carries a
   release-please annotation and is listed in `release-please-config.json`; the trailing comment
   is why every reader of those files must tolerate one, see `scripts/read-version.sh`), and it
   writes the root `CHANGELOG.md` above the hand-written history. The `release-please` workflow
   refreshes `cli/Cargo.lock` on the branch, because the build is `--locked`.
3. **Pins, on the PR.** The `Release pins` workflow builds `fsp` for the five targets on the PR
   branch, stages the archives, and commits their SHA-256s to the branch as
   `chore: pin fsp X.Y.Z checksums` (`packages/fespalier/lib/src/release_checksums.dart`,
   `scripts/pin_checksums.py`). release-please force-pushes the branch whenever `main` moves,
   which removes that commit; the workflow then runs again on the new head. It recognises its own
   commit and does not loop. The `fsp` build reads only `cli/`, never `release_checksums.dart`,
   so the pin commit does not change the binaries. Wait for the `Release pins gate` check before
   merging (make it required in the `main` ruleset; other pull requests pass it by skipping).
   The archives wait in a _staging_ draft release named `fsp-staging` (visible to maintainers,
   replaced by every build, deleted after the release), not in workflow artifacts, which expire.
4. **Merge the release PR.** release-please (as the org's GitHub App, so that the tag raises a
   workflow event) creates the tag `vX.Y.Z` at the merge commit and a _draft_ GitHub Release.
   The `Release` workflow, triggered by the tag, then
   - checks that the tag equals the Cargo, pubspec, manifest and lockfile versions;
   - fetches the staged archives and **refuses anything that is not the pinned build**
     (`scripts/verify-staged.sh`): they must be this version, built from the `cli/` tree that is
     tagged, and every archive's SHA-256 must equal the pin in the tagged tree. It never
     rebuilds: builds are not reproducible, so a rebuild could not match the pins;
   - regenerates the `.sha256` files and renders `fsp.rb` (Homebrew) and `fsp.json` (Scoop) from
     the verified archives (`scripts/packaging.py`), attaches all of it to the draft Release,
     publishes it (only now is it public and the latest release), and deletes the staging draft;
   - pushes `fsp.rb` and `fsp.json` to `vaam-apps/homebrew-tap` and `vaam-apps/scoop-bucket`.
     A git dependency on the new tag therefore carries the pins, and `dart run fespalier` refuses
     any download that does not match them (a checksum served next to the binary can be replaced
     together with it; one in the package cannot).

Between releases, `main` still carries the last release's pins, and on an open release PR, before
its pin commit, the pubspec is ahead of them; the launcher then falls back to the release's
`.sha256` with a warning, as for any development build. `cli/tests/versions.rs` accepts pins for
the current or an older version, never a newer one.

**If something fails.** A failed `Release` run leaves the release a draft (nobody sees it, and
`latest` does not move): fix the cause and re-run the failed jobs. The usual causes are a
`cli/` change that reached `main` after the last build (the release PR was merged before its
head was rebuilt: make `Release pins gate` required and the branch up to date before merging),
or staged binaries that were replaced or deleted. If the merged commit cannot be made to match,
delete the draft and the tag and fix forward with the next release. A manual run of `Release`
(_Run workflow_) only builds the five targets and renders the Homebrew and Scoop files as a
smoke test; it publishes nothing.

**Repository settings** (not enforceable from a workflow): squash merging only, with the
squash commit title set to the pull request title and the message to the commit messages;
merge commits and rebase merges off. The release-please GitHub App must be installed on this
repository, and on `homebrew-tap` and `scoop-bucket` for the last job.

**By hand, per release** (the editor plugins are versioned on their own and not part of the
release PR):

- **JetBrains Marketplace (IntelliJ plugin).** Build the plugin from the tag with
  `cd editors/intellij && ./gradlew buildPlugin` (JDK 21) and upload
  `build/distributions/fespalier-intellij-<version>.zip` on the plugin's page in the
  JetBrains Marketplace, or run `PUBLISH_TOKEN=<token> ./gradlew publishPlugin`. Bump
  `version` in `editors/intellij/build.gradle.kts` first. The first upload needs a vendor
  account and a manual review; later ones can use a permanent token from the Marketplace's
  _My Tokens_ page.
- **VS Code extension.** Not published to a marketplace: build the `.vsix` from source (see
  `editors/vscode/README.md`). Bump `version` in `editors/vscode/package.json` first if you
  distribute a build.

**One-time setup** for the package managers: create the repositories `vaam-apps/homebrew-tap`
(with a `Formula/` folder; the `homebrew-` prefix is what lets `brew install
vaam-apps/tap/fsp` find it) and `vaam-apps/scoop-bucket` (with a `bucket/` folder; the
manifest's `checkver` and `autoupdate` let Scoop's own tooling keep it current too).

### Testing

`package:fespalier/testing.dart` has two helpers for widget tests. Boot the app at a
location with `pumpRouter`, and read where it is with `currentLocation` (it follows `go`, `pop` and
`push`: after a push it is the pushed location, the top of the stack):

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

`pumpRouter(tester, router, {overrides, container, settle, retry})` wraps the router in a
`ProviderScope` and Flutter's `MaterialApp.router`, and returns the `ProviderContainer`
(for `container.read(...)`). `settle` (on by default) pumps until nothing is scheduled: turn
it off to look at a loading view, then `pump` the time you want. Pass your own `container`
instead of `overrides` to share one with code outside the widget tree; it's yours to
dispose. `retry` is the container's Riverpod retry policy, and it defaults to **no retries**,
unlike a real app, whose generated providers keep Riverpod's automatic retry unless
`data_retry: none` says otherwise: a failing `data.dart` shows its `error.dart` at once and
leaves no timer behind. To test what the app's policy does, pass
`retry: ProviderContainer.defaultRetry` (or your own function). A policy that keeps retrying
leaves a timer pending when the test ends, so dispose the returned container first. Make a new
router per test, since a router remembers where it went. `pumpRouter` disposes the router when
the test ends (since 0.5.0), so `LeakTesting` finds nothing left behind: don't dispose it
yourself with an `addTearDown` registered before the call (those run after `pumpRouter`'s, and a
second `dispose` throws), and don't share one between tests. The generated `AppRoutes` remembers the last
`router()` or `mount()` (its `base` and `rootNavigatorKey`), and a call without a `navigatorKey`
makes a fresh one (since 0.5.0), so a test that mounts under a prefix restores the defaults with
`addTearDown(AppRoutes.mount)`, and no test depends on the order they run in. Return
synchronously from a guard when you can (see [Guards](#guards)): any `Future`, even
`Future.value(...)`, costs a frame, so a test sees a blank first frame before the page, where a
synchronous guard shows the page at once. If a widget
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

## Design notes

**Why `watch` and `read` are static.** `ProductRoute(id: 42).watch(ref)` would be nicer than
`ProductRoute.watch(ref, id: 42)`, and it can't be had for what it costs. An instance member has to
say what it returns, `AsyncValue<Product>`, so the generated file would have to _name_ `Product`,
and it doesn't import what your `data.dart` imports (it can't tell which of its imports a name
comes from, and it may be a private, aliased or record type). The other ways out don't work: a
`late final watch = (ref) => ...` field, whose type Dart would infer from the provider, is refused
in a class with a `const` constructor, and typed routes are `const` (`const SearchRoute(q: 'ap')`);
an `extension type` or a getter still has to be typed; and returning `AsyncValue<Object?>` would
lose the very type that is the point. A static function value takes its type from the provider
by inference, which is why the helpers that return your data are static, and the ones that
don't (`prefetch`, `refresh`, `go`, `location`) are instance methods. If Dart macros, or naming a
type through the import machinery that `extra` already uses, become an option, this can be
reopened; today the trade is a `const` route and a type that is never `dynamic`.

**Why an action's `submit` is static, and its input is typed.** `RefundRoute(id: 1).submit(ref,
input: form)` has the problem `ProductRoute(id: 42).watch(ref)` has: an instance member has to say
what it returns, so the generated file would have to name `Refund`. A static function value takes
its result type from the provider by inference, so it is never `dynamic`. The `input` is the one
type that has to be written out (a function value's parameters can't be inferred), and that one
`fespalier` can name: it reads it from `action.dart` the way it reads the type of an `extra`, which
is how the file's own imports reach `app.g.dart`. A write is also kept apart from the read it
changes on purpose: it has its own provider, with its own state, instead of being a mode of
`data.dart`'s, so a failed write can never put `error.dart` where the form was.

**Why a localized path is one route with an alternation.** `products/` answering `/produits` could be
done three ways in go_router, and only one keeps the URL and the route one thing.

1. _A redirect from each spelling to the canonical path._ It changes the URL the user came for
   (`/produits/2` turns into `/products/2` in the address bar and in shared links), which is the
   opposite of a localized path, and every nested route would need its own redirect.
2. _A sibling `GoRoute` per spelling sharing the builder._ The URL stays, but the subtree is copied
   per spelling (nested routes, layouts, guards), the copies have different page keys (navigating
   from one spelling to another rebuilds the page), restoration ids and a tab's branch would see
   several routes, and the order and duplicate checks multiply.
3. _One `GoRoute`, the segment a path parameter with its own pattern_, `:_l0(products|produits)`.
   go_router matches a route with a regular expression made from its `path`, where `:name(pattern)`
   is a parameter with a pattern of its own (`path_utils.dart`, `patternToRegExp`, the same in go_router
   17.5 and 18.0; the catch-all's `:rest(.+)` is one). A deep link, `go`, a redirect and the tab
   stack all see one route, and its subtree is written once. The costs are small and all handled:
   the parameter shows up in `pathParameters` and `fullPath` (fespalier's readers skip it and
   `routeTemplate` turns it back into the canonical path), a spelling is escaped for the regular
   expression, and go_router's rule that a tab opens on a route without parameters needs an
   `initialLocation`, which `fsp gen` writes.

And the typed side takes the locale as an argument (`locationFor(locale)`, `go(context, locale:)`) rather
than from a global, so that a route stays a value: see [Localized paths](#localized-paths).

## Status

This is an early version.

- **Generator:** 532 tests (491 unit, 30 CLI integration, 11 version checks) cover parsing, every binding rule and contract error, query
  parameters, `(group)` folders and route order, tab layouts, navigators and shells, transitions, all three data
  forms, section data, nested `not_found.dart`, the typed helpers, guards and redirects, `extra` for pages, layouts and guards and `extra_codec.dart`,
  scaffolding, the route manifest, meta.dart (and `meta_unique`) and restoration ids, `match` / `dataAt`, typed catch-alls, enum segments, per-folder case, localized paths (spellings, non-ASCII, collisions, and `route.dart` `paths` edits in the incremental test), routes that leave the page above (`nest = false`), that the committed outputs are up to date, and that `watch`'s incremental runs equal a from-scratch `gen` after random edits (enum files outside the app folder included). Clippy is clean.
- **Runtime + examples:** `flutter analyze` is clean on Flutter 3.47 (go_router 17 and 18,
  hooks_riverpod 3, flutter_hooks 0.21). 453 Flutter tests (the package 196, `shop` 24, `features` 190, `tabs` 35, `minimal` 8); the example tests drive the generated router through every
  file kind.
- **Types are compared by spelling, not resolved.** The generator reads a syntax tree,
  not the Dart analyzer, so `Product` and a `typedef` of it count as different types. The
  Dart compiler still catches real mismatches in the generated code. (An enum is the one type
  it does look up: it reads the declaration, and compares enums by it.)

Things to know:

- Pages render below their `layout.dart`, so a layout's `Scaffold` is not their nearest
  `Material` during page transitions. Wrap `ListTile`-heavy pages in
  `Material(type: MaterialType.transparency, …)`, as `products/page.dart` does.
- In a route file, any optional nullable parameter of a primitive type (or of an enum) becomes a
  query parameter, including one you meant as widget configuration (`String? title`). Keep such
  parameters on inner widgets instead of the file's exported one.
- go_router builds the whole matched stack, so `/products/abc` also loads `/products`
  underneath the not-found view.

## License

MIT. See [LICENSE](LICENSE).
