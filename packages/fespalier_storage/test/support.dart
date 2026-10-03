import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier_storage/src/bounded.dart';
import 'package:flutter/foundation.dart';

/// A store that is a map, with the failures a test asks for.
final class MapStore implements EntryStore {
  MapStore([Map<String, Object> values = const {}]) : values = {...values};

  /// What is stored: strings, and anything else a test plants (a value that is not a string).
  final Map<String, Object> values;

  /// Every key a put or a remove was asked for, in order.
  final puts = <String>[];
  final removes = <String>[];

  /// What a put or a remove fails with, when set.
  Object? putError;
  Object? removeError;

  /// Completers the next puts wait on, in order: one that completes with an error fails that put.
  final gates = <Completer<void>>[];

  @override
  Iterable<String> get keys => values.keys.toList();

  @override
  String? get(String key) => values[key] as String?;

  @override
  Future<void> put(String key, String value) async {
    puts.add(key);
    if (gates.isNotEmpty) await gates.removeAt(0).future;
    final error = putError;
    if (error != null) throw error;
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    removes.add(key);
    final error = removeError;
    if (error != null) throw error;
    values.remove(key);
  }

  /// The keys of this storage's entries in the map, sorted.
  List<String> get ours => [
    for (final key in values.keys)
      if (key.startsWith(storedKeyPrefix))
        key.substring(storedKeyPrefix.length),
  ]..sort();
}

/// A storage over a [MapStore] and nothing else, so the base class is tested on its own.
final class TestStorage extends BoundedDataStorage {
  // `store` is a MapStore, which a super parameter (an EntryStore) would not say.
  // ignore: use_super_parameters
  TestStorage(
    MapStore store, {
    super.maxSize = 100000,
    super.maxEntries = 100,
    super.maxKeyBytes,
  }) : super(store);
}

/// Runs [body] with the clock stopped at [time].
T at<T>(DateTime time, T Function() body) => withClock(Clock.fixed(time), body);

/// Runs [body] with `debugPrint` captured, and returns the lines it printed.
Future<List<String>> printed(FutureOr<void> Function() body) async {
  final lines = <String>[];
  final original = debugPrint;
  debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  try {
    await body();
  } finally {
    debugPrint = original;
  }
  return lines;
}
