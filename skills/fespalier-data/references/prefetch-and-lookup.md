# Typed helpers, prefetch handles, `dataAt` and `match`

As of v0.5.0. Every route with a `data.dart` has helpers next to `.data` and
`.refresh`; two generated functions on `AppRoutes` go from a **location** to its
data; and Riverpod stays in charge throughout.

The samples use this small app.

```dart
// lib/products.dart
class Product {
  const Product(this.id, this.name);

  final int id;
  final String name;
}

Future<Product> fetchProduct(int id) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  if (id > 100) throw StateError('no product $id');
  return Product(id, 'Product $id');
}
```

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/products.dart';

Future<Product> data(Ref ref, {required int id}) => fetchProduct(id);
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/products.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => Text(product.name);
}
```

```dart
// lib/app/products/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/products.dart';

final data = FutureProvider<List<Product>>(
  (ref) async => [for (var i = 1; i <= 3; i++) Product(i, 'Product $i')],
);
```

## The typed helpers

```dart
final product = ProductRoute.watch(ref, id: 42);      // AsyncValue<Product>, for build()
final p = await ProductRoute.read(ref, id: 42);       // Future<Product>, for callbacks
final warm = ProductRoute(id: 42).prefetch(ref);      // a PrefetchHandle, before navigating
await ProductRoute(id: 42).refresh(ref);              // re-runs data.dart
ref.watch(ProductRoute.data(42));                     // the provider itself
```

- **`watch` and `read` are static**, and take the keys the provider uses as
  **named arguments** (`ItemRoute.watch(ref, shop: 'a', id: 1)`,
  `SearchRoute.watch(ref, q: 'ap', page: 2)`; none for a route without keys).
  They cannot be instance methods: `ProductRoute(id: 42).watch(ref)` would have
  to write `AsyncValue<Product>` into the generated file, which never copies
  your imports. A static function value takes its type from the provider by
  inference, so `Product` flows through and is never `dynamic`. `prefetch`,
  `refresh`, `go` and `location` do not return your data and are instance
  members.
- **`read` keeps the provider alive until it completes**, which a plain
  `ref.read(p.future)` does not for an `autoDispose` provider. **Do not call it
  from `build`.**
- `watch`, `read`, `prefetch`, `preload`, `refresh`, `ref` and `keepFor` cannot be
  segment or query names (`preload` since 0.5.0; nor, since 0.5.0, `of`, `maybeOf`
  and `copyWith`: see `fespalier-routing`).

## Prefetch

The generated providers are `autoDispose`: with nothing listening, one is
dropped at the end of the frame, and the warm value with it. `prefetch(ref)`
starts the load and returns a **`PrefetchHandle`** that keeps the provider alive
**until you call `close()`**, so the page you navigate to next shows the value at
once. Call it before `go`, for example on hover:

```dart
// lib/app/products/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/products.dart';

class ProductsPage extends ConsumerStatefulWidget {
  const ProductsPage({super.key, required this.products});

  final List<Product> products;

  @override
  ConsumerState<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends ConsumerState<ProductsPage> {
  PrefetchHandle? _warm;

  @override
  void dispose() {
    _warm?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final p in widget.products)
        MouseRegion(
          onEnter: (_) => _warm = ProductRoute(id: p.id).prefetch(ref),
          onExit: (_) => _warm?.close(),
          child: TextButton(
            onPressed: () => ProductRoute(id: p.id).go(context),
            child: Text(p.name),
          ),
        ),
    ],
  );
}
```

- **How long is yours to decide.** An app's prefetch queue holds one handle per
  lease and closes it when the lease ends. `keepFor:` is an optional auto-close
  (`prefetch(ref, keepFor: Duration(seconds: 30))` closes the handle after that
  long). **The default changed in 0.3.0**: a prefetch used to lapse after 30
  seconds without a `keepFor`; now it lasts until closed, and
  `prefetchKeepAlive` is gone. A `prefetch(ref)` whose handle is dropped lasts as
  long as the widget behind `ref`.
- **A failed load is not kept**: the handle closes itself, so the page starts a
  fresh load instead of showing an error nobody asked for yet.
- Closing twice is fine, and `handle.isClosed` tells. The subscription also ends
  when the widget whose `ref` you pass is disposed; since 0.5.0 that also closes the
  handle and cancels its `keepFor` timer (before, the timer ran on after the widget).
- `keepFor` holds a **timer** while the widget lives, so a widget test that uses it
  should `pump` past it, or pass `Duration.zero`, which starts the load and keeps
  nothing (the handle comes back closed).
- Under the routes: `ref.prefetchData(provider, {keepFor})` for any
  `ProviderListenable<AsyncValue<...>>`, and `ref.prefetchAll(providers,
{keepFor})` for several at once, closed together by one handle (and, since 0.5.0,
  all closed when one of them fails).

## Preloading the data behind a link

`prefetch` warms a route's **own** `data.dart`. A page usually reads more: the
data of each [section](sections.md) above it. **`preload`** (since 0.5.0) starts
all of it, the list `dataAt` gives for the route's location, and returns **one**
`PrefetchHandle` that closes every provider:

```dart
final warm = ProductRoute(id: 42).preload(ref);        // on every route that has data
final byUri = AppRoutes.preload(ref, Uri.parse('/products/42'));   // from a location
// ... when the lease ends:
warm.close();
byUri.close();
```

- It is `ref.prefetchAll(<the page's providers>)` underneath, so the rules of a
  `PrefetchHandle` hold: kept until `close()` (or `keepFor:`), closing twice is
  fine, and **a failed load is not kept**. With several providers, one failure
  closes the whole handle (since 0.5.0), so a retry starts them all fresh.
- A route with **no data at all, and none above it**, has no generated `preload`;
  it inherits one that returns a closed handle. `AppRoutes.preload` does the same
  for a location no route fits, or a segment that does not parse (the
  `not_found.dart` rule), without throwing.
- **It never navigates and runs no `guard.dart` or `redirect.dart`.** A guard runs
  when the user arrives; preloading is only the load, so a link to a guarded page
  can be preloaded for a user who will be redirected: that costs a request, not
  access.
- Two preloads of one provider (two links to the same product) load it **once**.
- `RouteLink` calls it for you: `RouteLink(to: ..., preload: Preload.intent)`
  starts it on hover, focus or touch, `Preload.visible` when the link is on screen,
  and closes the handle when the link is disposed or leaves the screen (see
  [`fespalier-routing`](../../fespalier-routing/references/links.md)). Use `preload`
  directly for a queue of your own (the next page of a list, a swipe target).

## From a location to its data

An app's own prefetch layer often starts from a **location** (the next page a
list points at), not from a route it built by hand. Two generated functions on
`AppRoutes` answer that from the tree, without a table of your own:

