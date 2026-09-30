import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class LoginPage extends ConsumerWidget {
  const LoginPage({super.key, this.from});

  /// Where the guard that sent us here wanted to go.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      Text('Log in${from == null ? '' : ' to see $from'}'),
      TextButton(
        onPressed: () {
          ref.read(session.notifier).set(true);
          // Only in-app locations count: anything else falls back to `/`.
          context.go(returnTo(from));
        },
        child: const Text('Sign in'),
      ),
    ],
  );
}
