import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/api.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';

class ProductPage extends HookConsumerWidget {
  const ProductPage({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qty = useState(1);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The row's avatar on the list flies here: both sides name the same
          // route and the same element.
          ProductRoute(id: product.id).hero(
            'avatar',
            child: CircleAvatar(radius: 40, child: Text(product.name[0])),
          ),
          const SizedBox(height: 16),
          Text(product.name, style: Theme.of(context).textTheme.headlineSmall),
          Text('€${product.price.toStringAsFixed(2)}'),
          const SizedBox(height: 24),
          Row(
            children: [
              IconButton(
                onPressed: qty.value > 1 ? () => qty.value-- : null,
                icon: const Icon(Icons.remove),
              ),
              Text('${qty.value}'),
              IconButton(
                onPressed: () => qty.value++,
                icon: const Icon(Icons.add),
              ),
              const SizedBox(width: 16),
              FilledButton(
                onPressed: () {
                  ref.read(cartProvider.notifier).add(product, qty.value);
                  qty.value = 1;
                },
                child: const Text('Add to cart'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
