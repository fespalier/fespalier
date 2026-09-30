import 'package:features/app.g.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

class InboxPage extends ConsumerWidget {
  const InboxPage({super.key, this.folder});

  /// `/inbox?folder=sent` survives the trip through the login page.
  final String? folder;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        children: [
          Text('Inbox: ${folder ?? 'all'}'),
          TextButton(
            onPressed: () => const AdminRoute().go(context),
            child: const Text('Admin'),
          ),
          TextButton(
            onPressed: () => ref.read(session.notifier).set(false),
            child: const Text('Sign out'),
          ),
        ],
      );
}
