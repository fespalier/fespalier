import 'dart:convert';

import 'package:auth/api.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// One order: opened together with `/orders`, the two requests share one refresh when the access
/// token has expired.
Future<Order> data(Ref ref, {required int id}) async {
  ref.watch(authUserId);
  final response = await ref.watch(authHttpClient).get(api('/orders/$id'));
  if (response.statusCode != 200) {
    throw StateError('GET /orders/$id answered HTTP ${response.statusCode}');
  }
  final json = jsonDecode(response.body) as Map<String, Object?>;
  if (json['error'] != null) throw StateError('No order $id');
  return Order.fromJson(json);
}
