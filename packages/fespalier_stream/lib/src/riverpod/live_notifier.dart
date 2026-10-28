part of 'live_feed.dart';

final class _Spec<T, K> {
  _Spec(this.connect, this.rules);

  final LiveConnection<T> Function(Ref ref, K key, String? lastEventId) connect;
  final LiveRules rules;
}

/// The status of a feed across its connections: what [LiveFeed.status] streams. It starts with
/// the current one for each listener.
final class _StatusHub {
  LiveStatus _current = const LiveConnecting(1);
  final Set<MultiStreamController<LiveStatus>> _watchers =
      <MultiStreamController<LiveStatus>>{};

  Stream<LiveStatus> get stream => Stream<LiveStatus>.multi((controller) {
    controller.add(_current);
    _watchers.add(controller);
    controller.onCancel = () => _watchers.remove(controller);
  }, isBroadcast: true);

  void _set(LiveStatus status) {
    if (status == _current) return;
    _current = status;
    for (final watcher in _watchers.toList()) {
      watcher.add(status);
    }
  }

  /// Copies [connection]'s statuses while [isCurrent] says it is the feed's connection. The
  /// `await for` is the subscription, and it ends with the connection (its statuses end at
  /// `LiveDone`).
  Future<void> follow(
    LiveConnection<Object?> connection,
    bool Function() isCurrent,
  ) async {
    await for (final status in connection.statusChanges) {
      if (!isCurrent()) return;
      _set(status);
    }
  }
}

final Object _unseen = Object();

/// The notifier of one feed (or one key of a family). Its instance outlives its rebuilds, so its
/// fields do; a disposal makes a new one.
///
/// It holds no listener: the signals of [LiveRules.reconnectOn] are watched through a `select` of
/// [_signal], a memo that returns the same number whatever happens (so it never rebuilds the
/// feed) and asks a waiting connection to reconnect when the value it is called with changed. The
/// tick is not watched at all: [StreamTicker] keeps the connection in a list and sweeps it, which
/// works while every page that watches the feed is paused (Riverpod then stops notifying the feed
/// of anything).
class _LiveNotifier<T, K> extends StreamNotifier<T> {
  _LiveNotifier(this._spec, this._key, this._slot);

  final _Spec<T, K> _spec;
  final K _key;

  /// Where the resume point of this feed or key is kept.
  final Object _slot;

  final _StatusHub _hub = _StatusHub();
  LiveConnection<T>? _connection;
  int _generation = 0;
  bool _built = false;
  final List<Object?> _seen = <Object?>[];

  @override
  Stream<T> build() {
    final points = ref.read(liveResumePoints);
    final String? resumeFrom;
    if (_built) {
      // A rebuild: something `connect` watches changed, maybe the user. Start afresh.
      points._forget(_slot);
      resumeFrom = null;
    } else {
      resumeFrom = points._read(_slot);
    }
    _built = true;
    final epoch = points._epoch;
    final signals = _spec.rules.reconnectOn;
    for (var i = 0; i < signals.length; i++) {
      ref.watch(signals[i].select((value) => _signal(i, value)));
    }
    final ticker = ref.watch(streamTicker.notifier);
    final generation = ++_generation;
    final LiveConnection<T> connection;
    try {
      connection = _spec.connect(ref, _key, resumeFrom);
    } catch (_) {
      _connection = null;
      _hub._set(const LiveDone(LiveEnd.failed));
      rethrow;
    }
    _connection = connection;
    ticker._track(connection, _spec.rules.idle);
    ref.onDispose(() {
      ticker._untrack(connection);
      final id = connection.lastEventId;
      if (id == null) {
        points._forget(_slot);
      } else {
        points._keep(_slot, id, epoch);
      }
      if (identical(_connection, connection)) _connection = null;
      unawaited(connection.close());
    });
    unawaited(_hub.follow(connection, () => generation == _generation));
    return connection.events;
  }

  /// The memo of the [i]th signal: always 0; a change after the first value reconnects.
  int _signal(int i, Object? value) {
    while (_seen.length <= i) {
      _seen.add(_unseen);
    }
    final last = _seen[i];
    _seen[i] = value;
    if (!identical(last, _unseen) && last != value) _connection?.reconnect();
    return 0;
  }
}
