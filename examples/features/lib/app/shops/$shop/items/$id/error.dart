import 'package:flutter/material.dart';

/// Positional parameters bound by type: Object → the error,
/// VoidCallback → retry.
class ItemError extends StatelessWidget {
  const ItemError(this.problem, this.again, {super.key});

  final Object problem;
  final VoidCallback again;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: again, child: Text('Failed: $problem'));
}
