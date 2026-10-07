import 'dart:async';

import 'package:fespalier/fespalier.dart' show Provider;

/// Durable key-value storage for intents, owned rows, sync cursors and the HLC node id.
///
/// It must never evict: an intent never expires, and an unpushed row is the only copy of an edit.
/// That is why there is no adapter of fespalier_storage's budgeted storages onto this interface.
/// Methods answer synchronously when they can (`FutureOr`), so a local read stays synchronous.
abstract interface class LocalStore {
  /// The value under [key], or null.
  FutureOr<String?> read(String key);

  /// Saves [value] under [key].
  FutureOr<void> write(String key, String value);

  /// Saves [entries] in one transaction where the backend has one.
  FutureOr<void> writeAll(Map<String, String> entries);

  /// Deletes [key].
  FutureOr<void> delete(String key);

  /// Every key that starts with [prefix].
  FutureOr<Iterable<String>> keys(String prefix);

  /// Deletes every key under [prefix] (a sign-out passes the account's prefix).
  FutureOr<void> clear(String prefix);
}

/// A synchronous [LocalStore] in memory: the web without a store, examples and tests. Nothing
/// outlives the process.
final class InMemoryLocalStore implements LocalStore {
  /// An empty store.
  InMemoryLocalStore();

  final Map<String, String> _entries = {};

  @override
  String? read(String key) => _entries[key];

  @override
  void write(String key, String value) => _entries[key] = value;

  @override
  void writeAll(Map<String, String> entries) => _entries.addAll(entries);

  @override
  void delete(String key) => _entries.remove(key);

  @override
  List<String> keys(String prefix) => [
    for (final key in _entries.keys)
      if (key.startsWith(prefix)) key,
  ]..sort();

  @override
  void clear(String prefix) =>
      _entries.removeWhere((k, _) => k.startsWith(prefix));
}

/// The durable store the app provides: `localStore.overrideWithValue(await HiveLocalStore.open())`.
/// In memory by default, which loses every queued intent at exit.
final localStore = Provider<LocalStore>((ref) => InMemoryLocalStore());
