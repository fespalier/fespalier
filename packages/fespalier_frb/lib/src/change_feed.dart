import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart' show immutable;

/// One event of a change stream, numbered (since 0.13.0).
///
/// The number is what makes two equal events two changes: Riverpod 3 does not notify when a new
/// state is `==` the old one, and a Rust core may well say "order 42 changed" twice in a row.
/// [Change] does not override `==`, so no two are ever equal.
@immutable
final class Change<E> {
  /// Creates the [seq]th change, carrying [event].
  const Change(this.event, this.seq);

  /// What the core said.
  final E event;

  /// 1 for the first event the feed saw in this container, then 2, 3, ...
  final int seq;
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
/// stream, and Riverpod rebuilds what depends on it. Events that arrive before the dependents
/// rebuild are coalesced into one rebuild, like any other provider change. A stream error is
/// kept in [latest] (an `AsyncError`) and does not rebuild any topic.
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
        return open(ref).map((event) => Change<E>(event, ++seq));
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
    name: name ?? (_name == null ? null : '$_name.topic'),
  );

  /// Any event at all: an `int` that counts the events seen since it was first watched.
  ProviderListenable<int> get any => _any ??= topic<Object?>(
    (_, _) => true,
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
/// So a provider watching `orderChanged(42)` rebuilds on an event about order 42 and on no other.
///
/// Cost: every revision of every watched key evaluates the matcher once per event. That is cheap
/// for tens or hundreds of watched keys; a core that emits thousands of events a second wants
/// coarser events (one per table) or an [InvalidationTable] it applies itself.
final class ChangeTopic<E, K> {
  ChangeTopic._(
    StreamProvider<Change<E>> latest,
    bool Function(E event, K key) matches, {
    String? name,
  }) : _revisionOf = NotifierProvider.autoDispose
           .family<_Revision<E, K>, int, K>(
             (key) => _Revision<E, K>(latest, matches, key),
             name: name,
           )
           .call;

  final ProviderListenable<int> Function(K key) _revisionOf;

  /// The revision provider of [key]: watch it (`ref.watch(topic(key))`).
  ProviderListenable<int> call(K key) => _revisionOf(key);
}

/// The counter of one key. Its instance outlives its rebuilds, so [_revision] and [_seen] do.
class _Revision<E, K> extends Notifier<int> {
  _Revision(this._latest, this._matches, this._key);

  final StreamProvider<Change<E>> _latest;
  final bool Function(E event, K key) _matches;
  final K _key;

  int _revision = 0;

  /// The last change already looked at: a rebuild with the same one (the stream going from data to
  /// an error, say) counts nothing. Compared by identity, so a stream that is opened again (the core
  /// provider changed) and starts numbering from 1 again is not mistaken for the old one.
  Change<E>? _seen;

  bool _started = false;

  @override
  int build() {
    final change = ref.watch(_latest).value;
    if (!_started) {
      // The first watch: an event older than the watcher is history, not a change.
      _started = true;
      _seen = change;
    } else if (change != null && !identical(change, _seen)) {
      _seen = change;
      if (_matches(change.event, _key)) _revision++;
    }
    return _revision;
  }
}
