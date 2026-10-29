part of 'live_feed.dart';

/// How many recent events a feed remembers per subscription, so a watcher that rebuilds late can
/// look at every event it missed (since 0.13.0, in fespalier_stream since 0.25.0). A watcher that missed more than this treats the
/// gap as a match: it rebuilds, which is always safe.
const int changeLogCapacity = 64;

/// One event of a change stream, numbered (since 0.13.0, in fespalier_stream since 0.25.0).
///
/// The number is what makes two equal events two changes: Riverpod 3 does not notify when a new
/// state is `==` the old one, and a Rust core may well say "order 42 changed" twice in a row.
/// [Change] does not override `==`, so no two are ever equal.
@immutable
final class Change<E> {
  /// Creates the [seq]th change, carrying [event]. A change made by hand belongs to no feed's log (for a test that overrides `latest`): a topic
  /// counts it when it differs from the last one it saw and matches.
  const Change(this.event, this.seq) : _log = null;

  const Change._(this.event, this.seq, this._log);

  /// What the core said.
  final E event;

  /// 1 for the first event the feed saw on this subscription, then 2, 3, ... (a live feed numbers
  /// from 1 again after a gap).
  final int seq;

  final _ChangeLog<E>? _log;
}

/// The last [changeLogCapacity] changes of one subscription. Riverpod rebuilds a provider lazily,
/// so a watcher sees only the newest change of a burst; the log is how it finds the others.
final class _ChangeLog<E> {
  _ChangeLog([this.epoch = 0]);

  /// 0, or for a live feed the number of gaps before this log: a change of a lower epoch than
  /// the log a watcher knows is older than the gap that already moved it.
  final int epoch;

  final ListQueue<Change<E>> _ring = ListQueue();

  void add(Change<E> change) {
    if (_ring.length == changeLogCapacity) _ring.removeFirst();
    _ring.add(change);
  }

  /// The changes with a number above [seen], oldest first, or null when some of them were
  /// dropped from the ring.
  List<Change<E>>? after(int seen) {
    if (_ring.isEmpty) return const [];
    if (_ring.first.seq > seen + 1) return null;
    return [
      for (final change in _ring)
        if (change.seq > seen) change,
    ];
  }
}

/// A change stream, held by Riverpod (since 0.13.0, in fespalier_stream since 0.25.0, where
/// fespalier_frb re-exports it from).
///
/// The generated bindings of flutter_rust_bridge (or any other core) give a `Stream<E>` of what
/// changed: "order 42 changed", "the cart was cleared"; a server says the same over a live
/// connection ([ChangeFeed.live]). A `ChangeFeed` is that stream as a provider. [latest] is the **one subscription**, a provider that is never auto-disposed, so it
/// lives as long as the `ProviderContainer` and is cancelled by its disposal. A provider that
/// should be rebuilt when something changed does not listen to the stream: it **watches** a
/// [topic] (or [any]), whose value moves only when an event the topic accepts arrives, so the watch
/// is the invalidation:
///
/// ```dart
/// final orderChanged = changes.topic<int>((e, id) => e is OrderChanged && e.id == id);
///
/// Future<Order> data(Ref ref, {required int id}) {
///   ref.watch(orderChanged(id));
///   return ref.read(core).order(id);
/// }
/// ```
///
/// There is no `listen` in this package, no timer and no `Future`: an event is delivered by the
/// stream, and Riverpod rebuilds what depends on it. A key is rebuilt only by an event that
/// concerns it (since 0.21.0): an event about another key costs one call of the matcher. Events
/// that arrive before a dependent rebuilds (a burst, or a paused page that is shown again) share
/// **one rebuild** (but see below), and none is lost: the feed remembers the last
/// [changeLogCapacity] events of the subscription and a topic looks at every one it missed. A
/// watcher that missed more than that, or whose core was restarted, rebuilds anyway. A stream
/// error is kept in [latest] (an `AsyncError`) and does not rebuild any topic.
///
/// Riverpod runs a provider's rebuild after two zero-length timers, not once a frame, so a key
/// whose events come one per event-loop turn (how flutter_rust_bridge delivers them) reloads what
/// watches it once per event; and Riverpod 3 pauses [latest] while every provider that watches
/// it rebuilds, so a burst that concerns every watched key comes through one event per turn. A
/// [ChangeBudget] on the topic bounds both (since 0.21.0).
final class ChangeFeed<E> {
  /// Creates a feed over the stream [open] returns.
  ///
  /// [open] is called **once per container**, when something first watches the feed (a stream of
  /// flutter_rust_bridge is single-subscription, so it must not be shared by two containers):
  /// `ChangeFeed((ref) => ref.watch(core).changes())`. A `ref.watch` inside it rebuilds the
  /// subscription when the core provider changes, which is what an app that restarts its core
  /// wants. [name] shows in the DevTools extension and in errors.
  ///
  /// A failure of [open] is kept in [latest] and [open] is not called again: no retry, which
  /// would be a `Timer` (since 0.16.0; Riverpod's default called it again after 200 ms, up to ten
  /// times).
  ChangeFeed(Stream<E> Function(Ref ref) open, {String? name})
    : _name = name,
      _logs = null,
      _currentLog = null,
      latest = StreamProvider<Change<E>>(
        (ref) {
          var seq = 0;
          final log = _ChangeLog<E>();
          return open(ref).map((event) {
            final change = Change<E>._(event, ++seq, log);
            log.add(change);
            return change;
          });
        },
        name: name == null ? null : '$name.latest',
        retry: (_, _) => null,
      );

