import 'package:auth/api.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// The signed-in user's orders. `authTransport` sends the session to the API (only to
/// `AuthConfig.apiOrigins`), renews an expired token once, and sends the request again after a
/// 401.
Future<List<Order>> data(Ref ref) async {
  // Another user loads this again; a token renewal does not.
  ref.watch(authUserId);
  final json = await getJson(ref.watch(authTransport), '/orders');
  return [
    for (final order in json! as List<Object?>)
      Order.fromJson(order! as Map<String, Object?>),
  ];
}
