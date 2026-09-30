import 'package:flutter/material.dart';
import 'package:shop/api.dart';
import 'package:shop/cart.dart';
import 'package:trellis/trellis.dart';

class ProductPage extends Screen<Product> {
  const ProductPage(super.data, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qty = useState(1);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(data.name, style: Theme.of(context).textTheme.headlineSmall),
          Text('€${data.price.toStringAsFixed(2)}'),
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
                  ref.read(cartProvider.notifier).add(data, qty.value);
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
