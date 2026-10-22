import 'package:auth/api.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// One order: opened together with `/orders`, the two requests share one renewal when the access
/// token has expired.
Future<Order> data(Ref ref, {required int id}) async {
  ref.watch(authUserId);
  final json = await getJson(ref.watch(authTransport), '/orders/$id');
  final order = json! as Map<String, Object?>;
  if (order['error'] != null) throw StateError('No order $id');
  return Order.fromJson(order);
}
