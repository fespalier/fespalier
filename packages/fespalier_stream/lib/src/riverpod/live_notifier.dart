part of 'live_feed.dart';

final class _Spec<T, K> {
  _Spec(this.connect, this.rules);

  final LiveConnection<T> Function(Ref ref, K key, String? lastEventId) connect;
  final LiveRules rules;
}

/// The last value of something that outlives a provider's builds, streamed to any number of
/// watchers, each of which starts with the current one: a feed's status, a live change feed's log.
class _Hub<V> {
  _Hub(this._current);

  V _current;
  final Set<MultiStreamController<V>> _watchers = <MultiStreamController<V>>{};

  Stream<V> get stream => Stream<V>.multi((controller) {
    controller.add(_current);
    _watchers.add(controller);
    controller.onCancel = () => _watchers.remove(controller);
  }, isBroadcast: true);

  void _set(V value) {
    if (value == _current) return;
    _current = value;
    for (final watcher in _watchers.toList()) {
      watcher.add(value);
    }
  }
}

/// The status of a feed across its connections: what [LiveFeed.status] streams. It starts with
/// the current one for each listener.
final class _StatusHub extends _Hub<LiveStatus> {
  _StatusHub() : super(const LiveConnecting(1));

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

/// What a feed keeps across the builds of its provider, and the part of a build that opens its
/// connection: [LiveFeed]'s notifier and a live [ChangeFeed] share it, so both resume, reconnect,
/// follow the tick and close alike.
///
/// It holds no listener: the signals of [LiveRules.reconnectOn] are watched through a `select` of
/// [_signal], a memo that returns the same number whatever happens (so it never rebuilds the
/// feed) and asks a waiting connection to reconnect when the value it is called with changed. The
/// tick is not watched at all: [StreamTicker] keeps the connection in a list and sweeps it, which
/// works while every page that watches the feed is paused (Riverpod then stops notifying the feed
/// of anything).
final class _Line<T> {
  _Line(this._slot);

  /// Where the resume point of this feed or key is kept.
  final Object _slot;

  LiveConnection<T>? _connection;
  int _generation = 0;
  bool _built = false;
  final List<Object?> _seen = <Object?>[];

  /// Opens the connection of one build of the provider [ref] belongs to, through [connect] (given
  /// the ID to resume from), and closes it when that build is disposed. Answers the connection and
  /// whether it is still the line's (a rebuild makes a new one). When [connect] throws, [failed]
  /// runs and the error is rethrown.
  (LiveConnection<T>, bool Function() isCurrent) open(
    Ref ref,
    LiveRules rules,
    LiveConnection<T> Function(String? lastEventId) connect, {
    void Function()? failed,
  }) {
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
    final signals = rules.reconnectOn;
    for (var i = 0; i < signals.length; i++) {
      ref.watch(signals[i].select((value) => _signal(i, value)));
    }
    final ticker = ref.watch(streamTicker.notifier);
    final generation = ++_generation;
    final LiveConnection<T> connection;
    try {
      connection = connect(resumeFrom);
    } catch (_) {
      _connection = null;
      failed?.call();
      rethrow;
    }
    _connection = connection;
    ticker._track(connection, rules.idle);
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
    return (connection, () => generation == _generation);
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

/// The notifier of one feed (or one key of a family). Its instance outlives its rebuilds, so its
/// fields do (the [_Line] among them); a disposal makes a new one.
class _LiveNotifier<T, K> extends StreamNotifier<T> {
  _LiveNotifier(this._spec, this._key, Object slot) : _line = _Line<T>(slot);

  final _Spec<T, K> _spec;
  final K _key;
  final _Line<T> _line;

  final _StatusHub _hub = _StatusHub();

  @override
  Stream<T> build() {
    final (connection, isCurrent) = _line.open(
      ref,
      _spec.rules,
      (lastEventId) => _spec.connect(ref, _key, lastEventId),
      failed: () => _hub._set(const LiveDone(LiveEnd.failed)),
    );
    unawaited(_hub.follow(connection, isCurrent));
    return connection.events;
  }
}
