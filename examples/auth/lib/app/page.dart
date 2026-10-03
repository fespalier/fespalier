import 'package:auth/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';

/// The home page is public: it says who is signed in, and links to the signed-in pages.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authUser);
    return Scaffold(
      appBar: AppBar(title: const Text('Auth example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(user == null ? 'Signed out' : 'Signed in as ${user.name}'),
            if (user == null)
              FilledButton(
                onPressed: () => const SignInRoute().go(context),
                child: const Text('Sign in'),
              )
            else ...[
              TextButton(
                onPressed: () => const OrdersRoute().go(context),
                child: const Text('Orders'),
              ),
              if (user.hasRole('admin'))
                TextButton(
                  onPressed: () => const AdminRoute().go(context),
                  child: const Text('Admin'),
                ),
              // The guards move the user: signOut() sets SignedOut before its first await, and every
              // guard that watches the session runs again.
              TextButton(
                onPressed: () => ref.read(authSession.notifier).signOut(),
                child: const Text('Sign out'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
