import 'package:flutter/material.dart';
import 'package:shop/api.dart';

class ProductError extends StatelessWidget {
  const ProductError({
    super.key,
    required this.id,
    required this.error,
    required this.retry,
  });

  final int id;
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final missing = error is ProductNotFound;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(missing
              ? 'Product #$id does not exist'
              : "Couldn't load product #$id: $error"),
          if (!missing)
            TextButton(onPressed: retry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
