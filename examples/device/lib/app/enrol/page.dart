import 'package:device/demo/demo_api.dart';
import 'package:device/device_setup.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:flutter/material.dart';

/// Enrolling the device is signing in: the phone number first (the server texts a code and sends a
/// challenge for each key), then the code (the keys sign the challenges). Neither step navigates:
/// the enrolment guard moves the user once there is a session.
class EnrolPage extends HookConsumerWidget {
  const EnrolPage({super.key, this.from});

  /// Where the guard that sent us here was going: the enrolment guard sends the user back to it.
  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = useTextEditingController();
    final code = useTextEditingController();
    // The challenge leg one answered: its presence is the second step.
    final challenge = useState<EnrolmentChallenge?>(null);
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
            if (challenge.value == null) ...[
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
                // Makes the device's keys, and sends their public halves with the phone number.
                onPressed: pending.value
                    ? null
                    : () => run(() async {
                        challenge.value = await ref
                            .read(deviceBackend)
                            .beginEnrolment(fields: {'phone': phone.text});
                      }),
                child: const Text('Send code'),
              ),
            ] else ...[
              Text('A code was sent to ${phone.text}.'),
              const Text('The demo server always sends ${DemoApi.demoCode}.'),
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
                // The keys sign the challenges (the user-present one prompts), and the server
                // answers an attestation for each.
                onPressed: pending.value
                    ? null
                    : () => run(() async {
                        await ref
                            .read(authSession.notifier)
                            .signIn(
                              CompleteEnrolment(
                                challenge.value!,
                                proof: code.text,
                              ),
                            );
                      }),
                child: Text(pending.value ? 'Enrolling...' : 'Confirm code'),
              ),
              TextButton(
                onPressed: () => challenge.value = null,
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
