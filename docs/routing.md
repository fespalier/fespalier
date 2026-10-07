# Routing

How a URL becomes a route: segment types, query parameters, case, localized paths, groups and not-found views.

## Segment types

`{required int id}` in `products/$id/data.dart` makes `$id` an `int` everywhere: the typed `ProductRoute(id: 42)`, the page, and parsing.

- A segment's type comes from the parameters that ask for it. With none, it is a `String`.
- The types are `String`, `int`, `double`, `bool` or an [enum](#enum-segments) of your app. (A [catch-all](#catch-all-segments) is a `List` of those, or of `num` or `DateTime`.)
- **Every file that asks for `$id` must agree on its type**, or `fsp` reports the mismatch with a code frame.
- **A part that does not parse is a bad segment**: `/products/abc` goes to `not_found.dart`, the page is never built, and a guard that reads segments or query parameters is skipped (see [Guards](guards.md)).

`fsp new` scaffolds every segment as a `String`: `fsp new 'products/[id]' --data` writes `data(Ref ref, {required String id})`. To make `$id` an `int`, change the parameter type in each file that asks for it, then run `fsp gen` (or let `fsp watch` do it).

## Enum segments

A segment, a [query parameter](#query-parameters) and the parts of a [catch-all](#catch-all-segments) can be an enum of your app. Type the parameter with it in the file that asks:

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

- **Read by name.** A value is the one whose `name` the text spells (`Category.values.byName`). A segment or catch-all part that names no value is a bad segment ([Segment types](#segment-types)). A query parameter that names none is `null`, or left out of a list.
- **Case follows the route.** Names match exactly by default. Where the route's paths match in any case ([`case_sensitive: false`, or a `route.dart`](#case-and-trailing-slashes)), `/shop/SHOES` is `Category.shoes` too. A name that matches exactly always wins, so an enum with `a` and `A` still tells them apart.
- **Written by name.** `.location` writes `.name` for a segment, each part of a catch-all and a query parameter. The typed route's field has the enum's type.
  **Finding the enum.** `fsp gen` reads the declaration from the file that names the type or a file it imports (through `export`s too): relative imports and `package:` imports of your own package, not `dart:` or other packages; an import prefix (`m.Category`) is followed through that import only. A type with no enum found (a class, one from another package, one not imported) and a private enum (`_Mode`) are errors at the parameter, which suggests taking a `String` and parsing it in the page.
- **The type must agree across files.** `Category` in `page.dart` and `Size` in `data.dart` is the error a mismatched `int` is (`` `$category` is Size in data.dart:1 but Category here ``). `Category` and `m.Category` are the same type when they name the same enum; two enums that share a name are not.
- **`data.dart` can be keyed by an enum.** `{required Category category}` keys the provider by the enum, and `ShopRoute.watch(ref, category: Category.hats)` takes it. A `List<Category>` catch-all is keyed by its path and `data()` gets the list back; a `List<Category>` query parameter is keyed by a `QueryList`. `AppRoutes.match(uri).params` and `AppRoutes.dataAt` have the enum values.

**Limits.**

- An enum is read by `name` only.
- `Sort sort = Sort.price` (not nullable) isn't a query parameter, as for `int`.
- An _optional_ nullable parameter of a type `fsp` finds no enum for keeps its default (it may be plain widget configuration, `Color? color`); the error comes when a `data.dart`, `guard.dart` or `redirect.dart` asks for it.
- `fsp watch` also watches the rest of `lib/`, so an enum added or edited there regenerates (outside `lib/`, run `fsp gen`).
- `fsp new` below an enum segment writes its type name into the new files; you add the import.

## Catch-all segments

`$$rest` matches **one or more** remaining segments, and `$$$rest` (three `$`) **zero or more**. The page takes them as a `List<String>` (or a [typed list](#typed-catch-alls)), each part decoded on its own:

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

A catch-all becomes a go*router route with a `:rest(.+)` pattern, so deep links, redirects and `go` use go_router's normal matching (`$$$rest` is two routes with one builder: `/files` and `:path(.+)`). Parts are read from the decoded string taken apart \_by the requested location*, so an encoded slash survives (`/docs/a%2Fb/c` is `['a/b', 'c']`).

- Siblings are tried in this order whatever the folder order: static, then dynamic (`docs/$id`), then the catch-all. A page that another route always catches first is reported as unreachable, including by a catch-all (`(wiki)/docs/$$rest` behind `$a/$$rest`).
- `guard.dart`, `redirect.dart`, `layout.dart`, `loading.dart` and `error.dart` can take the parts like any segment (`{required List<String> rest}`).
- `data.dart` can be keyed by them. Lists compare by identity, so the generated provider is keyed by the encoded path as one string (`restKey`) and `data()` gets the list back (`restParts`). `ref.watch(DocsRoute.data(restKey(rest)))` is what the route does; the typed `DocsRoute.watch(ref, rest: [...])` takes the list. A provider you write yourself (`final data = FutureProvider.family<…>`) can't be keyed by a catch-all: use the function or a [selector](data.md#datadart-a-function-a-selector-or-a-provider).
- `$$$rest` and a `page.dart` in the folder above would both serve `/docs`: an error. Use `$$rest` beside the page.

**Limits.** A catch-all is always the last segment and a `List`; nothing can be below its folder, and it can't have a `not_found.dart` (it matches every URL under it). As a tab's first route it needs a `tabOptions` `initialLocation`, like any route with a parameter. A part of `.` or `..` is read as a dot segment by the URL parser, so `DocsRoute(rest: ['..'])` doesn't reach a `..` part. `fsp new 'docs/[...rest]'` and `'docs/[[...rest]]'` write the folders, so you don't have to quote `$`.

### Typed catch-alls

A catch-all takes its type from the parameters that ask for it; `List<String>` is the default. Ask for a `List<int>`, `List<double>`, `List<num>`, `List<bool>`, `List<DateTime>` or a `List` of an [enum](#enum-segments) and every part is read like one segment of that type:

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

- **A part that doesn't parse** is a bad segment ([Segment types](#segment-types)). `bool` parts are `true` and `false`; `num` reads `1` as an int and `2.5` as a double; a `DateTime` part is what `DateTime.tryParse` reads, and the typed route writes it as ISO 8601 (`2024-12-31T10:30:00.000Z`, colons encoded).
- **`.location` joins the encoded parts**, each on its own (`restPath`), whatever their type. `$$$rest` is an empty list when the path has no part.
- **The type must agree across files**: a `page.dart` with `List<int> ids` and a `data.dart` with `List<String> ids` is an error with a code frame at the second, naming the first (`` `$ids` is List<String> in data.dart:1 but List<int> here ``). Anything else (`List<Object>`, `List<int?>`, `Set<int>`) is an error that lists what a catch-all can be.
- **`data.dart`** takes the typed list too: the provider is keyed by the encoded path, and `data()` gets the list back as a `List<int>`.

## Query parameters

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

A query parameter's type comes from the parameters that ask for it, like a segment's: `T?` for a single value, `List<T>` for repeated ones. Every file of a route that asks for `?page` must agree on its type.

- A missing or unparsable value is `null` (or left out of a list). Unlike a bad segment, it never leads to not-found.
- The typed route takes query parameters as optional arguments and writes them into `.location`, leaving out nulls and empty lists.
- A query parameter can be an [enum](#enum-segments) too (`Sort? sort`, `List<Sort> sorts`).

**In `data.dart`.** A `data.dart` can take query parameters, and its provider is then keyed by them, so `/search?page=2` and `?page=3` load separately.

- A `List` works as a key too. Lists compare by identity, so the generated provider is keyed by a `QueryList` (a `List` with value equality, exported by fespalier) holding the same elements, and `?tags=a&tags=b` is one provider however many times the page builds a new list.
- Your `data()` still takes and receives a plain `List<String>`, and the typed helpers take one (`SearchRoute.watch(ref, tags: ['a', 'b'])`).
- Order counts: `[a, b]` and `[b, a]` are different keys.
- A provider you write yourself can't be keyed by a query parameter, only by segments.

To change one query parameter of the current location from a widget, see [the URL as state](navigation.md#the-url-as-state-of-and-copywith): `SearchRoute.of(context).copyWith(page: 2).go(context)`.

## Case and trailing slashes

**Trailing slashes.** `/products/` reaches `/products`: go_router drops a trailing slash before it matches (also in front of a query, `/products/?page=2`), whether it comes from a deep link, `initialLocation` or `context.go`. There is nothing to configure, and typed locations never end in one. (Checked against go_router 17.5 and 18.)

**Case.** Paths are case-sensitive, like go_router's default: `/Products` isn't `/products`. Set `case_sensitive: false` in the pubspec's `fespalier:` section to emit `caseSensitive: false` on every route:

```yaml
fespalier:
  case_sensitive: false
```

Static parts then match in any case (`/PRODUCTS/Guide` finds `products/guide`), and the parts you take out of the URL (a `$segment`, a catch-all) keep the case they had.

**Per folder.** A `route.dart` overrides that for its folder and everything below it; the nearest one wins over the parent's and over the pubspec. (`route.dart` is the per-folder settings file: [all its constants and the rules they share](configuration.md#per-folder-settings-routedart).)

```dart
// lib/app/files/route.dart: /files/README.md isn't /files/readme.md, whatever the pubspec says
const caseSensitive = true;
```

It works both ways: `false` in one folder of an otherwise exact app, or `true` in one folder of a `case_sensitive: false` one (`examples/features` does the second).

go_router has one case flag per route, so a folder with no page above one that has (`docs/` above `docs/guide/page.dart`) takes the flag in effect at the page's folder, for the whole path. The nearest-`not_found.dart` lookup compares each folder by its own setting, and the mount point (`AppRoutes.mount(at: '/Shop')`) by the root's.

**The requested case is kept.** go_router matches a case-insensitive route in any case and leaves the location as it was asked for.

- Navigating or deep-linking to `/Products/2` leaves `GoRouterState.uri` and the router's own location (`currentLocation(tester)` in a test) as `/Products/2`. Nothing is lowercased or redirected, and a `$segment` or catch-all keeps what was typed.
- Only `state.matchedLocation` is spelled by the route (`/products/2`, with the parameters as typed).
- A typed route has no requested case: `ProductRoute(id: 2).location` always writes the folders' spelling. If you want the canonical spelling in the address bar, navigate to it yourself.

## Localized paths

One folder can answer several URL spellings, one per locale, while the typed route, the page and its data stay single. Give the folder a `route.dart` with a `paths` map from a locale tag to that folder's name in it. (To serve translated texts as well, with the language taken from the URL, see [Translations](i18n-tolgee.md).)

```dart
// lib/app/products/route.dart: /products also answers /produits (fr) and /produkte (de)
const paths = {'fr': 'produits', 'de': 'produkte'};
```

```text
/products/2    /produits/2    /produkte/2      → the same ProductPage(id: 2), the same data
/products      /produits      /produkte        → the same ProductsPage
```

The folder's name stays the canonical spelling: it is what `.location`, the route table and `AppManifest.byPath` say, and what a locale with no entry gets. `paths` is read from the source, so it must be a map literal of string literals.

- **Only its own segment.** `paths` spells the one static folder it sits in. Folders below have their own `route.dart` (or none), and each level is spelled on its own, so `/aide/routing/exemples` (`help/` → `aide`, `$topic/examples/` → `exemples`) is a nested child under the localized parent. It is an error in the `route.dart` of a `$dynamic`, a `$$catch-all` or a `(group)` folder or of the app folder itself (none has a word to spell). A `route.dart` may hold `paths` alone.
- **What a spelling can be.** One URL segment: letters and digits, `- _ . ~`, and letters beyond ASCII (`'über'`, `'продукты'`; see [below](#non-ascii-spellings)). A key is a locale tag (`fr`, `pt-BR`), each once (`fr` and `FR` are the same). A value that is empty, `.` or `..`, or has a `/`, `?`, `#`, `%` (write the letter, not its encoding), whitespace, a control character, or any of `: | ( ) [ ] { } ' " $ \ * =` is an error at the value. Two locales may share a spelling, and a spelling may equal the folder's own name. An entry with an error is left out, and the rest of the map still takes part in the collision check.
- **Collisions are errors, with a code frame on each side.** A spelling that makes a URL another route serves is reported at the entry and at the route it collides with (or at both entries, when both are spellings). Two [`not_found.dart`](#not-found-views) files that would cover one URL through a spelling collide the same way:

  ```text
  error: `fr: 'about'` makes /about, which about/page.dart serves too; rename the spelling, or the folder it collides with
    ┌─ lib/app/products/route.dart:2:9
  error: /about is also reached through `fr: 'about'` in products/route.dart:2; rename the spelling, or this folder
    ┌─ lib/app/about/page.dart:1:7
  ```

  The [unreachable-route](#group-folders) check knows the spellings too.

**Typed locations.** `.location` is canonical, `locationFor(locale)` spells the locale, and `go`, `push` and `replace` take an optional `locale:`:

```dart
ProductRoute(id: 2).location;                 // '/products/2'
ProductRoute(id: 2).locationFor('fr');        // '/produits/2'
ProductRoute(id: 2).locationFor('fr-CA');     // '/produits/2': a region falls back to its language
ProductRoute(id: 2).locationFor('es');        // '/products/2': nobody spells it
ProductRoute(id: 2).go(context, locale: 'de');  // → /produkte/2; also push<T>(…, locale:), pushReplacement<T>(…, locale:) and replace(…, locale:)
```

- A level with no spelling for the locale keeps its canonical one, each level on its own (with `help/` spelled `fr` and `contact/` only `de`, `ContactRoute().locationFor('fr')` is `/aide/contact`).
- Tags compare without regard to case and `_` is `-`; an exact tag wins over its language.
- Every route has `locationFor` (a route with no localized segment answers `location`), and query parameters are kept.
- The locale is an argument, not a global the typed routes read, so a route stays a value and `.location` never depends on when it is read ([why](faq.md#why-a-localized-path-is-one-route-with-an-alternation)). To use your locale everywhere, wrap it once: `extension on TypedLocation { void goHere(BuildContext c) => go(c, locale: currentLocaleTag()); }`. (A `$locale` folder, `/:locale/products`, is a different way to localize and needs none of this.)

**Every surface knows the spellings.** A deep link, `context.go('/produits/2')`, the router's location (it stays as it was asked: nothing is redirected to the canonical URL), and the helpers that read a location:

- `AppRoutes.match` / `matchUrl` / `dataAt` and `RouteMatcher` match every spelling and return the canonical typed route (`match.route.location` is `/products/2`).
- `nearestNotFound`, so `AppRoutes.notFound(uri)`, treats a localized prefix as all its spellings: a [`not_found.dart`](#not-found-views) in `help/` covers `/help/x`, `/aide/x` and `/hilfe/x`. Case follows the route's [`caseSensitive`](#case-and-trailing-slashes).
- `AppManifest.of(state)` finds the route at any spelling. The [manifest](#route-manifest-and-metadart)'s `RouteInfo` has `paths` (`{'fr': '/produits/:id', 'de': '/produkte/:id'}`, with each level's canonical spelling where a locale has none) and `pathFor(locale)`; `path` and `byPath` stay canonical.
- `fsp routes` lists the spellings under the route, and `--json` has a `paths` object for a route that has them:

  ```text
  /products/:id  ProductRoute  products/$id/page.dart  (data)
    fr  /produits/:id
    de  /produkte/:id
  ```

**How it is routed.** A localized folder is _one_ `GoRoute` whose segment is a path parameter with its own pattern (like the catch-all's `:rest(.+)`): `products/$id` is `path: ':_l0(products|produits|produkte)/:id'`, so a deep link, a redirect and `go` take any spelling, and everything below the folder (nested routes, layout, guards, `not_found.dart`) is the same route as without `paths`. `state.pageKey` is the same for every spelling (navigating from `/products/2` to `/produits/2` updates the page instead of building another), and restoration ids are unchanged. [Why not the alternatives](faq.md#why-a-localized-path-is-one-route-with-an-alternation).

Things to know:

- The parameter is named `_l<n>` after the segment's place in the URL (`_l0`, `_l1`) and shows up in `GoRouterState.pathParameters` and `fullPath`; don't read it. `state.matchedLocation` is spelled as requested (`/produits/2`).
- Spellings also match when mixed (`/help/routing/exemples`, `/aide/routing/examples`): each level is its own alternation. A typed route never writes one; to refuse or redirect mixed URLs, a `guard.dart` can read the `uri`.
- **A tab's first route.** go_router opens a tab on its first route and asserts that it has no path parameter, which a localized segment is. `fsp gen` writes the tab's `initialLocation` for you (the canonical one, `/search`), unless you gave one in `tabOptions` (which can be a spelling: `'/recherche'`). The one place that can't be written down is a localized first tab route below a `:segment` (the location would need a value): that is an error that says so.
- A localized static folder still sorts before dynamic siblings, so `/produits` isn't caught by a `/:slug`.

### Non-ASCII spellings

`const paths = {'de': 'über', 'ru': 'продукты'};` works. A URL carries only ASCII: `Uri.path` is always percent-encoded, whether a location was typed `/über`, arrives from the browser as `/%C3%BCber` or as `/%c3%bcber` (`Uri.parse` normalizes all three to `/%C3%BCber`, and go_router's location, `GoRouterState.uri` and `currentLocation` are that form). So:

- **The route matches the encoded spelling.** `fsp gen` writes it into go_router's pattern encoded, UTF-8 bytes in upper-case hex: `':_l0(shop|%C3%BCber|%D0%BF%D1%80%D0%BE%D0%B4%D1%83%D0%BA%D1%82%D1%8B)'`. A deep link raw, encoded or in lower-case hex, `go('/über')` and `go('/%C3%BCber')` all reach it.
- **The runtime helpers compare decoded segments,** so `AppRoutes.match`, `dataAt` and `nearestNotFound` (and the manifest, `fsp routes` and diagnostics) have the word as written: `'shop|über|продукты'`.
- **`locationFor` writes it encoded,** as `Uri` would: `ProductsRoute().locationFor('de')` is `/%C3%BCber`, the same URL as `Uri.parse('/über')`. `.location` (canonical) is always ASCII.
- **Case and normalization.** With [`caseSensitive: false`](#case-and-trailing-slashes), go_router's match is on the encoded text: it folds `A-Z` and the hex digits, but `/ÜBER` is not `/über` (different bytes). `AppRoutes.match` lowercases Unicode, so it may say a route fits where go_router's own matching would not; list the capital spelling in `paths` if you need it. A letter written two ways (`ü` as one character, or `u` plus a combining diaeresis) is two spellings to go_router: write the precomposed form browsers send.

## `(group)` folders

A folder named in parentheses groups routes without adding to their URLs. Its `layout.dart`, `loading.dart` and `error.dart` apply to the routes inside it and not to their siblings, so `(shop)/cart` and `(account)/profile` can have different shells and still be `/cart` and `/profile`. A group can also hold a `page.dart`: `(marketing)/page.dart` serves `/` with the marketing layout, as long as nothing else serves `/`.

Two pages that end up at the same URL are an error, and so is a page that another route always catches first. go_router takes the first route that fully matches, so fespalier puts static routes before dynamic ones (`/about` comes before `/:slug`). A group's routes stay together in one ShellRoute, though, so a group holding a dynamic route can't be sorted around a dynamic sibling outside it:

```text
error: /settings is unreachable: $slug/page.dart (/:slug) comes first and matches it;
       move one of them into or out of its (group)
```

### A sibling with a compound path

A page is the parent of the routes in the folders below it. With `orders/$id/refund/page.dart` and `orders/$id/refund/confirm/page.dart`, `confirm` is a `GoRoute` inside the `refund` one, and a deep link to `/orders/1/refund/confirm` builds the stack `/orders/1`, `/orders/1/refund`, `/orders/1/refund/confirm` (see [Transitions](layouts.md#transitions)). That is the right default.

A tree migrated from go_router may have `GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` side by side under `:id`. The stack of the same link is then `/orders/1`, `/orders/1/refund/confirm`: the `refund` page is not built and nothing is read for it. Two ways to write that shape: a group, or a declaration.

**With a group.** A group has no page and adds nothing to the URL, so what it holds nests under the page above the group, not under a page beside it, and its folders may repeat a segment of that sibling:

```text
lib/app/orders/$id/
  page.dart                                    → /orders/:id
  refund/page.dart                             → /orders/:id/refund
  (refund-confirm)/refund/confirm/page.dart    → /orders/:id/refund/confirm
```

This generates `GoRoute(path: 'refund')` and `GoRoute(path: 'refund/confirm')` as two children of `/orders/:id`: the `refund/` inside the group has no `page.dart`, so it only adds its segment to the path. A group with no layout, guard or transition looks like it does nothing: name it for what it is for, or say it outright with `nest`.

**With `route.dart`.** `const nest = false;` in the folder of the route that must not nest:

```dart
// lib/app/orders/$id/refund/confirm/route.dart
const nest = false;
```

`confirm/` stays where it is: its URL, its typed route (`ConfirmRoute(id: 1).location` is `/orders/1/refund/confirm`) and its place in the manifest do not change. What changes is the route fespalier writes for it: no longer a child of the page of the folder above (`refund`) but a sibling of that page, with a compound path,

```dart
GoRoute(path: joinLocation(at, '/orders/:id'), routes: [
  GoRoute(path: 'refund'),
  GoRoute(path: 'refund/confirm'),   // beside it, not inside
])
```

so the stack is `/orders/1`, `/orders/1/refund/confirm`, and the `refund` page is neither built nor asked for its `data.dart`. `fsp routes` marks the route `(sibling)` (and its `tags` in `--json` have `"sibling"`).

- Like `caseSensitive` it is read from the source, so it must be a `true` or `false` literal.
- It is about this folder's route alone and is not inherited: the routes in the folders below `confirm/` nest under `confirm` as usual.
- `true` is the default and says nothing. There is only this declaration, in the folder of the route that leaves.
- The name `nest`: it is the verb the docs already use for folders, and `false` is the exception.

**Where it goes.** Beside the nearest page above it; page-less folders and groups in between don't count as one.

- The path joins the segments of the folders it leaves: the static ones, the `$param` ones and a [localized](#localized-paths) one as its alternation (`:_l2(refund|remboursement)/confirm`). Examples: `refund/confirm`, `refund/:step`, `refund/:rest(.+)` for a `$$rest`. A `(group)` adds none.
- If the page above is itself `nest = false`, the route goes beside that one: its parent is the nearest route that stays, and the path joins every folder between.
- Beside the root page, a route is at the top: `login/` with `nest = false` is `/login` without `/` below it.
- A `redirect.dart` route can leave too. In a tab layout the route stays in its tab, after the page.

**What it keeps.** Everything comes from the folders, not from where the route is written.

- The guards of the page it leaves and of the page-less folders in between run first, outermost first, then its own.
- The nearest `transition.dart`, `navigator.dart`, `not_found.dart` and `loading.dart` / `error.dart` still apply.
- The segments of the folders it leaves are parsed and typed for it, its data and its views, and a segment that doesn't parse is not-found as before.
- The data of the sections above it is the same, so `AppRoutes.match` and `dataAt` list the same providers.
- What the page it leaves builds and reads (its page, `data.dart`, `present.dart`) is not part of it.
- A dialog or sheet [transition](layouts.md#transitions) opens over the page that stays below it, `orders/$id`.

**`caseSensitive`.** One go_router path is one flag, so the whole compound path matches by the route's own setting: the nearest `route.dart` at or above it, its own included.

**Order.** go_router takes the first route that matches the whole URL, depth first, so `refund` and `refund/confirm` can come in either order. Static routes come before `:param` ones and catch-alls as always; fespalier puts a static `refund/confirm` before `refund` when something below `refund` (a `$step`, a `$$rest`) would match `confirm` first, and otherwise follows the page, so a tab still opens on it. A route that something earlier still catches is the usual [unreachable error](#group-folders).

**Errors, each with a code frame on the declaration.**

- `nest = false` where there is nothing to leave: in the app folder, in a `(group)` (which has no route of its own; the error names the group shape above), in a folder with no `page.dart` or `redirect.dart`, or with no `page.dart` above.
- A `layout.dart` in the page's folder or in a page-less folder between: the route would leave its shell, so move the layout above the page, or drop `nest`.
- A value that isn't a `true` or `false` literal, or two of them.
- A route on the root navigator (`navigator.dart`, `present.dart`) that would become a direct child of a layout: the existing [root navigator](navigation.md#the-root-navigator-navigatordart) error.

## Not-found views

A `not_found.dart` at the root is the app-wide one. Any other folder can have one too, and the nearest wins, for two things:

- **Unknown paths.** An unknown URL shows the `not_found.dart` of the deepest folder it is under (a `$dynamic` folder matches any value), or the root's. With `teams/$teamId/not_found.dart` and `teams/$teamId/members/not_found.dart`, `/teams/a/members/1/x` shows the members one, `/teams/a/x` the team one, and `/nope` the root's. This is what `AppRoutes.notFound(uri)` does, and the router's `errorBuilder` calls it. The view shows without any layout.
- **Unparsable segments.** `/teams/a/members/abc`, where a member's id is an `int`, shows the nearest `not_found.dart` above that route (a `(group)`'s counts here).

**What it gets.** `Uri uri`, and the segments of its own path as `String`s, as the URL spells them (`teams/$teamId/not_found.dart` can take `String teamId`).

- The segments are raw on purpose: a segment that didn't parse (`abc` where an id is an `int`) is often the reason you are here. So a `not_found.dart` can't ask for one typed, and one that declares `int teamId` is an error that says so.
- The value is the decoded path part: `/teams/Acme%20Co/members/x` gives `Acme Co`.
- It gets no query parameters and no data.
- `fsp new members --not-found` scaffolds one (with the segments it can take).

**Groups and mounts.**

- A `(group)` folder adds nothing to the URL, so its `not_found.dart` can't be picked for unknown URLs: only for its own routes' bad segments.
- Two folders with the same URL (`(a)/x` and `(b)/x`) can't both have one; that's an error.
- When the tree is mounted under a prefix (`mount(at: '/shop')`), the prefix is skipped when looking for the folder, and a URL outside it gets the root's.

## Route manifest and `meta.dart`

The generator knows a lot about every route (its typed route, path, folder, groups and layouts, parameters), and only a person can write the rest (a stable review code, a page title, an analytics name). The manifest puts the first at runtime, next to the second.

```dart
final info = AppRoutes.byType[ProductRoute]!;   // or AppRoutes.byPath['/products/:id']
info.path;      // '/products/:id'
info.folder;    // r'(buyer)/products/$id'
info.groups;    // ['(buyer)']
info.meta;      // whatever lib/app/(buyer)/products/$id/meta.dart declares
AppRoutes.all;  // every route, in the order of the table at the top of app.g.dart
```

`AppRoutes.all`, `byType` (typed-route class → info) and `byPath` (path template → info) are generated as `AppManifest`, a `const` list of `RouteInfo`s, and forwarded by `AppRoutes`. `AppManifest.match(uri)` finds the entry for a _location_ ([From a location to its data](data.md#from-a-location-to-its-data)). Each `RouteInfo<M>` has:

| Field               | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `type`              | the typed-route class: `ProductRoute`                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `path`              | the path template, without the mount point: `/products/:id`; a [catch-all](#catch-all-segments) is `/docs/*rest`, or `/files/*path?` when optional (as in `fsp routes`). Case-insensitive paths (`case_sensitive: false`) don't change it                                                                                                                                                                                                                                                                      |
| `paths`             | the path in each locale its folders spell it in, `{'fr': '/produits/:id'}` (a level with no spelling for a locale keeps its own); empty without [localized paths](#localized-paths). `pathFor(locale)` picks one, falling back to `path`                                                                                                                                                                                                                                                                       |
| `folder`            | the route's folder relative to the app folder: `(buyer)/products/$id` (empty for the app folder itself)                                                                                                                                                                                                                                                                                                                                                                                                        |
| `presentation`      | `RoutePresentation.page`; `.redirect` for a `redirect.dart` (`isRedirect`); `.root` for a page on the [root navigator](navigation.md#the-root-navigator-navigatordart) through `navigator.dart`; `.custom` for a page a [`present.dart`](navigation.md#presentdart-a-page-of-your-own) builds (it is on the root navigator too, unless a `navigator.dart` beside it says otherwise). Whether a page opens as a dialog or sheet is up to its `transition.dart` or `present.dart` at runtime, so it isn't listed |
| `sibling`           | `true` for a route declared [`nest = false`](#a-sibling-with-a-compound-path) (since 0.7.0): a sibling of the page above it, with a compound path, not its child (the `sibling` tag of `fsp routes`); `false` otherwise                                                                                                                                                                                                                                                                                        |
| `groups`            | the `(group)` folders above it, outermost first, parentheses included                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `layouts`           | the folders of the layouts that wrap it, outermost first (`''` is the app folder's own layout)                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `segments`, `query` | `RouteParam(name, type)`: `('id', 'int')`, `('page', 'int?')`, `('tags', 'List<String>')`. A catch-all is the last segment, a `List<String>` (or the `List` type it is typed with) with `catchAll: true`                                                                                                                                                                                                                                                                                                       |
| `tabs`              | the tabs it sits in, outermost first: `RouteTab(layout, index, branch)`, where `branch` is the name `tabs` and `tabOptions` use (`.` for the layout's own page); empty outside tab layouts                                                                                                                                                                                                                                                                                                                     |
| `dataKeys`          | what its `data.dart` is keyed by; `null` without one                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `meta`              | its `meta.dart`, as declared                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

**`meta.dart`.** Put `const meta = <any const expression>;` next to a `page.dart` (or `redirect.dart`), and the generator copies it into the manifest _by reference_ (`meta: _i7.meta`). fespalier doesn't interpret it; use any type:

```dart
// lib/app/(buyer)/products/$id/meta.dart
import 'package:my_app/page_meta.dart';

const meta = PageMeta(code: 'B04', slug: 'product-detail', title: 'Product');
```

- **It is per route, not inherited.** A route gets its own folder's `meta.dart` or none, so `photos/sort/` doesn't see `photos/meta.dart`. To share something (a role, say), keep it in the group: `info.groups` already lists it.
- **It must be `const`.** The manifest is a `const` list. A `meta` that is `final`, `var` or a getter is an error at its declaration, and so is a `meta.dart` that declares no `meta`. A `meta.dart` in a folder with no `page.dart` or `redirect.dart` is a warning: it describes no route.
- **It can be required.** With `fespalier: { meta: required }` in `pubspec.yaml`, a route without a `meta.dart` is an error that names its folder: `` `products/$id/` has no meta.dart ``. fespalier never numbers, derives or defaults anything in it.
- **Its values can be unique.** `meta_unique: [code, slug]` in the same section makes a duplicate an error. It reads the _literal_ named arguments of `meta`'s constructor call (`const meta = PageMeta(code: 'B04', slug: 'product-detail')`; a string, number or bool) in every route's `meta.dart` and reports a value two routes share, naming both files (`` `code: 'B04'` is also in products/meta.dart ``). An argument that is an expression, or that a route leaves out, is skipped, and a listed name no `meta.dart` gives a literal is a warning (a typo, maybe). Anything more is a few lines in a test over `AppRoutes.all` and `metaAs`.
- **Read it typed** with `info.metaAs<PageMeta>()` (null when the route has none, or it is another type), or check `info.meta is PageMeta`. The list holds `RouteInfo<Object?>`.

**A library of its own.** `meta.dart` files pull whatever they import into `app.g.dart`, and so into your app. To keep review-only metadata out of production code, write the manifest to a second file:

```yaml
fespalier:
  output_manifest: lib/app.routes.g.dart
```

- `app.g.dart` then has no manifest and no `meta.dart` import. `lib/app.routes.g.dart` (which imports `app.g.dart` for the typed routes) holds `AppManifest` with the same `all`, `byType` and `byPath`.
- Import it only where you need it (tests, a review screen); production code that imports `app.g.dart` alone never sees a `meta.dart`.
- `AppManifest` is the same name in both modes, so code that uses it doesn't change when you move the file; `AppRoutes.byType` exists only when the manifest is in `app.g.dart`.
- `fsp gen` writes both files, `fsp check` checks what either would say, `fsp watch` regenerates both, and both are committed like `app.g.dart` (see `examples/tabs`).

**Web tab titles.** A layout can read the route it is showing with `AppManifest.of(GoRouterState.of(context))` (null in a not-found view), and set the title of the browser tab with Flutter's `Title` widget. No meta schema is baked in: whatever your type calls it works.

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

`AppManifest.of` looks the path up in `byPath` after taking `AppRoutes.base` off, so it also works under `AppRoutes.mount(at: '/shop')`, and for catch-all routes (go_router's `:rest(.+)` is matched to `*rest`, and an optional catch-all's bare path to its route). The same lookup gives analytics screen names (`info.path`, or a name in your meta) from a `NavigatorObserver`.

**`fsp routes --json`** prints the same data, one object per route. Besides `pattern`, `route`, `file`, `tags` and `params` it has the manifest's fields, in this order (paths in `file` and `meta` are relative to the project root; `folder`, `layouts` and `tabs[].layout` to the app folder):

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

- `presentation` is `page`, `redirect`, `root` or `custom` (see the table above).
- `tabs` is `[{"layout":"(tabs)","index":0,"branch":"search"}]` for a route in a tab.
- `data_keys` and `meta` are `null` when the route has no `data.dart` or `meta.dart`. The meta itself is Dart, so JSON only says where it is.
- `catch_all` is `{"name":"rest","optional":false}` for a route that ends in a `$$rest` (or `$$$rest`, `"optional":true`) catch-all, else `null`; the catch-all is also in `params` as a path parameter of its `List` type.

Keys that appear only on some routes, in this order after `catch_all`:

| Key         | When                                                                                                    | Value                                                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `paths`     | the route has [localized paths](#localized-paths)                                                       | `"paths":{"fr":"/produits/:id"}` (the manifest's `paths`)                                                                                                                                          |
| `remount`   | the route [remounts](navigation.md#remounting-a-page-remount) (since 0.6.0)                             | `"remount":"on_segments"` or `"remount":"on_location"`; in `fsp routes --json` only, not in the manifest                                                                                           |
| `deferred`  | the page is [deferred](navigation.md#deferred-routes-a-pages-code-on-demand) (since 0.7.0)              | `"deferred":true`; the manifest says it as `RouteInfo.deferred`                                                                                                                                    |
| `freshness` | its own `data.dart` has a [`freshness`](data.md#freshness-staletime-resume-and-reconnect) (since 0.8.1) | the file whose `Freshness` applies (the `data.dart` itself, or the nearest `route.dart` above it, relative to the project root like `file`), e.g. `"freshness":"lib/app/teams/$teamId/route.dart"` |
| `cache`     | its `data.dart` has a [`dataCache`](data.md#a-cache-that-survives-a-restart-datacache)                  | `"cache":true`                                                                                                                                                                                     |

The manifest does not carry `freshness` or `cache`.
