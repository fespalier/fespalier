import 'hlc.dart';

/// The field that marks a row deleted: a tombstone is a field like any other, so a delete and a
/// concurrent edit of another field both survive.
const tombstoneField = 'deletedAt';

/// A row this device owns and edits: field values with a stamp each, a dirty set, and a tombstone.
final class OwnedRow {
  /// A row of [collection] with [id].
  OwnedRow({
    required this.collection,
    required this.id,
    Map<String, Object?>? fields,
    Map<String, Hlc>? stamps,
    Set<String>? dirty,
  }) : fields = fields ?? {},
       stamps = stamps ?? {},
       dirty = dirty ?? {};

  /// The row as [toJson] wrote it.
  factory OwnedRow.fromJson(Object? json) {
    final map = json! as Map<String, Object?>;
    return OwnedRow(
      collection: map['collection']! as String,
      id: map['id']! as String,
      fields: Map<String, Object?>.of(map['fields']! as Map<String, Object?>),
      stamps: {
        for (final e in (map['stamps']! as Map<String, Object?>).entries)
          e.key: Hlc.parse(e.value! as String),
      },
      dirty: {...(map['dirty']! as List<Object?>).cast<String>()},
    );
  }

  /// The collection (a model or table name) the row belongs to.
  final String collection;

  /// The row's id, unique within its collection.
  final String id;

  /// The field values.
  final Map<String, Object?> fields;

  /// The stamp of the write that set each field.
  final Map<String, Hlc> stamps;

  /// The fields edited here and not yet acknowledged by the server.
  final Set<String> dirty;

  /// Whether the row is deleted (its `deletedAt` field is set).
  bool get deleted => fields[tombstoneField] != null;

  /// A copy that can be changed without touching this one.
  OwnedRow copy() => OwnedRow(
    collection: collection,
    id: id,
    fields: Map.of(fields),
    stamps: Map.of(stamps),
    dirty: Set.of(dirty),
  );

  /// The row as a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'collection': collection,
    'id': id,
    'fields': fields,
    'stamps': {for (final e in stamps.entries) e.key: e.value.pack()},
    'dirty': dirty.toList()..sort(),
  };

  @override
  String toString() => 'OwnedRow($collection/$id)';
}

/// Per-field last-writer-wins: commutative, associative and idempotent, so two devices converge
/// whatever the order their rows arrive in.
abstract final class LwwMerge {
  /// For each field, the value with the greater stamp (equal stamps are the same write). The
  /// result's `dirty` is the fields of [local] that were dirty and still win.
  static OwnedRow merge(OwnedRow local, OwnedRow remote) {
    final out = OwnedRow(collection: local.collection, id: local.id);
    for (final field in {...local.fields.keys, ...remote.fields.keys}) {
      final a = local.stamps[field];
      final b = remote.stamps[field];
      final takeRemote = b != null && (a == null || b.compareTo(a) > 0);
      if (takeRemote) {
        out.fields[field] = remote.fields[field];
        out.stamps[field] = b;
      } else {
        if (local.fields.containsKey(field)) {
          out.fields[field] = local.fields[field];
        }
        if (a != null) out.stamps[field] = a;
        if (local.dirty.contains(field)) out.dirty.add(field);
      }
    }
    return out;
  }

  /// A server row arriving over a local one: a dirty field keeps the local edit unless the
  /// server's stamp is newer or equal (the server has it, or something later); clean fields take
  /// the server's. A read never overwrites an unpushed edit.
  static OwnedRow adopt(OwnedRow local, OwnedRow server) {
    final out = OwnedRow(collection: local.collection, id: local.id);
    for (final field in {...local.fields.keys, ...server.fields.keys}) {
      final a = local.stamps[field];
      final b = server.stamps[field];
      final keepLocal =
          local.fields.containsKey(field) &&
          (!server.fields.containsKey(field) ||
              (local.dirty.contains(field) &&
                  a != null &&
                  (b == null || a.compareTo(b) > 0)));
      if (keepLocal) {
        out.fields[field] = local.fields[field];
        if (a != null) out.stamps[field] = a;
        if (local.dirty.contains(field)) out.dirty.add(field);
      } else {
        out.fields[field] = server.fields[field];
        if (b != null) out.stamps[field] = b;
      }
    }
    return out;
  }
}
