import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/misc.dart'
    show AsyncProviderListenable, ProviderListenable, ProviderOrFamily;

import 'route_data.dart';

/// What the generated route classes build on when `data.dart` *selects* a provider
/// that already exists:
///
/// ```dart
/// ProviderListenable<AsyncValue<Product>> data({required int id}) => productProvider(id);
/// ```
///
/// Watching only needs a `ProviderListenable`, but invalidating, refreshing and
/// reading the value as a `Future` need the provider itself. The declared type
/// stays `ProviderListenable<AsyncValue<T>>`, the same spelling for every provider
/// kind (a `riverpod_generator` family instance is a `$FunctionalProvider` with
/// `$FutureModifier`, so it is a `ProviderOrFamily` and an
/// `AsyncProviderListenable<T>`), and these check at run time that what came back is
/// one. Anything else (a `.select(...)` of a provider, say) throws a [StateError]
/// that says what to return instead.
///
/// The selected provider is never wrapped, so its own `retry`, `keepAlive` and
/// dependencies are what runs.
extension SelectedDataRef on WidgetRef {
  /// Invalidates the selected provider (`error.dart`'s `retry` does this).
  void invalidateSelected(ProviderListenable<AsyncValue<Object?>> selected) {
    invalidate(_providerOf(selected));
  }

  /// Invalidates the selected provider and reads it again, so it runs once.
  /// Completes with its fresh value, or its error.
  Future<void> refreshSelected<T>(ProviderListenable<AsyncValue<T>> selected) {
    final provider = _asyncOf(selected);
    invalidate(_providerOf(selected));
    return read(provider.future);
  }

  /// Reads the selected provider once, keeping it alive until it completes.
  Future<T> readSelected<T>(ProviderListenable<AsyncValue<T>> selected) =>
      readData(_asyncOf(selected));
}

ProviderOrFamily _providerOf(ProviderListenable<AsyncValue<Object?>> selected) {
  if (selected is ProviderOrFamily) return selected as ProviderOrFamily;
  throw _notAProvider(selected);
}

AsyncProviderListenable<T> _asyncOf<T>(
  ProviderListenable<AsyncValue<T>> selected,
) {
  if (selected is ProviderOrFamily && selected is AsyncProviderListenable<T>) {
    return selected;
  }
  throw _notAProvider(selected);
}

StateError _notAProvider(Object selected) => StateError(
  'data.dart selected `$selected`, which is not a FutureProvider, '
  'StreamProvider or generated async provider, so it cannot be invalidated '
  'or refreshed. Return the provider itself from data() '
  '(`=> productProvider(id)`), not a `.select(...)` of it.',
);
