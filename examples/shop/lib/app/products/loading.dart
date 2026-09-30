import 'package:flutter/material.dart';
import 'package:trellis/trellis.dart';

/// Also covers products/$id, which has no loading.dart of its own.
class ProductsLoading extends Loading<Params> {
  const ProductsLoading(super.params, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
