import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) => watch(ref).when(
    skipLoadingOnReload: keepPrevious,
    skipLoadingOnRefresh: keepPrevious,
    data: data,
    loading: loading,
    error: (e, st) => error(e, st, () => _retry(ref)),
  );

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
