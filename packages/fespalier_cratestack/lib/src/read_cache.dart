import 'dart:async';
import 'dart:convert';

import 'package:fespalier/persist.dart'
    show Storage, StorageCacheTime, StorageOptions;
import 'package:fespalier/fespalier.dart' show Provider;

import 'future_or.dart';
import 'local_store.dart';
import 'scope.dart';

/// A saved answer of a read: its JSON value and when the server gave it.
final class CachedAnswer {
  /// An answer saved at [fetchedAt].
  const CachedAnswer(this.json, this.fetchedAt);

  /// The value, as `ServedCodec.toJson` wrote it.
  final Object? json;

  /// When the server last answered this read for this account, on this device.
  final DateTime fetchedAt;
}

abstract interface class _Raw {
  FutureOr<String?> read(String key);
  FutureOr<void> write(String scope, String key, String value);
  FutureOr<void> delete(String key);
  FutureOr<void> clear(String scope);
}

String _key(String scope, String key) => '${scopePrefix(scope)}read/$key';

final class _OnLocal implements _Raw {
  const _OnLocal(this.store);
  final LocalStore store;

  @override
  FutureOr<String?> read(String key) => store.read(key);

  @override
  FutureOr<void> write(String scope, String key, String value) =>
      store.write(key, value);

  @override
  FutureOr<void> delete(String key) => store.delete(key);

  @override
  FutureOr<void> clear(String scope) =>
      store.clear('${scopePrefix(scope)}read/');
}

/// A Riverpod `Storage` keeps no list of its keys, so the keys of a scope are listed under one
/// entry of their own, which is what lets a sign-out wipe them.
final class _OnStorage implements _Raw {
  const _OnStorage(this.storage);
  final Storage<String, String> storage;

  static const _options = StorageOptions(
    cacheTime: StorageCacheTime.unsafe_forever,
  );

  String _index(String scope) => '${scopePrefix(scope)}read-index';

  @override
  FutureOr<String?> read(String key) =>
      andThen(storage.read(key), (saved) => saved?.data);

  @override
  FutureOr<void> write(String scope, String key, String value) {
    final index = _index(scope);
    return andThen<String?, void>(read(index), (saved) {
      final keys = <String>{
        if (saved != null)
          ...(jsonDecode(saved) as List<Object?>).cast<String>(),
      };
      final written = storage.write(key, value, _options);
      if (keys.add(key)) {
        return andThen<void, void>(
          written,
          (_) => storage.write(index, jsonEncode(keys.toList()), _options),
        );
      }
      return written;
    });
  }

  @override
  FutureOr<void> delete(String key) => storage.delete(key);

  @override
  FutureOr<void> clear(String scope) {
    final index = _index(scope);
    return andThen<String?, void>(read(index), (saved) {
      if (saved == null) return null;
      final keys = (jsonDecode(saved) as List<Object?>).cast<String>();
      return andThen<List<void>, void>(
        allOf<void>([for (final key in keys) storage.delete(key)]),
        (_) => storage.delete(index),
      );
    });
  }
}

/// The read cache: served answers by key, with their `fetchedAt` and scope.
///
/// It is a cache, so it can sit on any Riverpod `Storage<String, String>`, including
/// fespalier_storage's `PrefsDataStorage` or `HiveDataStorage` (budgeted eviction is fine for a
/// cache), or on a [LocalStore]. A saved answer that is not readable, or was saved under another
/// `ServedCodec.version`, is dropped and counts as nothing saved.
final class ReadCache {
  /// A cache on [storage]: the one the app already opens in `startup()` for `dataCacheStorage`.
  ReadCache.storage(Storage<String, String> storage)
    : _raw = _OnStorage(storage);

  /// A cache on [store], under the scope's prefix, so a sign-out's `clear` takes it too.
  ReadCache.local(LocalStore store) : _raw = _OnLocal(store);

  final _Raw _raw;

  /// The answer saved for [key] under [scope] with this [version], or null.
  FutureOr<CachedAnswer?> read(String scope, String key, String version) {
    final full = _key(scope, key);
    return andThen<String?, CachedAnswer?>(_raw.read(full), (text) {
      if (text == null) return null;
      try {
        final map = jsonDecode(text) as Map<String, Object?>;
        if (map['v'] != version) throw const FormatException('version');
        return CachedAnswer(
          map['d'],
          DateTime.fromMillisecondsSinceEpoch(map['at']! as int),
        );
      } on Object {
        return andThen<void, CachedAnswer?>(_raw.delete(full), (_) => null);
      }
    });
  }

  /// Saves [json] for [key] under [scope], as of [at].
  FutureOr<void> write(
    String scope,
    String key,
    String version,
    Object? json,
    DateTime at,
  ) => _raw.write(
    scope,
    _key(scope, key),
    jsonEncode({'v': version, 'at': at.millisecondsSinceEpoch, 'd': json}),
  );

  /// Deletes every answer of [scope].
  FutureOr<void> clear(String scope) => _raw.clear(scope);
}

/// The read cache the app provides; by default on the [localStore].
final readCache = Provider<ReadCache>(
  (ref) => ReadCache.local(ref.watch(localStore)),
);
