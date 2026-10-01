import 'package:flutter/material.dart';

/// Confirms the refund. A deep link to `/orders/1/refund/confirm` builds the order page
/// and this one, and back goes to `/orders/1`.
class ConfirmRefundPage extends StatelessWidget {
  const ConfirmRefundPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Confirm refund of order $id')),
        body: const Center(child: Text('Refund this order?')),
      );
}
