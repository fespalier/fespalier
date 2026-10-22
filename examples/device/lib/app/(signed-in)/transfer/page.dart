import 'package:device/app.g.dart';
import 'package:device/device_setup.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/material.dart';

/// A sensitive action: sending money asks for the user-present key, which prompts. Where the device
/// has none (the web), the page says so and does not offer it.
class TransferPage extends ConsumerWidget {
  const TransferPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final send = TransferRoute.useSend(ref);
    final canConfirm = ref.watch(deviceBackend).keys.userPresent != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Send money')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Send 50.00 to Ada'),
            if (!canConfirm)
              const Text(
                'This device has no user-present key (the web has none), so it '
                'cannot confirm a transfer.',
              ),
            // Null while the call runs, and where there is no key to confirm with.
            FilledButton(
              onPressed: send.isPending || !canConfirm
                  ? null
                  : () => send.call((to: 'Ada', cents: 5000)),
              child: const Text('Confirm and send'),
            ),
            if (send.state.error case final UserPresenceRefused _)
              const Text('Confirmation cancelled. Nothing was sent.')
            else if (send.state.error case final error?)
              Text('The transfer failed: $error'),
            if (send.state.value case final done?) Text(done),
          ],
        ),
      ),
    );
  }
}
