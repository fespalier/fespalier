import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:orders_client/orders_client.dart' show Order;

/// How `ref.serve` saves the order list on the device between runs: the generated `Order`'s own wire
/// form, which is JSON-native.
final ServedCodec<List<Order>> ordersCodec = ServedCodec<List<Order>>(
  toJson: (orders) => [for (final order in orders) order.toWire()],
  fromJson: (json) => [
    for (final order in json! as List<Object?>)
      Order.fromWire(order! as Map<String, Object?>),
  ],
);
