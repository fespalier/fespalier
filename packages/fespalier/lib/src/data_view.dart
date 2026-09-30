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
  const DataView({
    super.key,
    required this.watch,
    required this.refresh,
    required this.data,
    required this.loading,
    required this.error,
    this.keepPrevious = true,
  });

  final AsyncValue<T> Function(WidgetRef ref) watch;
  final void Function(WidgetRef ref) refresh;
  final Widget Function(T data) data;
  final Widget Function() loading;
  final Widget Function(Object error, StackTrace stackTrace, VoidCallback retry)
      error;
  final bool keepPrevious;

  @override
  Widget build(BuildContext context, WidgetRef ref) => watch(ref).when(
        skipLoadingOnReload: keepPrevious,
        skipLoadingOnRefresh: keepPrevious,
        data: data,
        loading: loading,
        error: (e, st) => error(e, st, () => refresh(ref)),
      );
}

/// Fallback when no `loading.dart` exists anywhere up the tree.
class DefaultLoading extends StatelessWidget {
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
  const DefaultError({super.key, required this.error, required this.retry});

  final Object error;
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
  const DefaultNotFound(this.uri, {super.key});

  final Uri uri;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text('Nothing at ${uri.path}'));
}
