import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:telemetry/app.g.dart';

class OrderPage extends ConsumerWidget {
  const OrderPage({super.key, required this.id, required this.data});

  final int id;
  final String data;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Column(
      children: [
        Text(data),
        TextButton(
          // The write is a span of its own: `action orders/$id/action.dart#action`.
          onPressed: () => OrderRoute.submit(ref, id: id, input: 'refund'),
          child: const Text('Refund'),
        ),
        TextButton(
          // This order cannot be refunded: the action throws. The page would say so; Sentry
          // (`fespalier_sentry`) has the event, tagged with this route, this file and `action`.
          onPressed: () async {
            try {
              await OrderRoute.submit(ref, id: id, input: 'refuse');
            } on StateError {
              // Shown to the user in a real app.
            }
          },
          child: const Text('Refuse'),
        ),
      ],
    ),
  );
}
