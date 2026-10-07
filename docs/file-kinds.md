# File kinds

## At a glance

```text
lib/main.dart            Future<void> main() => AppMain.run();           (the whole main(), since 0.8.1)
lib/app/
  app.dart               App({required GoRouter router})              the MaterialApp.router around the router (root only, optional)
  startup.dart           Future<List<Override>> startup()             before the app: overrides, observers, a zone (root only, optional)
  splash.dart            Splash({Object? error, VoidCallback? retry})   while startup() runs, and when it fails (root only, optional)
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

Each view file exports one widget class, of any kind (`StatelessWidget`, `ConsumerWidget`,
`HookConsumerWidget` and so on), or a [top-level function](#function-views) that returns a widget.
Function files export one top-level function.

Other public classes may sit in the file as long as exactly one of them extends a `…Widget` class (a
`class Helper {}` beside a `StatelessWidget` is fine). When `fsp` can't tell which is the view it says
"expected one public widget class" and lists them. Make helpers private (`_Name`) rather than lean on
that.

| File               | Exports                                                                                                                                                                                                                                                                                                                                                                                               | Its constructor / signature can ask for                                                                                                                                           |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `page.dart`        | a widget                                                                                                                                                                                                                                                                                                                                                                                              | segments; query; what `data.dart` yields; the navigation [`extra`](navigation.md#typed-extra)                                                                                     |
| `data.dart`        | `data(Ref ref, {…})` returning `Future<T>`, `Stream<T>` or `T` — **or** `ProviderListenable<AsyncValue<T>> data({…})` selecting a provider you have — **or** `final data = <Provider>(…)`. Beside a `page.dart` it feeds the page; in a page-less folder with a `layout.dart`, the whole [section](data.md#section-data)                                                                              | segments, query (named)                                                                                                                                                           |
| `action.dart`      | `action(Ref ref, {…, required Input input})` (any number of functions of that shape) returning `Future<T>`, `FutureOr<T>` or `T`, and optionally `const invalidates = [...]`. Beside a `page.dart` it is that route's [write](actions.md#actiondart-typed-writes); in a page-less folder with a `layout.dart`, the [section's](actions.md#actiondart-typed-writes)                                    | segments, query (named), and the one `input`                                                                                                                                      |
| `loading.dart`     | a widget, inherited by subfolders                                                                                                                                                                                                                                                                                                                                                                     | segments; query                                                                                                                                                                   |
| `error.dart`       | a widget, inherited by subfolders                                                                                                                                                                                                                                                                                                                                                                     | segments; query; `error`, `stackTrace`, `retry`                                                                                                                                   |
| `layout.dart`      | a widget; wraps this folder and below (ShellRoute), or holds its subfolders as tabs. A tab layout can also export a [`container`](layouts.md#tab-layouts) function                                                                                                                                                                                                                                    | `child` or `navigationShell`; segments at or above it; query; the [section data](data.md#section-data) it wraps or is inside; the navigation [`extra`](navigation.md#typed-extra) |
| `guard.dart`       | `GuardResult guard(Ref ref, {…})`; `GuardResult` is `FutureOr<String?>`: a location to redirect to, or `null` to let the navigation through. Guards every route at and below its folder, and runs again when what it `ref.watch`es changes (since 0.5.0; `ProviderContainer c` first is the older form, read once)                                                                                    | `uri`; segments at or above its folder; query (named); `extra`                                                                                                                    |
| `redirect.dart`    | `String redirect({…})` in place of `page.dart`: a route that only redirects; may take `Ref ref` first (since 0.5.0), or `ProviderContainer c`                                                                                                                                                                                                                                                         | `uri`; segments; query (named); `extra`                                                                                                                                           |
| `observe.dart`     | `void onEnter(Ref ref, {…})`, `onLeave` and `onFocus` (any of them): run for every page at and below its folder when it is entered, left and focused (since 0.8.1). See [Route lifecycle](observability.md#route-lifecycle-observedart)                                                                                                                                                               | `Ref ref` first; segments at or above its folder; query (named); `uri`; `TypedLocation route`                                                                                     |
| `transition.dart`  | `Page<…> transition(…)`; applies to this folder and below, layouts' shells included                                                                                                                                                                                                                                                                                                                   | `key`, `child`, `state`, `shell` (a `bool`)                                                                                                                                       |
| `present.dart`     | `Page<…> present(…)`: the app builds this route's own page (a sheet, say), on the [root navigator](navigation.md#presentdart-a-page-of-your-own); this folder only                                                                                                                                                                                                                                    | `key`, `child`, `state`                                                                                                                                                           |
| `navigator.dart`   | `const navigator = RouteNavigator.root;`: this folder and below [render on the root navigator](navigation.md#the-root-navigator-navigatordart)                                                                                                                                                                                                                                                        | nothing: it is data                                                                                                                                                               |
| `not_found.dart`   | a widget, optional, in any folder ([nearest wins](routing.md#not-found-views); without one at the root, a plain "Nothing at /path" view); unknown paths and unparsable segments                                                                                                                                                                                                                       | `uri`                                                                                                                                                                             |
| `meta.dart`        | `const meta = <any const expression>;`, beside a `page.dart` or `redirect.dart`: that route's own facts, passed [untouched into the manifest](routing.md#route-manifest-and-metadart)                                                                                                                                                                                                                 | nothing: it is data                                                                                                                                                               |
| `extra_codec.dart` | at the root of the app folder only: a top-level `extraCodec`, the `Codec<Object?, Object?>` the router saves an [`extra`](navigation.md#restoring-extra-on-the-web) with                                                                                                                                                                                                                              | nothing: it is data                                                                                                                                                               |
| `app.dart`         | at the root of the app folder only (since 0.8.1): a widget (any kind) that gets the `router` and builds the `MaterialApp.router` around it; optionally `GoRouter router()` too. [`AppMain.app`](app-startup.md)                                                                                                                                                                                       | `router` (a `GoRouter`); other parameters must be optional                                                                                                                        |
| `startup.dart`     | at the root of the app folder only (since 0.8.1): `startup()` (before the app; may return the `Override`s), `zone()`, `providerObservers`, `routerObservers`, `retry()`; at least one                                                                                                                                                                                                                 | nothing: `startup()` takes no parameters                                                                                                                                          |
| `splash.dart`      | at the root of the app folder only (since 0.8.1): a widget shown while an async `startup()` runs, and when it fails                                                                                                                                                                                                                                                                                   | `error`, `stackTrace`, `retry` (each nullable: null while `startup()` runs)                                                                                                       |
| `route.dart`       | constants, in any folder: `caseSensitive`, `paths`, `nest`, `linkable`, `remount`, `deferred`, `freshness` (see below). Read from the source, never imported                                                                                                                                                                                                                                          | nothing: it is data                                                                                                                                                               |
| `nav.dart`         | in any folder (since 0.8.1): `const nav = Nav(label: 'Products', order: 1);` — how the folder shows in the generated [menus and breadcrumbs](layouts.md#menus-and-breadcrumbs-navdart) (`AppMenu`) — and optionally `String label(BuildContext context, {…})`, the label shown, localized. Read from the source (its `order` and the segments `label()` asks for); a folder with no page is a heading | nothing: it is data; `label()` takes a `BuildContext` and the segments of its folder and above (named, `required`)                                                                |

**What `route.dart` can hold.** Each constant is optional, and the file is read from the source, never imported:

- `const caseSensitive = <true or false>;`: whether paths match by case in this folder and below, [the nearest one winning](routing.md#case-and-trailing-slashes) over the pubspec's `case_sensitive`.
- `const paths = {'fr': 'produits'};` in a static folder: [its other spellings per locale](routing.md#localized-paths).
- `const nest = false;` beside a `page.dart` or `redirect.dart`: [its route is a sibling of the page above, not a child](routing.md#a-sibling-with-a-compound-path).
- `const linkable = false;` (since 0.5.0): [`fsp links`](cli.md#deep-links-and-a-sitemap-fsp-links) leaves this folder's routes and those below it out, [the nearest one winning](routing.md#case-and-trailing-slashes).
- `const remount = Remount.onSegments;` (since 0.6.0): [when the pages in this folder and below get a fresh state because their URL changed](navigation.md#remounting-a-page-remount), the nearest one winning over the pubspec's `remount`.
- `const deferred = true;` (since 0.7.0): [the pages in this folder and below load their code on demand](navigation.md#deferred-routes-a-pages-code-on-demand), the nearest one winning over the pubspec's `deferred`.
- `const freshness = Freshness(staleTime: Duration(minutes: 5));` (since 0.8.1): [the default for when the data.dart functions in this folder and below load again](data.md#freshness-staletime-resume-and-reconnect), the nearest one winning, a data.dart's own over all.

Since 0.8.1 an `action.dart` may also hold the companions of an action: its [`form()`, `validate()`](actions.md#forms-form-and-validate) and [`optimistic()`](actions.md#optimistic-updates-optimistic). They are functions in that file, not a file kind.

## Function views

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

That is one route per file, however many routes build the same screen, and the screen can stay where it
is (`lib/screens/…`) instead of moving into `lib/app/`. The function's parameters are filled exactly
like a constructor's ([below](#how-parameters-are-filled)): segments and query parameters by name,
`data` by name or by type, `child` or a shell for a `layout()`, `error`, `stackTrace` and `retry` for
an `error()`, `uri` for a `notFound()`. Named and positional parameters both work, and a binding error
points at the parameter.

- **Names.** `page()`, `loading()`, `error()`, `layout()` and `notFound()` (`not_found()`
  too). Other functions in the file are helpers and are ignored.
- **One form per file.** A file with a public widget class _and_ the function is an error that names
  both. To use the function, keep the widget in another file (or make it private) and build it from the
  function.
- **No hooks, no `ref`.** A function view is a plain function: it has no `BuildContext` and no
  `WidgetRef` (asking for one is an error that says so). Hooks and `ref` belong in the widget it
  returns.
- **The route class name.** A class names its route after itself (`ProductPage` → `ProductRoute`). A
  `page()` takes the folder path instead, ignoring `(group)` folders and joining the segments in
  PascalCase: `(kyc)/shop/name/page.dart` is `ShopNameRoute`, `orders/$orderId/cancel/page.dart` is
  `OrdersOrderIdCancelRoute` (the root is `RootRoute`). To pick another, put a string literal in
  `page.dart`:

  ```dart
  const routeName = 'KycShopName'; // KycShopNameRoute
  Widget page() => const LegalNameScreen(audience: KycAudience.shop);
  ```

  It must be an UpperCamelCase name (the route class is `<routeName>Route`), and it also renames a
  class-form page's route. The [route manifest](routing.md#route-manifest-and-metadart) lists the
  route under this name, and `meta.dart` works beside a function page. Two routes with the same name
  are an error that suggests `routeName`.

- **`export` isn't followed.** `page.dart` has to hold the function itself, so it stays the
  source of truth for the route.

`fsp new 'shop/name' --function` scaffolds the function form (`--name KycShopName` writes the
`routeName`). `examples/features` has two routes, `(plans)/free` and `(plans)/pro`, serving one
screen with different constants.

## File names

The one file kind with two words is `not_found.dart`. It is also read in kebab-case, `not-found.dart`,
whatever the configuration says, so a project that names every Dart file in kebab-case can keep to
that, and a tree that mixes the two still works. Both in one folder is an error with a code frame for
each file. Diagnostics, `fsp routes` and the header of `app.g.dart` name a file as it is spelled on
disk.

`file_style: snake | kebab` (default `snake`) only picks what `fsp init` and `fsp new` write. The
single-word kinds (`page.dart`, `layout.dart`, …) have one spelling.

## How parameters are filled

The generator reads each constructor (named or positional, `this.x` or typed) and fills every
parameter, trying these rules in order:

1. **By name.** A parameter named like a `$segment` in the path gets that segment. `data`, `child`,
   `navigationShell` (or `shell`), `error`, `stackTrace`, `retry`, `uri` and `extra` (in a page, a
   layout, a guard or a redirect) get what their name says, in the files where they make sense.
2. **Query.** An _optional_ parameter that is nullable or a `List` of
   `String`/`int`/`double`/`bool` (or of an [enum](routing.md#enum-segments)) is a query parameter:
   `int? page` gets `?page=2`, and `List<String> tags = const []` gets every `?tags=`.
3. **By type.** Otherwise, a page's parameter whose type is what `data.dart` yields gets the data, so
   `required this.product` with `final Product product;` works. (A page or layout below a
   [section](data.md#section-data) can take the section's data the same way.) An error view's `Object`
   gets the error, `StackTrace` the stack trace and `VoidCallback` the retry. A layout's `Widget` gets
   the child, its `StatefulNavigationShell` gets the tab shell, and not-found's `Uri` gets the URI.
4. **Otherwise**, a required parameter is a generator error pointing at it. An optional one is left to
   its default.

These names are reserved, so segments can't use them. Parameters bound by name are type-checked: `uri`
must be a `Uri`, `child` a `Widget`, `error` an `Object`, `stackTrace` a `StackTrace`, `retry` a
`VoidCallback`, `navigationShell` a `StatefulNavigationShell`, and a transition's `key` and `state` a
`LocalKey` and a `GoRouterState`. Declaring one as anything else is an error at that parameter
(`Object` and `dynamic` always fit).
