import 'package:adopt/app.g.dart';
import 'package:adopt/screens.dart';
import 'package:adopt/shop.dart';
import 'package:flutter/material.dart';

/// `/shop/products/2`. `$id` is an int because data.dart asks for `required int id`, so
/// `/shop/products/abc` is not found and never reaches the page. The old `/products/:id`
/// forwards here.
class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) => ProductDetailView(
    product: product,
    onList: () => const ProductsRoute().go(context),
  );
}