  /// A feed over the live connection [connect] returns (since 0.25.0): a server's change events,
  /// over `ServerEvents` (decoded with an `EventCodec`) or any other [LiveConnection].
  ///
  /// ```dart
  /// final changes = ChangeFeed<OrderEvent>.live(
  ///   (ref, lastEventId) => ServerEvents(
  ///     ref.watch(apiTransport),
  ///     Uri.parse('https://api.example.com/changes'),
  ///     lastEventId: lastEventId,
  ///     name: 'changes',
  ///   ).transform(orderCodec),
  ///   rules: LiveRules(reconnectOn: [reconnectSignal, appShowSignal]),
  /// );
  /// ```
  ///
  /// The connection behaves as a [LiveFeed]'s (with `keepAlive`): it opens when something first
  /// watches the feed, a drop waits for a signal of [rules] or the app's [streamTicker], a
  /// connection whose watchers are all paused (every page hidden) stops reading and is closed by
  /// the tick, and a resume opens it again with `Last-Event-ID`. A rebuild ([connect] watches a
  /// provider that changed) opens a new connection, with no ID. A refusal ends [latest] with it.
  ///
  /// **A gap moves every topic.** When the connection opens again without resuming
  /// (`LiveOpen(resumed: false)` after an earlier open: the server sends no event IDs, or the
  /// feed was rebuilt), the events sent meanwhile are lost, so the feed starts a new log and
  /// every key watched moves once at that moment, without waiting for an event; [any] moves by
  /// one. An open that follows failed tries (a 503, a timeout or a network error, before any open)
  /// is a gap too, even the first open: the server may have said something while the connection
  /// was failing. A reopen that resumed (`LiveOpen(resumed: true)`, the
  /// request carried `Last-Event-ID`) moves nothing: the server sends what was missed. The
  /// feed cannot tell that a server ignored the ID it was given, so a server that cannot honour
  /// `Last-Event-ID` must send no `id:` (or clear it with an empty `id:` line before it ends a
  /// stream), which makes every reopen a gap.
  factory ChangeFeed.live(
    LiveConnection<E> Function(Ref ref, String? lastEventId) connect, {
    LiveRules rules = const LiveRules(),
    String? name,
  }) {
    // Where the resume point of this feed is kept (see LiveResumePoints).
    final slot = Object();
    final held = Provider<_LiveChanges<E>>(
      (ref) => _LiveChanges<E>(slot),
      name: name == null ? null : '$name.state',
    );
    final latest = StreamProvider<Change<E>>(
      (ref) {
        final changes = ref.watch(held);
        final (connection, isCurrent) = changes.line.open(
          ref,
          rules,
          (lastEventId) => connect(ref, lastEventId),
        );
        unawaited(changes.followGaps(connection, isCurrent));
        return connection.events.map(changes.number);
      },
      name: name == null ? null : '$name.latest',
      retry: (_, _) => null,
    );
    final logs = StreamProvider<_ChangeLog<E>>(
      (ref) => ref.watch(held).logs.stream,
      name: name == null ? null : '$name.logs',
      retry: (_, _) => null,
    );
    return ChangeFeed<E>._(latest, logs, name, (ref) => ref.read(held)._log);
  }

