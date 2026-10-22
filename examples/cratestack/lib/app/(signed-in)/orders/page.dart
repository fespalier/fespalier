import 'package:cratestack_example/app.g.dart';
import 'package:cratestack_example/src/session.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';
import 'package:orders_client/orders_client.dart' show Order;

/// The orders, and a form for a new one. `orders` is data.dart's, spelled exactly as it returns it:
/// fsp matches by type.
class OrdersPage extends HookConsumerWidget {
  const OrdersPage(this.orders, {super.key});

  final Served<List<Order>> orders;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final place = OrdersRoute.useAction(ref);
    final item = useTextEditingController();
    final quantity = useTextEditingController(text: '1');
    final errors = place.fieldErrors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => signOutAndWipe(ref),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Served says where the list came from: the server, or the copy this phone saved.
          if (orders.source == ServedFrom.local)
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_off),
                title: Text(
                  orders.neverFetched
                      ? 'Offline: not loaded on this phone yet'
                      : 'Offline copy, as of ${_clock(orders.fetchedAt!)}',
                ),
                trailing: TextButton(
                  onPressed: () => const OrdersRoute().refresh(ref),
                  child: const Text('Try again'),
                ),
              ),
            ),
          for (final order in orders.value)
            ListTile(
              title: Text('${order.quantity} x ${order.item}'),
              subtitle: Text('Order ${order.id}, ${order.status}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => OrderRoute(id: order.id).go(context),
            ),
          const Divider(),
          TextField(
            controller: item,
            decoration: InputDecoration(
              labelText: 'Item',
              errorText: errors?.fields['item'],
            ),
          ),
          TextField(
            controller: quantity,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Quantity',
              errorText: errors?.fields['quantity'],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: place.isPending
                ? null
                : () async {
                    final placed = await place.call((
                      item: item.text,
                      quantity: int.tryParse(quantity.text) ?? 0,
                    ));
                    if (placed != null) item.clear();
                  },
            child: Text(place.isPending ? 'Placing...' : 'Place order'),
          ),
          // Anything that is not a field of the form: the server refused, or could not be reached.
          if (place.state.error case final error? when error is! FieldErrors)
            Text('The order was not placed: $error'),
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
