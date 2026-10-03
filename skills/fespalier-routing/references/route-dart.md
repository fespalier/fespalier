# `route.dart`: case, trailing slashes, localized paths, `nest`, `linkable`, `remount` and `deferred`

As of v0.4.0 (`linkable` since 0.5.0, `remount` since 0.6.0, `deferred` since 0.7.0). A `route.dart`
holds up to six declarations, and `fsp` reads them **from the source**; it never imports or runs the file, so
each must be a literal:

```dart
const caseSensitive = false;                 // this folder and below
const paths = {'fr': 'produits', 'de': 'produkte'};   // this folder's own segment
const nest = false;                          // this folder's route only (0.4.0)
const linkable = false;                      // this folder and below, for `fsp links` (0.5.0)
const remount = Remount.onSegments;          // this folder and below: when a page starts again (0.6.0)
const deferred = true;                       // this folder and below: pages load their code on demand (0.7.0)
```

A `route.dart` adds and removes no route, and may hold any one of them alone.
`caseSensitive`, `paths`, `linkable`, `remount` and `deferred` need no page beside it; `nest` does. One
with none of the six is an error (since 0.7.0 its text names all six; on 0.6.0 it names five, without
`deferred`, on 0.5.0 four and on 0.4.0 the first two):
``expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;` or `const deferred = true;` ``.

## Trailing slashes

Nothing to configure: go_router drops a trailing slash before it matches, so
`/products/` and `/products/?page=2` reach `/products` (checked against
go_router 17.5 and 18). Typed locations never end in one.

## Case

Paths are **case-sensitive** by default, like go_router: `/Products` is not
`/products`. Two ways to change that:

```yaml
# pubspec.yaml
fespalier:
  case_sensitive: false
```

```dart
// lib/app/files/route.dart
// /files/README.md is not /files/readme.md, whatever the pubspec says.
const caseSensitive = true;
```

- `case_sensitive: false` emits `caseSensitive: false` on every `GoRoute`:
  static parts match in any case (`/PRODUCTS/Guide` finds `products/guide`),
  while the parts you **take out** of the URL (a `$segment`, a catch-all) keep the
  case they had.
- A `route.dart` overrides it for **its folder and everything below**, the
  **nearest one winning**, over the parent's and over the pubspec. It works both
  ways (`false` in one folder of an exact app, `true` in one of a
  case-insensitive one), is inherited by `(group)` folders and folders without a
  page, and may sit at the root, where it replaces the pubspec's value for the
  whole app.
- go_router has one flag per route, and a route's folders are the whole path down
  to its page, so a page-less folder above one that has a page is part of that
  route: the flag is the one in effect **at the page's folder**, for the whole
  path.
- **The requested case is kept.** go_router matches a case-insensitive route in
  any case and leaves the location as it was asked for: navigating to
  `/Products/2` leaves `GoRouterState.uri` and the router's own location as
  `/Products/2`. Only `state.matchedLocation` is spelled by the route. A typed
  route has no requested case: `ProductRoute(id: 2).location` always writes the
  folders' spelling, and if you want the canonical spelling in the address bar
  you navigate to it yourself.
- Enum segments follow the route's case setting too (`/shop/SHOES`).
- The nearest-`not_found.dart` lookup compares each folder by that folder's own
  setting, and the mount point (`AppRoutes.mount(at: '/Shop')`) by the root's.

## Localized paths

One folder can answer several URL spellings, one per locale, while the typed
route, the page and its data stay **single**.

```dart
// lib/app/products/route.dart
// /products also answers /produits (fr) and /produkte (de)
const paths = {'fr': 'produits', 'de': 'produkte'};
```

```dart
// lib/app/products/page.dart
import 'package:flutter/material.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('products');
}
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Text('product $id');
}
```

```text
/products/2    /produits/2    /produkte/2      -> the same ProductPage(id: 2)
/products      /produits      /produkte        -> the same ProductsPage
```

The folder's name stays the **canonical** spelling: it is what `.location`, the
route table and `AppManifest.byPath` say, and what a locale with no entry gets.

- **Only its own segment.** `paths` spells the one static folder it sits in.
  Folders below have their own `route.dart` (or none), each level spelled on its
  own, so `/aide/routing/exemples` is a nested child under a localized parent.
  It is an **error** in the `route.dart` of a `$dynamic`, a `$$catch-all`, a
  `(group)` folder or the app folder (none has a word to spell).
- **What a spelling can be.** One URL segment: letters (accented or not), digits,
  `- _ . ~`. A key is a locale tag (`fr`, `pt-BR`), each once (`fr` and `FR` are
  the same tag). A value that is empty, `.`, `..`, or has `/ ? # %`, whitespace,
  a control character, or any of `: | ( ) [ ] { } ' " $ \ * =` is an error at the
  value. Two locales may share a spelling, and a spelling may equal the folder's
  own name. An entry with an error is left out, and the rest still takes part in
  the collision check.
