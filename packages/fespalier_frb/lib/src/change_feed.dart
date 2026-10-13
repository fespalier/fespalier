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
/// stream, and Riverpod rebuilds what depends on it. Riverpod rebuilds lazily, so events that
/// arrive before the dependents rebuild (a burst in one frame, or a paused page that is shown
/// again) share **one rebuild**, but none is lost: the feed remembers the last
/// [changeLogCapacity] events of the subscription and a topic looks at every one it missed. A
/// watcher that missed more than that, or whose core was restarted, rebuilds anyway. A stream
/// error is kept in [latest] (an `AsyncError`) and does not rebuild any topic.
final class ChangeFeed<E> {
  /// Creates a feed over the stream [open] returns.
  ///
  /// [open] is called **once per container**, when something first watches the feed (a stream of
  /// flutter_rust_bridge is single-subscription, so it must not be shared by two containers):
  /// `ChangeFeed((ref) => ref.watch(core).changes())`. A `ref.watch` inside it rebuilds the
  /// subscription when the core provider changes, which is what an app that restarts its core
  /// wants. [name] shows in the DevTools extension and in errors.
  ChangeFeed(Stream<E> Function(Ref ref) open, {String? name})
    : _name = name,
      latest = StreamProvider<Change<E>>((ref) {
        var seq = 0;
        final log = _ChangeLog<E>();
        return open(ref).map((event) {
          final change = Change<E>._(event, ++seq, log);
          log.add(change);
          return change;
        });
      }, name: name == null ? null : '$name.latest');

  final String? _name;

  /// The one subscription: the last change, numbered, as an `AsyncValue` (loading until the first
  /// event, an error when the stream fails). Never auto-disposed.
  final StreamProvider<Change<E>> latest;

  /// A topic over this feed: [matches] says whether an event concerns a key.
  ///
  /// The returned [ChangeTopic] is called with the key (`orderChanged(42)`) and watched.
  ChangeTopic<E, K> topic<K>(
    bool Function(E event, K key) matches, {
    String? name,
  }) => ChangeTopic<E, K>._(
    latest,
    matches,
    countAll: false,
    name: name ?? (_name == null ? null : '$_name.topic'),
  );

  /// Any event at all: an `int` that counts the events seen since it was first watched (every
  /// event of a burst counts, up to the point where the feed's log no longer holds them).
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
/// matching event arrives after the first watch; an event for another key rebuilds the revision
/// but leaves the same number, and Riverpod does not notify the dependents of an unchanged value.
/// So a provider watching `orderChanged(42)` rebuilds on an event about order 42 and on no other,
/// even when that event was one of several that arrived together.
///
/// Cost: every revision of every watched key evaluates the matcher once per event it missed,
/// at most [changeLogCapacity] of them per rebuild. That is cheap for tens or hundreds of watched
/// keys; a core that emits thousands of events a second wants coarser events (one per table) or
/// an [InvalidationTable] it applies itself.
final class ChangeTopic<E, K> {
  ChangeTopic._(
    StreamProvider<Change<E>> latest,
    bool Function(E event, K key) matches, {
    required bool countAll,
    String? name,
  }) : _revisionOf = NotifierProvider.autoDispose
           .family<_Revision<E, K>, int, K>(
             (key) => _Revision<E, K>(latest, matches, key, countAll),
             name: name,
           )
           .call;

  final ProviderListenable<int> Function(K key) _revisionOf;

  /// The revision provider of [key]: watch it (`ref.watch(topic(key))`).
  ProviderListenable<int> call(K key) => _revisionOf(key);
}

/// The counter of one key. Its instance outlives its rebuilds, so its fields do.
class _Revision<E, K> extends Notifier<int> {
  _Revision(this._latest, this._matches, this._key, this._countAll);

  final StreamProvider<Change<E>> _latest;
  final bool Function(E event, K key) _matches;
  final K _key;
  final bool _countAll;

  int _revision = 0;

  /// The subscription's log and the last number this key looked at. A different log is a
  /// stream that was opened again (the core provider changed).
  _ChangeLog<E>? _log;
  int _seen = 0;

  bool _started = false;

  /// The last change made by hand (it belongs to no log): told apart by identity.
  Change<E>? _handMade;

  @override
  int build() {
    final change = ref.watch(_latest).value;
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
        _handMade = change;
        if (_countAll || _matches(change.event, _key)) _revision++;
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
        _revision++;
      } else if (change.seq != _seen) {
        final missed = _log!.after(_seen);
        if (_countAll) {
          _revision += change.seq - _seen;
        } else if (missed == null ||
            missed.any((c) => _matches(c.event, _key))) {
          _revision++;
        }
        _seen = change.seq;
      }
    }
    return _revision;
  }
}
