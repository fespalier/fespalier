import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart' show AsyncProviderListenable;

/// How long [DataRef.prefetchData] keeps what it loaded when no `keepFor` is given.
const prefetchKeepAlive = Duration(seconds: 30);

/// What the generated route classes build `read` and `prefetch` on.
///
/// The providers `data.dart` becomes are `autoDispose`: with nothing watching
/// one, it is dropped at the end of the frame. These keep it alive for as long
/// as a caller needs the result.
extension DataRef on WidgetRef {
  /// Reads [provider] once, completing with its value. The provider is kept
  /// alive until then, even if nothing else watches it, so the load isn't cut
  /// short. Not for `build`: use `watch` there.
  Future<T> readData<T>(AsyncProviderListenable<T> provider) async {
    final sub = listenManual(provider, (previous, next) {});
    try {
      return await read(provider.future);
    } finally {
      sub.close();
    }
  }

  /// Starts loading [provider] and keeps the result for [keepFor] (default
  /// [prefetchKeepAlive]), so the page that watches it next shows it at once
  /// instead of loading. Meant for the moment before navigating: on hover, on
  /// press, or in a list item's `onTap` just before `go`.
  ///
  /// If the load fails, the error isn't kept: the page starts a fresh load
  /// (and shows its own loading view) instead of an error nobody asked for yet.
  /// The subscription also ends when the widget that called this is disposed,
  /// and `Duration.zero` starts the load without keeping anything. A pending
  /// timer holds it: widget tests that prefetch should `pump` past [keepFor].
  void prefetchData(AsyncProviderListenable<Object?> provider, {Duration? keepFor}) {
    final keep = keepFor ?? prefetchKeepAlive;
    late final ProviderSubscription<AsyncValue<Object?>> sub;
    sub = listenManual(provider, (previous, next) {
      if (next.hasError) sub.close();
    });
    if (keep <= Duration.zero) {
      sub.close();
    } else {
      Timer(keep, sub.close);
    }
  }
}

/// What a page or layout below a section reads of the section's `data.dart`.
///
/// The section's own layout has already loaded it (and shows `loading.dart` or
/// `error.dart` until it has), so this reads the same provider and builds as
/// soon as it has a value.
class SectionView<T> extends ConsumerWidget {
  const SectionView({super.key, required this.watch, required this.data});

  final AsyncValue<T> Function(WidgetRef ref) watch;
  final Widget Function(T data) data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = watch(ref);
    return value.hasValue ? data(value.value as T) : const SizedBox.shrink();
  }
}