- **Collisions are errors, with a code frame on each side.** A spelling that
  makes a URL another route serves is reported at the entry and at the route
  (or at both entries). Two `not_found.dart` files that would cover one URL
  through a spelling collide the same way.
- `paths` must be a map literal of string literals. An empty map is a warning
  (`` `paths` is empty, so it adds no spelling ``).

### Typed locations

`.location` is canonical; `locationFor(locale)` spells the locale; `go`,
`push` and `replace` take an optional `locale:`.

```dart
// lib/app/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(const ProductRoute(id: 2).location), // /products/2
      Text(const ProductRoute(id: 2).locationFor('fr')), // /produits/2
      TextButton(
        onPressed: () => const ProductRoute(id: 2).go(context, locale: 'de'),
        child: const Text('de'), // -> /produkte/2
      ),
    ],
  );
}
```

`locationFor('fr-CA')` falls back to `fr`; an unknown locale (`es`) gives the
canonical location; tags compare without regard to case and `_` is `-`; an
exact tag wins over its language. A level with no spelling for the locale keeps
its canonical one, each level on its own. Every route has `locationFor` (a route
with no localized segment answers `location`), and query parameters are kept.
There is **no global locale** on purpose: the app owns its locale and passes it.
To get it everywhere, wrap it once:
`extension on TypedLocation { void goHere(BuildContext c) => go(c, locale: currentLocaleTag()); }`.

### Every surface knows the spellings

- A deep link, `context.go('/produits/2')` and the router's location all work; the
  location **stays as asked** (`/produits/2`), nothing redirects to the
  canonical URL.
- `AppRoutes.match`, `matchUrl`, `dataAt` and `RouteMatcher` match every
  spelling and return the canonical typed route. `AppRoutes.notFound(uri)` treats
  a localized prefix as all its spellings. `AppManifest.of(state)` finds the
  route at any spelling.
- `RouteInfo.paths` is `{'fr': '/produits/:id', 'de': '/produkte/:id'}` (each
  level's canonical spelling where a locale has none) and `pathFor(locale)`
  picks one, falling back to `path`. `fsp routes` lists the spellings under the
  row, and `--json` has a `paths` object for such a route only.

### How it is routed

A localized folder is **one** `GoRoute` whose segment is a path parameter with a
pattern of its own: `':_l0(products|produits|produkte)/:id'`. So a deep link, a
redirect and `go` take any spelling; nested routes, layout, guards and
`not_found.dart` are the same route as without `paths`; `state.pageKey` is the
same for every spelling (navigating between spellings updates the page instead
of building another); restoration ids are unchanged. (A page that `remount`s on
`onLocation` is keyed by the matched path, so another spelling is another page.)

- The parameter is named `_l<n>` after the segment's place in the URL
  (`_l0`). It shows in `GoRouterState.pathParameters` and `fullPath`; **do not
  read it**.
- Spellings also match mixed (`/help/routing/exemples`): each level is its own
  alternation. A typed route never writes one; a `guard.dart` reading `uri` can
  refuse or redirect them.
- **A tab's first route.** go_router opens a tab on its first route and asserts
  it has no path parameter, which a localized segment is. `fsp gen` writes the
  tab's `initialLocation` (the canonical one) unless you gave one in
  `tabOptions` (which may be a spelling). The one case it cannot write is a
  localized first tab route **below a `:segment`**: that is an error.
- A localized static folder still sorts before dynamic siblings, so `/produits`
  is not caught by a `/:slug`.

### Non-ASCII spellings

```dart
// lib/app/guide/route.dart
const paths = {'de': 'führer', 'ru': 'руководство'};
```

```dart
// lib/app/guide/page.dart
import 'package:flutter/material.dart';

class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('guide');
}
```

A URL carries only ASCII: `Uri.path` is always percent-encoded, so `/führer`,
`/f%C3%BChrer` and `/f%c3%bchrer` all reach the route (the pattern has each
spelling encoded, UTF-8 bytes in upper-case hex). The runtime helpers
(`match`, `dataAt`, `nearestNotFound`, the manifest, `fsp routes`, diagnostics)
compare decoded segments and show the word as written. `locationFor('de')`
writes it **encoded** (`/f%C3%BChrer`); `.location` is always ASCII. With
`caseSensitive: false`, go_router folds `A-Z` and the hex digits only, so
`/FÜHRER` is **not** `/führer`; `AppRoutes.match` lowercases Unicode and may say
a route fits where go_router's own matching would not (list the capital
spelling in `paths` if you need it). A letter written two ways (precomposed or
with a combining mark) is two spellings to go_router: write the precomposed
form browsers send.

