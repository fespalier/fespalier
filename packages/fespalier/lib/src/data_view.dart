import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'deferred.dart';
import 'field_errors.dart' show DataRefusal;
import 'optimistic.dart' show OptimisticLayer;

/// Glue emitted around every route that has a `data.dart`:
/// watch the provider, then pick page / loading / error.
///
/// Takes closures instead of provider types so it works with any provider
/// whose value is an [AsyncValue].
///
/// [keepPrevious] (the `keep_previous` setting in pubspec.yaml) decides what a
/// provider that is loading again shows. On, `loading` is only for the first
/// load: a refresh or reload keeps rendering the old value (or the error), and a
/// provider that failed and is being retried keeps showing its `error`. Off,
/// `loading` shows whenever the provider is loading.
///
/// A route whose data.dart has a `freshness` or a `dataCache` sets [keepDataOnError] (since
/// 0.8.1): a reload that fails (a stale value loaded again, a start offline) keeps the page on
/// its value, and `error` only shows when there is nothing to show. A value restored from the
/// cache (`isFromCache`) shows while the fresh one loads, whatever [keepPrevious] says. An error
/// that is a [DataRefusal] (since 0.13.1) is never kept behind the value: `error` shows.
///
/// With a [library] (the route's `page.dart` is deferred, since 0.7.0) the page's code
/// starts loading at the first build, in parallel with the data, and the page shows once
/// both are there; `loading` covers both waits, and `error` a failed load of either (the
/// code's with a retry that loads it again).
class DataView<T> extends ConsumerWidget {
  /// Creates a view of the data [watch] reads, shown with [data], [loading] or [error].
  const DataView({
    super.key,
    required this.watch,
    required this.refresh,
    required this.data,
    required this.loading,
    required this.error,
    this.keepPrevious = true,
    this.keepDataOnError = false,
    this.library,
    this.optimistic,
  });

  /// Reads the provider's state; called on every build.
  final AsyncValue<T> Function(WidgetRef ref) watch;

  /// Invalidates the provider so it loads again (the `retry` of [error]).
  final void Function(WidgetRef ref) refresh;

  /// Builds the view once the data has arrived.
  final Widget Function(T data) data;

  /// Builds the view while the data is loading.
  final Widget Function() loading;

  /// Builds the view when loading failed; `retry` loads it again (and does nothing once the
  /// view is gone).
  final Widget Function(Object error, StackTrace stackTrace, VoidCallback retry)
  error;

  /// Whether the previous data stays on screen while a refresh loads.
  final bool keepPrevious;

  /// Whether a failed reload keeps showing the value it had (set for a route whose data.dart
  /// has a `freshness` or a `dataCache`, since 0.8.1): [error] then only shows when there is
  /// no value, or when the error is a [DataRefusal] (since 0.13.1).
  final bool keepDataOnError;

  /// The code of the page [data] builds, when its `page.dart` is deferred; null otherwise.
  /// It starts loading with the first build, and [data]'s page is built inside a
  /// [DeferredView] for good, so the page's `State` survives the load.
  final DeferredLibrary? library;

  /// What the page shows of the value while a write that patches it is in flight: the
  /// `optimistic()` of an action, through the layer the generated file watches here (since
  /// 0.8.1). Null when no action patches this data.
  final OptimisticLayer<T> Function(WidgetRef ref)? optimistic;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lib = library;
    lib?.preload();
    final value = watch(ref);
    final layer = optimistic?.call(ref);
    final page = layer == null || layer.isEmpty
        ? data
        : (T d) => data(layer.apply(d));
    // After a write that patched it, the data loads again under its patch: no loading.dart.
    final keep = keepPrevious || (layer?.settling(value.value) ?? false);
    return value.when(
      // A value Riverpod's offline persistence restored (isFromCache) is shown while the
      // fresh one loads, whatever keep_previous says (since 0.8.1).
      skipLoadingOnReload: keep || value.isFromCache,
      skipLoadingOnRefresh: keep,
      // A refusal is an answer, not a lost connection: it shows over the kept value.
      skipError: keepDataOnError && value.error is! DataRefusal,
      data: lib == null
          ? page
          : (d) => DeferredView(
              library: lib,
              page: () => page(d),
              loading: loading,
              error: error,
            ),
      loading: loading,
      error: (e, st) => error(e, st, () => _retry(ref)),
    );
  }

  /// A `retry` an app held on to (a debounced button, a timer, a future's callback) can run
  /// after the view is gone; `ref` can't be used then, so there is nothing to load again.
  void _retry(WidgetRef ref) {
    if (ref.context.mounted) refresh(ref);
  }
}

/// Fallback when no `loading.dart` exists anywhere up the tree.
class DefaultLoading extends StatelessWidget {
  /// Creates the fallback loading view.
  const DefaultLoading({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox.square(
      dimension: 32,
      child: CircularProgressIndicator.adaptive(),
    ),
  );
}

/// Fallback when no `error.dart` exists anywhere up the tree.
class DefaultError extends StatelessWidget {
  /// Creates the fallback error view for [error], with a button that calls [retry].
  const DefaultError({super.key, required this.error, required this.retry});

  /// What went wrong.
  final Object error;

  /// Loads the data again.
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$error', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );
}

/// Fallback when the root has no `not_found.dart`.
class DefaultNotFound extends StatelessWidget {
  /// Creates the fallback not-found view for [uri].
  const DefaultNotFound(this.uri, {super.key});

  /// The location that matched nothing.
  final Uri uri;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('Nothing at ${uri.path}'));
}
