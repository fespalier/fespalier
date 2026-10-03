// The one runtime file that touches Riverpod's experimental offline persistence
// (`experimental/persist.dart`), with `lib/persist.dart`, which only re-exports it. If a
// Riverpod 3.x minor changes that API, this is the file that changes; `data_cache_test.dart`
// is the tripwire. Generated code calls `cachedData` and `cachedDataFamily` only.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/experimental/persist.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show AsyncNotifierProviderFamily;

import 'freshness.dart';

/// How a data.dart's value is saved for the next start (since 0.8.1):
/// `final dataCache = DataCache<Product>.json(toJson: ..., fromJson: ...);`.
///
/// Nothing is saved unless the app gives a [dataCacheStorage]. It is built on Riverpod 3's
/// experimental offline persistence.
final class DataCache<T> {
  /// A cache that saves `encode(value)` and reads it back with `decode(saved)`.
  const DataCache({
    required this.encode,
    required this.decode,
    this.maxAge = const Duration(days: 2),
    this.version,
  });

  /// Saved as `jsonEncode(toJson(value))`, read back as `fromJson(jsonDecode(saved))`.
  DataCache.json({
    required Object? Function(T value) toJson,
    required T Function(Object? json) fromJson,
    this.maxAge = const Duration(days: 2),
    this.version,
  }) : encode = ((value) => jsonEncode(toJson(value))),
       decode = ((saved) => fromJson(jsonDecode(saved)));

  /// Turns a value into the string that is saved.
  final String Function(T value) encode;

  /// Turns a saved string back into a value. If it throws, the saved value is dropped.
  final T Function(String saved) decode;

  /// How long a saved value may be shown at a start (Riverpod's `StorageCacheTime`).
  final Duration maxAge;

  /// Change it when what [encode] writes changes shape: saved values of another
  /// version are dropped, not decoded (Riverpod's `destroyKey`).
  final String? version;
}

/// Where `dataCache` values are saved (since 0.8.1). Null (the default) saves nothing.
///
/// Override it in the app's `ProviderScope`:
/// `dataCacheStorage.overrideWithValue(MemoryDataStorage())`, or a
/// `Storage<String, String>` on disk such as riverpod_sqflite's
/// `JsonSqFliteStorage.open(path)` (a `Future` is fine; a storage whose `read` is
/// synchronous shows the saved value on the first frame).
///
/// Its type is `FutureOr<Storage<String, String>?>`, not `FutureOr<Storage<String, String>>?`:
/// Dart rejects a `null` cast to a `FutureOr<FutureOr<T>?>`, which Riverpod's provider
/// makes of the second.
final dataCacheStorage = Provider<FutureOr<Storage<String, String>?>>(
  (ref) => null,
);

/// A `Storage<String, String>` in memory (since 0.8.1): values survive a page being
/// disposed and opened again, not a restart. For the web, examples and tests.
///
/// Share one between two `pumpRouter` calls to simulate a restart. Its methods are
/// synchronous, so a test leaves no pending future behind.
final class MemoryDataStorage extends Storage<String, String> {
  /// Creates an empty storage.
  MemoryDataStorage();

  final Map<String, PersistedData<String>> _entries = {};

  @override
  PersistedData<String>? read(String key) => _entries[key];

  @override
  void write(String key, String value, StorageOptions options) {
    final duration = options.cacheTime.duration;
    _entries[key] = PersistedData(
      value,
      destroyKey: options.destroyKey,
      expireAt: duration == null ? null : clock.now().toUtc().add(duration),
    );
  }

  @override
  void delete(String key) {
    _entries.remove(key);
  }

  @override
  void deleteOutOfDate() {
    // Nothing outlives the process.
  }
}

void _report(String name, String what, Object error) {
  if (kDebugMode) debugPrint('fespalier: dataCache of $name $what: $error');
}

