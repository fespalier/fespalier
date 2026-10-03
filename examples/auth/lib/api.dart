/// The API the signed-in pages call. In this example it is the in-process server of
/// lib/demo/demo_server.dart; in an app it is yours.
final Uri apiOrigin = Uri.parse('https://api.example.com');

/// [path] on the API.
Uri api(String path) => apiOrigin.resolve(path);

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
