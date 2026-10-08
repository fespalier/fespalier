import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

// The screens, as plain widgets that know nothing about routing. The "before" app (lib/before/)
// and the half-moved one (lib/app/) both put these on screen, which is what lets
// test/parity_test.dart say that one URL opens the same screen in both.

/// `/`. Legacy code, untouched by the move: it still navigates by string, and the old URLs it
/// uses are redirected to the new routes.
class LegacyHome extends StatelessWidget {
  const LegacyHome({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Legacy home')),
    body: Column(
      children: [
        TextButton(
          onPressed: () => context.go('/products'),
          child: const Text('All products'),
        ),
        TextButton(
          onPressed: () => context.go('/products/2'),
          child: const Text('Featured: Kettle'),
        ),
        TextButton(
          onPressed: () => context.go('/legacy/orders/7'),
          child: const Text('Order 7'),
        ),
      ],
    ),
  );
}

/// `/legacy/orders/:id`. A page nobody has moved yet.
class LegacyOrderView extends StatelessWidget {
  const LegacyOrderView({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: Text('Order $id')));
}

class ProductListView extends StatelessWidget {
  const ProductListView({
    super.key,
    required this.products,
    required this.onOpen,
    required this.onHome,
  });

  final List<Product> products;
  final void Function(Product product) onOpen;
  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Products'),
      actions: [TextButton(onPressed: onHome, child: const Text('Home'))],
    ),
    body: ListView(
      children: [
        for (final p in products)
          ListTile(
            title: Text(p.name),
            subtitle: Text(p.price),
            onTap: () => onOpen(p),
          ),
      ],
    ),
  );
}

class ProductDetailView extends StatelessWidget {
  const ProductDetailView({
    super.key,
    required this.product,
    required this.onList,
  });

  final Product product;
  final VoidCallback onList;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(product.name)),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${product.name} costs ${product.price}'),
          TextButton(onPressed: onList, child: const Text('All products')),
        ],
      ),
    ),
  );
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class LoadFailedView extends StatelessWidget {
  const LoadFailedView({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not load the product'),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

/// What both apps show for a URL nothing matches.
class MissingView extends StatelessWidget {
  const MissingView({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Nothing at ${uri.path}'),
          TextButton(
            onPressed: () => context.go('/'),
            child: const Text('Home'),
          ),
        ],
      ),
    ),
  );
}
