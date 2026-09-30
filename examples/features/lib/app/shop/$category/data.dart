import 'package:features/models/category.dart';
import 'package:fespalier/fespalier.dart';

/// How many times [data] ran; the tests read it.
int shopFetches = 0;

/// Keyed by an enum segment: an enum is hashable, so the generated provider is
/// keyed by the `Category` itself, and `dataAt('/shop/hats')` is the provider for
/// `Category.hats`.
Future<List<String>> data(Ref ref, {required Category category}) async {
  shopFetches++;
  return switch (category) {
    Category.shoes => ['sneaker', 'boot'],
    Category.hats => ['cap', 'beret'],
  };
}
