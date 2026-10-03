import 'package:auth/app.g.dart';
import 'package:flutter/material.dart';

/// Shown when no route matches. It shows without a layout, so it brings its own Scaffold.
class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Nothing at ${uri.path}'),
          TextButton(
            onPressed: () => const HomeRoute().go(context),
            child: const Text('Home'),
          ),
        ],
      ),
    ),
  );
}
