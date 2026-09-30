import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';
import 'package:trellis/trellis.dart';

class CartPage extends Screen<Params> {
  const CartPage(super.data, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(cartProvider).values.toList();
    if (lines.isEmpty) return const Center(child: Text('Your cart is empty'));
    final total = lines.fold(0.0, (sum, l) => sum + l.product.price * l.qty);
    return Material(
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