  ChangeFeed._(this.latest, this._logs, this._name, [this._currentLog]);

  final String? _name;

  /// A live feed's current log, which a gap replaces; null for a feed over a plain stream.
  final ProviderListenable<AsyncValue<_ChangeLog<E>>>? _logs;

  /// Reads the log a live feed holds now (not the one its paused `logs` provider last handed
  /// out), for a topic's first build; null for a feed over a plain stream.
  final _ChangeLog<E> Function(Ref ref)? _currentLog;

  /// The one subscription: the last change, numbered, as an `AsyncValue` (loading until the first
  /// event, an error when the stream fails, or when a live connection is refused). Never
  /// auto-disposed.
  final StreamProvider<Change<E>> latest;

  /// A topic over this feed: [matches] says whether an event concerns a key.
  ///
  /// The returned [ChangeTopic] is called with the key (`orderChanged(42)`) and watched. With a
  /// [budget] (since 0.21.0), each key moves at most once between two ticks of
  /// [ChangeBudget.tick]: for a key whose events come faster than what watches it reloads.
  ChangeTopic<E, K> topic<K>(
    bool Function(E event, K key) matches, {
    String? name,
    ChangeBudget? budget,
  }) => ChangeTopic<E, K>._(
    latest,
    matches,
    logs: _logs,
    currentLog: _currentLog,
    countAll: false,
    tick: budget?.tick,
    name: name ?? (_name == null ? null : '$_name.topic'),
  );

  /// Any event at all: an `int` that counts the events seen since it was first watched (every
  /// event of a burst counts, up to the point where the feed's log no longer holds them). It has
  /// no budget: `topic<Null>((_, _) => true, budget: ...)` is a budgeted one, which counts moves.
  ProviderListenable<int> get any => _any ??= ChangeTopic<E, Object?>._(
    latest,
    (_, _) => true,
    logs: _logs,
    currentLog: _currentLog,
    countAll: true,
    name: _name == null ? null : '$_name.any',
  )(null);

  ProviderListenable<int>? _any;
}

/// Watch a key of a [ChangeFeed.topic] to be rebuilt by the events that concern it (since 0.13.0,
/// in fespalier_stream since 0.25.0).
///
/// Each key has its own revision provider (auto-dispose: it lives while something watches it, so
/// a screen that is gone costs nothing). Its value is a counter that moves **only** when a
/// matching event arrives after the first watch. Since 0.21.0 an event for another key does not
/// rebuild the revision at all: the revision watches the feed through a `select`, which Riverpod
/// evaluates for each event, and the number it selects moves only on a match. So a provider
/// watching `orderChanged(42)` rebuilds on an event about order 42 and on no other, even when that
/// event was one of several that arrived together.
///
/// Cost: an event costs each watched key one call of the matcher (a key that was rebuilding or
/// paused looks at each event it missed, at most [changeLogCapacity] of them), and a rebuild of
/// the keys it concerns. Before 0.21.0 every watched key was rebuilt by every event, which grew
/// with the square of the number of keys. A key that matches more events than what watches it
/// can reload wants a [ChangeBudget].
final class ChangeTopic<E, K> {
  ChangeTopic._(
    StreamProvider<Change<E>> latest,
    bool Function(E event, K key) matches, {
    required ProviderListenable<AsyncValue<_ChangeLog<E>>>? logs,
    required _ChangeLog<E> Function(Ref ref)? currentLog,
    required bool countAll,
    ProviderListenable<Object?>? tick,
    String? name,
  }) : _revisionOf = NotifierProvider.autoDispose
           .family<_Revision<E, K>, int, K>(
             (key) => _Revision<E, K>(
               latest,
               logs,
               currentLog,
               matches,
               key,
               countAll,
               tick,
             ),
             name: name,
           )
           .call;