/// A key part as the URL spells it, so that a key is the same across starts.
Object? _part(Object? part) {
  if (part == null || part is String || part is bool) return part;
  if (part is num) return part.isFinite ? part : '$part';
  if (part is Enum) return part.name;
  if (part is DateTime) return part.toIso8601String();
  if (part is Iterable<Object?>) return [for (final p in part) _part(p)];
  return '$part';
}

/// What `build` saves and restores [CachedData]'s value through: the app's storage, with
/// the two behaviours of Riverpod's `persist` that would hurt left out. A failed fetch
/// does not delete the saved value (Riverpod deletes it on any error, so an offline start
/// would lose the cache for the next one), and a value that does not decode is dropped
/// quietly instead of reported as an error. A storage that throws never becomes the
/// route's error.
final class _GuardedStorage<T> extends Storage<String, String> {
  _GuardedStorage(this._inner, this._owner) {
    _built = true;
  }

  final Storage<String, String> _inner;
  final CachedData<T> _owner;
  var _built = false;

  @override
  void deleteOutOfDate() {
    // Called by the constructor too; the wrapped storage swept when it was made.
    if (_built) _inner.deleteOutOfDate();
  }

  @override
  FutureOr<PersistedData<String>?> read(String key) {
    try {
      final saved = _inner.read(key);
      if (saved is Future<PersistedData<String>?>) {
        return saved.then(
          (value) => _decode(key, value),
          onError: (Object error, StackTrace _) => _unreadable(key, error),
        );
      }
      return _decode(key, saved);
    } on Object catch (error) {
      return _unreadable(key, error);
    }
  }

  PersistedData<String>? _decode(String key, PersistedData<String>? saved) {
    if (saved == null) return null;
    // A slow storage can answer after the load did: Riverpod would then replace the fresh
    // value with the saved one, for good. The saved value is of no use any more.
    if (_owner._hasFreshValue) return null;
    try {
      _owner._decoded = _owner._cache.decode(saved.data);
      return saved;
    } on Object catch (error) {
      return _unreadable(key, error);
    }
  }

  PersistedData<String>? _unreadable(String key, Object error) {
    _report(_owner._name, 'could not read a saved value, dropped it', error);
    try {
      final done = _inner.delete(key);
      if (done is Future<void>) unawaited(done.onError<Object>((_, _) {}));
    } on Object {
      // Nothing more to do about it.
    }
    return null;
  }

  @override
  FutureOr<void> write(String key, String value, StorageOptions options) {
    // A value that did not encode is not saved (the failure was reported by `encode`).
    if (_owner._encodeFailed) return null;
    try {
      final done = _inner.write(key, value, options);
      if (done is Future<void>) {
        return done.onError<Object>(
          (error, _) => _report(_owner._name, 'could not save', error),
        );
      }
    } on Object catch (error) {
      _report(_owner._name, 'could not save', error);
    }
    return null;
  }

  @override
  FutureOr<void> delete(String key) {
    // Riverpod deletes the saved value when the state is an error; keep it: the next start
    // can still show it. The deletes for an expired value and a changed `version` happen
    // while the state is loading, so they go through.
    if (_owner._stateHasError) return null;
    try {
      final done = _inner.delete(key);
      if (done is Future<void>) {
        return done.onError<Object>(
          (error, _) => _report(_owner._name, 'could not save', error),
        );
      }
    } on Object catch (error) {
      _report(_owner._name, 'could not save', error);
    }
    return null;
  }
}

/// What a `Future<Storage>` that completes with null is: nothing is read or saved.
final class _NoStorage extends Storage<String, String> {
  @override
  PersistedData<String>? read(String key) => null;

  @override
  void write(String key, String value, StorageOptions options) {}

  @override
  void delete(String key) {}

  @override
  void deleteOutOfDate() {}
}