```dart
final providers = AppRoutes.dataAt(Uri.parse('/products/42'));
// [ProductRoute.data(42)]: the provider the page watches, so warming it warms the page.
final handle = ref.prefetchAll(providers ?? const []);   // one PrefetchHandle for them all
// ... later, when your queue's lease ends:
handle.close();
```

`dataAt(uri)` is a `List<ProviderListenable<AsyncValue<Object?>>>?`, **outermost
first**: the `data.dart` of each [section](sections.md) above the route, then its
own.

- **`null`** when no route fits the location, or when a segment does not parse
  (`/products/abc` where the id is an `int`): the rule that shows
  `not_found.dart`.
- **Empty** for a route without data (a page, or a catch-all with nothing behind
  it): a match, with nothing to warm.
- The key is built by the same parser the route uses:
  `dataAt(Uri.parse('/products/42')).single == ProductRoute.data(42)`; for a
  selector it is the **selected provider itself**. Query-keyed data is keyed by the
  query of the location (lists as the `QueryList` the page's key uses); a
  catch-all by its decoded path.
- The **mount point** (`AppRoutes.mount(at: '/shop')`) is taken off first, a
  location outside it is `null`, and each route matches its path by its own case
  setting. A localized spelling matches too. A typed catch-all parses each part
  like the page, so one that fails is no match.
- **Nothing else runs**: no `guard.dart`, no `redirect.dart`, no widget. A guard
  may well send the user somewhere else when they arrive; prefetching what they
  asked for is your queue's call.

`AppRoutes.match(uri)` is what `dataAt` is a shortcut for (`match(uri)?.data`).
It returns a `RouteMatch?` under the same rules:

```dart
final m = AppRoutes.match(Uri.parse('/products/42'))!;
m.info;    // the RouteInfo from the manifest: path '/products/:id', folder, meta, ...
m.params;  // {'id': 42}: the segments and query parameters, parsed
m.route;   // ProductRoute(id: 42), typed; m.route.location is its canonical spelling
m.data;    // the providers, as dataAt returns them
m.uri;     // the location it was given
```

Routes are tried **most specific first** (static parts, then `:param`s, then
catch-alls), the order go_router uses. `match` lives on the manifest
(`AppManifest.match`, forwarded by `AppRoutes`); with `output_manifest:` it is in
the manifest library. `AppRoutes.dataAt` and `AppRoutes.matchUrl` (a `UrlMatch`:
the route, params and data without the `RouteInfo`) always stay in
`app.g.dart`. **`RouteMatch` is fespalier's:** `package:fespalier/fespalier.dart`
hides go_router's own `RouteMatch` to make room for it; import
`package:go_router/go_router.dart` if you need that one.

## Riverpod interplay

- The app needs a **`ProviderScope`** above `MaterialApp.router`. `Ref`,
  `ProviderListenable`, `ConsumerWidget`, `HookConsumerWidget` and the rest come
  from `package:fespalier/fespalier.dart`, which re-exports hooks_riverpod 3 and
  flutter_hooks.
- `XRoute.data` is an ordinary family (or plain) provider: `ref.watch`,
  `ref.listen`, `ref.invalidate` and `ProviderScope(overrides: [...])` all work on
  it. The usual way to fake a backend is to override the provider your `data()`
  reads (the README's testing example does `apiProvider.overrideWithValue(FakeApi())`).
- For a **selector** `data.dart`, `XRoute.data` **is** the provider you selected
  (`CatalogRoute.data(1) == productProvider(1)`), so overriding `productProvider`
  overrides what the route shows too.
- A `data.dart` function runs inside an autoDispose provider. Do not `ref.watch`
  things the route should not reload on; `ref.read` in a callback, `ref.watch` in
  `build`, as anywhere in Riverpod 3.
- Retries and `keepAlive` follow the app's `ProviderScope(retry:)` unless a
  provider sets its own (see `loading-error-retry.md`).
