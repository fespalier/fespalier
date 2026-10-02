import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () => const ProductsRoute().go(context),
              child: const Text('Browse products'),
            ),
            // A string path is fine when it matches a route: `fsp` checks that
            // it does (`lints: unknown_path` in pubspec.yaml), and the typed
            // route above is the one that cannot be misspelled.
            TextButton(
              onPressed: () => context.go('/products?sort=expensive'),
              child: const Text('Most expensive first'),
            ),
            TextButton(
              // fsp:ignore unknown_path -- gift cards aren't built yet: not_found.dart shows
              onPressed: () => context.go('/gift-cards'),
              child: const Text('Gift cards'),
            ),
          ],
        ),
      );
}