/// The provider fespalier makes of a data() function with a `dataCache` (since 0.8.1): the
/// function's value, saved with [dataCacheStorage] and shown at the next start while the
/// fresh one loads (`AsyncValue.isFromCache` is then true).
///
/// An optimistic update must not be written with `state =` on it: every `AsyncData` the
/// notifier sets is saved.
final class CachedData<T> extends AsyncNotifier<T> {
  CachedData._(
    this._fetch,
    this._cache,
    this._name,
    this._key,
    this._freshness,
  );

  final FutureOr<T> Function(Ref ref) _fetch;
  final DataCache<T> _cache;
  final String _name;
  final String _key;
  final Freshness? _freshness;

  /// What `_GuardedStorage.read` decoded, for the `decode` that `persist` calls next.
  Object? _decoded;
  bool _encodeFailed = false;

  bool get _hasFreshValue {
    try {
      return state is AsyncData<T>;
    } on Object {
      return false;
    }
  }

  bool get _stateHasError {
    try {
      return state.hasError;
    } on Object {
      return false;
    }
  }

  String _encode(T value) {
    try {
      final saved = _cache.encode(value);
      _encodeFailed = false;
      return saved;
    } on Object catch (error) {
      _encodeFailed = true;
      _report(_name, 'could not save', error);
      return '';
    }
  }

  T _restore(String _) {
    final value = _decoded as T;
    _decoded = null;
    return value;
  }

  FutureOr<Storage<String, String>> _guard(
    FutureOr<Storage<String, String>?> storage,
  ) {
    if (storage is Future<Storage<String, String>?>) {
      // A Future that completes with null saves nothing.
      return storage.then(
        (Storage<String, String>? s) =>
            _GuardedStorage<T>(s ?? _NoStorage(), this),
      );
    }
    return _GuardedStorage<T>(storage ?? _NoStorage(), this);
  }

  @override
  FutureOr<T> build() {
    final storage = ref.watch(dataCacheStorage);
    if (storage != null) {
      persist<String, String>(
        _guard(storage),
        key: _key,
        encode: _encode,
        decode: _restore,
        options: StorageOptions(
          cacheTime: StorageCacheTime(_cache.maxAge),
          destroyKey: _cache.version,
        ),
      );
    }
    final value = _fetch(ref);
    final freshness = _freshness;
    return freshness == null ? value : freshData(ref, freshness, value);
  }
}

/// The provider of a data() function without keys, with a `dataCache` (since 0.8.1).
/// What the generated code calls; `T` is inferred from [fetch].
///
/// [name] is the data.dart's folder relative to the app folder (`products/$id`), which
/// keeps the saved key stable across `fsp gen`.
AsyncNotifierProvider<CachedData<T>, T> cachedData<T>(
  FutureOr<T> Function(Ref ref) fetch, {
  required DataCache<T> cache,
  required String name,
  Freshness? freshness,
  Duration? Function(int retryCount, Object error)? retry,
}) => AsyncNotifierProvider.autoDispose<CachedData<T>, T>(
  () => CachedData<T>._(fetch, cache, name, 'fespalier:$name', freshness),
  retry: retry,
);

/// The family of a data() function with keys, with a `dataCache` (since 0.8.1). What the
/// generated code calls; `T` and `K` are inferred from [fetch].
///
/// [keyParts] lists the key's parts in path order (`[id]`, `[k.shop, k.id]`); each is
/// saved as the URL spells it, so a custom segment type's `toString()` must be stable.
AsyncNotifierProviderFamily<CachedData<T>, T, K> cachedDataFamily<T, K>(
  FutureOr<T> Function(Ref ref, K key) fetch, {
  required DataCache<T> cache,
  required String name,
  required List<Object?> Function(K key) keyParts,
  Freshness? freshness,
  Duration? Function(int retryCount, Object error)? retry,
}) => AsyncNotifierProvider.autoDispose.family<CachedData<T>, T, K>(
  (key) => CachedData<T>._(
    (ref) => fetch(ref, key),
    cache,
    name,
    'fespalier:$name${jsonEncode([for (final p in keyParts(key)) _part(p)])}',
    freshness,
  ),
  retry: retry,
);