## `nest = false`: a sibling with a compound path

Since 0.4.0. A page is the parent of the routes in the folders below it: with
`orders/$id/refund/page.dart` and `orders/$id/refund/confirm/page.dart`, `confirm` is a
`GoRoute` inside the `refund` one, and a deep link to `/orders/1/refund/confirm` builds
the stack `/orders/1`, `/orders/1/refund`, `/orders/1/refund/confirm`. That is the right
default. When the deeper page must **not** build (or read anything for) the page that
happens to share its first segment, as with go_router routes written side by side
(`GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` under `:id`), declare
it in the folder of the route that leaves:

```dart
// lib/app/orders/$id/refund/confirm/route.dart
const nest = false;
```

```dart
// lib/app/orders/$id/page.dart
import 'package:flutter/material.dart';

class OrderPage extends StatelessWidget {
  const OrderPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Text('order $id');
}
```

```dart
// lib/app/orders/$id/refund/page.dart
import 'package:flutter/material.dart';

class RefundPage extends StatelessWidget {
  const RefundPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Text('refund $id');
}
```

```dart
// lib/app/orders/$id/refund/confirm/page.dart
import 'package:flutter/material.dart';

class ConfirmPage extends StatelessWidget {
  const ConfirmPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Text('confirm refund $id');
}
```

The folder stays where it is: the URL, the typed route
(`ConfirmRoute(id: 1).location` is `/orders/1/refund/confirm`) and the manifest entry do
not change. What changes is the route `fsp` writes: a sibling of `refund`, with a
compound path,

```text
GoRoute(path: joinLocation(at, '/orders/:id'), routes: [
  GoRoute(path: 'refund'),
  GoRoute(path: 'refund/confirm'),   // beside it, not inside
])
```

so the stack is `/orders/1`, `/orders/1/refund/confirm`, and the `refund` page is neither
built nor asked for its `data.dart`. `fsp routes` tags it `(sibling)` (`"sibling"` in
`--json`). `examples/features` has `orders/$id/refund/confirm` (and `refund/receipt`,
which nests) with widget tests for the stack and for back.

- **At runtime** (since 0.7.0), `RouteInfo.sibling` is `true` for the route that declares
  `nest = false` and `false` for the page it left and for every other route
  (`AppRoutes.byType[ConfirmRoute]!.sibling`, like the rest of
  `RouteInfo`). It is a flag, not a parent: the page it sits beside is not always one route
  (the folders between can be page-less), and `path` already has the segments it joined.
  A nested route below a sibling is not one itself.
- **This folder's route only.** It is not inherited: the folders below `confirm/` nest
  under `confirm` as usual. Put it beside a `page.dart` or a `redirect.dart`; `true` is
  the default and says nothing.
- **Where it goes.** Beside the nearest page above; page-less folders and `(group)`s in
  between don't count as one. The path joins every folder it leaves: static
  (`refund/confirm`), `$param` (`refund/:step`), catch-all (`refund/:rest(.+)`) and
  localized (`:_l2(refund|remboursement)/confirm`); a `(group)` adds nothing. If the page
  above is itself `nest = false`, the route goes beside **that** one. Beside the root
  page a route is top level (`login/` with `nest = false` is `/login`, not under `/`). In
  a tab layout it stays in its tab, after the page.