  final ProviderListenable<int> Function(K key) _revisionOf;

  /// The revision provider of [key]: watch it (`ref.watch(topic(key))`).
  ProviderListenable<int> call(K key) => _revisionOf(key);
}

/// A rebuild budget for the keys of a [ChangeFeed.topic] (since 0.21.0, in fespalier_stream since
/// 0.25.0): each key moves at most
/// once between two ticks of [tick], a provider the app fires.
///
/// A key that has not moved since the last tick moves at once on the first event that concerns
/// it, so a quiet core is as quick as without a budget; the next ones are held, and the next tick
/// moves the key once if anything was held. That move opens the next period: an event right after
/// a tick that released a held change is held for the tick after it, and only a tick that moved
/// nothing lets the next event through at once. Nothing is dropped: a held change waits for the
/// next tick however long the core then stays quiet, so a tick that stops firing holds it until
/// it fires again. A tick moves only the keys that hold a change; the others cost one comparison
/// each.
///
/// The package has no clock (no `Timer`, no frame callback): [tick] is the app's, usually a
/// `RefetchSignal` that fires from a timer of its own. The timer runs while a budgeted key is
/// watched and active, and stops while every one is paused (a page covered by an opaque route, a
/// hidden tab), because Riverpod then calls `onCancel`; it starts again on `onResume`:
///
/// ```dart
/// final changeTick = NotifierProvider.autoDispose<RefetchSignal, int>(ChangeTick.new);
///
/// class ChangeTick extends RefetchSignal {
///   Timer? _timer;
///
///   void _start() => _timer ??= Timer.periodic(
///     const Duration(milliseconds: 100),
///     (_) => fire(),
///   );
///
///   void _stop() {
///     _timer?.cancel();
///     _timer = null;
///   }
///
///   @override
///   int build() {
///     _start();
///     ref.onCancel(_stop);
///     ref.onResume(_start);
///     ref.onDispose(_stop);
///     return 0;
///   }
/// }
///
/// final orderChanged = changes.topic<int>(
///   (event, id) => event is OrderChanged && event.id == id,
///   budget: ChangeBudget(changeTick),
/// );
/// ```
///
/// A test overrides it with `changeTick.overrideWith(RefetchSignal.new)` and fires it by hand.
@immutable
final class ChangeBudget {
  /// A budget of one move per key between two ticks of [tick].
  const ChangeBudget(this.tick);

  /// What ends a period: a new value (a `RefetchSignal`'s `fire()`). Every budgeted key watches
  /// it, so an auto-dispose tick is created by the first budgeted key watched and disposed with
  /// the last; a timer that is started in `build` and stopped in `onCancel` (and started again in
  /// `onResume`) does not run while every budgeted key is paused.
  final ProviderListenable<Object?> tick;
}

/// The counter of one key. Its instance outlives its rebuilds, so its fields do.
///
/// It watches the feed through a `select` of [_observe], which Riverpod calls for each event
/// while the key is watched; the number [_observe] returns moves only when the event concerns the
/// key, and Riverpod rebuilds this provider only then. A live feed's log is watched the same way
/// through [_onLog], so a gap moves the key at once. [_observe], [_onLog] and [_onTick] are memos,
/// not listeners: they set no state and read no provider, a second call with the same value
/// returns the same number, and the revision moves by returning it from [build].
class _Revision<E, K> extends Notifier<int> {
  _Revision(
    this._latest,
    this._logs,
    this._currentLog,
    this._matches,
    this._key,
    this._countAll,
    this._tick,
  );

