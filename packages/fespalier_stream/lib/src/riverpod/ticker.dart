part of 'live_feed.dart';

/// The tick of every live feed (since 0.25.0): a [RefetchSignal] whose [fire] also sweeps the feeds
/// of its container. It never fires by itself: the app overrides [streamTicker] with a subclass
/// that fires from a timer of its own (the package starts none), every 10 to 30 seconds:
///
/// ```dart
/// final class AppStreamTicker extends StreamTicker {
///   @override
///   int build() {
///     final timer = Timer.periodic(const Duration(seconds: 15), (_) => fire());
///     ref.onDispose(timer.cancel);
///     return super.build();
///   }
/// }
///
/// // ProviderScope(overrides: [streamTicker.overrideWith(AppStreamTicker.new)], ...)
/// ```
///
/// Each tick, for each feed's connection: one that stayed paused since the previous tick is
/// closed (`closeIfPaused`; a resume opens it again, with `Last-Event-ID`), one whose server said
/// nothing for the feed's `LiveRules.idle` is closed (`closeIfIdle`), and one that waits
/// reconnects once its server's retry hint has passed. Without the override, nothing closes a
/// paused connection and a waiting one waits for a `LiveRules.reconnectOn` signal.
///
/// The timer must keep running while every page that watches a feed is paused (stop it in
/// `ref.onDispose`, not in `ref.onCancel`): closing the connections of hidden pages is what the
/// tick is for. It lives as long as a feed does, because each feed holds it.
class StreamTicker extends RefetchSignal {
  final Map<LiveConnection<Object?>, Duration?> _live =
      Map<LiveConnection<Object?>, Duration?>.identity();

  /// Fires the signal, then sweeps the feeds' connections.
  @override
  void fire() {
    super.fire();
    sweep();
  }

  /// One tick's work on every feed's connection, without firing the signal.
  void sweep() {
    final now = clock.now();
    for (final MapEntry(key: connection, value: idle)
        in _live.entries.toList()) {
      if (connection.closeIfPaused()) continue;
      if (idle != null && connection.closeIfIdle(idle)) continue;
      final status = connection.status;
      if (status is LiveWaiting) {
        final hint = status.retryHint;
        if (hint == null || now.difference(status.since) >= hint) {
          connection.reconnect();
        }
      }
    }
  }

  /// How many feed connections the tick looks after: for a test.
  int get trackedCount => _live.length;

  void _track(LiveConnection<Object?> connection, Duration? idle) =>
      _live[connection] = idle;

  void _untrack(LiveConnection<Object?> connection) => _live.remove(connection);
}

/// The tick every live feed follows (since 0.25.0). It never fires by itself: override it with a
/// [StreamTicker] that fires from the app's own timer (see [StreamTicker]), or, in a test, with
/// `ManualStreamTicker` from `package:fespalier_stream/testing.dart`.
final streamTicker = NotifierProvider.autoDispose<StreamTicker, int>(
  StreamTicker.new,
  retry: (_, _) => null,
);
