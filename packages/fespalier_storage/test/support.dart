import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

// The base class's own test helpers (MapStore, TestStorage) are fespalier_storage_hive's, with the base class.

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
