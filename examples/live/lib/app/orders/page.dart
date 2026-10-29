import 'package:flutter/material.dart';
import 'package:live/app.g.dart';
import 'package:live/demo/script.dart';

/// The orders: each opens a page that follows it live.
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      for (final order in scriptOrders)
        ListTile(
          title: Text('Order ${order.id}: ${order.item}'),
          subtitle: const Text('Follow it live'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => OrderRoute(id: order.id).go(context),
        ),
    ],
  );
}
