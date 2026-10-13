import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_ce/hive.dart';

import 'local_store.dart';

/// A durable [LocalStore] on a hive_ce `Box<String>` that never evicts (since 0.10.0).
///
/// Reads are synchronous once the box is open, so a `localOnly` read is on the first frame; the web
/// keeps the box in IndexedDB. It is unbounded on purpose: an intent never expires and an unpushed
/// row is the only copy of an edit, which is why this is not a fespalier_storage storage (those
/// evict the entries written longest ago).
///
/// One writer per box. Hive keys are at most 255 UTF-8 bytes: a collection or a row id long enough
/// to pass that is the app's to shorten.
final class HiveLocalStore implements LocalStore {
  /// A store over [box], open. The box may hold other entries: only String keys are listed.
  HiveLocalStore(this._box);

  final Box<String> _box;

  /// Opens the box [name] in [directory] without touching Hive's global home. [directory] is
  /// required off the web (an app passes `getApplicationSupportDirectory()`'s path, not a cache
  /// directory: the system may empty a cache); on the web it is ignored.
  static Future<HiveLocalStore> open({
    String name = 'fespalier_cratestack',
    String? directory,
  }) async {
    if (!kIsWeb && directory == null) {
      throw ArgumentError.value(
        directory,
        'directory',
        'fespalier_cratestack: HiveLocalStore.open needs a directory off the web '
            '(a folder the system does not empty, e.g. the application support directory)',
      );
    }
    final box = await Hive.openBox<String>(
      name,
      path: kIsWeb ? null : directory,
    );
    return HiveLocalStore(box);
  }

  @override
  String? read(String key) => _box.get(key);

  @override
  Future<void> write(String key, String value) => _box.put(key, value);

  @override
  Future<void> writeAll(Map<String, String> entries) => _box.putAll(entries);

  @override
  Future<void> delete(String key) => _box.delete(key);

  @override
  List<String> keys(String prefix) => [
    for (final key in _box.keys)
      if (key is String && key.startsWith(prefix)) key,
  ]..sort();

  @override
  Future<void> clear(String prefix) => _box.deleteAll(keys(prefix));

  /// Closes the box.
  Future<void> close() => _box.close();
}
