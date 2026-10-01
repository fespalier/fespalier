import 'package:flutter/material.dart';

/// Nested under the refund page, like any folder below a page.
class ReceiptPage extends StatelessWidget {
  const ReceiptPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Receipt for order $id')),
        body: const Center(child: Text('Refunded')),
      );
}
