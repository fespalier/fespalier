import 'package:flutter/material.dart';

/// Shown when a page's data.dart throws: a refusal (the core's server answered and said no), or an error nothing here
/// knows. Unreachable is not an error: the notes page is served from the device, and the core's page never throws.
class RootError extends StatelessWidget {
  const RootError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't load this page: $error"),
          TextButton(onPressed: retry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
