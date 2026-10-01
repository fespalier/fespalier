# The three forms of `data.dart`

As of v0.4.0. `data.dart` is told apart by **what it exports**. Beside a
`page.dart` it feeds that page: the page is only built once the data has
arrived, `loading.dart` shows meanwhile and `error.dart` if it fails.

| You write                                                                                                                                      | fespalier                                                                     | Use it when                                                                                      |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `Future<T> data(Ref ref, {...})` (or `Stream<T>`, or `T`)                                                                                      | wraps it in an autoDispose `FutureProvider` (`StreamProvider` for a `Stream`) | the data is fetched for this route only: the function is the fetch                               |
| `ProviderListenable<AsyncValue<T>> data({...}) => productProvider(id)`                                                                         | calls it and uses the provider it returns; **nothing is wrapped**             | a provider for it already exists, above all a `riverpod_generator` one                           |
| `final data = FutureProvider<T>(...)` (or `StreamProvider`, `AsyncNotifierProvider`, `StreamNotifierProvider`), **type arguments spelled out** | uses it as is                                                                 | you write the provider yourself (a notifier, `keepAlive`, `retry:`) and it belongs to this route |

The samples below share a tiny backend.

```dart
// lib/products.dart
import 'package:fespalier/fespalier.dart';

class Product {
  const Product(this.id, this.name);

  final int id;
  final String name;
}

Future<Product> fetchProduct(int id) async {
  await Future<void>.delayed(const Duration(milliseconds: 50));
  if (id > 100) throw StateError('no product $id');
  return Product(id, 'Product $id');
}

final productProvider = FutureProvider.autoDispose.family<Product, int>(
  (ref, id) => fetchProduct(id),
);
```

## 1. A function

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

  final Product product; // what data.dart yields: filled by type

  @override
  Widget build(BuildContext context) => Text(product.name);
}
```

- The first parameter must be **`Ref ref`** (positional), then **named** parameters
  that are segments or query parameters (`data() must take Ref ref first`;
  `data() takes segments as named parameters, e.g. {required int id}`). The return
  type must be explicit (`Future<T>`, `FutureOr<T>`, `Stream<T>` or `T`).
- A parameter that is neither a segment of the path nor an **optional nullable**
  (or `List`) query parameter is an error naming it.
- The page gets the data **by type** (`required this.product`), or by the
  parameter name `data`. A page that ignores its `data.dart` only warns.
- **Keys.** The route exposes it as `XRoute.data`, keyed by the segments and
  query parameters `data.dart` uses:

  | Parameters used | Provider                              | Watch it with                                   |
  | --------------- | ------------------------------------- | ----------------------------------------------- |
  | none            | plain                                 | `ref.watch(ProductsRoute.data)`                 |
  | one             | `.family<T, int>`                     | `ref.watch(ProductRoute.data(42))`              |
  | several         | `.family<T, ({String shop, int id})>` | `ref.watch(ItemRoute.data((shop: 'a', id: 1)))` |

- A `List` query parameter is keyed by a `QueryList`; a catch-all by its encoded
  path (`restKey`); an enum by the enum. All three are handled for you when you
  write the function form or a selector.

## 2. A selector

Do **not** write `Future<Product> data(Ref ref, ...) => ref.watch(productProvider(id).future)`
for a provider you already have: that puts a second provider in front of the
real one, and awaiting `.future` drops the error the real provider **holds while
it retries**, so the route cannot show `error.dart` during the retry window.
Select the provider instead:

```dart
// lib/app/catalog/$id/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/products.dart';

ProviderListenable<AsyncValue<Product>> data({required int id}) =>
    productProvider(id);
```

```dart
// lib/app/catalog/$id/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/products.dart';

class CatalogPage extends StatelessWidget {
  const CatalogPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => Text('catalog: ${product.name}');
}
```

- **The return type is what says so**: `ProviderListenable<AsyncValue<T>>` with
  **no `Ref` parameter** (a `Ref` there is an error). `T` is what the page's
  parameter is matched to by type. `ProviderListenable` is exported by
  `package:fespalier/fespalier.dart`. It is a syntax-only read of the return
  type, so a generated provider's own type (`ProductFamily`) is never resolved.
- **Parameters are the function form's**: named segments and query parameters,
  keyed and typed the same; any other parameter is an error at it.
- **`XRoute.data` is the selected provider** (`CatalogRoute.data(1) ==
productProvider(1)`), and `watch`, `read`, `prefetch` and `refresh` all go to
  it. The generated `DataView` watches it directly: one fetch per navigation.
  `refresh` (and `error.dart`'s `retry`) **invalidates the selected provider**.
- **The app's provider keeps its own `retry`, `keepAlive` and dependencies**, so
  `data_retry` does **not** apply to it (it only configures providers fespalier
  creates). `keep_previous` does (it is about what the view shows).
- **Refresh needs a provider, not just a listenable.** The declared type stays
  `ProviderListenable<AsyncValue<T>>` for every kind of provider and the runtime
  checks what it gets: a provider with a `.future` (every `FutureProvider`,
  `StreamProvider` and generated async provider). Returning something else, say
  `productProvider(id).select(...)`, builds and watches fine, but `refresh` and
  `retry` throw a `StateError` ("Return the provider itself from data()").
- A section's `data.dart` may be a selector too (segments and query, see
  `sections.md`).

## 3. A provider you write

```dart
// lib/app/products/data.dart
import 'package:fespalier/fespalier.dart';
import 'package:my_app/products.dart';

