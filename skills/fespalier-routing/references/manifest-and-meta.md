# The route manifest and `meta.dart`

As of v0.4.0. The generator knows a lot about every route (typed route, path, folder,
groups, layouts, parameters), and only a person can write the rest: a stable review code,
a page title, an analytics name. The manifest puts the first at runtime next to the
second.

```dart
// lib/page_meta.dart
class PageMeta {
  const PageMeta({required this.code, required this.title});

  final String code;
  final String title;
}
```

```dart
// lib/app/products/$id/meta.dart
import 'package:my_app/page_meta.dart';

const meta = PageMeta(code: 'B04', title: 'Product');
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

```dart
// lib/app/meta.dart
import 'package:my_app/page_meta.dart';

const meta = PageMeta(code: 'A01', title: 'Home');
```

```dart
// lib/app/layout.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/page_meta.dart';

class AppLayout extends StatelessWidget {
  const AppLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The route this layout is showing; null in a not-found view.
    final info = AppManifest.of(GoRouterState.of(context));
    return Title(
      title: info?.metaAs<PageMeta>()?.title ?? 'My app',
      color: Theme.of(context).colorScheme.primary,
      child: Scaffold(body: child),
    );
  }
}
```

```yaml
# pubspec.yaml
fespalier:
  meta_unique: [code]
