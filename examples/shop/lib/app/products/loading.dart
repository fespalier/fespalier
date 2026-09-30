import 'package:flutter/material.dart';

/// Also covers products/$id, which has no loading.dart of its own.
class ProductsLoading extends StatelessWidget {
  const ProductsLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final shade = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            height: 48,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: shade,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
      ],
    );
  }
}
