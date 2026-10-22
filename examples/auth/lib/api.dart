import 'dart:convert';

import 'package:fespalier_transport/fespalier_transport.dart';

/// The API the signed-in pages call. In this example it is the in-process server of
/// lib/demo/demo_server.dart; in an app it is yours.
final Uri apiOrigin = Uri.parse('https://api.example.com');

/// [path] on the API.
Uri api(String path) => apiOrigin.resolve(path);

/// `GET`s [path] on the API through [transport] (the app's `authTransport`, which attaches the
/// session) and returns the JSON it answers. Anything but a 200 is a `StateError`.
Future<Object?> getJson(HttpTransport transport, String path) async {
  final response = await transport.send(
    TransportRequest(method: 'GET', uri: api(path)),
  );
  final body = utf8.decode(await response.bytes());
  if (response.statusCode != 200) {
    throw StateError('GET $path answered HTTP ${response.statusCode}');
  }
  return jsonDecode(body);
}

/// An order, as the demo API answers it.
class Order {
  /// An order of [id] called [title].
  const Order({required this.id, required this.title});

  /// What `GET /orders` and `GET /orders/{id}` answer.
  factory Order.fromJson(Map<String, Object?> json) =>
      Order(id: json['id']! as int, title: json['title']! as String);

  /// The order's number.
  final int id;

  /// What it says.
  final String title;
}
