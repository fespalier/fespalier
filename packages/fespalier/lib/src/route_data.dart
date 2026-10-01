import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart'
    show AsyncProviderListenable, ProviderListenable;

/// A prefetched provider, kept alive until [close] (or until the `keepFor` you gave
/// it passes, or the widget whose `ref` started it is disposed).
///
/// The providers `data.dart` becomes are `autoDispose`: with nothing listening, one
/// is dropped at the end of the frame, and the warm value with it. A handle is that
/// listener. Hold it for as long as the warm value should stay (an app's prefetch
/// queue holds one per lease) and `close()` it when done; closing it twice is fine.
///
/// A load that fails closes its handle: the error isn't kept, so the page that
/// watches the provider next starts a fresh load instead of showing an error nobody
/// asked for yet. A handle that holds several providers (`prefetchAll`) closes all
/// of them when one fails.
final class PrefetchHandle {
  PrefetchHandle._(this._release);

  /// A handle that keeps nothing: what a prefetch with `keepFor: Duration.zero`,
  /// or of no providers at all, returns.
  PrefetchHandle._closed() : _release = null;

  void Function()? _release;
  Timer? _timer;

  /// The handle that holds this one together with others, when there is one.
  PrefetchHandle? _group;

  /// Whether this handle no longer keeps anything alive.
  bool get isClosed => _release == null;

  /// Stops keeping the provider alive. It is dropped once nothing else watches it.
  void close() {
    _timer?.cancel();
    _timer = null;
    final release = _release;
    _release = null;
    release?.call();
  }

  /// The load failed: nothing is kept, not even what the others it was
  /// started with are holding.
  void _fail() {
    close();
    _group?.close();
  }

  /// One handle that closes [handles] together, and closes when one fails.
  static PrefetchHandle _join(List<PrefetchHandle> handles) {
    final open = [
      for (final h in handles)
        if (!h.isClosed) h,
    ];
    if (open.isEmpty) return PrefetchHandle._closed();
    final group = PrefetchHandle._(() {
      for (final h in open) {
        h.close();
      }
    });
    for (final h in open) {
      h._group = group;
    }
    return group;
  }
}

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

  /// Starts loading [provider] and keeps it alive until the returned
  /// [PrefetchHandle] is closed, so the page that watches it next shows the value
  /// at once instead of loading. Meant for the moment before navigating (on hover,
  /// on press, in a list item's `onTap` just before `go`), or from an app's own
  /// prefetch queue, with the providers of `AppRoutes.dataAt(uri)`.
  ///
  /// With [keepFor], the handle also closes itself after that long; without it the
  /// provider stays until you close the handle. `Duration.zero` starts the load and
  /// keeps nothing. A pending `keepFor` timer holds a widget test: `pump` past it.
  ///
  /// If the load fails, the handle closes: the error isn't kept. The subscription
  /// also ends when the widget that called this is disposed.
  PrefetchHandle prefetchData(
    ProviderListenable<AsyncValue<Object?>> provider, {
    Duration? keepFor,
  }) {
    late final PrefetchHandle handle;
    final sub = listenManual<AsyncValue<Object?>>(provider, (previous, next) {
      if (next.hasError) handle._fail();
    });
    handle = PrefetchHandle._(sub.close);
    if (keepFor != null) {
      if (keepFor <= Duration.zero) {
        handle.close();
      } else {
        handle._timer = Timer(keepFor, handle.close);
      }
    }
    return handle;
  }

  /// [prefetchData] for several providers (what `AppRoutes.dataAt(uri)` returns),
  /// closed together by one handle.
  PrefetchHandle prefetchAll(
    Iterable<ProviderListenable<AsyncValue<Object?>>> providers, {
    Duration? keepFor,
  }) => PrefetchHandle._join([
    for (final p in providers) prefetchData(p, keepFor: keepFor),
  ]);
}

/// What a page or layout below a section reads of the section's `data.dart`.
///
/// The section's own layout has already loaded it (and shows `loading.dart` or
/// `error.dart` until it has), so this reads the same provider and builds as
/// soon as it has a value.
class SectionView<T> extends ConsumerWidget {
  /// Creates a view of the section data [watch] reads, built by [data] once it has a value.
  const SectionView({super.key, required this.watch, required this.data});

  /// Reads the section's provider; called on every build.
  final AsyncValue<T> Function(WidgetRef ref) watch;

  /// Builds the view from the section data.
  final Widget Function(T data) data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = watch(ref);
    return value.hasValue ? data(value.value as T) : const SizedBox.shrink();
  }
}
