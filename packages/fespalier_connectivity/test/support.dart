import 'dart:async';

import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter/foundation.dart';

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

/// A source a test drives by hand: a late `check()` answer, an error on the stream, a `check()` that throws.
final class ScriptedSource implements ConnectivitySource {
  /// The answers `check()` waits for, in order.
  final answers = <Completer<List<ConnectivityResult>>>[];

  /// How many times `check()` ran.
  var checks = 0;

  /// What `check()` throws, synchronously, when set.
  Object? checkThrows;

  /// What the `changes` getter throws, when set.
  Object? changesThrows;

  final controller = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );

  @override
  Stream<List<ConnectivityResult>> get changes {
    final error = changesThrows;
    if (error != null) throw error;
    return controller.stream;
  }

  @override
  Future<List<ConnectivityResult>> check() {
    checks++;
    final error = checkThrows;
    if (error != null) throw error;
    final answer = Completer<List<ConnectivityResult>>();
    answers.add(answer);
    return answer.future;
  }
}

/// Lets what a test left on the microtask queue run.
Future<void> turn() => Future<void>.delayed(Duration.zero);

/// A [FakeConnectivity] that is `[none]` and `[wifi]`: a convenience for the lists a test writes.
const none = [ConnectivityResult.none];
const wifi = [ConnectivityResult.wifi];
const mobile = [ConnectivityResult.mobile];
