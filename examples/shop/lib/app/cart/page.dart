import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';

class CartPage extends ConsumerWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(cartProvider).values.toList();
    if (lines.isEmpty) return const Center(child: Text('Your cart is empty'));
    final total = lines.fold(0.0, (sum, l) => sum + l.product.price * l.qty);
    return Material(
      // Pages sit below the layout's Scaffold, so give ListTile ink a
      // surface of its own (page transitions paint in between).
      type: MaterialType.transparency,
      child: ListView(
        children: [
          for (final l in lines)
            ListTile(
              title: Text(l.product.name),
              subtitle: Text('× ${l.qty}'),
              onTap: () => ProductRoute(id: l.product.id).go(context),
            ),
          ListTile(title: Text('Total €${total.toStringAsFixed(2)}')),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () => const CheckoutRoute().go(context),
              child: const Text('Checkout'),
            ),
          ),
        ],
      ),
    );
  }
}
