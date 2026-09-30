import 'package:flutter/material.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:trellis/trellis.dart';

class ProductsPage extends Screen<List<Product>> {
  const ProductsPage(super.data, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => RefreshIndicator(
        onRefresh: () => const ProductsRoute().refresh(ref),
        child: ListView(
          children: [
            for (final p in data)
              ListTile(
                title: Text(p.name),
                trailing: Text('€${p.price.toStringAsFixed(2)}'),
                onTap: () => ProductRoute(id: p.id).go(context),
              ),
          ],
        ),
      );
}
