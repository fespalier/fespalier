# Segments, query parameters and their types

As of v0.13.0. The type of a segment or query parameter comes from the
parameters that ask for it; nobody declares it in the folder name.

## Dynamic segments

`products/$id/` is `/products/:id`. **Every file that asks for `$id` must agree
on its type**; when nobody gives one it is a `String`.

```dart
// lib/products.dart
class Product {
  const Product(this.id, this.name);
  final int id;
  final String name;
}

Future<Product> fetchProduct(int id) async => Product(id, 'Product $id');
```

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/products.dart';

// `required int id` makes `$id` an int everywhere: ProductRoute(id: 42),
// the page, and parsing. `/products/abc` is not found.
Future<Product> data(Ref ref, {required int id}) => fetchProduct(id);
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/products.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product, this.tab});

  final Product product; // what data.dart yields: filled by type
  final String? tab; //      optional and nullable: ?tab=

  @override
  Widget build(BuildContext context) =>
      Text('${product.name} (${tab ?? 'info'})');
}
```

- A segment is `String`, `int`, `double`, `bool` or an app enum. `bool` reads
  `true` and `false` only.
- **An unparsable segment** (`/products/abc`) shows the nearest `not_found.dart`:
  the page is never built and **no guard runs**. A bad **query** parameter never
  does that; it reads as `null`.
- `fsp new 'products/[id]'` scaffolds every segment as a `String`. Change the
  type in every file that asks for it, then regenerate.
- A segment name must be a lowerCamel identifier and cannot be a reserved name
  (`fespalier/references/binding-rules.md`).
- A segment cannot repeat down one path (`p/$id/q/$id`): `` `$id` is already a segment higher up this path ``.

## Query parameters

An **optional** parameter that is nullable, or an optional `List`, of `String`,
`int`, `double`, `bool` or an enum is a query parameter. The typed route takes
it as an optional argument and writes it into `.location`, leaving out nulls
and empty lists.

```dart
// lib/app/search/data.dart
import 'package:fespalier/fespalier.dart';

Future<List<String>> data(
  Ref ref, {
  String? q,
  int? page,
  List<String> tags = const [],
}) async => [for (final t in tags) '$q:$t:${page ?? 1}'];
```

```dart
// lib/app/search/page.dart
import 'package:flutter/material.dart';

class SearchPage extends StatelessWidget {
  const SearchPage({
    super.key,
    required this.hits,
    this.q,
    this.tags = const [],
  });

  final List<String> hits; // required, and data.dart's type: the data
  final String? q; //         optional and nullable: ?q=
  final List<String> tags; // optional List: every ?tags=

  @override
  Widget build(BuildContext context) => Text('${hits.length} hits for $q');
}
```

- `data.dart` may take query parameters too; its provider is then keyed by
  them, so `?page=2` and `?page=3` load separately. A `List` key is wrapped in a
  `QueryList` (value equality, exported by fespalier), so `?tags=a&tags=b` is
  one provider however many times the page builds a new list. Order counts:
  `[a, b]` and `[b, a]` are different keys. `data()` still receives a plain
  `List`.
- A provider you write yourself (`final data = FutureProvider.family<...>`)
  can be keyed by **segments only**, not by a query parameter.
- Every file of a route that names `?page` must agree on its type:
  `` `?page` is String? in s/data.dart:2 but int? here ``.
- **The trap:** any optional nullable `String?`, `int?`, ... parameter of a
  route file is a query parameter, including one you meant as widget
  configuration. Keep such parameters on inner widgets.
- A query parameter cannot be called a member of the route class (`location`,
  `go`, `push`, `replace`, `refresh`, `watch`, `read`, `prefetch`, `ref`,
  `keepFor`, `hashCode`, and since 0.5.0 `of`, `maybeOf`, `copyWith`).

## Enum segments, query parameters and catch-all parts

A segment, a query parameter and the parts of a catch-all can be an **enum of
your app**, typed in the file that asks.

```dart
// lib/models/category.dart
enum Category { shoes, hats }

enum Sort { price, name }
```

```dart
// lib/app/shop/$category/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/models/category.dart';

