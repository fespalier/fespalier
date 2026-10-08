/// What tests use from fespalier_frb (since 0.13.0).
library;

import 'dart:async';

export 'package:fespalier_frb/fespalier_frb.dart'
    show Change, ChangeFeed, InvalidationRule, InvalidationTable;

/// A fake Rust core's change stream (since 0.13.0): fed by the test, counting its listeners.
///
/// `ChangeFeed((ref) => fake.stream)` is the feed under test. Events are delivered **synchronously**
/// to the one subscription (a broadcast controller, or a single-subscription one with
/// `broadcast: false`, like flutter_rust_bridge's streams, which refuse a second listener).
final class FakeChangeSource<E> {
  /// Creates a source. [broadcast] false makes it single-subscription, like a generated stream.
  FakeChangeSource({bool broadcast = true}) {
    void listened() => listenCount++;
    void cancelled() => cancelCount++;
    _controller = broadcast
        ? StreamController<E>.broadcast(
            sync: true,
            onListen: listened,
            onCancel: cancelled,
          )
        : StreamController<E>(
            sync: true,
            onListen: listened,
            onCancel: cancelled,
          );
  }

  late final StreamController<E> _controller;

  /// How many times the stream was listened to: 1 for any number of topics.
  int listenCount = 0;

  /// How many times a listener cancelled (a container's disposal does).
  int cancelCount = 0;

  /// The stream a feed opens.
  Stream<E> get stream => _controller.stream;

  /// Whether someone is subscribed now.
  bool get hasListener => _controller.hasListener;

  /// Delivers [event].
  void emit(E event) => _controller.add(event);

  /// Delivers an error.
  void emitError(Object error) => _controller.addError(error);

  /// Ends the stream.
  Future<void> close() => _controller.close();
}
