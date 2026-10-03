import 'package:auth/api.dart';
import 'package:auth/app.g.dart';
import 'package:flutter/material.dart';

class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key, required this.orders});

  /// data.dart's, by type.
  final List<Order> orders;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Orders')),
    body: ListView(
      children: [
        for (final order in orders)
          ListTile(
            title: Text(order.title),
            onTap: () => OrderRoute(id: order.id).go(context),
          ),
      ],
    ),
  );
}
