import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// An order, as the shop's server describes it. Cancelling one is a decision only the server makes.
class Order {
  /// An order of [item] at [version], in [status] (`placed`, `shipped` or `cancelled`).
  const Order(this.id, this.item, this.status, this.version);

  /// Reads the wire shape.
  factory Order.fromMap(Map<String, Object?> map) => Order(
    map['id']! as int,
    map['item']! as String,
    map['status']! as String,
    map['version']! as int,
  );

  /// The server's id.
  final int id;

  /// What was bought.
  final String item;

  /// `placed`, `shipped` or `cancelled`.
  final String status;

  /// The server's version of the row, sent back with a cancel so a stale cancel is a conflict.
  final int version;

  /// The wire shape (what [ServedCodec] saves on the device).
  Map<String, Object?> toMap() => {
    'id': id,
    'item': item,
    'status': status,
    'version': version,
  };
}

/// Reads the shop's server through the transport. A generated CrateStack client would sit here.
class ShopClient {
  /// A client that sends through [transport].
  const ShopClient(this._transport);

  final CrateStackTransport _transport;

  /// Every order of the signed-in account.
  Future<List<Order>> orders() async {
    final out = await _transport.send(const RpcCall('listOrders', null));
    return [
      for (final order in out! as List<Object?>)
        Order.fromMap(order! as Map<String, Object?>),
    ];
  }
}

/// The client every `data.dart` reads through.
final shopClient = Provider<ShopClient>(
  (ref) => ShopClient(ref.watch(crateStackTransport)),
);

/// A note the device owns: edited here at once, merged with the server's copy field by field.
class Note {
  /// A note [id] with a [title] and a [body]; [waiting] when an edit has not reached the server yet.
  const Note(this.id, this.title, this.body, {this.waiting = false});

  /// Reads an owned row of the `notes` collection.
  factory Note.fromRow(OwnedRow row) => Note(
    row.id,
    (row.fields['title'] as String?) ?? '',
    (row.fields['body'] as String?) ?? '',
    waiting: row.dirty.isNotEmpty,
  );

  /// The row's id.
  final String id;

  /// The title (a field of its own: two devices editing title and body both keep their edit).
  final String title;

  /// The body.
  final String body;

  /// True while a field was edited here and the server has not acknowledged it.
  final bool waiting;
}
