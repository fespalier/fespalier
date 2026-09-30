import 'package:flutter/material.dart';

class RootError extends StatelessWidget {
  const RootError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: TextButton.icon(
      onPressed: retry,
      icon: const Icon(Icons.refresh),
      label: Text('$error'),
    ),
  );
}
