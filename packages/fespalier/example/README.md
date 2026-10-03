# fespalier example

A route is a folder under `lib/app/`; the files in it say what it does.

```
lib/app/
  page.dart                 /
  products/
    page.dart               /products
    data.dart               loads what /products shows
    $id/
      page.dart             /products/:id   (ProductPage(product: ...))
      data.dart             Future<Product> data(Ref ref, {required int id})
      error.dart            shown when data.dart throws
```

`lib/app/products/$id/page.dart` is a plain widget. `id` and the loaded `product` are
filled in by name and type:

```dart
class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});
  final Product product;

  @override
  Widget build(BuildContext context) => Text(product.name);
}
```

Run `fsp gen` (or `dart run fespalier gen`; `fsp watch` regenerates on every save) and mount
the router in `main.dart`:

```dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

import 'app.g.dart';

final _router = AppRoutes.router();

void main() => runApp(
      ProviderScope(child: MaterialApp.router(routerConfig: _router)),
    );
```

Navigate with the generated typed routes: `ProductRoute(id: 2).go(context)`.

Complete, runnable apps are in
[examples/](https://github.com/fespalier/fespalier/tree/main/examples): `shop`
(products, cart, a guarded checkout), `features` (every file kind) and `tabs`
(nested tab layouts).
