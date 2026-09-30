import 'package:fespalier/fespalier.dart';

/// A stand-in for what `riverpod_generator` writes for
/// `@riverpod Future<Product> product(Ref ref, String id)`: a family of
/// `FutureProvider`s that lives in the app, not under `lib/app/`. A route's
/// `data.dart` selects it (`catalog/$productId/data.dart`) instead of wrapping it.
class Product {
  const Product(this.id, this.name);

  final String id;
  final String name;
}

/// How many times each provider ran; the tests read them.
int productFetches = 0;
int featuredFetches = 0;
int reviewFetches = 0;

/// Runs of the `flaky` product, which fails its first two.
int flakyRuns = 0;

/// The app's own retry policy for its products: twice, 100 ms apart. It sits on
/// the provider, so it is the one that runs (the `ProviderScope` may set another).
Duration? productRetry(int retryCount, Object error) =>
    retryCount < 2 ? const Duration(milliseconds: 100) : null;

final productProvider = FutureProvider.autoDispose.family<Product, String>((
  ref,
  id,
) async {
  productFetches++;
  await Future<void>.delayed(const Duration(milliseconds: 10));
  if (id == 'bad') throw Exception('no product bad');
  if (id == 'flaky' && flakyRuns++ < 2) throw Exception('flaky product');
  return Product(id, 'Product $id');
}, retry: productRetry);

/// No family: `catalog/data.dart` selects it as it is.
final featuredProvider = FutureProvider.autoDispose<List<String>>((ref) async {
  featuredFetches++;
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return ['alpha', 'beta'];
});

/// A family keyed by a record, for the route that also takes a query parameter.
final reviewsProvider = FutureProvider.autoDispose
    .family<List<String>, ({String productId, int? page})>((ref, key) async {
  reviewFetches++;
  await Future<void>.delayed(const Duration(milliseconds: 10));
  return ['${key.productId} review, page ${key.page ?? 1}'];
});
