import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';

class AppLayout extends ConsumerWidget {
  const AppLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(cartCountProvider);
    return Scaffold(
      appBar: AppBar(
        // A button, not an InkWell around a Text: its tap target is 48 pixels high, which
        // `test: a11y` (pubspec.yaml) checks on every route.
        title: TextButton(
          onPressed: () => const HomeRoute().go(context),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.onSurface,
            textStyle: Theme.of(context).textTheme.titleLarge,
          ),
          child: const Text('Shop'),
        ),
        actions: [
          TextButton(
            onPressed: () => const ProductsRoute().go(context),
            child: const Text('Products'),
          ),
          IconButton(
            // The label a screen reader says, and `test: a11y` (pubspec.yaml) checks for.
            tooltip: 'Cart',
            onPressed: () => const CartRoute().go(context),
            icon: Badge.count(
              count: count,
              isLabelVisible: count > 0,
              child: const Icon(Icons.shopping_cart_outlined),
            ),
          ),
        ],
      ),
      body: child,
    );
  }
}
