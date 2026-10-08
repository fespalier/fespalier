import 'package:adopt/legacy_routes.dart';
import 'package:adopt/screens.dart';
import 'package:adopt/shop.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

// The app before it adopted fespalier: one hand-written GoRouter with every route in it. It is
// kept compiled (flutter analyze checks it) so test/parity_test.dart can open the same URLs here
// and in the half-moved app. Nothing in lib/app/ imports this folder.

GoRouter buildBeforeRouter({String initialLocation = '/'}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    ...legacyRoutes(),
    GoRoute(
      path: '/products',
      builder: (context, state) => const BeforeProductsPage(),
    ),
    GoRoute(
      path: '/products/:id',
      builder: (context, state) {
        final id = int.tryParse(state.pathParameters['id']!);
        return id == null
            ? MissingView(uri: state.uri)
            : BeforeProductPage(id: id);
      },
    ),
  ],
  errorBuilder: (context, state) => MissingView(uri: state.uri),
);

/// The page loaded its own data: it watched a provider and drew loading, error and data itself.
/// In lib/app/ that is `data.dart`, `loading.dart` and `error.dart`.
class BeforeProductsPage extends ConsumerWidget {
  const BeforeProductsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(catalogProvider)) {
        AsyncData(:final value) => ProductListView(
          products: value,
          onOpen: (product) => context.go('/products/${product.id}'),
          onHome: () => context.go('/'),
        ),
        AsyncError() => LoadFailedView(
          onRetry: () => ref.invalidate(catalogProvider),
        ),
        _ => const LoadingView(),
      };
}

class BeforeProductPage extends ConsumerWidget {
  const BeforeProductPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(productProvider(id))) {
        AsyncData(:final value) => ProductDetailView(
          product: value,
          onList: () => context.go('/products'),
        ),
        AsyncError() => LoadFailedView(
          onRetry: () => ref.invalidate(productProvider(id)),
        ),
        _ => const LoadingView(),
      };
}