- **What it keeps.** Everything that comes from the folders: the guards of the page it
  leaves and of the page-less folders between run first (outermost first), then its own;
  the nearest `transition.dart`, `navigator.dart`, `not_found.dart`, `loading.dart` and
  `error.dart` apply; the segments of the folders it leaves are parsed and typed for it
  (a bad one is not-found as before); section data above it is the same, so
  `AppRoutes.match` and `dataAt` list the same providers.
- **What it leaves.** The left page's `page.dart`, `data.dart` and `present.dart`. A
  dialog or sheet transition opens over the page that stays below (`orders/$id`), not
  over `refund`.
- **Case.** One go_router path is one flag: the whole compound path matches by the
  route's own `caseSensitive` (the nearest `route.dart` at or above it, its own
  included).
- **Order.** go_router tries siblings depth first and moves on when a route's children
  don't match the rest, so `refund` and `refund/confirm` can come in either order;
  `fsp` puts a static `refund/confirm` first when something below `refund` (a `$step`,
  a `$$rest`) would otherwise catch `confirm`.
- **Errors**, each on the declaration (texts in `fespalier-troubleshooting`,
  `references/diagnostics-config-and-meta.md`): nothing to leave (the app folder, a
  folder with no page above), a `(group)` or a folder with no `page.dart` or
  `redirect.dart`, a `layout.dart` in the folders it would leave (the route would
  escape that shell: move the layout above the page's folder), a value that is not a
  `true`/`false` literal, or two declarations.

**The other way: a group.** Without a `route.dart`, repeat the shared segment under a
`(group)`: a group adds nothing to the URL, so what it holds nests under the page
**above** the group, and its `refund/` folder has no page, so it only adds its segment:

```text
lib/app/orders/$id/
  page.dart                                    -> /orders/:id
  refund/page.dart                             -> /orders/:id/refund
  (refund-confirm)/refund/confirm/page.dart    -> /orders/:id/refund/confirm
```

That writes the same two sibling `GoRoute`s. It works because of how groups fold away
(the README documents it and a test holds it), but a group with no layout, guard or
transition looks like it does nothing; prefer `nest = false`, which says it outright.

## `linkable = false`: keep a folder out of `fsp links`

Since 0.5.0. `fsp links` writes the Android intent filters, the iOS association file and the
sitemap from the route tree (`fespalier`, `references/cli-and-config.md`). A folder whose
`route.dart` says

```dart
// admin/route.dart: nothing in admin/ or below is an App Link, a Universal Link or in the sitemap
const linkable = false;
```

is left out, with everything below it. It works like `caseSensitive`: **the nearest `route.dart`
wins** (`const linkable = true;` below turns it on again), it is inherited by `(group)` folders
and by folders without a page, it may sit at the root, and it needs no page beside it. It has no
effect on routing, `fsp gen` or the manifest.

- It must be a `true` or `false` literal, declared once; otherwise the error is
  `` `linkable` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it `` or
  `` `linkable` is declared twice ``.
- It removes the route's **own** entries only. A `$slug` route at the root still lets every
  one-segment path through the wildcard Android and iOS get for it, `/admin` included; Android has
  no way to exclude a path, so use a more specific tree (or `linkable = false` on the `$slug` folder
  too).
- If nothing is linkable, `fsp links` fails with ``no route can be linked: the app has no page, or
every folder says `const linkable = false;` ``.

## `remount`: start a page again when its URL changes

Since 0.6.0. A page keeps its widget state (a scroll position, a text field, a hook's
`useState`) when only its URL parameters change: go_router keys a page by its path template, so
`/gallery/1` to `/gallery/2` is the same page, built again with the new `id`. Whether that is
what the app wants depends on the app, so it is a setting, with the enum `Remount` (exported by
`package:fespalier/fespalier.dart`):

| Value                 | The page starts again (a fresh state) when            | It keeps its state when     |
| --------------------- | ----------------------------------------------------- | --------------------------- |
| `never` (the default) | never                                                 | anything changes in the URL |
| `onSegments`          | the value of a segment changes (`/gallery/1` to `/2`) | only the query changes      |
| `onLocation`          | anything in the location changes, the query included  | the location is the same    |

```dart
// lib/app/gallery/route.dart
import 'package:fespalier/fespalier.dart';

const remount = Remount.onSegments;
```

```dart
// lib/app/gallery/$id/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class PhotoPage extends HookWidget {
  const PhotoPage({super.key, required this.id, this.tab});

  final int id;

  /// A query parameter: it changes without starting the page again under `onSegments`.
  final String? tab;

  @override
  Widget build(BuildContext context) {
    final taps = useState(0); // lost when the page starts again
    return TextButton(
      onPressed: () => taps.value++,
      child: Text('photo $id, ${tab ?? 'info'}, ${taps.value}'),
    );
  }
}
```

For the whole app, set it in the pubspec; a folder's `route.dart` overrides it:

```yaml
fespalier:
  remount: on_segments   # never (default) | on_segments | on_location
```

- **Same rules as `caseSensitive`.** The nearest `route.dart` wins, over the parent's and
  over the pubspec; it covers the folder and everything below, is inherited by `(group)`
  folders and folders without a page, may sit at the root, and needs no page beside it.
  `const remount = Remount.never;` in a folder goes back to the default under a parent that
  remounts. An import prefix (`fsp.Remount.onSegments`) is fine.
- **`onSegments` is the one for [the URL as state](typed-routes-and-extra.md).** The page
  keeps its state across `XRoute.of(context).copyWith(page: 2)` and starts again on another
  `id`. Its key is the route template plus the values of the route's own path parameters
  (the folders above it included), as the URL spells them. A route with no segment has
  nothing to watch and is generated as if it were `never`.
- **`onLocation`** keys the page by the path matched down to its own route plus the whole
  query; the fragment is not part of it. A page below which another is pushed
  (`/orders/1` under `/orders/1/refund`) keeps its state: the path is the route's own, not the
  whole location.
- **Pages only.** A layout (a shell, a tab layout) is not remounted, whatever its folder says:
  its page is keyed by its folder, so it and its sections outlive a change of the URL. The pages
  inside it follow their own `remount`.
- **A new key is a new page** to go_router, which replaces the old page with the new one: the
  page's transition may play. With a `transition.dart` or `present.dart` the key is the one
  they get as their `LocalKey key` parameter (pass it to the `Page`, as `Transitions.*` do;
  `Transitions.none` starts a page again without animating). One that takes no key leaves
  `remount` nothing to act on, and `fsp` warns (below). Without a `transition.dart` the generated
  code builds a Material page (a Cupertino one inside a `CupertinoApp`), `remountPage`, under
  the key `remountKey`.
- **Not data.** It restarts the page's widgets, not the data: a `data.dart` provider is keyed by
  the segments and the query anyway. It changes no route and nothing `XRoute.of(context)` reads.
- **Where it shows.** `fsp routes` tags the page `remount` (only where it acts), and
  `fsp routes --json` has `"remount":"on_segments"` or `"on_location"` for a route that has one
  (the other rows have no key). The manifest has no field for it.
- **Errors**, each on the declaration (texts in `fespalier-troubleshooting`,
  `references/diagnostics-config-and-meta.md`): not `const`, a value that is not one of the
  three written out, two declarations, and a pubspec `remount:` that is not one of
  `never`, `on_segments`, `on_location`. The warning is on the page, for a `transition()` or
  `present()` that does not take the key.

`examples/features` has all three under `remount/` (`never/` and `segments/` override the
`onLocation` of `remount/route.dart`), with a widget test that presses a button, changes the URL
and reads the count.

## `deferred`: load a page's code on demand

Since 0.7.0. On the web a Flutter app is one JavaScript bundle. A folder whose `route.dart` says

```dart
// lib/app/checkout/route.dart
const deferred = true;
```

has the `page.dart` of its route, and of every route below it, imported `deferred as` in the
generated file, so dart2js makes a chunk (`main.dart.js_N.part.js`) of it that the browser fetches
when the page is first built, or earlier when it is preloaded. Nothing else about the route changes.

```dart
// lib/app/checkout/page.dart
import 'package:flutter/material.dart';

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Place order');
}
```

For the whole app, `fespalier: { deferred: true }` in the pubspec (default `false`); a folder's
`const deferred = false;` opts it out. **Off by default, and a route that isn't deferred generates
byte-identical code.**

- **Same rules as `caseSensitive`.** The nearest `route.dart` wins, over the parent's and over the
  pubspec; it covers the folder and everything below, is inherited by `(group)` folders and
  folders without a page, may sit at the root, and needs no page beside it. It must be a `true` or
  `false` literal, declared once. A pubspec value that is not a bool is serde's error, not
  ours: `invalid pubspec.yaml: fespalier.deferred: invalid type: string "maybe", expected a boolean at line 3 column 13`.
- **Only `page.dart`** (a tab layout's own page included). `layout.dart` (it wraps a `Navigator`
  and the state below it), `loading.dart` and `error.dart` (what shows while it loads or fails),
  `guard.dart` and `redirect.dart` (they decide before any build), `data.dart`, `action.dart`,
  `meta.dart`, `transition.dart`, `present.dart` and `not_found.dart` stay in the main bundle. A
  `redirect.dart` route has no page, so it is never deferred. **Layouts are never deferred.**
- **What the generated code does.** A route without data builds its page in a
  `DeferredView(library: _lib2, page: () => _i7.CheckoutPage(), loading: ..., error: ...)`: the
  nearest `loading.dart` (a spinner without one) shows until the code is there, the nearest
  `error.dart` if it can't be fetched (with `retry` loading it again, and the error `loadLibrary()`
  threw, a `DeferredLoadException` on the web). A route with data hands its library to the
  `DataView` (`library: _lib6,`), so the code loads **in parallel** with the data and the page shows
  when both are there. The page is built with no `const` (a deferred class can't be named in a
  constant expression), and **once its code is loaded it is built synchronously**.
