import 'package:flutter/material.dart';
import 'package:shop/app.g.dart';
import 'package:trellis/trellis.dart';

class HomePage extends Screen<Params> {
  const HomePage(super.data, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: FilledButton(
          onPressed: () => const ProductsRoute().go(context),
          child: const Text('Browse products'),
        ),
      );
}
