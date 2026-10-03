import 'package:flutter/material.dart';
import 'package:telemetry/app.g.dart';

class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        for (final id in [1, 2])
          ListTile(
            title: Text('Order $id'),
            onTap: () => OrderRoute(id: id).go(context),
          ),
      ],
    ),
  );
}
