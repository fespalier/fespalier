import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'bounded.dart';

/// A Hive box as an [EntryStore]: the box may hold other entries, so only the String keys are listed.
final class _BoxStore implements EntryStore {
  const _BoxStore(this._box);

  final Box<String> _box;

  @override
  Iterable<String> get keys => [
    for (final key in _box.keys)
      if (key is String) key,
  ];

  @override
  String? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, String value) => _box.put(key, value);

  @override
  Future<void> remove(String key) => _box.delete(key);
}

/// A dataCache storage on a hive_ce `Box<String>` (since 0.9.0): synchronous reads once the box is open, so a saved
/// value is on the first frame; IndexedDB on the web; for more or larger values than shared preferences should hold.
/// Opening reads the whole box, so [maxSize] also bounds the startup cost.
///
/// Hive takes keys of at most 255 UTF-8 bytes: a dataCache key that would be longer is stored under the SHA-256 of it.
///
/// One writer per box: a background isolate that writes the same box makes the index stale until the next start.
final class HiveDataStorage extends BoundedDataStorage {
  /// A storage over [box], open. The box may hold other entries: this storage only touches keys under its prefix.
  HiveDataStorage(
    Box<String> box, {
    super.maxSize = defaultMaxSize,
    super.maxEntries = defaultMaxEntries,
  }) : _box = box,
       super(_BoxStore(box), maxKeyBytes: 255);

  /// 4,000,000 characters.
  static const defaultMaxSize = 4000000;

  /// 1,000 entries.
  static const defaultMaxEntries = 1000;

  final Box<String> _box;

  /// Opens the box [name] in [directory] (default: path_provider's `getApplicationCacheDirectory()`; none on the
  /// web) without touching Hive's global home, and sweeps it. Null, with a debug line (S5), if it could not open.
  static Future<HiveDataStorage?> open({
    String name = 'fespalier_data_cache',
    String? directory,
    int maxSize = defaultMaxSize,
    int maxEntries = defaultMaxEntries,
  }) async {
    // A budget of 0 is the app's mistake, not a box that cannot open: it throws (S7).
    checkBudget(maxSize, 'maxSize');
    checkBudget(maxEntries, 'maxEntries');
    final HiveDataStorage storage;
    try {
      final path =
          directory ??
          (kIsWeb ? null : (await getApplicationCacheDirectory()).path);
      final box = await Hive.openBox<String>(name, path: path);
      storage = HiveDataStorage(box, maxSize: maxSize, maxEntries: maxEntries);
    } on Object catch (error) {
      if (kDebugMode) {
        debugPrint(
          'fespalier_storage: could not open the Hive box $name, so nothing is saved: $error',
        ); // S5
      }
      return null;
    }
    await storage.sweepDone();
    return storage;
  }

  /// Closes the box.
  Future<void> close() => _box.close();
}
