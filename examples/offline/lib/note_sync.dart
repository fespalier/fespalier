import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// The two procedures of the app's own schema that move owned rows: `syncPush` and `syncPull`.
/// CrateStack has no sync protocol, so this is the app's; the server applies the same per-field rule.
///
/// Both calls go out without an idempotency key: repeating them is safe because the merge is idempotent.
class NoteSync implements RowSync {
  /// Syncs through [_transport].
  NoteSync(this._transport);

  final CrateStackTransport _transport;

  @override
  Future<PushResult> push(List<OwnedRow> dirty) async {
    final answer =
        (await _transport.send(
              RpcCall('syncPush', {
                'rows': [for (final row in dirty) row.toJson()],
              }),
            ))!
            as Map<String, Object?>;
    return PushResult(
      accepted: [
        for (final row in answer['accepted']! as List<Object?>)
          OwnedRow.fromJson(row),
      ],
      rejected: [
        for (final row in answer['rejected']! as List<Object?>) _rejection(row),
      ],
    );
  }

  @override
  Future<PullPage> pull(String collection, String? cursor) async {
    final answer =
        (await _transport.send(
              RpcCall('syncPull', {'collection': collection, 'cursor': cursor}),
            ))!
            as Map<String, Object?>;
    return PullPage(
      [
        for (final row in answer['rows']! as List<Object?>)
          OwnedRow.fromJson(row),
      ],
      nextCursor: answer['next'] as String?,
      hasMore: answer['more'] == true,
    );
  }
}

RowRejection _rejection(Object? json) {
  final rejection = json! as Map<String, Object?>;
  return RowRejection(
    collection: rejection['collection']! as String,
    id: rejection['id']! as String,
    // The wire code only, never the server's message.
    code: rejection['code']! as String,
    server: rejection['server'] == null
        ? null
        : OwnedRow.fromJson(rejection['server']),
  );
}
