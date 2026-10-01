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
                // A real <a href="/products/2"> on the web (middle click, status
                // bar); a plain click goes through the router. Hovering, focusing
                // or touching a row starts loading the product, so its page is
                // there when the row is followed.
                RouteLink(
                  to: ProductRoute(id: p.id),
                  preload: Preload.intent,
                  builder: (context, follow) => ListTile(
                    title: Text(p.name),
                    trailing: Text('€${p.price.toStringAsFixed(2)}'),
                    onTap: follow,
                  ),
                ),
            ],
          ),
        ),
      );
}
