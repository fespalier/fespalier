import 'package:flutter/material.dart';
import 'package:minimal/app.g.dart';

/// Shown when no route matches (`/nope`) or a segment doesn't parse
/// (`/items/abc`). It is optional, and `uri` is the only thing it can ask for.
/// It shows without the layout, so it brings its own Scaffold and link home.
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