```

## What the manifest holds

`AppRoutes.all`, `byType` (typed-route class to info) and `byPath` (path template to info)
are generated as `AppManifest`, a `const` list of `RouteInfo`s, and forwarded by
`AppRoutes`:

```dart
final info = AppRoutes.byType[ProductRoute]!;   // or AppRoutes.byPath['/products/:id']
info.path;      // '/products/:id'
info.folder;    // r'products/$id'
info.groups;    // ['(buyer)'] when the folder is inside groups
info.meta;      // whatever meta.dart declares
AppRoutes.all;  // every route, in the order of the table at the top of app.g.dart
```

| `RouteInfo` field   | Meaning                                                                                                                                                                                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `type`              | the typed-route class (`ProductRoute`)                                                                                                                                                                                                                        |
| `path`              | the path template **without the mount point**: `/products/:id`; a catch-all is `/docs/*rest`, or `/files/*path?` when optional. `case_sensitive: false` does not change it                                                                                    |
| `paths`             | the path in each locale its folders spell it in; empty without localized paths; `pathFor(locale)` picks one, falling back to `path`                                                                                                                           |
| `folder`            | the route's folder relative to the app folder (`products/$id`; empty for the app folder itself)                                                                                                                                                               |
| `presentation`      | `RoutePresentation.page`, `.redirect` (`isRedirect`), `.root` (through `navigator.dart`), `.custom` (a `present.dart` builds the page)                                                                                                                        |
| `sibling`           | `true` for a route declared `nest = false` (since 0.7.0), a sibling of the page above it with a compound path ([`route-dart.md`](route-dart.md#nest--false-a-sibling-with-a-compound-path)); `false` for every other route. The `sibling` tag of `fsp routes` |
| `groups`            | the `(group)` folders above it, outermost first, parentheses included                                                                                                                                                                                         |
| `layouts`           | the folders of the layouts that wrap it, outermost first (`''` is the app folder's own layout)                                                                                                                                                                |
| `segments`, `query` | `RouteParam(name, type)`: `('id', 'int')`, `('page', 'int?')`, `('tags', 'List<String>')`; a catch-all is the last segment, with `catchAll: true`                                                                                                             |
| `tabs`              | the tabs it sits in, outermost first: `RouteTab(layout, index, branch)`; empty outside tab layouts                                                                                                                                                            |
| `dataKeys`          | what its `data.dart` is keyed by; `null` without one                                                                                                                                                                                                          |
| `meta`              | its `meta.dart`, as declared                                                                                                                                                                                                                                  |

`AppManifest.of(GoRouterState)` finds the route a layout is showing (`null` in a not-found
view): it looks the path up in `byPath` after taking `AppRoutes.base` off, so it works under
`AppRoutes.mount(at: '/shop')`, for catch-all routes and at any localized spelling. The same
lookup gives analytics screen names (`info.path`, or a name in your meta) from a
`NavigatorObserver`. `AppManifest.match(uri)` finds a route for a **location** (see
`fespalier-data`).

## `meta.dart`

`const meta = <any const expression>;` beside a `page.dart` or `redirect.dart`. The generator
copies it into the manifest **by reference** (`meta: _i7.meta`), never re-spelling it;
fespalier does not interpret it, so use any type.

- **It is per route, not inherited.** A route gets its own folder's `meta.dart` or none, so
  `photos/sort/` does not see `photos/meta.dart`. To share something (a role, say), keep it in
  the group: `info.groups` already lists it.
- **It must be `const`.** The manifest is a `const` list. A `meta` that is `final`, `var` or a
  getter is an error at its declaration (_`meta` must be `const` (the route manifest lists it in a const list)_), and so is a `meta.dart`
  that declares no `meta`. A `meta.dart` in a folder with no `page.dart` or `redirect.dart` is a
  **warning**: it describes no route.
- **It can be required.** `fespalier: { meta: required }` makes a route without a `meta.dart` an
  error that names its folder. fespalier never numbers, derives or defaults anything in it.
- **Its values can be unique.** `meta_unique: [code, slug]` reads the **literal** named arguments
  of `meta`'s constructor call (a string, number or bool) in every route's `meta.dart` and
  reports a value two routes share, naming both files. An argument that is an expression, or one a
  route leaves out, is skipped; a listed name no `meta.dart` gives a literal is a **warning**
  (probably a typo). Anything more (a pattern for the code, unique across tabs only) is a few
  lines in a test over `AppRoutes.all` and `metaAs`.
- **Read it typed** with `info.metaAs<PageMeta>()` (`null` when the route has none or it is
  another type), or `info.meta is PageMeta`. The list holds `RouteInfo<Object?>`.

## A library of its own: `output_manifest`

`meta.dart` files pull whatever they import into `app.g.dart`, and so into your app. To keep
review-only metadata out of production code, write the manifest to a second file:

```yaml
fespalier:
  output_manifest: lib/app.routes.g.dart
```

`app.g.dart` then has no manifest and no `meta.dart` import, and `lib/app.routes.g.dart` (which
imports `app.g.dart` for the typed routes) holds `AppManifest` with the same `all`, `byType`,
`byPath`, `of` and `match`. Import it only where you need it (tests, a review screen), and
production code that imports `app.g.dart` alone never sees a `meta.dart`. `AppManifest` is the
same name in both modes, so code that uses it does not change when you move the file;
**`AppRoutes.all`, `byType`, `byPath` and `match` exist only when the manifest is in
`app.g.dart`.** `fsp gen` writes both files, `fsp check` checks what either would say, `fsp
watch` regenerates both, and both are committed. The path must be a `.dart` file under `lib/`
and differ from `output`.

## `fsp routes --json`

Prints the same data, one object per route, with `pattern`, `route`, `file`, `tags` and
`params` first, then the manifest's fields, in this order (`file` and `meta` are relative to the
project root; `folder`, `layouts` and `tabs[].layout` to the app folder):

```json
{"pattern":"/products/:id","route":"ProductRoute","file":"lib/app/products/$id/page.dart","tags":["transition"],"params":[{"name":"id","type":"int","in":"path"}],"folder":"products/$id","presentation":"page","groups":[],"layouts":[""],"tabs":[],"data_keys":null,"meta":"lib/app/products/$id/meta.dart","catch_all":null}
```

`presentation` is `page`, `redirect`, `root` or `custom`; `data_keys` and `meta` are `null`
without a `data.dart` or `meta.dart` (the meta itself is Dart, so JSON only says where it is);
`catch_all` is `{"name":"rest","optional":false}` for a route ending in a catch-all; a route with
localized paths has one more key, `paths`, after `catch_all`.
