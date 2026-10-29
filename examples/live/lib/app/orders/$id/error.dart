import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:flutter/material.dart';

/// The order's stream ended with an error: a refusal (an order the server does not know answers 404),
/// never a drop, which waits instead. **Try again** builds the feed again.
class OrderError extends StatelessWidget {
  const OrderError({
    super.key,
    required this.id,
    required this.error,
    required this.retry,
  });

  final int id;
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(switch (error) {
          ServerEventsRefused(:final statusCode) =>
            'The server refused order $id ($statusCode)',
          _ => 'Order $id stopped: $error',
        }),
        const SizedBox(height: 8),
        FilledButton(onPressed: retry, child: const Text('Try again')),
      ],
    ),
  );
}
