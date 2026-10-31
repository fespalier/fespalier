import 'package:cratestack_example/app.g.dart';
import 'package:cratestack_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:orders_client/orders_client.dart'
    show CratestackRpcException, Order;

/// One order, and the one sensitive action: paying, which the server accepts only when signed by the
/// user-present key (a step-up the session completes). Where the device has none (the web), the
/// page says so and does not offer it.
class OrderPage extends ConsumerWidget {
  const OrderPage(this.order, {super.key});

  /// data.dart's, by type.
  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pay = OrderRoute.usePay(ref, id: order.id);
    final canConfirm = ref.watch(deviceBackend).keys.userPresent != null;
    return Scaffold(
      appBar: AppBar(title: Text('Order ${order.id}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(title: Text('Item: ${order.item}')),
          ListTile(title: Text('Quantity: ${order.quantity}')),
          ListTile(title: Text('Status: ${order.status}')),
          if (order.status != 'paid') ...[
            if (!canConfirm)
              const Text(
                'This device has no user-present key (the web has none), so it '
                'cannot confirm a payment.',
              ),
            // Null while the call runs, and where there is no key to confirm with.
            FilledButton(
              onPressed: pay.isPending || !canConfirm
                  ? null
                  : () => pay.call(null),
              child: Text(pay.isPending ? 'Paying...' : 'Confirm and pay'),
            ),
          ],
          // The step-up refusal stands only when the user did not confirm (the session retried it
          // once with the user-present key, and the prompt was cancelled).
          if (pay.state.error case CratestackRpcException(stepUp: _?))
            const Text('Confirmation cancelled. Nothing was paid.')
          else if (pay.state.error case final error?)
            Text('The payment failed: $error'),
        ],
      ),
    );
  }
}
