// What a draft is on disk, and nothing about forms: the key, the entry, the index. The only file of
// the package that touches a `Storage`. Every call is guarded, because a draft is a convenience and
// a storage that throws must never cost the page; and none of it creates a Future unless the
// storage's own answer is one.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier/persist.dart';
import 'package:flutter/foundation.dart';

/// The storage key that lists every draft key, for `clearFormDrafts`.
const draftIndexKey = 'fespalier_forms.drafts';

/// The version of the entry's JSON, the `v` in `{"v":1,"fields":{...}}`.
const draftEntryVersion = 1;

/// How many times every draft was cleared. A form remembers the number it started under and writes
/// nothing once it is another: a page that goes after `clearFormDrafts` (a sign-out) must not put
/// what it held back on the disk.
int get draftClearGeneration => _generation;
int _generation = 0;

/// A key part as the URL spells it, so a key is the same across starts (the rule `dataCache`
/// follows for a family key).
Object? _part(Object? part) {
  if (part == null || part is String || part is bool) return part;
  if (part is num) return part.isFinite ? part : '$part';
  if (part is Enum) return part.name;
  if (part is DateTime) return part.toIso8601String();
  if (part is Iterable<Object?>) return [for (final p in part) _part(p)];
  return '$part';
}

/// `fespalier_forms.draft:<id>:<key>[:<scope>]`: [id] is the action's file and name, [key] the
/// action's family key and [scope] the app's `formDraftScope`.
String draftKey(String id, List<Object?> key, String? scope) =>
    'fespalier_forms.draft:$id:${jsonEncode([for (final p in key) _part(p)])}'
    '${scope == null ? '' : ':$scope'}';

/// Calls [then] with [value], now when it is one, when it completes when it is a Future.
FutureOr<R> _then<T, R>(
  FutureOr<T> value,
  FutureOr<R> Function(T value) then,
) => value is Future<T> ? value.then(then) : then(value);

void _report(String what, Object error) {
  if (kDebugMode) debugPrint('fespalier_forms: draft $what: $error');
}

/// Runs [body]; what it throws, now or later, is reported and [fallback] is the answer.
FutureOr<R> _guard<R>(String what, R fallback, FutureOr<R> Function() body) {
  try {
    final result = body();
    if (result is Future<R>) {
      return result.then<R>(
        (value) => value,
        onError: (Object error, StackTrace _) {
          _report(what, error);
          return fallback;
        },
      );
    }
    return result;
  } on Object catch (error) {
    _report(what, error);
    return fallback;
  }
}

/// What reaches a storage's index one at a time: the index is read, changed and written back, and
/// two of those at once on a storage that answers later would lose a key.
final Expando<Future<void>> _pending = Expando<Future<void>>('draft index');

FutureOr<void> _serial(
  Storage<String, String> storage,
  FutureOr<void> Function() body,
) {
  final before = _pending[storage];
  if (before == null) {
    final result = body();
    if (result is! Future<void>) return null;
    _track(storage, result);
    return result;
  }
  // What came before failed or not, this still runs: a failed index write must not drop a clear.
  final next = before.then<void>(
    (_) => body(),
    onError: (Object _, StackTrace _) => body(),
  );
  _track(storage, next);
  return next;
}

void _track(Storage<String, String> storage, Future<void> future) {
  _pending[storage] = future;
  unawaited(
    future
        .whenComplete(() {
          if (identical(_pending[storage], future)) _pending[storage] = null;
        })
        .onError<Object>((_, _) {}),
  );
}

const _forever = StorageOptions(cacheTime: StorageCacheTime.unsafe_forever);

FutureOr<List<String>> _readIndex(Storage<String, String> storage) =>
    _then<PersistedData<String>?, List<String>>(storage.read(draftIndexKey), (
      saved,
    ) {
      if (saved == null) return <String>[];
      try {
        return [for (final k in jsonDecode(saved.data) as List) k as String];
      } on Object {
        return <String>[];
      }
    });

FutureOr<void> _writeIndex(
  Storage<String, String> storage,
  List<String> keys,
) => keys.isEmpty
    ? storage.delete(draftIndexKey)
    : storage.write(draftIndexKey, jsonEncode(keys), _forever);

