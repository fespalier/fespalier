import 'package:adopt/screens.dart';
import 'package:flutter/widgets.dart';

/// Shown when the product provider fails (`/shop/products/99`). `retry` is filled by the
/// generator.
class ProductError extends StatelessWidget {
  const ProductError({super.key, required this.retry});

  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => LoadFailedView(onRetry: retry);
}
