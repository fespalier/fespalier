import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart' show Provider;

import 'future_or.dart';
import 'hlc.dart';
import 'ids.dart';
import 'local_store.dart';
import 'lww.dart';
import 'revision.dart';
import 'scope.dart';

const _nodeKey = 'cs/node';

/// The rows this device owns and edits, over a [LocalStore]: edits stamp fields and mark them dirty,
/// reads list a collection.
///
/// Every method answers synchronously when the store does, so a `localOnly` read of a `Hive` or
/// in-memory store is on the first frame. Rows are per account: nothing here is read or written
/// while [crateStackScope] is null (a `StateError`, the app's mistake).
final class OwnedRows {
  /// Rows in [store] for the account [scope] answers; [bump] is told which collections changed.
  OwnedRows({
    required LocalStore store,
    required String? Function() scope,
    required BumpTags bump,
  }) : _store = store,
       _scope = scope,
       _bump = bump;

  final LocalStore _store;
  final String? Function() _scope;
  final BumpTags _bump;

  String? _nodeCached;
  Future<String>? _nodePending;

  String _prefix() {
    final scope = _scope();
    if (scope == null) {
      throw StateError(
        'fespalier_cratestack: crateStackScope is null (nobody is signed in), '
        'so owned rows cannot be read or written.',
      );
    }
    return scopePrefix(scope);
  }

  String _rowKey(String prefix, String collection, String id) =>
      '${prefix}row/$collection/$id';

  /// The node id of this device: random, made once per store and kept in it.
  FutureOr<String> node() {
    final cached = _nodeCached;
    if (cached != null) return cached;
    final result = andThen<String?, String>(_store.read(_nodeKey), (saved) {
      if (saved != null) return _nodeCached = saved;
      final made = randomHex(8);
      return andThen<void, String>(
        _store.write(_nodeKey, made),
        (_) => _nodeCached = made,
      );
    });
    if (result is Future<String>) return _nodePending ??= result;
    return result;
  }

  FutureOr<Hlc?> _last(String prefix) => andThen<String?, Hlc?>(
    _store.read('${prefix}hlc'),
    (text) => text == null ? null : Hlc.parse(text),
  );

  /// The row [id] of [collection], or null.
  FutureOr<OwnedRow?> get(String collection, String id) =>
      _get(_prefix(), collection, id);

  FutureOr<OwnedRow?> _get(String prefix, String collection, String id) =>
      andThen<String?, OwnedRow?>(
        _store.read(_rowKey(prefix, collection, id)),
        (text) => text == null ? null : OwnedRow.fromJson(jsonDecode(text)),
      );

  /// The rows of [collection], by id. Rows that are deleted are left out unless [includeDeleted].
  FutureOr<List<OwnedRow>> list(
    String collection, {
    bool includeDeleted = false,
  }) {
    final prefix = '${_prefix()}row/$collection/';
    return andThen<Iterable<String>, List<OwnedRow>>(_store.keys(prefix), (
      keys,
    ) {
      return andThen<List<OwnedRow?>, List<OwnedRow>>(
        allOf<OwnedRow?>([for (final key in keys) _readRow(key)]),
        (rows) => [
          for (final row in rows)
            if (row != null && (includeDeleted || !row.deleted)) row,
        ],
      );
    });
  }

  FutureOr<OwnedRow?> _readRow(String key) => andThen<String?, OwnedRow?>(
    _store.read(key),
    (text) => text == null ? null : OwnedRow.fromJson(jsonDecode(text)),
  );

  /// The rows of [collections] with an edit the server has not acknowledged (deleted ones too).
  FutureOr<List<OwnedRow>> dirty(Iterable<String> collections) =>
      andThen<List<List<OwnedRow>>, List<OwnedRow>>(
        allOf<List<OwnedRow>>([
          for (final c in collections) list(c, includeDeleted: true),
        ]),
        (lists) => [
          for (final rows in lists)
            for (final row in rows)
              if (row.dirty.isNotEmpty) row,
        ],
      );

