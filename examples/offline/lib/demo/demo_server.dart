import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/shop.dart';

/// The longest title the demo server takes; a longer one is refused and the device rolls the edit back.
const maxTitle = 60;

/// What the demo server answers with when it decides no: the shape of CrateStack's error envelope.
class DemoError implements Exception {
  /// A refusal with an HTTP [status], a wire [code] and a [message].
  const DemoError(this.status, this.code, this.message);

  /// The HTTP status.
  final int status;

  /// The wire code (`ORDER_ALREADY_SHIPPED`).
  final String code;

  /// A human message. Nothing stores it: only the code survives on the device.
  final String message;

  @override
  String toString() => 'DemoError($status $code)';
}

/// An in-process stand-in for a CrateStack server (no network, no backend): the app runs and is tested
/// without one. It speaks the same RPC operations a real schema would declare, behind
/// [CrateStackTransport]:
///
/// - `listOrders` and `cancelOrder`, which keeps an idempotency store like CrateStack's: a replay under
///   the same key returns the stored answer and does not run twice.
/// - `syncPush` and `syncPull`, the two procedures of the app's schema that [RowSync] needs. They merge
///   with [LwwMerge], the same per-field rule the device runs.
///
/// Every call goes through JSON, as it would on the wire. The "network" is the switch in the app bar
/// (`lib/network.dart`) in front of it, not a flag in here.
final class DemoServer implements CrateStackTransport {
  /// A server with three orders and one note.
  DemoServer() {
    for (final order in const [
      Order(1, 'Ceramic mug', 'placed', 1),
      Order(2, 'Linen apron', 'placed', 1),
      // Already on its way: the server refuses to cancel it.
      Order(3, 'Cast-iron pan', 'shipped', 1),
    ]) {
      _orders[order.id] = order;
    }
    _put(
      OwnedRow(
        collection: 'notes',
        id: 'n1',
        fields: {'title': 'Groceries', 'body': 'Milk, eggs'},
        stamps: {
          'title': const Hlc(1700000000000, 0, 'server'),
          'body': const Hlc(1700000000000, 0, 'server'),
        },
      ),
    );
  }

  final Map<int, Order> _orders = {};
  final Map<String, OwnedRow> _notes = {};
  final Map<String, int> _versions = {};
  final Map<String, ({String body, Object? output})> _stored = {};
  final Map<String, int> _runs = {};
  var _version = 0;

  /// How many times the server really ran [op] (a replay of a stored answer does not count).
  int runs(String op) => _runs[op] ?? 0;

  /// What another phone of the same account did: edits [changes] of note [id] with a stamp later than
  /// anything the server has seen. This phone sees them at its next pull, and merges them field by field.
  void editOnAnotherDevice(String id, Map<String, Object?> changes) {
    final row = _notes[id];
    if (row == null) return;
    var last = row.stamps.values.fold<Hlc?>(
      null,
      (a, b) => a == null || b > a ? b : a,
    );
    final edit = OwnedRow(collection: 'notes', id: id);
    for (final change in changes.entries) {
      last = Hlc.next(last, 'other-phone');
      edit.fields[change.key] = change.value;
      edit.stamps[change.key] = last;
    }
    _put(edit);
  }

  @override
  Future<Object?> send(CrateStackCall call, {String? idempotencyKey}) async {
    if (call is! RpcCall) {
      throw UnsupportedError('the demo server speaks the RPC transport');
    }
    final body = jsonEncode(call.toJson());
    if (idempotencyKey != null) {
      final stored = _stored[idempotencyKey];
      if (stored != null) {
        if (stored.body != body) {
          throw const DemoError(
            422,
            idempotencyKeyConflict,
            'the key was used with another body',
          );
        }
        return stored.output;
      }
    }
    final input = jsonDecode(jsonEncode(call.input));
    final output = jsonDecode(jsonEncode(_run(call.opId, input)));
    _runs[call.opId] = runs(call.opId) + 1;
    if (idempotencyKey != null) {
      _stored[idempotencyKey] = (body: body, output: output);
    }
    return output;
  }

  Object? _run(String op, Object? input) => switch (op) {
    'listOrders' => [for (final order in _orders.values) order.toMap()],
    'cancelOrder' => _cancel(input! as Map<String, Object?>),
    'syncPush' => _push(input! as Map<String, Object?>),
    'syncPull' => _pull(input! as Map<String, Object?>),
    _ => throw DemoError(404, 'UNKNOWN_OPERATION', op),
  };

  Object? _cancel(Map<String, Object?> input) {
    final order = _orders[input['id']];
    if (order == null) throw const DemoError(404, 'NOT_FOUND', 'no such order');
    if (order.status == 'shipped') {
      throw const DemoError(
        422,
        'ORDER_ALREADY_SHIPPED',
        'a shipped order cannot be cancelled',
      );
    }
    if (order.version != input['expectedVersion']) {
      throw const DemoError(
        409,
        'STALE_VERSION',
        'the order changed since it was read',
      );
    }
    final cancelled = Order(
      order.id,
      order.item,
      'cancelled',
      order.version + 1,
    );
    _orders[order.id] = cancelled;
    return cancelled.toMap();
  }

  Object? _push(Map<String, Object?> input) {
    final accepted = <Object?>[];
    final rejected = <Object?>[];
    for (final json in input['rows']! as List<Object?>) {
      final row = OwnedRow.fromJson(json);
      final title = row.fields['title'];
      if (title is String && title.length > maxTitle) {
        rejected.add({
          'collection': row.collection,
          'id': row.id,
          'code': 'TITLE_TOO_LONG',
          'server': _notes[row.id]?.toJson(),
        });
        continue;
      }
      _put(row);
      accepted.add(_notes[row.id]!.toJson());
    }
    return {'accepted': accepted, 'rejected': rejected};
  }

  Object? _pull(Map<String, Object?> input) {
    final after = int.tryParse('${input['cursor']}') ?? 0;
    final changed = [
      for (final row in _notes.values)
        if (_versions[row.id]! > after) row,
    ]..sort((a, b) => _versions[a.id]!.compareTo(_versions[b.id]!));
    return {
      'rows': [for (final row in changed) row.toJson()],
      'next': changed.isEmpty
          ? input['cursor']
          : '${_versions[changed.last.id]}',
      'more': false,
    };
  }

  void _put(OwnedRow row) {
    final existing = _notes[row.id];
    _notes[row.id] =
        (existing == null ? row.copy() : LwwMerge.merge(existing, row))
          ..dirty.clear();
    _versions[row.id] = ++_version;
  }
}

/// The server the app talks to. The demo's own, unless startup() or a test says otherwise.
final demoServer = Provider<DemoServer>((ref) => DemoServer());