  final StreamProvider<Change<E>> _latest;

  /// A live feed's current log, or null for a feed over a plain stream.
  final ProviderListenable<AsyncValue<_ChangeLog<E>>>? _logs;

  /// Reads the live feed's current log without watching it.
  final _ChangeLog<E> Function(Ref ref)? _currentLog;
  final bool Function(E event, K key) _matches;
  final K _key;
  final bool _countAll;

  /// The budget's tick, or null for a topic without one.
  final ProviderListenable<Object?>? _tick;

  int _revision = 0;

  /// The subscription's log and the last number this key looked at. A different log is a
  /// stream that was opened again (the core provider changed).
  _ChangeLog<E>? _log;
  int _seen = 0;

  bool _started = false;

  /// A live feed's log when this key first saw it, then the last one seen: a different one is a
  /// gap.
  bool _logSeen = false;
  _ChangeLog<E>? _lastLog;

  /// The last change made by hand (it belongs to no log): told apart by identity.
  Change<E>? _handMade;

  /// The last change [_observe] finished with: a second call with it changes nothing.
  Change<E>? _observed;

  /// The budget: the last tick seen, whether the key moved since it, and whether a change waits
  /// for the next one.
  bool _tickSeen = false;
  Object? _lastTick;
  bool _movedSinceTick = false;
  bool _held = false;

  @override
  int build() {
    final tick = _tick;
    if (tick != null) ref.watch(tick.select(_onTick));
    final logs = _logs;
    if (logs != null) {
      if (!_logSeen) {
        // The first build: a gap older than the watcher is history. The log is read from the
        // holder, not taken from `logs`: that provider may have been paused with nothing
        // listening (only `latest` stayed watched), and then it hands out the log from before
        // the gap first and the current one after it.
        _logSeen = true;
        _lastLog = _currentLog!(ref);
      }
      ref.watch(logs.select(_onLog));
    }
    ref.watch(_latest.select(_observe));
    return _revision;
  }

  /// The revision once a live feed's log reads [value]: a log other than the one this key knows
  /// is a gap, which moves the key once. An event of the new log may have come first, and moved it
  /// already through [_observe]'s new-stream path; then this changes nothing.
  int _onLog(AsyncValue<_ChangeLog<E>> value) {
    final log = value.value;
    if (log == null) return _revision;
    final last = _lastLog;
    // The log this key started from, or one from before it (a paused provider's buffer).
    if (last != null && log.epoch <= last.epoch) return _revision;
    _lastLog = log;
    final known = _log;
    if (known != null && log.epoch <= known.epoch) return _revision;
    _log = log;
    _seen = 0;
    _changed();
    return _revision;
  }

  /// Something concerns this key: it moves, unless a budget already let it move since the tick.
  void _changed() {
    if (_tick != null && _movedSinceTick) {
      _held = true;
      return;
    }
    _movedSinceTick = true;
    _revision++;
  }

  /// The revision once the tick reads [tick]: a new value moves a held change and starts a period.
  int _onTick(Object? tick) {
    if (!_tickSeen) {
      _tickSeen = true;
      _lastTick = tick;
      return _revision;
    }
    if (tick == _lastTick) return _revision;
    _lastTick = tick;
    _movedSinceTick = _held;
    if (_held) {
      _held = false;
      _revision++;
    }
    return _revision;
  }

