import 'package:device/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter/material.dart';

/// The home page is public: it says whether this device is enrolled, and why it is not when the
/// session ended on its own, and links to the signed-in pages.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authUser);
    final state = ref.watch(authSession);
    return Scaffold(
      appBar: AppBar(title: const Text('Device example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(user == null ? 'Not enrolled' : 'Signed in as ${user.name}'),
            if (state case SignedOut(:final reason?)) Text(_why(reason)),
            if (user == null)
              FilledButton(
                onPressed: () => const EnrolRoute().go(context),
                child: const Text('Enrol this device'),
              )
            else ...[
              TextButton(
                onPressed: () => const AccountRoute().go(context),
                child: const Text('Account'),
              ),
              TextButton(
                onPressed: () => const TransferRoute().go(context),
                child: const Text('Send money'),
              ),
              // Revokes the device on the server, then deletes both keys. The guards move the
              // user: signOut() sets SignedOut before its first await.
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

  /// Why an earlier session is gone, when the device did not end it.
  static String _why(SignOutReason reason) => switch (reason) {
    SignOutReason.keyLost => "This device's key changed. Enrol again.",
    SignOutReason.revoked => 'This device was revoked. Enrol again.',
    _ => 'Your session ended. Enrol again.',
  };
}
