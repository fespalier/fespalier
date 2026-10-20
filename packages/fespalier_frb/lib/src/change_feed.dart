import 'dart:collection';

import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart' show immutable;

/// How many recent events a feed remembers per subscription, so a watcher that rebuilds late can
/// look at every event it missed (since 0.13.0). A watcher that missed more than this treats the
/// gap as a match: it rebuilds, which is always safe.
const int changeLogCapacity = 64;

/// One event of a change stream, numbered (since 0.13.0).
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

  /// 1 for the first event the feed saw on this subscription, then 2, 3, ...
  final int seq;

  final _ChangeLog<E>? _log;
}

/// The last [changeLogCapacity] changes of one subscription. Riverpod rebuilds a provider lazily,
/// so a watcher sees only the newest change of a burst; the log is how it finds the others.
final class _ChangeLog<E> {
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

/// A Rust core's change stream, held by Riverpod (since 0.13.0).
///
/// The generated bindings of flutter_rust_bridge (or any other core) give a `Stream<E>` of what
/// changed: "order 42 changed", "the cart was cleared". A `ChangeFeed` is that stream as a
/// provider. [latest] is the **one subscription**, a provider that is never auto-disposed, so it
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

  final String? _name;

  /// The one subscription: the last change, numbered, as an `AsyncValue` (loading until the first
  /// event, an error when the stream fails). Never auto-disposed.
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
    countAll: true,
    name: _name == null ? null : '$_name.any',
  )(null);

  ProviderListenable<int>? _any;
}

/// Watch a key of a [ChangeFeed.topic] to be rebuilt by the events that concern it (since 0.13.0).
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
    required bool countAll,
    ProviderListenable<Object?>? tick,
    String? name,
  }) : _revisionOf = NotifierProvider.autoDispose
           .family<_Revision<E, K>, int, K>(
             (key) => _Revision<E, K>(latest, matches, key, countAll, tick),
             name: name,
           )
           .call;

  final ProviderListenable<int> Function(K key) _revisionOf;

  /// The revision provider of [key]: watch it (`ref.watch(topic(key))`).
  ProviderListenable<int> call(K key) => _revisionOf(key);
}

/// A rebuild budget for the keys of a [ChangeFeed.topic] (since 0.21.0): each key moves at most
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
/// key, and Riverpod rebuilds this provider only then. [_observe] and [_onTick] are memos, not
/// listeners: they set no state and read no provider, a second call with the same value returns
/// the same number, and the revision moves by returning it from [build].
class _Revision<E, K> extends Notifier<int> {
  _Revision(this._latest, this._matches, this._key, this._countAll, this._tick);

  final StreamProvider<Change<E>> _latest;
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
    ref.watch(_latest.select(_observe));
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
      if (!identical(change._log, _log)) {
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
