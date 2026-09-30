import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';

class ProductsPage extends ConsumerWidget {
  const ProductsPage({super.key, required this.products});

  /// What data.dart yields, matched by type.
  final List<Product> products;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
        // Pages sit below the layout's Scaffold, so give ListTile ink a
        // surface of its own (page transitions paint in between).
        type: MaterialType.transparency,
        child: RefreshIndicator(
          onRefresh: () => const ProductsRoute().refresh(ref),
          child: ListView(
            children: [
              for (final p in products)
                ListTile(
                  title: Text(p.name),
                  trailing: Text('€${p.price.toStringAsFixed(2)}'),
                  onTap: () => ProductRoute(id: p.id).go(context),
                ),
            ],
          ),
        ),
      );
}
