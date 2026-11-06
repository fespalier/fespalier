import 'dart:convert';

/// The format of a saved entry, `fsc1`: five header lines, then the data (since 0.9.0).
///
/// ```text
/// fsc1
/// <expireAt, milliseconds since the epoch, UTC; empty for none>
/// <writtenAt, milliseconds since the epoch, UTC>
/// <jsonEncode(destroyKey)>             null or a JSON string
/// <jsonEncode(key) when the stored key is hashed, else empty>
/// <data>                               everything after the fifth newline, newlines included
/// ```
///
/// The header is parsed with `indexOf('\n')` and the data is never parsed, so the saved JSON is not escaped a second
/// time (which matters against the web's localStorage). A later format is `fsc2`; `fsc1` code treats it as
/// unreadable, which for a cache means "dropped and loaded again".
final class Entry {
  /// An entry written at [writtenAt].
  const Entry({
    required this.data,
    required this.writtenAt,
    this.expireAt,
    this.destroyKey,
    this.key,
  });

  /// What the dataCache saved: its encoded value.
  final String data;

  /// When this storage wrote it: what eviction orders by.
  final DateTime writtenAt;

  /// When it stops being valid; null for never.
  final DateTime? expireAt;

  /// Riverpod's `destroyKey`: `DataCache.version`.
  final String? destroyKey;

  /// The dataCache key, for an entry stored under a hashed key; null for any other.
  final String? key;
}

/// The message of the `FormatException` of an entry that cannot be read (S2).
const unreadableEntryMessage =
    'fespalier_storage: a saved entry is not one this storage wrote (format fsc1)';

/// The stored text of [entry].
String encodeEntry(Entry entry) {
  final expire = entry.expireAt?.millisecondsSinceEpoch;
  final buffer = StringBuffer()
    ..write('fsc1\n')
    ..write(expire ?? '')
    ..write('\n')
    ..write(entry.writtenAt.millisecondsSinceEpoch)
    ..write('\n')
    ..write(jsonEncode(entry.destroyKey))
    ..write('\n')
    ..write(entry.key == null ? '' : jsonEncode(entry.key))
    ..write('\n')
    ..write(entry.data);
  return buffer.toString();
}

final _digits = RegExp(r'^[0-9]{1,16}$');

/// The entry [stored] holds. Throws the `FormatException` of [unreadableEntryMessage] when [stored] is not one `fsc1`
/// wrote: fewer than five newlines, another first line, a time that is not an integer, a `destroyKey` that is not
/// `null` or a JSON string, or a key line that is neither empty nor a JSON string.
Entry decodeEntry(String stored) {
  const bad = FormatException(unreadableEntryMessage);
  var start = 0;
  String? line() {
    final end = stored.indexOf('\n', start);
    if (end < 0) return null;
    final text = stored.substring(start, end);
    start = end + 1;
    return text;
  }

  final format = line();
  final expire = line();
  final written = line();
  final destroy = line();
  final key = line();
  if (format != 'fsc1' ||
      expire == null ||
      written == null ||
      destroy == null ||
      key == null) {
    throw bad;
  }
  DateTime time(String milliseconds) {
    if (!_digits.hasMatch(milliseconds)) throw bad;
    try {
      return DateTime.fromMillisecondsSinceEpoch(
        int.parse(milliseconds),
        isUtc: true,
      );
    } on ArgumentError {
      throw bad;
    }
  }

  String? text(String json) {
    final Object? value;
    try {
      value = jsonDecode(json);
    } on FormatException {
      throw bad;
    }
    if (value != null && value is! String) throw bad;
    return value as String?;
  }

  return Entry(
    data: stored.substring(start),
    writtenAt: time(written),
    expireAt: expire.isEmpty ? null : time(expire),
    destroyKey: text(destroy),
    key: key.isEmpty ? null : text(key),
  );
}