- **`loading.dart` and `error.dart` now cover a page without data**, as for one with data, with the
  same rule: an inherited view must fit every route it covers, so an `error.dart` asking for a
  segment the deferred route doesn't have is the existing "can't fill" error, and one asking for a
  query parameter adds it to the typed route.
- **Guards run first**, from eager code: a guard that redirects means the code is never fetched.
- **Preloading** also loads the code: `preload` of the typed route (so `RouteLink` and
  `AppRoutes.preload`), and `AppRoutes.loadDeferred()` loads every deferred page now (call it after
  the first frame; before `runApp` outside the web: `if (!kIsWeb) await AppRoutes.loadDeferred();`).
  `AppRoutes.deferred` lists the `DeferredLibrary` of each.
- **A type declared in a deferred page.dart is an error (G4).** An enum segment or query type, or a
  typed `extra` class, declared in the page's own file is named by the generated file outside the
  page, where Dart can't use a deferred library's type. Move it to its own file and import it in the
  page, or say `const deferred = false;`. A type declared in a page that is not deferred is fine for a
  deferred child.
- **Where it shows.** `fsp routes` tags the page `deferred` (last), `fsp routes --json` has
  `"deferred":true` for such a route only, `--graph` marks the node, and the manifest's
  `RouteInfo.deferred` is `true`.
- **Tests.** `pumpRouter` loads the deferred code first (in `runAsync`), so a deferred page is in the
  first settled frame. A test that pumps its own router calls
  `await tester.runAsync(AppRoutes.loadDeferred);` first (`fespalier-testing`).
- **What each chunk costs** (since 0.8.0): `fsp size` after `flutter build web` reports each deferred
  route's own and shared bytes and holds them to budgets (`size:` in the pubspec); see `fespalier`,
  `references/cli-and-config.md`.
- **Not built:** deferring a layout, a `const preload = true;`, a cap on parallel loads, and
  `deferred: auto`. Don't defer the landing page.
- **Errors** (texts in `fespalier-troubleshooting`, `references/diagnostics-config-and-meta.md`): a
  value that is not a `true`/`false` literal, two declarations, a type declared in a deferred page,
  and a pubspec `deferred:` that is not a bool.

`examples/shop` defers `checkout/` and `products/$id/`, with `examples/shop/test/deferred_test.dart`,
and `just web-chunks` builds it for the web and checks that their strings are in chunks of their own.
