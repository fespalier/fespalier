import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: FilledButton(
          onPressed: () => const ProductsRoute().go(context),
          child: const Text('Browse products'),
        ),
      );
}
