import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:live/orders.dart';
import 'package:live/widgets.dart';

/// One order, followed by server-sent events: its status as the last event says, and where the
/// connection is. **Advance** makes the server send the next status; **Drop** breaks the stream, which
/// waits for the tick and then resumes from the last event (`Last-Event-ID`).
class OrderPage extends ConsumerWidget {
  const OrderPage({super.key, required this.id, required this.order});

  final int id;

  /// What data.dart's `ProviderListenable<AsyncValue<OrderUpdate>>` yields, by type.
  final OrderUpdate order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(orderLive.status(id)).value;
    return ListView(
      children: [
        StatusBanner(status),
        ListTile(
          title: Text('Order $id: ${order.item}'),
          subtitle: Text('Event ${order.seq} from the server'),
        ),
        ListTile(
          title: Text(
            'Status: ${order.status}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        ServerControls([
          ServerButton('Advance the order', 'orders/$id/advance'),
          ServerButton('Drop the connection', 'orders/$id/drop'),
        ]),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'A drop waits for the next tick (every 15 s, or Tick now), the network coming back or the '
            'app being shown again, then resumes from the last event it read.',
          ),
        ),
      ],
    );
  }
}
