import 'package:flutter/material.dart';

/// Shown when data.dart throws: a refusal (the server answered and said no), or an error nothing
/// here knows. Unreachable is not an error: the page is served from the device.
class HomeError extends StatelessWidget {
  const HomeError({super.key, required this.error, required this.retry});

  final Object error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't load the notes: $error"),
          TextButton(onPressed: retry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
