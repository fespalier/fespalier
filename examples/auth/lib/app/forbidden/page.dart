import 'package:auth/app.g.dart';
import 'package:flutter/material.dart';

/// Where `requireRole` sends a signed-in user who lacks the role. Outside the guarded group: it is
/// the answer to a guard, so a guard on it would redirect it to itself.
class ForbiddenPage extends StatelessWidget {
  const ForbiddenPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Forbidden')),
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text("Your account can't open that page."),
          TextButton(
            onPressed: () => const HomeRoute().go(context),
            child: const Text('Home'),
          ),
        ],
      ),
    ),
  );
}
