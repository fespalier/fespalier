import 'dart:convert';

import 'package:auth/api.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// The signed-in user's orders. `authHttpClient` sends the session to the API (only to
/// `AuthConfig.apiOrigins`), refreshes an expired token once, and sends the request again after a
/// 401.
Future<List<Order>> data(Ref ref) async {
  // Another user loads this again; a token refresh does not.
  ref.watch(authUserId);
  final response = await ref.watch(authHttpClient).get(api('/orders'));
  if (response.statusCode != 200) {
    throw StateError('GET /orders answered HTTP ${response.statusCode}');
  }
  return [
    for (final json in jsonDecode(response.body) as List<Object?>)
      Order.fromJson(json! as Map<String, Object?>),
  ];
}
