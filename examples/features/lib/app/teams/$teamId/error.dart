import 'package:flutter/material.dart';

class TeamError extends StatelessWidget {
  const TeamError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: retry, child: Text('Team failed: $error'));
}
