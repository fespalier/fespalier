import 'package:flutter/material.dart';
import 'package:shop/api.dart';
import 'package:trellis/trellis.dart';

import 'params.dart';

class ProductError extends ErrorView<ProductParams> {
  const ProductError(super.params, super.failure, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missing = failure.error is ProductNotFound;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(missing
              ? 'Product #${params.id} does not exist'
              : "Couldn't load product #${params.id}: ${failure.error}"),
          if (!missing)
            TextButton(onPressed: failure.retry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
