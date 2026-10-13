import 'package:fespalier/fespalier.dart';

/// A pretend backend (not fespalier). Both the "before" app and the half-moved one use it.
class Product {
  const Product(this.id, this.name, this.price);

  final int id;
  final String name;
  final String price;
}

class ProductNotFound implements Exception {
  const ProductNotFound(this.id);

  final int id;

  @override
  String toString() => 'No product #$id';
}

const _catalog = [
  Product(1, 'Teapot', '24 €'),
  Product(2, 'Kettle', '39 €'),
  Product(3, 'Whisk', '9 €'),
];

/// How many times the catalog was fetched; the tests read it to see that `ready()` loads it once
/// and the routes reuse it.
int catalogLoads = 0;

Future<List<Product>> loadCatalog() async {
  catalogLoads++;
  return _catalog;
}

/// The catalog. A plain `FutureProvider` is not auto-dispose in Riverpod 3, so what `ready()`
/// loads is still there when the first route reads it.
final catalogProvider = FutureProvider<List<Product>>((ref) => loadCatalog());

/// One product out of the catalog. `retry: null`: a missing product is an answer, not a blip.
final productProvider = FutureProvider.family<Product, int>((ref, id) async {
  final all = await ref.watch(catalogProvider.future);
  return all.firstWhere(
    (p) => p.id == id,
    orElse: () => throw ProductNotFound(id),
  );
}, retry: (_, _) => null);

/// Something outside the widget tree (a notification, say) asks to open a product. In the
/// half-moved app `attach()` in startup.dart listens to it with the router in hand.
class OpenProduct extends Notifier<int?> {
  @override
  int? build() => null;

  void open(int id) => state = id;
}

final openProductProvider = NotifierProvider<OpenProduct, int?>(
  OpenProduct.new,
);
