import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

import 'bounded.dart';

/// shared_preferences' cache as an [EntryStore].
final class _PrefsStore implements EntryStore {
  const _PrefsStore(this._prefs);

  final SharedPreferencesWithCache _prefs;

  @override
  Iterable<String> get keys => _prefs.keys;

  @override
  String? get(String key) => _prefs.getString(key);

  @override
  Future<void> put(String key, String value) => _prefs.setString(key, value);

  @override
  Future<void> remove(String key) => _prefs.remove(key);
}

/// A dataCache storage on shared_preferences' `SharedPreferencesWithCache` (since 0.9.0): reads are synchronous,
/// so a saved value is on the first frame. On the web it is localStorage (about 5 MB per origin, shared with
/// everything else there): keep [maxSize] well below.
///
/// ```dart
/// Future<List<Override>> startup() async => [
///   dataCacheStorage.overrideWithValue(await PrefsDataStorage.open()),
/// ];
/// ```
///
/// One writer per store: a background isolate that writes the same store makes the index stale until the next start.
final class PrefsDataStorage extends BoundedDataStorage {
  /// A storage over [prefs], which must have no allowList (the keys of a dataCache are not known in advance): an
  /// ArgumentError (S6) says so otherwise.
  PrefsDataStorage(
    SharedPreferencesWithCache prefs, {
    super.maxSize = defaultMaxSize,
    super.maxEntries = defaultMaxEntries,
  }) : super(_PrefsStore(_withoutAllowList(prefs)));

  /// 1,000,000 characters.
  static const defaultMaxSize = 1000000;

  /// 200 entries.
  static const defaultMaxEntries = 200;

  /// Creates its own `SharedPreferencesWithCache` (no allowList; [options] for the platform), sweeps it and waits
  /// for the sweep's deletes. Null, with a debug line (S4), if shared preferences could not open: the app starts
  /// and nothing is saved.
  static Future<PrefsDataStorage?> open({
    SharedPreferencesOptions options = const SharedPreferencesOptions(),
    int maxSize = defaultMaxSize,
    int maxEntries = defaultMaxEntries,
  }) async {
    // A budget of 0 is the app's mistake, not a store that cannot open: it throws (S7).
    checkBudget(maxSize, 'maxSize');
    checkBudget(maxEntries, 'maxEntries');
    final PrefsDataStorage storage;
    try {
      final prefs = await SharedPreferencesWithCache.create(
        sharedPreferencesOptions: options,
        cacheOptions: const SharedPreferencesWithCacheOptions(),
      );
      storage = PrefsDataStorage(
        prefs,
        maxSize: maxSize,
        maxEntries: maxEntries,
      );
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint(
          'fespalier_storage: could not open shared preferences, so nothing is saved: $error',
        ); // S4
      }
      return null;
    }
    await storage.sweepDone();
    return storage;
  }
}

/// [prefs] itself, or the S6 error when it has an allowList: a key outside one throws an ArgumentError.
SharedPreferencesWithCache _withoutAllowList(SharedPreferencesWithCache prefs) {
  try {
    prefs.containsKey(storedKeyPrefix);
  } on ArgumentError {
    throw ArgumentError(
      'PrefsDataStorage needs a SharedPreferencesWithCache without an allowList: the keys of a dataCache are not '
      'known in advance. Use PrefsDataStorage.open(), or create it with const SharedPreferencesWithCacheOptions().',
    );
  }
  return prefs;
}
