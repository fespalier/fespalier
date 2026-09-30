import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';
import 'package:trellis/trellis.dart';

class AppLayout extends Layout {
  const AppLayout(super.child, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(cartCountProvider);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => const HomeRoute().go(context),
          child: const Text('Shop'),
        ),
        actions: [
          TextButton(
            onPressed: () => const ProductsRoute().go(context),
            child: const Text('Products'),
          ),
          IconButton(
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
