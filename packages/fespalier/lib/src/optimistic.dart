import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart'
    show NotifierProviderFamily, ProviderBase, ProviderListenable;

/// One write's patch in an [OptimisticLayer]: pending until the write succeeds, then
/// committed on the value the data had at that moment ([basis]).
@immutable
final class _Entry<T> {
  const _Entry(this.apply, {this.committed = false, this.basis});

  final T Function(T value) apply;
  final bool committed;
  final Object? basis;

  /// A committed patch only holds over the value it was committed on: once the data has a
  /// value of its own again (a new object), the server's answer is what shows.
  bool holdsOver(Object? value) => !committed || identical(basis, value);
}

/// The patches of the writes in flight over one `data.dart` value (since 0.8.1): what the page
/// shows of it while an action with an `optimistic()` runs.
///
/// A write's patch applies from the moment it starts. A failure removes it, so the page shows the
/// data as it was (the rollback). A success keeps it over the value the data had then, while the
/// invalidated data loads again, and it stops applying as soon as the data has a new value: the
/// server's answer replaces the guess without a frame of the old value in between.
final class OptimisticLayer<T> {
  OptimisticLayer._(this._entries);

  final List<_Entry<T>> _entries;

  // The last value [apply] was given and what it gave back, so a build that asks again gets the
  // same object (a page, or a form that compares its data, sees no change).
  Object? _in;
  Object? _out;
  bool _memo = false;

  /// Whether no write patches the value.
  bool get isEmpty => _entries.isEmpty;

  /// How many writes that patch the value are still in flight.
  int get pending => _entries.where((e) => !e.committed).length;

  /// Whether a write that succeeded is still shown over [value], the data's value while it loads
  /// again after that write: the page shows the patched value meanwhile, not `loading.dart`, even
  /// with `keep_previous: false`.
  bool settling(Object? value) =>
      _entries.any((e) => e.committed && identical(e.basis, value));

  /// [value] with the patch of every write in flight applied, oldest first, or [value] itself when
  /// none applies. A patch that throws is reported (`FlutterError.reportError`) and skipped.
  T apply(T value) {
    if (_entries.isEmpty) return value;
    if (_memo && identical(_in, value)) return _out as T;
    var out = value;
    for (final e in _entries) {
      if (!e.holdsOver(value)) continue;
      try {
        out = e.apply(out);
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'fespalier',
            context: ErrorDescription('while applying an optimistic() patch'),
          ),
        );
      }
    }
    _memo = true;
    _in = value;
    _out = out;
    return out;
  }
}

/// Holds the [OptimisticLayer] of one `data.dart` value; the generated file makes one per data that
/// an action patches, keyed like it. Actions write to it, through [OptimisticPatch].
final class OptimisticLayerNotifier<T> extends Notifier<OptimisticLayer<T>> {
  /// Creates the layer over [data], the provider whose value it patches.
  OptimisticLayerNotifier(this.data);

  /// The provider whose value the layer patches: the data's own, not the patched view.
  final ProviderListenable<AsyncValue<T>> data;

  @override
  OptimisticLayer<T> build() {
    // A committed patch is over once the data has a value of its own again: drop it then, so the
    // layer is empty when nothing is in flight. (The page already stopped applying it: `apply`
    // checks the same thing.)
    ref.listen(data, (previous, next) {
      if (next is! AsyncData<T> || next.isLoading) return;
      final entries = state._entries;
      if (!entries.any((e) => e.committed)) return;
      // Loaded again after the write (even to the very same object): the server has answered.
      final reloaded = previous?.isLoading ?? false;
      final kept = [
        for (final e in entries)
          if (!e.committed || (!reloaded && e.holdsOver(next.value))) e,
      ];
      if (kept.length != entries.length) {
        state = OptimisticLayer<T>._(List.unmodifiable(kept));
      }
    });
    return OptimisticLayer<T>._(const []);
  }

  /// The value the data has now, or null when it has none (or is not alive).
  Object? _current() {
    final d = data;
    if (d is ProviderBase<Object?> && !ref.exists(d as ProviderBase<Object?>)) {
      return null;
    }
    return ref.read(d).value;
  }