  /// The revision once the feed reads [value].
  int _observe(AsyncValue<Change<E>> value) {
    final change = value.value;
    if (_started && identical(change, _observed)) return _revision;
    if (!_started) {
      // The first watch: an event older than the watcher is history, not a change.
      _started = true;
      _log = change?._log;
      _seen = change?.seq ?? 0;
      _handMade = change != null && change._log == null ? change : null;
      final live = _lastLog;
      if (live != null && (_log == null || live.epoch > _log!.epoch)) {
        // A live feed whose gap came after its last event: that log is empty so far.
        _log = live;
        _seen = 0;
      }
    } else if (change != null && change._log == null) {
      // A `Change(event, seq)` made by hand (a test overriding `latest`): no log to scan, so
      // a different change than the last seen counts if it matches.
      if (!identical(change, _handMade)) {
        // The matcher first, the memo after: a matcher that throws throws again on the rebuild
        // that the error causes, and the error reaches whoever watches the topic.
        final hit = _countAll || _matches(change.event, _key);
        _handMade = change;
        if (hit) _changed();
      }
    } else if (change != null) {
      // Started before the first event: every event of the subscription is news.
      if (_log == null) {
        _log = change._log;
        _seen = 0;
      }
      if (!identical(change._log, _log) && change._log!.epoch < _log!.epoch) {
        // An event from before a gap that already moved this key (it was paused meanwhile).
      } else if (!identical(change._log, _log)) {
        // A new stream: whatever came before is unknown, so rebuild (over-invalidating is safe).
        _log = change._log;
        _seen = change.seq;
        _changed();
      } else if (change.seq > _seen) {
        if (_countAll) {
          _revision += change.seq - _seen;
        } else if (change.seq == _seen + 1
            ? _matches(change.event, _key)
            : (_log!.after(_seen)?.any((c) => _matches(c.event, _key)) ??
                  true)) {
          // The next event, or (after a rebuild or a pause) any of those missed; a gap the
          // log no longer holds counts as a match.
          _changed();
        }
        _seen = change.seq;
      }
    }
    // Last, so that a matcher that throws throws again on the rebuild it causes.
    _observed = change;
    return _revision;
  }
}

/// What a live [ChangeFeed] keeps for its container across the builds of [ChangeFeed.latest]: the
/// [_Line] its connections open through, and the log its events are numbered into, which a gap
/// replaces.
final class _LiveChanges<E> {
  _LiveChanges(Object slot) : line = _Line<E>(slot) {
    logs = _Hub<_ChangeLog<E>>(_log);
  }

  final _Line<E> line;

  _ChangeLog<E> _log = _ChangeLog<E>();
  int _seq = 0;

  /// Whether a connection of this feed was open before: the next open that did not resume is a gap.
  bool _opened = false;

  /// Whether a request went out ([LiveConnecting]) since the last open: a [LiveOpen] that follows
  /// a pause, not a request, is the same connection read again.
  bool _requested = false;

  /// Whether a try failed before the first open: that open is a gap too, because the server may
  /// have sent events while the connection was failing.
  bool _failedBeforeOpen = false;

  /// The current log, for each topic's [_Revision._onLog].
  late final _Hub<_ChangeLog<E>> logs;

  /// [event], numbered into the current log.
  Change<E> number(E event) {
    final change = Change<E>._(event, ++_seq, _log);
    _log.add(change);
    return change;
  }

  /// Starts a new log at each request that opened without resuming, after the first open or after
  /// failed tries before it, while [isCurrent] says [connection] is the feed's. A request is a [LiveConnecting] (each try of a
  /// connection says it), so a [LiveOpen] that only ends a pause is not one. The `await for` is
  /// the subscription, and it ends with the connection (its statuses end at `LiveDone`).
  Future<void> followGaps(
    LiveConnection<E> connection,
    bool Function() isCurrent,
  ) async {
    await for (final status in connection.statusChanges) {
      if (!isCurrent()) return;
      switch (status) {
        case LiveConnecting(:final attempt):
          _requested = true;
          if (!_opened && attempt > 1) _failedBeforeOpen = true;
        case LiveWaiting():
          if (!_opened) _failedBeforeOpen = true;
        case LiveOpen(:final resumed) when _requested:
          if ((_opened || _failedBeforeOpen) && !resumed) {
            _log = _ChangeLog<E>(_log.epoch + 1);
            _seq = 0;
            logs._set(_log);
          }
          _opened = true;
          _requested = false;
        default:
      }
    }
  }
}
