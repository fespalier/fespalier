import 'package:cratestack_example/src/wiring.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/material.dart';

/// Enrolling the device is signing in: the phone number first (the server texts a code), then the
/// code, which goes to the server with the device's public keys (Authkestra checks it, then sends a
/// challenge for each key) before the keys sign the challenges. Every call goes through the generated
/// client over the plain chain (`OrdersDeviceServer`). Neither step navigates: the enrolment guard
/// moves the user once there is a session.
class EnrolPage extends HookConsumerWidget {
  const EnrolPage({super.key, this.from});

  /// Where the guard that sent us here was going: the enrolment guard sends the user back to it.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = useTextEditingController();
    final code = useTextEditingController();
    // Whether the code was sent: the second step.
    final sent = useState(false);
    final errors = useState<FieldErrors?>(null);
    final failure = useState<String?>(null);
    final pending = useState(false);

    Future<void> run(Future<void> Function() step) async {
      errors.value = null;
      failure.value = null;
      pending.value = true;
      try {
        await step();
      } on FieldErrors catch (e) {
        errors.value = e;
      } on Object catch (e) {
        failure.value = '$e';
      } finally {
        if (context.mounted) pending.value = false;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Enrol')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (from != null) Text('Enrol to see $from'),
            if (!sent.value) ...[
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Phone number',
                  errorText: errors.value?.fields['phone'],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                // The server texts a code to the number.
                onPressed: pending.value
                    ? null
                    : () => run(() async {
                        await ref.read(ordersDeviceServer).sendCode(phone.text);
                        sent.value = true;
                      }),
                child: const Text('Send code'),
              ),
            ] else ...[
              Text('A code was sent to ${phone.text}.'),
              const Text('The demo server always sends 123456.'),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'One-time code',
                  errorText: errors.value?.fields['otp'],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                // Makes the device's keys and sends their public halves with the number and the
                // code; then the keys sign the challenges (the user-present one prompts), and the
                // server answers an attestation for each.
                onPressed: pending.value
                    ? null
                    : () => run(() async {
                        final challenge = await ref
                            .read(deviceBackend)
                            .beginEnrolment(
                              fields: {'phone': phone.text, 'otp': code.text},
                            );
                        await ref
                            .read(authSession.notifier)
                            .signIn(CompleteEnrolment(challenge));
                      }),
                child: Text(pending.value ? 'Enrolling...' : 'Confirm code'),
              ),
              TextButton(
                onPressed: () => sent.value = false,
                child: const Text('Use another number'),
              ),
            ],
            if (failure.value case final text?) Text(text),
          ],
        ),
      ),
    );
  }
}
