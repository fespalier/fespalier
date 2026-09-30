import 'package:trellis/trellis.dart';

class Product {
  const Product(this.id, this.name, this.price);

  final int id;
  final String name;
  final double price;
}

class ProductNotFound implements Exception {
  const ProductNotFound(this.id);

  final int id;

  @override
  String toString() => 'No product #$id';
}

final apiProvider = Provider((ref) => FakeApi());

/// Slow on purpose so loading.dart is visible. #13 fails once so error.dart
/// and retry are too.
class FakeApi {
  static const _all = [
    Product(1, 'Coffee beans, 500 g', 9.5),
    Product(2, 'Ceramic mug', 12),
    Product(3, 'Pour-over kettle', 38),
    Product(13, 'Flaky grinder (fails once)', 45),
  ];

  var _flakyFailed = false;

  Future<List<Product>> products() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return _all;
  }

  Future<Product> product(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (id == 13 && !_flakyFailed) {
      _flakyFailed = true;
      throw Exception('Network hiccup');
    }
    return _all.firstWhere((p) => p.id == id,
        orElse: () => throw ProductNotFound(id));
  }
}
