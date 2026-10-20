import 'package:flutter/material.dart';

/// The error view of every route below this folder that has no `error.dart` of its own, for a
/// `data.dart` that fails and, since 0.21.0, for a guard that fails. go_router shows it as the whole
/// page, with no layout around it, so it builds its own `Scaffold`.
class RootError extends StatelessWidget {
  const RootError({super.key, required this.error, required this.retry});

  /// What went wrong: for the developer (the report of a failed guard names
  /// it), not for the person looking at the screen, who gets a message of its
  /// own.
  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Something went wrong.'),
              TextButton.icon(
                onPressed: retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
}