  /// Writes [changes] at once, offline or not: each field gets `Hlc.next` and is marked dirty.
  /// Bumps the collection's revision. Returns the row as it now stands.
  FutureOr<OwnedRow> edit(
    String collection,
    String id,
    Map<String, Object?> changes,
  ) {
    // The account is read once: an edit that finishes after a sign-out is the old account's.
    final prefix = _prefix();
    final rowKey = _rowKey(prefix, collection, id);
    final hlcKey = '${prefix}hlc';
    return andThen<String, OwnedRow>(
      node(),
      (node) => andThen<Hlc?, OwnedRow>(
        _last(prefix),
        (last) =>
            andThen<OwnedRow?, OwnedRow>(_get(prefix, collection, id), (saved) {
              final row = saved ?? OwnedRow(collection: collection, id: id);
              if (changes.isEmpty) return row;
              var stamp = last;
              for (final change in changes.entries) {
                stamp = Hlc.next(stamp, node);
                row.fields[change.key] = change.value;
                row.stamps[change.key] = stamp;
                row.dirty.add(change.key);
              }
              return andThen<void, OwnedRow>(
                _store.writeAll({
                  rowKey: jsonEncode(row.toJson()),
                  hlcKey: stamp!.pack(),
                }),
                (_) {
                  _bump({collection});
                  return row;
                },
              );
            }),
      ),
    );
  }

  /// Deletes the row with a tombstone (its `deletedAt` field, stamped like any other edit): the
  /// server learns of it with the next push. Returns the row as it now stands.
  FutureOr<OwnedRow> remove(String collection, String id) => edit(
    collection,
    id,
    {tombstoneField: clock.now().toUtc().toIso8601String()},
  );

  /// Takes the [server] rows in: a dirty field keeps its local edit unless the server's stamp is
  /// newer (`LwwMerge.adopt`), the rest is the server's, and this device's clock moves past every
  /// stamp that arrived. Returns how many rows it was given. It does not bump revisions: the
  /// caller knows when a whole sync is done.
  FutureOr<int> adopt(List<OwnedRow> server) {
    if (server.isEmpty) return 0;
    // The account is read once: rows that arrive after a sign-out are the old account's.
    final prefix = _prefix();
    final hlcKey = '${prefix}hlc';
    return andThen<String, int>(
      node(),
      (node) => andThen<Hlc?, int>(
        _last(prefix),
        (last) => andThen<List<OwnedRow?>, int>(
          allOf<OwnedRow?>([
            for (final r in server) _get(prefix, r.collection, r.id),
          ]),
          (locals) {
            final writes = <String, String>{};
            var clockNow = last;
            for (var i = 0; i < server.length; i++) {
              final remote = server[i];
              final local = locals[i];
              final merged = local == null
                  ? LwwMerge.adopt(
                      OwnedRow(collection: remote.collection, id: remote.id),
                      remote,
                    )
                  : LwwMerge.adopt(local, remote);
              writes[_rowKey(prefix, remote.collection, remote.id)] =
                  jsonEncode(merged.toJson());
              for (final stamp in remote.stamps.values) {
                clockNow = Hlc.receive(clockNow, stamp, node);
              }
            }
            if (clockNow != null) writes[hlcKey] = clockNow.pack();
            return andThen<void, int>(
              _store.writeAll(writes),
              (_) => server.length,
            );
          },
        ),
      ),
    );
  }

  /// Forgets the local row: the server's version, if it has one, comes back with the next pull of
  /// a cursor that is reset.
  FutureOr<void> discard(String collection, String id) =>
      _store.delete(_rowKey(_prefix(), collection, id));

  /// The cursor of the last page of [collection] that was pulled, or null.
  FutureOr<String?> cursor(String collection) =>
      _store.read('${_prefix()}cursor/$collection');

  /// Saves the [cursor] of [collection]; null forgets it, so the next pull starts over.
  FutureOr<void> setCursor(String collection, String? cursor) {
    final key = '${_prefix()}cursor/$collection';
    return cursor == null ? _store.delete(key) : _store.write(key, cursor);
  }
}

/// The owned rows of the current account on the [localStore]. A new account gets a new instance.
final ownedRows = Provider<OwnedRows>((ref) {
  final scope = ref.watch(crateStackScope);
  return OwnedRows(
    store: ref.watch(localStore),
    scope: () => ref.mounted ? scope : null,
    bump: ref.watch(crateStackBump),
  );
});
