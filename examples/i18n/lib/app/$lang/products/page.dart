import 'package:fespalier_tolgee/fespalier_tolgee.dart';
import 'package:flutter/material.dart';
import 'package:i18n/lang.dart';

/// `/en/products`, `/fr/produits`. A number in one string: the ICU plural of `products.stock`
/// picks the form of the language (`=0`, `one`, `other`).
class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, required this.lang});

  final Lang lang;

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  int _count = 1;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const TrText('products.title', style: TextStyle(fontSize: 32)),
      Text(context.tr('products.stock', {'count': _count})),
      TextButton(
        onPressed: () => setState(() => _count++),
        child: Text(context.tr('products.more')),
      ),
      TextButton(
        onPressed: _count == 0 ? null : () => setState(() => _count--),
        child: Text(context.tr('products.less')),
      ),
    ],
  );
}
