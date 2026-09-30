import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:shop/cart.dart';

class CheckoutPage extends HookConsumerWidget {
  const CheckoutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placed = useState(false);
    return Center(
      child: placed.value
          ? TextButton(
              onPressed: () => const HomeRoute().go(context),
              child: const Text('Order placed. Back home'),
            )
          : FilledButton(
              onPressed: () {
                ref.read(cartProvider.notifier).clear();
                placed.value = true;
              },
              child: const Text('Place order'),
            ),
    );
  }
}
