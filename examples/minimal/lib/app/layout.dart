import 'package:flutter/material.dart';
import 'package:minimal/app.g.dart';

/// layout.dart wraps every page below this folder. `child` is the page; the
/// generator sees the `child` parameter and mounts this as a ShellRoute.
class AppLayout extends StatelessWidget {
  const AppLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Minimal'),
      actions: [
        // HomeRoute and AboutRoute are generated from the file tree.
        TextButton(
          onPressed: () => const HomeRoute().go(context),
          child: const Text('Home'),
        ),
        TextButton(
          onPressed: () => const AboutRoute().go(context),
          child: const Text('About'),
        ),
      ],
    ),
    body: SafeArea(child: child),
  );
}
