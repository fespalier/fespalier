import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:plugins/session.dart';

/// Sign in, then go back to where the guard wanted to send the person.
class LoginPage extends ConsumerWidget {
  const LoginPage({super.key, this.from});

  /// Where the guard that sent us here wanted to go.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Log in')),
    body: Column(
      children: [
        Text('Log in${from == null ? '' : ' to see $from'}'),
        TextButton(
          onPressed: () {
            ref.read(session.notifier).set(true);
            context.go(returnTo(from));
          },
          child: const Text('Sign in'),
        ),
      ],
    ),
  );
}
