import 'package:adopt/app.g.dart';
import 'package:adopt/screens.dart';
import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// `/shop`: the products list, moved out of the old router. It is mounted under `/shop`, so
/// this is the tree's root page.
///
/// `products` is what data.dart returns (matched by type). The old `/products` forwards here.
class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key, required this.products});

  final List<Product> products;

  @override
  Widget build(BuildContext context) => ProductListView(
    products: products,
    onOpen: (product) => ProductRoute(id: product.id).go(context),
    // A legacy page: still a string, the host router owns it.
    onHome: () => context.go('/'),
  );
}