  void _write(List<_Entry<T>> entries) {
    final now = _current();
    state = OptimisticLayer<T>._(
      List.unmodifiable(entries.where((e) => e.holdsOver(now))),
    );
  }

  Object _add(T Function(T value) apply) {
    final entry = _Entry<T>(apply);
    _write([...state._entries, entry]);
    return entry;
  }

  void _commit(Object ticket) {
    final now = _current();
    _write([
      for (final e in state._entries)
        if (identical(e, ticket))
          if (now != null)
            _Entry<T>(e.apply, committed: true, basis: now)
          else
            ...[]
        else
          e,
    ]);
  }

  void _remove(Object ticket) =>
      _write([...state._entries.where((e) => !identical(e, ticket))]);
}

/// The provider of an [OptimisticLayer] over a `data.dart` with no keys.
typedef OptimisticLayerProvider<T> =
    NotifierProvider<OptimisticLayerNotifier<T>, OptimisticLayer<T>>;

/// The layer over a `data.dart` with no keys: [data] is its provider. Called by the generated file.
OptimisticLayerProvider<T> optimisticLayer<T>(
  ProviderListenable<AsyncValue<T>> data,
) =>
    NotifierProvider.autoDispose<
      OptimisticLayerNotifier<T>,
      OptimisticLayer<T>
    >(() => OptimisticLayerNotifier<T>(data));

/// The layers over a `data.dart` keyed by [K]: [data] gives its provider for a key. Called by the
/// generated file.
NotifierProviderFamily<OptimisticLayerNotifier<T>, OptimisticLayer<T>, K>
optimisticLayerFamily<K, T>(
  ProviderListenable<AsyncValue<T>> Function(K key) data,
) => NotifierProvider.autoDispose
    .family<OptimisticLayerNotifier<T>, OptimisticLayer<T>, K>(
      (key) => OptimisticLayerNotifier<T>(data(key)),
    );

/// How an action patches a layer: the `optimistic()` of its `action.dart` bound to the layer of the
/// data it patches. An `ActionNotifier` calls [begin] when a run starts, then [commit] or
/// [rollback]; an app has no reason to.
abstract final class OptimisticPatch<I> {
  /// Adds the patch for [input] to the layer, when something shows it; the ticket for [commit]
  /// and [rollback], or null.
  Object? begin(Ref ref, I input);

  /// The write of [ticket] succeeded: the patch holds over the value the data has now, until the
  /// data has a new one. Call it before invalidating the data.
  void commit(Ref ref, Object ticket);

  /// The write of [ticket] failed: the patch is gone.
  void rollback(Ref ref, Object ticket);
}

final class _Patch<T, I> extends OptimisticPatch<I> {
  _Patch(this.layer, this.patch);

  final OptimisticLayerProvider<T> layer;
  final T Function(T current, I input) patch;

  @override
  Object? begin(Ref ref, I input) {
    // Nothing shows the data: there is nothing to patch, and reading the layer would only make
    // one to throw away.
    if (!ref.exists(layer)) return null;
    return ref.read(layer.notifier)._add((value) => patch(value, input));
  }

  @override
  void commit(Ref ref, Object ticket) {
    if (ref.exists(layer)) ref.read(layer.notifier)._commit(ticket);
  }

  @override
  void rollback(Ref ref, Object ticket) {
    if (ref.exists(layer)) ref.read(layer.notifier)._remove(ticket);
  }
}

/// Binds an action's `optimistic()` to the layer it patches. Called by the generated file.
extension OptimisticLayerPatch<T> on OptimisticLayerProvider<T> {
  /// The patch [apply] makes to this layer's data for an input.
  OptimisticPatch<I> patch<I>(T Function(T current, I input) apply) =>
      _Patch<T, I>(this, apply);
}

/// What the generated `XRoute.watch` of a patched data is built on.
extension OptimisticRef on WidgetRef {
  /// Watches [data] with [layer]'s patches over its value.
  AsyncValue<T> watchOptimistic<T>(
    ProviderListenable<AsyncValue<T>> data,
    OptimisticLayerProvider<T> layer,
  ) {
    final value = watch(data);
    final patches = watch(layer);
    if (patches.isEmpty || value is! AsyncData<T>) return value;
    return value.whenData(patches.apply);
  }
}