/// Lists or unlists [key]; always inside a [_serial] of its caller.
FutureOr<void> _index(
  Storage<String, String> storage,
  String key, {
  required bool add,
}) => _then<List<String>, void>(_readIndex(storage), (keys) {
  // Listing a key again rewrites the index, so it is never older than the draft it lists (a
  // storage that evicts the entry written longest ago drops a draft before its index).
  if (!add && !keys.contains(key)) return null;
  return _writeIndex(storage, [
    for (final k in keys)
      if (k != key) k,
    if (add) key,
  ]);
});

/// What a draft holds: the saved [fields], and, for a multi-page form (since 0.11.0), the names
/// of the [steps] that were done.
typedef DraftEntry = ({Map<String, Object?> fields, List<String> steps});

/// The saved fields of the draft under [key], or null when there is none, it is older than its
/// `maxAge`, or it was saved for another [shape] or entry version (those are deleted).
FutureOr<Map<String, Object?>?> loadDraft(
  Storage<String, String> storage,
  String key,
  String shape,
) => _then<DraftEntry?, Map<String, Object?>?>(
  loadDraftEntry(storage, key, shape),
  (entry) => entry?.fields,
);

/// [loadDraft] with the steps a multi-page form had done.
FutureOr<DraftEntry?> loadDraftEntry(
  Storage<String, String> storage,
  String key,
  String shape,
) => _guard<DraftEntry?>(
  'could not be read',
  null,
  () => _then<PersistedData<String>?, DraftEntry?>(storage.read(key), (saved) {
    if (saved == null) return null;
    final expired = saved.expireAt?.isBefore(clock.now()) ?? false;
    if (expired || saved.destroyKey != shape) {
      _drop(storage, key);
      return null;
    }
    try {
      final entry = jsonDecode(saved.data) as Map<String, Object?>;
      if (entry['v'] != draftEntryVersion) throw const FormatException('v');
      return (
        fields: Map<String, Object?>.of(
          entry['fields']! as Map<String, Object?>,
        ),
        steps: [
          for (final s in (entry['steps'] as List? ?? const [])) s as String,
        ],
      );
    } on Object {
      _drop(storage, key);
      return null;
    }
  }),
);

void _drop(Storage<String, String> storage, String key) {
  if (removeDraft(storage, key) case final Future<void> pending) {
    unawaited(pending);
  }
}

/// Saves [fields] under [key], for [maxAge] and the [shape] of the form, and lists the key. A
/// multi-page form saves the [steps] it has done too.
FutureOr<void> saveDraft(
  Storage<String, String> storage,
  String key,
  String shape,
  Duration maxAge,
  Map<String, Object?> fields, {
  int? generation,
  List<String>? steps,
}) => _guard<void>(
  'could not be saved',
  null,
  () => _serial(storage, () {
    // Queued before a clear, run after it: what a signed-out account typed is not kept.
    if (generation != null && generation != _generation) return null;
    return _then<void, void>(
      storage.write(
        key,
        jsonEncode({'v': draftEntryVersion, 'fields': fields, 'steps': ?steps}),
        StorageOptions(cacheTime: StorageCacheTime(maxAge), destroyKey: shape),
      ),
      (_) => _index(storage, key, add: true),
    );
  }),
);

/// Deletes the draft under [key] and takes it off the index.
FutureOr<void> removeDraft(Storage<String, String> storage, String key) =>
    _guard<void>(
      'could not be deleted',
      null,
      () => _serial(
        storage,
        () => _then<void, void>(
          storage.delete(key),
          (_) => _index(storage, key, add: false),
        ),
      ),
    );

/// Deletes every draft the index lists, then the index.
FutureOr<void> clearDrafts(Storage<String, String> storage) {
  _generation++;
  return _clear(storage);
}

FutureOr<void> _clear(Storage<String, String> storage) => _guard<void>(
  'could not be cleared',
  null,
  () => _serial(
    storage,
    () => _then<List<String>, void>(_readIndex(storage), (keys) async {
      for (final key in keys) {
        await storage.delete(key);
      }
      await storage.delete(draftIndexKey);
    }),
  ),
);
