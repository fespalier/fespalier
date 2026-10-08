import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart' hide Intent;
import 'package:offline/app.g.dart';
import 'package:offline/problems.dart';
import 'package:offline/shop.dart';

class OrdersPage extends ConsumerWidget {
  // Spelled exactly as data() returns it: fsp matches by type, syntactically.
  const OrdersPage(this.orders, {super.key});

  final Served<List<Order>> orders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cancel = OrdersRoute.useCancel(ref);
    final waiting = ref.watch(pendingIntents(null)).value ?? const [];
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        children: [
          if (orders.source == ServedFrom.local)
            ListTile(
              title: Text(
                orders.neverFetched
                    ? 'Offline: not loaded on this phone yet'
                    : 'Offline copy, as of ${_clock(orders.fetchedAt!)}',
              ),
            ),
          // What the last cancel did. A refusal is shown, not retried.
          if (cancel.state.error case final CrateStackRefused refused)
            ListTile(
              title: Text('The shop refused: ${refused.code}'),
              subtitle: const Text(
                'Nothing was kept, and nothing will be sent again.',
              ),
            )
          else if (cancel.state.value case final Accepted<Order> done)
            ListTile(title: Text('Order ${done.value.id} cancelled'))
          else if (cancel.state.value is Queued<Order>)
            const ListTile(
              title: Text('Saved. It will be sent when you are back online'),
            ),
          const Problems(),
          for (final order in orders.value)
            ListTile(
              title: Text('Order ${order.id}: ${order.item} (${order.status})'),
              subtitle: waiting.any((i) => i.subject == 'order:${order.id}')
                  ? const Text('Cancelling, will send when back online')
                  : null,
              trailing: TextButton(
                onPressed: cancel.isPending || order.status == 'cancelled'
                    ? null
                    : () => cancel.call((
                        orderId: order.id,
                        expectedVersion: order.version,
                      )),
                child: Text('Cancel order ${order.id}'),
              ),
            ),
        ],
      ),
    );
  }
}

String _clock(DateTime at) {
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}