final data = FutureProvider<List<Product>>(
  (ref) async => [for (var i = 1; i <= 3; i++) Product(i, 'Product $i')],
);
```

```dart
// lib/app/products/page.dart
import 'package:flutter/material.dart';
import 'package:my_app/products.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key, required this.products});

  final List<Product> products;

  @override
  Widget build(BuildContext context) => Text('${products.length} products');
}
```

```dart
// lib/app/inbox/data.dart
import 'package:fespalier/fespalier.dart';

class InboxNotifier extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async => ['welcome'];

  void add(String message) =>
      state = AsyncData([...?state.value, message]);
}

final data = AsyncNotifierProvider<InboxNotifier, List<String>>(
  InboxNotifier.new,
);
```

```dart
// lib/app/inbox/page.dart
import 'package:flutter/material.dart';

class InboxPage extends StatelessWidget {
  const InboxPage({super.key, required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) => Text(messages.join(', '));
}
```

- Allowed: `FutureProvider`, `StreamProvider`, `AsyncNotifierProvider`,
  `StreamNotifierProvider`. **Spell the type arguments out**:
  ``give the provider its type arguments, e.g. `FutureProvider<Product>` ``.
  Anything else (`Provider<int>`) is an error.
- A **family** you write is keyed by **segments only**: one segment keys it by the bare
  value (`FutureProvider.family<Product, int>`), several need a **record** naming the
  ones it uses (error: _this path has 2 segments, so the family argument must be a
  record naming the ones it uses_).
- A provider you write **cannot be keyed by a query parameter** (a record field such as
  `({int id, int? page})` is rejected: _page isn't a segment of this path ($id); a
  provider you write can be keyed by segments only_; on 0.3.0 the message was a misleading
  _make it optional and nullable_ and the README said such a record was allowed) and
  **not by a catch-all** (a `List` compares by identity): use the function form or a
  selector for those.
- It keeps the app's retry policy (or its own `retry:`); `data_retry` does not
  apply.

## Streams and plain values

`Stream<T> data(Ref ref)` is wrapped in a `StreamProvider` and the page gets each
`T`. A plain `T data(Ref ref)` (or `FutureOr<T>`) is accepted too and wrapped like
the function form.

```dart
// lib/app/ticks/data.dart
import 'package:fespalier/fespalier.dart';

Stream<int> data(Ref ref) => Stream.periodic(
  const Duration(milliseconds: 10),
  (i) => i,
).take(3);
```

```dart
// lib/app/ticks/page.dart
import 'package:flutter/material.dart';

class TicksPage extends StatelessWidget {
  const TicksPage({super.key, required this.tick});

  final int tick;

  @override
  Widget build(BuildContext context) => Text('tick $tick');
}
```

## Several keys

```dart
// lib/app/shops/$shop/items/$id/data.dart
import 'package:fespalier/fespalier.dart';

Future<String> data(Ref ref, {required String shop, required int id}) async =>
    '$shop #$id';
```

```dart
// lib/app/shops/$shop/items/$id/page.dart
import 'package:flutter/material.dart';

class ItemPage extends StatelessWidget {
  const ItemPage({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Text(label);
}
```

`ItemRoute.data((shop: 'a', id: 1))` is the provider; `ItemRoute.watch(ref, shop:
'a', id: 1)` the typed shortcut (see `prefetch-and-lookup.md`).

## Forms that are errors

| Symptom in `data.dart`                                     | Message (abridged)                                                                                                        |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `Future<int> data()`                                       | `data() must take Ref ref first`                                                                                          |
| `data(Ref ref) async => 1`                                 | `data() needs an explicit return type (Future<T>, Stream<T> or T)`                                                        |
| `final data = 3;`                                          | `data must be a FutureProvider, StreamProvider, AsyncNotifierProvider or StreamNotifierProvider`                          |
| `final data = FutureProvider((ref) ...)`                   | ``give the provider its type arguments, e.g. `FutureProvider<Product>` ``                                                 |
| `ProviderListenable<AsyncValue<int>> data(Ref ref)`        | ``a data() that returns a `ProviderListenable` takes no `Ref` ``                                                          |
| `ProviderListenable<int> data()`                           | ``a data() that selects a provider must return `ProviderListenable<AsyncValue<T>>` ``                                     |
| a file with neither function nor variable                  | ``expected `Future<T> data(Ref ref, {...segments})`, ...``                                                                |
| `data.dart` with no `page.dart` or `layout.dart` beside it | `data.dart has no page.dart to feed; with a layout.dart beside it, it would be the data of the section below that layout` |
