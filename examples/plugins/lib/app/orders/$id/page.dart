import 'package:flutter/material.dart';

/// An order: where the notification "your order shipped" lands.
class OrderPage extends StatelessWidget {
  const OrderPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: Text('Order $id')));
}
