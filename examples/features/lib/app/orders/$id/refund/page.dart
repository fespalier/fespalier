import 'package:features/app.g.dart';
import 'package:flutter/material.dart';

/// Quotes a refund (`data.dart` beside this file) and asks to confirm it. `confirm/` is
/// not below this page in the stack, although its URL is: see `confirm/route.dart`.
class RefundPage extends StatelessWidget {
  const RefundPage({super.key, required this.id, required this.quote});

  final int id;
  final String quote;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Refund order $id')),
        body: Column(
          children: [
            Text(quote),
            TextButton(
              onPressed: () => ConfirmRefundRoute(id: id).go(context),
              child: const Text('Continue'),
            ),
            TextButton(
              onPressed: () => ReceiptRoute(id: id).go(context),
              child: const Text('Receipt'),
            ),
          ],
        ),
      );
}
