import 'package:flutter/material.dart';

/// Shown when data.dart throws. `error` and `retry` are the two values
/// error.dart can ask for besides the route's own segments (`id` here).
class ItemError extends StatelessWidget {
  const ItemError({
    super.key,
    required this.id,
    required this.error,
    required this.retry,
  });

  final int id;
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text("Couldn't load item #$id: $error"),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );
}
