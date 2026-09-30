import 'package:features/catalog.dart';
import 'package:flutter/material.dart';

class ProductDetailPage extends StatelessWidget {
  const ProductDetailPage({super.key, required this.product});

  /// What data.dart's `ProviderListenable<AsyncValue<Product>>` yields, by type.
  final Product product;

  @override
  Widget build(BuildContext context) => Text(product.name);
}
