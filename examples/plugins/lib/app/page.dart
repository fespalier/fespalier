import 'package:fespalier/fespalier.dart';
import 'package:fespalier_push/fespalier_push.dart';
import 'package:flutter/material.dart';
import 'package:plugins/push.dart';
import 'package:plugins/session.dart';

/// The home page, with the debug buttons that stand in for the system tray: each one is a tap on
/// a notification, delivered through the fake push source.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('Plugins')),
    body: ListView(
      children: [
        Text(ref.watch(session) ? 'Signed in' : 'Signed out'),
        TextButton(
          onPressed: () => ref.read(session.notifier).set(true),
          child: const Text('Sign in'),
        ),
        TextButton(
          onPressed: () => demoPush.tap(
            const PushMessage(id: 'tap-order', data: {'link': '/orders/42'}),
          ),
          child: const Text('Simulate a tap: order 42'),
        ),
        TextButton(
          onPressed: () => demoPush.tap(
            const PushMessage(id: 'tap-account', data: {'link': '/account'}),
          ),
          child: const Text('Simulate a tap: account'),
        ),
        TextButton(
          onPressed: () => demoPush.tap(
            const PushMessage(
              id: 'tap-evil',
              data: {'link': 'https://evil.example.com/orders/1'},
            ),
          ),
          child: const Text('Simulate a tap: foreign link'),
        ),
      ],
    ),
  );
}
