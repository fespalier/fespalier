import 'package:auth/api.dart';
import 'package:flutter/material.dart';

class OrderPage extends StatelessWidget {
  const OrderPage({super.key, required this.order});

  /// data.dart's, by type.
  final Order order;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Order ${order.id}')),
    body: Center(child: Text(order.title)),
  );
}
