import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:live/wiring.dart';

/// An order as one event of its stream says it is now.
///
/// No `==` on purpose: Riverpod does not notify a value equal to the last one, and the server sends
/// the same status again when a client that was up to date resumes.
final class OrderUpdate {
  /// What event [seq] said about order [id].
  const OrderUpdate({
    required this.id,
    required this.item,
    required this.status,
    required this.seq,
  });

  /// Reads an event's JSON `data`.
  factory OrderUpdate.fromEvent(ServerEvent event) {
    final json = jsonDecode(event.data) as Map<String, Object?>;
    return OrderUpdate(
      id: json['id']! as int,
      item: json['item']! as String,
      status: json['status']! as String,
      seq: json['seq']! as int,
    );
  }

  /// The order's number.
  final int id;

  /// What was ordered.
  final String item;

  /// Where it is: placed, packed, shipped, delivered.
  final String status;

  /// The event's number, also its `id:`, which a reconnection resumes from.
  final int seq;
}

/// One event stream per order watched (`orderLive(1)`), and where its connection is
/// (`orderLive.status(1)`). The server sends `id:` on each event, so a reconnection asks for what it
/// missed (`Last-Event-ID`), and a page watched again after it was disposed resumes from the ID the feed
/// kept. A drop waits for the network to come back, the app to be shown again, or the tick.
final orderLive = LiveFeedFamily<OrderUpdate, int>(
  (ref, id, lastEventId) => ServerEvents(
    ref.watch(liveTransport),
    ref.watch(liveOrigin).resolve('orders/$id/events'),
    lastEventId: lastEventId,
    name: 'order',
  ).map(OrderUpdate.fromEvent),
  rules: LiveRules(
    reconnectOn: [reconnectSignal, appShowSignal],
    idle: liveIdle,
  ),
  name: 'orderLive',
);
