import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:fespalier/persist.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'entry.dart';
import 'errors.dart';

/// Every entry this storage saves is under this prefix of the store's own keys, so an app's other keys (a Hive box
/// it shares, shared preferences it uses itself) are never read, swept, evicted or cleared.
const storedKeyPrefix = 'fespalier.dataCache/';

/// The key-value store a [BoundedDataStorage] keeps its entries in: shared preferences' cache, a Hive box, or a map in
/// a test (since 0.9.0). Reads are synchronous; writes may be asynchronous.
abstract interface class EntryStore {
  /// Every key in the store, the app's own included.
  Iterable<String> get keys;

  /// The value under [key], or null. May throw for a value that is not a string.
  String? get(String key);

  /// Saves [value] under [key]. The next [get] sees it before the future completes.
  Future<void> put(String key, String value);

  /// Removes [key].
  Future<void> remove(String key);
}

/// A budget that must be more than 0 (S7): `ArgumentError.value` prints
/// `Invalid argument (maxSize): must be more than 0: <value>`.
int checkBudget(int value, String name) {
  if (value <= 0) throw ArgumentError.value(value, name, 'must be more than 0');
  return value;
}

/// What the index knows about one saved entry: what it takes, and when it was written.
final class _Slot {
  const _Slot(this.size, this.writtenAt);

  final int size;
  final DateTime writtenAt;
}