class ShopPage extends StatelessWidget {
  const ShopPage({super.key, required this.category, this.sort});

  final Category category; // the segment: /shop/shoes
  final Sort? sort; //        the query:   ?sort=price

  @override
  Widget build(BuildContext context) =>
      Text('${category.name} by ${sort?.name ?? 'default'}');
}
```

- **Read by name** (`Category.values.byName`): `/shop/shoes` is `Category.shoes`;
  `/shop/socks` names no value, so it is a `BadSegment` and shows `not_found.dart`
  like a bad `int`. A query parameter that names none is `null`.
- **Case follows the route.** Names match exactly by default; where the route
  matches in any case (`case_sensitive: false` or a `route.dart`), `/shop/SHOES`
  is `Category.shoes` too. An exact match always wins.
- **Written by name:** `.location` writes `.name`, and the typed route's field has
  the enum's type: `ShopRoute(category: Category.hats, sort: Sort.price)` is
  `/shop/hats?sort=price`.
- **`fsp` has to find the declaration** to tell an enum from a class: in the
  file that names the type, or in a file it imports (relative or `package:` of
  your own app, through `export`s, and through an import prefix `m.Category`).
  `dart:` and other packages are not read. A type it finds no enum for is an
  error that suggests taking a `String` and parsing it in the page, and a
  **private** enum (`_Mode`) is an error too.
- Two files must agree on the enum: `Category` here and `Size` there is the
  usual mismatch error. Two different enums with one name are a mismatch.
- `data.dart` can be keyed by an enum (it is hashable).
  `ShopRoute.watch(ref, category: Category.hats)` takes it, and
  `AppRoutes.match(uri).params` and `dataAt` have the enum values.
- An enum is read by `name` only. A non-nullable `Sort sort = Sort.price` is **not** a
  query parameter, as for `int`.
- `fsp new` below an enum segment writes its type name into the new files; you
  add the import.
- **Not in a deferred page (since 0.7.0).** An enum declared in the `page.dart` of a
  [deferred](route-dart.md#deferred-load-a-pages-code-on-demand) route is named by the
  generated file outside the page, which Dart forbids for a deferred library, so `fsp`
  reports it (G4, `fespalier-troubleshooting`) and says to move the enum to a file of its own,
  as `lib/models/category.dart` above. An enum declared in a page that is not deferred is
  fine for a deferred child.
- **A language folder is this pattern** (since 0.10.0): `lib/app/$lang/products/page.dart` with
  `enum Lang { en, fr, de }` makes `/xx/products` not found, **but only if some file of the folder asks for
  `required Lang lang`**. A segment's type comes from the parameters that ask for it, so with no such parameter `$lang`
  is a `String` and `/xx/products` matches. `fespalier_tolgee` reads the segment as the locale
  ([`fespalier-i18n`](../../fespalier-i18n/references/locales-and-the-url.md)); a tag that is not an identifier
  (`pt-BR`) cannot be an enum name, so use a `String` segment there.

## Catch-all segments

`$$rest` matches **one or more** remaining segments and `$$$rest` **zero or
more**. The parameter is a `List`, each part decoded on its own.

```dart
// lib/app/docs/$$rest/page.dart
import 'package:flutter/material.dart';

class DocsPage extends StatelessWidget {
  const DocsPage({super.key, required this.rest});

  final List<String> rest; // `rest` is the folder's name

  @override
  Widget build(BuildContext context) => Text(rest.join(' > '));
}
```

```dart
// lib/app/files/$$$path/page.dart
import 'package:flutter/material.dart';

class FilesPage extends StatelessWidget {
  const FilesPage({super.key, required this.path});

  final List<String> path;

  @override
  Widget build(BuildContext context) => Text('files: ${path.length}');
}
```

```dart
// lib/app/compare/$$ids/page.dart
import 'package:flutter/material.dart';

// A typed catch-all: each part is read as an int.
class ComparePage extends StatelessWidget {
  const ComparePage({super.key, required this.ids});

  final List<int> ids;

