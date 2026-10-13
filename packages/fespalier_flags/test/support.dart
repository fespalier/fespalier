import 'dart:async';
import 'dart:io' show Platform;

import 'package:fespalier_flags/fespalier_flags.dart';
import 'package:flutter/foundation.dart';

/// Whether the Flutter is older than 3.44 (Dart below 3.12), the floor, 3.35, included, and so
/// resolves go_router 17 at most. go_router 17 builds the page that a location change lands on
/// one frame after the change; go_router 18 builds it in the same frame.
final bool onGoRouter17 =
    int.parse(RegExp(r'^3\.(\d+)').firstMatch(Platform.version)![1]!) < 12;

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

/// A source that counts what is asked of it: reads by key, `changes` getters, and who listens.
final class CountingFlags implements FlagSource {
  CountingFlags([Map<String, Object> values = const {}]) : values = {...values};

  final Map<String, Object> values;

  /// How many times each key was read.
  final reads = <String, int>{};

  /// How many `changes` getters ran.
  var changesGets = 0;

  /// What a read of a key throws, by key.
  final throwing = <String, Object>{};

  late final StreamController<FlagsChanged> _controller =
      StreamController<FlagsChanged>.broadcast(
        sync: true,
        onListen: () {
          listening++;
          final replayed = replay;
          if (replayed != null) _controller.add(replayed);
        },
        onCancel: () => listening--,
      );

  /// 1 while something listens (a broadcast controller reports its first listener and its last).
  var listening = 0;

  /// Whether `changes` is null (a source whose values never change).
  bool staticValues = false;

  /// What the `changes` getter throws, when set.
  Object? changesThrows;

  /// An event sent to each listener while it is being added: one replayed during `listen`.
  FlagsChanged? replay;

  Object? _read(String key) {
    reads[key] = (reads[key] ?? 0) + 1;
    final error = throwing[key];
    if (error != null) throw error;
    return values[key];
  }

  /// Sets [key] and tells the listeners that only [key] changed.
  void set(String key, Object value) {
    values[key] = value;
    _controller.add(FlagsChanged({key}));
  }

  /// Sends [event] to the listeners.
  void send(FlagsChanged event) => _controller.add(event);

  /// Sends [error] to the listeners.
  void sendError(Object error) => _controller.addError(error);

  int get totalReads => reads.values.fold(0, (a, b) => a + b);

  @override
  bool boolValue(String key, bool fallback) => switch (_read(key)) {
    final bool v => v,
    _ => fallback,
  };

  @override
  String stringValue(String key, String fallback) => switch (_read(key)) {
    final String v => v,
    _ => fallback,
  };

  @override
  int intValue(String key, int fallback) => switch (_read(key)) {
    final int v => v,
    _ => fallback,
  };

  @override
  double doubleValue(String key, double fallback) => switch (_read(key)) {
    final num v => v.toDouble(),
    _ => fallback,
  };

  @override
  Stream<FlagsChanged>? get changes {
    changesGets++;
    final error = changesThrows;
    if (error != null) throw error;
    if (staticValues) return null;
    return _controller.stream;
  }
}