/// A `Storage<String, String>` over a synchronous key-value store, with a size budget (since 0.9.0).
///
/// Each entry is one string in the `fsc1` format (`entry.dart`) under a key with [storedKeyPrefix]. An in-memory index,
/// built when the storage is made, holds each entry's size and write time; it is never saved, so it cannot disagree
/// with the store across a crash. Over budget, the entries **written longest ago** go first, ties by key: a function of
/// the store and `clock.now()`, with no timer and no background sweep.
abstract base class BoundedDataStorage extends Storage<String, String> {
  /// A storage over [store]. The budgets are checked **in the initializer list**, because `Storage`'s constructor body
  /// then runs [deleteOutOfDate], which builds the index with them. [maxKeyBytes] is the longest key [store] takes in
  /// UTF-8 bytes (Hive's 255); a longer one is stored under the SHA-256 of the dataCache key.
  BoundedDataStorage(
    this._store, {
    required int maxSize,
    required int maxEntries,
    this.maxKeyBytes,
  }) : maxSize = checkBudget(maxSize, 'maxSize'),
       maxEntries = checkBudget(maxEntries, 'maxEntries');

  final EntryStore _store;

  /// The longest key the store takes, in UTF-8 bytes; null for no limit.
  final int? maxKeyBytes;

  /// The most the saved entries may take, keys and headers included, in `String.length` units (UTF-16 code units, what
  /// browsers count localStorage in).
  final int maxSize;

  /// The most entries kept.
  final int maxEntries;

  final _index = <String, _Slot>{};
  var _size = 0;
  final _sweeping = <Future<void>>[];

  /// What the saved entries take now, in the units of [maxSize].
  int get size => _size;

  /// How many entries are saved.
  int get length => _index.length;

  /// Completes when the deletes of the sweep that built the index are done (they are not awaited by the constructor).
  Future<void> sweepDone() => Future.wait(_sweeping).then<void>((_) {});

  /// Deletes every entry this storage saved (and any unreadable one under its prefix). For a sign-out: the next start
  /// shows nothing from the previous user. Values in memory are the app's to invalidate.
  Future<void> clear() {
    final keys = [
      for (final key in _store.keys)
        if (key.startsWith(storedKeyPrefix)) key,
    ];
    _index.clear();
    _size = 0;
    return Future.wait([
      for (final key in keys) _run(() => _store.remove(key)),
    ]).then<void>((_) {});
  }

  /// The stored key of [key], and whether it is hashed.
  (String stored, bool hashed) _storedKey(String key) {
    final plain = '$storedKeyPrefix$key';
    final limit = maxKeyBytes;
    if (limit == null || utf8.encode(plain).length <= limit) {
      return (plain, false);
    }
    return ('$storedKeyPrefix#${sha256.convert(utf8.encode(key))}', true);
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    try {
      return operation();
    } on Object catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }
  }

  void _track(String storedKey, int size, DateTime writtenAt) {
    _size += size - (_index[storedKey]?.size ?? 0);
    _index[storedKey] = _Slot(size, writtenAt);
  }

  /// Takes [storedKey] out of the index and the store; never fails (the next start sweeps what is left).
  Future<void> _removeQuietly(String storedKey) {
    final slot = _index.remove(storedKey);
    if (slot != null) _size -= slot.size;
    return _run(() => _store.remove(storedKey)).catchError((Object _) {});
  }

  /// Evicts the entries written longest ago while over a budget, never [keep]. Returns the removals.
  List<Future<void>> _evict({String? keep}) {
    bool within() => _size <= maxSize && _index.length <= maxEntries;
    if (within()) return const [];
    final order =
        [
          for (final entry in _index.entries)
            if (entry.key != keep) entry,
        ]..sort((a, b) {
          final byTime = a.value.writtenAt.compareTo(b.value.writtenAt);
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });
    final removals = <Future<void>>[];
    for (final entry in order) {
      if (within()) break;
      removals.add(_removeQuietly(entry.key));
    }
    return removals;
  }

  /// Builds the index and deletes the expired and the unreadable entries; then evicts down to the budgets. Called
  /// once, by `Storage`'s constructor.
  @override
  void deleteOutOfDate() {
    _index.clear();
    _size = 0;
    final now = clock.now();
    var unreadable = 0;
    final keys = [
      for (final key in _store.keys)
        if (key.startsWith(storedKeyPrefix)) key,
    ]..sort();
    for (final storedKey in keys) {
      String? stored;
      Entry? entry;
      try {
        stored = _store.get(storedKey);
        if (stored != null) entry = decodeEntry(stored);
      } on Object {
        // A FormatException, or a TypeError for a value that is not a string.
        unreadable++;
        _sweeping.add(_removeQuietly(storedKey));
        continue;
      }
      if (stored == null || entry == null) continue;
      final expireAt = entry.expireAt;
      if (expireAt != null && !expireAt.isAfter(now)) {
        _sweeping.add(_removeQuietly(storedKey));
        continue;
      }
      _track(storedKey, storedKey.length + stored.length, entry.writtenAt);
    }
    _sweeping.addAll(_evict());
    if (unreadable > 0 && kDebugMode) {
      debugPrint(
        'fespalier_storage: dropped $unreadable saved entries that could not be read',
      ); // S3
    }
  }

  /// The saved entry, synchronously; null when there is none. Throws a FormatException for an entry it cannot read
  /// (fespalier then prints it, deletes it and loads). Expired data is returned as it is: Riverpod's `persist` checks
  /// `expireAt` and `destroyKey` and deletes.
  @override
  PersistedData<String>? read(String key) {
    final (storedKey, hashed) = _storedKey(key);
    final String? stored;
    try {
      stored = _store.get(storedKey);
    } on TypeError {
      throw const FormatException(unreadableEntryMessage); // S2
    }
    if (stored == null) return null;
    final entry = decodeEntry(stored); // S2
    // A hash collision is a miss, not corruption.
    if (hashed && entry.key != key) return null;
    return PersistedData(
      entry.data,
      destroyKey: entry.destroyKey,
      expireAt: entry.expireAt,
    );
  }

  /// Saves [value]: one entry, evicting the entries written longest ago when over budget. A value too large for
  /// [maxSize] fails with [DataEntryTooLarge] (S1), as a failed `Future`, never a synchronous throw.
  @override
  Future<void> write(String key, String value, StorageOptions options) {
    final (storedKey, hashed) = _storedKey(key);
    final writtenAt = clock.now().toUtc();
    final duration = options.cacheTime.duration;
    final stored = encodeEntry(
      Entry(
        data: value,
        writtenAt: writtenAt,
        expireAt: duration == null ? null : writtenAt.add(duration),
        destroyKey: options.destroyKey,
        key: hashed ? key : null,
      ),
    );
    final size = storedKey.length + stored.length;
    if (size > maxSize) {
      // The older copy of this key is stale: take it away, then fail.
      return _removeQuietly(
        storedKey,
      ).then<void>((_) => throw DataEntryTooLarge(key, size, maxSize));
    }
    _track(storedKey, size, writtenAt);
    final put = _run(() => _store.put(storedKey, stored)).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        final slot = _index[storedKey];
        if (slot != null && slot.writtenAt == writtenAt && slot.size == size) {
          unawaited(_removeQuietly(storedKey));
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    return Future.wait([put, ..._evict(keep: storedKey)]).then<void>((_) {});
  }

  /// Deletes the entry of [key].
  @override
  Future<void> delete(String key) {
    final (storedKey, _) = _storedKey(key);
    final slot = _index.remove(storedKey);
    if (slot != null) _size -= slot.size;
    return _run(() => _store.remove(storedKey));
  }
}