  @override
  Widget build(BuildContext context) => Text('comparing ${ids.join(', ')}');
}
```

| Folder           | URL                    | Value                          |
| ---------------- | ---------------------- | ------------------------------ |
| `docs/$$rest/`   | `/docs/guide/setup`    | `['guide', 'setup']`           |
| `files/$$$path/` | `/files`, `/files/a/b` | `[]`, `['a', 'b']`             |
| `compare/$$ids/` | `/compare/3/7/12`      | `[3, 7, 12]`                   |
| `compare/$$ids/` | `/compare/3/x`         | not found: `x` is not an `int` |

- **Typed parts:** `List<int>`, `List<double>`, `List<num>`, `List<bool>`,
  `List<DateTime>` (what `DateTime.tryParse` reads; written as ISO 8601), or a
  `List` of an enum. A part that does not parse sends the **whole route** to
  `not_found.dart`. Anything else (`List<Object>`, `List<int?>`, `Set<int>`) is
  an error that lists what a catch-all can be.
- **Location:** `DocsRoute(rest: ['guide', 'a b']).location` is
  `/docs/guide/a%20b`, each part encoded; an encoded slash survives
  (`/docs/a%2Fb/c` is `['a/b', 'c']`). `FilesRoute().location` is `/files`.
- **How it routes:** a catch-all folder becomes go_router's `:rest(.+)`;
  `$$$rest` is two routes with one builder (`/files` and `/files/:path(.+)`).
- **Order:** siblings are tried static, then dynamic (`docs/$id`), then the
  catch-all, whatever the folder order. A page another route always catches
  first is reported as unreachable, catch-alls included.
- **Limits:** a catch-all is the **last** segment; **nothing can go below it**
  (`a catch-all matches the rest of the path, so no route can go below it`); it
  cannot have a `not_found.dart`; `$$$rest` and a `page.dart` in the folder above
  both serve `/docs` (an error: use `$$rest` beside the page). `.` and `..`
  parts are read as dot segments by the URL parser, so `DocsRoute(rest: ['..'])`
  cannot reach a `..` part. A catch-all as a tab's first route needs a
  `tabOptions` `initialLocation`.
- **`data.dart`** can take the parts (`{required List<String> rest}`); the
  provider is keyed by the encoded path (`restKey`) and `data()` gets the list
  back (`restParts`). A provider **you write yourself** cannot be keyed by a
  catch-all: use the function form or a selector.
- `fsp new 'docs/[...rest]'` and `'docs/[[...rest]]'` write the folders.

## Sibling order and unreachable routes

go_router takes the first route that fully matches, so `fsp` puts static
routes before dynamic ones before catch-alls: `/about` comes before `/:slug`.
Two pages at one URL are an error (`(a)/x` and `(b)/x`: `/x is served by both ...`).
A group's routes stay together in one `ShellRoute`, so **a group holding a
dynamic route cannot be sorted around a dynamic sibling outside it**, and the
page behind it is an error:

```text
error: /settings is unreachable: $a/page.dart (/:a) comes first and matches it;
       move one of them into or out of its (group)
```

Move one into or out of its group.

## Typed use, in one place

```dart
// lib/app/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/models/category.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextButton(
        onPressed: () => const ProductRoute(id: 42).go(context),
        child: const Text('Product 42'),
      ),
      TextButton(
        onPressed: () => const SearchRoute(q: 'ap', page: 2).go(context),
        child: const Text('Search'),
      ),
      TextButton(
        onPressed: () => const ShopRoute(
          category: Category.hats,
          sort: Sort.price,
        ).go(context),
        child: const Text('Hats'),
      ),
      TextButton(
        onPressed: () => const DocsRoute(rest: ['guide', 'a b']).go(context),
        child: const Text('Docs'),
      ),
      TextButton(
        onPressed: () => const CompareRoute(ids: [3, 7, 12]).go(context),
        child: const Text('Compare'),
      ),
    ],
  );
}
```

`ProductRoute(id: 42)` is `const` when its arguments are; the route class is
named after the page class (`ProductPage` becomes `ProductRoute`; `Page`,
`Screen` or `View` is dropped).
