import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

/// The order a refund is for: the parent of both refund routes, so every deep link below
/// it builds this page first.
class OrderPage extends StatelessWidget {
  const OrderPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Order $id')),
        body: Center(
          child: TextButton(
            onPressed: () => RefundRoute(id: id).go(context),
            child: const Text('Request a refund'),
          ),
        ),
      );
}
