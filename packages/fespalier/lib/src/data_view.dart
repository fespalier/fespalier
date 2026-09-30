import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Glue emitted around every route that has a `data.dart`:
/// watch the provider, then pick page / loading / error.
///
/// Takes closures instead of provider types so it works with any provider
/// whose value is an [AsyncValue].
class DataView<T> extends ConsumerWidget {
  const DataView({
    super.key,
    required this.watch,
    required this.refresh,
    required this.data,
    required this.loading,
    required this.error,
  });

  final AsyncValue<T> Function(WidgetRef ref) watch;
  final void Function(WidgetRef ref) refresh;
  final Widget Function(T data) data;
  final Widget Function() loading;
  final Widget Function(Object error, StackTrace stackTrace, VoidCallback retry)
      error;

  @override
  Widget build(BuildContext context, WidgetRef ref) => watch(ref).when(
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
