import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart';

/// What the list shows when the read failed and the copy on the device is not an honest answer: the
/// server refused (a 403 is not "the network is down"), or an error no reader knows.
class OrdersError extends StatelessWidget {
  const OrdersError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(switch (error) {
          CrateStackRefused(:final code) => 'The shop refused this: $code',
          _ => 'The orders could not be read',
        }),
        TextButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );
}
