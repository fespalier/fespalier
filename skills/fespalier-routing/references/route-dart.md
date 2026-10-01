# `route.dart`: case, trailing slashes, localized paths and `nest`

As of v0.4.0. A `route.dart` holds up to three declarations, and `fsp` reads them
**from the source**; it never imports or runs the file, so each must be a
literal:

```dart
const caseSensitive = false;                 // this folder and below
const paths = {'fr': 'produits', 'de': 'produkte'};   // this folder's own segment
const nest = false;                          // this folder's route only (0.4.0)
```

A `route.dart` adds and removes no route, and may hold any one of them alone.
`caseSensitive` and `paths` need no page beside it; `nest` does. One with none of the
three is an error (its text predates `nest` and names the other two):
``expected `const caseSensitive = false;` (or `true`), or `const paths = {'fr': 'produits'};` ``.

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
of building another); restoration ids are unchanged.

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
