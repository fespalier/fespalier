import 'package:flutter/material.dart';

class ProductError extends StatelessWidget {
  const ProductError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: retry, child: Text('Product failed: $error'));
}
